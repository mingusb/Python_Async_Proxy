bench: build http-bench connect-bench update-readme

http-bench:
	@bash bench.sh > bench.log 2>&1

connect-bench:
	@bash bench_connect.sh > bench_connect.log 2>&1

update-readme:
	@python scripts/update_readme_results.py bench.log bench_connect.log README.md

smoke:
	@bash bench_smoke.sh

build:
	@python setup.py build_ext --inplace
