rnnoise — CMake instructions for Visual Studio 2022 and Windows

**Work in progress**

This repo now includes a `CMakeLists.txt` to generate a Visual Studio 2022 solution or to build using Unix toolchains.

Quick checklist
- Get rnnoise from https://github.com/xiph/rnnoise
- Copy the content in this repository to the root dir. of your copy of https://github.com/xiph/rnnoise
- Generate VS2022 solution and build Release x64
- Enable/disable x86-optimized sources (SSE4.1 / AVX2)
- Build in Android Studio
- Build on WSL / Unix toolchains
- Troubleshoot common MSVC issues (intrinsics / inline asm / missing macros)

Generate a Visual Studio 2022 solution (recommended on Windows)
1. Open "x64 Native Tools Command Prompt for VS 2022" (or Developer PowerShell for VS 2022).
2. From the project root run:

```powershell
mkdir build
cd build
cmake -G "Visual Studio 17 2022" -A x64 -DBUILD_EXAMPLES=ON -DBUILD_TOOLS=ON -DENABLE_AVX2=OFF ..
cmake --build . --config Release
```

- To enable AVX2-optimized sources (if your CPU and MSVC support it):
```powershell
cmake -G "Visual Studio 17 2022" -A x64 -DENABLE_AVX2=ON -DBUILD_EXAMPLES=ON ..
cmake --build . --config Release
```

Notes for MSVC
- `CMakeLists.txt` now sets `/arch:AVX2` for AVX2 when `ENABLE_AVX2=ON`, and defines `__AVX2__` / `__SSE4_1__` for MSVC so the `src/x86/*` compile-time checks pass.
- If compilation fails in `src/x86/*` due to compiler-specific intrinsics or inline assembly, disable x86 optimization options and build the generic code path (set `-DENABLE_AVX2=OFF -DENABLE_SSE4_1=OFF`). I can help adapt the code for MSVC if you want.
- The CMake file adds `_CRT_SECURE_NO_WARNINGS` to reduce CRT warnings.

 Build in Android Studio
 - Install NDK and CMake in Adnroid Studio (SDK Manager)
 - Open the folder ...rnnoise\android in Android Studio
 
Build on WSL / Unix toolchains
- Install a C compiler and make (e.g., `sudo apt install build-essential cmake`), then from project root:

```bash
mkdir build
cd build
cmake -G "Unix Makefiles" ..
make -j$(nproc)
```

- If CMake fails with `CMAKE_MAKE_PROGRAM is not set` or `CMAKE_C_COMPILER not set`, install the system build tools (see above). I tried configuring in WSL earlier and saw that your environment didn't have a build toolchain configured.

Troubleshooting tips
- Linker errors for math functions on MinGW: ensure libm is linked; CMake currently links `m` on non-MSVC toolchains.
- CPU feature detection: `src/x86/x86cpu.c` performs runtime detection; building optimized sources is optional.


*Made by CoPilot GPT-5*