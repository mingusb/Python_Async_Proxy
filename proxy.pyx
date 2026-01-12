import asyncio
import base64
import json
import signal
import socket
import sys
import time
import os
import ctypes
from pathlib import Path
from collections import Counter

try:
    import uvloop
except ImportError:
    uvloop = None

cdef str USER = "username"
cdef str PASS = "password"
cdef str HOST = "127.0.0.1"
cdef int PORT = 8888
cdef int TIMEOUT = 10  # Request timeout
cdef str DEFAULT_BACKEND_HOST = "127.0.0.1"  # Backend for relative links
cdef int DEFAULT_BACKEND_PORT = 80           # Port for relative links
cdef bytes AUTH_HEADER = (
    b"Proxy-Authorization: Basic "
    + base64.b64encode(f"{USER}:{PASS}".encode())
)
cdef bint TRACK_DOMAINS = False  # flip on if you want domain stats (slower)
cdef bytes RESP_407 = (
    b"HTTP/1.1 407 Proxy Auth Required\r\n"
    b"Proxy-Authenticate: Basic\r\n\r\n"
)
cdef bytes RESP_502 = b"HTTP/1.1 502 Bad Gateway\r\n\r\n"
cdef int SOCK_BUF_SIZE = 131072
cdef int SOCKET_BUF_BYTES = 1 << 20
visits = Counter()
cdef unsigned long bw = 0
cdef unsigned long total_requests = 0
cdef unsigned long successful_requests = 0
cdef unsigned long failed_requests = 0

_zc = None
_ENABLE_SPLICE = os.environ.get("USE_SPLICE", "0") == "1"
try:
    if _ENABLE_SPLICE:
        _zc = ctypes.CDLL(str(Path(__file__).with_name("zero_copy_helper.so")))
except Exception:
    _zc = None

# Helper functions
cdef str format_bw(unsigned long xfered):
    """Format bandwidth usage for metrics."""
    if xfered < 1024:
        return f"{xfered}B"
    elif xfered < 1024**2:
        return f"{xfered / 1024:.2f}KB"
    else:
        return f"{xfered / 1024**2:.2f}MB"

cdef str canon(str host):
    """Simplify domain name to base domain (e.g., xyz.com)."""
    cdef list parts = host.split('.')
    cdef Py_ssize_t n = len(parts)
    if n > 2:
        return '.'.join(parts[n - 2 : n])
    return host

cdef inline void tune_socket(object sock):
    """Set aggressive socket options to trim latency."""
    if sock is None:
        return
    try:
        sock.setblocking(False)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SOCKET_BUF_BYTES)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCKET_BUF_BYTES)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_QUICKACK, 1)
    except Exception:
        pass

def print_met():
    """Print proxy metrics and exit."""
    print("Metrics:")
    print(f"Bandwidth usage: {format_bw(bw)}")
    print(f"Total Requests: {total_requests}")
    print(f"Successful Visits: {successful_requests}")
    print(f"Failed Visits: {failed_requests}")
    if TRACK_DOMAINS:
        for dom, count in visits.items():
            if dom not in ("total", "successful", "failed"):
                print(f"- {dom}: {count} visit(s)")
    sys.exit(0)

cdef inline tuple fast_parse_host(bytes targ, bytes raw_request):
    """Return (host, port, path) for HTTP requests without urlparse."""
    cdef str host = DEFAULT_BACKEND_HOST
    cdef int port = DEFAULT_BACKEND_PORT
    cdef str path = "/"

    cdef int scheme_idx = targ.find(b"://")
    cdef int slash_idx

    if scheme_idx != -1:
        after_scheme = targ[scheme_idx + 3 :]
        slash_idx = after_scheme.find(b"/")
        if slash_idx == -1:
            hostport = after_scheme
            path = "/"
        else:
            hostport = after_scheme[:slash_idx]
            try:
                path = after_scheme[slash_idx:].decode("ascii", "ignore") or "/"
            except Exception:
                path = "/"

        colon_idx = hostport.find(b":")
        if colon_idx != -1:
            try:
                host = hostport[:colon_idx].decode("ascii", "ignore")
                port = int(hostport[colon_idx + 1 :])
            except Exception:
                host = hostport[:colon_idx].decode("ascii", "ignore")
        else:
            host = hostport.decode("ascii", "ignore")
        return host, port, path

    # Relative URL: pull Host header
    raw_lower = raw_request.lower()
    host_idx = raw_lower.find(b"\r\nhost:")
    if host_idx != -1:
        host_line = raw_request[host_idx + 2 :]
        end_idx = host_line.find(b"\r\n")
        if end_idx != -1:
            host_line = host_line[:end_idx]
        try:
            host_val = host_line.split(b":", 1)[1].strip()
            colon_idx = host_val.find(b":")
            if colon_idx != -1:
                host = host_val[:colon_idx].decode("ascii", "ignore")
                port = int(host_val[colon_idx + 1 :])
            else:
                host = host_val.decode("ascii", "ignore")
        except Exception:
            pass

    try:
        path = targ.decode("ascii", "ignore") or "/"
    except Exception:
        path = "/"
    return host, port, path


async def proxy(client_r, client_w):
    """Legacy entrypoint (kept for compatibility with asyncio.start_server)."""
    client_sock = client_w.get_extra_info("socket")
    return await handle_client(client_sock)


async def handle_client(object client_sock):
    """Handle proxy connections with minimal Python overhead."""
    global bw, total_requests, successful_requests, failed_requests
    total_requests += 1  # count connections (keep-alive aggregates requests)
    try:
        loop = asyncio.get_running_loop()
        remote_sock = None
        tune_socket(client_sock)

        # Read the initial client request via raw socket
        data = await asyncio.wait_for(loop.sock_recv(client_sock, 2048), timeout=TIMEOUT)
        if not data:
            return

        # Handle /metrics endpoint
        if b'GET /metrics' in data:
            metrics_resp = {
                "bandwidth_usage": format_bw(bw),
                "total_requests": total_requests,
                "successful_visits": successful_requests,
                "failed_visits": failed_requests,
                "top_sites": [],
            }
            if TRACK_DOMAINS:
                metrics_resp["top_sites"] = [
                    {"url": dom, "visits": count}
                    for dom, count in visits.items()
                    if dom not in ("total", "successful", "failed")
                ]
            await loop.sock_sendall(
                client_sock,
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n\r\n"
                + json.dumps(metrics_resp).encode(),
            )
            return

        # Validate Proxy-Authorization header (byte match avoids repeated decoding)
        if AUTH_HEADER not in data:
            await loop.sock_sendall(client_sock, RESP_407)
            return

        # Parse the target URL
        met, targ, _ = data.split(b' ')[:3]
        remote_sock = None
        dom = ""

        if met == b'CONNECT':  # Handle HTTPS CONNECT requests
            try:
                host, port_b = targ.split(b':')
                host_str = host.decode()
                dom = canon(host_str)
                remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                tune_socket(remote_sock)
                await loop.sock_connect(remote_sock, (host_str, int(port_b)))
                await loop.sock_sendall(
                    client_sock, b"HTTP/1.1 200 Connection Established\r\n\r\n"
                )
            except Exception as error:
                print(f"Error connecting to {host.decode()}:{int(port_b)}: {error}")
                await loop.sock_sendall(client_sock, RESP_502)
                failed_requests += 1
                return
        else:  # Handle HTTP GET/POST requests
            host, port, path = fast_parse_host(targ, data)
            dom = canon(host)
            if host == HOST and port == PORT:
                host = DEFAULT_BACKEND_HOST
                port = DEFAULT_BACKEND_PORT

            # Reconstruct the full request if the URL is relative
            if targ.startswith(b"/"):
                req_lines = data.split(b"\r\n")
                filtered_headers = [
                    line for line in req_lines[1:] if line and not line.lower().startswith(b"host:")
                ]
                data = (
                    f"GET {path} HTTP/1.1\r\nHost: {host}\r\n".encode()
                    + b"\r\n".join(filtered_headers)
                    + b"\r\n\r\n"
                )

            try:
                remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                tune_socket(remote_sock)
                await loop.sock_connect(remote_sock, (host, port))
                await loop.sock_sendall(remote_sock, data)
            except Exception as error:
                print(f"Error connecting to {host}:{port}: {error}")
                await loop.sock_sendall(client_sock, b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                failed_requests += 1
                return

        # Update domain visits (count every request)
        if TRACK_DOMAINS:
            visits.update([dom])

        # Relay data between client and remote server
        async def relay_sock(src_sock, dest_sock):
            global bw
            if src_sock is None or dest_sock is None:
                return
            buf = bytearray(SOCK_BUF_SIZE)
            mv = memoryview(buf)
            try:
                while True:
                    # Attempt zero-copy splice if helper is loaded
                    if _zc is not None and _ENABLE_SPLICE:
                        sent = _zc.splice_copy(src_sock.fileno(), dest_sock.fileno())
                        if sent > 0:
                            bw += sent
                            continue
                    n = await loop.sock_recv_into(src_sock, mv)
                    if n <= 0:
                        break
                    bw += n
                    await loop.sock_sendall(dest_sock, mv[:n])
            except (asyncio.TimeoutError, ConnectionResetError, BrokenPipeError, OSError):
                pass

        if remote_sock is not None:
            to_client = asyncio.create_task(relay_sock(remote_sock, client_sock))
            to_remote = asyncio.create_task(relay_sock(client_sock, remote_sock))
            await asyncio.gather(to_client, to_remote)

            # Increment successful visits only if relay completes without errors
            successful_requests += 1

    except asyncio.TimeoutError:
        print("Timeout.")
        failed_requests += 1
    except Exception as error:
        print(f"Error: {error}")
        failed_requests += 1
    finally:
        try:
            client_sock.close()
        except Exception:
            pass
        try:
            if remote_sock is not None:
                remote_sock.close()
        except Exception:
            pass

async def main():
    """Run the proxy server with a raw socket accept loop."""
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, print_met)

    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except Exception:
        pass
    tune_socket(server_sock)
    server_sock.bind((HOST, PORT))
    server_sock.listen(65535)
    print(f"Running on {HOST}:{PORT}")

    try:
        while True:
            client_sock, _ = await loop.sock_accept(server_sock)
            asyncio.create_task(handle_client(client_sock))
    finally:
        server_sock.close()

try:
    if uvloop is not None:
        asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
    asyncio.run(main())
except KeyboardInterrupt:
    print_met()
import ctypes

_zc = None
try:
    _zc = ctypes.CDLL(str(Path(__file__).with_name("zero_copy_helper.so")))
except Exception:
    _zc = None
