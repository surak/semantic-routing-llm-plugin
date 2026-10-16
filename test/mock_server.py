#!/usr/bin/env python3
"""Mock upstreams for the end-to-end tests (stdlib only).

POST /v1/systemone          fake decision model: keyword rules pick a candidate
POST <anything else>        fake LLM: echoes which model / path served the call

Decision rules (on the request "state"):
  contains "FAIL"     -> HTTP 500 (tests fallback on decision errors)
  contains "LOWCONF"  -> picks "math" with confidence 0.2
  code words          -> "code";  math words -> "math";  otherwise "general"
Every decision request is appended to /tmp/decisions.jsonl for inspection.
"""
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CODE = re.compile(r"\b(python|bug|function|compile|segfault|code)\b", re.I)
MATH = re.compile(r"\b(prove|integral|theorem|derivative|equation)\b", re.I)


def decide(payload):
    state = payload.get("state", "")
    options = list(payload["questions"]["route"]["criteria"])
    if "FAIL" in state:
        return None
    if "LOWCONF" in state:
        choice, conf = "math", 0.2
    elif CODE.search(state):
        choice, conf = "code", 0.9
    elif MATH.search(state):
        choice, conf = "math", 0.85
    else:
        choice, conf = "general", 0.7
    if choice not in options:
        choice = options[0]
    rest = (1 - conf) / max(len(options) - 1, 1)
    probs = {o: (conf if o == choice else rest) for o in options}
    return {
        "model": payload.get("model"),
        "answers": {"route": {"choice": choice, "confidence": conf, "probabilities": probs}},
        "usage": {"input_tokens": len(state.split()), "output_tokens": 1},
    }


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if self.path == "/v1/systemone":
            with open("/tmp/decisions.jsonl", "a") as f:
                f.write(json.dumps({"auth": self.headers.get("Authorization"), **body}) + "\n")
            result = decide(body)
            if result is None:
                return self.send(500, {"error": "boom"})
            return self.send(200, result)
        text = f"model={body.get('model')} path={self.path}"
        self.send(200, {
            "id": "mock", "object": "chat.completion", "model": body.get("model"),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": text}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        })

    def send(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
