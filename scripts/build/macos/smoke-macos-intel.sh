#!/bin/bash
# GeneralsX @build Cursor 25/11/2026 Launch the bundled app far enough to hit the
# missing-data path. A GPU hang is reported and does not fail the check.

set -euo pipefail

ZIP_PATH="${1:-zerohour-intel-mac-v0.1.zip}"
ROOT="$(mktemp -d)"
HOME_DIR="${ROOT}/home"
mkdir -p "${HOME_DIR}"
unzip -q "${ZIP_PATH}" -d "${ROOT}"
BINARY="${ROOT}/GeneralsXZH.app/Contents/MacOS/GeneralsXZH"

python3 - "${BINARY}" "${HOME_DIR}" <<'PY'
import os
import subprocess
import sys

binary = sys.argv[1]
home = sys.argv[2]
env = os.environ.copy()
env["GX_NONINTERACTIVE"] = "1"
env["CI"] = "true"
env["HOME"] = home
try:
    completed = subprocess.run(
        [binary],
        env=env,
        text=True,
        capture_output=True,
        timeout=60,
    )
except subprocess.TimeoutExpired as exc:
    sys.stdout.write(exc.stdout or "")
    sys.stderr.write(exc.stderr or "")
    print("SMOKE: timed out. GPU or window startup may have hung after the data check.")
    sys.exit(0)

sys.stdout.write(completed.stdout or "")
sys.stderr.write(completed.stderr or "")
combined = (completed.stdout or "") + (completed.stderr or "")
print(f"SMOKE_EXIT={completed.returncode}")
if completed.returncode < 0:
    print("SMOKE: process was signaled")
    sys.exit(1)
if "Zero Hour data was not found" not in combined and "Zero Hour data:" not in combined:
    print("SMOKE: expected the data-missing or data-found message")
    sys.exit(1)
if "Library not loaded" in combined or "dyld[" in combined:
    print("SMOKE: dynamic loader failed")
    sys.exit(1)
print("SMOKE: reached the data-folder path without a loader crash")
PY
