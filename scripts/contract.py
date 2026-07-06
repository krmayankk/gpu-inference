#!/usr/bin/env python3
"""The seam contract, executable.

Asserts the OpenAI-compatible surface behind the `inference` Service — the
invariant every pool must honor (ADR-0002/0009). The SAME assertions run
against the CPU mock on kind and vLLM on a GPU; passing both is what "the
portability seam holds" means operationally. If vLLM upgrade or a new backend
breaks a field the chat UI depends on, this fails before a human notices.

Stdlib only (urllib): runs anywhere, no venv, no pip.

Usage: contract.py [base_url]   (default http://localhost:8080 — the chat
       proxy, so the test also proves the UI's exact path to the API)
"""
import json
import sys
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080").rstrip("/")
# The public model id is pinned by --served-model-name on every GPU profile;
# the mock accepts any id. Clients never learn a HF path or a hardware name.
MODEL = "gpu-inference"

_failures = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok   {name}")
    else:
        _failures.append(name)
        print(f"  FAIL {name}  {detail}")


def get(path):
    with urllib.request.urlopen(f"{BASE}{path}", timeout=30) as r:
        return json.load(r)


def post(path, body, timeout=120):
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    return urllib.request.urlopen(req, timeout=timeout)


# --- 1. model listing -------------------------------------------------------
models = get("/v1/models")
check("models: object == 'list'", models.get("object") == "list")
check("models: at least one model with an id",
      bool(models.get("data")) and isinstance(models["data"][0].get("id"), str))

# --- 2. non-streaming completion -------------------------------------------
with post("/v1/chat/completions", {
    "model": MODEL,
    "messages": [{"role": "user", "content": "Reply with the single word: pong"}],
    "max_tokens": 40,
}) as r:
    c = json.load(r)
choice = (c.get("choices") or [{}])[0]
msg = choice.get("message") or {}
check("completion: object == 'chat.completion'", c.get("object") == "chat.completion")
check("completion: has id", isinstance(c.get("id"), str) and bool(c["id"]))
check("completion: role == 'assistant'", msg.get("role") == "assistant")
check("completion: non-empty content", bool((msg.get("content") or "").strip()))
check("completion: finish_reason present", bool(choice.get("finish_reason")))

# --- 3. multi-turn history accepted (what the chat UI actually sends) -------
with post("/v1/chat/completions", {
    "model": MODEL,
    "messages": [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "hello"},
        {"role": "user", "content": "and again"},
    ],
    "max_tokens": 40,
}) as r:
    c2 = json.load(r)
check("multi-turn: accepted with content",
      bool(((c2.get("choices") or [{}])[0].get("message") or {}).get("content")))

# --- 4. streaming (SSE) — the UI's actual consumption path ------------------
resp = post("/v1/chat/completions", {
    "model": MODEL,
    "messages": [{"role": "user", "content": "count to three"}],
    "stream": True,
    "max_tokens": 60,
})
ctype = resp.headers.get("content-type", "")
check("stream: content-type is text/event-stream", "text/event-stream" in ctype, ctype)

saw_delta, saw_done = False, False
for raw in resp:
    line = raw.decode(errors="replace").strip()
    if not line.startswith("data:"):
        continue
    data = line[5:].strip()
    if data == "[DONE]":
        saw_done = True
        break
    try:
        chunk = json.loads(data)
    except json.JSONDecodeError:
        continue
    if chunk.get("object") == "chat.completion.chunk" and \
       (chunk.get("choices") or [{}])[0].get("delta", {}).get("content"):
        saw_delta = True
check("stream: at least one content delta chunk", saw_delta)
check("stream: terminates with data: [DONE]", saw_done)

# --- verdict -----------------------------------------------------------------
print()
if _failures:
    print(f"CONTRACT FAILED: {len(_failures)} assertion(s): {', '.join(_failures)}")
    sys.exit(1)
print("CONTRACT HOLDS: this backend is a valid occupant of the serving seam.")
