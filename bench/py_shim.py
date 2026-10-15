#!/usr/bin/env python3
"""Run a Python script with fixture-backed macOS Keychain lookups."""

import inspect
import json
import locale
import os
import runpy
import shlex
import subprocess
import sys


_MISSING_PASSWORD = (
    "security: SecKeychainSearchCopyNext: The specified item could not be "
    "found in the keychain.\n"
)
_RUN_OPTIONS = {"input", "capture_output", "timeout", "check"}


def _install_shim(keychain, log_path):
    original_run = subprocess.run
    original_check_output = subprocess.check_output
    popen_signature = inspect.signature(subprocess.Popen)

    def lookup_arguments(popenargs, kwargs):
        options = {key: value for key, value in kwargs.items() if key not in _RUN_OPTIONS}
        try:
            options = popen_signature.bind(*popenargs, **options).arguments
        except TypeError:
            return None
        command = options.get("args")
        if isinstance(command, str) and options.get("shell"):
            try:
                argv = shlex.split(command)
            except ValueError:
                return None
        elif isinstance(command, (list, tuple)):
            try:
                argv = [os.fsdecode(arg) for arg in command]
            except TypeError:
                return None
        else:
            return None
        if (
            not argv
            or os.path.basename(argv[0]) != "security"
            or "find-generic-password" not in argv[1:]
        ):
            return None
        return command, argv, options

    def run(*popenargs, **kwargs):
        lookup = lookup_arguments(popenargs, kwargs)
        if lookup is None:
            return original_run(*popenargs, **kwargs)
        command, argv, options = lookup
        if kwargs.get("input") is not None and options.get("stdin") is not None:
            raise ValueError("stdin and input arguments may not both be used.")
        if kwargs.get("capture_output"):
            if options.get("stdout") is not None or options.get("stderr") is not None:
                raise ValueError("stdout and stderr arguments may not be used with capture_output.")
            options["stdout"] = options["stderr"] = subprocess.PIPE
        if (
            options.get("text") is not None
            and options.get("universal_newlines") is not None
            and bool(options["text"]) != bool(options["universal_newlines"])
        ):
            raise subprocess.SubprocessError("Cannot disambiguate when both text and universal_newlines are supplied but different.")

        service = None
        for index, arg in enumerate(argv[1:], 1):
            if arg == "-s":
                service = argv[index + 1] if index + 1 < len(argv) else None
            elif arg.startswith("-s") and len(arg) > 2:
                service = arg[2:]
        found = service in keychain
        if log_path:
            with open(log_path, "a", encoding="utf-8") as log:
                log.write(json.dumps({"service": service, "found": found}) + "\n")

        encoding = options.get("encoding") or locale.getpreferredencoding(False)
        errors = options.get("errors") or "strict"
        text_mode = bool(
            options.get("text")
            or options.get("universal_newlines")
            or options.get("encoding")
            or options.get("errors")
        )
        stdout_data = (keychain[service] + "\n" if found else "").encode(encoding, errors)
        stderr_data = ("" if found else _MISSING_PASSWORD).encode(encoding, errors)

        def output(data, stream, default):
            if stream == subprocess.PIPE:
                return data.decode(encoding, errors) if text_mode else data
            if stream == subprocess.DEVNULL:
                return None
            target = default if stream is None else stream
            if isinstance(target, int):
                with os.fdopen(os.dup(target), "wb") as handle:
                    handle.write(data)
            else:
                target = getattr(target, "buffer", target)
                try:
                    target.write(data)
                except TypeError:
                    target.write(data.decode(encoding, errors))
                target.flush()
            return None

        if options.get("stderr") == subprocess.STDOUT:
            stdout_data += stderr_data
            stderr = None
        else:
            stderr = output(stderr_data, options.get("stderr"), sys.stderr)
        stdout = output(stdout_data, options.get("stdout"), sys.stdout)
        result = subprocess.CompletedProcess(command, 0 if found else 44, stdout, stderr)
        if kwargs.get("check"):
            result.check_returncode()
        return result

    def check_output(*popenargs, **kwargs):
        if lookup_arguments(popenargs, kwargs) is None:
            return original_check_output(*popenargs, **kwargs)
        for option in ("stdout", "check"):
            if option in kwargs:
                raise ValueError("%s argument not allowed, it will be overridden." % option)
        return run(*popenargs, stdout=subprocess.PIPE, check=True, **kwargs).stdout

    subprocess.run = run
    subprocess.check_output = check_output


def main():
    arguments = sys.argv[1:]
    while arguments and arguments[0].startswith("-"):
        flag = arguments.pop(0)
        if flag.startswith(("-c", "-m")):
            print("py_shim.py: -c and -m are not supported; supply a script path", file=sys.stderr)
            return 2
    if not arguments:
        print("usage: python3 bench/py_shim.py [flags...] SCRIPT [ARGS...]", file=sys.stderr)
        return 2

    keychain_path = os.environ.get("BP_KEYCHAIN")
    if not keychain_path:
        print("py_shim.py: BP_KEYCHAIN must name a JSON service/password mapping", file=sys.stderr)
        return 2
    try:
        with open(keychain_path, encoding="utf-8") as source:
            keychain = json.load(source)
        if not isinstance(keychain, dict) or not all(
            isinstance(service, str) and isinstance(password, str)
            for service, password in keychain.items()
        ):
            raise ValueError("expected a JSON object mapping service names to passwords")
    except (OSError, ValueError) as error:
        print("py_shim.py: cannot load BP_KEYCHAIN: %s" % error, file=sys.stderr)
        return 2

    _install_shim(keychain, os.environ.get("BP_SHIM_LOG"))
    script, *script_arguments = arguments
    sys.argv = [script, *script_arguments]
    sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
    runpy.run_path(script, run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main())
