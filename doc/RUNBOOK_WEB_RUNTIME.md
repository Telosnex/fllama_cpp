# Runbook: Rebuilding the fllama Web Runtime

The web runtime is wllama v4: `wllama/index.js`, `wllama/wasm/wllama.wasm`
(main), and `wllama/compat/wllama.wasm` (compat). Both builds use wasm32 and
embed the worker JavaScript in the Wasm. The main build uses JSPI and relaxed
SIMD; the compat build uses Asyncify and is used when either feature is
missing (e.g. Safari). Firefox with relaxed SIMD can use the main build on
CPU without JSPI. GitHub Actions builds the released files in the native
release workflow (kiln ADR 002).

Each Wasm instance is limited to 4 GiB of memory. With cross-origin isolation
(COOP/COEP), more than one thread, and async file reads (JSPI or compat),
wllama can spread model weights across RPC workers. Unsupported modes report
a load error when a model does not fit in a single instance. The browser's
available memory and GPU limits can still prevent large models from loading.

## Source of truth

- `web_build/wllama.json`: the wllama and llama.cpp commits, the Dawn WebGPU
  package and its SHA-256, the emsdk image digest (Emscripten 4.0.20), and
  Node 22.16.0. The Binaryen commit and patch checksum pin the `wasm-opt`
  rebuilt for Asyncify with Wasm exceptions; only compat uses it.
- `web_build/wllama.patch`: all fllama changes to wllama (ADR 003 §3).
- `tool/kiln/build_web.dart`: the build. It runs the steps of wllama's
  `build:wasm` (the default and the compat build), `build:worker` and
  `build:tsup`, and stops at the first failed step.
- `lib/web/fllama_web_init.js`: the hand-written bridge. It is in git.

All of these are inputs of the source key. A change to any of them makes a
new native release, and the release contains the web files.

## Rebuild

1. Change `web_build/wllama.json` or `web_build/wllama.patch`. If the
   llama.cpp commit changes, refresh `src/llama.cpp` too (ADR 003 §6).
2. Run the release workflow: `git push -f origin HEAD:kiln-release-dry`,
   then `HEAD:kiln-release`. The web job builds the files. The web-test
   job runs `scripts/check_web_assets.sh` and loads a model in Chrome
   (`test/web_runtime_test.dart`).
3. Merge the `kiln-manifest/<tag>` branch. It updates
   `native_artifacts/web.json` and `lib/src/web_runtime.g.dart`.

## Build and test locally

```bash
cd "$FLLAMA_DIR"
docker run --rm -v "$PWD:/src" -v /tmp/fllama_web:/out -w /src \
  "$(python3 -c 'import json;print(json.load(open("web_build/wllama.json"))["emsdkImage"])')" \
  bash -c 'dart tool/kiln/build_web.dart --out /out'
dart run kiln:web install-dev --from /tmp/fllama_web
scripts/check_web_assets.sh

mkdir -p test/web_models
curl -sSfL -o test/web_models/stories15M-q4_0.gguf \
  https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories15M-q4_0.gguf
flutter test --platform chrome test/web_runtime_test.dart
```

The image needs Dart on the PATH. Without `--from`, `install-dev` downloads
the released files.

## Decide and realtime bridge tests

Run `node --test dev/web_smoke/web_api.test.mjs` to check the JS bridge
without model files. The Chrome runtime test also checks the Dart API
with the small test model.

## Smoke test with a real model

```bash
cd "$FLLAMA_DIR/dev/web_smoke"
npm install
HEADLESS=1 npm run smoke:current -- --max-tokens=100 --ctx=4096
```

It serves the built Flutter example, overlays `lib/web/` into
`example/build/web/kiln/fllama/`, and calls `fllamaChatWebJs()`.
See `dev/web_smoke/README.md`. `--browser=webkit` runs Safari's engine, and
`--force-compat` makes Chrome load the compat build.

## Common pitfalls

- Do not add runtime files to `example/web/` or a script tag to `index.html`; the build hook installs the files, and Dart loads the bridge.
- Do not ship separate worker JS files. The constructor takes `{ default: '<wasm-url>' }` and `setCompat()` takes `{ wasm: '<compat-wasm-url>' }`.
- After changing sources, test with `web_build: local` until the release workflow produces updated manifests. Do not stamp old release bytes as a new runtime.
- Do not assume browser requests can run concurrently; the fllama JS bridge serializes them until batching is validated.
