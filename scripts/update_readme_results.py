import re
import sys
from pathlib import Path


def strip_ansi(s: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", s)


def parse_http_log(path: Path):
    text = strip_ansi(path.read_text(errors="ignore"))
    results = {}
    current = None
    for line in text.splitlines():
        if line.startswith("==="):
            label = line.strip("= ").strip()
            current = label
            results[current] = {}
            continue
        if current is None:
            continue
        if "Requests/sec:" in line and "wrk_rps" not in results[current]:
            try:
                results[current]["wrk_rps"] = float(line.split(":")[1])
            except Exception:
                pass
        if line.strip().startswith("50%"):
            parts = line.strip().split()
            if len(parts) > 1:
                raw = parts[1]
                if raw.endswith("ms"):
                    val = float(raw.replace("ms", ""))
                elif raw.endswith("s"):
                    val = float(raw.replace("s", "")) * 1000
                else:
                    val = float(raw)
                results[current]["p50"] = val
        if line.strip().startswith("99%"):
            parts = line.strip().split()
            if len(parts) > 1:
                raw = parts[1]
                if raw.endswith("ms"):
                    val = float(raw.replace("ms", ""))
                elif raw.endswith("s"):
                    val = float(raw.replace("s", "")) * 1000
                else:
                    val = float(raw)
                results[current]["p99"] = val
        if line.strip().startswith("Transactions:"):
            try:
                results[current]["siege_tx"] = int(line.split(":")[1].split()[0])
            except Exception:
                pass
        if line.strip().startswith("Transaction rate:"):
            try:
                results[current]["siege_rate"] = float(line.split(":")[1].split()[0])
            except Exception:
                pass
        if line.strip().startswith("Throughput:"):
            try:
                results[current]["siege_tp"] = line.split(":")[1].strip()
            except Exception:
                pass
    return results


def parse_connect_log(path: Path):
    text = strip_ansi(path.read_text(errors="ignore"))
    results = {}
    current = None
    for line in text.splitlines():
        if line.startswith("==="):
            label = line.strip("= ").strip()
            current = label
            results[current] = {}
            continue
        if current is None:
            continue
        if "Requests per second:" in line:
            try:
                results[current]["ab_rps"] = float(line.split(":")[1].split()[0])
            except Exception:
                pass
        if "Requests/sec:" in line:
            try:
                results[current]["ab_rps"] = float(line.split(":")[1].strip())
            except Exception:
                pass
        if "Transfer rate:" in line:
            results[current]["ab_tp"] = line.split(":")[1].strip()
        if "Transfer/sec:" in line:
            results[current]["ab_tp"] = line.split(":")[1].strip()
    return results


def replace_block(content: str, marker: str, new_block: str) -> str:
    start = f"<!-- {marker}_START -->"
    end = f"<!-- {marker}_END -->"
    pattern = re.compile(f"{start}.*?{end}", re.DOTALL)
    return pattern.sub(f"{start}\n{new_block}\n{end}", content)


def format_http_block(results):
    lines = []
    for label, data in results.items():
        wrk = data.get("wrk_rps")
        p50 = data.get("p50")
        p99 = data.get("p99")
        siege_rate = data.get("siege_rate")
        siege_tp = data.get("siege_tp")
        if wrk is None:
            continue
        line = (
            f"- {label}: wrk {wrk:,.2f} req/s"
            f" (p50 {p50}ms, p99 {p99}ms);"
            f" siege {siege_rate:,.2f} trans/s, throughput {siege_tp}"
        )
        lines.append(line)
    return "\n".join(lines)


def format_connect_block(results):
    lines = []
    for label, data in results.items():
        if "ab_rps" not in data:
            continue
        lines.append(
            f"- {label}: {data['ab_rps']:,.2f} req/s, transfer {data.get('ab_tp','')}"
        )
    return "\n".join(lines)


def main():
    http_log = Path(sys.argv[1])
    connect_log = Path(sys.argv[2])
    readme_path = Path(sys.argv[3])

    http_results = parse_http_log(http_log)
    connect_results = parse_connect_log(connect_log)

    readme = readme_path.read_text()
    http_block = format_http_block(http_results)
    connect_block = format_connect_block(connect_results)

    readme = replace_block(readme, "HTTP_RESULTS", http_block)
    readme = replace_block(readme, "CONNECT_RESULTS", connect_block)

    readme_path.write_text(readme)


if __name__ == "__main__":
    main()
