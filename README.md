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
- small (HTML) (/index.html): wrk 20,029.69 req/s (p50 4.83ms, p99 9.29ms); siege 2,678.95 trans/s, throughput 0.17 MB/sec
- 1KB binary (/payload_1k.bin): wrk 28,392.10 req/s (p50 5.26ms, p99 22.56ms); siege 2,663.13 trans/s, throughput 2.60 MB/sec
- 16KB binary (/payload_16k.bin): wrk 12,528.65 req/s (p50 7.85ms, p99 15.65ms); siege 2,351.79 trans/s, throughput 36.75 MB/sec
- 128KB binary (/payload_128k.bin): wrk 7,701.01 req/s (p50 19.83ms, p99 65.82ms); siege 1,673.67 trans/s, throughput 209.21 MB/sec
- 1024KB binary (/payload_1024k.bin): wrk 799.45 req/s (p50 123.07ms, p99 382.9ms); siege 580.56 trans/s, throughput 580.56 MB/sec
<!-- HTTP_RESULTS_END -->

**HTTPS CONNECT (via proxy to local nginx SSL on :8443)**

<!-- CONNECT_RESULTS_START -->
- CONNECT HTML (/index.html): 606.98 req/s, transfer 0.04 MB/s
- CONNECT 1KB binary (/payload_1k.bin): 627.94 req/s, transfer 0.61 MB/s
- CONNECT 16KB binary (/payload_16k.bin): 606.98 req/s, transfer 9.48 MB/s
- CONNECT 128KB binary (/payload_128k.bin): 530.50 req/s, transfer 66.31 MB/s
- CONNECT 1024KB binary (/payload_1024k.bin): 331.95 req/s, transfer 331.95 MB/s
<!-- CONNECT_RESULTS_END -->
