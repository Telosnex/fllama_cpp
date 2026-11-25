import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:fllama_cpp/fllama_io.dart';
import 'package:fllama_cpp/fllama_universal.dart';
import 'package:fllama_cpp/io/fllama_bindings_generated.dart';

typedef _NativeRealtimeEvent =
    Void Function(Int session, Pointer<Char> eventJson);
typedef _NativeLog = Void Function(Pointer<Char> message);

/// Starts a session of llama.cpp's realtime API with [request]'s model. See
/// [FllamaRealtimeSession].
///
/// Returns at once. The model loads in the background; the session starts
/// with `session.created`. Events that are sent before it wait for it.
FllamaRealtimeSession fllamaRealtimeOpen(FllamaRealtimeRequest request) {
  if (request.modelPath.isEmpty) {
    throw ArgumentError.value(request.modelPath, 'modelPath', 'is empty');
  }
  return _NativeRealtimeSession(request);
}

class _NativeRealtimeSession implements FllamaRealtimeSession {
  _NativeRealtimeSession(FllamaRealtimeRequest request) {
    final logger = request.logger;
    if (logger != null) {
      _logger = NativeCallable<_NativeLog>.listener((Pointer<Char> message) {
        final line = _takeNativeString(message);
        if (line.trim().isNotEmpty) logger(line);
      });
    }
    _onEvent = NativeCallable<_NativeRealtimeEvent>.listener(_handleEvent);

    final native = calloc<fllama_inference_request>();
    final strings = <Pointer<Utf8>>[];
    Pointer<Char> string(String value) {
      final pointer = value.toNativeUtf8();
      strings.add(pointer);
      return pointer.cast<Char>();
    }

    try {
      final r = native.ref;
      r.context_size = request.contextSize;
      r.model_path = string(request.modelPath);
      if (request.mmprojPath.isNotEmpty) {
        r.model_mmproj_path = string(request.mmprojPath);
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
      final query = request.query;
      final queryPointer = query == null || query.isEmpty
          ? nullptr
          : string(query);
      // Native copies the strings before it returns.
      _id = fllamaBindings.fllama_realtime_open(
        r,
        queryPointer,
        _onEvent.nativeFunction,
      );
    } finally {
      for (final pointer in strings) {
        calloc.free(pointer);
      }
      calloc.free(native);
    }
    if (_id <= 0) {
      _release();
      throw StateError('fllama_realtime_open failed');
    }
  }

  late final NativeCallable<_NativeRealtimeEvent> _onEvent;
  NativeCallable<_NativeLog>? _logger;
  int _id = 0;
  bool _ended = false;
  final _events = StreamController<Map<String, dynamic>>();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  bool send(Map<String, dynamic> event) {
    if (_ended) return false;
    final json = jsonEncode(event).toNativeUtf8();
    try {
      return fllamaBindings.fllama_realtime_send(_id, json.cast<Char>()) == 1;
    } finally {
      calloc.free(json);
    }
  }

  @override
  void close() {
    if (_ended) return;
    fllamaBindings.fllama_realtime_close(_id);
  }

  void _handleEvent(int session, Pointer<Char> eventJson) {
    final text = _takeNativeString(eventJson);
    Map<String, dynamic> event;
    try {
      final decoded = jsonDecode(text);
      event = decoded is Map<String, dynamic>
          ? decoded
          : {'type': 'error', 'error': _invalidEvent(text)};
    } on FormatException {
      event = {'type': 'error', 'error': _invalidEvent(text)};
    }
    if (_ended) return;
    final last = event['type'] == FllamaRealtimeSession.closedEventType;
    _events.add(event);
    if (last) {
      // Native makes no call for the session after this one (fllama.h).
      _ended = true;
      _release();
      unawaited(_events.close());
    }
  }

  static Map<String, dynamic> _invalidEvent(String text) => {
    'type': 'server_error',
    'code': null,
    'message': 'fllama: an event is not a JSON object: $text',
    'param': null,
  };

  void _release() {
    _onEvent.close();
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
