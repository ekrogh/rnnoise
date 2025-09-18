#!/usr/bin/env bash
set -euo pipefail

# One-shot iOS build for rnnoise -> rnnoise.xcframework
# Env overrides:
#   DEPLOYMENT_TARGET (default 12.0)
#   CONFIG (default Release)
#   RNNOISE_SKIP_MODEL_DOWNLOAD (use ON to skip network if src/rnnoise_data.c exists)
#   BUILD_DIR, ARTIFACTS_DIR (optional)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/ios}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"
CONFIG="${CONFIG:-Release}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-12.0}"
GENERATOR="Xcode"

command -v xcodebuild >/dev/null || { echo "xcodebuild not found (install Xcode)."; exit 1; }
command -v cmake >/dev/null || { echo "cmake not found."; exit 1; }

mkdir -p "$BUILD_DIR" "$ARTIFACTS_DIR"

MODEL_FLAG="-DRNNOISE_SKIP_MODEL_DOWNLOAD=${RNNOISE_SKIP_MODEL_DOWNLOAD:-OFF}"

cmake_common=(
  -G "$GENERATOR"
  -DCMAKE_BUILD_TYPE="$CONFIG"
  -DBUILD_EXAMPLES=OFF
  -DBUILD_TOOLS=OFF
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO
  "$MODEL_FLAG"
)

echo "Building rnnoise iOS static libs (CONFIG=$CONFIG, iOS $DEPLOYMENT_TARGET)…"

# iPhoneOS (device, arm64)
os_dir="$BUILD_DIR/iphoneos"
cmake -S "$ROOT_DIR" -B "$os_dir" \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "${cmake_common[@]}"
cmake --build "$os_dir" --config "$CONFIG" --target rnnoise

# iPhoneSimulator (arm64)
sim_arm64_dir="$BUILD_DIR/iphonesimulator-arm64"
cmake -S "$ROOT_DIR" -B "$sim_arm64_dir" \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "${cmake_common[@]}"
cmake --build "$sim_arm64_dir" --config "$CONFIG" --target rnnoise

# iPhoneSimulator (x86_64)
sim_x64_dir="$BUILD_DIR/iphonesimulator-x86_64"
cmake -S "$ROOT_DIR" -B "$sim_x64_dir" \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  "${cmake_common[@]}"
cmake --build "$sim_x64_dir" --config "$CONFIG" --target rnnoise

# Resolve built libs
LIB_OS="$os_dir/$CONFIG-iphoneos/librnnoise.a"
LIB_SIM_ARM64="$sim_arm64_dir/$CONFIG-iphonesimulator/librnnoise.a"
LIB_SIM_X64="$sim_x64_dir/$CONFIG-iphonesimulator/librnnoise.a"

for f in "$LIB_OS" "$LIB_SIM_ARM64" "$LIB_SIM_X64"; do
  [[ -f "$f" ]] || { echo "Missing built lib: $f"; exit 1; }
done

XC_OUT="$ARTIFACTS_DIR/rnnoise.xcframework"
rm -rf "$XC_OUT"

echo "Packaging XCFramework -> $XC_OUT"
xcodebuild -create-xcframework \
  -library "$LIB_OS" -headers "$ROOT_DIR/include" \
  -library "$LIB_SIM_ARM64" -headers "$ROOT_DIR/include" \
  -library "$LIB_SIM_X64" -headers "$ROOT_DIR/include" \
  -output "$XC_OUT"

echo "Done: $XC_OUT"
