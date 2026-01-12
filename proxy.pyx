import asyncio
import base64
import json
import signal
import socket
import sys
import time
import os
import ctypes
from concurrent.futures import ThreadPoolExecutor
from collections import Counter
from pathlib import Path

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
WORKERS = int(os.environ.get("WORKERS", "1"))
_batch = None
_ENABLE_BATCH = os.environ.get("USE_BATCH", "0") == "1"
_ENABLE_ZC = os.environ.get("USE_ZEROCOPY", "0") == "1"
_ENABLE_SPLICE = os.environ.get("USE_SPLICE", "0") == "1"
_ENABLE_C_RELAY = os.environ.get("USE_C_RELAY", "0") == "1"
_CRELAY_THREADS = int(os.environ.get("CRELAY_THREADS", "256"))
_BUSY_POLL_US = int(os.environ.get("BUSY_POLL_US", "0"))
visits = Counter()
cdef unsigned long bw = 0
cdef unsigned long total_requests = 0
cdef unsigned long successful_requests = 0
cdef unsigned long failed_requests = 0

_zc = None
_splicer = None
_crelay = None
_relay_executor = None
try:
    if _ENABLE_ZC:
        _zc = ctypes.CDLL(str(Path(__file__).with_name("zero_copy_helper.so")))
except Exception:
    _zc = None

try:
    if _ENABLE_SPLICE:
        _splicer = ctypes.CDLL(str(Path(__file__).with_name("splice_helper.so")))
        _splicer.init_splice_pipe()
except Exception:
    _splicer = None

try:
    if _ENABLE_BATCH:
        _batch = ctypes.CDLL(str(Path(__file__).with_name("batch_helper.so")))
except Exception:
    _batch = None

try:
    if _ENABLE_C_RELAY:
        _crelay = ctypes.CDLL(str(Path(__file__).with_name("c_relay_helper.so")))
        try:
            _crelay.relay_pair.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
            _crelay.relay_pair.restype = ctypes.c_int
            _relay_executor = ThreadPoolExecutor(max_workers=_CRELAY_THREADS)
        except Exception:
            pass
except Exception:
    _crelay = None

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
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except Exception:
        pass
    try:
        if hasattr(socket, "TCP_FASTOPEN_CONNECT"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_FASTOPEN_CONNECT, 1)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SOCKET_BUF_BYTES)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCKET_BUF_BYTES)
    except Exception:
        pass
    if _BUSY_POLL_US > 0:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BUSY_POLL, _BUSY_POLL_US)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_PREFER_BUSY_POLL, 1)
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
            cdef int sizes[16]
            cdef int max_batch = 16
            mv = memoryview(buf)
            try:
                while True:
                    if _batch is not None and _ENABLE_BATCH:
                        count = _batch.recvmmsg_batch(
                            src_sock.fileno(), mv, SOCK_BUF_SIZE, max_batch, sizes
                        )
                        if count > 0:
                            total_sent = 0
                            for i in range(count):
                                if sizes[i] > 0:
                                    total_sent += sizes[i]
                            if total_sent > 0:
                                sent = _batch.sendmmsg_batch(
                                    dest_sock.fileno(), mv, SOCK_BUF_SIZE, sizes, count
                                )
                                if sent > 0:
                                    bw += total_sent
                                    continue
                        # negative values fall through to regular read
                    if _splicer is not None and _ENABLE_SPLICE:
                        sent = _splicer.splice_once(
                            src_sock.fileno(), dest_sock.fileno(), SOCK_BUF_SIZE
                        )
                        if sent > 0:
                            bw += sent
                            continue
                        elif sent == -1:
                            break
                    if _zc is not None and _ENABLE_ZC:
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
            if _crelay is not None and _ENABLE_C_RELAY:
                def _relay_pair():
                    return _crelay.relay_pair(client_sock.fileno(), remote_sock.fileno(), SOCK_BUF_SIZE)

                await loop.run_in_executor(_relay_executor, _relay_pair)
                successful_requests += 1
            else:
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
    if _relay_executor is not None:
        loop.set_default_executor(_relay_executor)
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, print_met)

    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except Exception:
        pass
    try:
        server_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_FASTOPEN, 1024)
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

def _shutdown_children(list worker_pids):
    """Best-effort cleanup for forked workers."""
    for pid in worker_pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass
    for pid in worker_pids:
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass


def _run_workers():
    """Spawn WORKERS processes (if >1) to leverage SO_REUSEPORT."""
    workers = WORKERS if WORKERS > 0 else 1
    if workers > 1 and not hasattr(os, "fork"):
        workers = 1
    if workers == 1:
        try:
            if uvloop is not None:
                asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
            asyncio.run(main())
        except KeyboardInterrupt:
            print_met()
        return

    worker_pids = []

    def _handle_stop(sig=0, frame=None):
        _shutdown_children(worker_pids)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    for _ in range(workers):
        pid = os.fork()
        if pid == 0:
            try:
                if uvloop is not None:
                    asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
                asyncio.run(main())
            except KeyboardInterrupt:
                print_met()
            sys.exit(0)
        worker_pids.append(pid)

    def _reap(_sig, _frame):
        while True:
            try:
                reaped, _ = os.waitpid(-1, os.WNOHANG)
                if reaped <= 0:
                    break
                if reaped in worker_pids:
                    worker_pids.remove(reaped)
            except ChildProcessError:
                break

    signal.signal(signal.SIGCHLD, _reap)

    try:
        while worker_pids:
            signal.pause()
    finally:
        _shutdown_children(worker_pids)


_run_workers()
