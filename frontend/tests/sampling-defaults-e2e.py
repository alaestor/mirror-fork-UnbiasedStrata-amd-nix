#!/usr/bin/env python3
"""Check engine-bound sampling through the real HTTP frontend, without weights or a GPU."""
import contextlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
VOCAB = HERE.parent.parent / "third_party/llama.cpp/models/ggml-vocab-qwen35.gguf"
BIN = str(Path(sys.argv[1]).resolve())


def fixture(path, arch):
    data = VOCAB.read_bytes()
    assert struct.unpack_from("<Q", data, 8)[0] == 0, "fixture must have no tensors"
    key = b"general.architecture"
    pos = data.index(struct.pack("<Q", len(key)) + key + struct.pack("<I", 8)) + 8 + len(key) + 4
    size = struct.unpack_from("<Q", data, pos)[0]
    path.write_bytes(data[:pos] + struct.pack("<Q", len(arch)) + arch.encode() + data[pos + 8 + size:])


@contextlib.contextmanager
def server(work, arch, *args):
    # Deliberately unrelated filename: derivatives are selected by GGUF architecture, not name.
    model = work / "DavidAU-variant.gguf"
    fixture(model, arch)
    capture = work / "requests.log"
    capture.write_text("")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    with (work / "server.log").open("w+") as log:
        proc = subprocess.Popen([
            BIN, "--engine", str(HERE / "fake-engine.py"), "-m", str(model),
            "--host", "127.0.0.1", "--port", str(port), "--jinja",
            "--chat-template-file", str(HERE / "data/qwen3-chat-template.jinja"), *args,
        ], stdout=log, stderr=log,
            env={**os.environ, "FAKE_N_TOKENS": "1", "FAKE_REQUEST_LOG": str(capture)})
        try:
            for _ in range(200):
                try:
                    urllib.request.urlopen(url + "/health", timeout=1).close()
                    break
                except (urllib.error.URLError, TimeoutError):
                    if proc.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read())
                    time.sleep(0.1)
            else:
                raise AssertionError("server readiness timed out")

            def request(settings=None, endpoint="/v1/chat/completions", expected_status=200):
                body = {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 1}
                if endpoint != "/v1/chat/completions":
                    body = {"prompt": "hi", "max_tokens": 1}
                body.update(settings or {})
                req = urllib.request.Request(url + endpoint, data=json.dumps(body).encode(),
                                             headers={"Content-Type": "application/json"})
                try:
                    with urllib.request.urlopen(req, timeout=10) as res:
                        assert res.status == expected_status
                        res.read()
                except urllib.error.HTTPError as exc:
                    assert exc.code == expected_status, exc.read()
                    return {}
                line = [line for line in capture.read_text().splitlines() if line.startswith("GEN ")][-1]
                return {key: float(value) for key, value in
                        (field.split("=", 1) for field in line.split()[2:-1])}

            yield request
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


with tempfile.TemporaryDirectory(prefix="strata-sampling-") as tmp:
    work = Path(tmp)
    for arch in ("qwen4exp", "qwen35moe"):
        with server(work, arch) as request:
            got = request()
            assert got["temperature"] == 1 and got["top_p"] == .95 and got["top_k"] == 20, got
            assert "min_p" not in got, got
            assert got.get("penalty_present", 0) == (1.5 if arch == "qwen35moe" else 0), got
            for mode in ({"chat_template_kwargs": {"enable_thinking": False}}, {"reasoning_effort": "none"}):
                got = request(mode)
                assert got["temperature"] == .7 and got["top_p"] == .8 and got["penalty_present"] == 1.5, got
            assert "temperature" not in request({"temperature": 0})
            got = request({"temperature": None, "top_k": None, "min_p": None})
            assert got["temperature"] == 1 and got["top_k"] == 20 and "min_p" not in got, got
            got = request({"temperature": .6, "top_k": 10, "min_p": .1, "presence_penalty": 0})
            assert got["temperature"] == .6 and got["top_k"] == 10 and got["min_p"] == .1, got
            assert got.get("penalty_present", 0) == 0, got
            assert request(endpoint="/v1/completions")["temperature"] == 1
            request({"temperature": "invalid"}, expected_status=400)
            assert request()["temperature"] == 1  # no cross-request mutation

    with server(work, "qwen35moe", "--temp", "0.8", "--top-k", "40", "--min-p", "0.05",
                "--presence-penalty", "0") as request:
        got = request({"reasoning_effort": "none"})
        assert got["temperature"] == .8 and got["top_k"] == 40 and got["min_p"] == .05, got
        assert got["top_p"] == .8 and got.get("penalty_present", 0) == 0, got
        assert request({"temperature": 1})["temperature"] == 1
    with server(work, "qwen4exp", "--temp", "0") as request:
        assert "temperature" not in request()
        assert request({"temperature": 1})["temperature"] == 1
    with server(work, "qwen4exp", "--chat-template-kwargs", '{"enable_thinking":false}') as request:
        assert request()["temperature"] == .7
        assert request({"chat_template_kwargs": {"enable_thinking": True}})["temperature"] == 1
    with server(work, "qwen35") as request:
        got = request()
        assert got["temperature"] == .8 and got["top_k"] == 40 and got["min_p"] == .05, got

print("PASS: model-card defaults, derivative metadata, thinking modes, server/request overrides, raw completions")
