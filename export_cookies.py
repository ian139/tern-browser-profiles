#!/usr/bin/env python3
"""Print one Chromium browser profile's live cookies as JSON on stdout.

usage: export_cookies.py --data DATA --keychain SERVICE PROFILE_DIR HOST [--summary]

DATA is a relative directory under ~/Library/Application Support; SERVICE is
the browser's Safe Storage Keychain item. Reads the profile's `Cookies`
SQLite file (a copy, since the browser keeps it locked) and decrypts values
with that Keychain key; macOS asks the user to allow the read. Nothing is
written to disk except a temporary database copy, removed on exit.

Only cookies of HOST's site are exported (HOST and its parent/sibling
subdomains: ai.example.com -> everything under example.com).

Each cookie is {name, value, domain, path, expires?, httpOnly, secure,
sameSite?} -- the shape of Tern's browser `setCookie` op. With --summary
only the per-domain cookie counts are printed, never a value.
"""
import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

EPOCH_DELTA = 11644473600  # seconds from 1601-01-01 to 1970-01-01
SAMESITE = {0: "None", 1: "Lax", 2: "Strict"}  # -1 (unspecified) is omitted
HOST_HASH_META_VERSION = 24  # from here the plaintext is prefixed by sha256(host_key)
GENERIC_SECOND_LEVEL = {"co", "com", "org", "net", "gov", "edu", "ac"}

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
libc.CCCrypt.argtypes = [
    ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
    ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
    ctypes.c_char_p, ctypes.c_size_t,
    ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t),
]
libc.CCCrypt.restype = ctypes.c_int


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


def keychain_key(service):
    r = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-w", "-s", service],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        fail("Keychain refused the %s key (%d): %s" % (service, r.returncode, r.stderr.strip()))
    return hashlib.pbkdf2_hmac("sha1", r.stdout.strip().encode(), b"saltysalt", 1003, 16)


def decrypt(key, blob):
    out = ctypes.create_string_buffer(len(blob))
    moved = ctypes.c_size_t()
    # kCCDecrypt=1, kCCAlgorithmAES=0, kCCOptionPKCS7Padding=1 (CBC by default)
    status = libc.CCCrypt(1, 0, 1, key, 16, b" " * 16, blob, len(blob), out, len(blob), ctypes.byref(moved))
    if status != 0:
        return None
    return out.raw[: moved.value]


def database(data, profile):
    base = os.path.expanduser("~/Library/Application Support")
    for rel in ("Network/Cookies", "Cookies"):
        path = os.path.join(base, data, profile, rel)
        if os.path.isfile(path):
            return path
    fail("no Cookies database in %s profile %r" % (data, profile))


def site_of(host):
    """The site a host belongs to: its last two labels, three under a two-letter
    country code with a generic second level (example.co.uk). A heuristic, not
    the public suffix list; a site it gets wrong just matches too few or too
    many sibling subdomains."""
    labels = host.lower().strip(".").split(".")
    if len(labels) <= 2 or re.fullmatch(r"\d+(\.\d+){3}", host):
        return host.lower().strip(".")
    n = 3 if len(labels[-1]) == 2 and labels[-2] in GENERIC_SECOND_LEVEL else 2
    return ".".join(labels[-n:])


def in_site(cookie_host, site):
    h = cookie_host.lower().lstrip(".")
    return h == site or h.endswith("." + site)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, help="browser data directory under ~/Library/Application Support")
    parser.add_argument("--keychain", required=True, help="browser Keychain service")
    parser.add_argument("profile", metavar="PROFILE_DIR")
    parser.add_argument("host", metavar="HOST")
    parser.add_argument("--summary", action="store_true", help="print counts instead of cookie values")
    args = parser.parse_args()
    if os.path.isabs(args.data) or any(
        part in (".", "..") or not re.fullmatch(r"[A-Za-z0-9 ._-]+", part)
        for part in args.data.split("/")
    ):
        parser.error("--data must be a relative path of safe components, without '.' or '..'")
    if not re.fullmatch(r"[A-Za-z0-9 ._-]+", args.keychain):
        parser.error("--keychain must contain only letters, digits, spaces, '.', '_' or '-'")
    if not re.fullmatch(r"[A-Za-z0-9 _-]+", args.profile):
        parser.error("PROFILE_DIR must contain only letters, digits, spaces, '_' or '-'")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", args.host):
        parser.error("HOST must contain only letters, digits, '.' or '-'")
    site = site_of(args.host)
    src = database(args.data, args.profile)
    key = keychain_key(args.keychain)

    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "Cookies")
        shutil.copy2(src, copy)
        for suffix in ("-wal", "-shm"):
            if os.path.isfile(src + suffix):
                shutil.copy2(src + suffix, copy + suffix)
        db = sqlite3.connect(copy)
        row = db.execute("select value from meta where key = 'version'").fetchone()
        hashed = row is not None and int(row[0]) >= HOST_HASH_META_VERSION
        rows = db.execute(
            "select host_key, name, value, encrypted_value, path, expires_utc,"
            " is_secure, is_httponly, samesite, has_expires from cookies"
        ).fetchall()
        db.close()

    rows = [r for r in rows if in_site(r[0], site)]
    import time
    now = time.time()
    cookies = []
    for host, name, value, enc, path, expires_utc, secure, httponly, samesite, has_expires in rows:
        if enc:
            if enc[:3] != b"v10":
                continue
            plain = decrypt(key, enc[3:])
            if plain is None:
                continue
            if hashed:
                if plain[:32] != hashlib.sha256(host.encode()).digest():
                    continue
                plain = plain[32:]
            try:
                value = plain.decode()
            except UnicodeDecodeError:
                continue
        expires = None
        if has_expires and expires_utc:
            expires = expires_utc / 1e6 - EPOCH_DELTA
            if expires <= now:
                continue
        cookie = {
            "name": name, "value": value, "domain": host, "path": path or "/",
            "httpOnly": bool(httponly), "secure": bool(secure),
        }
        if expires is not None:
            cookie["expires"] = int(expires)
        site = SAMESITE.get(samesite)
        if site is not None and not (site == "None" and not secure):
            cookie["sameSite"] = site
        cookies.append(cookie)

    if args.summary:
        counts = {}
        for c in cookies:
            counts[c["domain"]] = counts.get(c["domain"], 0) + 1
        json.dump({"total": len(cookies), "skipped": len(rows) - len(cookies), "domains": counts}, sys.stdout)
    else:
        json.dump(cookies, sys.stdout)


main()
