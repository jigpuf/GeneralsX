#!/bin/bash
# GeneralsX @build Cursor 25/11/2026 Confirm an Intel .app is x86_64, minos <= 12.0,
# and links only the bundle, /System, or /usr/lib.

set -euo pipefail

ZIP_PATH="${1:?zip path required}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
unzip -q "${ZIP_PATH}" -d "${WORKDIR}"
APP_PATH="$(find "${WORKDIR}" -maxdepth 1 -name '*.app' -type d | head -n 1)"
if [[ -z "${APP_PATH}" ]]; then
    echo "ERROR: no .app in ${ZIP_PATH}" >&2
    exit 1
fi

python3 - "${APP_PATH}" <<'PY'
import os
import plistlib
import subprocess
import sys

app = sys.argv[1]
plist_path = os.path.join(app, "Contents", "Info.plist")
with open(plist_path, "rb") as handle:
    plist = plistlib.load(handle)

errors = []
if str(plist.get("LSMinimumSystemVersion")) != "12.0":
    errors.append(f"LSMinimumSystemVersion is {plist.get('LSMinimumSystemVersion')!r}, expected 12.0")
if str(plist.get("CFBundleShortVersionString")) != "0.4":
    errors.append(f"CFBundleShortVersionString is {plist.get('CFBundleShortVersionString')!r}, expected 0.4")

frameworks = os.path.join(app, "Contents", "Frameworks")
required_runtime = [
    "libdxvk_d3d8.dylib",
    "libdxvk_d3d8.0.dylib",
    "libdxvk_d3d9.dylib",
    "libdxvk_d3d9.0.dylib",
    "libMoltenVK.dylib",
    "libvulkan.dylib",
    "MoltenVK_icd.json",
]
for name in required_runtime:
    path = os.path.join(frameworks, name)
    if not os.path.isfile(path):
        errors.append(f"missing dlopen/runtime file Contents/Frameworks/{name}")
    else:
        print(f"runtime file Contents/Frameworks/{name}")

icd_path = os.path.join(frameworks, "MoltenVK_icd.json")
if os.path.isfile(icd_path):
    import json
    with open(icd_path, "r", encoding="utf-8") as icd_handle:
        icd = json.load(icd_handle)
    library_path = icd.get("ICD", {}).get("library_path", "")
    resolved = os.path.normpath(os.path.join(os.path.dirname(icd_path), library_path))
    print(f"MoltenVK ICD library_path={library_path} -> {resolved}")
    if not library_path or not os.path.isfile(resolved):
        errors.append(f"MoltenVK ICD library_path does not exist: {library_path}")

def version_tuple(value):
    parts = [int(item) for item in value.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))

def run(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

machos = []
for root, dirs, files in os.walk(app):
    for name in files:
        path = os.path.join(root, name)
        try:
            kind = run(["file", path])
        except subprocess.CalledProcessError:
            continue
        if "Mach-O" in kind:
            machos.append(path)

if not machos:
    errors.append("no Mach-O files found")

print(f"Mach-O files: {len(machos)}")
for path in machos:
    info = run(["lipo", "-info", path]).strip()
    print(info)
    if "arm64" in info or "x86_64" not in info:
        errors.append(f"architecture check failed: {info}")
    load = run(["otool", "-l", path])
    minos = None
    for line in load.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "minos":
            minos = parts[1]
            break
    print(f"  minos {minos}")
    if minos is None or version_tuple(minos) > (12, 0, 0):
        errors.append(f"minos {minos} for {path}")
    for line in load.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "path":
            rpath = parts[1]
            if not (rpath.startswith("@executable_path/") or rpath.startswith("@loader_path")):
                errors.append(f"rpath outside bundle: {rpath} ({path})")
    libs = run(["otool", "-L", path]).splitlines()[1:]
    for line in libs:
        dep = line.strip().split()[0]
        print(f"  dep {dep}")
        allowed = (
            dep.startswith("@rpath/")
            or dep.startswith("@executable_path/")
            or dep.startswith("@loader_path/")
            or dep.startswith("/System/")
            or dep.startswith("/usr/lib/")
        )
        if not allowed:
            errors.append(f"dependency outside bundle: {dep} ({path})")

if errors:
    print("VERIFICATION FAILED")
    for error in errors:
        print(f"  - {error}")
    sys.exit(1)
print("VERIFICATION PASSED")
PY
