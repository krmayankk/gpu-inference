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
