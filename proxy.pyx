from urllib.parse import urlparse
import asyncio
import base64
import signal
import json
import time
import sys
from collections import Counter
from libc.stdlib cimport atoi

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

visits = Counter()
cdef unsigned long bw = 0
cdef unsigned long total_requests = 0
cdef unsigned long successful_requests = 0
cdef unsigned long failed_requests = 0

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
    if len(parts) > 2:
        return '.'.join(parts[-2:])
    return host

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

async def proxy(client_r, client_w):
    """Handle proxy connections."""
    global bw, total_requests, successful_requests, failed_requests
    total_requests += 1  # count connections (keep-alive aggregates requests)

    try:
        # Read the initial client request
        data = await asyncio.wait_for(client_r.read(1024), timeout=TIMEOUT)

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
            client_w.write(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n\r\n"
                + json.dumps(metrics_resp).encode()
            )
            await client_w.drain()
            return client_w.close()

        # Validate Proxy-Authorization header (byte match avoids repeated decoding)
        if AUTH_HEADER not in data:
            client_w.write(
                b"HTTP/1.1 407 Proxy Auth Required\r\n"
                b"Proxy-Authenticate: Basic\r\n\r\n"
            )
            return await client_w.drain()

        # Parse the target URL
        met, targ, _ = data.split(b' ')[:3]
        remote_r, remote_w = None, None
        dom = ""

        if met == b'CONNECT':  # Handle HTTPS CONNECT requests
            try:
                host, port = targ.split(b':')
                dom = canon(host.decode())
                remote_r, remote_w = await asyncio.open_connection(host.decode(), int(port))
                client_w.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                await client_w.drain()
            except Exception as error:
                print(f"Error connecting to {host.decode()}:{int(port)}: {error}")
                client_w.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                failed_requests += 1
                return await client_w.drain()
        else:  # Handle HTTP GET/POST requests
            targ_text = targ.decode()
            parsed_url = urlparse(targ_text)
            host = parsed_url.hostname or DEFAULT_BACKEND_HOST
            port = parsed_url.port or DEFAULT_BACKEND_PORT
            path = parsed_url.path or "/"
            dom = canon(host)

            # Reconstruct the full request if the URL is relative
            if targ_text.startswith("/"):
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
                remote_r, remote_w = await asyncio.open_connection(host, port)
                remote_w.write(data)
                await remote_w.drain()
            except Exception as error:
                print(f"Error connecting to {host}:{port}: {error}")
                client_w.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                failed_requests += 1
                return await client_w.drain()

        # Update domain visits (count every request)
        if TRACK_DOMAINS:
            visits.update([dom])

        # Relay data between client and remote server
        async def relay(src_read, dest_write):
            global bw
            flushed = 0
            try:
                while True:
                    chunk = await src_read.read(65536)
                    if not chunk:
                        break
                    bw += len(chunk)
                    dest_write.write(chunk)
                    flushed += 1
                    if flushed & 7 == 0:  # amortize drain calls
                        await dest_write.drain()
                await dest_write.drain()
            except (asyncio.TimeoutError, ConnectionResetError, BrokenPipeError):
                pass
            finally:
                dest_write.close()

        # Start relaying data
        to_client = asyncio.create_task(relay(client_r, remote_w))
        to_remote = asyncio.create_task(relay(remote_r, client_w))
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
        client_w.close()

async def main():
    """Run the proxy server."""
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, print_met)

    server = await asyncio.start_server(
        proxy, HOST, PORT, reuse_port=True, backlog=65535
    )
    async with server:
        print(f"Running on {HOST}:{PORT}")
        await server.serve_forever()

try:
    if uvloop is not None:
        asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
    asyncio.run(main())
except KeyboardInterrupt:
    print_met()
