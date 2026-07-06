#!/usr/bin/env python3
"""Phase-0 CPU mock that speaks the OpenAI API.

Why this exists: it validates the *invariant* — the `inference` Service, the
`/v1` contract, the chat UI, and the whole up/demo/down lifecycle — at $0 on a
CPU. Phase 1 replaces this single pod with vLLM on a real GPU and NOTHING above
the Service changes. That swap is the portability thesis (ADR-0002 / ADR-0009)
made executable, not asserted.

Pure standard library on purpose: the container is `python:3.12-slim` with the
source mounted from a ConfigMap, so there is no image build and no pip install.
"""
import json
import os
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = os.environ.get("MODEL_ID", "gpu-inference-mock-cpu")
PORT = int(os.environ.get("PORT", "8000"))


def reply_text(messages):
    """A deterministic, self-describing answer. Honest about being a mock."""
    user = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            user = (m.get("content") or "").strip()
            break
    return (
        f"You said: {user!r}. "
        "I am the Phase-0 CPU mock speaking the OpenAI API. In Phase 1 this exact "
        "endpoint is served by vLLM on a GPU — the Service, the /v1 contract, and "
        "this chat UI do not change. That invariance is the portability thesis."
    )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):  # noqa: D401 - k8s captures stdout; stay quiet
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.rstrip("/")
        if path in ("/health", "/healthz"):
            self._json(200, {"status": "ok"})
        elif self.path.startswith("/v1/models"):
            self._json(200, {"object": "list", "data": [
                {"id": MODEL_ID, "object": "model", "owned_by": "gpu-inference"}]})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if not self.path.startswith("/v1/chat/completions"):
            self._json(404, {"error": {"message": "not found"}})
            return
        length = int(self.headers.get("content-length", 0))
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"error": {"message": "invalid json"}})
            return
        text = reply_text(req.get("messages", []))
        cid = "chatcmpl-" + uuid.uuid4().hex[:24]
        created = int(time.time())
        if req.get("stream"):
            self._stream(cid, created, text)
        else:
            n = len(text.split())
            self._json(200, {
                "id": cid, "object": "chat.completion", "created": created,
                "model": MODEL_ID,
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": text}}],
                "usage": {"prompt_tokens": 0, "completion_tokens": n, "total_tokens": n},
            })

    def _stream(self, cid, created, text):
        # SSE. Delimit the body by connection close (no content-length) so any
        # OpenAI-compatible client sees a clean end-of-stream.
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True

        def emit(delta, finish=None):
            chunk = {"id": cid, "object": "chat.completion.chunk", "created": created,
                     "model": MODEL_ID,
                     "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()

        emit({"role": "assistant"})
        for word in text.split(" "):
            emit({"content": word + " "})
            time.sleep(0.02)
        emit({}, finish="stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    print(f"mock OpenAI server on :{PORT} model={MODEL_ID}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
