#!/usr/bin/env python3
"""Runtime regressions for abandoned sends and shared receive buffers."""
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


LIMIT = 8 * 1024 * 1024
quote = lambda value: json.dumps(str(value), ensure_ascii=False)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test_network_recovery.py /path/to/babet")
    binary = Path(sys.argv[1]).resolve()
    project = Path(__file__).resolve().parent.parent
    passes = 0
    with tempfile.TemporaryDirectory(prefix='babet-network-recovery-') as tmp:
        root = Path(tmp)
        preload = root / 'write_fault.so'
        subprocess.run([*shlex.split(os.environ.get('CC', 'cc')), '-shared', '-fPIC',
                        '-O2', '-Wall', '-Wextra', '-Werror',
                        str(project / 'tests/network/write_fault.c'), '-ldl',
                        '-o', str(preload)], check=True)
        cert, key = root / 'cert.pem', root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cert), '-days', '1',
                        '-subj', '/CN=localhost'], check=True, capture_output=True)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)

        def run_case(name, tls, make_lua, serve, injection=None):
            nonlocal passes
            case = root / name
            case.mkdir()
            arm, marker = case / 'armed', case / 'injected'
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0)); listener.listen(); listener.settimeout(8)
            port = listener.getsockname()[1]
            errors = []

            def server():
                try:
                    raw, _ = listener.accept()
                    raw.settimeout(8)
                    conn = ctx.wrap_socket(raw, server_side=True) if tls else raw
                    with conn:
                        serve(conn)
                except (ssl.SSLError, ConnectionResetError, BrokenPipeError) as error:
                    if injection is None:
                        errors.append(repr(error))
                except Exception as error:
                    errors.append(repr(error))
                finally:
                    listener.close()

            thread = threading.Thread(target=server, daemon=True)
            thread.start()
            script = case / 'test.lua'
            script.write_text(make_lua(port, arm), encoding='utf-8')
            env = dict(os.environ)
            if injection:
                libraries = [env.get('BABET_TEST_ASAN_RUNTIME', ''), str(preload),
                             env.get('LD_PRELOAD', '')]
                env.update(LD_PRELOAD=':'.join(p for p in libraries if p),
                           BABET_TEST_WRITE_MODE=injection,
                           BABET_TEST_WRITE_ARM=str(arm),
                           BABET_TEST_WRITE_MARKER=str(marker))
            try:
                result = subprocess.run([str(binary), str(script)], env=env,
                                        capture_output=True, text=True, timeout=20)
                assert result.returncode == 0, (
                    f'{name}: exit {result.returncode}\n' + result.stdout + result.stderr)
                if injection:
                    assert marker.exists(), f'{name}: transport injection did not run'
            finally:
                thread.join(9)
            assert not thread.is_alive() and not errors, f'{name}: server errors {errors}'
            passes += 1
            print(f'[PASS] {name}', flush=True)

        def upgrade(conn):
            request = b''
            while b'\r\n\r\n' not in request:
                data = conn.recv(4096)
                assert data, 'missing WebSocket opening request'
                request += data
            key_line = next(line for line in request.split(b'\r\n')
                            if line.lower().startswith(b'sec-websocket-key:'))
            accept = base64.b64encode(hashlib.sha1(key_line.split(b':', 1)[1].strip()
                + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                         b'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')

        def drain(conn):
            data = b''
            while True:
                part = conn.recv(65536)
                if not part:
                    return data
                data += part

        cases = [('tls', m) for m in ('no-progress', 'partial', 'partial-interrupt',
                                      'fatal', 'before-write')]
        for protocol in ('ws', 'wss'):
            cases.extend((protocol, m) for m in ('no-progress', 'partial',
                          'partial-interrupt', 'fatal', 'ping', 'pong'))
        cases.append(('ws', 'after-fragment'))
        for protocol, mode in cases:
            fault = 'partial' if mode in ('ping', 'pong') else mode
            websocket = protocol != 'tls'

            def serve(conn):
                if websocket:
                    upgrade(conn)
                    if mode == 'pong':
                        conn.sendall(b'\x89\x01p')
                data = drain(conn)
                if mode == 'before-write':
                    assert data == b'SECOND', repr(data)
                if mode == 'after-fragment':
                    assert len(data) == 14 + 65536 and data[0] == 2, (
                        'expected exactly one unfinished 64 KiB binary fragment')
                if protocol == 'ws' and fault in ('partial', 'partial-interrupt'):
                    assert len(data) == 1, 'extra bytes sent after abandoned frame'
                if protocol == 'ws' and fault in ('no-progress', 'fatal'):
                    assert not data, 'unexpected bytes after zero-progress failure'

            def make_lua(port, arm):
                if websocket:
                    connect = f'babet.websocket.connect("{protocol}://127.0.0.1:{port}/", {{verify=false, timeout=2}})'
                    retry = 's:send_text("SECOND", 1)'
                    operation = ('s:ping("p", 1)' if mode == 'ping' else
                                 's:recv(1)' if mode == 'pong' else
                                 's:send_binary(string.rep("x", 131072), 1)')
                else:
                    connect = f'babet.socket.connect_tls("127.0.0.1", {port}, {{verify=false, timeout=2}})'
                    retry = 's:send("SECOND")'
                    operation = 's:send(string.rep("x", 32768))'
                code = f'local s = assert({connect})\n'
                code += 'assert(s:set_timeout(1))\n'
                if mode == 'partial-interrupt':
                    code += ('local hits=0\nassert(babet.signal.handle("USR1", function()\n'
                             f'  local value, err = {retry}\n'
                             '  assert(value == nil and err:find("closed", 1, true), err)\n'
                             '  hits=hits+1\nend))\n')
                code += f'local f=assert(io.open({quote(arm)}, "w")); f:close()\n'
                code += f'local value, err = {operation}\n'
                expected = 'interrupted' if mode == 'partial-interrupt' else 'timeout'
                code += ('assert(value == nil and type(err) == "string", tostring(err))\n'
                         if mode == 'fatal' else f'assert(value == nil and err == "{expected}", tostring(err))\n')
                # Disable injection: the second call must fail due to Babet's
                # state, not because the shim happens to keep rejecting writes.
                code += f'assert(os.remove({quote(arm)}))\n'
                code += f'local next_value, next_err = {retry}\n'
                if mode == 'before-write':
                    code += 'assert(next_value == 6, next_err)\n'
                else:
                    code += ('assert(next_value == nil and type(next_err) == "string"\n'
                             '  and next_err:find("closed", 1, true), tostring(next_err))\n')
                if mode == 'partial-interrupt':
                    code += 'assert(hits == 1, "callback did not see the closed transport")\n'
                code += 'assert(s:close())\nassert(s:close())\n'
                return code

            run_case(f'{protocol}-send-{mode}', protocol != 'ws', make_lua, serve, fault)

        # All receive fixtures seed recv_pending with the real recv_all API.
        # A size limit one byte below the payload makes the test independent
        # of packet/record boundaries and leaves every byte in that buffer.
        for tls in (False, True):
            protocol = 'tls' if tls else 'tcp'
            for mode in ('mixed-lines', 'timeout-lines', 'split-crlf-eof',
                         'exact-limit', 'over-limit-line', 'over-limit-prefix'):
                payload = {
                    'mixed-lines': b'one\r\ntwo\n\nA\0B\r\nrest',
                    'timeout-lines': b'one\ntwo\ntail',
                    'split-crlf-eof': b'split\r',
                }.get(mode)
                if payload is None:
                    payload = b'x' * (LIMIT + (mode != 'exact-limit'))
                    if mode != 'over-limit-prefix':
                        payload += b'\nkept\n'

                def serve(conn):
                    conn.sendall(payload)
                    assert conn.recv(1) == b'A', 'missing client acknowledgement'
                    if mode == 'split-crlf-eof':
                        conn.sendall(b'\nTAIL')
                    if tls:
                        conn.unwrap().close()
                    else:
                        conn.shutdown(socket.SHUT_WR)

                def make_lua(port, arm):
                    connect = (f'babet.socket.connect_tls("127.0.0.1", {port}, {{verify=false, timeout=3}})'
                               if tls else f'babet.socket.connect("127.0.0.1", {port})')
                    code = f'local s=assert({connect})\n'
                    if mode == 'timeout-lines':
                        code += 'local value, err=s:recv_all(.2)\nassert(value == nil and err == "timeout", err)\n'
                    else:
                        code += f'local value, err=s:recv_all(5, {len(payload)-1})\n'
                        code += 'assert(value == nil and err:find("max_bytes", 1, true), err)\n'
                    if mode == 'mixed-lines':
                        code += ('assert(s:recv_line(.1) == "one")\n'
                                 'assert(s:recv_line(.1) == "two")\n'
                                 'assert(s:recv_line(.1) == "")\n'
                                 'assert(s:recv_line(.1) == "A\\0B")\n'
                                 'assert(s:recv(4, .1) == "rest")\n')
                    elif mode == 'timeout-lines':
                        code += ('assert(s:recv_line(.1) == "one")\n'
                                 'assert(s:recv_line(.1) == "two")\n'
                                 'assert(s:recv(4, .1) == "tail")\n')
                    elif mode == 'exact-limit':
                        code += (f'local line=assert(s:recv_line(.1))\nassert(#line == {LIMIT})\n'
                                 'assert(s:recv_line(.1) == "kept")\n')
                    elif mode.startswith('over-limit'):
                        code += 'local line, why=s:recv_line(.1)\nassert(line == nil and why == "line too long", why)\n'
                        if mode == 'over-limit-line':
                            code += 'assert(s:recv_line(.1) == "kept")\n'
                    code += 'assert(s:send("A") == 1)\n'
                    if mode == 'split-crlf-eof':
                        code += 'assert(s:recv_line(2) == "split")\n'
                    code += 'local last, why, partial=s:recv_line(2)\n'
                    expected = 'TAIL' if mode == 'split-crlf-eof' else ''
                    code += f'assert(last == nil and why == "closed" and partial == "{expected}", why)\n'
                    code += 'assert(s:close())\n'
                    return code

                run_case(f'{protocol}-buffer-{mode}', tls, make_lua, serve)

        # Validation errors occur before committing any WebSocket frame.
        for tls in (False, True):
            protocol = 'wss' if tls else 'ws'

            def serve(conn):
                upgrade(conn)
                wire = drain(conn)
                assert len(wire) == 8 and wire[:2] == b'\x81\x82'
                assert bytes(wire[6+i] ^ wire[2+i] for i in range(2)) == b'OK'

            def make_lua(port, arm):
                return f'''local s=assert(babet.websocket.connect("{protocol}://127.0.0.1:{port}/", {{verify=false, timeout=2, max_message_bytes=8, max_frame_bytes=8}}))
local value, err=s:send_text(string.char(255))
assert(value == nil and err:find("UTF-8", 1, true), err)
value, err=s:send_binary(string.rep("x", 9))
assert(value == nil and err:find("max_message_bytes", 1, true), err)
assert(s:send_text("OK") == 2)
s=nil; collectgarbage("collect")
'''
            run_case(f'{protocol}-validation-keeps-connection', tls, make_lua, serve)
    print(f'network recovery runtime: {passes} PASS / 0 FAIL', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f'[FAIL] network recovery runtime: {error}', file=sys.stderr)
        raise SystemExit(1)
