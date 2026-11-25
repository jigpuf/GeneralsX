#!/bin/bash
# GeneralsX @build Cursor 25/11/2026 Package an unsigned Intel macOS .app.
# Non-system dylibs land in Contents/Frameworks with @rpath install names.
# The bundle contains the engine only. Retail .big archives are never copied.

set -euo pipefail

GAME="${1:-zh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build/macos-vulkan-x64"
PREFIX="${GX_PREFIX:-${HOME}/gx-prefix}"

case "${GAME}" in
    zh|GeneralsMD)
        APP_NAME="GeneralsXZH"
        BINARY_SRC="${BUILD_DIR}/GeneralsMD/GeneralsXZH"
        BUNDLE_ID="com.generalsx.generalsxzh"
        ICON_SRC="${PROJECT_ROOT}/assets/generalsx-zh_icon.png"
        OUTPUT_ZIP="${PROJECT_ROOT}/zerohour-intel-mac-v0.2.zip"
        ;;
    generals|Generals)
        APP_NAME="GeneralsX"
        BINARY_SRC="${BUILD_DIR}/Generals/GeneralsX"
        BUNDLE_ID="com.generalsx.generalsx"
        ICON_SRC="${PROJECT_ROOT}/assets/generalsx_icon.png"
        OUTPUT_ZIP="${PROJECT_ROOT}/generals-intel-mac-v0.2.zip"
        ;;
    *)
        echo "Usage: $0 zh|generals" >&2
        exit 1
        ;;
esac

if [[ ! -f "${BINARY_SRC}" ]]; then
    echo "ERROR: Binary not found at ${BINARY_SRC}" >&2
    exit 1
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT
APP_DIR="${STAGE_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
FRAMEWORKS_DIR="${APP_DIR}/Contents/Frameworks"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}/fonts" "${RESOURCES_DIR}/fontconfig"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>0.2</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>$(basename "${ICON_SRC}")</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cp "${BINARY_SRC}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

if [[ -f "${ICON_SRC}" ]]; then
    cp "${ICON_SRC}" "${RESOURCES_DIR}/"
fi
if [[ -f "${PROJECT_ROOT}/resources/dxvk/dxvk.conf" ]]; then
    cp "${PROJECT_ROOT}/resources/dxvk/dxvk.conf" "${RESOURCES_DIR}/dxvk.conf"
fi
if [[ -d "${PROJECT_ROOT}/assets/fonts" ]]; then
    cp "${PROJECT_ROOT}/assets/fonts/"*.ttf "${RESOURCES_DIR}/fonts/" 2>/dev/null || true
    cp "${PROJECT_ROOT}/assets/fonts/"LICENSE.* "${RESOURCES_DIR}/fonts/" 2>/dev/null || true
fi

FONTCONFIG_ETC="${BUILD_DIR}/vcpkg_installed/x64-osx/etc/fonts"
if [[ -f "${FONTCONFIG_ETC}/fonts.conf" ]]; then
    cp "${FONTCONFIG_ETC}/fonts.conf" "${RESOURCES_DIR}/fontconfig/fonts.conf"
    if [[ -d "${FONTCONFIG_ETC}/conf.d" ]]; then
        cp -R "${FONTCONFIG_ETC}/conf.d" "${RESOURCES_DIR}/fontconfig/conf.d"
    fi
fi

GENERALSX_BIG="${BUILD_DIR}/generalsx.big"
if [[ ! -f "${GENERALSX_BIG}" && "${APP_NAME}" == "GeneralsXZH" ]]; then
    python3 "${PROJECT_ROOT}/scripts/tooling/build_big.py" pack \
        "${PROJECT_ROOT}/assets/generalsx-big" "${GENERALSX_BIG}"
fi
if [[ -f "${GENERALSX_BIG}" && "${APP_NAME}" == "GeneralsXZH" ]]; then
    cp "${GENERALSX_BIG}" "${RESOURCES_DIR}/generalsx.big"
fi

# The Vulkan loader resolves library_path relative to the JSON file.
# A manifest beside libMoltenVK.dylib avoids a ../Frameworks hop.
cat > "${FRAMEWORKS_DIR}/MoltenVK_icd.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "libMoltenVK.dylib",
        "api_version": "1.3.0",
        "is_portability_driver": true
    }
}
EOF
cp "${FRAMEWORKS_DIR}/MoltenVK_icd.json" "${RESOURCES_DIR}/MoltenVK_icd.json"

is_system_dep() {
    local dep="$1"
    [[ "${dep}" == /System/* || "${dep}" == /usr/lib/* ]]
}

resolve_dep() {
    local owner="$1"
    local dep="$2"
    local candidate=""
    if [[ "${dep}" == @rpath/* || "${dep}" == @loader_path/* || "${dep}" == @executable_path/* ]]; then
        local name="${dep##*/}"
        local search_dirs=(
            "$(dirname "${owner}")"
            "${FRAMEWORKS_DIR}"
            "${PREFIX}/lib"
            "${BUILD_DIR}"
            "${BUILD_DIR}/_deps/sdl3-build"
            "${BUILD_DIR}/_deps/sdl3_image-build"
            "${BUILD_DIR}/_deps/dxvk-build-macos/src/d3d8"
            "${BUILD_DIR}/_deps/dxvk-build-macos/src/d3d9"
        )
        local dir
        for dir in "${search_dirs[@]}"; do
            if [[ -f "${dir}/${name}" ]]; then
                echo "${dir}/${name}"
                return 0
            fi
        done
        return 1
    fi
    if [[ "${dep}" == /* && -f "${dep}" ]]; then
        echo "${dep}"
        return 0
    fi
    return 1
}

copy_library() {
    local source="$1"
    local name
    name="$(basename "${source}")"
    local dest="${FRAMEWORKS_DIR}/${name}"
    if [[ ! -f "${dest}" ]]; then
        echo "  + ${name}" >&2
        cp -L "${source}" "${dest}"
        chmod 755 "${dest}"
    fi
    echo "${dest}"
}

PENDING="${STAGE_DIR}/pending.txt"
SEEN="${STAGE_DIR}/seen.txt"
: > "${PENDING}"
: > "${SEEN}"
echo "${MACOS_DIR}/${APP_NAME}" >> "${PENDING}"

# Runtime dlopen() names are not LC_LOAD_DYLIB entries. Seed them explicitly.
for known in \
    "${BUILD_DIR}/libdxvk_d3d8.0.dylib" \
    "${BUILD_DIR}/libdxvk_d3d9.0.dylib" \
    "${BUILD_DIR}/libdxvk_d3d8.dylib" \
    "${BUILD_DIR}/libdxvk_d3d9.dylib" \
    "${BUILD_DIR}/_deps/dxvk-build-macos/src/d3d8/libdxvk_d3d8.0.dylib" \
    "${BUILD_DIR}/_deps/dxvk-build-macos/src/d3d9/libdxvk_d3d9.0.dylib" \
    "${BUILD_DIR}/libgamespy.dylib" \
    "${BUILD_DIR}/Patches/SagePatch/libsage_patch.dylib" \
    "${PREFIX}/lib/libMoltenVK.dylib" \
    "${PREFIX}/lib/libvulkan.dylib" \
    "${PREFIX}/lib/libvulkan.1.dylib"
do
    if [[ -f "${known}" ]]; then
        copied="$(copy_library "${known}")"
        echo "${copied}" >> "${PENDING}"
    fi
done

while [[ -s "${PENDING}" ]]; do
    target="$(head -n 1 "${PENDING}")"
    tail -n +2 "${PENDING}" > "${PENDING}.next" && mv "${PENDING}.next" "${PENDING}"
    if grep -Fqx "${target}" "${SEEN}"; then
        continue
    fi
    echo "${target}" >> "${SEEN}"
    while IFS= read -r dep; do
        [[ -z "${dep}" ]] && continue
        if is_system_dep "${dep}"; then
            continue
        fi
        resolved="$(resolve_dep "${target}" "${dep}" || true)"
        if [[ -z "${resolved}" ]]; then
            echo "WARNING: unresolved dependency '${dep}' from ${target}" >&2
            continue
        fi
        if is_system_dep "${resolved}"; then
            continue
        fi
        copied="$(copy_library "${resolved}")"
        if ! grep -Fqx "${copied}" "${SEEN}" && ! grep -Fqx "${copied}" "${PENDING}"; then
            echo "${copied}" >> "${PENDING}"
        fi
    done < <(otool -L "${target}" | awk 'NR > 1 { print $1 }')
done

rewrite_macho() {
    local bin="$1"
    local dep
    while IFS= read -r dep; do
        [[ -z "${dep}" ]] && continue
        local name
        name="$(basename "${dep}")"
        if [[ -f "${FRAMEWORKS_DIR}/${name}" ]]; then
            install_name_tool -change "${dep}" "@rpath/${name}" "${bin}"
        fi
    done < <(otool -L "${bin}" | awk 'NR > 1 { print $1 }')

    if [[ "${bin}" == *.dylib ]]; then
        install_name_tool -id "@rpath/$(basename "${bin}")" "${bin}"
    fi

    local rpath
    while IFS= read -r rpath; do
        [[ -z "${rpath}" ]] && continue
        case "${rpath}" in
            @executable_path/*|@loader_path/*) ;;
            *) install_name_tool -delete_rpath "${rpath}" "${bin}" || true ;;
        esac
    done < <(otool -l "${bin}" | awk '$1 == "cmd" && $2 == "LC_RPATH" { keep=1; next } keep && $1 == "path" { print $2; keep=0 }')

    local wanted="@executable_path/../Frameworks"
    if [[ "${bin}" == *.dylib ]]; then
        wanted="@loader_path"
    fi
    if ! otool -l "${bin}" | awk '$1 == "path" { print $2 }' | grep -Fqx "${wanted}"; then
        install_name_tool -add_rpath "${wanted}" "${bin}"
    fi
}

# DX8Wrapper dlopens the unversioned name. The Meson output is only the .0 file.
stage_dlopen_alias() {
    local versioned="$1"
    local plain="$2"
    if [[ ! -f "${FRAMEWORKS_DIR}/${versioned}" ]]; then
        echo "ERROR: ${versioned} is not in Contents/Frameworks" >&2
        echo "DXVK did not build, or the bundle scan missed it." >&2
        exit 1
    fi
    cp -f "${FRAMEWORKS_DIR}/${versioned}" "${FRAMEWORKS_DIR}/${plain}"
    chmod 755 "${FRAMEWORKS_DIR}/${plain}"
    echo "  + ${plain} (dlopen name for ${versioned})" >&2
}
stage_dlopen_alias "libdxvk_d3d8.0.dylib" "libdxvk_d3d8.dylib"
stage_dlopen_alias "libdxvk_d3d9.0.dylib" "libdxvk_d3d9.dylib"
if [[ ! -f "${FRAMEWORKS_DIR}/libMoltenVK.dylib" || ! -f "${FRAMEWORKS_DIR}/libvulkan.dylib" ]]; then
    echo "ERROR: libMoltenVK.dylib or libvulkan.dylib is missing from Contents/Frameworks" >&2
    exit 1
fi

rewrite_macho "${MACOS_DIR}/${APP_NAME}"
for library in "${FRAMEWORKS_DIR}/"*.dylib; do
    [[ -f "${library}" ]] || continue
    rewrite_macho "${library}"
done

xattr -cr "${APP_DIR}" || true
codesign --force --sign - "${FRAMEWORKS_DIR}/"*.dylib
codesign --force --deep --sign - "${APP_DIR}"

rm -f "${OUTPUT_ZIP}"
(cd "${STAGE_DIR}" && zip -y -r "${OUTPUT_ZIP}" "${APP_NAME}.app")
echo "Bundle written to ${OUTPUT_ZIP}"
du -sh "${OUTPUT_ZIP}"
