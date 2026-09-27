

### FILE: logstats.py

```python
#!/usr/bin/env python3
"""CLI tool to analyze nginx access logs in the combined format."""

import re
import sys
from collections import Counter
from math import ceil, floor

LOG_PATTERN = re.compile(
    r'^(?P<ip>\S+)\s+'
    r'(?P<ident>\S+)\s+'
    r'(?P<user>\S+)\s+'
    r'\[(?P<timestamp>[^\]]+)\]\s+'
    r'"(?P<request>[^"]*)"\s+'
    r'(?P<status>\d{3})\s+'
    r'(?P<bytes>\d+|-)\s+'
    r'"(?P<referer>[^"]*)"\s+'
    r'"(?P<user_agent>[^"]*)"\s*$'
)


def parse_line(line):
    """Parse a single nginx combined log line.

    Returns a dict with keys: ip, ident, user, timestamp, request,
    status (int), bytes (int), referer, user_agent.
    Returns None if the line is malformed.
    """
    line = line.rstrip('\n')
    m = LOG_PATTERN.match(line)
    if not m:
        return None
    d = m.groupdict()
    d['status'] = int(d['status'])
    d['bytes'] = 0 if d['bytes'] == '-' else int(d['bytes'])
    return d


def percentile(sorted_values, p):
    """Calculate the p-th percentile using linear interpolation.

    sorted_values must be a non-empty list of numbers in ascending order.
    p is a float in [0, 100].
    """
    if not sorted_values:
        return 0
    n = len(sorted_values)
    if n == 1:
        return float(sorted_values[0])
    rank = (p / 100.0) * (n - 1)
    lower = floor(rank)
    upper = ceil(rank)
    if lower == upper:
        return float(sorted_values[int(rank)])
    fraction = rank - lower
    return sorted_values[lower] + fraction * (sorted_values[upper] - sorted_values[lower])


def analyze(entries):
    """Analyze a list of parsed log entry dicts.

    Returns a dict with keys: top_ips, status_counts, p50, p95.
    """
    ip_counts = Counter(e['ip'] for e in entries)
    status_counts = Counter(e['status'] for e in entries)
    sizes = sorted(e['bytes'] for e in entries)

    return {
        'top_ips': ip_counts.most_common(10),
        'status_counts': status_counts,
        'p50': percentile(sizes, 50),
        'p95': percentile(sizes, 95),
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: logstats.py <logfile>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    entries = []
    with open(path, 'r') as f:
        for line in f:
            entry = parse_line(line)
            if entry is not None:
                entries.append(entry)

    if not entries:
        print("No valid log entries found.")
        return

    results = analyze(entries)

    print("Top 10 Client IPs by Request Count:")
    for ip, count in results['top_ips']:
        print(f"  {ip}: {count}")

    print("\nHTTP Status Code Counts:")
    for status in sorted(results['status_counts']):
        print(f"  {status}: {results['status_counts'][status]}")

    print("\nResponse Body Size (bytes):")
    print(f"  p50: {results['p50']:.1f}")
    print(f"  p95: {results['p95']:.1f}")


if __name__ == '__main__':
    main()
```

### FILE: test_logstats.py

```python
"""Tests for logstats.py."""

import os
import subprocess
import sys
import tempfile

import pytest

from logstats import parse_line, percentile, analyze


# --- Parsing tests ---

class TestParseLine:
    def test_valid_line(self):
        line = '192.168.1.1 - - [10/Oct/2023:13:55:36 +0000] "GET / HTTP/1.1" 200 612 "-" "Mozilla/5.0"'
        result = parse_line(line)
        assert result is not None
        assert result['ip'] == '192.168.1.1'
        assert result['status'] == 200
        assert result['bytes'] == 612
        assert result['request'] == 'GET / HTTP/1.1'

    def test_valid_line_with_referer(self):
        line = '10.0.0.1 - - [10/Oct/2023:13:55:36 +0000] "GET /page HTTP/1.1" 200 100 "http://ref.com" "curl/7.81.0"'
        result = parse_line(line)
        assert result is not None
        assert result['referer'] == 'http://ref.com'
        assert result['user_agent'] == 'curl/7.81.0'

    def test_bytes_dash_means_zero(self):
        line = '10.0.0.1 - - [10/Oct/2023:13:55:36 +0000] "GET / HTTP/1.1" 301 - "-" "agent"'
        result = parse_line(line)
        assert result is not None
        assert result['bytes'] == 0

    def test_malformed_no_match(self):
        assert parse_line("THIS IS A MALFORMED LINE") is None

    def test_malformed_missing_fields(self):
        assert parse_line('192.168.1.1 - - [10/Oct/2023:13:55:36 +0000] "GET / HTTP/1.1" 200') is None

    def test_malformed_bad_status(self):
        line = '192.168.1.1 - - [10/Oct/2023:13:55:36 +0000] "GET / HTTP/1.1" abc 612 "-" "agent"'
        assert parse_line(line) is None

    def test_empty_line(self):
        assert parse_line("") is None

    def test_trailing_newline_stripped(self):
        line = '192.168.1.1 - - [10/Oct/2023:13:55:36 +0000] "GET / HTTP/1.1" 200 612 "-" "agent"\n'
        result = parse_line(line)
        assert result is not None
        assert result['ip'] == '192.168.1.1'


# --- Percentile tests ---

class TestPercentile:
    def test_single_value(self):
        assert percentile([42], 50) == 42.0
        assert percentile([42], 95) == 42.0

    def test_p50_even_count(self):
        # [1, 2, 3, 4] -> rank = 0.5*3 = 1.5 -> 2 + 0.5*(3-2) = 2.5
        assert percentile([1, 2, 3, 4], 50) == 2.5

    def test_p50_odd_count(self):
        # [1, 2, 3] -> rank = 0.5*2 = 1.0 -> values[1] = 2
        assert percentile([1, 2, 3], 50) == 2.0

    def test_p95(self):
        # [1, 2, 3, 4, 5] -> rank = 0.95*4 = 3.8 -> 4 + 0.8*(5-4) = 4.8
        assert percentile([1, 2, 3, 4, 5], 95) == 4.8

    def test_p0(self):
        assert percentile([10, 20, 30], 0) == 10.0

    def test_p100(self):
        assert percentile([10, 20, 30], 100) == 30.0

    def test_empty_list(self):
        assert percentile([], 50) == 0


# --- Analyze tests ---

class TestAnalyze:
    def test_basic(self):
        entries = [
            {'ip': '1.1.1.1', 'status': 200, 'bytes': 100},
            {'ip': '1.1.1.1', 'status': 404, 'bytes': 200},
            {'ip': '2.2.2.2', 'status': 200, 'bytes': 300},
        ]
        result = analyze(entries)
        assert result['top_ips'][0] == ('1.1.1.1', 2)
        assert result['status_counts'][200] == 2
        assert result['status_counts'][404] == 1
        assert result['p50'] == 200.0

    def test_top_ips_limited_to_10(self):
        entries = [{'ip': f'10.0.0.{i}', 'status': 200, 'bytes': 1} for i in range(15)]
        result = analyze(entries)
        assert len(result['top_ips']) == 10


# --- CLI integration tests ---

class TestCLI:
    def test_cli_output(self):
        sample = os.path.join(os.path.dirname(__file__), 'sample.log')
        result = subprocess.run(
            [sys.executable, os.path.join(os.path.dirname(__file__), 'logstats.py'), sample],
            capture_output=True, text=True
        )
        assert result.returncode == 0
        assert "Top 10 Client IPs by Request Count:" in result.stdout
        assert "HTTP Status Code Counts:" in result.stdout
        assert "p50:" in result.stdout
        assert "p95:" in result.stdout

    def test_cli_counts_correct(self):
        sample = os.path.join(os.path.dirname(__file__), 'sample.log')
        result = subprocess.run(
            [sys.executable, os.path.join(os.path.dirname(__file__), 'logstats.py'), sample],
            capture_output=True, text=True
        )
        # 192.168.1.10 appears 3 times in sample.log
        assert "192.168.1.10: 3" in result.stdout
        # 10.0.0.1 appears 3 times
        assert "10.0.0.1: 3" in result.stdout
        # Status 200 appears 9 times
        assert "200: 9" in result.stdout
        # Status 404 appears 2 times
        assert "404: 2" in result.stdout

    def test_cli_percentiles(self):
        sample = os.path.join(os.path.dirname(__file__), 'sample.log')
        result = subprocess.run(
            [sys.executable, os.path.join(os.path.dirname(__file__), 'logstats.py'), sample],
            capture_output=True, text=True
        )
        # 13 valid entries, sorted bytes: [0,0,0,152,612