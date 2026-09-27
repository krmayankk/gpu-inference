"""Send one coding task to the self-hosted model, write the files it returns,
and report timing. Usage: run.py <variant: fast|thinking> <outdir>"""
import json, os, re, sys, time, urllib.request

variant, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)

TASK = """Create a small, working Python project.

1. `logstats.py`: a CLI that reads an nginx access log in the default "combined"
   format (path given as the first argument) and prints:
   - the top 10 client IPs by request count,
   - counts per HTTP status code,
   - p50 and p95 of the response body size in bytes.
   Malformed lines must be skipped, not crash the program. Standard library only.
2. `test_logstats.py`: pytest tests covering parsing, malformed lines, the
   percentile calculation, and the CLI output on a small sample log.
3. `sample.log`: at least 12 realistic lines, including one malformed line.

Output EVERY file in full, each preceded by a line `### FILE: <name>` and then
a fenced code block. No other prose."""

kwargs = ({"enable_thinking": False} if variant == "fast"
          else {"enable_thinking": True, "reasoning_effort": "low"})
body = {"model": "gpu-inference", "max_tokens": 6000, "temperature": 0.2,
        "messages": [{"role": "user", "content": TASK}],
        "chat_template_kwargs": kwargs}

t0 = time.time()
req = urllib.request.Request("http://localhost:8000/v1/chat/completions",
                             data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=1800) as r:
    resp = json.load(r)
dt = time.time() - t0

msg = resp["choices"][0]["message"]
content = msg.get("content") or ""
reasoning = msg.get("reasoning_content") or msg.get("reasoning") or ""
usage = resp.get("usage", {})
open(os.path.join(outdir, "_response.md"), "w").write(content)
if reasoning:
    open(os.path.join(outdir, "_reasoning.md"), "w").write(reasoning)

files = re.findall(r"### FILE:\s*(\S+)\s*\n```[a-zA-Z]*\n(.*?)```", content, re.S)
for name, code in files:
    open(os.path.join(outdir, os.path.basename(name)), "w").write(code)

ct = usage.get("completion_tokens", 0)
print(json.dumps({
    "variant": variant, "seconds": round(dt, 1),
    "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": ct,
    "tok_per_s": round(ct / dt, 1) if dt else None,
    "reasoning_chars": len(reasoning), "finish_reason": resp["choices"][0].get("finish_reason"),
    "files": [n for n, _ in files]}, indent=1))
