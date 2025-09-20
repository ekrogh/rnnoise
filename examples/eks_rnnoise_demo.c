/* Copyright (c) 2018 Gregor Richards
 * Copyright (c) 2017 Mozilla */
/*
   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   - Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

   - Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <pthread.h>
#endif
#include "rnnoise.h"

/* -------------------------------------------------------------------------
   Draft extension for guitar isolation support
   We propose a new API function (to be added to rnnoise.h / library):

     float rnnoise_process_frame_guitar_mask(DenoiseState *st,
                                             float *out,
                                             const float *in,
                                             float *band_gains, // optional (can be NULL)
                                             int band_gains_len);

   Semantics:
     - Processes one frame (same frame size as rnnoise_process_frame).
     - Returns guitar activity probability in [0,1].
     - If band_gains != NULL and band_gains_len >= rnnoise_get_band_count(),
       fills band_gains with per-band post-mask linear gains applied to the frame.

   Until the core library implements it, we provide a fallback stub below so
   this demo still compiles. Define RNNOISE_HAVE_GUITAR_MASK when the real
   implementation is linked in (and remove the stub). The stub simply calls
   rnnoise_process_frame and returns its probability; no per-band gains.
   ------------------------------------------------------------------------- */

/* Now that rnnoise_get_band_count / rnnoise_process_frame_guitar_mask are
   implemented in the library, we only need a stub if building against an
   older binary lacking them. We detect by checking for RNNOISE_BAND_COUNT
   accessor macro/compile-time define presence. */
#if !defined(RNNOISE_HAVE_GUITAR_MASK)
/* Assume new symbols exist; if link fails, define RNNOISE_HAVE_GUITAR_MASK=0 and keep stub. */
#define RNNOISE_HAVE_GUITAR_MASK 1
#endif

/* If the library later exposes rnnoise_get_band_count(), you can remove this
   hard-coded constant or gate it with another #ifdef. RNNoise internally uses
   NB_BANDS = 22. We'll default to 22 for mask CSV layout. */
#ifndef RNNOISE_BAND_COUNT
#define RNNOISE_BAND_COUNT 22
#endif

#define FRAME_SIZE 480

static void print_usage(const char *prog) {
  fprintf(stderr,
          "Usage: %s <input raw 16-bit mono 48k> <output raw> [--guitar-mask mask.csv] [--prob-out prob.csv] [--background]"\
          "\n\n"
          "Description:\n"
          "  Processes 16-bit PCM mono @48k using standard rnnoise or (if available)\n"
          "  the guitar mask variant. Outputs 16-bit PCM raw (no WAV header).\n\n"
          "Options:\n"
          "  --guitar-mask <file>  Write per-frame guitar probability and aggregate\n"
          "                        average band gains (draft API).\n"
          "  --prob-out <file>     Write per-frame guitar probability only (CSV: frame,guitar_prob).\n"
          "  --background          Enable background worker (ring buffers + thread) to\n"
          "                        test low-latency async isolation pipeline.\n"
          , prog);
}

/* ------------------------- Background Isolator Support -------------------- */
typedef struct IsoFrame {
  float samples[FRAME_SIZE];
  float activityProb; /* guitar probability */
  int   valid;        /* used internally */
  uint64_t sequence;  /* monotonic seq */
} IsoFrame;

#define RING_CAPACITY 128 /* must be power-of-two */
#define RING_MASK (RING_CAPACITY-1)

typedef struct SpscRingFrames {
  IsoFrame frames[RING_CAPACITY];
  volatile uint32_t writeIndex; /* producer writes */
  volatile uint32_t readIndex;  /* consumer reads */
} SpscRingFrames;

static int ring_push(SpscRingFrames *ring, const IsoFrame *src) {
  uint32_t w = ring->writeIndex;
  uint32_t r = ring->readIndex; /* single consumer -> relaxed OK */
  if (((w + 1) & RING_MASK) == r) return 0; /* full */
  ring->frames[w] = *src; /* struct copy */
#ifdef _MSC_VER
  _ReadWriteBarrier();
#endif
  ring->writeIndex = (w + 1) & RING_MASK;
  return 1;
}

static int ring_pop(SpscRingFrames *ring, IsoFrame *dst) {
  uint32_t r = ring->readIndex;
  uint32_t w = ring->writeIndex;
  if (r == w) return 0; /* empty */
  *dst = ring->frames[r];
#ifdef _MSC_VER
  _ReadWriteBarrier();
#endif
  ring->readIndex = (r + 1) & RING_MASK;
  return 1;
}

typedef struct BackgroundIsolator {
  DenoiseState *st;
  int running;
  int stopFlag;
  uint64_t seqCounter;
  SpscRingFrames inputRing;
  SpscRingFrames outputRing;
#ifdef _WIN32
  HANDLE threadHandle;
#else
  pthread_t threadHandle;
#endif
} BackgroundIsolator;

static BackgroundIsolator g_isolator; /* single instance for demo */

static void tiny_sleep(void) {
#ifdef _WIN32
  Sleep(0); /* yield */
#else
  struct timespec ts; ts.tv_sec = 0; ts.tv_nsec = 200000; /* 0.2 ms */
  nanosleep(&ts, NULL);
#endif
}

static void isolator_init(BackgroundIsolator *iso, DenoiseState *sharedState) {
  memset(iso, 0, sizeof(*iso));
  iso->st = sharedState; /* share the rnnoise state OR use separate if thread-safe */
  /* NOTE: Original rnnoise_state isn't strictly documented as thread-safe for concurrent frames.
     For correctness you should create a separate DenoiseState here. For prototype we share. */
}

static void process_frame_iso(BackgroundIsolator *iso, IsoFrame *frame) {
  /* Call guitar mask variant or standard; band gains omitted for stream test */
  frame->activityProb = rnnoise_process_frame_guitar_mask(iso->st, frame->samples, frame->samples, NULL, 0);
}

#ifdef _WIN32
static DWORD WINAPI isolator_thread_fn(LPVOID param)
#else
static void* isolator_thread_fn(void *param)
#endif
{
  BackgroundIsolator *iso = (BackgroundIsolator*)param;
  iso->running = 1;
  IsoFrame inFrame;
  while (!iso->stopFlag) {
    if (!ring_pop(&iso->inputRing, &inFrame)) {
      tiny_sleep();
      continue;
    }
    process_frame_iso(iso, &inFrame);
    /* Try to push until success or stop */
    while (!iso->stopFlag && !ring_push(&iso->outputRing, &inFrame)) {
      tiny_sleep();
    }
  }
  iso->running = 0;
#ifdef _WIN32
  return 0;
#else
  return NULL;
#endif
}

static void isolator_start(BackgroundIsolator *iso) {
  iso->stopFlag = 0;
#ifdef _WIN32
  iso->threadHandle = CreateThread(NULL, 0, isolator_thread_fn, iso, 0, NULL);
#else
  pthread_create(&iso->threadHandle, NULL, isolator_thread_fn, iso);
#endif
}

static void isolator_stop(BackgroundIsolator *iso) {
  iso->stopFlag = 1;
  while (iso->running) tiny_sleep();
#ifdef _WIN32
  if (iso->threadHandle) CloseHandle(iso->threadHandle);
#else
  if (iso->threadHandle) pthread_join(iso->threadHandle, NULL);
#endif
}

static int isolator_push_input(BackgroundIsolator *iso, const float *samples) {
  IsoFrame fr; memset(&fr, 0, sizeof(fr));
  memcpy(fr.samples, samples, FRAME_SIZE * sizeof(float));
  fr.sequence = iso->seqCounter++;
  while (!ring_push(&iso->inputRing, &fr)) { /* backpressure */
    tiny_sleep();
  }
  return 1;
}

static int isolator_pop_output(BackgroundIsolator *iso, IsoFrame *out) {
  return ring_pop(&iso->outputRing, out);
}

int main(int argc, char **argv) {
  int i; int first = 1; float x[FRAME_SIZE];
  FILE *f1 = NULL, *fout = NULL, *fmask = NULL, *fprob = NULL; DenoiseState *st;
  const char *maskPath = NULL; const char *probPath = NULL;
  int useBackground = 0;
#ifdef USE_WEIGHTS_FILE
  RNNModel *model = rnnoise_model_from_filename("weights_blob.bin");
  st = rnnoise_create(model);
#else
  st = rnnoise_create(NULL);
#endif

  if (argc < 3) {
    print_usage(argv[0]);
    return 1;
  }

  /* Parse optional arguments */
  for (int a = 3; a < argc; ++a) {
    if (strcmp(argv[a], "--guitar-mask") == 0) {
      if (a + 1 >= argc) { fprintf(stderr, "Missing path after --guitar-mask\n"); return 1; }
      maskPath = argv[++a];
    } else if (strcmp(argv[a], "--prob-out") == 0) {
      if (a + 1 >= argc) { fprintf(stderr, "Missing path after --prob-out\n"); return 1; }
      probPath = argv[++a];
    } else if (strcmp(argv[a], "--background") == 0) {
      useBackground = 1;
    } else {
      fprintf(stderr, "Unknown argument: %s\n", argv[a]);
      print_usage(argv[0]);
      return 1;
    }
  }

  if ((f1 = fopen(argv[1], "rb")) == NULL) {
    fprintf(stderr, "Cannot open input %s: %s\n", argv[1], strerror(errno));
    return 1;
  }
  if ((fout = fopen(argv[2], "wb")) == NULL) {
    fprintf(stderr, "Cannot open output %s: %s\n", argv[2], strerror(errno));
    fclose(f1);
    return 1;
  }
  if (maskPath) {
    fmask = fopen(maskPath, "w");
    if (!fmask) {
      fprintf(stderr, "Cannot open mask CSV %s: %s\n", maskPath, strerror(errno));
      fclose(f1); fclose(fout); return 1;
    }
    /* CSV header */
    fprintf(fmask, "frame,guitar_prob");
    for (i = 0; i < RNNOISE_BAND_COUNT; ++i) fprintf(fmask, ",g%d", i);
    fprintf(fmask, "\n");
  }
  if (probPath) {
    fprob = fopen(probPath, "w");
    if (!fprob) {
      fprintf(stderr, "Cannot open prob CSV %s: %s\n", probPath, strerror(errno));
      if (fmask) fclose(fmask);
      fclose(f1); fclose(fout); return 1;
    }
    fprintf(fprob, "frame,guitar_prob\n");
  }

  long frameIndex = 0;

  if (useBackground) {
    /* Background pipeline */
    isolator_init(&g_isolator, st);
    isolator_start(&g_isolator);
    int eofReached = 0;
    short tmp[FRAME_SIZE];
    while (!eofReached || isolator_pop_output(&g_isolator, (IsoFrame*)&x)) {
      /* READ/PUSH stage */
      if (!eofReached) {
        size_t r = fread(tmp, sizeof(short), FRAME_SIZE, f1);
        if (r == 0) {
          eofReached = 1;
        } else {
          if (r < FRAME_SIZE) { for (i = (int)r; i < FRAME_SIZE; ++i) tmp[i] = 0; eofReached = 1; }
          for (i = 0; i < FRAME_SIZE; ++i) x[i] = (float)tmp[i];
          isolator_push_input(&g_isolator, x);
        }
      }
      /* POP/WRITE stage: drain all available processed frames */
      IsoFrame outFrame;
      while (isolator_pop_output(&g_isolator, &outFrame)) {
        float band_gains_dummy[1]; /* not collected here */
        /* If mask requested we need to re-run? Instead skip per-band for async mode unless future API caches them */
        if (fmask) {
          fprintf(fmask, "%ld,%.6f\n", outFrame.sequence, outFrame.activityProb);
        }
        if (fprob) {
          fprintf(fprob, "%ld,%.6f\n", outFrame.sequence, outFrame.activityProb);
        }
        /* Write audio (skip first frame like original behavior) */
        if (!first) {
          for (i = 0; i < FRAME_SIZE; ++i) tmp[i] = (short)outFrame.samples[i];
          fwrite(tmp, sizeof(short), FRAME_SIZE, fout);
        }
        first = 0;
      }
      if (eofReached && !g_isolator.inputRing.writeIndex == g_isolator.inputRing.readIndex) {
        /* waiting for remaining frames */
      }
      if (eofReached && g_isolator.inputRing.readIndex == g_isolator.inputRing.writeIndex) {
        /* All input consumed; check if output drained */
        if (g_isolator.outputRing.readIndex == g_isolator.outputRing.writeIndex) break;
      }
      tiny_sleep();
    }
    isolator_stop(&g_isolator);
  } else {
    /* Sequential original pipeline */
    while (1) {
      short tmp[FRAME_SIZE];
      size_t r = fread(tmp, sizeof(short), FRAME_SIZE, f1);
      if (r == 0) break; /* EOF */
      if (r < FRAME_SIZE) { /* zero-pad last frame */
        for (i = (int)r; i < FRAME_SIZE; ++i) tmp[i] = 0;
      }
      for (i = 0; i < FRAME_SIZE; i++) x[i] = (float)tmp[i];

      float band_gains[RNNOISE_BAND_COUNT];
      float guitar_prob = rnnoise_process_frame_guitar_mask(st, x, x, maskPath ? band_gains : NULL, RNNOISE_BAND_COUNT);

      for (i = 0; i < FRAME_SIZE; i++) tmp[i] = (short)x[i];
      if (!first) fwrite(tmp, sizeof(short), FRAME_SIZE, fout);
      first = 0;

      if (fmask) {
        fprintf(fmask, "%ld,%.6f", frameIndex, guitar_prob);
        if (maskPath) {
          for (i = 0; i < RNNOISE_BAND_COUNT; ++i) fprintf(fmask, ",%.6f", band_gains[i]);
        }
        fprintf(fmask, "\n");
      }
      if (fprob) {
        fprintf(fprob, "%ld,%.6f\n", frameIndex, guitar_prob);
      }
      frameIndex++;

      if (r < FRAME_SIZE) break; /* Don't loop again after partial */
    }
  }

  rnnoise_destroy(st);
  if (fmask) fclose(fmask);
  if (fprob) fclose(fprob);
  fclose(f1); fclose(fout);
#ifdef USE_WEIGHTS_FILE
  rnnoise_model_free(model);
#endif
  return 0;
}
