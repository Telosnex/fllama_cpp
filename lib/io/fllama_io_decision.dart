import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:fllama_cpp/fllama_io.dart';
import 'package:fllama_cpp/fllama_universal.dart';
import 'package:fllama_cpp/io/fllama_bindings_generated.dart';

typedef _NativeDecisionDone =
    Void Function(
      Int requestId,
      Pointer<Char> responseJson,
      Pointer<Char> errorJson,
    );
typedef _NativeLog = Void Function(Pointer<Char> message);

/// Answers the questions of [body] about its state with [request]'s decision
/// model. See [FllamaDecision].
///
/// [body] is the JSON body of llama-server's `POST /v1/systemone`: `state`,
/// `questions`, and optionally `files` (data URLs of images, or of audio for
/// a model that hears). For example:
///
/// ```dart
/// final decision = fllamaDecide(request, {
///   'state': 'I was charged twice for my order.',
///   'questions': {
///     'team': {
///       'type': 'choice',
///       'instructions': 'Which team should handle this?',
///       'criteria': {'billing': null, 'shipping': null},
///     },
///   },
/// });
/// final answers = (await decision.response)['answers'];
/// ```
///
/// Returns at once. The model loads in the background.
FllamaDecision fllamaDecide(
  FllamaDecisionRequest request,
  Map<String, dynamic> body,
) {
  if (request.modelPath.isEmpty) {
    throw ArgumentError.value(request.modelPath, 'modelPath', 'is empty');
  }
  return _NativeDecision(request, jsonEncode(body));
}

class _NativeDecision implements FllamaDecision {
  _NativeDecision(FllamaDecisionRequest request, String body) {
    final logger = request.logger;
    if (logger != null) {
      _logger = NativeCallable<_NativeLog>.listener((Pointer<Char> message) {
        final line = _takeNativeString(message);
        if (line.trim().isNotEmpty) logger(line);
      });
    }
    _onDone = NativeCallable<_NativeDecisionDone>.listener(_handleDone);
    _requestId = fllamaBindings.fllama_new_request_id();

    final native = calloc<fllama_inference_request>();
    final strings = <Pointer<Utf8>>[];
    Pointer<Char> string(String value) {
      final pointer = value.toNativeUtf8();
      strings.add(pointer);
      return pointer.cast<Char>();
    }

    var started = 0;
    try {
      final r = native.ref;
      r.request_id = _requestId;
      r.context_size = request.contextSize;
      r.model_path = string(request.modelPath);
      final mmproj = request.mmprojPath;
      if (mmproj != null && mmproj.isNotEmpty) {
        r.model_mmproj_path = string(mmproj);
      }
      r.num_gpu_layers = request.numGpuLayers;
      r.num_threads = request.numThreads;
      r.temperature = double.nan;
      r.top_p = double.nan;
      r.penalty_freq = double.nan;
      r.penalty_repeat = double.nan;
      r.draft_p_min = -1;
      final gpu = request.gpuDeviceKey;
      if (gpu != null && gpu.isNotEmpty) r.gpu_device_key = string(gpu);
      if (_logger != null) r.dart_logger = _logger!.nativeFunction;
      // Native copies the strings before it returns.
      started = fllamaBindings.fllama_decision(
        r,
        string(body),
        _onDone.nativeFunction,
      );
    } finally {
      for (final pointer in strings) {
        calloc.free(pointer);
      }
      calloc.free(native);
    }
    if (started != 1) {
      _release();
      throw StateError('fllama_decision failed');
    }
  }

  late final NativeCallable<_NativeDecisionDone> _onDone;
  NativeCallable<_NativeLog>? _logger;
  late final int _requestId;
  final _response = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> get response => _response.future;

  @override
  void cancel() {
    if (_response.isCompleted) return;
    fllamaBindings.fllama_inference_cancel(_requestId);
  }

  void _handleDone(
    int requestId,
    Pointer<Char> responseJson,
    Pointer<Char> errorJson,
  ) {
    // Native makes no call for the request after this one (fllama.h).
    final error = errorJson == nullptr ? null : _takeNativeString(errorJson);
    final text = _takeNativeString(responseJson);
    _release();
    if (error != null) {
      _response.completeError(FllamaError.fromJson(error));
      return;
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        _response.complete(decoded);
        return;
      }
    } on FormatException {
      // Reported below.
    }
    _response.completeError(
      FllamaError(
        FllamaErrorType.other,
        'fllama: the response is not a JSON object: $text',
      ),
    );
  }

  void _release() {
    _onDone.close();
    _logger?.close();
    _logger = null;
  }
}

/// Decodes a string that native code allocated for Dart, then frees it.
/// Invalid UTF-8 becomes U+FFFD.
String _takeNativeString(Pointer<Char> pointer) {
  if (pointer == nullptr) return '';
  try {
    final bytes = pointer.cast<Uint8>();
    var length = 0;
    while (bytes[length] != 0) {
      length++;
    }
    return utf8.decode(bytes.asTypedList(length), allowMalformed: true);
  } finally {
    malloc.free(pointer);
  }
}
