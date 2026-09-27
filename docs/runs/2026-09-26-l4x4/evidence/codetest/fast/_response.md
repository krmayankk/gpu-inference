### FILE: logstats.py
```python
import sys
import re
from collections import Counter

# Regex for nginx combined log format
# Example: 127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] "GET /apache_pb.gif HTTP/1.0" 200 2326 "http://www.example.com/start.html" "Mozilla/4.08 [en] (Win98; I ;Nav)"
LOG_PATTERN = re.compile(
    r'^(?P<ip>\S+) '
    r'(?P<ident>\S+) '
    r'(?P<user>\S+) '
    r'\[(?P<time>[^\]]+)\] '
    r'"(?P<request>[^"]*)" '
    r'(?P<status>\d{3}) '
    r'(?P<size>\d+|-) '
    r'"(?P<referer>[^"]*)" '
    r'"(?P<user_agent>[^"]*)"'
)

def parse_line(line):
    """
    Parses a single line of nginx combined log format.
    Returns a dict with 'ip', 'status', 'size' or None if malformed.
    """
    match = LOG_PATTERN.match(line)
    if not match:
        return None
    
    data = match.groupdict()
    
    # Validate status code
    try:
        status = int(data['status'])
    except ValueError:
        return None
        
    # Validate size
    size_str = data['size']
    if size_str == '-':
        size = 0
    else:
        try:
            size = int(size_str)
        except ValueError:
            return None
            
    return {
        'ip': data['ip'],
        'status': status,
        'size': size
    }

def calculate_percentile(sorted_data, percentile):
    """
    Calculates the percentile of a sorted list of numbers.
    Uses the 'nearest rank' method or linear interpolation.
    For simplicity and common usage in small datasets, we'll use linear interpolation
    similar to numpy's default 'linear' method.
    """
    if not sorted_data:
        return 0
    
    n = len(sorted_data)
    if n == 1:
        return sorted_data[0]
        
    # Calculate rank
    rank = (percentile / 100.0) * (n - 1)
    lower_rank = int(rank)
    upper_rank = lower_rank + 1
    
    if upper_rank >= n:
        return sorted_data[-1]
        
    weight = rank - lower_rank
    return sorted_data[lower_rank] * (1 - weight) + sorted_data[upper_rank] * weight

def analyze_log(filepath):
    """
    Reads the log file and computes statistics.
    Returns a dictionary with results.
    """
    ip_counts = Counter()
    status_counts = Counter()
    sizes = []
    
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parsed = parse_line(line)
                if parsed:
                    ip_counts[parsed['ip']] += 1
                    status_counts[parsed['status']] += 1
                    sizes.append(parsed['size'])
    except FileNotFoundError:
        print(f"Error: File {filepath} not found.", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error reading file: {e}", file=sys.stderr)
        sys.exit(1)
        
    # Sort sizes for percentile calculation
    sizes.sort()
    
    p50 = calculate_percentile(sizes, 50)
    p95 = calculate_percentile(sizes, 95)
    
    return {
        'top_ips': ip_counts.most_common(10),
        'status_counts': status_counts,
        'p50': p50,
        'p95': p95
    }

def main():
    if len(sys.argv) != 2:
        print("Usage: python logstats.py <logfile>", file=sys.stderr)
        sys.exit(1)
        
    filepath = sys.argv[1]
    results = analyze_log(filepath)
    
    print("Top 10 Client IPs by Request Count:")
    if results['top_ips']:
        for ip, count in results['top_ips']:
            print(f"  {ip}: {count}")
    else:
        print("  (none)")
        
    print("\nCounts per HTTP Status Code:")
    if results['status_counts']:
        # Sort by status code for consistent output
        for status in sorted(results['status_counts'].keys()):
            print(f"  {status}: {results['status_counts'][status]}")
    else:
        print("  (none)")
        
    print("\nResponse Body Size Percentiles (bytes):")
    print(f"  p50: {results['p50']:.2f}")
    print(f"  p95: {results['p95']:.2f}")

if __name__ == "__main__":
    main()
```

### FILE: test_logstats.py
```python
import pytest
import os
import tempfile
import logstats

def test_parse_line_valid():
    line = '127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] "GET /apache_pb.gif HTTP/1.0" 200 2326 "http://www.example.com/start.html" "Mozilla/4.08 [en] (Win98; I ;Nav)"'
    result = logstats.parse_line(line)
    assert result is not None
    assert result['ip'] == '127.0.0.1'
    assert result['status'] == 200
    assert result['size'] == 2326

def test_parse_line_malformed():
    line = 'this is not a valid log line'
    result = logstats.parse_line(line)
    assert result is None

def test_parse_line_missing_size():
    line = '127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] "GET / HTTP/1.0" 200 - "-" "Mozilla/4.08"'
    result = logstats.parse_line(line)
    assert result is not None
    assert result['size'] == 0

def test_calculate_percentile_empty():
    assert logstats.calculate_percentile([], 50) == 0

def test_calculate_percentile_single():
    assert logstats.calculate_percentile([100], 50) == 100
    assert logstats.calculate_percentile([100], 95) == 100

def test_calculate_percentile_multiple():
    data = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    # p50 of 1-10 is 5.5
    assert logstats.calculate_percentile(data, 50) == 5.5
    # p95 of 1-10: rank = 0.95 * 9 = 8.55. 
    # lower=8 (val 9), upper=9 (val 10). 
    # 9 * (1-0.55) + 10 * 0.55 = 9*0.45 + 5.5 = 4.05 + 5.5 = 9.55
    assert logstats.calculate_percentile(data, 95) == 9.55

def test_analyze_log_sample():
    # Create a temporary log file
    log_content = """127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] "GET / HTTP/1.0" 200 1000 "-" "Mozilla/4.08"
127.0.0.1 - - [10/Oct/2000:13:55:37 -0700] "GET /about HTTP/1.0" 200 2000 "-" "Mozilla/4.08"
192.168.1.1 - - [10/Oct/2000:13:55:38 -0700] "GET /contact HTTP/1.0" 404 500 "-" "Mozilla/4.08"
malformed line here
192.168.1.1 - - [10/Oct/2000:13:55:39 -0700] "GET / HTTP/1.0" 200 1500 "-" "Mozilla/4.08"
"""
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.log') as f:
        f.write(log_content)
        temp_path = f.name
        
    try:
        results = logstats.analyze_log(temp_path)
        
        # Check IP counts
        ip_dict = dict(results['top_ips'])
        assert ip_dict.get('127.0.0.1') == 2
        assert ip_dict.get('192.168.1.1') == 2
        
        # Check status counts
        assert results['status_counts'][200] == 3
        assert results['status_counts'][404] == 1
        
        # Check percentiles
        # Sizes: 1000, 2000, 500, 1500 -> sorted: 500, 1000, 1500, 2000
        # p50: rank = 0.5 * 3 = 1.5. lower=1 (1000), upper=2 (1500). 1000*0.5 + 1500*0.5 = 1250
        assert results['p50'] == 1250.0
        # p95: rank = 0.95 * 3 = 2.85. lower=2 (1500), upper=3 (2000). 1500*0.15 + 2000*0.85 = 225 + 1700 = 1925
        assert results['p95'] == 1925.0
        
    finally:
        os.unlink(temp_path)

def test_cli_output(capsys):
    log_content = """127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] "GET / HTTP/1.0" 200 1000 "-" "Mozilla/4.08"
127.0.0.1 - - [10/Oct/2000:13:55:37 -0700] "GET /about HTTP/1.0" 200 2000 "-" "Mozilla/4.08"
"""
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.log') as f:
        f.write(log_content)
        temp_path = f.name
        
    try:
        # Simulate CLI call
        sys_argv_backup = sys.argv
        sys.argv = ['logstats.py', temp_path]
        
        # We need to import sys to modify argv
        import sys
        logstats.main()
        
        captured = capsys.readouterr()
        assert "Top 10 Client IPs by Request Count:" in captured.out
        assert "127.0.0.1: 2" in captured.out
        assert "Counts per HTTP Status Code:" in captured.out
        assert "200: 2" in captured.out
        assert "p50: 1500.00" in captured.out
        assert "p95: 1950.00" in captured.out
        
    finally:
        os.unlink(temp_path)
        sys.argv = sys_argv_backup
```

### FILE: sample.log
```
192.168.1.10 - - [10/Oct/2023:13:55:36 -0700] "GET /index.html HTTP/1.1" 200 5120 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
192.168.1.10 - - [10/Oct/2023:13:55:37 -0700] "GET /style.css HTTP/1.1" 200 1024 "http://example.com/index.html" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
10.0.0.5 - - [10/Oct/2023:13:55:38 -0700] "POST /api/login HTTP/1.1" 302 0 "http://example.com/login" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
10.0.0.5 - - [10/Oct/2023:13:55:39 -0700] "GET /dashboard HTTP/1.1" 200 8192 "-" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
192.168.1.10 - - [10/Oct/2023:13:55:40 -0700] "GET /images/logo.png HTTP/1.1" 200 2048 "http://example.com/index.html" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
172.16.0.1 - - [10/Oct/2023:13:55:41 -0700] "GET /nonexistent HTTP/1.1" 404 128 "-" "curl/7.68.0"
192.168.1.10 - - [10/Oct/2023:13:55:42 -0700] "GET /script.js HTTP/1.1" 200 4096 "http://example.com/index.html" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
10.0.0.5 - - [10/Oct/2023:13:55:43 -0700] "GET /api/data HTTP/1.1" 200 16384 "-" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
MALFORMED LINE THAT SHOULD BE SKIPPED
172.16.0.1 - - [10/Oct/2023:13:55:44 -0700] "GET /robots.txt HTTP/1.1" 200 64 "-" "Googlebot/2.1 (+http://www.google.com/bot.html)"
192.168.1.10 - - [10/Oct/2023:13:55:45 -0700] "GET /favicon.ico HTTP/1.1" 404 0 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
10.0.0.5 - - [10/Oct/2023:13:55:46 -0700] "POST /api/logout HTTP/1.1" 200 0 "-" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
192.168.1.10 - - [10/Oct/2023:13:55:47 -0700] "GET /about.html HTTP/1.1" 200 3072 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
172.16.0.1 - - [10/Oct/2023:13:55:48 -0700] "GET /sitemap.xml HTTP/1.1" 200 512 "-" "Googlebot/2.1 (+http://www.google.com/bot.html)"
```