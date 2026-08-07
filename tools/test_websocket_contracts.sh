#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE="${PROJECT_DIR}/src/lua_bindings/websocket.cpp"
HEADER="${PROJECT_DIR}/src/lua_bindings/websocket.hpp"
MAIN="${PROJECT_DIR}/src/main.cpp"
SUITE="${PROJECT_DIR}/examples/selftest/suites/network/websocket.lua"
REGISTRY="${PROJECT_DIR}/examples/selftest/suites/network/init.lua"
RUNTIME="${PROJECT_DIR}/tools/test_websocket_runtime.sh"
SERVER="${PROJECT_DIR}/tools/websocket_test_server.py"

python3 - "${SOURCE}" "${HEADER}" "${MAIN}" "${SUITE}" "${REGISTRY}" "${RUNTIME}" "${SERVER}" <<'PY'
from pathlib import Path
import re
import sys

source, header, main, suite, registry, runtime, server = [Path(p).read_text(encoding="utf-8") for p in sys.argv[1:]]
checks = []
def check(name, condition): checks.append((name, bool(condition)))

check("WebSocket module is declared and registered",
      "register_websocket" in header and "register_websocket(L);" in main
      and 'lua_setfield(L, -2, "websocket")' in source)
check("all public WebSocket Lua calls use the C++ exception boundary",
      all(f"websocket_lua_boundary<{name}>" in source for name in [
          "websocket_connect", "ws_tostring", "ws_send_text",
          "ws_send_binary", "ws_recv", "ws_ping", "ws_close",
          "ws_set_timeout",
      ]))
check("WebSocket userdata owns resources before TCP/TLS acquisition",
      "push_empty_ws_protected" in source
      and "lua_build_results_protected(L, builder, 1)" in source
      and source.find("WebSocket *ws = push_empty_ws_protected(L);")
          < source.find("if (!connect_tcp(ws, url, deadline, err))")
      and 'lua_setfield(L, -2, "__gc")' in source)
check("connect accepts only ws and wss URL schemes case-insensitively",
      'starts_with_ascii_ci("ws://")' in source
      and 'starts_with_ascii_ci("wss://")' in source
      and "URL scheme must be ws:// or wss://" in source)
check("URL authority cannot inject HTTP headers",
      "URL authority contains an unescaped control or space" in source
      and "websocket rejects control bytes in authority" in suite)
check("client handshake uses RFC 6455 version 13 and GUID accept validation",
      "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" in source
      and "Sec-WebSocket-Version: 13" in source
      and "expected_accept" in source)
check("handshake response header names use strict HTTP token syntax",
      "valid_http_header_name" in source
      and "Do not trim the field-name" in source
      and "malformed HTTP response header" in source)
check("unsolicited extension and subprotocol fields fail closed on presence",
      re.search(r"if \(extensions\)\s*\{", source) is not None
      and re.search(r"if \(protocol\)\s*\{", source) is not None)
check("client masks every outgoing frame with fresh strong entropy",
      "RAND_bytes(mask.data()" in source
      and re.search(r"header\[header_size\+\+\] = static_cast<unsigned char>\(0x80U \|", source)
      and "mask[(offset + i) % mask.size()]" in source)
check("server masking and reserved RSV/opcodes are rejected",
      "server frames must not be masked" in source
      and "unsupported RSV bits" in source
      and "received reserved opcode" in source)
check("frame lengths require minimal RFC encoding and 63-bit bounds",
      "non-minimal frame length encoding" in source
      and "invalid 63-bit frame length" in source)
check("frame and message allocation limits are explicit and bounded",
      "DEFAULT_MAX_MESSAGE_BYTES" in source
      and "DEFAULT_MAX_FRAME_BYTES" in source
      and "MAX_CONFIGURED_BYTES" in source
      and "incoming frame exceeds max_frame_bytes" in source
      and "incoming message exceeds max_message_bytes" in source)
check("application frame caps do not disable RFC control frames",
      "if (!control && payload.size() > ws->max_frame_bytes)" in source
      and "if ((!control && length > ws->max_frame_bytes)" in source
      and "control frames have" in source)
check("fragmented messages and interleaved control frames are supported",
      "unexpected continuation frame" in source
      and "new data frame during fragmented message" in source
      and "frame.opcode == 0x9" in source
      and "send_frame(ws, 0xa" in source)
check("outgoing messages are fragmented into bounded frames",
      "SEND_FRAGMENT_BYTES" in source
      and "first ? opcode : 0x0" in source)
check("text and close reasons require valid UTF-8",
      "is_valid_utf8" in source
      and "text message is not valid UTF-8" in source
      and "close reason is not valid UTF-8" in source)
check("close codes and control payload limits are validated",
      "valid_close_code" in source
      and "payload.size() > 125" in source
      and "close reason exceeds 123 bytes" in source)
check("protocol and size failures send 1002/1007/1009 close codes",
      "fail_protocol(ws, 1002" in source
      and "fail_protocol(ws, 1007" in source
      and "fail_protocol(ws, 1009" in source
      and 'parse_error == "close reason is not valid UTF-8" ? 1007 : 1002' in source)
check("protocol failures half-close writes before releasing unread TCP data",
      "void shutdown_transport_write(WebSocket *ws) noexcept" in source
      and "::shutdown(ws->fd, SHUT_WR)" in source
      and re.search(r"const bool close_sent = send_close_payload\(ws, payload, deadline, ignored\);\s*if \(close_sent\)\s*shutdown_transport_write\(ws\);\s*close_transport\(ws\);", source) is not None)
check("WSS uses TLS 1.2 minimum and certificate identity verification",
      "TLS1_2_VERSION" in source and "SSL_set1_host" in source
      and "X509_VERIFY_PARAM_set1_ip_asc" in source
      and "SSL_VERIFY_PEER" in source)
check("WebSocket options are raw, strict and reject unknown fields",
      "lua_next(L, idx)" in source
      and "option names must be strings" in source
      and "unknown option" in source
      and "opts.max_frame_bytes must be <= max_message_bytes" in source)
check("Lua regression suite is reachable and covers workers",
      'test:run("selftest.suites.network.websocket")' in registry
      and "websocket rejects unknown options" in suite
      and "worker sees the websocket client API" in suite)
check("runtime regression covers framing, protocol errors and WSS",
      "ws round-trip covers masking, fragmentation, Ping/Pong, binary and Close" in runtime
      and "unsolicited WebSocket extension is rejected" in runtime
      and "unsolicited WebSocket subprotocol is rejected" in runtime
      and "malformed handshake header name is rejected" in runtime
      and "masked server frame is rejected" in runtime
      and "oversized announced frame is rejected" in runtime
      and "invalid UTF-8 Close reason is rejected with close code 1007" in runtime
      and "wss accepts a locally trusted certificate" in runtime)
check("runtime handshake negatives are served deterministically",
      "Sec-WebSocket-Extensions: permessage-deflate" in server
      and "Sec-WebSocket-Protocol: bidi-test" in server
      and "Upgrade : websocket" in server)
check("runtime server validates client masking and outgoing fragmentation",
      "client frame was not masked" in server
      and "large client text was not fragmented" in server
      and "automatic Pong mismatch" in server
      and "control frame was incorrectly constrained by max_frame_bytes" in server
      and "client did not close invalid UTF-8 reason with 1007" in server)

for name, passed in checks:
    print(f"[{'PASS' if passed else 'FAIL'}] {name}")
failed = [name for name, passed in checks if not passed]
if failed:
    raise SystemExit(1)
print(f"WebSocket structural contracts: {len(checks)} PASS / 0 FAIL")
PY
