#!/usr/bin/env python3
"""Personal, loopback-only DrawPort study proxy. Tailscale Serve supplies HTTPS/tailnet access.

Only explicitly confirmed purple OCR text or a bounded image cropped from
inside a purple enclosure is accepted. No PDF, full page, notebook, tool
execution, file retrieval or provider credential reaches the IPA.
Not a multi-user/commercial service. Never log request bodies or credentials.
"""
import base64
import binascii
import http.server
import json
import re
import uuid
import os
from pathlib import Path
import stat
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.request

PORT = 18746
MODEL = "nvidia/nemotron-3.5-super-vl:free"
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
                and candidate.get("pricing", {}).get("completion") in ("0", "0.0")
                and "image" in (candidate.get("architecture", {}).get("input_modalities") or []))


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
        if not 1 <= count <= 250_000 or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.reply(413, "Selection exceeds the request limit")
        try:
            value = json.loads(self.rfile.read(count))
            if not isinstance(value, dict) or value.get("version") not in (1, 2):
                raise ValueError()
            request_id = context_hash = None
            fields = set(value)
            if value["version"] == 2:
                request_id = str(uuid.UUID(value["requestID"]))
                context_hash = value["contextHash"]
                if not isinstance(context_hash, str) or re.fullmatch(r"[0-9a-f]{64}", context_hash) is None:
                    raise ValueError()
                fields -= {"requestID", "contextHash"}
            if fields == {"version", "question"}:
                question = value["question"]
                if not isinstance(question, str) or not 1 <= len(question.strip()) <= 700 or "\x00" in question:
                    raise ValueError()
                selected = (question.strip(), None)
            elif fields == {"version", "image"}:
                encoded = value["image"]
                if not isinstance(encoded, str) or len(encoded) > 240_000:
                    raise ValueError()
                png = base64.b64decode(encoded, validate=True)
                if not 1 <= len(png) <= 180_000 or png[:8] != b'\x89PNG\r\n\x1a\n' or png[12:16] != b'IHDR':
                    raise ValueError()
                width, height = struct.unpack('>II', png[16:24])
                if not 1 <= width <= 1_200 or not 1 <= height <= 1_200 or width * height > 1_200_000:
                    raise ValueError()
                selected = (None, encoded)
            else:
                raise ValueError()
            selected += (request_id, context_hash)
        except (ValueError, UnicodeError, binascii.Error, struct.error):
            return self.reply(400, "Invalid purple-ink selection")
        if not LOCK.acquire(blocking=False):
            return self.reply(429, "A study request is already running")
        try:
            self.answer(*selected)
        finally:
            LOCK.release()

    def send_event(self, event):
        data = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.wfile.write(b"data: " + data + b"\n\n")
        self.wfile.flush()

    def answer(self, question, image, request_id, context_hash):
        stream_open = False
        try:
            key = credential()
            if not free_now():
                return self.reply(503, "The chosen model is not currently free")
            system = ("You are a Bulgarian STUDY ASSISTANT. Verify the circled student's work or "
                      "explain/solve the question; check arithmetic and mathematical steps instead of guessing. "
                      "Use only the supplied text or cropped image. State uncertainty when handwriting cannot "
                      "be read. Never claim to have read a whole notebook or PDF. No tools, no invented sources. "
                      "Answer concisely in plain text without Markdown or asterisks.")
            wants_graph = question is not None and bool(re.search(
                r"\b(graph|plot|plotting|draw graph)\b|график|начертай|построй график",
                question.casefold()))
            structured = request_id is not None and (image is not None or wants_graph)
            if structured:
                sample = {"version": 1, "requestID": request_id, "contextHash": context_hash,
                          "explanation": "Brief Bulgarian answer", "assets": [{
                    "id": "00000000-0000-0000-0000-000000000002", "kind": "function2D",
                    "caption": "y = x²", "trigger": "requested", "width": 500, "height": 340,
                    "x": 0.1, "y": 0.2, "sourceIDs": [], "parameters": [],
                    "plot": {"xMin": -4, "xMax": 4, "yMin": -2, "yMax": 8,
                             "nodes": [{"op": "x", "inputs": []},
                                       {"op": "power", "inputs": [0], "exponent": 2}], "output": 1}}]}
                system += (" Respond ONLY with a single JSON object, schema version 1, exact requestID and contextHash. "
                           "The explanation is your short Bulgarian study answer. assets MUST be [] for ordinary "
                           "questions. Include ONE function2D asset only when the student explicitly asks for a "
                           "graph or it is genuinely useful to explain a function; never draw for simple arithmetic. "
                           "Graph expressions are a topologically ordered DAG of nodes with op x, constant(literal), "
                           "parameter(a/b/c), add/subtract/multiply/divide(inputs two earlier indices), "
                           "sin/cos(inputs one), power(inputs one, exponent integer 0..4). "
                           "Only output normalized coordinates, finite values, no SVG/JS/URLs or citations. "
                           "Use this concrete JSON schema example, but make the function fit the actual task: "
                           + json.dumps(sample, separators=(",", ":")))
            content = question if image is None else [
                {"type": "text", "text": "Това е изрязано изображение с мастилото вътре в лилаво заграждение И евентуални лилави ръкописни указания отстрани. Самата линия на заграждението е премахната нарочно; не я обсъждай. Считай лилавия текст отстрани за въпрос/контекст към ограденото. Прочети видимото, провери решението или обясни задачата кратко НА БЪЛГАРСКИ. При нечетлив почерк кажи го."},
                {"type": "image_url", "image_url": {"url": "data:image/png;base64," + image}}]
            payload = {"model": MODEL, "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": content}],
                "temperature": 0, "max_tokens": 1_800 if structured else 500,
                "reasoning": {"effort": "none"},
                "stream": True, "stream_options": {"include_usage": True}}
            if structured:
                payload["response_format"] = {"type": "json_object"}
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
                structured_parts = []
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
                        if total > (12_000 if structured else 4_000):
                            self.send_event({"error": "Response limit reached"})
                            return
                        if structured: structured_parts.append(delta)
                        else: self.send_event({"delta": delta})
                if structured:
                    try:
                        proposed = json.loads(''.join(structured_parts))
                        if not isinstance(proposed, dict) \
                                or not isinstance(proposed.get('explanation'), str) \
                                or not 1 <= len(proposed['explanation']) <= 4_000 \
                                or not isinstance(proposed.get('assets'), list) \
                                or len(proposed['assets']) > 1:
                            raise ValueError()
                        self.send_event({"delta": proposed['explanation']})
                        if proposed['assets']:
                            proposed['version'] = 1
                            # Model-authored binding IDs are not trusted: assign them
                            # from the authenticated request, not from its example.
                            proposed['requestID'] = request_id
                            proposed['contextHash'] = context_hash
                            for asset in proposed['assets']:
                                if not isinstance(asset, dict): raise ValueError()
                                asset['id'] = str(uuid.uuid4())
                            self.send_event({"visualJSON": json.dumps(proposed, separators=(',', ':'), ensure_ascii=False)})
                        self.send_event({"done": True})
                    except (ValueError, KeyError, TypeError):
                        self.send_event({"error": "No valid study graph was produced"})
                else:
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
