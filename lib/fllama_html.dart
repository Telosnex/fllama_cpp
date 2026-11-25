import 'dart:async';
import 'dart:js_interop';
import 'dart:convert';

import 'package:fllama_cpp/fllama_cpp.dart';
import 'package:fllama_cpp/src/web_parallel_slots.dart';
import 'package:fllama_cpp/src/web_runtime_loader.dart';

export 'package:fllama_cpp/src/web_runtime_loader.dart' show FllamaWeb;

@JS('fllamaInferenceJs')
external JSPromise<JSNumber> fllamaInferenceJs(
  JSAny request,
  JSFunction callback,
);

Future<List<FllamaGpuMemoryInfo>> fllamaGpuMemoryInfoGetAll() async {
  return const [];
}

/// No GPU backends to allow or forbid on this platform.
bool fllamaSetGpuAllowed(bool allowed) => true;

/// No backend libraries on this platform.
Future<List<String>> fllamaLoadedBackendFiles() async => const [];

/// No GPU packs on this platform.
List<FllamaGpuPackFile> fllamaGpuPackFiles() => const [];

/// No GPU packs on this platform.
Future<String?> fllamaLoadGpuPack(String pack, String directory) async =>
    'This platform does not load GPU packs';

/// No Vulkan on this platform.
Future<bool> fllamaHasVulkanGpu() async => false;

/// No CUDA on this platform.
Future<bool> fllamaHasCudaGpu() async => false;

/// On the web, model files are not on a file system that Dart can read.
int? fllamaTrainedContextLength(String modelPath) => null;

// Keep in sync with fllama_inference_request.dart to pass correctly from Dart to JS
extension type _JSFllamaInferenceRequest._(JSObject _) implements JSObject {
  external factory _JSFllamaInferenceRequest({
    required int contextSize,
    required String input,
    required int maxTokens,
    required String modelPath,
    String? modelMmprojPath,
    required int numGpuLayers,
    required int numThreads,
    double? temperature,
    double? penaltyFrequency,
    double? penaltyRepeat,
    double? topP,
    // INTENTIONALLY MISSING: logger
  });
}

/// Runs [FllamaInferenceRequest.openAiRequestJsonString] as a chat, if set,
/// as native fllama does. Else runs [FllamaInferenceRequest.input] as one
/// user message. Returns the request ID soon, for [fllamaCancelInference];
/// [callback] gets the results. See [FllamaInferenceCallback].
///
/// Most callers want [fllamaChat].
Future<int> fllamaInference(
  FllamaInferenceRequest dartRequest,
  FllamaInferenceCallback callback,
) async {
  await loadFllamaWebRuntime();
  final openAiRequestJsonString = dartRequest.openAiRequestJsonString;
  if (openAiRequestJsonString != null) {
    return _runWebChat(
      _JSFllamaWebInferenceRequest(
        openAiRequestJsonString: openAiRequestJsonString,
        messagesAsJsonString: '[]',
        toolsAsJsonString: '[]',
        maxTokens: dartRequest.maxTokens,
        modelPath: dartRequest.modelPath,
        modelMmprojPath: dartRequest.modelMmprojPath,
        contextSize: dartRequest.contextSize,
        numGpuLayers: dartRequest.numGpuLayers,
        numThreads: dartRequest.numThreads,
        nParallel: dartRequest.nParallel != null && dartRequest.nParallel! > 0
            ? dartRequest.nParallel
            : kFllamaWebDefaultParallelSlots,
        temperature: dartRequest.temperature,
        penaltyFrequency: dartRequest.penaltyFrequency,
        penaltyRepeat: dartRequest.penaltyRepeat,
        topP: dartRequest.topP,
      ),
      (_, _) {},
      callback,
    );
  }
  final jsRequest = _JSFllamaInferenceRequest(
    contextSize: dartRequest.contextSize,
    input: dartRequest.input,
    maxTokens: dartRequest.maxTokens,
    modelPath: dartRequest.modelPath,
    modelMmprojPath: dartRequest.modelMmprojPath,
    numGpuLayers: dartRequest.numGpuLayers,
    numThreads: dartRequest.numThreads,
    temperature: dartRequest.temperature,
    penaltyFrequency: dartRequest.penaltyFrequency,
    penaltyRepeat: dartRequest.penaltyRepeat,
    topP: dartRequest.topP,
  );

  callbackFn(
    String response,
    String responseJson,
    bool done,
    String? errorJson,
  ) {
    callback(
      response,
      responseJson,
      done,
      errorJson == null ? null : FllamaError.fromJson(errorJson),
    );
  }

  return (await fllamaInferenceJs(jsRequest, callbackFn.toJS).toDart).toDartInt;
}

// The promise resolves with undefined: JSAny? (JSAny never completed).
@JS('fllamaWebModelDeleteJs')
external JSPromise<JSAny?> fllamaWebModelDeleteJs(String modelPath);

@JS('fllamaWebIsModelDownloadedJs')
external JSPromise<JSBoolean> fllamaWebIsModelDownloadedJs(String modelPath);

@JS('fllamaWebPickModelJs')
external JSPromise<JSString> fllamaWebPickModelJs();

@JS('fllamaChatWebJs')
external JSPromise<JSNumber> fllamaChatWebJs(
  // ignore: library_private_types_in_public_api
  _JSFllamaWebInferenceRequest request,
  JSFunction loadCallback,
  JSFunction callback,
);

extension type _JSFllamaWebInferenceRequest._(JSObject _) implements JSObject {
  external _JSFllamaWebInferenceRequest({
    required String openAiRequestJsonString,
    required String messagesAsJsonString,
    required String toolsAsJsonString,
    required int maxTokens,
    required String modelPath,
    String? modelMmprojPath,
    required int contextSize,
    required int numGpuLayers,
    int? numThreads,
    int? nParallel,
    double? temperature,
    double? penaltyFrequency,
    double? penaltyRepeat,
    double? topP,
  });
}

typedef FllamaWebLoadCallback =
    void Function(double downloadProgress, double loadProgress);

Future<bool> fllamaWebIsModelDownloaded(String modelPath) async {
  await loadFllamaWebRuntime();
  return fllamaWebIsModelDownloadedJs(modelPath).toDart.then((value) {
    return value.toDart;
  });
}

/// Pick a local GGUF in the browser and return an opaque modelPath token.
///
/// The selected File stays in JavaScript memory and is passed directly to
/// wllama. This avoids copying multi-GB GGUF bytes through Dart. Browsers do
/// not expose the full local filesystem path; the token may include the file
/// name for display only.
Future<String?> fllamaWebPickModel() async {
  await loadFllamaWebRuntime();
  final token = await fllamaWebPickModelJs().toDart.then((value) {
    return value.toDart;
  });
  return token.isEmpty ? null : token;
}

/// Run chat inference on web using wllama.
///
/// [OpenAiRequest.modelPath] should be a GGUF URL, a blob URL, or a token
/// returned by [fllamaWebPickModel].
Future<int> fllamaChatWeb(
  OpenAiRequest request,
  FllamaWebLoadCallback loadCallback,
  FllamaInferenceCallback callback,
) async {
  await loadFllamaWebRuntime();
  final messagesAsMaps = request.messages
      .map((e) => {'role': e.role.openAiName, 'content': e.text})
      .toList();
  final toolsAsMaps = request.tools
      .map(
        (e) => {
          'type': 'function',
          'function': {
            'name': e.name,
            'description': e.description,
            'parameters': e.jsonSchema,
          },
        },
      )
      .toList();
  final jsRequest = _JSFllamaWebInferenceRequest(
    openAiRequestJsonString: request.toJsonString(),
    toolsAsJsonString: jsonEncode(toolsAsMaps),
    messagesAsJsonString: jsonEncode(messagesAsMaps),
    maxTokens: request.maxTokens,
    modelPath: request.modelPath,
    modelMmprojPath: request.mmprojPath,
    contextSize: request.contextSize,
    numGpuLayers: request.numGpuLayers,
    nParallel: fllamaWebParallelSlots(request),
    temperature: request.temperature,
    penaltyFrequency: request.frequencyPenalty,
    penaltyRepeat: request.repeatPenalty,
    topP: request.topP,
  );
  return _runWebChat(jsRequest, loadCallback, callback);
}

Future<int> _runWebChat(
  _JSFllamaWebInferenceRequest jsRequest,
  FllamaWebLoadCallback loadCallback,
  FllamaInferenceCallback callback,
) async {
  firstCallback(double downloadProgress, double loadProgress) {
    loadCallback(downloadProgress, loadProgress);
  }

  secondCallback(
    String response,
    String responseJson,
    bool done,
    String? errorJson,
  ) {
    callback(
      response,
      responseJson,
      done,
      errorJson == null ? null : FllamaError.fromJson(errorJson),
    );
  }

  final id = await fllamaChatWebJs(
    jsRequest,
    firstCallback.toJS,
    secondCallback.toJS,
  ).toDart;
  return id.toDartInt;
}

Future<void> fllamaWebModelDelete(String modelPath) async {
  await loadFllamaWebRuntime();
  await fllamaWebModelDeleteJs(modelPath).toDart;
}

// Tokenize
@JS('fllamaTokenizeJs')
external JSPromise<JSNumber> fllamaTokenizeJs(String modelPath, String input);

/// An estimate of the number of tokens in [request.input]: one token for
/// each 4 characters. The web runtime does not tokenize: that loads the model
/// in wllama, which can unload the model of a running chat.
Future<int> fllamaTokenize(FllamaTokenizeRequest request) async {
  await loadFllamaWebRuntime();
  return (await fllamaTokenizeJs(
    request.modelPath,
    request.input,
  ).toDart).toDartInt;
}

@JS('fllamaCancelInferenceJs')
external void fllamaCancelInferenceJs(int requestId);

/// Cancels the inference with the given [requestId].
///
/// The request then ends soon with its last callback: `done` set, the text
/// so far, and no error. A request that has not started ends with no text.
void fllamaCancelInference(int requestId) {
  // Before the runtime loads, no inference exists to cancel.
  if (!fllamaWebRuntimeLoaded) return;
  fllamaCancelInferenceJs(requestId);
}

@JS('fllamaDecideJs')
external int _decideJs(
  _JSFllamaModelRequest request,
  String body,
  JSFunction done,
  JSFunction? logger,
);

@JS('fllamaRealtimeOpenJs')
external _JSRealtimeSession _realtimeOpenJs(
  _JSFllamaModelRequest request,
  String? query,
  JSFunction onEvent,
  JSFunction? logger,
);

extension type _JSFllamaModelRequest._(JSObject _) implements JSObject {
  external _JSFllamaModelRequest({
    required String modelPath,
    String? modelMmprojPath,
    required int contextSize,
    required int numGpuLayers,
    required int numThreads,
  });
}

extension type _JSRealtimeSession._(JSObject _) implements JSObject {
  external bool send(String json);
  external void close();
}

/// Answers the questions of [body] with the decision model of [request].
/// [body] is the JSON body of llama-server's `POST /v1/systemone`.
/// Returns at once. The model loads in the background.
FllamaDecision fllamaDecide(
  FllamaDecisionRequest request,
  Map<String, dynamic> body,
) {
  _checkModelPath(request.modelPath);
  return _WebDecision(request, jsonEncode(body));
}

class _WebDecision implements FllamaDecision {
  _WebDecision(FllamaDecisionRequest request, String body) {
    unawaited(_start(request, body));
  }

  final _response = Completer<Map<String, dynamic>>();
  int? _id;

  @override
  Future<Map<String, dynamic>> get response => _response.future;

  Future<void> _start(FllamaDecisionRequest request, String body) async {
    try {
      await loadFllamaWebRuntime();
      if (_response.isCompleted) return;
      _id = _decideJs(
        _JSFllamaModelRequest(
          modelPath: request.modelPath,
          modelMmprojPath: request.mmprojPath,
          contextSize: request.contextSize,
          numGpuLayers: request.numGpuLayers,
          numThreads: request.numThreads,
        ),
        body,
        _done.toJS,
        request.logger?.toJS,
      );
    } catch (error) {
      if (!_response.isCompleted) {
        _response.completeError(
          FllamaError(FllamaErrorType.modelLoad, error.toString()),
        );
      }
    }
  }

  @override
  void cancel() {
    if (_response.isCompleted) return;
    final id = _id;
    if (id != null) fllamaCancelInferenceJs(id);
    _response.completeError(
      const FllamaError(FllamaErrorType.cancelled, 'Cancelled'),
    );
  }

  void _done(String text, String? errorJson) {
    if (_response.isCompleted) return;
    if (errorJson != null) {
      _response.completeError(FllamaError.fromJson(errorJson));
      return;
    }
    final decoded = _decodeObject(text);
    if (decoded != null) {
      _response.complete(decoded);
    } else {
      _response.completeError(
        FllamaError(
          FllamaErrorType.other,
          'fllama: the response is not a JSON object: $text',
        ),
      );
    }
  }
}

/// Starts a session of llama.cpp's realtime API with [request]'s model.
/// Returns at once. The model loads in the background. Events sent before
/// `session.created` wait for it.
FllamaRealtimeSession fllamaRealtimeOpen(FllamaRealtimeRequest request) {
  _checkModelPath(request.modelPath);
  return _WebRealtimeSession(request);
}

class _WebRealtimeSession implements FllamaRealtimeSession {
  _WebRealtimeSession(FllamaRealtimeRequest request) {
    unawaited(_start(request));
  }

  final _events = StreamController<Map<String, dynamic>>();
  final _pending = <String>[];
  _JSRealtimeSession? _session;
  bool _closing = false;
  bool _ended = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<void> _start(FllamaRealtimeRequest request) async {
    try {
      await loadFllamaWebRuntime();
      if (_closing) return;
      final session = _realtimeOpenJs(
        _JSFllamaModelRequest(
          modelPath: request.modelPath,
          modelMmprojPath: request.mmprojPath,
          contextSize: request.contextSize,
          numGpuLayers: request.numGpuLayers,
          numThreads: request.numThreads,
        ),
        request.query,
        _onEvent.toJS,
        request.logger?.toJS,
      );
      _session = session;
      for (final json in _pending) {
        session.send(json);
      }
      _pending.clear();
    } catch (error) {
      if (_ended) return;
      _events.add({
        'type': 'error',
        'error': _realtimeError('model_load', error.toString()),
      });
      _closed('error');
    }
  }

  @override
  bool send(Map<String, dynamic> event) {
    if (_closing || _ended) return false;
    final json = jsonEncode(event);
    final session = _session;
    if (session != null) return session.send(json);
    _pending.add(json);
    return true;
  }

  @override
  void close() {
    if (_closing || _ended) return;
    _closing = true;
    final session = _session;
    if (session != null) {
      session.close();
    } else {
      _closed('client');
    }
  }

  void _onEvent(String text) {
    if (_ended) return;
    final event =
        _decodeObject(text) ??
        {
          'type': 'error',
          'error': _realtimeError(
            'server_error',
            'fllama: an event is not a JSON object: $text',
          ),
        };
    _events.add(event);
    if (event['type'] == FllamaRealtimeSession.closedEventType) {
      _finish();
    }
  }

  void _closed(String reason) {
    _events.add({
      'type': FllamaRealtimeSession.closedEventType,
      'reason': reason,
    });
    _finish();
  }

  void _finish() {
    _ended = true;
    _session = null;
    _pending.clear();
    unawaited(_events.close());
  }
}

Map<String, dynamic> _realtimeError(String type, String message) => {
  'type': type,
  'code': null,
  'message': message,
  'param': null,
};

Map<String, dynamic>? _decodeObject(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

void _checkModelPath(String modelPath) {
  if (modelPath.isEmpty) {
    throw ArgumentError.value(modelPath, 'modelPath', 'is empty');
  }
}
