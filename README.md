This is an HTTP/HTTPS CONNECT proxy written in async Python, which has been Cythonized.

## System Tuning

In order to run the benchmark on Linux you may need to increase the number of allowed file handles. There are a variety of other ways to tune the system as well.

## Benchmark Environment

For benchmarking purposes a tuned local Apache webserver was used as the backend. It served the small index.html included in this repo from `/var/www/html/`.

## Installation

- The Python distribution used was Miniforge. https://github.com/conda-forge/miniforge

- After installing Miniforge, run `mamba install cython uvloop` (or `pip install cython uvloop`).

- If building Python from source run `pip3 install cython setuptools`.

- If building Python from source there are compiler flags available such as `--enable-optimizations --enable-experimental-jit` which improve performance.

- To build `proxy.pyx` run `CFLAGS='-O3 -march=native' python setup.py build_ext --inplace --force`.

- On Ubuntu, run `sudo apt update` followed by `sudo apt -y install curl wrk siege`.

## Running the Benchmark

To run the benchmark:

- Make sure Nginx (or Apache) is serving `index.html` at `/var/www/html/`. The simplest way on Ubuntu is:
  - `sudo cp index.html /var/www/html/index.html`
  - `sudo systemctl start nginx`
- The benchmark script generates payload files under `/var/www/html/` (1KB, 16KB, 128KB, 1MB) using `sudo dd`. Be ready to enter sudo for that step.
- Run `bash bench.sh` (it starts the proxy for you, runs wrk and siege for each payload with default 8s duration and 100 concurrency). Override with `DURATION=5` or `CONC=200` if you want different settings.
- To fan out across CPU cores, set `WORKERS=<n>` (SO_REUSEPORT forked workers). The bench matrix (`make bench-all`) will also try `WORKERS_BENCH` (default 4) alongside other modes and pick the fastest run.
- To offload the relay hot path into C (poll + splice fallback), set `USE_C_RELAY=1` (built via `make build`). This is optional; the fastest mode is chosen automatically by `make bench-all`.
- `USE_C_RELAY` can also set `CRELAY_THREADS=<n>` to grow the thread pool used to run C relays in parallel.

### Verifying that traffic is flowing

If you want to confirm the proxy is actually transferring data, compare the backend access log before and after a short wrk run:

```
sudo wc -l /var/log/nginx/access.log
wrk -t1 -c50 -d2 --latency -H "Proxy-Authorization: Basic $(echo -n 'username:password' | base64)" http://127.0.0.1:8888/index.html
sudo wc -l /var/log/nginx/access.log
sudo tail -n 5 /var/log/nginx/access.log   # should show 200 responses for /index.html
```

## Results

The output includes `wrk` and `siege`. On this machine with the steps above (uvloop + `-O3 -march=native` build) at 100 concurrency and 5s per payload (set via `DURATION=5`), the proxy returns HTTP 200s and the backend access log increments accordingly.

<!-- HTTP_RESULTS_START -->
- small (HTML) (/index.html): wrk 10,876.48 req/s (p50 8.86ms, p99 41.3ms); siege 1,669.60 trans/s, throughput 0.11 MB/sec
- 1KB binary (/payload_1k.bin): wrk 9,943.98 req/s (p50 9.56ms, p99 94.15ms); siege 1,594.80 trans/s, throughput 1.56 MB/sec
- 16KB binary (/payload_16k.bin): wrk 6,255.64 req/s (p50 15.45ms, p99 62.21ms); siege 984.76 trans/s, throughput 15.39 MB/sec
- 128KB binary (/payload_128k.bin): wrk 2,488.53 req/s (p50 37.19ms, p99 495.4ms); siege 829.66 trans/s, throughput 103.71 MB/sec
- 1024KB binary (/payload_1024k.bin): wrk 459.31 req/s (p50 211.49ms, p99 895.45ms); siege 264.13 trans/s, throughput 264.13 MB/sec
<!-- HTTP_RESULTS_END -->

**HTTPS CONNECT (via proxy to local nginx SSL on :8443)**

<!-- CONNECT_RESULTS_START -->
- CONNECT HTML (/index.html): 268.64 req/s, transfer 0.02 MB/s
- CONNECT 1KB binary (/payload_1k.bin): 277.97 req/s, transfer 0.27 MB/s
- CONNECT 16KB binary (/payload_16k.bin): 308.88 req/s, transfer 4.83 MB/s
- CONNECT 128KB binary (/payload_128k.bin): 280.31 req/s, transfer 35.04 MB/s
- CONNECT 1024KB binary (/payload_1024k.bin): 168.42 req/s, transfer 168.42 MB/s
<!-- CONNECT_RESULTS_END -->
