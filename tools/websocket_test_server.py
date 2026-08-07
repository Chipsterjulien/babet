#!/usr/bin/env python3
import argparse
import base64
import hashlib
import socket
import ssl
import struct
from pathlib import Path

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_exact(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        data.extend(chunk)
    return bytes(data)


def recv_http(sock):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("EOF during handshake")
        data.extend(chunk)
        if len(data) > 65536:
            raise RuntimeError("handshake too large")
    head, rest = bytes(data).split(b"\r\n\r\n", 1)
    lines = head.decode("ascii").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, value = line.split(":", 1)
        headers[name.lower()] = value.strip()
    return lines[0], headers, rest


def handshake(sock, bad_accept=False, extra_header=None, malformed_upgrade=False):
    request, headers, rest = recv_http(sock)
    if not request.startswith("GET ") or not request.endswith(" HTTP/1.1"):
        raise RuntimeError("bad request line")
    if headers.get("upgrade", "").lower() != "websocket":
        raise RuntimeError("missing Upgrade")
    if "upgrade" not in headers.get("connection", "").lower():
        raise RuntimeError("missing Connection upgrade")
    if headers.get("sec-websocket-version") != "13":
        raise RuntimeError("bad WebSocket version")
    key = headers.get("sec-websocket-key")
    if not key:
        raise RuntimeError("missing key")
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
    if bad_accept:
        accept = "invalid-accept"
    upgrade_line = "Upgrade : websocket\r\n" if malformed_upgrade else "Upgrade: websocket\r\n"
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        + upgrade_line
        + "Connection: Upgrade\r\n"
        + f"Sec-WebSocket-Accept: {accept}\r\n"
        + (extra_header or "")
        + "\r\n"
    ).encode("ascii")
    sock.sendall(response)
    return rest


def read_frame(sock, pending=b""):
    def take(n):
        nonlocal pending
        if len(pending) >= n:
            out, pending = pending[:n], pending[n:]
            return out
        out = pending
        pending = b""
        return out + recv_exact(sock, n - len(out))

    first = take(2)
    b0, b1 = first
    fin = bool(b0 & 0x80)
    opcode = b0 & 0x0F
    masked = bool(b1 & 0x80)
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack("!H", take(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", take(8))[0]
    mask = take(4) if masked else b""
    payload = bytearray(take(length))
    if masked:
        for i in range(len(payload)):
            payload[i] ^= mask[i % 4]
    return fin, opcode, masked, bytes(payload), pending


def read_message(sock, pending=b""):
    data = bytearray()
    initial = None
    frame_count = 0
    while True:
        fin, opcode, masked, payload, pending = read_frame(sock, pending)
        frame_count += 1
        if not masked:
            raise RuntimeError("client frame was not masked")
        if opcode in (0x8, 0x9, 0xA):
            return opcode, payload, frame_count, pending
        if opcode in (0x1, 0x2):
            if initial is not None:
                raise RuntimeError("unexpected new data frame")
            initial = opcode
        elif opcode != 0x0 or initial is None:
            raise RuntimeError("bad continuation")
        data.extend(payload)
        if fin:
            return initial, bytes(data), frame_count, pending


def send_frame(sock, opcode, payload=b"", fin=True, masked=False):
    first = (0x80 if fin else 0) | opcode
    length = len(payload)
    second_mask = 0x80 if masked else 0
    if length <= 125:
        header = bytes([first, second_mask | length])
    elif length <= 0xFFFF:
        header = bytes([first, second_mask | 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, second_mask | 127]) + struct.pack("!Q", length)
    if masked:
        key = b"ABCD"
        transformed = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
        sock.sendall(header + key + transformed)
    else:
        sock.sendall(header + payload)


def close_code(payload):
    if len(payload) < 2:
        return None
    return struct.unpack("!H", payload[:2])[0]


def run_roundtrip(conn, pending):
    opcode, payload, frame_count, pending = read_message(conn, pending)
    if opcode != 0x1 or payload != b"x" * 70000:
        raise RuntimeError("client text message mismatch")
    if frame_count < 2:
        raise RuntimeError("large client text was not fragmented")

    send_frame(conn, 0x1, b"hello ", fin=False)
    send_frame(conn, 0x9, b"probe")
    send_frame(conn, 0x0, b"world", fin=True)

    opcode, payload, _, pending = read_message(conn, pending)
    if opcode != 0xA or payload != b"probe":
        raise RuntimeError("automatic Pong mismatch")

    send_frame(conn, 0x2, b"\x00\x01\xff")

    opcode, payload, _, pending = read_message(conn, pending)
    if opcode != 0x9 or payload != b"client-ping":
        raise RuntimeError("client Ping mismatch")
    send_frame(conn, 0xA, payload)

    opcode, payload, _, pending = read_message(conn, pending)
    if opcode != 0x8 or close_code(payload) != 1000:
        raise RuntimeError("client Close mismatch")
    send_frame(conn, 0x8, payload)


def run_masked_server(conn, pending):
    send_frame(conn, 0x1, b"bad", masked=True)
    opcode, payload, _, _ = read_message(conn, pending)
    if opcode != 0x8 or close_code(payload) != 1002:
        raise RuntimeError("client did not close masked server frame with 1002")


def run_oversize(conn, pending):
    # Control frames keep their RFC 125-byte ceiling independently of the
    # application's max_frame_bytes. This Ping is deliberately larger than
    # the client's 32-byte data-frame cap and must still be answered.
    probe = b"p" * 64
    send_frame(conn, 0x9, probe)
    opcode, payload, _, pending = read_message(conn, pending)
    if opcode != 0xA or payload != probe:
        raise RuntimeError("control frame was incorrectly constrained by max_frame_bytes")

    conn.sendall(bytes([0x81, 126]) + struct.pack("!H", 1024))
    opcode, payload, _, _ = read_message(conn, pending)
    if opcode != 0x8 or close_code(payload) != 1009:
        raise RuntimeError("client did not close oversized frame with 1009")


def run_invalid_close_utf8(conn, pending):
    send_frame(conn, 0x8, struct.pack("!H", 1000) + b"\xff")
    opcode, payload, _, _ = read_message(conn, pending)
    if opcode != 0x8 or close_code(payload) != 1007:
        raise RuntimeError("client did not close invalid UTF-8 reason with 1007")


def run_secure(conn, pending):
    send_frame(conn, 0x1, b"secure")
    opcode, payload, _, _ = read_message(conn, pending)
    if opcode != 0x8 or close_code(payload) != 1000:
        raise RuntimeError("secure client Close mismatch")
    send_frame(conn, 0x8, payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True,
                        choices=["roundtrip", "bad-handshake", "unsolicited-extension", "unsolicited-protocol", "malformed-header", "masked-server", "oversize", "invalid-close-utf8", "secure"])
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--cert")
    parser.add_argument("--key")
    args = parser.parse_args()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    Path(args.port_file).write_text(str(listener.getsockname()[1]), encoding="ascii")

    conn, _ = listener.accept()
    listener.close()
    conn.settimeout(8)
    if args.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        conn = context.wrap_socket(conn, server_side=True)
    try:
        extra_header = None
        if args.mode == "unsolicited-extension":
            extra_header = "Sec-WebSocket-Extensions: permessage-deflate\r\n"
        elif args.mode == "unsolicited-protocol":
            extra_header = "Sec-WebSocket-Protocol: bidi-test\r\n"
        pending = handshake(
            conn,
            bad_accept=args.mode == "bad-handshake",
            extra_header=extra_header,
            malformed_upgrade=args.mode == "malformed-header",
        )
        if args.mode == "roundtrip":
            run_roundtrip(conn, pending)
        elif args.mode == "masked-server":
            run_masked_server(conn, pending)
        elif args.mode == "oversize":
            run_oversize(conn, pending)
        elif args.mode == "invalid-close-utf8":
            run_invalid_close_utf8(conn, pending)
        elif args.mode == "secure":
            run_secure(conn, pending)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
