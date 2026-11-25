<img src="https://raw.githubusercontent.com/Telosnex/fllama_cpp/main/fllama_header.png"
     alt="fllama image header, bird like Flutter mascot riding a llama. Text reads: FLLAMA. Run cutting-edge, free, large language models. Near ChatGPT quality. On any platform.
     iOS, macOS, Android, Windows, Linux, and Web. Metal GPU support."
     style="float: left; margin-right: 0px;" />

- Everywhere: web, iOS, macOS, Android, Windows, Linux.
- Fast: exceeds average reading speed on all platforms except web.
- Private: No network connection, server, cloud required.
- Forward compatible: Any model compatible with llama.cpp. (so, every model.)
- Full OpenAI compatability: chat messages, multimodal/image support via LLaVa models, and function calling. (constrain outputs to valid JSON based on a JSON schema) 
- Bare metal interface: call LLMs without being constrained to a chat implementation.
- Use with FONNX for RAG
  - Combine with [FONNX](https://github.com/Telosnex/fonnx) to have a full retrieval-augmented generation stack available on all platforms.

## CI
The `Native release` GitHub Actions workflow builds the native libraries for
every platform and the web runtime, and runs the web runtime tests (see
`.github/workflows/kiln_release.yml`). Run the integration tests locally:
see `example/integration_test/README.md`.

## Integrate
- Add it to your app:
```
flutter pub add fllama_cpp
```
- Run inference:
```dart
import 'package:fllama_cpp/fllama_cpp.dart';

String latestResult = "";

final request = OpenAiRequest(
  maxTokens: 256,
  messages: [
    Message(Role.system, 'You are a chatbot.'),
    Message(Role.user, messageText),
  ],
  // -1: llama.cpp fits the layers to free GPU memory (all layers on web).
  // 0: CPU only. N: N layers on the GPU.
  numGpuLayers: -1,
  modelPath: _modelPath!,
  mmprojPath: _mmprojPath,
  // Sampling fields that are not set use the values that the GGUF file
  // recommends, else llama.cpp's defaults, as llama-server does.
  // Proportional to RAM use. 
  // 4096 is a good default. 
  // 2048 should be considered on devices with low RAM (<8 GB)
  // 8192 and higher can be considered on device with high RAM (>16 GB)
  // Models are trained on <= a certain context size. Exceeding that # can/will lead to completely incoherent output.
  // 0 is the model's trained context size.
  contextSize: 2048,
  logger: (log) {
    // ignore: avoid_print
    print('[llama.cpp] $log');
  },
);
fllamaChat(request, (response, json, done, error) {
  // error is set only on the last call, when done is true.
  setState(() {
    latestResult = error?.message ?? response;
  });
});
```
### Flutter 3.50 on Linux

Flutter 3.50's Linux GTK engine exports its own unwinder. This can abort
Linux apps when native code throws a C++ exception, even if that code catches
it. This affects debug, profile, and release runners; upgrading the Dart
package alone does not fix it. See [flutter/flutter#196402](https://github.com/flutter/flutter/issues/196402).

In your app's `linux/runner/CMakeLists.txt` (or `linux/CMakeLists.txt` if
it defines the executable), add this after `add_executable` and before linking
Flutter. It requires CMake 3.13 or later:

```cmake
target_link_options(${BINARY_NAME} PRIVATE
  "LINKER:--push-state,--no-as-needed,-lgcc_s,--pop-state")
```

Rebuild the Linux runner. `readelf -d <runner>` should list `libgcc_s.so.1`
before `libflutter_linux_gtk.so` in `NEEDED`. The example runner already does
this. Remove the workaround when your Flutter SDK includes the upstream fix.

### Realtime voice
`fllamaRealtimeOpen` runs a session of llama.cpp's realtime API, the
`/v1/realtime` WebSocket of llama-server, in process. Events are the JSON
objects of OpenAI Realtime GA; see "WebSocket `/v1/realtime`" in
`src/llama.cpp/tools/server/README.md`. A model with streaming audio input
and chat (LFM3-Audio, LFM3-Omni) holds a voice conversation, with speech out
and tool calls. Voxtral Realtime, or a live ASR checkpoint with
`query: 'intent=transcription'`, transcribes.

```dart
final session = fllamaRealtimeOpen(FllamaRealtimeRequest(
  modelPath: 'LFM3-Audio-2B-Q4_K_M.gguf',
  mmprojPath: 'mmproj-LFM3-Audio-2B-Q8_0.gguf',
  contextSize: 32768,
));
session.events.listen((event) {
  // session.created, response.output_text.delta,
  // response.output_audio.delta (base64 PCM16), ..., and last
  // fllama.realtime.closed.
});
session.send({'type': 'input_audio_buffer.append', 'audio': base64Pcm16});
session.send({'type': 'input_audio_buffer.commit'});
session.send({'type': 'response.create'});
```

The server does no turn detection: the app commits each turn. The
conversation stays in the context, and audio uses it (LFM3-Audio: about
12.5 positions per second of input). A full context ends the session with
an error. A session holds one inference slot until it ends. Web loads one
slot by default. Close the session before you use another model.

### Decisions
`fllamaDecide` runs llama.cpp's decision API, `POST /v1/systemone` of
llama-server, in process: typed questions about a state, answered by a
decision model in one forward pass, with no generated text. The request and
response are the JSON bodies of that route; see "POST `/v1/systemone`" in
`src/llama.cpp/tools/server/README.md`. A question is a `choice`, a `score`
or a `noul` (yes/no). With its projector, LFM3 D1 Omni also reads images and
hears audio (`files`: data URLs).

```dart
final decision = fllamaDecide(
  FllamaDecisionRequest(
    modelPath: 'd1-Omni-2B-Q8_0.gguf',
    mmprojPath: 'mmproj-d1-Omni-2B-Q8_0.gguf',
  ),
  {
    'state': 'I was charged twice for my order.',
    'questions': {
      'team': {
        'type': 'choice',
        'instructions': 'Which team should handle this?',
        'criteria': {'billing': null, 'shipping': null},
      },
    },
  },
);
final answers = (await decision.response)['answers'];
// {"team": {"choice": "billing", "probabilities": {...}, "confidence": ...}}
```

The model reads the whole prompt, with its images and audio, in one batch:
`contextSize` is also the batch, and 0 is 4096.

## Tips & Tricks
### Web
  Web uses a wllama/WebGPU runtime. In a Flutter web build, the fllama build hook installs it in `web/kiln/fllama_cpp/` of the app, and fllama loads it at the first call; the app needs no script tag (kiln ADR 002). Other embedders serve those files and set `FllamaWeb.runtimeUri`.
  Serve the app with cross-origin isolation to use multiple Wasm threads.
  For decisions and realtime, pass model and projector URLs or browser-local
  model locators, as for chat. The browser selects the WebGPU adapter and
  does not use `gpuDeviceKey`.

  To check the web runtime locally:
  ```sh
  dart run kiln:web install-dev
  scripts/check_web_assets.sh
  ```
### Models
  Any GGUF model that llama.cpp supports. The tests use
  Qwen3.5 0.8B (Q4_K_M),
  and its mmproj file for images.
### RAM Requirements
  Roughly: you'll need as much RAM as the model file size.
  If inference runs on CPU, that much regular RAM is required.
  If inference runs on GPU, that much GPU RAM is required.
### Download files from HuggingFace at runtime
  HuggingFace, among many things, can be thought of as GitHub for AI models.
  You can download a model from HuggingFace and use it with fllama.
  To get a download URL at runtime, see below.
  ```dart
  String getHuggingFaceUrl(
    {required String repoId,
    required String filename,
    String? revision,
    String? subfolder}) {
  // Default values
  const String defaultEndpoint = 'https://huggingface.co';
  const String defaultRevision = 'main';

  // Ensure the revision and subfolder are not null and are URI encoded
  final String encodedRevision =
      Uri.encodeComponent(revision ?? defaultRevision);
  final String encodedFilename = Uri.encodeComponent(filename);
  final String? encodedSubfolder =
      subfolder != null ? Uri.encodeComponent(subfolder) : null;

  // Handle subfolder if provided
  final String fullPath = encodedSubfolder != null
      ? '$encodedSubfolder/$encodedFilename'
      : encodedFilename;

  // Construct the URL
  final String url =
      '$defaultEndpoint/$repoId/resolve/$encodedRevision/$fullPath';

  return url;
}
```

# Licensing

FLLAMA is licensed under the MIT License (LICENSE). NOTICES has that license
and the licenses of the code it bundles (llama.cpp, nlohmann_json, and the
NVIDIA CUDA libraries of the CUDA pack). Flutter reads NOTICES in place of
LICENSE, so an app's license page shows all of them.

# llama.cpp source layout and update process

fllama has two llama.cpp delivery paths:

- **Native platforms** compile the vendored source tree in this repo:
  ```text
  src/llama.cpp
  ```
- **Web** uses wllama (`wllama/index.js`, `wllama/wasm/wllama.wasm`, and
  `wllama/compat/wllama.wasm` for browsers without JSPI or relaxed SIMD).
  Both Wasm files include their JavaScript glue.
  The release workflow builds it with `tool/kiln/build_web.dart` from wllama and
  llama.cpp at the commits of `web_build/wllama.json`, with
  `web_build/wllama.patch`. `native_artifacts/web.json` pins the files.
  Models with more than 4 GiB of CPU-resident weights need cross-origin
  isolation and more than one inference thread.

To keep native and web matched, the llama.cpp commit of `web_build/wllama.json`
is the commit of `src/llama.cpp`.

## Refresh native llama.cpp from wllama

```sh
export FLLAMA=/Users/jpo/dev/fllama
export WLLAMA=/Users/jpo/dev/ngxson_wllama

cd "$FLLAMA"
git status --short

# Dry run first. Review every changed/deleted file.
rsync -nrc --delete \
  --exclude='.git' \
  --exclude='build/' \
  --exclude='FLLAMA_LLAMA_CPP_DROP.txt' \
  "$WLLAMA/llama.cpp/" \
  "$FLLAMA/src/llama.cpp/"

# If the dry run is sane, do the copy.
rsync -a --delete \
  --exclude='.git' \
  --exclude='build/' \
  --exclude='FLLAMA_LLAMA_CPP_DROP.txt' \
  "$WLLAMA/llama.cpp/" \
  "$FLLAMA/src/llama.cpp/"
```

Then update the native build metadata/documentation:

- `src/CMakeLists.txt`: update `LLAMA_BUILD_COMMIT`.
- `src/llama.cpp/FLLAMA_LLAMA_CPP_DROP.txt`: record where the drop came from and why.

If the wllama `llama.cpp` directory is a real Git checkout, use:

```sh
git -C "$WLLAMA/llama.cpp" rev-parse --short HEAD
```

If it is a copied/submodule tree without `.git` metadata, use the recorded source commit in `FLLAMA_LLAMA_CPP_DROP.txt` or the wllama submodule gitlink:

```sh
git -C "$WLLAMA" ls-files -s llama.cpp
```

Clean stale native build outputs before validating:

```sh
cd "$FLLAMA"
rm -rf src/build example/build
cmake -S src -B src/build -DCMAKE_BUILD_TYPE=Release
cmake --build src/build -j
```

Then validate through a Flutter host, for example:

```sh
cd "$FLLAMA/example"
flutter build macos --debug
```

## Rebuild the web wllama artifacts

Change `web_build/wllama.json` or `web_build/wllama.patch`, then run the native
release workflow: its web job builds the files and its browser test loads a
model with them. For a local build, run the script in the pinned image (see
the comment at the top of `tool/kiln/build_web.dart`), then:

```sh
dart run kiln:web install-dev --from /tmp/fllama_web
node --check lib/web/fllama_web_init.js
scripts/check_web_assets.sh
flutter test --platform chrome test/web_runtime_test.dart
```

After a change to `lib/web/fllama_web_init.js`, run
`dart run kiln:web stamp`.

# Web development
- The web example uses wllama's server backend and requires cross-origin isolation for SharedArrayBuffer/pthreads.
- From the example directory, run debug mode with:
  ```sh
  flutter run -d chrome --cross-origin-isolation
  ```
- Or run a release-style local build with the bundled header-setting server:
  ```sh
  flutter build web
  node web/server.js
  ```
- `flutter run -d web` is not a valid Flutter device id; use `chrome` for an auto-launched browser or `web-server` if you want to open the URL yourself.
- If your Flutter version does not support `--cross-origin-isolation`, pass the headers explicitly:
  ```sh
  flutter run -d chrome \
    --web-header=Cross-Origin-Opener-Policy=same-origin \
    --web-header=Cross-Origin-Embedder-Policy=require-corp
  ```

# FFI development
- When changes are made to C++ bindings, run `flutter pub run ffigen --config ffigen.yaml` to make them available in Dart.
- `rm -rvf Podfile.lock && rm -rvf Podfile && rm -rvf Pods && flutter clean`
^ run in example/macos / example/ios when upgrading cpp files, or when getting cryptic errors about build cache.

