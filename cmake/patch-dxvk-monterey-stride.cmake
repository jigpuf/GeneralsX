# GeneralsX @build Cursor 26/11/2026
# DXVK has no dxvk.conf switch for this. On macOS 12, MoltenVK 1.3 advertises
# extended dynamic state and then rejects VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE
# (Metal requires macOS 14 and an Apple4 or Mac2 GPU). Bake the stride into the
# pipeline on older systems. macOS 14 and later keep the dynamic path.
if(NOT DEFINED SOURCE_DIR)
	message(FATAL_ERROR "SOURCE_DIR is required")
endif()

set(target "${SOURCE_DIR}/src/dxvk/dxvk_context.cpp")
if(NOT EXISTS "${target}")
	message(FATAL_ERROR "DXVK context source was not found: ${target}")
endif()

file(READ "${target}" content)
if(content MATCHES "GeneralsX monterey vertex stride")
	return()
endif()

set(needle "    bool newDynamicStrides = true;")
string(FIND "${content}" "${needle}" found)
if(found EQUAL -1)
	message(FATAL_ERROR "DXVK vertex-stride patch point was not found in ${target}")
endif()

string(REPLACE "${needle}"
"    // GeneralsX monterey vertex stride: Metal rejects dynamic binding stride before macOS 14.
    bool newDynamicStrides = true;
#if defined(__APPLE__)
    if (!__builtin_available(macOS 14.0, *))
      newDynamicStrides = false;
#endif"
	content "${content}")

file(WRITE "${target}" "${content}")
message(STATUS "Patched DXVK to bake vertex strides before macOS 14")
