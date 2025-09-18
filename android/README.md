Android NDK integration for rnnoise

This folder provides a minimal JNI wrapper and CMake build files to link rnnoise into an Android app.

Layout
- app/src/main/cpp/CMakeLists.txt: Builds rnnoise as a subdirectory and produces a shared lib `librnnoise_jni.so`.
- app/src/main/cpp/rnnoise_jni.c: Minimal JNI bridge.

How to use in Android Studio
1) In your Android project, copy or reference this `android/app/src/main/cpp` folder under your app module.
2) In your app module's build.gradle, enable externalNativeBuild.cmake and point to `src/main/cpp/CMakeLists.txt`.
3) Choose ABIs via ndk.abiFilters (e.g., arm64-v8a, armeabi-v7a).
4) Sync and build. The JNI library will be packaged into your APK/AAB.

Notes
- The top-level rnnoise CMake now supports `-DRNNOISE_SKIP_MODEL_DOWNLOAD=ON` so NDK builds can avoid network.
- rnnoise expects 48 kHz audio and 480-sample frames.
