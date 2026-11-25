# ADR 003 — llama.cpp / wllama provenance

Status: accepted (updated 2026-11-24)

This documents what fllama's native and web llama.cpp runtimes are made of and
how to reproduce them. Keep it current whenever either runtime is refreshed.

---

## 1. Current runtime

fllama runs the same llama.cpp source two ways:

- **Native** compiles the vendored copy at `src/llama.cpp`.
- **Web** ships `wllama/index.js`, `wllama/wasm/wllama.wasm`, and the compat
  build at `wllama/compat/wllama.wasm`. Both Wasm files include their
  JavaScript glue. The native release workflow builds them with
  `tool/kiln/build_web.dart` from
  `web_build/wllama.json` and `web_build/wllama.patch`, and publishes it in
  the same release as the native libraries (ADR 002).
  `native_artifacts/web.json` pins the files.

Both use upstream llama.cpp

```text
0b51bb2fed322bc884f96f98db340e2b0f6ea176  (2026-11-22, b12637)
server: support /models/sse on single-model mode (#32398)
```

with the patches in `patches/llama.cpp`. It is the llama.cpp pin of wllama
`c875858`. The web bundle names its llama.cpp build `b12637-0b51bb2`.

---

## 2. Source lineage

### 2a. wllama

```text
ngxson/wllama c87585843be05973f1fd82b53d28659c45e1c41a (2026-11-23)
hf space: list the LFS files without list_lfs_files(), it fails on the files of a rejected push (#377)
```

plus `web_build/wllama.patch`, the reproducible source of every fllama change
to wllama. The patch does not move the llama.cpp gitlink.

### 2b. llama.cpp

```text
upstream: https://github.com/ggml-org/llama.cpp
commit:   0b51bb2fed322bc884f96f98db340e2b0f6ea176
build:    b12637 (git rev-list --count)
```

`src/llama.cpp` is an exact copy of that commit, with the patches in
`patches/llama.cpp` applied, plus the fllama-owned provenance file
`src/llama.cpp/FLLAMA_LLAMA_CPP_DROP.txt`. The web build applies the same
patch files to its llama.cpp clone. `test/llama_cpp_pin_test.dart` checks
that native and web pin one commit and that every patch is applied.

Patches (2026-11-24):

- `0001-mtmd-check-sched-reserve.patch`: llama.cpp PR 29150 (open). The patch
  now uses the scheduler shared by mtmd subcontexts. Without the check, an
  mmproj load can report success after it fails to reserve its compute
  buffer. The next image request aborts. Drop it when llama.cpp has the PR.
- `0002-server-realtime-overflow-error.patch`: a realtime conversation that
  fills the context sends its error with no prompt tokens, and `send_error`
  asserts on that: the app aborts. Drop it when llama.cpp fixes it.
- `0003-ggml-metal-keep-devices-at-exit.patch`: at exit, the static Metal device
  list frees each device, and `ggml_metal_device_free` asserts that no Metal
  buffer exists. An app that exits with a loaded model aborts. The list is
  now never destroyed. Drop it when llama.cpp fixes it.

### 2c. Artifact fingerprints

`native_artifacts/web.json` has the SHA-256 of each released file; the
release workflow writes it. To compare a local build with a release, use
`--work /tmp/fllama_web_build` and the same linux/amd64 image.

---

## 3. fllama's wllama changes

All are in `web_build/wllama.patch`. Upstream wllama has had request IDs,
`n_parallel`, `kv_unified`, cancel and one-call-at-a-time wasm calls since
`a3d9da2` (PR 270), so fllama no longer patches those.

- **Per-request Jinja template.** A chat request can carry
  `jinja_template`, as in native fllama, without the template being part of
  the loaded model: requests with and without tools share one server
  context. A template that does not render falls back to ChatML.
- **Load in the same worker.** `wllama_unload` (a JSPI / Asyncify export)
  frees the model and its context; with `Wllama.reuseWorker`, a second
  `loadModel()` unloads and loads in the same worker
  (`ProxyToWorker.replaceFiles`, async file reads). It refuses, before
  unloading, more threads, another build, another WebGPU setup, or a model
  that needs RPC workers. On iOS Safari 26.3 a new worker does not get the
  memory of an ended one back.
- **pthread pool of 2 × n_threads.** The text model and the mtmd image
  encoder each start n_threads − 1 pthreads; in Safari a pthread beyond the
  pool never starts, and image encoding waits forever.
- **Link options**: `-sSTACK_SIZE=16MB` (Gemma tool / response-format
  grammars exhaust 5 MB) and `-sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE=_localtime_js`
  (`std::localtime` / `strftime`).

wllama v4 uses 32-bit Wasm for both builds, so it does not need the Memory64
check. It converts the worker abort message to a string upstream; fllama still
handles a missing or non-string stack. Large models can split their
CPU-resident weights across RPC workers. This needs cross-origin isolation
and more than one inference thread.

Toolchain: Emscripten SDK 4.0.20, Dawn `v20260317.182325`, and Node 22.16.0.
The compat build also uses pinned Binaryen with wllama's Asyncify patch for
Wasm exception handling. `web_build/wllama.json` pins the checkout and the
patch checksum.

---

## 4. fllama native adaptations

fllama builds `server-context` directly because `tools/server` also builds
`llama-server`, which needs cpp-httplib. In b12637, add
`server-slot-sched.cpp` and link the vendored hash library for prompt prefix
hashes. The Decision API calls the same in-process route; llama.cpp now
packs LFM3 D1 questions that share text or an image into one prompt.

Other native adaptations:

- JSON is `common_json` (`common/json.h`); `json_text` uses
  `safe_json_to_str`;
- `oaicompat_chat_params_parse` takes the vocab and a `common_chat_session`;
  the task gets it with `apply_chat_session` and the reader with
  `post_tasks(tasks, session)`, which parses tool calls from the stream;
- the per-request template sets `server_chat_params` by field name;
- tokenizer-only loads use `LLAMA_LOAD_MODE_MMAP`; directly made
  `common_params` are CPU-postprocessed so batch and speculative thread
  counts do not keep the `-1` CLI sentinel.

fllama does not link cpp-httplib or download from C++. The stubs in
`fllama_download_stub.cpp` reject remote media and keep the upstream hostname
resolver and CLI model cache path code out of the binary. Native inference
uses local model paths and caller-provided media.

---

## 5. Reproduce the web runtime

The native release workflow builds it: the `web` job runs
`tool/kiln/build_web.dart` in the image of `web_build/wllama.json`, and
`web-test` loads a model with the result in Chrome. `integration.yml`'s `web-files`
job builds the same files for each commit. The steps:

1. Check out wllama at the pinned commit and apply `web_build/wllama.patch`.
2. Clone llama.cpp with its history at the pinned commit and apply
   `patches/llama.cpp`. `build:worker` names the build
   `b<commit count>-<short hash>`.
3. Download the Dawn WebGPU package and check its SHA-256.
4. Build the main Wasm (JSPI) and the compat Wasm (Asyncify and Wasm
   exceptions). Pack the JavaScript glue into each Wasm file and bundle
   `index.js`.

Locally, with Docker:

```sh
docker run --rm -v "$PWD:/src" -v /tmp/fllama_web:/out -w /src \
  <emsdkImage with Dart> bash -c \
  'dart tool/kiln/build_web.dart --out /out --work /tmp/fllama_web_build'
```

---

## 6. Refresh llama.cpp and wllama

1. Pick the llama.cpp commit: the pin of the wllama commit you move to is the
   safe choice.
2. Apply `web_build/wllama.patch` to the new wllama
   (`git apply --3way --exclude=llama.cpp`), resolve, and write the patch
   again (`git diff --cached`). Drop what upstream now has.
3. Copy llama.cpp into `src/llama.cpp`:

   ```sh
   rsync -a --delete --exclude='.git' --exclude='build/' \
     --exclude='.DS_Store' --exclude='FLLAMA_LLAMA_CPP_DROP.txt' \
     "$LLAMA_CPP/" src/llama.cpp/
   git apply --directory=src/llama.cpp patches/llama.cpp/*.patch
   ```

4. Update `web_build/wllama.json`, `src/CMakeLists.txt`
   (`LLAMA_BUILD_COMMIT`), `src/llama.cpp/FLLAMA_LLAMA_CPP_DROP.txt`, this
   ADR, and fllama's C++ for API changes.
5. Run `flutter test test`, the native integration test, and the web test in
   Chrome and Safari. Run `integration.yml` on the PR head, either on a
   `ci/**` branch or with `workflow_dispatch`. A change under
   `src/llama.cpp/ggml` starts `cuda_pack.yml`; publish the CUDA pack before
   the native release.

---

## 7. Native Decision API validation for this drop (2026-11-24)

LFM3 D1 Omni 2B Q8_0 with its projector, macOS Metal (M4 Max), 8,192-token
context. The nine-question text figure is the median of three warm calls.
The other figures are one warm call each.

| Fixture | Prompt tokens, b12211 → b12637 | Time, b12211 → b12637 |
| --- | ---: | ---: |
| Text and nine questions | 894 → 390 | 318.6 → 121.0 ms |
| Text and three questions | 160 → 118 | 73.7 → 41.2 ms |
| Wallpaper and three questions | 520 → 250 | 219.3 → 90.9 ms |

Both builds gave the same choices and scores, with small changes to the
probabilities. The response JSON shape was unchanged. A 10,426-token request
returned `contextSizeExceeded` in both builds.
