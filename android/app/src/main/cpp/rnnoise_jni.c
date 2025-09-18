// JNI bridge for org.xiph.rnnoise.RnnoiseJni
#include <jni.h>
#include <stdint.h>
#include "rnnoise.h"

JNIEXPORT jlong JNICALL
Java_org_xiph_rnnoise_RnnoiseJni_create(JNIEnv* env, jclass clazz) {
  (void)env; (void)clazz;
  DenoiseState* st = rnnoise_create(NULL);
  return (jlong)(intptr_t)st;
}

JNIEXPORT void JNICALL
Java_org_xiph_rnnoise_RnnoiseJni_destroy(JNIEnv* env, jclass clazz, jlong handle) {
  (void)env; (void)clazz;
  DenoiseState* st = (DenoiseState*)(intptr_t)handle;
  if (st) rnnoise_destroy(st);
}

JNIEXPORT jint JNICALL
Java_org_xiph_rnnoise_RnnoiseJni_processFrame(JNIEnv* env, jclass clazz,
                                              jlong handle,
                                              jshortArray in_, jshortArray out_) {
  (void)clazz;
  DenoiseState* st = (DenoiseState*)(intptr_t)handle;
  if (!st) return -1;
  if ((*env)->GetArrayLength(env, in_) < 480 || (*env)->GetArrayLength(env, out_) < 480) return -2;
  jshort* in = (*env)->GetShortArrayElements(env, in_, NULL);
  jshort* out = (*env)->GetShortArrayElements(env, out_, NULL);
  int ret = rnnoise_process_frame(st, out, in);
  (*env)->ReleaseShortArrayElements(env, in_, in, JNI_ABORT);
  (*env)->ReleaseShortArrayElements(env, out_, out, 0);
  return ret;
}
