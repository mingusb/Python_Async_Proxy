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
- Start the proxy with `python -c "import proxy"`. If `uvloop` is installed it will be used automatically.
- Run `bash bench.sh` (wrk 30s and siege 30s).

### Verifying that traffic is flowing

If you want to confirm the proxy is actually transferring data, compare the backend access log before and after a short wrk run:

```
sudo wc -l /var/log/nginx/access.log
wrk -t1 -c50 -d2 --latency -H "Proxy-Authorization: Basic $(echo -n 'username:password' | base64)" http://127.0.0.1:8888/index.html
sudo wc -l /var/log/nginx/access.log
sudo tail -n 5 /var/log/nginx/access.log   # should show 200 responses for /index.html
```

## Results

The output will include the results of `wrk` and `siege`. On this machine with the steps above (uvloop + `-O3 -march=native` build), the proxy returns HTTP 200s for `/index.html` and the backend access log increments by the request counts below.

**wrk**

```
Running 30s test @ http://127.0.0.1:8888/index.html
  1 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     7.67ms    5.53ms 167.16ms   93.31%
    Req/Sec    13.68k     2.91k   18.04k    74.33%
  Latency Distribution
     50%    6.46ms
     75%    8.47ms
     90%   11.58ms
     99%   26.31ms
  409856 requests in 27.30s, 123.51MB read
  Socket errors: timeout 100
Requests/sec:  15013.18
Transfer/sec:      4.52MB
```

**siege**

```
	"transactions":			      62507,
	"availability":			      100.00,
	"elapsed_time":			       33.04,
	"data_transferred":		        3.93,
	"response_time":		        0.05,
	"transaction_rate":		     1891.86,
	"throughput":			        0.12,
	"concurrency":			       99.67,
	"successful_transactions":	       62508,
	"failed_transactions":		           0,
	"longest_transaction":		        0.13,
	"shortest_transaction":		        0.00
```
