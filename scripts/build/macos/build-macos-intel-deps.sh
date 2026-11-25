#!/bin/bash
# GeneralsX @build Cursor 25/11/2026 Build x86_64 macOS 12 dependencies for the Intel bundle.
# Homebrew bottles on macos-15-intel advertise the host OS, so ffmpeg, MoltenVK, and the
# Vulkan loader are compiled here with MACOSX_DEPLOYMENT_TARGET=12.0.
# MiniAudio is compiled into the game. OpenAL is not linked by the macos-vulkan-x64 preset.

set -euo pipefail

PREFIX="${GX_PREFIX:-${HOME}/gx-prefix}"
SRC_ROOT="${GX_DEP_SRC:-${HOME}/gx-dep-src}"
FFMPEG_TAG="n6.1.2"
MOLTENVK_TAG="v1.3.0"
VULKAN_LOADER_TAG="v1.3.296"

mkdir -p "${PREFIX}/lib" "${PREFIX}/include" "${SRC_ROOT}"

export MACOSX_DEPLOYMENT_TARGET="12.0"
export CMAKE_OSX_DEPLOYMENT_TARGET="12.0"
export CMAKE_OSX_ARCHITECTURES="x86_64"
export CFLAGS="-arch x86_64 -mmacosx-version-min=12.0"
export CXXFLAGS="-arch x86_64 -mmacosx-version-min=12.0"
export LDFLAGS="-arch x86_64 -mmacosx-version-min=12.0"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

minos_ok() {
    local target="$1"
    local minos
    minos="$(otool -l "${target}" | awk '$1 == "minos" { print $2; exit }')"
    if [[ -z "${minos}" ]]; then
        echo "ERROR: ${target} has no LC_BUILD_VERSION minos"
        return 1
    fi
    python3 - "${minos}" <<'PY'
import sys
def parse(value):
    parts = [int(item) for item in value.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))
sys.exit(0 if parse(sys.argv[1]) <= (12, 0, 0) else 1)
PY
}

require_x64() {
    local target="$1"
    local info
    info="$(lipo -info "${target}")"
    echo "${target}: ${info}"
    if [[ "${info}" == *"arm64"* ]]; then
        echo "ERROR: ${target} contains arm64"
        return 1
    fi
    if [[ "${info}" != *"x86_64"* ]]; then
        echo "ERROR: ${target} is not x86_64"
        return 1
    fi
    minos_ok "${target}"
    echo "  minos $(otool -l "${target}" | awk '$1 == "minos" { print $2; exit }')"
}

build_libpng() {
    if [[ -f "${PREFIX}/lib/libpng16.dylib" ]] && minos_ok "${PREFIX}/lib/libpng16.dylib" 2>/dev/null; then
        echo "libpng already built in ${PREFIX}"
        return 0
    fi
    echo "Building libpng 1.6.44 for x86_64 / macOS 12..."
    curl -L --retry 3 --max-time 120 -o "${SRC_ROOT}/libpng.tar.gz" \
        "https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.44.tar.gz"
    tar -xzf "${SRC_ROOT}/libpng.tar.gz" -C "${SRC_ROOT}"
    local src
    src="$(find "${SRC_ROOT}" -maxdepth 1 -type d -name 'libpng-*' | head -n 1)"
    if [[ -z "${src}" ]]; then
        echo "ERROR: libpng source directory was not extracted"
        exit 1
    fi
    cmake -S "${src}" -B "${src}/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
        -DPNG_SHARED=ON \
        -DPNG_STATIC=OFF \
        -DPNG_TESTS=OFF \
        -DPNG_TOOLS=OFF
    cmake --build "${src}/build" --target install
    rm -rf "${src}" "${SRC_ROOT}/libpng.tar.gz"
}

build_ffmpeg() {
    if [[ -f "${PREFIX}/lib/pkgconfig/libavcodec.pc" ]] && minos_ok "${PREFIX}/lib/libavcodec.dylib" 2>/dev/null; then
        echo "FFmpeg already built in ${PREFIX}"
        return 0
    fi
    echo "Building FFmpeg ${FFMPEG_TAG} for x86_64 / macOS 12..."
    local src="${SRC_ROOT}/FFmpeg-${FFMPEG_TAG}"
    if [[ ! -d "${src}" ]]; then
        curl -L --retry 3 --max-time 180 -o "${SRC_ROOT}/ffmpeg.tar.gz" \
            "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${FFMPEG_TAG}.tar.gz"
        tar -xzf "${SRC_ROOT}/ffmpeg.tar.gz" -C "${SRC_ROOT}"
    fi
    pushd "${src}" >/dev/null
    ./configure \
        --prefix="${PREFIX}" \
        --arch=x86_64 \
        --cc=clang \
        --enable-shared \
        --disable-static \
        --disable-programs \
        --disable-doc \
        --disable-avdevice \
        --disable-network \
        --disable-everything \
        --enable-avcodec \
        --enable-avformat \
        --enable-avutil \
        --enable-swscale \
        --enable-swresample \
        --enable-decoder=bink,binkaudio_dct,binkaudio_rdft \
        --enable-demuxer=bink \
        --enable-parser=bink \
        --enable-protocol=file \
        --enable-pthreads \
        --disable-xlib \
        --disable-libxcb \
        --extra-cflags="-arch x86_64 -mmacosx-version-min=12.0" \
        --extra-ldflags="-arch x86_64 -mmacosx-version-min=12.0"
    make -j"$(sysctl -n hw.ncpu)"
    make install
    popd >/dev/null
    rm -rf "${src}" "${SRC_ROOT}/ffmpeg.tar.gz"
}

build_moltenvk() {
    if [[ -f "${PREFIX}/lib/libMoltenVK.dylib" ]] && minos_ok "${PREFIX}/lib/libMoltenVK.dylib" 2>/dev/null; then
        echo "MoltenVK already built in ${PREFIX}"
        return 0
    fi
    echo "Building MoltenVK ${MOLTENVK_TAG} for x86_64 / macOS 12..."
    local src="${SRC_ROOT}/MoltenVK"
    rm -rf "${src}"
    git clone --depth 1 --branch "${MOLTENVK_TAG}" https://github.com/KhronosGroup/MoltenVK.git "${src}"
    pushd "${src}" >/dev/null
    # Xcode on the Intel runner rejects bare ARCHS= arguments ("invalid argument").
    # Select the slice with the destination and pin minos inside the projects.
    pin_moltenvk_x64() {
        local project
        while IFS= read -r project; do
            sed -i '' \
                -e 's/MACOSX_DEPLOYMENT_TARGET = [^;]*;/MACOSX_DEPLOYMENT_TARGET = 12.0;/g' \
                "${project}"
        done < <(find . -name project.pbxproj -type f)
    }
    pin_moltenvk_x64
    # generic/platform=macOS is the destination this runner accepts. "Any Mac"
    # rejects an arch= specifier. The host is already x86_64 ("My Mac").
    ./fetchDependencies --macos
    pin_moltenvk_x64
    cat > gx-x64.xcconfig <<'EOF'
ARCHS = x86_64
EXCLUDED_ARCHS = arm64
ONLY_ACTIVE_ARCH = YES
MACOSX_DEPLOYMENT_TARGET = 12.0
CODE_SIGNING_ALLOWED = NO
CODE_SIGNING_REQUIRED = NO
EOF
    xcodebuild \
        -project MoltenVKPackaging.xcodeproj \
        -scheme "MoltenVK Package (macOS only)" \
        -destination "platform=macOS,name=My Mac" \
        -configuration Release \
        -xcconfig "${src}/gx-x64.xcconfig" \
        build
    local built
    built="$(find . -name 'libMoltenVK.dylib' -type f | head -n 1)"
    if [[ -z "${built}" ]]; then
        echo "ERROR: libMoltenVK.dylib was not produced"
        exit 1
    fi
    local thin="${PREFIX}/lib/libMoltenVK.dylib"
    if lipo -info "${built}" | grep -q "arm64"; then
        lipo "${built}" -extract x86_64 -output "${thin}"
    else
        cp -L "${built}" "${thin}"
    fi
    if [[ -d "External/Vulkan-Headers/include/vulkan" ]]; then
        mkdir -p "${PREFIX}/include/vulkan"
        cp -R External/Vulkan-Headers/include/vulkan/. "${PREFIX}/include/vulkan/"
    fi
    # CMake FindVulkan requires MoltenVK/mvk_vulkan.h in addition to the dylib.
    local moltenvk_header
    moltenvk_header="$(find . -path '*/MoltenVK/mvk_vulkan.h' -type f | head -n 1)"
    if [[ -z "${moltenvk_header}" ]]; then
        echo "ERROR: MoltenVK headers were not produced"
        exit 1
    fi
    mkdir -p "${PREFIX}/include/MoltenVK"
    cp -R "$(dirname "${moltenvk_header}")/." "${PREFIX}/include/MoltenVK/"
    popd >/dev/null
    rm -rf "${src}" "${HOME}/Library/Developer/Xcode/DerivedData"
}

build_vulkan_loader() {
    if [[ -f "${PREFIX}/lib/libvulkan.dylib" ]] && minos_ok "${PREFIX}/lib/libvulkan.dylib" 2>/dev/null; then
        echo "Vulkan loader already built in ${PREFIX}"
        return 0
    fi
    echo "Building Vulkan-Loader ${VULKAN_LOADER_TAG} for x86_64 / macOS 12..."
    local src="${SRC_ROOT}/Vulkan-Loader"
    rm -rf "${src}"
    git clone --depth 1 --branch "${VULKAN_LOADER_TAG}" https://github.com/KhronosGroup/Vulkan-Loader.git "${src}"
    cmake -S "${src}" -B "${src}/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
        -DBUILD_TESTS=OFF \
        -DUPDATE_DEPS=ON
    cmake --build "${src}/build" --target install
    if [[ -f "${PREFIX}/lib/libvulkan.1.dylib" && ! -f "${PREFIX}/lib/libvulkan.dylib" ]]; then
        ln -sf libvulkan.1.dylib "${PREFIX}/lib/libvulkan.dylib"
    fi
    local loader="${PREFIX}/lib/libvulkan.dylib"
    if [[ -L "${loader}" ]]; then
        loader="$(readlink "${loader}")"
        if [[ "${loader}" != /* ]]; then
            loader="${PREFIX}/lib/${loader}"
        fi
    fi
    if lipo -info "${loader}" | grep -q "arm64"; then
        local thin="${PREFIX}/lib/libvulkan.x86_64.dylib"
        lipo "${loader}" -extract x86_64 -output "${thin}"
        mv "${thin}" "${PREFIX}/lib/libvulkan.1.dylib"
        ln -sf libvulkan.1.dylib "${PREFIX}/lib/libvulkan.dylib"
    fi
    rm -rf "${src}"
}

build_libpng
build_ffmpeg
build_moltenvk
build_vulkan_loader

echo "Checking dependency architectures and deployment targets..."
shopt -s nullglob
for library in "${PREFIX}"/lib/*.dylib; do
    require_x64 "${library}"
done

if [[ ! -f "${PREFIX}/include/vulkan/vulkan.h" ]]; then
    echo "ERROR: Vulkan headers were not installed to ${PREFIX}/include"
    exit 1
fi
if [[ ! -f "${PREFIX}/lib/libMoltenVK.dylib" || ! -f "${PREFIX}/lib/libvulkan.dylib" ]]; then
    echo "ERROR: MoltenVK or the Vulkan loader is missing from ${PREFIX}/lib"
    exit 1
fi

echo "Intel macOS 12 dependencies ready in ${PREFIX}"
