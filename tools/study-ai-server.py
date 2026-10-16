#!/usr/bin/env python3
"""Personal, loopback-only DrawPort study proxy. Tailscale Serve supplies HTTPS/tailnet access.

Only an explicitly typed, bounded question is accepted. No PDF, image, stroke,
notebook, tool execution, file retrieval, or provider credential reaches the IPA.
Not a multi-user/commercial service. Never log request bodies or credentials.
"""
import http.server
import json
import os
from pathlib import Path
import stat
import subprocess
import threading
import time
import urllib.error
import urllib.request

PORT = 18746
MODEL = "liquid/lfm-2.5-2.6b:free"
API = "https://openrouter.ai/api/v1"
KEY_PATH = Path.home() / ".config/drawport/openrouter.key"
LOCK = threading.BoundedSemaphore(1)


def owner_login():
    # Tailscale Serve strips spoofed incoming identity headers and sets the
    # authenticated tailnet user on local proxy requests. Refuse tagged peers
    # and other tailnet users; no account identifier is printed or published.
    result = subprocess.run(['tailscale', 'status', '--json'], capture_output=True,
                            text=True, check=True, timeout=8)
    status = json.loads(result.stdout)
    login = (status.get('User') or {}).get(str((status.get('Self') or {}).get('UserID')), {}).get('LoginName')
    if not isinstance(login, str) or not login:
        raise ValueError('owner identity unavailable')
    return login


OWNER = owner_login()


def credential():
    info = KEY_PATH.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("private credential required")
    if not 20 <= info.st_size <= 256:
        raise ValueError("private credential required")
    value = KEY_PATH.read_text(encoding="ascii").strip()
    if len(value) == 64 and all(ch in "0123456789abcdefABCDEF" for ch in value):
        value = "sk-or-v1-" + value
    if not value.startswith("sk-or-v1-") or any(ch.isspace() for ch in value):
        raise ValueError("private credential required")
    return value


def free_now():
    with urllib.request.urlopen(API + "/models", timeout=12) as response:
        models = json.load(response).get("data", [])
    candidate = next((item for item in models if item.get("id") == MODEL), None)
    return bool(candidate and candidate.get("pricing", {}).get("prompt") in ("0", "0.0")
                and candidate.get("pricing", {}).get("completion") in ("0", "0.0"))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass  # HTTP and model text may contain private questions. No access logs.

    def reply(self, code, message):
        data = json.dumps({"error": message}, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def do_GET(self):
        if self.path != "/v1/study/health":
            return self.reply(404, "Not found")
        data = b'{"ready":true,"version":1}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/v1/study/ask":
            return self.reply(404, "Not found")
        if self.headers.get('Tailscale-Funnel-Request') or self.headers.get('Tailscale-User-Login') != OWNER:
            return self.reply(403, "Tailnet owner required")
        try:
            count = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            count = -1
        if not 1 <= count <= 2_000 or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.reply(413, "Question exceeds the request limit")
        try:
            value = json.loads(self.rfile.read(count))
            if not isinstance(value, dict) or set(value) != {"version", "question"} or value["version"] != 1:
                raise ValueError()
            question = value["question"]
            if not isinstance(question, str) or not 1 <= len(question.strip()) <= 700 or "\x00" in question:
                raise ValueError()
        except (ValueError, UnicodeError):
            return self.reply(400, "Enter one short question")
        if not LOCK.acquire(blocking=False):
            return self.reply(429, "A study request is already running")
        try:
            self.answer(question.strip())
        finally:
            LOCK.release()

    def send_event(self, event):
        data = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.wfile.write(b"data: " + data + b"\n\n")
        self.wfile.flush()

    def answer(self, question):
        stream_open = False
        try:
            key = credential()
            if not free_now():
                return self.reply(503, "The chosen model is not currently free")
            payload = {"model": MODEL, "messages": [
                {"role": "system", "content": "You are a concise Bulgarian study tutor. Answer in plain text only (no Markdown, headings or asterisks), preferably under 120 words. Explain accurately. Never invent sources or claim to have read a PDF. No tools. If unsure, say so."},
                {"role": "user", "content": question}],
                "temperature": 0, "max_tokens": 420, "reasoning": {"max_tokens": 32},
                "stream": True, "stream_options": {"include_usage": True}}
            request = urllib.request.Request(API + "/chat/completions",
                data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                         "Accept": "text/event-stream"})
            with urllib.request.urlopen(request, timeout=38) as upstream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Accel-Buffering", "no")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                stream_open = True
                total = 0
                started = time.monotonic()
                for line in upstream:
                    if time.monotonic() - started > 42:
                        self.send_event({"error": "Model time limit reached"})
                        return
                    if not line.startswith(b"data:"):
                        continue
                    body = line[5:].strip()
                    if body == b"[DONE]":
                        break
                    event = json.loads(body)
                    if event.get("error"):
                        self.send_event({"error": "Model provider unavailable"})
                        return
                    for choice in event.get("choices") or []:
                        delta = (choice.get("delta") or {}).get("content")
                        if not isinstance(delta, str) or not delta:
                            continue  # Do not relay provider reasoning or tool calls.
                        total += len(delta)
                        if total > 4_000:
                            self.send_event({"error": "Response limit reached"})
                            return
                        self.send_event({"delta": delta})
                self.send_event({"done": True} if total else {"error": "Model returned no answer"})
        except (BrokenPipeError, ConnectionResetError):
            pass  # User closed/cancelled the answer.
        except urllib.error.HTTPError as error:
            try:
                if stream_open: self.send_event({"error": "Model provider unavailable"})
                else: self.reply(502, "Model provider unavailable (HTTP " + str(error.code) + ")")
            except OSError:
                pass
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            try:
                if stream_open: self.send_event({"error": "Study AI unavailable"})
                else: self.reply(503, "Study AI unavailable")
            except OSError:
                pass


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
