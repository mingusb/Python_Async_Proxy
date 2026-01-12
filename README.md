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
- small (HTML) (/index.html): wrk 20,066.98 req/s (p50 4.87ms, p99 8.42ms); siege 2,660.49 trans/s, throughput 0.17 MB/sec
- 1KB binary (/payload_1k.bin): wrk 19,540.95 req/s (p50 4.98ms, p99 9.25ms); siege 2,703.91 trans/s, throughput 2.64 MB/sec
- 16KB binary (/payload_16k.bin): wrk 19,189.11 req/s (p50 8.0ms, p99 24.96ms); siege 2,347.06 trans/s, throughput 36.67 MB/sec
- 128KB binary (/payload_128k.bin): wrk 4,756.92 req/s (p50 20.46ms, p99 30.54ms); siege 1,606.38 trans/s, throughput 200.80 MB/sec
- 1024KB binary (/payload_1024k.bin): wrk 1,278.31 req/s (p50 120.02ms, p99 438.02ms); siege 569.55 trans/s, throughput 569.55 MB/sec
<!-- HTTP_RESULTS_END -->

**HTTPS CONNECT (via proxy to local nginx SSL on :8443)**

<!-- CONNECT_RESULTS_START -->
- CONNECT HTML (/index.html): 565.77 req/s, transfer 0.04 MB/s
- CONNECT 1KB binary (/payload_1k.bin): 453.51 req/s, transfer 0.44 MB/s
- CONNECT 16KB binary (/payload_16k.bin): 441.01 req/s, transfer 6.89 MB/s
- CONNECT 128KB binary (/payload_128k.bin): 381.68 req/s, transfer 47.71 MB/s
- CONNECT 1024KB binary (/payload_1024k.bin): 254.78 req/s, transfer 254.78 MB/s
<!-- CONNECT_RESULTS_END -->
