#!/usr/bin/env python3
"""Build a disposable fake macOS browser tree from the adjacent spec.json."""

import base64
import ctypes
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import sqlite3
import sys


COOKIE_SCHEMA = """
CREATE TABLE cookies(
    creation_utc INTEGER NOT NULL,
    host_key TEXT NOT NULL,
    top_frame_site_key TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL,
    value TEXT NOT NULL,
    encrypted_value BLOB NOT NULL DEFAULT '',
    path TEXT NOT NULL,
    expires_utc INTEGER NOT NULL,
    is_secure INTEGER NOT NULL,
    is_httponly INTEGER NOT NULL,
    last_access_utc INTEGER NOT NULL,
    has_expires INTEGER NOT NULL DEFAULT 1,
    is_persistent INTEGER NOT NULL DEFAULT 1,
    priority INTEGER NOT NULL DEFAULT 1,
    samesite INTEGER NOT NULL DEFAULT -1,
    source_scheme INTEGER NOT NULL DEFAULT 0,
    source_port INTEGER NOT NULL DEFAULT -1,
    last_update_utc INTEGER NOT NULL DEFAULT 0
)
"""
EPOCH_DELTA = 11644473600
EXPIRES = {
    "future": (4102444800 + EPOCH_DELTA) * 1000000,
    "past": (978307200 + EPOCH_DELTA) * 1000000,
    None: 0,
}


def write_json(path, value):
    path.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")), encoding="utf-8"
    )


def make_app(root, home, browser):
    location = browser["location"]
    if location is None:
        return
    app_root = root if location == "system" else home
    contents = app_root / "Applications" / browser["app"] / "Contents"
    executable = contents / "MacOS" / browser["exe"]
    executable.parent.mkdir(parents=True, exist_ok=True)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleExecutable": browser["exe"],
                "CFBundleIdentifier": browser["bundle_id"],
                "CFBundleName": browser["app"].removesuffix(".app"),
                "CFBundlePackageType": "APPL",
            },
            stream,
            sort_keys=True,
        )
    executable.write_bytes(b"#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)


def make_state(data, browser):
    state = browser["state"]
    if state == "missing":
        return
    data.mkdir(parents=True, exist_ok=True)
    if state == "malformed":
        (data / "Local State").write_bytes(b'{"profile": {"info_cache": ')
        return

    profiles = browser["profiles"]
    info_cache = {}
    profile_dirs = []
    for index, profile in enumerate(profiles):
        directory = profile["dir"]
        info_cache[directory] = {
            "name": profile["name"],
            "user_name": profile["account"],
            "gaia_name": "",
            "is_using_default_name": False,
            "active_time": 1700000000.0 + index,
            "avatar_icon": "chrome://theme/IDR_PROFILE_AVATAR_26",
            "background_apps": False,
            "is_ephemeral": False,
        }
        if not profile.get("hostile", False):
            profile_dirs.append(directory)
            profile_path = data / directory
            profile_path.mkdir(parents=True, exist_ok=True)
            (profile_path / "Preferences").write_bytes(b"{}")

    key = browser["key"]
    seed_bytes = b"".join(
        hashlib.sha256(f"{key}:{index}".encode()).digest()
        for index in range(1152)
    )
    last_used = browser["last_used"]
    write_json(
        data / "Local State",
        {
            "profile": {
                "info_cache": info_cache,
                "profiles_order": browser.get("profiles_order", profile_dirs),
                "last_used": last_used,
                "last_active_profiles": [last_used],
                "profiles_created": len(profiles),
            },
            "variations_compressed_seed": base64.b64encode(seed_bytes).decode("ascii"),
            "variations_seed_signature": "fixture",
            "browser": {"enabled_labs_experiments": [], "last_redirect_origin": ""},
            "user_experience_metrics": {
                "client_id2": "00000000-0000-4000-8000-"
                + hashlib.sha256(key.encode()).hexdigest()[:12],
                "low_entropy_source3": 1234,
            },
        },
    )


def common_crypto():
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    crypt = library.CCCrypt
    crypt.argtypes = [
        ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
        ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
        ctypes.c_char_p, ctypes.c_size_t,
        ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t),
    ]
    crypt.restype = ctypes.c_int
    return crypt


def encrypt(crypt, key, plaintext):
    output = ctypes.create_string_buffer(len(plaintext) + 16)
    moved = ctypes.c_size_t()
    # kCCEncrypt=0, kCCAlgorithmAES=0, kCCOptionPKCS7Padding=1; CBC by default.
    status = crypt(
        0, 0, 1, key, len(key), b" " * 16, plaintext, len(plaintext),
        output, len(output), ctypes.byref(moved),
    )
    if status != 0:
        raise RuntimeError(f"CCCrypt encryption failed with status {status}")
    return b"v10" + output.raw[:moved.value]


def make_cookies(data, browser, cookies, keychain, crypt):
    path = data / cookies["profile"] / cookies["db"]
    path.parent.mkdir(parents=True, exist_ok=True)
    # "keychain_override" encrypts with another password, as a newer scheme
    # or a mismatched Keychain item would: nothing decrypts.
    password = cookies.get("keychain_override") or keychain[browser["keychain"]]
    key = hashlib.pbkdf2_hmac("sha1", password.encode(), b"saltysalt", 1003, 16)
    database = sqlite3.connect(path)
    try:
        with database:
            database.execute(
                "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, "
                "value LONGVARCHAR)"
            )
            database.execute(
                "INSERT INTO meta(key, value) VALUES (?, ?)",
                ("version", str(cookies["meta_version"])),
            )
            database.execute(COOKIE_SCHEMA)
            for index, row in enumerate(cookies["rows"]):
                value = row["value"]
                encrypted = b""
                if row["encrypt"]:
                    plaintext = value.encode()
                    if cookies["meta_version"] >= 24:
                        plaintext = hashlib.sha256(row["host"].encode()).digest() + plaintext
                    encrypted = encrypt(crypt, key, plaintext)
                    value = ""
                timestamp = 13300000000000000 + index
                persistent = int(row["expires"] is not None)
                database.execute(
                    "INSERT INTO cookies(creation_utc, host_key, name, value, "
                    "encrypted_value, path, expires_utc, is_secure, is_httponly, "
                    "last_access_utc, has_expires, is_persistent, samesite) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        timestamp, row["host"], row["name"], value, encrypted, "/",
                        EXPIRES[row["expires"]], row["secure"], row["httponly"],
                        timestamp, persistent, persistent, row["samesite"],
                    ),
                )
    finally:
        database.close()


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: make_fixtures.py ROOT\n")
        return 2
    spec = json.loads(Path(__file__).with_name("spec.json").read_text(encoding="utf-8"))
    root = Path(sys.argv[1])
    if root.is_symlink() or root.is_file():
        root.unlink()
    elif root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    home = root / spec["home"]
    browsers = {browser["key"]: browser for browser in spec["browsers"]}
    data_root = home / "Library" / "Application Support"
    for browser in spec["browsers"]:
        make_app(root, home, browser)
        make_state(data_root / browser["data"], browser)
    crypt = common_crypto()
    for cookies in spec["cookies"]:
        browser = browsers[cookies["browser"]]
        make_cookies(data_root / browser["data"], browser, cookies, spec["keychain"], crypt)
    write_json(root / "keychain.json", spec["keychain"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
