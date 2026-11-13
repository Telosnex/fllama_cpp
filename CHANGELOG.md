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
