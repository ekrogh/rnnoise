cmake_minimum_required(VERSION 3.15)
project(rnnoise C)

# If using Xcode, avoid generating the ZERO_CHECK target (less clutter)
if(CMAKE_GENERATOR STREQUAL "Xcode")
    set(CMAKE_SUPPRESS_REGENERATION ON)
endif()

# --- Model Download, Checksum, and Extraction ---
# Allow skipping network during cross builds (e.g., Android NDK) when sources already include rnnoise_data.c
option(RNNOISE_SKIP_MODEL_DOWNLOAD "Skip model download and extraction (use existing rnnoise_data.c)" OFF)

# If the generated source already exists in the tree, skip download/extraction automatically
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/rnnoise_data.c" AND NOT RNNOISE_SKIP_MODEL_DOWNLOAD)
    set(RNNOISE_SKIP_MODEL_DOWNLOAD ON)
    message(STATUS "Found src/rnnoise_data.c; auto-skipping model download/extraction.")
endif()

if(NOT RNNOISE_SKIP_MODEL_DOWNLOAD)
    set(MODEL_VERSION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/model_version")
    file(READ "${MODEL_VERSION_FILE}" MODEL_VER_RAW)
    string(STRIP "${MODEL_VER_RAW}" MODEL_VER_RAW)

    # Determine if model_version contains a full SHA256 or a short ID
    set(MODEL_SHA256 "")
    set(MODEL_ID "")
    if(MODEL_VER_RAW MATCHES "^[0-9a-fA-F]{64}$")
        # Full SHA256 provided; derive a short ID (first 7 chars) for the filename
        set(MODEL_SHA256 "${MODEL_VER_RAW}")
        string(SUBSTRING "${MODEL_VER_RAW}" 0 7 MODEL_ID)
    elseif(MODEL_VER_RAW MATCHES "^[0-9a-fA-F]{7,16}$")
        # Short ID provided (as used by upstream tarball names)
        set(MODEL_ID "${MODEL_VER_RAW}")
    else()
        message(WARNING "Unrecognized model_version content: '${MODEL_VER_RAW}'. Proceeding without checksum validation.")
        set(MODEL_ID "${MODEL_VER_RAW}")
    endif()

    set(MODEL_FILENAME "rnnoise_data-${MODEL_ID}.tar.gz")
    set(MODEL_URL "https://media.xiph.org/rnnoise/models/${MODEL_FILENAME}")
    set(MODEL_PATH "${CMAKE_CURRENT_SOURCE_DIR}/${MODEL_FILENAME}")

    # Decide if we need to download
    set(NEED_DOWNLOAD TRUE)
    if(EXISTS "${MODEL_PATH}")
        if(MODEL_SHA256)
            file(SHA256 "${MODEL_PATH}" MODEL_LOCAL_HASH)
            if(MODEL_LOCAL_HASH STREQUAL "${MODEL_SHA256}")
                set(NEED_DOWNLOAD FALSE)
                message(STATUS "Found cached model with valid checksum: ${MODEL_FILENAME}")
            else()
                message(WARNING "Existing ${MODEL_FILENAME} checksum mismatch. Re-downloading with verification.")
                file(REMOVE "${MODEL_PATH}")
            endif()
        else()
            # No known SHA256; trust cached file
            set(NEED_DOWNLOAD FALSE)
            message(STATUS "Found cached model (no checksum available to verify): ${MODEL_FILENAME}")
        endif()
    endif()

    if(NEED_DOWNLOAD)
        message(STATUS "Downloading model: ${MODEL_FILENAME}")
        if(MODEL_SHA256)
            file(DOWNLOAD "${MODEL_URL}" "${MODEL_PATH}"
                 SHOW_PROGRESS TLS_VERIFY ON
                 EXPECTED_HASH "SHA256=${MODEL_SHA256}"
                 STATUS DL_STATUS)
        else()
            # Download without EXPECTED_HASH when only a short ID is known
            file(DOWNLOAD "${MODEL_URL}" "${MODEL_PATH}"
                 SHOW_PROGRESS TLS_VERIFY ON
                 STATUS DL_STATUS)
        endif()
        list(GET DL_STATUS 0 DL_CODE)
        if(NOT DL_CODE EQUAL 0)
            list(GET DL_STATUS 1 DL_MSG)
            file(REMOVE "${MODEL_PATH}")
            message(FATAL_ERROR "Failed to download model file: ${MODEL_URL}\n${DL_MSG}")
        endif()
        if(MODEL_SHA256)
            message(STATUS "Model downloaded and checksum verified.")
        else()
            message(STATUS "Model downloaded (no checksum provided by model_version; skipped verification).")
        endif()
    endif()

    # Extract model archive using CMake (portable across platforms)
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E tar xzf "${MODEL_PATH}"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        RESULT_VARIABLE TAR_RESULT
    )
    if(NOT TAR_RESULT EQUAL 0)
        message(FATAL_ERROR "Failed to extract ${MODEL_FILENAME}. Please extract it manually.")
    else()
        message(STATUS "Model archive extracted.")
    endif()
else()
    message(STATUS "RNNOISE_SKIP_MODEL_DOWNLOAD=ON: Skipping model download/extraction.")
endif()

# Options
option(BUILD_EXAMPLES "Build examples (rnnoise_demo)" OFF)
option(BUILD_TOOLS "Build tools (dump_features, dump_weights_blob)" OFF)
option(ENABLE_SSE4_1 "Enable SSE4.1 optimized sources" OFF)
option(ENABLE_AVX2 "Enable AVX2 optimized sources" OFF)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Includes
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR})

# Define math constants and flags globally for MSVC builds so all targets (examples/tools) see them
if(MSVC)
    add_compile_definitions(_USE_MATH_DEFINES=1 M_PI=3.14159265358979323846)
endif()

# Core sources (from the Makefile's RNNOISE_SOURCES)
set(RNNOISE_SOURCES
    src/denoise.c
    src/rnn.c
    src/pitch.c
    src/kiss_fft.c
    src/celt_lpc.c
    src/nnet.c
    src/nnet_default.c
    src/parse_lpcnet_weights.c
    src/rnnoise_data.c
    src/rnnoise_tables.c
)

# Optional x86 optimized implementations
if(ENABLE_SSE4_1)
    list(APPEND RNNOISE_SOURCES src/x86/nnet_sse4_1.c)
endif()
if(ENABLE_AVX2)
    list(APPEND RNNOISE_SOURCES src/x86/nnet_avx2.c)
endif()

# x86 runtime dispatch files (only add when any x86 optimization enabled)
if(ENABLE_SSE4_1 OR ENABLE_AVX2)
    list(APPEND RNNOISE_SOURCES src/x86/x86_dnn_map.c src/x86/x86cpu.c)
endif()

add_library(rnnoise STATIC ${RNNOISE_SOURCES})

target_include_directories(rnnoise PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_SOURCE_DIR}/src)

target_compile_definitions(rnnoise PRIVATE HAVE_CONFIG_H)

# Xcode: generate only the rnnoise scheme and hide CMake helper schemes
if(CMAKE_GENERATOR STREQUAL "Xcode")
    # Ensure schemes are generated but restrict to rnnoise
    set(CMAKE_XCODE_GENERATE_SCHEME ON)
    set_property(TARGET rnnoise PROPERTY XCODE_GENERATE_SCHEME TRUE)
    foreach(_cmake_tgt ALL_BUILD ZERO_CHECK install package RUN_TESTS test Experimental ExperimentalMemCheck ExperimentalBuild)
        if(TARGET ${_cmake_tgt})
            set_property(TARGET ${_cmake_tgt} PROPERTY XCODE_GENERATE_SCHEME FALSE)
        endif()
    endforeach()
endif()

## Use default CMake output locations
## The previous configuration forced outputs to <build>/../rnnoise via
## ARCHIVE_OUTPUT_DIRECTORY and a POST_BUILD copy step. Those overrides have
## been removed so artifacts are placed by the generator in standard build
## directories (e.g., <build>/, per-config subfolders where applicable).

# Link math library on Unix-like toolchains
if(NOT MSVC)
    target_link_libraries(rnnoise PRIVATE m)
endif()

# Compiler flags for optimizations
if(MSVC)
    # Use /arch for Visual Studio when AVX2 is requested
    if(ENABLE_AVX2)
        # Enable AVX2 codegen
        target_compile_options(rnnoise PRIVATE "/arch:AVX2")
    endif()

    # MSVC-specific optimizations and warnings
    # Apply optimization flags per configuration so Debug is not optimized
    target_compile_options(rnnoise PRIVATE
        $<$<CONFIG:Debug>:/Od>
        $<$<CONFIG:Release>:/O2>
        $<$<CONFIG:RelWithDebInfo>:/O2>
        $<$<CONFIG:MinSizeRel>:/O1>
        "/MP" "/W3")

    # Silence deprecated CRT warnings from some older C code
    target_compile_definitions(rnnoise PRIVATE _CRT_SECURE_NO_WARNINGS)

    # Ensure math constants like M_PI are available on MSVC
    target_compile_definitions(rnnoise PRIVATE _USE_MATH_DEFINES=1 M_PI=3.14159265358979323846)

    # Define architecture macros for source-level feature checks under MSVC
    if(ENABLE_AVX2)
        target_compile_definitions(rnnoise PRIVATE __AVX2__)
    endif()
    if(ENABLE_SSE4_1)
        target_compile_definitions(rnnoise PRIVATE __SSE4_1__)
    endif()

    # Silence MSVC truncation warnings (C4305) originating from the generated rnnoise_data.c
    # Apply the /wd4305 flag only to the huge generated source so other warnings stay visible.
    set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/src/rnnoise_data.c PROPERTIES COMPILE_FLAGS "/wd4305")

    # If SSE4.1-only code is selected, MSVC has no separate SSE4.1 switch; leave as-is. If you run into
    # missing intrinsics, we may need to add per-file compile options or edit source for MSVC intrinsics.
else()
    # GCC / Clang flags
    if(ENABLE_AVX2)
        target_compile_options(rnnoise PRIVATE -mavx -mfma -mavx2)
    elseif(ENABLE_SSE4_1)
        target_compile_options(rnnoise PRIVATE -msse4.1)
    endif()
    # General warnings similar to original Makefile
    target_compile_options(rnnoise PRIVATE -Wall -Wextra -Wno-sign-compare -Wno-parentheses -Wno-long-long -fvisibility=hidden)
endif()

# Examples
if(BUILD_EXAMPLES)
    add_executable(rnnoise_demo examples/rnnoise_demo.c)
    target_link_libraries(rnnoise_demo PRIVATE rnnoise)
endif()

# Tools
if(BUILD_TOOLS)
    add_executable(dump_features src/dump_features.c src/denoise.c src/pitch.c src/celt_lpc.c src/kiss_fft.c src/parse_lpcnet_weights.c src/rnnoise_tables.c)
    target_compile_definitions(dump_features PRIVATE TRAINING)
    target_link_libraries(dump_features PRIVATE ${CMAKE_DL_LIBS})

    add_executable(dump_weights_blob src/write_weights.c)
    target_compile_definitions(dump_weights_blob PRIVATE DUMP_BINARY_WEIGHTS)
    target_link_libraries(dump_weights_blob PRIVATE ${CMAKE_DL_LIBS})

    # Runtime smoke test: prints selected architecture
    add_executable(rnnoise_smoke tools/rnnoise_smoke.c)
    target_link_libraries(rnnoise_smoke PRIVATE rnnoise)
endif()

# Installation (optional)
# Respect CMAKE_SKIP_INSTALL_RULES to omit install targets in subprojects
if(NOT CMAKE_SKIP_INSTALL_RULES)
    install(TARGETS rnnoise
            ARCHIVE DESTINATION lib
            LIBRARY DESTINATION lib
            RUNTIME DESTINATION bin)
    install(DIRECTORY include/ DESTINATION include)
endif()

# Simple helper target to show configuration
message(STATUS "rnnoise: BUILD_EXAMPLES=${BUILD_EXAMPLES} BUILD_TOOLS=${BUILD_TOOLS} ENABLE_SSE4_1=${ENABLE_SSE4_1} ENABLE_AVX2=${ENABLE_AVX2}")

# ----------------------------------------------------------------------------
# Xcode helpers (macOS and iOS)
# These targets generate standalone .xcodeproj projects in subfolders, so you
# can open them directly in Xcode without reconfiguring your main build.
# Usage:
#   cmake --build . --target xcodeproj_macos
#   cmake --build . --target xcodeproj_ios
# The projects will appear in: <build>/xcode-macos and <build>/xcode-ios.
# ----------------------------------------------------------------------------
if(APPLE)
    set(RNNOISE_XCODE_BASE_DIR "${CMAKE_BINARY_DIR}")
    set(RNNOISE_XCODE_MACOS_DIR "${RNNOISE_XCODE_BASE_DIR}/xcode-macos")
    set(RNNOISE_XCODE_IOS_DIR   "${RNNOISE_XCODE_BASE_DIR}/xcode-ios")

    # Optionally generate the sub-projects at configure-time (useful for CMake GUI)
    option(RNNOISE_GEN_XCODE_ON_CONFIGURE "Generate macOS/iOS Xcode subprojects during configure" ON)
    if(RNNOISE_GEN_XCODE_ON_CONFIGURE)
        # Avoid infinite recursion: turn off this option in the sub-configures
        execute_process(
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${RNNOISE_XCODE_MACOS_DIR}"
        )
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -S "${CMAKE_SOURCE_DIR}" -B "${RNNOISE_XCODE_MACOS_DIR}" -G Xcode
            -DRNNOISE_SKIP_MODEL_DOWNLOAD=${RNNOISE_SKIP_MODEL_DOWNLOAD}
            -DRNNOISE_OUTPUT_BASE_DIR:PATH=${CMAKE_BINARY_DIR}
            -DBUILD_EXAMPLES=OFF -DBUILD_TOOLS=OFF
            -DCMAKE_SKIP_INSTALL_RULES=ON
            -DCMAKE_SUPPRESS_REGENERATION=ON
            -DCMAKE_XCODE_GENERATE_SCHEME=ON
            -DRNNOISE_GEN_XCODE_ON_CONFIGURE=OFF
            -DCMAKE_OSX_SYSROOT=macosx
        RESULT_VARIABLE RNNOISE_XCODE_MAC_RES
    )
        if(NOT RNNOISE_XCODE_MAC_RES EQUAL 0)
            message(WARNING "Failed to generate macOS Xcode project at configure-time. You can still run the xcodeproj_macos target later.")
        endif()

        execute_process(
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${RNNOISE_XCODE_IOS_DIR}"
        )
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -S "${CMAKE_SOURCE_DIR}" -B "${RNNOISE_XCODE_IOS_DIR}" -G Xcode
            -DCMAKE_SYSTEM_NAME=iOS
            -DCMAKE_OSX_SYSROOT=iphoneos
            -DCMAKE_OSX_ARCHITECTURES=arm64
            -DCMAKE_IOS_INSTALL_COMBINED=YES
            -DRNNOISE_SKIP_MODEL_DOWNLOAD=${RNNOISE_SKIP_MODEL_DOWNLOAD}
            -DRNNOISE_OUTPUT_BASE_DIR:PATH=${CMAKE_BINARY_DIR}
            -DBUILD_EXAMPLES=OFF -DBUILD_TOOLS=OFF
            -DCMAKE_SKIP_INSTALL_RULES=ON
            -DCMAKE_SUPPRESS_REGENERATION=ON
            -DCMAKE_XCODE_GENERATE_SCHEME=ON
            -DRNNOISE_GEN_XCODE_ON_CONFIGURE=OFF
        RESULT_VARIABLE RNNOISE_XCODE_IOS_RES
    )
        if(NOT RNNOISE_XCODE_IOS_RES EQUAL 0)
            message(WARNING "Failed to generate iOS Xcode project at configure-time. You can still run the xcodeproj_ios target later.")
        endif()
    endif()
endif()
