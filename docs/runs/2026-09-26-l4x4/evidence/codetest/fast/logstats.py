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
