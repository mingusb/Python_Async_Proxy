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
- If you want each worker pinned to a CPU (for lower cache thrash), set `PIN_WORKERS=1` alongside `WORKERS>1`.
- For a high-concurrency sweep (including C10K), run `make bench-c10k`. Tweak `CONC_LIST="1000 5000 10000 15000"` and `PROXY_ENV="WORKERS=4 PIN_WORKERS=1"` as needed; the script always reports the 10K-concurrency result and the peak observed.
- For tougher C10K loads, you can also set `WRK_THREADS=<n>` and `SYSCTL_TUNE=1` (enables higher backlog sysctls) when running `make bench-c10k`.

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
- small (HTML) (/index.html): wrk 28,216.40 req/s (p50 3.24ms, p99 10.45ms); siege 4,061.90 trans/s, throughput 0.26 MB/sec
- 1KB binary (/payload_1k.bin): wrk 25,993.51 req/s (p50 3.46ms, p99 10.76ms); siege 4,120.40 trans/s, throughput 4.02 MB/sec
- 16KB binary (/payload_16k.bin): wrk 17,002.71 req/s (p50 5.09ms, p99 15.28ms); siege 3,381.71 trans/s, throughput 52.84 MB/sec
- 128KB binary (/payload_128k.bin): wrk 6,739.34 req/s (p50 11.49ms, p99 31.57ms); siege 1,875.13 trans/s, throughput 234.39 MB/sec
- 1024KB binary (/payload_1024k.bin): wrk 983.22 req/s (p50 78.61ms, p99 176.76ms); siege 415.80 trans/s, throughput 415.80 MB/sec
<!-- HTTP_RESULTS_END -->

**HTTPS CONNECT (via proxy to local nginx SSL on :8443)**

<!-- CONNECT_RESULTS_START -->
- CONNECT HTML (/index.html): 611.62 req/s, transfer 0.04 MB/s
- CONNECT 1KB binary (/payload_1k.bin): 416.67 req/s, transfer 0.41 MB/s
- CONNECT 16KB binary (/payload_16k.bin): 341.30 req/s, transfer 5.33 MB/s
- CONNECT 128KB binary (/payload_128k.bin): 374.53 req/s, transfer 46.82 MB/s
- CONNECT 1024KB binary (/payload_1024k.bin): 281.49 req/s, transfer 281.49 MB/s
<!-- CONNECT_RESULTS_END -->

**C10K sweep (wrk only)**

<!-- C10K_RESULTS_START -->
- best: wrk 1,743.01 req/s at C=1000
- C=10000: wrk 898.55
- sweep:
  - C=1000: wrk 1,743.01 req/s
  - C=5000: wrk 1,408.40 req/s
  - C=10000: wrk 898.55 req/s
  - C=15000: wrk 523.61 req/s
<!-- C10K_RESULTS_END -->
