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

### Verifying that traffic is flowing

If you want to confirm the proxy is actually transferring data, compare the backend access log before and after a short wrk run:

```
sudo wc -l /var/log/nginx/access.log
wrk -t1 -c50 -d2 --latency -H "Proxy-Authorization: Basic $(echo -n 'username:password' | base64)" http://127.0.0.1:8888/index.html
sudo wc -l /var/log/nginx/access.log
sudo tail -n 5 /var/log/nginx/access.log   # should show 200 responses for /index.html
```

## Results

The output includes `wrk` and `siege`. On this machine with the steps above (uvloop + `-O3 -march=native` build) at 100 concurrency and ~8s per payload, the proxy returns HTTP 200s and the backend access log increments accordingly.

<!-- HTTP_RESULTS_START -->
- small (HTML) (/index.html): wrk 15,883.17 req/s (p50 5.73ms, p99 13.49ms); siege 1,994.61 trans/s, throughput 0.13 MB/sec
- 1KB binary (/payload_1k.bin): wrk 15,647.90 req/s (p50 5.85ms, p99 15.59ms); siege 1,975.25 trans/s, throughput 1.93 MB/sec
- 16KB binary (/payload_16k.bin): wrk 8,333.30 req/s (p50 11.19ms, p99 25.15ms); siege 1,666.37 trans/s, throughput 26.04 MB/sec
- 128KB binary (/payload_128k.bin): wrk 4,124.00 req/s (p50 35.84ms, p99 199.54ms); siege 995.34 trans/s, throughput 124.42 MB/sec
- 1024KB binary (/payload_1024k.bin): wrk 413.85 req/s (p50 235.05ms, p99 1130.0ms); siege 323.54 trans/s, throughput 323.54 MB/sec
<!-- HTTP_RESULTS_END -->

**HTTPS CONNECT (via proxy to local nginx SSL on :8443)**

<!-- CONNECT_RESULTS_START -->
- CONNECT HTML (/index.html): 312.74 req/s, transfer 0.02 MB/s
- CONNECT 1KB binary (/payload_1k.bin): 289.86 req/s, transfer 0.28 MB/s
- CONNECT 16KB binary (/payload_16k.bin): 284.70 req/s, transfer 4.45 MB/s
- CONNECT 128KB binary (/payload_128k.bin): 252.05 req/s, transfer 31.51 MB/s
- CONNECT 1024KB binary (/payload_1024k.bin): 163.93 req/s, transfer 163.93 MB/s
<!-- CONNECT_RESULTS_END -->
