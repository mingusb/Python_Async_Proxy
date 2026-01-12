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
- small (HTML) (/index.html): wrk 19,989.70 req/s (p50 4.86ms, p99 9.01ms); siege 2,673.59 trans/s, throughput 0.17 MB/sec
- 1KB binary (/payload_1k.bin): wrk 19,473.57 req/s (p50 4.99ms, p99 10.0ms); siege 2,675.69 trans/s, throughput 2.61 MB/sec
- 16KB binary (/payload_16k.bin): wrk 12,653.75 req/s (p50 7.72ms, p99 16.82ms); siege 2,361.79 trans/s, throughput 36.90 MB/sec
- 128KB binary (/payload_128k.bin): wrk 4,755.79 req/s (p50 20.44ms, p99 117.51ms); siege 1,658.50 trans/s, throughput 207.31 MB/sec
- 1024KB binary (/payload_1024k.bin): wrk 795.88 req/s (p50 122.43ms, p99 371.94ms); siege 576.04 trans/s, throughput 576.04 MB/sec
<!-- HTTP_RESULTS_END -->

**HTTPS CONNECT (via proxy to local nginx SSL on :8443)**

<!-- CONNECT_RESULTS_START -->
- CONNECT HTML (/index.html): 651.47 req/s, transfer 0.04 MB/s
- CONNECT 1KB binary (/payload_1k.bin): 656.81 req/s, transfer 0.64 MB/s
- CONNECT 16KB binary (/payload_16k.bin): 616.33 req/s, transfer 9.63 MB/s
- CONNECT 128KB binary (/payload_128k.bin): 543.48 req/s, transfer 67.93 MB/s
- CONNECT 1024KB binary (/payload_1024k.bin): 341.01 req/s, transfer 341.01 MB/s
<!-- CONNECT_RESULTS_END -->
