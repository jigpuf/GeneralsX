#include "types_compat.h"
#include "module_compat.h"

#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

// GeneralsX @feature BenderAI 24/02/2026 Phase 5 macOS executable path detection
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

bool GetModuleFileName(HINSTANCE hInstance, char* buffer, int size)
{
#ifdef __linux__
  ssize_t count = readlink("/proc/self/exe", buffer, size);
  if (count == -1)
    return false;
  buffer[count] = '\0';
  return true;
#elif defined(__APPLE__)
  uint32_t bufsize = (uint32_t)size;
  int ret = _NSGetExecutablePath(buffer, &bufsize);
  if (ret == 0) {
    return true;
  }
  return false;
#else
  return false;
#endif
}

HMODULE LoadLibrary(const char* lpFileName)
{
  // GeneralsX @feature BenderAI 24/02/2026 Phase 5 - Platform-agnostic library loading without C++17
  // Check if filename ends with ".dll" and remove extension if so
  const char* ext = strrchr(lpFileName, '.');
  if (ext && strcmp(ext, ".dll") == 0) {
    // Create a copy without the .dll extension
    size_t len = ext - lpFileName;
    char pathCurrent[512];
    if (len < sizeof(pathCurrent)) {
      strncpy(pathCurrent, lpFileName, len);
      pathCurrent[len] = '\0';
      return dlopen(pathCurrent, RTLD_LAZY);
    }
  }
  
#ifdef __APPLE__
  // GeneralsX @bugfix Cursor 25/11/2026 dlopen of a bare dylib name does not search
  // LC_RPATH. Also look beside the app in Contents/Frameworks.
  char exePath[1024];
  uint32_t exeSize = sizeof(exePath);
  if (_NSGetExecutablePath(exePath, &exeSize) == 0) {
    char *slash = strrchr(exePath, '/');
    if (slash) {
      *slash = '\0';
      char frameworkPath[1200];
      snprintf(frameworkPath, sizeof(frameworkPath), "%s/../Frameworks/%s", exePath, lpFileName);
      void *bundled = dlopen(frameworkPath, RTLD_LAZY);
      if (bundled) {
        return bundled;
      }
    }
  }
#endif

  return dlopen(lpFileName, RTLD_LAZY);
}

FARPROC GetProcAddress(HMODULE hModule, const char* lpProcName)
{
  return (FARPROC)dlsym(hModule, lpProcName);
}

void FreeLibrary(HMODULE hModule)
{
  // Currently misbehaves by unmapping regions not related to the library
  // dlclose(hModule);
}