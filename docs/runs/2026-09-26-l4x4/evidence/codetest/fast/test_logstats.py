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
