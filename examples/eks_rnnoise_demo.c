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

#ifndef RNNOISE_HAVE_GUITAR_MASK
static float rnnoise_process_frame_guitar_mask(DenoiseState *st,
                                              float *out,
                                              const float *in,
                                              float *band_gains,
                                              int band_gains_len)
{
  (void)band_gains; (void)band_gains_len; /* Unused in stub */
  return rnnoise_process_frame(st, out, in);
}
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
          "Usage: %s <input raw 16-bit mono 48k> <output raw> [--guitar-mask mask.csv]"\
          "\n\n"
          "Description:\n"
          "  Processes 16-bit PCM mono @48k using standard rnnoise or (if available)\n"
          "  the guitar mask variant. Outputs 16-bit PCM raw (no WAV header).\n\n"
          "Options:\n"
          "  --guitar-mask <file>  Write per-frame guitar probability and aggregate\n"
          "                        average band gains (draft API).\n"
          , prog);
}

int main(int argc, char **argv) {
  int i; int first = 1; float x[FRAME_SIZE];
  FILE *f1 = NULL, *fout = NULL, *fmask = NULL; DenoiseState *st;
  const char *maskPath = NULL;
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

  long frameIndex = 0;
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
      /* Optionally compute average gain if real implementation differs; here we dump raw band gains */
      fprintf(fmask, "%ld,%.6f", frameIndex, guitar_prob);
      if (maskPath) {
        for (i = 0; i < RNNOISE_BAND_COUNT; ++i) fprintf(fmask, ",%.6f", band_gains[i]);
      }
      fprintf(fmask, "\n");
    }
    frameIndex++;

    if (r < FRAME_SIZE) break; /* Don't loop again after partial */
  }

  rnnoise_destroy(st);
  if (fmask) fclose(fmask);
  fclose(f1); fclose(fout);
#ifdef USE_WEIGHTS_FILE
  rnnoise_model_free(model);
#endif
  return 0;
}
