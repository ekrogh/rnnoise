package org.xiph.rnnoise;

public final class RnnoiseJni {
  static {
    System.loadLibrary("rnnoise_jni");
  }

  private RnnoiseJni() {}

  // Handle lifecycle
  public static native long create();
  public static native void destroy(long handle);

  /**
   * Process one 480-sample 48kHz frame.
   * in/out arrays must be length >= 480.
   * Returns rnnoise_process_frame() result.
   */
  public static native int processFrame(long handle, short[] in, short[] out);
}
