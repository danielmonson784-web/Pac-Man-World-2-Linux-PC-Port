# `ENABLE_WAYLAND` is forced ON unconditionally, breaking any Windows/macOS cross-compile

**Repo:** ExpansionPak/ModernGekko
**Component:** top-level `CMakeLists.txt`

## Summary

Two problems make a MinGW-w64 cross-compile to Windows fail at configure/link
time on a stock checkout:

1. `set(ENABLE_WAYLAND ON CACHE BOOL "" FORCE)` is unconditional. Wayland is
   Linux-only, and the later `find_file(MODERNGEKKO_XDG_SHELL_XML xdg-shell.xml ... REQUIRED)`
   cannot be satisfied when targeting Windows, so configuration dies.

2. `if(TARGET PkgConfig::X11)` and `if(TARGET PkgConfig::WAYLAND)` gate the X11
   and Wayland platform sources. When cross-compiling on a Linux host, those
   pkg-config targets can still resolve from the *host* — so
   `DolphinNoGUI/PlatformX11.cpp` gets compiled into a Windows build, which is
   not what anyone wants.

## Fix

```diff
-    set(ENABLE_WAYLAND ON CACHE BOOL "" FORCE)
+    if(WIN32 OR APPLE)
+        set(ENABLE_WAYLAND OFF CACHE BOOL "" FORCE)
+    else()
+        set(ENABLE_WAYLAND ON CACHE BOOL "" FORCE)
+    endif()
```

```diff
-    if(TARGET PkgConfig::X11)
+    if(TARGET PkgConfig::X11 AND NOT WIN32)
```

```diff
-    if(TARGET PkgConfig::WAYLAND)
+    if(TARGET PkgConfig::WAYLAND AND NOT WIN32)
```

## Related (not in the patch, but worth documenting)

Cross-compiling this tree also needs `USE_SYSTEM_LIBS=OFF`, otherwise host
libraries leak into the Windows link. Even with that, pkg-config can still
inject `-I/usr/include` and pull in host headers. Both are configuration
issues rather than bugs, but they are not obvious, and a short
"cross-compiling to Windows" note in the README would save the next person some
time.

Separately, `CMAKE_CROSSCOMPILING_EMULATOR` needs to be set (or the relevant
build-time tool invocations skipped) or the build fails with exit 127 when it
tries to *run* a freshly built PE binary on the Linux host.

## Environment

Host: Linux (CachyOS), MinGW-w64 cross toolchain. Target: Windows x86-64.
