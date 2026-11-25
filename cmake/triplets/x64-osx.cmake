# GeneralsX @build Cursor 25/11/2026 vcpkg overlay triplet for Intel macOS 12.
# Pins architecture and deployment target so static vcpkg libraries
# (freetype, fontconfig, curl, zlib) are built for x86_64 with minos 12.0.
# The host GitHub runner is macOS 15; without this pin, vcpkg inherits the
# host SDK version and the linked binary advertises a newer minimum OS.

set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES x86_64)
set(VCPKG_OSX_DEPLOYMENT_TARGET "12.0")
set(VCPKG_C_FLAGS "-mmacosx-version-min=12.0")
set(VCPKG_CXX_FLAGS "-mmacosx-version-min=12.0")
set(VCPKG_LINKER_FLAGS "-mmacosx-version-min=12.0")
