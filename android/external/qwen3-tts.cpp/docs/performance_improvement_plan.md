# Qwen3-TTS C++ Performance Improvement Plan

This note captures the current performance state and the next concrete tests for
continuing optimization work in a later session.

## Current Baseline

Latest Linux benchmark on the GTX 1070 Max-Q used:

- Commit: `e4377ac perf(transformer): cache code predictor masks`
- Model: `qwen-talker-1.7b-base-Q8_0.gguf`
- Tokenizer/vocoder: `qwen-tokenizer-12hz-Q8_0.gguf`
- Prompt: Freeman full reference WAV ICL clone
- Benchmark: 8 fixed seeds, same text and sampling parameters as qwentts

Result:

| Implementation | Wall | Audio | ms/audio-s | AR / generation ms-frame |
| --- | ---: | ---: | ---: | ---: |
| qwen3-tts.cpp `e4377ac` | 78.02s | 65.84s | 1185.0 | 42.45 |
| qwentts.cpp `73fe0c6` | 64.71s | 65.44s | 988.8 | 37.33 |

qwentts remains about 1.20x faster end-to-end in this benchmark. Later timing
work showed that this was not a clean AR-loop comparison: qwen3's normal
`Generate` number includes prefill, while qwentts' reported AR ms/frame excludes
prefill and mostly covers talker decode plus Code Predictor.

The latest mask-cache commit was performance-neutral on this machine:

| Version | Wall | Audio | ms/audio-s | Gen avg | Gen ms-frame |
| --- | ---: | ---: | ---: | ---: | ---: |
| `54786fb` | 77.53s | 65.84s | 1177.5 | 4363 ms | 42.414 |
| `e4377ac` | 78.02s | 65.84s | 1185.0 | 4367 ms | 42.447 |

## Main Bottleneck

The biggest remaining target is still the synthesis hot path, but the latest
timing evidence says it is not a single obvious Code Predictor gap. Code
Predictor runs 15 sequential sub-steps per generated audio frame, so small
graph, scheduler, upload, readback, or sampling overheads still matter. However,
qwen3 and qwentts are now effectively tied in Code Predictor ms/frame on this
hardware.

qwen3 already uses a GPU-resident talker hidden bridge, so the remaining gap is
not an obvious host roundtrip of the talker hidden state.

## Highest-Impact Tests

1. Build with deep timing instrumentation.

   Rebuild with `QWEN3_TTS_TIMING=ON` and split generation timing into:

   - Talker decode
   - CodePred prefill
   - CodePred AR steps
   - graph build
   - graph alloc
   - graph compute
   - logits readback
   - sampling
   - input uploads / next embedding compose

   Goal: identify whether the missing ~5 ms/frame is compute, scheduler/graph
   overhead, synchronization, logits transfer, or CPU sampling.

2. Add or use a preencoded generation-only benchmark.

   Benchmark with precomputed speaker embedding plus reference codes / ICL
   prompt artifact. This removes reference WAV processing from the measurement
   and isolates the real decode loop.

   Goal: measure best-case generation-only throughput and avoid confusing
   reference encode variance with hot-loop changes.

3. Implement a GGML-native static Code Predictor graph experiment.

   The naive attempts to reuse raw `ggml_cgraph *` from scheduler reserve or a
   lazy graph cache crashed in CUDA `get_rows`, so raw graph pointer reuse is not
   safe with the current builder/meta-buffer/scheduler pattern.

   Next approach should be closer to qwentts:

   - one persistent graph arena/context for CodePred prefill
   - one persistent graph arena/context per CodePred substep
   - fixed shapes
   - stable tensor addresses
   - minimal per-step input mutation

   Goal: determine whether persistent graph arenas can still reduce overhead
   after correcting for benchmark accounting. This is still worth testing, but
   it is no longer proven to be the largest remaining gap.

4. Isolate logits readback and sampling cost.

   Run a benchmark variant with the cheapest possible sampling path, such as
   greedy/top-k-1 if available, and compare against normal `top-k 50`.

   Goal: determine whether reading logits back 15 times per frame and sampling
   on the CPU is a meaningful part of the gap.

5. Benchmark reference encode only.

   Compare qwen3 and qwentts on the Freeman WAV with no generation:

   - wall time
   - resampler time
   - speaker embedding time
   - speech tokenizer encode time
   - produced frame count

   Current observation: qwen3 emits 216 reference code frames, qwentts emits 215.
   qwen3 reference prep is somewhat slower, but this is not the main AR hot-loop
   gap.

6. Test talker graph persistence.

   Talker runs only once per generated frame, so the multiplier is smaller than
   Code Predictor. Still, persistent graph context reuse may shave overhead once
   Code Predictor is better understood.

7. Test vocoder left-context impact.

   Run with reduced or zero `--vocoder-left-context-sec` as a sanity check.
   Expected impact is small, roughly around 0.1s per benchmark run with the
   current 25-frame context.

## Recommended Order

1. Timing build breakdown
2. Preencoded generation-only benchmark
3. Static Code Predictor graph arena experiment
4. Logits/sampling isolation
5. Reference encode-only benchmark
6. Talker graph persistence
7. Vocoder left-context toggle

The likely next real win is now less certain. The timing build should decide
whether the next patch should focus on graph/scheduler structure, reference
encode and cache behavior, preencoded/server benchmark accounting, or logits
readback and sampling synchronization.

## 2026-07-05 Linux Timing Findings

Added timing-only counters for the Code Predictor hot loop:

- input upload
- logits readback
- sampling
- scheduler reset
- prefill/trailing row counts

Three-seed timing run before ICL prompt alignment:

| Area | Average |
| --- | ---: |
| Generate | 4329.5 ms |
| Talker step | 1541.4 ms |
| Code Predictor total | 2241.0 ms |
| Code Predictor compute | 2009.4 ms |
| Code Predictor graph build | 54.5 ms |
| Code Predictor graph alloc | 99.0 ms |
| Code Predictor data I/O | 31.8 ms |
| Code Predictor logits read | 14.8 ms |
| Code Predictor sampling | 42.0 ms |

Important conclusion: Code Predictor is not currently the whole gap. It is
about 22.0 ms/frame on this machine, very close to qwentts' reported
22.2 ms/frame. Talker step is also close. The bigger surprise was qwen3's ICL
talker prefill/prompt path and benchmark accounting around prefill/reference
work.

### ICL Prompt Alignment Fix

The old qwen3 ICL prompt builder appended the projected text stream and the
reference codec stream sequentially. qwentts aligns those streams row-by-row
over the codec reference length, matching the upstream-style ICL geometry.

Changed locally:

- `src/transformer/transformer_embeddings.cpp`
  - align projected reference/target text rows with reference codec rows
  - pad text with `tts_pad` when codec rows are longer
  - preserve leftover text rows in `trailing_text_hidden` when text is longer
- `src/qwen3_tts.h`, `src/tts_transformer.h`, `src/main.cpp`,
  `src/qwen3_tts_jni.cpp`
  - change the default language from explicit English (`2050`) to Auto (`-1`)
  - add `--language auto` CLI support
  - keep explicit `--language en` for the previous English-prefix behavior

Timing result after the local alignment patch:

| Area | Before | After |
| --- | ---: | ---: |
| Prefill rows | about 306 implied | 225 measured with Auto |
| Prefill forward | about 396 ms | about 292 ms |
| Generate ms/frame | 42.45 | 40.88 |

Eight-seed normal benchmark:

| Version | Wall | Audio | ms/audio-s | Gen ms/frame |
| --- | ---: | ---: | ---: | ---: |
| `e4377ac` baseline | 78.02s | 65.84s | 1185.0 | 42.45 |
| local ICL alignment patch, explicit English | 79.44s | 71.36s | 1113.2 | 40.88 |
| local ICL alignment + Auto default | 79.15s | 70.56s | 1121.8 | 40.89 |

The current Auto-default patch is about 5.3% faster normalized on the fixed
Freeman benchmark and reduces generation cost from 42.45 to 40.89 ms/frame.
The explicit-English variant is slightly faster in this seed set, but Auto
matches the Python and qwentts default prompt geometry. Both variants change
generated durations/content because this is a parity-sensitive ICL prompt
layout/default-language change. Treat it as a behavior change that needs full
regression/parity review, not only a speed patch.

Validation so far:

- normal CUDA build passed
- timing CUDA build passed
- CLI ICL smoke passed and produced audio
- `--language auto` CLI smoke passed and produced audio
- `test_tokenizer` passed
- `test_speech_tokenizer_encoder models/qwen-tokenizer-12hz-Q8_0.gguf` passed
- `ctest --test-dir build-cuda --output-on-failure` could not fully validate
  because local test assets are missing:
  - `clone.wav`
  - `reference/det_text_tokens.bin`
  - `reference/det_speech_codes.bin`
  - `reference/speech_codes.bin`
  - `reference/decoded_audio.bin`
  - available tokenizer and speech-tokenizer load tests passed

### Reference Prep Timing Split

Added local timing fields for full ICL reference preparation:

- speaker encoder lazy load
- speaker embedding encode
- speech tokenizer encoder lazy load
- reference speech-code encode

One Freeman full-ICL smoke after the split:

| Area | Time |
| --- | ---: |
| Total encode | 2400 ms |
| Speaker encoder lazy load | 70 ms |
| Speaker embedding encode | 252 ms |
| Speech tokenizer lazy load | 46 ms |
| Speech tokenizer encode | 2029 ms |

The reference encode bottleneck is clearly speech-tokenizer encoding, not the
speaker embedding. This matters mostly for cold CLI use or uncached server
requests. It disappears in preencoded or warm-reference paths.

### Reference Encode-Only Benchmark

Fresh three-run cold extraction benchmark with the Freeman reference and the
1.7B Q8 talker/tokenizer models:

| Implementation | Wall | Frames | Resampled samples | Code samples |
| --- | ---: | ---: | ---: | ---: |
| qwen3 `--extract-icl-prompt` | 3.55 s | 215 | 414337 | 412800 |
| qwentts `qwen-codec` | 3.08 s | 215 | 414337 | 412800 |

qwen3 averaged:

| Area | Time |
| --- | ---: |
| Encoder-only load | 292 ms |
| Speech tokenizer lazy load | 47 ms |
| Text tokenizer lazy load | 151 ms |
| ICL prompt encode total | 2467 ms |
| Speech tokenizer encode | 1967 ms |
| Speaker embedding encode | 256 ms |

Interpretation:

- qwen3 is about `0.47 s` slower, roughly `15%`, for this cold reference
  extraction path.
- Frame/sample parity now matches qwentts: both resample to `414337`, truncate
  reference codes to `412800`, and produce `215` codec frames.
- qwen3's largest measured cost is speech-tokenizer encoding, followed by cold
  model/tokenizer load overhead. The speaker embedding path is comparatively
  small.
- qwentts does not currently split codec compute and speaker extraction as
  cleanly in its logs, so the next useful step is deeper timing inside
  `SpeechTokenizerEncoder::encode`, especially SEANet, transformer,
  downsample/quantizer, backend upload, and readback.

This matters for cold CLI and uncached server requests. Preencoded or warm
prompt paths avoid most of this cost.

### Reference Encode RVQ Quantizer Split And Fix

Added deeper timing around `SpeechTokenizerEncoder::encode`:

- speech encoder graph build/alloc
- input and mask upload
- graph compute
- projected feature readback
- CPU semantic VQ
- CPU acoustic residual VQ

Three-run cold extraction before the RVQ change showed the real bottleneck:

| Area | Average |
| --- | ---: |
| Wall | 3.56 s |
| ICL prompt encode | 2497 ms |
| Reference speech tokenize | 2034 ms |
| Speech project graph | 123 ms |
| Speech graph compute | 120 ms |
| CPU RVQ quantize | 1912 ms |
| Semantic VQ | 120 ms |
| Acoustic VQ | 1792 ms |

So the slow reference speech encode path was not the CUDA speech-tokenizer graph.
It was the CPU residual vector quantizer, especially the 15 acoustic codebooks.

Changed locally:

- materialize per-codebook squared norms once at speech tokenizer load time
- use the qwentts-style `||c||^2 - 2 * dot(residual, c)` nearest-neighbor score
- parallelize frame-independent semantic and acoustic RVQ loops over the
  configured CPU thread count
- keep acoustic residual dependencies sequential within each frame

Parity check:

- one extracted Freeman ICL prompt after the change matched the previous JSON
  exactly for `reference_codes` and `reference_token_ids`
- `--threads 1` also matched the previous JSON exactly, confirming the serial
  and parallel paths choose the same codes

Three-run cold extraction after the RVQ change:

| Area | Average |
| --- | ---: |
| Wall | 1.98 s |
| ICL prompt encode | 901 ms |
| Reference speech tokenize | 431 ms |
| Speech project graph | 118 ms |
| Speech graph compute | 115 ms |
| CPU RVQ quantize | 313 ms |
| Semantic VQ | 20 ms |
| Acoustic VQ | 293 ms |

Impact:

- reference speech tokenization improved from about `2034 ms` to `431 ms`
- cold ICL prompt extraction improved from about `3.56 s` wall to `1.98 s`
- this makes qwen3's cold reference extraction faster than the earlier qwentts
  `qwen-codec` measurement on the same Freeman reference (`3.08 s` wall)

Thread-count sweep on the i7-8750H in this Linux test machine:

| Threads | Speech tokenize | CPU RVQ quantize | Wall |
| ---: | ---: | ---: | ---: |
| 1 | 2059 ms | 1931 ms | 3.65 s |
| 2 | 1086 ms | 969 ms | 2.55 s |
| 4 | 602 ms | 492 ms | 2.15 s |
| 6 | 433 ms | 327 ms | 1.96 s |
| 8 | 387 ms | 281 ms | 1.97 s |
| 12 | 305 ms | 199 ms | 1.81 s |

The CLI default CPU thread count remains physical cores for the GGML CPU
backend, but the custom RVQ loop now uses logical hardware threads when the user
did not explicitly pass `--threads`. Explicit `--threads N` is still honored.

Validation after the adaptive worker change:

| Mode | Speech tokenize | CPU RVQ quantize | Code parity |
| --- | ---: | ---: | --- |
| default auto workers | 322 ms | 198 ms | exact match |
| `--threads 6` | 435 ms | 324 ms | exact match |
| `--threads 1` | 1955 ms | 1847 ms | exact match |

Added a synthetic `quantize_projected()` test that loads the real tokenizer
codebooks, quantizes the same deterministic projected features with explicit
serial workers and automatic parallel workers, and requires exact code equality.

Recommended follow-up:

1. Keep the RVQ parallel path if broader regression agrees with the exact-code
   prompt parity check.
2. Consider adding a small deterministic unit test around
   `quantize_projected()` so future quantizer optimizations can prove exact
   code stability without running full prompt extraction.
3. If cold extraction still matters after this, next inspect speaker encoder
   load/encode and text tokenizer load overhead; the speech tokenizer graph is
   no longer the dominant reference-prep cost.

### Current Post-RVQ Benchmark Snapshot

Three-seed full Freeman ICL voice-clone slice at `3ee715e`, before adaptive RVQ
worker selection:

| Area | Average |
| --- | ---: |
| Wall | 8.07 s |
| Total pipeline | 5702 ms |
| Encode | 812 ms |
| Speech encode | 433 ms |
| Speaker encode | 251 ms |
| Generate | 4294 ms |
| Decode | 593 ms |
| Audio | 8.96 s |
| Wall ms/audio-s | 901.0 |
| Generate ms/frame | 38.34 |

The same three seeds with explicit `--threads 12`:

| Area | Average |
| --- | ---: |
| Wall | 8.01 s |
| Total pipeline | 5583 ms |
| Encode | 690 ms |
| Speech encode | 306 ms |
| Speech quantize | 197 ms |
| Generate | 4296 ms |
| Decode | 596 ms |
| Audio | 8.96 s |
| Wall ms/audio-s | 893.6 |
| Generate ms/frame | 38.36 |

Current preencoded timing build, same three seeds:

| Area | Average | Per frame |
| --- | ---: | ---: |
| Build prompt | 30.4 ms | n/a |
| Reference-code embed | 9.2 ms | n/a |
| Prefill forward | 127.5 ms | n/a |
| Talker total | 1670.2 ms | 14.91 ms |
| Code Predictor total | 2487.9 ms | 22.21 ms |
| Total generate | 4325.3 ms | 38.62 ms |
| Decode | 608.3 ms | n/a |

Interpretation:

- The cold reference-prep gap is no longer the dominant problem.
- The hot AR loop is now effectively tied with qwentts on this GPU: qwen3
  Talker + Code Predictor is about `37.13 ms/frame`, and qwentts' comparable
  AR loop was about `37.25 ms/frame`.
- qwen3's `Total generate` is still about `38.6 ms/frame` because it includes
  prompt build and prefill accounting. On these short runs, that fixed overhead
  amortizes to about `1.5 ms/frame`.
- The next useful generation work should target fixed per-request costs
  (prompt build, first-run setup, model load) or require a deeper graph/scheduler
  change than the earlier reset-context arena experiment.

### ICL Reference Code Frame Alignment

qwen3 was still producing 216 reference speech-code frames for the Freeman
reference while qwentts produced 215. The reason was input length handling:

- qwentts truncates reference audio to a positive multiple of the codec hop
  length before encoding reference codes.
- qwen3 passed the full resampled clip into `SpeechTokenizerEncoder`, whose
  convolution length math rounded this specific clip up to one extra frame.

Changed locally:

- `src/pipeline/pipeline_synthesize.cpp`
  - align ICL reference-code input length to a multiple of the 1920-sample codec
    hop
  - apply this in normal synthesis, streaming synthesis, and prompt extraction
  - keep speaker embedding extraction and voice-cache keys based on the full
    resampled reference audio

Focused timing smoke after this change:

| Check | Result |
| --- | ---: |
| Reference samples for codes | 414337 -> 412800 |
| Reference code frames | 215 |
| Prefill rows | 224 |
| Trailing rows | 1 |

Eight-seed normal benchmark after ICL text alignment, Auto default, and
reference-code frame alignment:

| Version | Wall | Audio | ms/audio-s | Gen ms/frame |
| --- | ---: | ---: | ---: | ---: |
| local ICL alignment + Auto default | 79.15s | 70.56s | 1121.8 | 40.89 |
| + reference-code frame alignment | 76.13s | 64.40s | 1182.1 | 41.35 |

This change improves prompt/layout parity and reduces average generated frames,
but it does not improve per-frame generation speed. The different reference ICL
codes also change sampled output lengths, so ms/audio-s is not directly
comparable as a pure speed signal.

Three-seed timing build after reference-code frame alignment:

| Area | Average | Per frame |
| --- | ---: | ---: |
| Prefill rows | 224 | n/a |
| Prefill forward | 279.9 ms | n/a |
| Talker step | 1476.6 ms | 14.86 ms |
| Code Predictor total | 2206.7 ms | 22.22 ms |
| Code Predictor compute | 1980.8 ms | 19.94 ms |
| Code Predictor graph build | 53.3 ms | 0.54 ms |
| Code Predictor graph alloc | 96.3 ms | 0.97 ms |
| Code Predictor data I/O | 30.8 ms | 0.31 ms |
| Code Predictor logits read | 14.2 ms | 0.14 ms |
| Code Predictor sampling | 41.5 ms | 0.42 ms |
| Total generate | 4111.9 ms | 41.39 ms |

Comparable qwentts fixed-run timing averages:

| Area | Average | Per frame |
| --- | ---: | ---: |
| Prefill | 123.1 ms | n/a |
| Talker decode | 1542.4 ms | 15.08 ms |
| Code Predictor | 2274.1 ms | 22.24 ms |
| AR loop | n/a | 37.37 ms |
| Codec decode | 565.9 ms | 5.53 ms |

Updated interpretation:

- qwen3 Talker and Code Predictor per-frame cost are already very close to
  qwentts on this GPU.
- Before the flash-attention prefill patch below, qwen3 prefill was much slower
  than qwentts even after prompt alignment (`~280 ms` vs `~123 ms` for the same
  224-row Freeman prompt).
- Code Predictor graph/scheduler overhead is measurable but not large enough to
  explain the original 20% headline gap by itself.
- Next comparisons should separate:
  - load time
  - reference speaker extraction
  - reference speech-code extraction
  - prompt build/prefill
  - AR decode loop
  - vocoder decode

### Preencoded And Isolation Benchmarks

Extracted a reusable Freeman ICL prompt artifact with:

- speaker embedding: 2048 floats
- reference codes: 215 frames x 16 codebooks
- extraction time: 2480 ms
- artifact: `/tmp/qwen3-preencoded-20260705-161845/freeman_icl_prompt.json`

Cold preencoded 8-seed benchmark using `--icl-prompt`:

| Area | Result |
| --- | ---: |
| Wall | 52.30 s |
| Audio | 64.40 s |
| Wall ms/audio-s | 812.1 |
| Average load | 1530.5 ms |
| Average encode | 0 ms |
| Average generate | 4190.1 ms |
| Average decode | 550.0 ms |
| Generate ms/frame | 41.64 |
| Generate+decode ms/audio-s | 588.8 |

Warm same-process preencoded repeat, seed 101, 5 repeats:

| Area | Result |
| --- | ---: |
| Average total | 4474.0 ms |
| Average generate | 3954.2 ms |
| Average decode | 519.4 ms |
| Generate ms/frame | 41.62 |

Interpretation: removing reference prep and process/model load dramatically
improves end-to-end wall time, but the generation loop itself stays at about
41.6 ms/frame. This confirms that the next true generation-speed win needs to
come from prefill/hot-loop implementation, not from prompt artifact plumbing.

Greedy/top-k-1 timing isolation, seed 101:

| Area | Normal sampling | Greedy |
| --- | ---: | ---: |
| Code Predictor sampling | ~0.42 ms/frame | 0.04 ms/frame |
| Code Predictor logits read | ~0.14 ms/frame | 0.13 ms/frame |
| Total generate | ~41.39 ms/frame | 41.32 ms/frame |

Interpretation: CPU sampling is measurable, but even making sampling almost
free does not materially move total generation. Logits readback is also too
small to explain the gap.

Vocoder context sanity check, first three seeds, `--vocoder-left-context-sec 0`:

| Area | Default 2s context | 0s context |
| --- | ---: | ---: |
| Decode frames, seed 101 | 120 | 95 |
| Decode ms, seed 101 | 522 ms | 430 ms |
| Average decode, 3 seeds | about 543 ms | 444.7 ms |

Interpretation: the 25-frame ICL vocoder context costs roughly 90-100 ms on
these short Freeman runs. It is not a large generation bottleneck, but it is a
reasonable low-latency knob when the quality tradeoff is acceptable.

### qwentts Preencoded Comparison

Regenerated qwentts latent artifacts with current models:

- command: `qwen-codec --model qwen-tokenizer-12hz-Q8_0.gguf --talker qwen-talker-1.7b-base-Q8_0.gguf -i freeman.wav`
- output: `/tmp/qwentts-preencoded-20260705-162507/freeman.rvq`
- output: `/tmp/qwentts-preencoded-20260705-162507/freeman.spk`
- reference frames: 215
- extraction wall: 3.14 s including codec and speaker-encoder loads

Cold preencoded qwentts 8-seed benchmark:

| Area | Result |
| --- | ---: |
| Wall | 46.27 s |
| Audio | 65.44 s |
| Wall ms/audio-s | 707.0 |
| Prompt build | 5.7 ms |
| Prefill | 125.6 ms |
| Talker decode | 15.08 ms/frame |
| Code Predictor | 22.28 ms/frame |
| AR loop | 37.38 ms/frame |
| Codec decode | 568.3 ms |

Closest warm qwentts check used `--stream-by-line -o -` with five repeated
lines. This keeps models and latents resident, but uses the streaming output
path, so codec timings are not directly comparable with buffered qwen3:

| Area | Result |
| --- | ---: |
| Repeats | 5 |
| Prompt build | 3.7 ms avg |
| Prefill | 122.5 ms avg |
| Talker decode | 14.94 ms/frame |
| Code Predictor | 22.27 ms/frame |
| AR loop | 37.25 ms/frame |

Interpretation: qwentts preencoded/warm accounting confirms the earlier phase
numbers. Its hot AR path is stable around 37.3 ms/frame. The biggest clear
qwen3-only phase delta before the next patch was talker prefill.

### Talker Flash-Attention Prefill

Implemented local qwen3 talker prefill using the same broad shape as qwentts:

- add a padded KV attention window for prefill
- upload an F16 causal mask shaped `[n_kv_pad, T]`
- use `ggml_flash_attn_ext` for multi-token talker prefill
- keep the existing GPU hidden bridge for the last prefill row

This replaces the old multi-token manual attention path:

- old: `mul_mat(K, Q) -> diag_mask_inf -> softmax -> mul_mat(V, KQ)`
- new: `ggml_flash_attn_ext(Q, K, V, mask)`

One-seed timing smoke, preencoded Freeman prompt:

| Area | Before | After |
| --- | ---: | ---: |
| Prefill rows | 224 | 224 |
| Prefill forward | ~279.9 ms | 133.4 ms |
| Prefill compute | ~285.9 ms in earlier smoke | 130.8 ms |

Three-seed timing after flash prefill:

| Area | Average | Per frame |
| --- | ---: | ---: |
| Prefill rows | 224 | n/a |
| Prefill forward | 127.1 ms | n/a |
| Talker step | 1624.2 ms | 14.86 ms |
| Code Predictor total | 2432.0 ms | 22.24 ms |
| Code Predictor compute | 2182.4 ms | 19.96 ms |
| Code Predictor sampling | 45.5 ms | 0.42 ms |
| Total generate | 4340.6 ms | 39.70 ms |

Cold preencoded qwen3 8-seed benchmark after flash prefill:

| Area | Before | After |
| --- | ---: | ---: |
| Wall | 52.30 s | 54.06 s |
| Audio | 64.40 s | 69.52 s |
| Wall ms/audio-s | 812.1 | 777.7 |
| Generate ms/frame | 41.64 | 39.73 |
| Generate+decode ms/audio-s | 588.8 | 565.7 |

The wall total rose because the flash-attention path changed sampled outputs
and this fixed seed set generated more audio frames. The phase-normalized result
is the important signal: talker prefill is now essentially tied with qwentts
(`127.1 ms` vs `125.6 ms`), and qwen3 generation improved by about 4.6%.

Updated interpretation after flash prefill:

- The clearest prefill gap is solved.
- qwen3 is now roughly:
  - prefill: comparable to qwentts
  - talker decode: comparable to qwentts
  - Code Predictor: comparable to qwentts
  - total generation: still slower (`~39.7 ms/frame` vs `~37.3 ms/frame`)
- The remaining gap is now likely accumulated scheduler/graph overhead and
  small per-frame costs across talker + Code Predictor rather than one obvious
  missing phase.
- Because flash attention changes numerics and sampled output lengths, it needs
  parity/regression review against Python/qwentts before treating the speed win
  as a safe default.

Recommended immediate next steps:

1. Run or regenerate full reference assets, then run the full regression suite.
2. Do a parity check against Python/qwentts for ICL prompt layout and output
   validity.
3. If the alignment patches are accepted, split timing instrumentation,
   prompt-language/default behavior, prompt alignment, codec-frame alignment,
   reference-prep timing, and flash-attention prefill into separate commits.
4. Compare qwen3 flash-prefill outputs against Python/qwentts for deterministic
   validity and perceptual quality. Expect exact sampled tokens to change.
5. Revisit persistent/static graph arena work only after the flash-prefill patch
   is validated. The remaining gap is now small enough that graph/scheduler
   overhead may be the next reasonable target again.

### Prompt-Build Reference-Code Embedding Batch

Added a deeper timing split inside qwen3 prompt construction:

- special text projection
- instruction text projection
- role text projection
- body/reference text projection
- codec lookups
- reference-code embedding
- CPU prompt composition

The first one-seed timing smoke showed that the remaining qwen3 prompt-build
gap was almost entirely reference-code embedding:

| Area | Before batching |
| --- | ---: |
| Build prompt | 149.0 ms |
| Special text | 15.2 ms |
| Body text | 2.5 ms |
| Codec lookups | 0.1 ms |
| Reference-code embedding | 128.3 ms |
| CPU composition | 2.7 ms |

Root cause: qwen3 embedded the ICL reference codec stream with one tiny tensor
row read per frame per codebook. For the Freeman prompt this meant 215 frames x
16 codebooks = 3440 small reads/conversions.

Changed locally:

- `src/transformer/transformer_embeddings.cpp`
  - gather all reference code IDs for one codebook
  - run one batched embedding lookup per codebook
  - accumulate the 16 codebook embedding streams into the reference-code rows

This keeps the same prompt geometry while replacing thousands of tiny lookups
with 16 batched lookups.

One-seed timing after batching:

| Area | Before | After |
| --- | ---: | ---: |
| Build prompt | 149.0 ms | 29.8 ms |
| Reference-code embedding | 128.3 ms | 8.2 ms |
| Generate throughput | 40.4 ms/frame | 39.3 ms/frame |

Three-seed timing after batching:

| Area | Average |
| --- | ---: |
| Build prompt | 29.6 ms |
| Reference-code embedding | 8.3 ms |
| Prefill forward | 128.1 ms |
| Talker total | 15.24 ms/frame |
| Code Predictor total | 22.17 ms/frame |
| Total generate | 38.93 ms/frame |

Cold preencoded qwen3 8-seed benchmark after batching:

| Area | Result |
| --- | ---: |
| Average load | 1539.1 ms |
| Average generate | 4494.6 ms |
| Average decode | 627.6 ms |
| Audio | 73.92 s |
| Generate ms/frame | 38.91 |
| Generate+decode ms/audio-s | 554.4 |
| Load+generate+decode ms/audio-s | 720.9 |

Interpretation after this patch:

- qwen3's prompt-build overhead is no longer a large qwentts gap. It is still
  slower than qwentts' prompt-build number (`~30 ms` vs `~6 ms`), but the
  difference is now a small fixed request cost rather than a major issue.
- The generation loop improved again, from about `39.7 ms/frame` after flash
  prefill to about `38.9 ms/frame` in this timing run.
- qwentts remains faster in the hot AR accounting (`~37.3 ms/frame`), but the
  remaining delta is now about 1.6 ms/frame rather than the original headline
  20% end-to-end gap.
- Because the batched lookup uses GGML `get_rows` instead of per-row host reads,
  sampled output lengths can shift slightly. Validate parity/output quality
  before committing this as a safe default.

Recommended next steps from here:

1. Run full regression once reference assets are available.
2. Compare batched reference-code prompt embeddings or generated code validity
   against the previous per-row path and qwentts/Python.
3. If parity is acceptable, keep the batched reference-code embedding patch.
4. Resume persistent/static graph arena experiments for the remaining
   approximately 1.6 ms/frame hot-loop gap.

### Warm Reference-Code Embedding Cache

Follow-up repeat-mode timing showed that the large `Special text` number in the
first run is mostly a one-time CUDA/scheduler setup cost:

| Repeat | Build prompt | Special text | Ref code embed |
| --- | ---: | ---: | ---: |
| 1 | 30.0 ms | 15.3 ms | 8.3 ms |
| 2 | 12.2 ms | 0.2 ms | 7.9 ms |
| 3 | 8.5 ms | 0.2 ms | 7.0 ms |

So caching the special token projection would mostly move first-run work around.
The repeated warm-reference cost was the reference-code embedding.

Changed locally:

- `src/transformer/transformer_state_internal.h`
  - add a last-reference-code embedding cache to `tts_transformer_private`
- `src/transformer/transformer_loader.cpp`
  - clear the cache on model unload
- `src/transformer/transformer_embeddings.cpp`
  - reuse cached summed reference-code rows when frame count, codebook count,
    and the exact reference code array match

Repeat-mode timing after the cache:

| Repeat | Build prompt | Special text | Ref code embed |
| --- | ---: | ---: | ---: |
| 1 | 30.6 ms | 15.3 ms | 9.3 ms |
| 2 | 4.4 ms | 0.2 ms | 0.1 ms |
| 3 | 1.6 ms | 0.2 ms | 0.1 ms |

Interpretation:

- This does not help cold one-shot CLI runs much.
- It directly helps server/repeat workflows with the same ICL reference, which
  was one of the planned warm-reference cache tests.
- It makes qwen3 warm prompt build faster than the earlier qwentts warm
  prompt-build measurement for repeated same-reference requests, although the
  remaining hot AR loop gap still needs graph/scheduler work.

### Code Predictor Valid-Prefix KV Step Experiment (Held Back)

Tested a small Code Predictor step-graph change locally, but do not include it
in the safe commit set yet:

- one-token AR step graphs now view only the valid KV prefix
  (`0..n_past`) instead of the full 16-slot Code Predictor frame cache
- one-token step attention no longer uploads or applies a mask
- Code Predictor prefill still uses the full mask because it processes two
  tokens and needs causal masking between them
- scheduler reserve now warms each Code Predictor substep with its real
  `step + 1` KV prefix shape

Three-seed timing after the change:

| Area | Average | Per frame |
| --- | ---: | ---: |
| Frames | 96.7 | n/a |
| Build prompt | 30.0 ms | n/a |
| Prefill forward | 127.7 ms | n/a |
| Talker total | 1473.1 ms | 15.24 ms |
| Code Predictor total | 2126.9 ms | 22.00 ms |
| Code Predictor prefill | 137.1 ms | 1.42 ms |
| Code Predictor steps | 1989.7 ms | 20.58 ms |
| Code Predictor graph build | 51.1 ms | 0.53 ms |
| Code Predictor graph alloc | 92.4 ms | 0.96 ms |
| Code Predictor compute | 1910.1 ms | 19.76 ms |
| Code Predictor data I/O | 29.3 ms | 0.30 ms |
| Code Predictor sampling | 39.7 ms | 0.41 ms |
| Total generate | 3765.4 ms | 38.95 ms |

Interpretation:

- Compared with the prior batched-prompt timing, Code Predictor total improved
  only slightly, roughly `22.17 -> 22.00 ms/frame`.
- This is a small compute/data cleanup, not the persistent graph-arena win.
- qwentts intentionally keeps a fixed 16-slot Code Predictor attention window
  with masks because its persistent graph arenas/CUDA replay strategy wants
  stable graph shapes. This experiment trades that fixed-shape property for a
  tiny valid-prefix compute win.
- Sampled lengths shifted, as expected from small attention-kernel numerical
  differences. Validate parity/output quality before treating this as a safe
  default.
- The code change was held back from the safe commit set because it conflicts
  with the fixed-shape persistent graph arena direction and only gives a tiny
  speed signal.

Recommended follow-up:

1. Keep this patch only if parity checks look acceptable and the small speed win
   is worth losing fixed Code Predictor step shapes.
2. If persistent/static Code Predictor graph arenas are resumed, test whether
   the fixed 16-slot masked shape is actually better overall because it supports
   graph reuse/replay.

### Code Predictor Persistent Context Arena Experiment

Tested the qwentts-style graph arena idea in a safer form:

- add one persistent no-alloc `ggml_context` per Code Predictor graph flavor
- reset the context before each graph build
- still build a fresh `ggml_cgraph` every call
- do not reuse stale `ggml_cgraph *` pointers

This avoids the unsafe raw graph-pointer reuse that previously crashed in CUDA
`get_rows`, while trying to keep graph node addresses stable for backend graph
caching.

Three-seed timing with persistent contexts:

| Area | Average | Per frame |
| --- | ---: | ---: |
| Frames | 111.0 | n/a |
| Build prompt | 29.0 ms | n/a |
| Prefill forward | 127.7 ms | n/a |
| Talker total | 1690.8 ms | 15.23 ms |
| Code Predictor total | 2463.6 ms | 22.19 ms |
| Code Predictor prefill | 157.5 ms | 1.42 ms |
| Code Predictor steps | 2305.8 ms | 20.77 ms |
| Code Predictor graph build | 59.3 ms | 0.53 ms |
| Code Predictor graph alloc | 108.9 ms | 0.98 ms |
| Code Predictor compute | 2210.1 ms | 19.91 ms |
| Code Predictor data I/O | 35.1 ms | 0.32 ms |
| Code Predictor sampling | 45.3 ms | 0.41 ms |
| Total generate | 4319.4 ms | 38.91 ms |

Interpretation:

- This did not materially improve Code Predictor timing on this GTX 1070 Max-Q.
- Code Predictor total remained around `22.2 ms/frame`, close to the previous
  masked-shape baseline.
- The graph build/alloc counters also stayed essentially unchanged because the
  scheduler still allocates each freshly built graph.
- The code change was reverted; only this note remains.

Recommended follow-up:

1. Do not retry simple persistent no-alloc contexts alone.
2. A future graph-arena attempt needs stronger evidence that the active GGML
   backend is actually caching/replaying by stable node address, or it needs a
   deeper scheduler/CUDA graph integration than this reset-context experiment.
