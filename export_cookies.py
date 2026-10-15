#!/usr/bin/env python3
"""Print one Chromium browser profile's live cookies as JSON on stdout.

usage: export_cookies.py --data DATA --keychain SERVICE PROFILE_DIR (HOST | --all) [--summary]

DATA is a relative directory under ~/Library/Application Support; SERVICE is
the browser's Safe Storage Keychain item. Reads the profile's `Cookies`
SQLite file (a copy in a private temporary directory, since the browser keeps
it locked) and decrypts values with that Keychain key; macOS may ask the user
to allow the read. The Keychain is read only when there is at least one live
encrypted cookie to decrypt. Nothing is written to disk except the temporary
database copy, removed on exit.

With HOST, only cookies of HOST's site are exported (HOST and its
parent/sibling subdomains: ai.example.com -> everything under example.com).
With --all, every live cookie of the profile is exported; a profile folder
that has no Cookies database yet (a fresh profile) exports [].

Each cookie is {name, value, domain, path, expires?, httpOnly, secure,
sameSite?} -- the shape of Tern's browser `setCookie` op. With --summary
only the per-domain cookie counts are printed, never a value.
"""
import argparse
import contextlib
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
import time

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


def decrypted(key, enc, host, hashed):
    """A cookie's value from its `encrypted_value`, or None when it cannot be
    decrypted with `key` (another scheme, a wrong key, a foreign host)."""
    if enc[:3] != b"v10":
        return None
    plain = decrypt(key, enc[3:])
    if plain is None:
        return None
    if hashed:
        if plain[:32] != hashlib.sha256(host.encode()).digest():
            return None
        plain = plain[32:]
    try:
        return plain.decode()
    except UnicodeDecodeError:
        return None


def database(data, profile):
    """The profile's Cookies database path, or None when the profile folder
    exists but has none yet. A missing profile folder is an error."""
    folder = os.path.join(os.path.expanduser("~/Library/Application Support"), data, profile)
    if not os.path.isdir(folder):
        fail("no %s profile %r" % (data, profile))
    for rel in ("Network/Cookies", "Cookies"):
        path = os.path.join(folder, rel)
        if os.path.isfile(path):
            return path
    return None


def read_rows(src):
    """(hashed, rows) from a private temporary copy of the Cookies database
    and its WAL sidecars; the copy is closed and removed before returning."""
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "Cookies")
        shutil.copyfile(src, copy)
        for suffix in ("-wal", "-shm"):
            if os.path.isfile(src + suffix):
                shutil.copyfile(src + suffix, copy + suffix)
        with contextlib.closing(sqlite3.connect(copy)) as db:
            row = db.execute("select value from meta where key = 'version'").fetchone()
            hashed = row is not None and int(row[0]) >= HOST_HASH_META_VERSION
            rows = db.execute(
                "select host_key, name, value, encrypted_value, path, expires_utc,"
                " is_secure, is_httponly, samesite, has_expires from cookies"
            ).fetchall()
    return hashed, rows


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


def emit(cookies, undecryptable, summary):
    if summary:
        counts = {}
        for c in cookies:
            counts[c["domain"]] = counts.get(c["domain"], 0) + 1
        json.dump({"total": len(cookies), "undecryptable": undecryptable, "domains": counts}, sys.stdout)
    else:
        json.dump(cookies, sys.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, help="browser data directory under ~/Library/Application Support")
    parser.add_argument("--keychain", required=True, help="browser Keychain service")
    parser.add_argument("profile", metavar="PROFILE_DIR")
    parser.add_argument("host", metavar="HOST", nargs="?", help="export only this host's site")
    parser.add_argument("--all", action="store_true", help="export every site's cookies")
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
    if args.all and args.host is not None:
        parser.error("give either HOST or --all, not both")
    if not args.all and args.host is None:
        parser.error("give HOST to export one site, or --all for every site")
    site = None
    if not args.all:
        if not re.fullmatch(r"[A-Za-z0-9.-]+", args.host):
            parser.error("HOST must contain only letters, digits, '.' or '-'")
        site = site_of(args.host)

    src = database(args.data, args.profile)
    if src is None:
        if site is not None:
            fail("no Cookies database in %s profile %r" % (args.data, args.profile))
        emit([], 0, args.summary)  # a fresh profile has no cookies yet
        return
    hashed, rows = read_rows(src)

    # Keep only this site's live cookies before touching the Keychain, so a
    # profile with nothing to decrypt never prompts for the key.
    now = time.time()
    live = []
    for r in rows:
        if site is not None and not in_site(r[0], site):
            continue
        has_expires, expires_utc = r[9], r[5]
        expires = None
        if has_expires and expires_utc:
            expires = expires_utc / 1e6 - EPOCH_DELTA
            if expires <= now:
                continue
        live.append((r, expires))
    key = keychain_key(args.keychain) if any(r[3] for r, _ in live) else None

    cookies = []
    undecryptable = decrypted_count = 0
    for (host, name, value, enc, path, _, secure, httponly, samesite, _), expires in live:
        if enc:
            value = decrypted(key, enc, host, hashed)
            if value is None:
                undecryptable += 1
                continue
            decrypted_count += 1
        cookie = {
            "name": name, "value": value, "domain": host, "path": path or "/",
            "httpOnly": bool(httponly), "secure": bool(secure),
        }
        if expires is not None:
            cookie["expires"] = int(expires)
        same_site = SAMESITE.get(samesite)
        if same_site is not None and not (same_site == "None" and not secure):
            cookie["sameSite"] = same_site
        cookies.append(cookie)

    # A wrong Keychain item or a newer encryption scheme decrypts nothing;
    # importing only the few plain cookies would look like a sign-in that
    # silently did not work, so say so instead.
    if undecryptable and not decrypted_count:
        fail(
            "none of the %d live %s cookies could be decrypted with the %s key"
            % (undecryptable, site or "profile", args.keychain)
        )

    emit(cookies, undecryptable, args.summary)


main()
