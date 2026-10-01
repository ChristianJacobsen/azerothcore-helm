#!/usr/bin/env python3
"""Log in to an AzerothCore authserver as a 3.3.5a client and print the realm list.

Runs the SRP6 logon challenge and proof, checks the server proof, and reads
the realm list. With --check-world, it also reads the worldserver greeting
from each online realm address. Exits with 1 on any failure. The chart's
helm test calls it with --expect-online.
"""
import argparse
import hashlib
import os
import secrets
import socket
import struct
import sys

# From src/common/Cryptography/Authentication/SRP6.cpp.
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
G = 7
K_MULT = 3
KEY_BYTES = 32
SHA1_BYTES = 20
EPHEMERAL_BITS = 19 * 8

CLIENT_VERSION = (3, 3, 5)
CLIENT_BUILD = 12340
PROTOCOL_VERSION = 0x08
TIMEZONE_BIAS_MINUTES = 60
CLIENT_IP = 0x0100007F            # 127.0.0.1, little-endian

# Opcodes and field sizes from src/server/apps/authserver/Server/AuthSession.cpp.
CMD_AUTH_LOGON_CHALLENGE = 0x00
CMD_AUTH_LOGON_PROOF = 0x01
CMD_REALM_LIST = 0x10
AUTH_LOGON_SUCCESS = 0x00
VERSION_CHALLENGE_BYTES = 16
REALM_LIST_REQUEST_PADDING = 4
REALM_LIST_HEADER_BYTES = 4       # uint32 unused, before the realm count
REALM_FLAG_OFFLINE = 0x02
REALM_FLAG_SPECIFYBUILD = 0x04
PROOF_NUMBER_OF_KEYS = 0
SECURITY_FLAGS_NONE = 0x00
CHALLENGE_REPLY = struct.Struct("<BBB")       # cmd, unused, result
PROOF_REPLY = struct.Struct("<BB")            # cmd, error
PROOF_TRAILER = struct.Struct("<IIH")         # account flags, survey id, login flags
REALM_LIST_SIZE = struct.Struct("<H")
REALM_COUNT = struct.Struct("<H")
REALM_HEAD = struct.Struct("<BBB")            # icon, lock, flags
REALM_ENTRY_TAIL = struct.Struct("<fBBB")     # population, characters, timezone, id
REALM_BUILD = struct.Struct("<BBBH")          # major, minor, bugfix, build

# Worldserver greeting (src/server/game/Server/WorldSocket.cpp): header with
# the size (opcode + payload) and the opcode, then 1, the seed and two
# encryption seeds.
SMSG_AUTH_CHALLENGE = 0x1EC
WORLD_OPCODE_BYTES = 2
WORLD_HEADER_FIELD_BYTES = 2
WORLD_CHALLENGE = struct.Struct("<II32s")

LOGON_RESULTS = {
    0x00: "success",
    0x03: "account banned",
    0x04: "unknown account or wrong password",
    0x06: "account in use",
    0x09: "wrong client build",
    0x0C: "account suspended",
    0x0D: "no access",
}

DEFAULT_TIMEOUT_SECONDS = 10.0
DEFAULT_AUTH_PORT = 3724


def key(n: int) -> bytes:
    """A number as the core's 32-byte little-endian arrays (EphemeralKey, Salt)."""
    return n.to_bytes(KEY_BYTES, "little")


def sha1(*parts: bytes) -> bytes:
    h = hashlib.sha1()
    for p in parts:
        h.update(p)
    return h.digest()


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError(f"connection closed after {len(buf)} of {n} bytes")
        buf += chunk
    return buf


def recv_u8(sock: socket.socket) -> int:
    return recv_exact(sock, 1)[0]


def read_cstring(data: bytes, pos: int):
    end = data.index(b"\x00", pos)
    return data[pos:end].decode("utf-8", "replace"), end + 1


def challenge_packet(username: str) -> bytes:
    user = username.encode()
    body = (
        b"WoW\x00"
        + bytes(CLIENT_VERSION)
        + struct.pack("<H", CLIENT_BUILD)
        + b"68x\x00"          # "x86", reversed as the client sends it
        + b"niW\x00"          # "Win"
        + b"SUne"             # "enUS"
        + struct.pack("<I", TIMEZONE_BIAS_MINUTES)
        + struct.pack("<I", CLIENT_IP)
        + bytes([len(user)])
        + user
    )
    return bytes([CMD_AUTH_LOGON_CHALLENGE, PROTOCOL_VERSION]) + struct.pack("<H", len(body)) + body


def session_key(S: bytes) -> bytes:
    """SRP6::SHA1Interleave, which skips the leading zero bytes of S."""
    p = 0
    while p < len(S) and not S[p]:
        p += 1
    if p & 1:
        p += 1
    p //= 2
    even = sha1(S[0::2][p:])
    odd = sha1(S[1::2][p:])
    return bytes(b for pair in zip(even, odd) for b in pair)


def login(host: str, port: int, username: str, password: str, timeout: float):
    username = username.upper()
    password = password.upper()
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    try:
        sock.sendall(challenge_packet(username))
        cmd, _, result = CHALLENGE_REPLY.unpack(recv_exact(sock, CHALLENGE_REPLY.size))
        if cmd != CMD_AUTH_LOGON_CHALLENGE:
            raise RuntimeError(f"unexpected reply to the logon challenge: cmd {cmd:#x}")
        if result != AUTH_LOGON_SUCCESS:
            raise RuntimeError(f"logon challenge refused: {LOGON_RESULTS.get(result, hex(result))}")
        B = recv_exact(sock, KEY_BYTES)
        g = int.from_bytes(recv_exact(sock, recv_u8(sock)), "little")
        n = int.from_bytes(recv_exact(sock, recv_u8(sock)), "little")
        salt = recv_exact(sock, KEY_BYTES)
        recv_exact(sock, VERSION_CHALLENGE_BYTES)
        security_flags = recv_u8(sock)
        if (g, n) != (G, N):
            raise RuntimeError("the server uses unknown SRP6 parameters")
        if security_flags:
            raise RuntimeError(f"the account needs a PIN or token (security flags {security_flags:#x})")

        # The client side of SRP6::VerifyChallengeResponse in the core.
        a = secrets.randbits(EPHEMERAL_BITS) | 1
        A = key(pow(G, a, N))
        u = int.from_bytes(sha1(A, B), "little")
        x = int.from_bytes(sha1(salt, sha1(f"{username}:{password}".encode())), "little")
        S = key(pow((int.from_bytes(B, "little") - K_MULT * pow(G, x, N)) % N, a + u * x, N))
        K = session_key(S)
        ng = bytes(x1 ^ x2 for x1, x2 in zip(sha1(key(N)), sha1(bytes([G]))))
        M1 = sha1(ng, sha1(username.encode()), salt, A, B, K)

        # The version hash stays empty: StrictVersionCheck is off by default.
        proof = (bytes([CMD_AUTH_LOGON_PROOF]) + A + M1 + bytes(SHA1_BYTES)
                 + bytes([PROOF_NUMBER_OF_KEYS, SECURITY_FLAGS_NONE]))
        sock.sendall(proof)
        cmd, error = PROOF_REPLY.unpack(recv_exact(sock, PROOF_REPLY.size))
        if cmd != CMD_AUTH_LOGON_PROOF:
            raise RuntimeError(f"unexpected reply to the logon proof: cmd {cmd:#x}")
        if error != AUTH_LOGON_SUCCESS:
            raise RuntimeError(f"logon proof refused: {LOGON_RESULTS.get(error, hex(error))}")
        M2 = recv_exact(sock, SHA1_BYTES)
        recv_exact(sock, PROOF_TRAILER.size)
        if M2 != sha1(A, M1, K):
            raise RuntimeError("the server proof does not match")

        sock.sendall(bytes([CMD_REALM_LIST]) + bytes(REALM_LIST_REQUEST_PADDING))
        cmd = recv_u8(sock)
        if cmd != CMD_REALM_LIST:
            raise RuntimeError(f"unexpected reply to the realm list request: cmd {cmd:#x}")
        (size,) = REALM_LIST_SIZE.unpack(recv_exact(sock, REALM_LIST_SIZE.size))
        data = recv_exact(sock, size)
    finally:
        sock.close()

    (count,) = REALM_COUNT.unpack_from(data, REALM_LIST_HEADER_BYTES)
    pos = REALM_LIST_HEADER_BYTES + REALM_COUNT.size
    realms = []
    for _ in range(count):
        _icon, _lock, flags = REALM_HEAD.unpack_from(data, pos)
        pos += REALM_HEAD.size
        name, pos = read_cstring(data, pos)
        address, pos = read_cstring(data, pos)
        _population, chars, _timezone, _ = REALM_ENTRY_TAIL.unpack_from(data, pos)
        pos += REALM_ENTRY_TAIL.size
        if flags & REALM_FLAG_SPECIFYBUILD:
            pos += REALM_BUILD.size
        realms.append({"name": name, "address": address, "flags": flags, "characters": chars})
    return realms


def check_world(address: str, timeout: float) -> None:
    """Connect to a realm address and read SMSG_AUTH_CHALLENGE from the worldserver."""
    host, _, port = address.rpartition(":")
    with socket.create_connection((host, int(port)), timeout=timeout) as sock:
        sock.settimeout(timeout)
        # Server header: size (big-endian, includes the opcode), opcode (little-endian).
        size = struct.unpack(">H", recv_exact(sock, WORLD_HEADER_FIELD_BYTES))[0]
        opcode = struct.unpack("<H", recv_exact(sock, WORLD_HEADER_FIELD_BYTES))[0]
        if opcode != SMSG_AUTH_CHALLENGE or size != WORLD_OPCODE_BYTES + WORLD_CHALLENGE.size:
            raise RuntimeError(f"{address} sent opcode {opcode:#x} (size {size}), not the worldserver greeting")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--host", default=os.environ.get("AUTH_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("AUTH_PORT", DEFAULT_AUTH_PORT)))
    p.add_argument("--user", default=os.environ.get("AUTH_USERNAME", ""))
    p.add_argument("--password", default=os.environ.get("AUTH_PASSWORD", ""))
    p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    p.add_argument("--expect-online", action="store_true",
                   help="fail when no realm is online (worldserver not running)")
    p.add_argument("--check-world", action="store_true",
                   help="connect to each online realm address and read the worldserver greeting")
    args = p.parse_args()
    if not args.user or not args.password:
        print("error: set AUTH_USERNAME and AUTH_PASSWORD (or --user and --password)", file=sys.stderr)
        return 1
    try:
        realms = login(args.host, args.port, args.user, args.password, args.timeout)
    except Exception as e:  # noqa: BLE001
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"logged in as {args.user.upper()} at {args.host}:{args.port} with build {CLIENT_BUILD}")
    for r in realms:
        state = "offline" if r["flags"] & REALM_FLAG_OFFLINE else "online"
        print(f"realm {r['name']!r} at {r['address']}: {state}, {r['characters']} character(s)")
    online = [r for r in realms if not r["flags"] & REALM_FLAG_OFFLINE]
    if args.expect_online and not online:
        print("error: no realm is online", file=sys.stderr)
        return 1
    if args.check_world:
        for r in online:
            try:
                check_world(r["address"], args.timeout)
            except Exception as e:  # noqa: BLE001
                print(f"error: realm {r['name']!r}: {e}", file=sys.stderr)
                return 1
            print(f"worldserver answers at {r['address']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
