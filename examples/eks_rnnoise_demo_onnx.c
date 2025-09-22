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
#include <math.h>
#include "rnnoise.h"
#ifdef RNNOISE_PURE_ONNX
#include "rnnoise_pure_onnx.h" /* for rnnoise_pure_onnx_load */
#endif

#define FRAME_SIZE 480

/*
 Simple test/demo program able to exercise either embedded RNNoise or PURE_ONNX
 build, with optional guitar-only gating to more aggressively suppress
 non-guitar content based on the model's activity probability output.

 Usage (embedded / legacy):
   eks_rnnoise_demo_onnx <input.raw> <out.raw> [options]

 Usage (PURE_ONNX):
   eks_rnnoise_demo_onnx <input.raw> <out.raw> [model.onnx] [options]

 Options:
   --guitar-only                    Enable post gain-frame gating to isolate guitar
   --guitar-threshold <float>       Probability threshold (default 0.55)
   --guitar-atten-db <float>        Attenuation (dB) applied when below threshold (default -40)
   --prob-floor <float>             Probability floor; below it energy heuristic may promote (default 0.0)
   --energy-threshold <float>       RMS (PCM) heuristic activation threshold (default 0.0=off)
   --min-scale <float>              Minimum gating scale (avoid full mute) (default 0.0)
   --dump-prob-csv <path>           Write per-frame CSV diagnostics (frame,prob,rms,active,scale)
   --help                           Show this help

 Notes:
   16-bit mono little-endian PCM, 48 kHz. Output is denoised (and optionally gated) PCM.
   Gating uses a smoothed envelope to reduce choppiness.
*/
int main(int argc, char **argv) {
  int i;
  int first = 1;
  float x[FRAME_SIZE];
  FILE *f1 = NULL, *fout = NULL;
  DenoiseState *st = NULL;
#ifdef RNNOISE_PURE_ONNX
  /* Model path argument still handled positionally before flags */
#endif
  int guitar_only = 0;
  float guitar_threshold = 0.55f;
  float guitar_atten_db = -40.0f;
  float env_scale = 1.0f; /* smoothed scale */
#define ENV_ATTACK 0.35f
#define ENV_RELEASE 0.08f
  /* Diagnostics / heuristic gating additions */
  float prob_floor = 0.0f;              /* promote via heuristic if prob below this */
  float energy_threshold = 0.0f;        /* RMS (PCM units) threshold to treat as active */
  float min_scale = 0.0f;               /* floor for envelope scale to avoid total mute */
  /* Adaptive threshold (EMA-based) */
  float adaptive_factor = 0.0f;         /* multiply EMA(prob) by this; if higher than static threshold use it */
  float ema_alpha = 0.05f;              /* smoothing factor for EMA of probability */
  float ema_prob = 0.0f;                /* running EMA of probability */
  /* Soft mask controls */
  int soft_mask_mode = 0;               /* 0 = hard gate, 1 = soft mask */
  float gamma_val = 1.0f;               /* exponent for soft mask shaping */
  const char *csv_path = NULL;          /* optional per-frame CSV dump */
    /* Instrumentation */
    unsigned long debug_first_n = 0;     /* dump first N probabilities */
    int force_threshold_enabled = 0;     /* override dynamic/static threshold with fixed */
    float force_threshold_value = 0.0f;  /* value for forced threshold */
    int prob_hist_enabled = 0;           /* whether to accumulate & dump histogram */
    unsigned long prob_hist_bins[11];    /* 0-0.1 ... 0.9-1.0 plus overflow guard */
    memset(prob_hist_bins, 0, sizeof(prob_hist_bins));
  unsigned long frame_index = 0;
  unsigned long active_frames = 0;
  unsigned long gated_frames = 0;
  double prob_accum = 0.0;
  float max_prob_initial = 0.0f;      /* Track max prob in initial window */
  int fallback_escalated = 0;          /* Whether we've boosted safety floors */
  int gating_disabled_runtime = 0;     /* Whether we've fully disabled gating at runtime */
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
  /* Basic positional validation first (we allow extra option args following). */
#ifdef RNNOISE_PURE_ONNX
  if (argc < 3) {
    fprintf(stderr, "usage: %s <in.raw> <out.raw> [model.onnx] [options]\n", argv[0]);
    return 1;
  }
  /* Determine if third arg is model (exists as file) or an option */
  if (argc >= 4) {
    if (argv[3][0] != '-' ) {
      onnx_model = argv[3];
    }
  }
#else
  if (argc < 3) {
    fprintf(stderr, "usage: %s <in.raw> <out.raw> [options]\n", argv[0]);
    return 1;
  }
#endif

  /* Parse flags after required args (+ optional model path in PURE_ONNX) */
  int argi = 3;
#ifdef RNNOISE_PURE_ONNX
  if (argi < argc && argv[argi] && argv[argi][0] != '-' && strcmp(argv[argi], onnx_model)==0) {
    /* Skip model path already consumed */
    argi++;
  }
#endif
  for (; argi < argc; ++argi) {
    if (strcmp(argv[argi], "--guitar-only") == 0) {
      guitar_only = 1;
    } else if (strcmp(argv[argi], "--guitar-threshold") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --guitar-threshold\n"); return 1; }
      guitar_threshold = (float)atof(argv[++argi]);
      if (guitar_threshold < 0.f) guitar_threshold = 0.f; if (guitar_threshold > 1.f) guitar_threshold = 1.f;
    } else if (strcmp(argv[argi], "--guitar-atten-db") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --guitar-atten-db\n"); return 1; }
      guitar_atten_db = (float)atof(argv[++argi]);
      if (guitar_atten_db > 0.f) guitar_atten_db = 0.f; /* ensure attenuation */
    } else if (strcmp(argv[argi], "--prob-floor") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --prob-floor\n"); return 1; }
      prob_floor = (float)atof(argv[++argi]); if (prob_floor < 0.f) prob_floor = 0.f; if (prob_floor > 1.f) prob_floor = 1.f;
    } else if (strcmp(argv[argi], "--energy-threshold") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --energy-threshold\n"); return 1; }
      energy_threshold = (float)atof(argv[++argi]); if (energy_threshold < 0.f) energy_threshold = 0.f;
    } else if (strcmp(argv[argi], "--min-scale") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --min-scale\n"); return 1; }
      min_scale = (float)atof(argv[++argi]); if (min_scale < 0.f) min_scale = 0.f; if (min_scale > 1.f) min_scale = 1.f;
    } else if (strcmp(argv[argi], "--dump-prob-csv") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --dump-prob-csv\n"); return 1; }
      csv_path = argv[++argi];
    } else if (strcmp(argv[argi], "--adaptive-factor") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --adaptive-factor\n"); return 1; }
      adaptive_factor = (float)atof(argv[++argi]); if (adaptive_factor < 0.f) adaptive_factor = 0.f;
    } else if (strcmp(argv[argi], "--ema-alpha") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --ema-alpha\n"); return 1; }
      ema_alpha = (float)atof(argv[++argi]); if (ema_alpha <= 0.f) ema_alpha = 0.01f; if (ema_alpha > 1.f) ema_alpha = 1.f;
    } else if (strcmp(argv[argi], "--debug-first-n") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --debug-first-n\n"); return 1; }
      debug_first_n = (unsigned long)atol(argv[++argi]);
    } else if (strcmp(argv[argi], "--force-threshold") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --force-threshold\n"); return 1; }
      force_threshold_value = (float)atof(argv[++argi]); if (force_threshold_value < 0.f) force_threshold_value = 0.f; if (force_threshold_value > 1.f) force_threshold_value = 1.f; force_threshold_enabled = 1;
    } else if (strcmp(argv[argi], "--dump-prob-hist") == 0) {
      prob_hist_enabled = 1;
    } else if (strcmp(argv[argi], "--soft-mask") == 0) {
      /* Enable soft mask mode: apply continuous scaling instead of binary gate */
      guitar_only = 1; /* implies gating path active */
      soft_mask_mode = 1;
    } else if (strcmp(argv[argi], "--gamma") == 0) {
      if (argi + 1 >= argc) { fprintf(stderr, "Missing value after --gamma\n"); return 1; }
      gamma_val = (float)atof(argv[++argi]);
      if (gamma_val < 0.1f) gamma_val = 0.1f; if (gamma_val > 8.f) gamma_val = 8.f;
      /* Supplying --gamma implicitly enables soft mask */
      soft_mask_mode = 1; guitar_only = 1;
    } else if (strcmp(argv[argi], "--help") == 0 || strcmp(argv[argi], "-h") == 0) {
    } else if (strcmp(argv[argi], "--help") == 0 || strcmp(argv[argi], "-h") == 0) {
      fprintf(stderr, "See header. Flags: --guitar-only --guitar-threshold <f> --guitar-atten-db <f> --prob-floor <f> --energy-threshold <f> --min-scale <f> --adaptive-factor <f> --ema-alpha <f> --dump-prob-csv <path>\n");
      return 0;
    } else {
      fprintf(stderr, "Unknown option: %s\n", argv[argi]);
      return 1;
    }
  }

  f1 = fopen(argv[1], "rb");
  if(!f1) { fprintf(stderr, "Failed to open input %s\n", argv[1]); return 1; }
  fout = fopen(argv[2], "wb");
  if(!fout) { fprintf(stderr, "Failed to open output %s\n", argv[2]); fclose(f1); return 1; }
  /* PURE_ONNX: load ONNX model after state init */
#ifdef RNNOISE_PURE_ONNX
  if(rnnoise_pure_onnx_load(st, onnx_model) != 0) {
    fprintf(stderr, "[RNNoise][PURE_ONNX] Failed to load ONNX model %s (aborting)\n", onnx_model);
    rnnoise_destroy(st);
    fclose(f1);
    fclose(fout);
    return 2;
  } else {
    fprintf(stderr, "[RNNoise][PURE_ONNX] Loaded ONNX model %s\n", onnx_model);
  }
#endif

  FILE *csv = NULL;
  if (csv_path) {
    csv = fopen(csv_path, "w");
    if (csv) fprintf(csv, "frame,prob,rms,active,scale\n");
  }
  while (1) {
    short tmp[FRAME_SIZE];
    size_t r = fread(tmp, sizeof(short), FRAME_SIZE, f1);
    if (r != FRAME_SIZE) break;
    for (i=0;i<FRAME_SIZE;i++) x[i] = (float)tmp[i];
    double rms_acc = 0.0; for (i=0;i<FRAME_SIZE;i++) rms_acc += (double)x[i]*(double)x[i];
    float rms = (float)sqrt(rms_acc / (double)FRAME_SIZE);
    float prob = rnnoise_process_frame(st, x, x);
    if (debug_first_n && frame_index < debug_first_n) {
      fprintf(stderr, "[DBG][prob] frame=%lu val=%.6f\n", frame_index, prob);
    }
    if (prob_hist_enabled) {
      int bin = (int)floorf(prob * 10.0f);
      if (bin < 0) bin = 0; if (bin > 10) bin = 10;
      prob_hist_bins[bin]++;
    }
    /* Update EMA for adaptive thresholding */
    ema_prob = ema_alpha * prob + (1.0f - ema_alpha) * ema_prob;
    prob_accum += prob;
    int active_flag = 0;
    if (guitar_only) {
      float eff_prob = prob;
      if (eff_prob < prob_floor && energy_threshold > 0.f && rms >= energy_threshold) {
        eff_prob = guitar_threshold; /* heuristic promote */
      }
      /* Compute dynamic threshold if adaptive enabled */
      float dyn_threshold = guitar_threshold;
      if (adaptive_factor > 0.f) {
        float adapt_val = ema_prob * adaptive_factor;
        if (adapt_val > dyn_threshold) dyn_threshold = adapt_val;
      }
      if (force_threshold_enabled) {
        dyn_threshold = force_threshold_value;
      }
      float target;
    if (soft_mask_mode == 1) {
        /* Soft mask: scale transitions smoothly without binary gate.
           mask_raw = clamp( (eff_prob / dyn_threshold) , 0..1 ) raised to gamma, if dyn_threshold>0.
           If dyn_threshold==0 use eff_prob directly. */
        float norm = (dyn_threshold > 1e-6f) ? (eff_prob / dyn_threshold) : eff_prob;
        if (norm < 0.f) norm = 0.f; if (norm > 1.f) norm = 1.f;
        float shaped = powf(norm, gamma_val);
        /* Blend with attenuation floor analogous to hard gating floor */
        float atten_lin = powf(10.0f, guitar_atten_db / 20.0f);
        target = atten_lin + (1.0f - atten_lin) * shaped;
      } else {
        /* Hard gating behavior (existing) */
        target = (eff_prob >= dyn_threshold) ? 1.0f : powf(10.0f, guitar_atten_db / 20.0f);
      }
      if (target < min_scale) target = min_scale;
      float coeff = (target > env_scale) ? ENV_ATTACK : ENV_RELEASE;
      env_scale += coeff * (target - env_scale);
      for (i=0;i<FRAME_SIZE;i++) x[i] *= env_scale;
      active_flag = (eff_prob >= dyn_threshold);
      if (!active_flag) gated_frames++; else active_frames++;
      /* Record max probability during early frames for fallback heuristics */
      if (frame_index < 300 && prob > max_prob_initial) max_prob_initial = prob;
      /* After 300 frames, if probabilities extremely low, escalate min_scale and prob_floor */
      if (!fallback_escalated && frame_index == 300 && max_prob_initial < 0.02f) {
        float old_min = min_scale;
        float old_floor = prob_floor;
        if (min_scale < 0.30f) min_scale = 0.30f;
        if (prob_floor < 0.05f) prob_floor = 0.05f;
        fprintf(stderr, "[GATING][FALLBACK] Very low activity probs (max %.4f). Escalating min_scale %.3f->%.3f prob_floor %.3f->%.3f to avoid silence.\n",
                max_prob_initial, old_min, min_scale, old_floor, prob_floor);
        fallback_escalated = 1;
      }
      /* After 800 frames if still no active frames, disable gating entirely */
      if (!gating_disabled_runtime && frame_index == 800 && active_frames == 0) {
        guitar_only = 0; /* disable gating */
        env_scale = 1.0f;
        fprintf(stderr, "[GATING][FALLBACK] Disabling gating (no active frames detected after 800 frames). Passing through denoised audio.\n");
        gating_disabled_runtime = 1;
      }
    } else {
      active_frames++;
    }
    for (i=0;i<FRAME_SIZE;i++) tmp[i] = (short)(x[i]);
    if (!first) fwrite(tmp, sizeof(short), FRAME_SIZE, fout);
    first = 0;
    if (csv) fprintf(csv, "%lu,%.6f,%.3f,%d,%.6f\n", frame_index, prob, rms, active_flag, env_scale);
    frame_index++;
  }
  if (csv) fclose(csv);
  rnnoise_destroy(st);
  fclose(f1);
  fclose(fout);
  if (frame_index > 0) {
    double avg_prob = prob_accum / (double)frame_index;
    fprintf(stderr, "[SUMMARY] frames=%lu active=%lu gated=%lu active_pct=%.2f avg_prob=%.4f\n",
      frame_index, active_frames, gated_frames,
      frame_index? (100.0 * (double)active_frames / (double)frame_index):0.0,
      avg_prob);
    if (prob_hist_enabled) {
      fprintf(stderr, "[PROB_HIST]\n");
      int b; for (b=0;b<10;b++) {
        double lo = b/10.0, hi=(b+1)/10.0; fprintf(stderr, "  %.1f-%.1f: %lu\n", lo, hi, prob_hist_bins[b]);
      }
      fprintf(stderr, "  1.0+: %lu\n", prob_hist_bins[10]);
    }
  }
#ifdef USE_WEIGHTS_FILE
  rnnoise_model_free(model);
#endif
  return 0;
}
