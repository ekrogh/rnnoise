cmake_minimum_required(VERSION 3.15)
project(rnnoise_android C)

# Path to rnnoise root (this repository)
# From android/app/src/main/cpp up five levels to repo root
# You can override with: -DRNNOISE_ROOT=D:/path/to/rnnoise
if(NOT DEFINED RNNOISE_ROOT)
  set(RNNOISE_ROOT ${CMAKE_SOURCE_DIR}/../../../../../)
endif()
message(STATUS "RNNOISE_ROOT=${RNNOISE_ROOT}")

# Build rnnoise as a subdirectory, disabling examples/tools and x86-specific opts
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(ENABLE_SSE4_1 OFF CACHE BOOL "" FORCE)
set(ENABLE_AVX2 OFF CACHE BOOL "" FORCE)
# Do not force RNNOISE_SKIP_MODEL_DOWNLOAD here.
# Root CMake defaults to downloading the model when needed.
# To skip download (when rnnoise_data.c is committed), pass:
#   -DRNNOISE_SKIP_MODEL_DOWNLOAD=ON

add_subdirectory(${RNNOISE_ROOT} ${CMAKE_BINARY_DIR}/rnnoise-build EXCLUDE_FROM_ALL)

# JNI bridge shared library
add_library(rnnoise_jni SHARED
  rnnoise_jni.c
)

target_include_directories(rnnoise_jni PRIVATE
  ${RNNOISE_ROOT}/include
)

find_library(log-lib log)

target_link_libraries(rnnoise_jni
  PRIVATE rnnoise ${log-lib}
)
