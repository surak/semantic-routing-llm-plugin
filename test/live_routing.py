#!/usr/bin/env python3
"""Send a set of prompts through a running gateway and report how each was routed.

  python3 test/live_routing.py http://127.0.0.1:9080/v1/chat/completions

Prints prompt, X-AI-Routed-Model, confidence, fallback reason, the model that
answered (from the response body) and the total latency. Exits non-zero if any
request fails. No API key needed: the gateway holds the credentials.
"""
import json
import sys
import time
import urllib.request

PROMPTS = [
    ("code-debug", "Here is my Python traceback: KeyError: 'id' inside a for loop over API results. Why?"),
    ("code-build", "Implement a thread-safe LRU cache in Rust with generics and unit tests."),
    ("snippet", "Quick: one-line bash to count lines in all .py files. I need it in 2 seconds."),
    ("proof", "Prove rigorously that the square root of 2 is irrational."),
    ("calc", "A train leaves at 9:10 at 87 km/h, another at 9:40 at 110 km/h. When does the second catch up?"),
    ("earth-obs", "Design a pipeline to detect deforestation from Sentinel-2 time series with cloud masking."),
    ("german", "Formuliere eine offizielle Pressemitteilung zur Eröffnung eines neuen Rechenzentrums."),
    ("chit-chat", "Hi! Any tips for staying motivated on a rainy Monday?"),
    ("long-docs", "I have 400 PDFs of meeting minutes from 10 years; track how the budget decisions evolved across all of them."),
    ("architecture", "Design a multi-agent system that plans, codes, tests and deploys microservices with human approval gates."),
    ("trivia", "What is the capital of Australia?"),
]


def call(url, prompt, model="auto"):
    body = json.dumps({"model": model, "max_tokens": 16,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    start = time.monotonic()
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.load(resp)
        h = resp.headers
    return {
        "routed": h.get("X-AI-Routed-Model", "-"),
        "conf": h.get("X-AI-Routing-Confidence", "-"),
        "fallback": h.get("X-AI-Routing-Fallback", ""),
        "served": (data.get("model") or "?")[:42],
        "secs": time.monotonic() - start,
    }


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9080/v1/chat/completions"
    failed = 0
    print(f"{'case':13} {'routed to':32} {'conf':>6}  {'secs':>5}  served by")
    for name, prompt in PROMPTS:
        try:
            r = call(url, prompt)
        except Exception as exc:  # report and keep going
            failed += 1
            print(f"{name:13} ERROR {exc}")
            continue
        extra = f"  [fallback: {r['fallback']}]" if r["fallback"] else ""
        print(f"{name:13} {r['routed']:32} {r['conf'][:6]:>6}  {r['secs']:5.1f}  {r['served']}{extra}")
    # an explicit model must pass through untouched
    try:
        r = call(url, "Prove Fermat's little theorem.", model="alias-fast")
        ok = r["routed"] == "-"
        print(f"{'explicit':13} {'(not routed)' if ok else r['routed']:32} {'':>6}  {r['secs']:5.1f}  {r['served']}")
        failed += not ok
    except Exception as exc:
        failed += 1
        print(f"explicit      ERROR {exc}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
