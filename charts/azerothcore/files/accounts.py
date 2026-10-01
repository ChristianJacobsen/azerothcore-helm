#!/usr/bin/env python3
"""Print SQL that creates AzerothCore accounts from environment variables.

Input: ACCOUNT_<n>_USERNAME, ACCOUNT_<n>_PASSWORD and ACCOUNT_<n>_GMLEVEL for
n = 0, 1, 2, ... (the first missing username ends the list).

The SQL creates an account only when the username does not exist. It always
sets the GM level. It never changes the password of an account that exists,
because players can change their passwords in the game.

The verifier follows AccountMgr::CreateAccount and SRP6::CalculateVerifier in
the core. --self-test checks it against two accounts with known verifiers.
"""
import argparse
import hashlib
import os
import re
import secrets
import sys

# From src/common/Cryptography/Authentication/SRP6.cpp.
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
G = 7
SALT_BYTES = 32
VERIFIER_BYTES = 32
# From src/server/game/Accounts/AccountMgr.h. Names must also be plain
# SQL-safe text.
MAX_ACCOUNT_STR = 17
MAX_PASS_STR = 16
USERNAME_RE = re.compile(rf"^[A-Z0-9_-]{{1,{MAX_ACCOUNT_STR}}}$")
MAX_GMLEVEL = 3                     # SEC_ADMINISTRATOR
EXPANSION_WOTLK = 2
ALL_REALMS = -1


def verifier(username: str, password: str, salt: bytes) -> bytes:
    """Return the verifier for an upper-cased user and password."""
    digest = hashlib.sha1(f"{username}:{password}".encode("utf-8")).digest()
    # BigNumber reads byte arrays as little-endian numbers and writes them
    # back the same way.
    x = int.from_bytes(hashlib.sha1(salt + digest).digest(), "little")
    return pow(G, x, N).to_bytes(VERIFIER_BYTES, "little")


def self_test() -> None:
    # The default accounts of sql/base/realmd.sql in CMaNGOS, whose password
    # is the user name, in the byte order of AzerothCore.
    vectors = [
        ("ADMINISTRATOR",
         "05458F8255EE9E5B0C8A0769A80E99778ABBC061CF9970FA05D8A35A91DEB58E",
         "142C678BAB7D11A6FA54EFE61993085D1C16CE14D1793BB76B19C0F1EE992B31"),
        ("PLAYER",
         "81D8621314451DC5F276BADAFBD8381C6B336DA0EB7FCA61809BD894F13AA2EB",
         "91A83AD0E16D071998DEA70DEF501D5CCA976D0C9916C731D41F737C7EEC3837"),
    ]
    for user, salt, v in vectors:
        if verifier(user, user, bytes.fromhex(salt)) != bytes.fromhex(v):
            sys.exit(f"self-test failed for {user}")
    print("srp6 self-test passed", file=sys.stderr)


def accounts_sql() -> str:
    statements = []
    n = 0
    while True:
        prefix = f"ACCOUNT_{n}_"
        username = os.environ.get(prefix + "USERNAME", "")
        if not username:
            break
        password = os.environ.get(prefix + "PASSWORD", "")
        gmlevel = os.environ.get(prefix + "GMLEVEL", "0") or "0"

        # AccountMgr::CreateAccount upper-cases both values.
        username = username.upper()
        password = password.upper()
        if not USERNAME_RE.match(username):
            sys.exit(f"account {n}: username must match {USERNAME_RE.pattern}")
        if not password:
            sys.exit(f"account {n} ({username}): empty password")
        if len(password) > MAX_PASS_STR:
            sys.exit(f"account {n} ({username}): password longer than {MAX_PASS_STR} characters")
        if not gmlevel.isdigit() or int(gmlevel) > MAX_GMLEVEL:
            sys.exit(f"account {n} ({username}): gmlevel must be 0-{MAX_GMLEVEL}")

        salt = secrets.token_bytes(SALT_BYTES)
        v = verifier(username, password, salt)
        account_id = f"(SELECT id FROM account WHERE username = '{username}')"
        statements += [
            "INSERT INTO account (username, salt, verifier, expansion, joindate) "
            f"SELECT '{username}', UNHEX('{salt.hex()}'), UNHEX('{v.hex()}'), {EXPANSION_WOTLK}, NOW() FROM DUAL "
            f"WHERE NOT EXISTS (SELECT 1 FROM account WHERE username = '{username}');",
            # AccountMgr::UpdateAccountAccess with RealmID -1 works the same way.
            f"DELETE FROM account_access WHERE id = {account_id};",
        ]
        if int(gmlevel) > 0:
            statements.append(
                "INSERT INTO account_access (id, gmlevel, RealmID) "
                f"SELECT id, {int(gmlevel)}, {ALL_REALMS} FROM account WHERE username = '{username}';"
            )
        print(f"account {username}: gmlevel {gmlevel}", file=sys.stderr)
        n += 1
    if statements:
        # LOGIN_INS_REALM_CHARACTERS_INIT, which CreateAccount runs as well.
        statements.append(
            "INSERT INTO realmcharacters (realmid, acctid, numchars) "
            "SELECT realmlist.id, account.id, 0 FROM realmlist, account "
            "LEFT JOIN realmcharacters ON acctid = account.id WHERE acctid IS NULL;"
        )
    return "".join(s + "\n" for s in statements)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--output", help="write the SQL to this file instead of stdout")
    args = p.parse_args()
    self_test()
    if args.self_test:
        return
    sql = accounts_sql()
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(sql)
    else:
        sys.stdout.write(sql)


if __name__ == "__main__":
    main()
