#!/usr/bin/env bash
# Canonical benchmark for the brave-profiles plugin: builds a deterministic
# fake macOS tree of Chromium browsers, loads both plugin halves into a mocked
# Tern (bench/harness.luau, run by Lune) and prints METRIC lines.
# Primary metric: score = 10 * spec_points - io_cost (higher is better).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
command -v lune >/dev/null || { echo "lune is required (brew install lune)" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

root="$(mktemp -d "${TMPDIR:-/tmp}/bp-bench.XXXXXX")"
trap 'rm -rf "$root"' EXIT

python3 "$here/bench/make_fixtures.py" "$root/fx"
lune run "$here/bench/harness.luau" "$here" "$root/fx"
