#!/usr/bin/env python3
"""Mock upstreams for the end-to-end tests (stdlib only).

POST /v1/systemone   fake System One API: answers the `instance` choice
                     question with a probability distribution
POST */fail/*        fake LLM that always fails with HTTP 500
POST <anything else> fake LLM: echoes which model and path served the call

Ranking rules (on the request "state"):
  contains "FAIL"     -> HTTP 500 (tests the fallback on System One errors)
  contains "LOWCONF"  -> nothing above 0.4 (tests the threshold)
  code words          -> "code" 0.9;  math words -> "math" 0.85;  else "general" 0.7
Every System One request is appended to /tmp/decisions.jsonl for inspection.
"""
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CODE = re.compile(r"\b(python|bug|function|compile|segfault|code)\b", re.I)
MATH = re.compile(r"\b(prove|integral|theorem|derivative|equation)\b", re.I)


def rank(payload):
    state = payload.get("state", "")
    options = list(payload["questions"]["instance"]["criteria"])
    if "FAIL" in state:
        return None
    if "LOWCONF" in state:
        weights = {o: 1 for o in options}
    else:
        winner, p = "general", 0.7
        if CODE.search(state):
            winner, p = "code", 0.9
        elif MATH.search(state):
            winner, p = "math", 0.85
        rest = (1 - p) / max(len(options) - 1, 1)
        weights = {o: (p if o == winner else rest) for o in options}
    total = sum(weights.values())
    probs = {o: round(w / total, 4) for o, w in weights.items()}
    choice = max(probs, key=probs.get)
    return {
        "model": payload.get("model"),
        "answers": {"instance": {
            "choice": choice, "confidence": probs[choice], "probabilities": probs,
        }},
        "usage": {"input_tokens": len(state.split()), "output_tokens": 1},
    }


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if self.path == "/v1/systemone":
            with open("/tmp/decisions.jsonl", "a") as f:
                f.write(json.dumps({"auth": self.headers.get("Authorization"),
                                    "cookie": self.headers.get("Cookie"), **body}) + "\n")
            result = rank(body)
            if result is None:
                return self.send(500, {"error": "boom"})
            return self.send(200, result)
        if "/fail/" in self.path:
            return self.send(500, {"error": "instance down"})
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

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
