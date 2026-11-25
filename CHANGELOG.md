## 1.3.0

- The web runtime supports decisions with `fllamaDecide` and realtime audio with `fllamaRealtimeOpen`.
- Update llama.cpp to b12637 and wllama to 4.0.0 (`c875858`). Native and web still use the same llama.cpp commit.
- For LFM3 D1, llama.cpp batches questions that share a state, including an image. The Decision API response format stays the same. Scores and input token counts can change.
- On web, both builds use 32-bit Wasm. Models with more than 4 GiB of CPU-resident weights need cross-origin isolation and multiple inference threads. The compat build supports browsers without JSPI or relaxed SIMD.

## 1.2.0

- Decision API: `fllamaDecide` runs llama.cpp's `/v1/systemone` in process, with no server: choice, score and yes/no questions about text, images and audio, answered by a decision model such as LFM3 D1 Omni. Native only.
- `FllamaErrorType` has `notSupported` and `cancelled`, used by the decision API.

## 1.1.1

- Flutter 3.50 compatability

## 1.1.0

- Realtime API: `fllamaRealtimeOpen` runs llama.cpp's `/v1/realtime` WebSocket API in process, with no server. With LFM3-Audio-2B it holds a voice conversation with tool calls. Native only.
- llama.cpp patch: a realtime conversation that does not fit in the context ends with an error. It aborted the app.
- Realtime API: live transcription (Voxtral Realtime) no longer stops after its first token. A realtime request has no token limit of its own.
- llama.cpp patch: on macOS and iOS, an app that exits with a model loaded no longer aborts in `ggml_metal_device_free`.

## 1.0.2

- llama.cpp b12211 (was b11719) and wllama 6647c1e (was 3bb2a46). On an M4 Max with Qwen 3.5 0.8B: web generation about 7% faster in Chrome, native CPU prompt processing about 11% faster; Metal unchanged.
- Android: the ggml CPU variant libraries are linked for 16 KB pages, like the other libraries, also when they are built from source.

## 1.0.1

- Web: model files download one at a time. With a model and an mmproj downloading together, Firefox sometimes never finished opening a cache file, and the load waited forever.

## 1.0.0

- First stable release. Requires kiln 1.0.0, whose source key leaves out the pubspec's `version` and `description`, so a release that changes only those needs no new native build.

## 0.1.3

- `LICENSE` has only the package's MIT license. The notices of the bundled native code are in `NOTICES`, which Flutter reads in place of `LICENSE`, so an app's license page still shows all of them.

## 0.1.2

- Requires `code_assets` 2.2, `hooks` 2.2 and `kiln` 0.2. With `code_assets` 1.x, the package could not be installed with current `objective_c` and `shared_preferences_foundation`.

## 0.1.1

- The package no longer includes iOS and macOS files that `flutter pub get`
  generates on the publishing machine. No code changes.

## 0.1.0

- First release on pub.dev, as fllama_cpp (fllama 0.0.1 on pub.dev is an
  older, unrelated release). MIT licensed.
