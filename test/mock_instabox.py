#!/usr/bin/env python3
"""本地测试用的假 InstaBox API，只实现 keeper.sh 用到的那几个端点。"""
import json
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {
    "state": "running",
    "startedAt": None,      # epoch 秒
    "cooldownUntil": None,  # ISO8601
}
EVENTS = []
LOCK = threading.Lock()


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        p = self.path.split("?")[0]
        with LOCK:
            if p == "/__events":
                return self._send(200, EVENTS)
            if p == "/__body":
                return self._send(200, {
                    "state": STATE["state"],
                    "startedAt": iso(STATE["startedAt"]) if STATE["startedAt"] else None,
                    "cooldownUntil": STATE["cooldownUntil"],
                })
            if p.startswith("/v1/machines/"):
                return self._send(200, {
                    "id": "m_test",
                    "state": STATE["state"],
                    "startedAt": iso(STATE["startedAt"]) if STATE["startedAt"] else None,
                    "cooldownUntil": STATE["cooldownUntil"],
                })
        self._send(404, {"error": "not found"})

    def do_POST(self):
        p = self.path.split("?")[0]
        with LOCK:
            if p == "/__set":
                q = dict(x.split("=", 1) for x in self.path.split("?")[1].split("&")) if "?" in self.path else {}
                if "state" in q:
                    STATE["state"] = q["state"]
                if "startedAgoMin" in q:
                    STATE["startedAt"] = time.time() - float(q["startedAgoMin"]) * 60
                if "cooldown" in q:
                    STATE["cooldownUntil"] = q["cooldown"] or None
                return self._send(200, {"ok": True})
            if p.endswith("/start"):
                EVENTS.append({"t": time.time(), "action": "start"})
                STATE["state"] = "running"
                STATE["startedAt"] = time.time()
                STATE["cooldownUntil"] = None
                return self._send(202, {"id": "m_test"})
            if p.endswith("/stop"):
                EVENTS.append({"t": time.time(), "action": "stop"})
                STATE["state"] = "suspended"
                STATE["cooldownUntil"] = iso(time.time() + 600)
                return self._send(202, {"id": "m_test"})
        self._send(404, {"error": "not found"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    STATE["startedAt"] = time.time()
    HTTPServer(("127.0.0.1", port), H).serve_forever()
