#!/usr/bin/env python3
"""One synthetic, streaming OpenRouter free-model trial. Never reads notebooks.

Credential: OPENROUTER_API_KEY or a user-created private
~/.config/drawport/openrouter.key (mode 0600, owned by current user).
No credential goes into the app, repository, shell arguments, or diagnostics.
"""
import json
import os
from pathlib import Path
import stat
import sys
import time
import urllib.error
import urllib.request

MODEL = "liquid/lfm-2.5-2.6b:free"
API = "https://openrouter.ai/api/v1"
KEY_PATH = Path.home() / ".config/drawport/openrouter.key"


def credential():
    def normalize(value):
        value = value.strip()
        # A locally stored 64-hex suffix is also accepted; the non-secret
        # OpenRouter key prefix is restored only in memory, never logged.
        if len(value) == 64 and all(ch in "0123456789abcdefABCDEF" for ch in value):
            return "sk-or-v1-" + value
        return value if value.startswith("sk-or-v1-") else None

    value = os.environ.get("OPENROUTER_API_KEY")
    if value:
        return normalize(value)
    try:
        meta = KEY_PATH.lstat()
        if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077:
            raise ValueError("key file permissions")
        if not 20 <= meta.st_size <= 256:
            raise ValueError("key file size")
        return normalize(KEY_PATH.read_text(encoding="ascii"))
    except (FileNotFoundError, ValueError, UnicodeError):
        return None


def request(url, *, key=None, data=None, timeout=25):
    headers = {"Accept": "application/json" if data is None else "text/event-stream",
               "User-Agent": "DrawPort-synthetic-free-model-test/1.0"}
    if key:
        headers["Authorization"] = "Bearer " + key
    if data is not None:
        headers["Content-Type"] = "application/json"
    return urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=timeout)


def main():
    key = credential()
    if not key:
        print("test_not_run: no securely provisioned local OpenRouter credential")
        return 2
    # Resolve pricing immediately before the request; never intentionally
    # fall back to a paid model, even if the free catalogue changes.
    with request(API + "/models") as response:
        catalogue = json.load(response)
    entry = next((model for model in catalogue.get("data", []) if model.get("id") == MODEL), None)
    if not entry or entry.get("pricing", {}).get("prompt") not in ("0", "0.0") \
            or entry.get("pricing", {}).get("completion") not in ("0", "0.0"):
        print("test_not_run: chosen model is not currently listed as free")
        return 2
    payload = {"model": MODEL,
               "messages": [{"role": "system", "content": "Answer in one short Bulgarian sentence. No tools."},
                            {"role": "user", "content": "Публичен тест: колко е 2 + 2?"}],
               "max_tokens": 300, "temperature": 0, "stream": True,
               # This free model requires reasoning. Cap that budget so a
               # small prompt does not exhaust all output before visible text.
               "reasoning": {"max_tokens": 32},
               "stream_options": {"include_usage": True}}
    started = time.monotonic()
    first = None
    chunks = []
    usage = None
    with request(API + "/chat/completions", key=key,
                 data=json.dumps(payload).encode("utf-8"), timeout=40) as response:
        for raw in response:
            if time.monotonic() - started > 40 or sum(map(len, chunks)) > 4_000:
                print("test_incomplete: time/response budget exceeded")
                return 2
            if not raw.startswith(b"data: "):
                continue
            line = raw[6:].strip()
            if line == b"[DONE]":
                break
            event = json.loads(line)
            if event.get("error"):
                print("test_failed: model/provider error (details withheld)")
                return 2
            usage = event.get("usage") or usage
            choices = event.get("choices") or []
            text = (choices[0].get("delta", {}) if choices else {}).get("content")
            if isinstance(text, str) and text:
                if first is None:
                    first = time.monotonic() - started
                chunks.append(text)
    elapsed = time.monotonic() - started
    answer = "".join(chunks).strip()
    if not answer:
        print("test_failed: no text returned")
        return 2
    # Only the fixed synthetic question is sent, so printing its answer is safe.
    print("model=", MODEL, "ttft_s=", round(first or 0, 2), "total_s=", round(elapsed, 2),
          "answer=", repr(answer[:300]), "usage_tokens=", (usage or {}).get("total_tokens", "unavailable"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as error:
        # Do not dump headers/body: gateways may reflect the bearer credential.
        print("test_failed: HTTP status", error.code)
        sys.exit(2)
    except Exception as error:
        print("test_failed:", type(error).__name__)
        sys.exit(2)
