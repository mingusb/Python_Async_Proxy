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
- small (HTML) (/index.html): wrk 26,892.18 req/s (p50 4.4ms, p99 9.31ms); siege 2,811.33 trans/s, throughput 0.18 MB/sec
- 1KB binary (/payload_1k.bin): wrk 19,708.61 req/s (p50 4.92ms, p99 14.73ms); siege 2,766.61 trans/s, throughput 2.70 MB/sec
- 16KB binary (/payload_16k.bin): wrk 13,926.94 req/s (p50 7.04ms, p99 32.76ms); siege 2,462.75 trans/s, throughput 38.48 MB/sec
- 128KB binary (/payload_128k.bin): wrk 6,359.65 req/s (p50 19.86ms, p99 130.62ms); siege 1,701.38 trans/s, throughput 212.67 MB/sec
- 1024KB binary (/payload_1024k.bin): wrk 770.15 req/s (p50 120.1ms, p99 347.07ms); siege 448.65 trans/s, throughput 448.65 MB/sec
<!-- HTTP_RESULTS_END -->

**HTTPS CONNECT (via proxy to local nginx SSL on :8443)**

<!-- CONNECT_RESULTS_START -->
- CONNECT HTML (/index.html): 632.91 req/s, transfer 0.04 MB/s
- CONNECT 1KB binary (/payload_1k.bin): 670.02 req/s, transfer 0.65 MB/s
- CONNECT 16KB binary (/payload_16k.bin): 632.91 req/s, transfer 9.89 MB/s
- CONNECT 128KB binary (/payload_128k.bin): 534.76 req/s, transfer 66.84 MB/s
- CONNECT 1024KB binary (/payload_1024k.bin): 345.13 req/s, transfer 345.13 MB/s
<!-- CONNECT_RESULTS_END -->
