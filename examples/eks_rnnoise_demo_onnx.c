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
#include <string.h>
#include "rnnoise.h"
#ifdef RNNOISE_PURE_ONNX
#include "rnnoise_pure_onnx.h" /* for rnnoise_pure_onnx_load */
#endif

#define FRAME_SIZE 480

/*
 Simple test/demo program able to exercise either embedded RNNoise or PURE_ONNX
 build.

 Usage (embedded / legacy):
   eks_rnnoise_demo_onnx <input.raw> <out.raw>

 Usage (PURE_ONNX):
   eks_rnnoise_demo_onnx <input.raw> <out.raw> [model.onnx]
 If model path is omitted in PURE_ONNX build it defaults to "model.onnx" in the
 current working directory.
 16‑bit mono little-endian PCM, 48 kHz. Output is denoised PCM.
*/
int main(int argc, char **argv) {
  int i;
  int first = 1;
  float x[FRAME_SIZE];
  FILE *f1 = NULL, *fout = NULL;
  DenoiseState *st = NULL;
#ifdef RNNOISE_PURE_ONNX
  const char *onnx_model = "model.onnx";
#endif
#ifdef USE_WEIGHTS_FILE
  RNNModel *model = rnnoise_model_from_filename("weights_blob.bin");
  st = rnnoise_create(model);
#else
  st = rnnoise_create(NULL);
#endif

  /* Arg parsing */
#ifdef RNNOISE_PURE_ONNX
  if (argc < 3 || argc > 4) {
    fprintf(stderr, "usage: %s <in.raw> <out.raw> [model.onnx]\n", argv[0]);
    return 1;
  }
  if (argc == 4) onnx_model = argv[3];
#else
  if (argc != 3) {
    fprintf(stderr, "usage: %s <in.raw> <out.raw>\n", argv[0]);
    return 1;
  }
#endif

  f1 = fopen(argv[1], "rb");
  if(!f1) { fprintf(stderr, "Failed to open input %s\n", argv[1]); return 1; }
  fout = fopen(argv[2], "wb");
  if(!fout) { fprintf(stderr, "Failed to open output %s\n", argv[2]); fclose(f1); return 1; }
  /* PURE_ONNX: load ONNX model after state init */
#ifdef RNNOISE_PURE_ONNX
  if(rnnoise_pure_onnx_load(st, onnx_model) != 0) {
    fprintf(stderr, "[RNNoise][PURE_ONNX] Failed to load ONNX model %s\n", onnx_model);
  } else {
    fprintf(stderr, "[RNNoise][PURE_ONNX] Loaded ONNX model %s\n", onnx_model);
  }
#endif

  while (1) {
    short tmp[FRAME_SIZE];
    size_t r = fread(tmp, sizeof(short), FRAME_SIZE, f1);
    if (r != FRAME_SIZE) break;
    for (i=0;i<FRAME_SIZE;i++) x[i] = (float)tmp[i];
    rnnoise_process_frame(st, x, x);
    for (i=0;i<FRAME_SIZE;i++) tmp[i] = (short)(x[i]);
    if (!first) fwrite(tmp, sizeof(short), FRAME_SIZE, fout);
    first = 0;
  }
  rnnoise_destroy(st);
  fclose(f1);
  fclose(fout);
#ifdef USE_WEIGHTS_FILE
  rnnoise_model_free(model);
#endif
  return 0;
}
