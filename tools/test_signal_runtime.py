#!/usr/bin/env python3
"""Bounded SIGPIPE/TLS and child-mask regressions on the actual runtime."""
from pathlib import Path
import base64
import hashlib
import json
import os
import shlex
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test_signal_runtime.py /path/to/babet")
    binary = Path(sys.argv[1]).resolve()
    project = Path(__file__).resolve().parent.parent
    fixtures = project / "tests/signals"
    passes = 0

    def passed(name):
        nonlocal passes
        passes += 1
        print(f"[PASS] {name}", flush=True)

    def run(script, env=None):
        result = subprocess.run([str(binary), str(script)], env=env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, (
            f"{script.name}: exit {result.returncode}\n"
            + result.stdout + result.stderr)
        return result.stdout

    with tempfile.TemporaryDirectory(prefix="babet-signals-") as tmp:
        root = Path(tmp)
        cc = shlex.split(os.environ.get("CC", "cc"))
        cxx = shlex.split(os.environ.get("CXX", "c++"))
        probe = root / "process_probe"
        guard = root / "sigpipe_guard_test"
        preload = root / "tls_write_epipe.so"
        subprocess.run([*cc, "-Wall", "-Wextra", "-Werror",
                        str(fixtures / "process_probe.c"), "-o", str(probe)], check=True)
        subprocess.run([*cxx, "-std=c++23", "-Wall", "-Wextra", "-Werror", "-pthread",
                        "-I" + str(project / "src"),
                        str(fixtures / "sigpipe_guard_test.cpp"), "-o", str(guard)], check=True)
        subprocess.run([str(guard)], check=True, timeout=10)
        passed("SIGPIPE guard preserves errno, handlers, pending signals and other threads")
        output = run(fixtures / "process_masks.lua",
                     dict(os.environ, BABET_TEST_SIGNAL_PROBE=str(probe)))
        print(output, end="", flush=True)
        passes += 2

        subprocess.run([*cc, "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror",
                        str(fixtures / "tls_write_epipe.c"), "-ldl", "-o", str(preload)], check=True)
        cert, key = root / "cert.pem", root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(cert), "-days", "1",
                        "-subj", "/CN=localhost"], check=True, capture_output=True)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)

        for mode in ("tls-connect", "tls-send", "tls-read", "tls-close",
                     "wss-connect", "wss-send", "wss-read",
                     "https-connect", "https-close", "https-download", "tls-handler"):
            case = root / mode
            case.mkdir()
            arm, marker = case / "armed", case / "injected"
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(6)
            port = listener.getsockname()[1]
            failures = []
            stop = threading.Event()

            def serve():
                try:
                    raw, _ = listener.accept()
                    raw.settimeout(6)
                    with ctx.wrap_socket(raw, server_side=True) as conn:
                        if mode.startswith("wss-") or mode == "https-close":
                            request = b""
                            while b"\r\n\r\n" not in request:
                                chunk = conn.recv(4096)
                                if not chunk:
                                    return
                                request += chunk
                            if mode == "https-close":
                                arm.touch()
                                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
                                             b"Connection: close\r\n\r\nOK")
                            else:
                                key_line = next(line for line in request.split(b"\r\n")
                                                if line.lower().startswith(b"sec-websocket-key:"))
                                ws_key = key_line.split(b":", 1)[1].strip()
                                accept = base64.b64encode(hashlib.sha1(
                                    ws_key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                                conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\n"
                                             b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                             b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                        if mode.endswith("-read"):
                            deadline = time.monotonic() + 6
                            while not arm.exists():
                                if stop.wait(.005) or time.monotonic() > deadline:
                                    raise TimeoutError("client did not arm read injection")
                            # A corrupt encrypted record makes SSL_read send an alert.
                            with socket.socket(fileno=conn.detach()) as transport:
                                transport.settimeout(6)
                                transport.sendall(b"\x17\x03\x03\x00\x01\x00")
                                while transport.recv(4096):
                                    pass
                        else:
                            while conn.recv(4096):
                                pass
                except (ssl.SSLError, ConnectionResetError, BrokenPipeError):
                    pass  # Expected after the injected TLS transport failure.
                except Exception as error:
                    failures.append(repr(error))
                finally:
                    listener.close()

            server = threading.Thread(target=serve, daemon=True)
            server.start()
            quote = lambda p: json.dumps(str(p))
            arm_lua = f'local f = assert(io.open({quote(arm)}, "w")); f:close()\n'
            opts = '{verify=false, timeout=2}'
            tls = f'babet.socket.connect_tls("127.0.0.1", {port}, {opts})'
            wss = f'babet.websocket.connect("wss://127.0.0.1:{port}/", {opts})'
            bad = 'assert(value == nil and type(err) == "string", tostring(err))\n'
            source = ''
            if mode == 'tls-handler':
                source += ('local hits=0\nassert(babet.signal.handle("PIPE", function() '
                           'hits=hits+1 end))\n')
            if mode in ('tls-connect', 'wss-connect'):
                source += arm_lua + f'local value, err = {tls if mode == "tls-connect" else wss}\n' + bad
            elif mode.startswith('https-'):
                call = f'babet.http.get("https://127.0.0.1:{port}/", {opts})'
                if mode == 'https-download':
                    call = (f'babet.http.download("https://127.0.0.1:{port}/", '
                            f'{quote(case / "download")}, {opts})')
                source += ('' if mode == 'https-close' else arm_lua)
                source += f'local value, err = {call}\n'
                source += ('assert(value and value.status == 200 and value.body == "OK", err)\n'
                           if mode == 'https-close' else bad)
            else:
                source += f'local s = assert({wss if mode.startswith("wss-") else tls})\n' + arm_lua
                if mode == 'tls-close':
                    source += 'assert(s:close())\n'
                else:
                    method = ('recv(64, 2)' if mode == 'tls-read' else
                              'recv(2)' if mode == 'wss-read' else
                              'send_text("hello", 2)' if mode == 'wss-send' else
                              'send("hello")')
                    source += f'local value, err = s:{method}\n' + bad
                    source += 's=nil; collectgarbage("collect")\n'
                if mode == 'tls-handler':
                    source += ('for i=1,10000 do local x=i+1 end\n'
                               'assert(hits == 0, "transport SIGPIPE escaped into Lua")\n'
                               'assert(babet.exec("kill", {"-PIPE", tostring(babet.pid())}))\n'
                               'for i=1,10000 do local x=i+1 end\n'
                               'assert(hits == 1, "application SIGPIPE handler was changed")\n')
            script = case / 'test.lua'
            script.write_text(source, encoding='utf-8')
            preloads = [os.environ.get('BABET_TEST_ASAN_RUNTIME', ''), str(preload),
                        os.environ.get('LD_PRELOAD', '')]
            env = dict(os.environ, LD_PRELOAD=':'.join(p for p in preloads if p),
                       BABET_TEST_SIGPIPE_ARM=str(arm), BABET_TEST_SIGPIPE_MARKER=str(marker))
            try:
                run(script, env)
                assert marker.exists(), f'{mode}: TLS BIO write injection did not run'
            finally:
                stop.set()
                server.join(7)
            assert not server.is_alive() and not failures, f'{mode}: server failed {failures}'
            passed(f'{mode}: SIGPIPE does not terminate the runtime')
    print(f'signal runtime: {passes} PASS / 0 FAIL', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f'[FAIL] signal runtime: {error}', file=sys.stderr)
        raise SystemExit(1)
