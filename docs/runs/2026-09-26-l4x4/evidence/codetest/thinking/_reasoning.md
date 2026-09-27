The user wants a small Python project with three files:
1. `logstats.py` - CLI tool for nginx access log analysis
2. `test_logstats.py` - pytest tests
3. `sample.log` - sample log file

Let me think about the nginx combined log format:
```
IP - - [timestamp] "METHOD /path HTTP/1.1" status bytes "referer" "user-agent"
```

Example:
```
127.0.0.1 - - [10/Oct/2023:13:55:36 +0000] "GET / HTTP/1.1" 200 612 "http://example.com" "Mozilla/5.0"
```

For the regex, I need to parse:
- IP address
- ident (usually -)
- user (usually -)
- timestamp in brackets
- request line in quotes
- status code
- bytes (can be - for zero)
- referer in quotes
- user-agent in quotes

For percentiles (p50, p95), I'll use the standard approach: sort the values, then use the nearest-rank method or linear interpolation. I'll use a simple approach - sort and pick the index.

Let me think about the percentile calculation. A common approach:
- Sort the data
- For percentile p, the rank is `p/100 * (n-1)` where n is the number of data points
- Use linear interpolation between the two nearest ranks

Actually, let me use a simpler approach that's easy to test:
- Sort the data
- Index = ceil(p/100 * n) - 1, clamped to [0, n-1]

Or even simpler: use the "nearest rank" method where the index is `ceil(p/100 * n) - 1`.

Let me go with a clean implementation. I'll use the method where:
- Sort values
- rank = p/100 * (n - 1)
- lower = floor(rank), upper = ceil(rank)
- fraction = rank - lower
- result = values[lower] + fraction * (values[upper] - values[lower])

This is the linear interpolation method (same as numpy's default).

Let me write the code:

```python
#!/usr/bin/env python3
"""CLI tool to analyze nginx access logs in combined format."""

import re
import sys
from collections import Counter
from math import ceil, floor

LOG_PATTERN = re.compile(
    r'^(?P<ip>\S+)\s+'          # IP
    r'(?P<ident>\S+)\s+'        # ident
    r'(?P<user>\S+)\s+'         # user
    r'\[(?P<timestamp>[^\]]+)\]\s+'  # timestamp
    r'"(?P<request>[^"]*)"\s+'  # request
    r'(?P<status>\d{3})\s+'     # status
    r'(?P<bytes>\d+|-)\s+'      # bytes
    r'"(?P<referer>[^"]*)"\s+'  # referer
    r'"(?P<user_agent>[^"]*)"\s*$'  # user agent
)


def parse_line(line):
    """Parse a single nginx combined log line. Returns dict or None if malformed."""
    line = line.rstrip('\n')
    m = LOG_PATTERN.match(line)
    if not m:
        return None
    d = m.groupdict()
    d['status'] = int(d['status'])
    d['bytes'] = 0 if d['bytes'] == '-' else int(d['bytes'])
    return d


def percentile(sorted_values, p):
    """Calculate the p-th percentile using linear interpolation."""
    if not sorted_values:
        return 0
    n = len(sorted_values)
    if n == 1:
        return sorted_values[0]
    rank = (p / 100.0) * (n - 1)
    lower = floor(rank)
    upper = ceil(rank)
    if lower == upper:
        return sorted_values[int(rank)]
    fraction = rank - lower
    return sorted_values[lower] + fraction * (sorted_values[upper] - sorted_values[lower])


def analyze(entries):
    """Analyze parsed log entries and return results dict."""
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
    
    print(f"\nResponse Body Size (bytes):")
    print(f"  p50: {results['p50']:.1f}")
    print(f"  p95: {results['p95']:.1f}")


if __name__ == '__main__':
    main()
```

Now for the tests, I need to cover:
- Parsing valid lines
- Malformed lines
- Percentile calculation
- CLI output on a small sample log

For the sample log, I need at least 12 realistic lines including one malformed line.

Let me make sure the sample log has varied IPs, status codes, and byte sizes to make the tests meaningful.

Let me refine the sample log:

```
192.168.1.10 - - [10/Oct/2023:13:55:36 +0000] "GET /index.html HTTP/1.1" 200 612 "http://example.com/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
192.168.1.10 - - [10/Oct/2023:13:55:37 +0000] "GET /style.css HTTP/1.1" 200 1234 "http://example.com/index.html" "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
192.168.1.11 - - [10/Oct/2023:13:55:38 +0000] "GET /script.js HTTP/1.1" 200 4567 "http://example.com/index.html" "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
192.168.1.12 - - [10/Oct/2023:13:55:39 +0000] "POST /api/login HTTP/1.1" 302 0 "-" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
192.168.1.12 - - [10/Oct/2023:13:55:40 +0000] "GET /dashboard HTTP/1.1" 200 8901 "http://example.com/api/login" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
10.0.0.1 - - [10/Oct/2023:13:55:41 +0000] "GET /api/data HTTP/1.1" 200 15234 "-" "curl/7.81.0"
10.0.0.1 - - [10/Oct/2023:13:55:42 +0000] "GET /api/data HTTP/1.1" 404 152 "-" "curl/7.81.0"
10.0.0.1 - - [10/Oct/2023:13:55:43 +0000] "GET /api/data HTTP/1.1" 200 15234 "-" "curl/7.81.0"
192.168.1.10 - - [10/Oct/2023:13:55:44 +0000] "GET /images/logo.png HTTP/1.1" 200 23456 "http://example.com/index.html" "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
192.168.1.13 - - [10/Oct/2023:13:55:45 +0000] "GET / HTTP/1.1" 301 0 "-" "Googlebot/2.1 (+http://www.google.com/bot.html)"
THIS IS A MALFORMED LINE
192.168.1.13 - - [10/Oct/2023:13:55:46 +0000] "GET /index.html HTTP/1.1" 200 612 "http://example.com/" "Googlebot/2.1 (+http://www.google.com/bot.html)"
10.0.0.2 - - [10/Oct/2023:13:55:47 +0000] "GET /favicon.ico HTTP/1.1" 404 0 "-" "Mozilla/5.0 (X11; Linux x86_64)"
192.168.1.11 - - [10/Oct/2023:13:55:48 +0000] "GET /about.html HTTP/1.1" 200 3456 "http://example.com/index.html" "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
```

That's 14 lines, 13 valid + 1 malformed. Good.

Let me count the IPs:
- 192.168.1.10: 3
- 192.168.1.11: 2
- 192.168.1.12: 2
- 10.0.0.1: 3
- 192.168.1.13: 2
- 10.0.0.2: 1

Status codes:
- 200: 9
- 302: 1
- 404: 2
- 301: 1

Bytes: 612, 1234, 4567, 0, 8901, 15234, 152, 15234, 23456, 0, 612, 0, 3456
Sorted: 0, 0, 0, 152, 612, 612, 1234, 3456, 4567, 8901, 15234, 15234, 23456
n = 13

p50: rank = 0.5 * 12 = 6.0, so index 6 → 1234
p95: rank = 0.95 * 12 = 11.4, lower=11, upper=12, fraction=0.4
     = 15234 + 0.4 * (23456 - 15234) = 15234 + 0.4 * 8222 = 15234 + 3288.8 = 18522.8

Let me verify: sorted values are [0, 0, 0, 152, 612, 612, 1234, 3456, 4567, 8901, 15234, 15234, 23456]
Index: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12

p50: rank = 0.5 * (13-1) = 6.0 → values[6] = 1234 ✓
p95: rank = 0.95 * (13-1) = 11.4 → values[11] + 0.4*(values[12]-values[11]) = 15234 + 0.4*(23456-15234) = 15234 + 3288.8 = 18522.8 ✓

Now let me write the tests. I'll use subprocess to test the CLI, and direct function calls for unit tests.

Let me finalize everything and make sure it's clean and correct.
