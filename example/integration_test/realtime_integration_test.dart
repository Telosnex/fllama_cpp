// ignore_for_file: avoid_print

// The realtime API (fllamaRealtimeOpen) with LFM3-Audio-2B.
//
// Opt-in: the model is not in the CI cache. Put these files in one directory
// and pass it with --dart-define=FLLAMA_REALTIME_DIR=<dir>:
//
// - LFM3-Audio-2B-Q4_K_M.gguf and mmproj-LFM3-Audio-2B-Q8_0.gguf, from
//   https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF
// - set_volume.wav: "Please set the speaker volume to thirty.", 16 kHz mono
//   PCM16. On macOS:
//   say -o v.aiff "Please set the speaker volume to thirty." &&
//   afconvert -f WAVE -d LEI16@16000 -c 1 v.aiff set_volume.wav
//
// cd example && flutter test -d macos integration_test/realtime_integration_test.dart \
//   --dart-define=FLLAMA_REALTIME_DIR=$PWD/.model_cache/lfm3
//
// Live transcription with Voxtral Realtime is also opt-in. Pass a directory
// with --dart-define=FLLAMA_VOXTRAL_DIR=<dir> that has:
//
// - Voxtral-Mini-4B-Realtime-2602-Q4_K_M.gguf and
//   mmproj-Voxtral-Mini-4B-Realtime-2602-Q8_0.gguf, from
//   https://huggingface.co/ggml-org/Voxtral-Mini-4B-Realtime-2602-GGUF
// - water_plants.wav: "Remind me to water the plants tomorrow morning.",
//   16 kHz mono PCM16. On macOS:
//   say -o w.aiff "Remind me to water the plants tomorrow morning." &&
//   afconvert -f WAVE -d LEI16@16000 -c 1 w.aiff water_plants.wav

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fllama_cpp/fllama_cpp.dart' as fllama;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'test/initialize.dart';

const _dir = String.fromEnvironment('FLLAMA_REALTIME_DIR');
const _voxtralDir = String.fromEnvironment('FLLAMA_VOXTRAL_DIR');
const _closed = fllama.FllamaRealtimeSession.closedEventType;

void main() {
  // This suite reads models and media from local file paths.
  if (kIsWeb) return;

  _voxtralTests();

  group('realtime API', () {
    late String model;
    late String mmproj;
    late Uint8List speech;
    var hasFiles = false;

    setUpAll(() async {
      prepareTestBindings();
      await preparePathProviderAsync();
      if (_dir.isEmpty) {
        print('[realtime test] skipping: FLLAMA_REALTIME_DIR is not set');
        return;
      }
      final files = [
        File('$_dir/LFM3-Audio-2B-Q4_K_M.gguf'),
        File('$_dir/mmproj-LFM3-Audio-2B-Q8_0.gguf'),
        File('$_dir/set_volume.wav'),
      ];
      for (final f in files) {
        if (!await f.exists()) {
          print('[realtime test] skipping: ${f.path} is missing');
          return;
        }
      }
      model = (await _stageForSandbox(files[0])).path;
      mmproj = (await _stageForSandbox(files[1])).path;
      speech = _wavPcm(await (await _stageForSandbox(files[2])).readAsBytes());
      hasFiles = true;
    });

    fllama.FllamaRealtimeRequest request({int contextSize = 8192}) =>
        fllama.FllamaRealtimeRequest(
          modelPath: model,
          mmprojPath: mmproj,
          contextSize: contextSize,
        );

    test('a spoken request calls a tool, then the answer is spoken', () async {
      if (!hasFiles) return;
      final session = fllama.fllamaRealtimeOpen(request());
      final events = _Events(session);

      final created = await events.next('session.created');
      final audio = created['session']['audio'] as Map<String, dynamic>;
      expect(audio['input']['format']['rate'], 16000);
      expect(audio['output'], isNotNull);

      session.send({
        'type': 'session.update',
        'session': {
          'type': 'realtime',
          'instructions': 'You are a voice assistant. Keep answers short.\n'
              'Respond with function calls, and interleaved text and audio.',
          'output_modalities': ['text', 'audio'],
          'tools': [
            {
              'type': 'function',
              'name': 'set_volume',
              'description': 'Set the device speaker volume.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'volume': {
                    'type': 'integer',
                    'description': 'Volume from 0 to 100.',
                  },
                },
                'required': ['volume'],
              },
            },
          ],
        },
      });
      await events.next('session.updated');
      _append(session, speech);
      session.send({'type': 'input_audio_buffer.commit'});
      session.send({'type': 'response.create'});

      final call = await events.next('response.function_call_arguments.done');
      expect(call['name'], 'set_volume');
      expect(jsonDecode(call['arguments'] as String), {'volume': 30});
      await events.next('response.done');

      session.send({
        'type': 'conversation.item.create',
        'item': {
          'type': 'function_call_output',
          'call_id': call['call_id'],
          'output': '{"ok": true}',
        },
      });
      session.send({'type': 'response.create'});
      final answer = await events.until('response.done');
      final audioBytes = answer
          .where((e) => e['type'] == 'response.output_audio.delta')
          .map((e) => base64Decode(e['delta'] as String).length)
          .fold<int>(0, (a, b) => a + b);
      final text = answer
          .where((e) => e['type'] == 'response.output_text.delta')
          .map((e) => e['delta'])
          .join();
      print('[realtime test] answer: $text, ${audioBytes / 48000} s of audio');
      expect(audioBytes, greaterThan(24000)); // > 0.5 s at 24 kHz
      expect(text, contains('30'));

      session.close();
      final closed = await events.next(_closed);
      expect(closed['reason'], 'client');
      expect(await events.done, isTrue);
      expect(session.send({'type': 'response.create'}), isFalse);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('response.cancel ends the response', () async {
      if (!hasFiles) return;
      final session = fllama.fllamaRealtimeOpen(request());
      final events = _Events(session);
      await events.next('session.created');
      _append(session, speech);
      session.send({'type': 'input_audio_buffer.commit'});
      session.send({
        'type': 'response.create',
        'response': {
          'output_modalities': ['text', 'audio'],
        },
      });
      await events.next('response.output_audio.delta');
      session.send({'type': 'response.cancel'});
      final done = await events.next('response.done');
      expect(done['response']['status'], 'cancelled');
      session.close();
      expect((await events.next(_closed))['reason'], 'client');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('close() during the load ends with one closed event', () async {
      if (!hasFiles) return;
      // Another context size: the model loads again.
      final session = fllama.fllamaRealtimeOpen(request(contextSize: 4096));
      final events = _Events(session);
      session.close();
      final all = await events.all();
      expect(all.last['type'], _closed);
      expect(all.last['reason'], 'client');
      expect(all.where((e) => e['type'] == _closed), hasLength(1));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a full context ends the session with an error', () async {
      if (!hasFiles) return;
      final session = fllama.fllamaRealtimeOpen(request(contextSize: 512));
      final events = _Events(session);
      await events.next('session.created');
      // About 12.5 positions per second of audio: 60 s does not fit.
      for (var i = 0; i < 20; i++) {
        _append(session, speech);
      }
      final all = await events.all();
      final error = all.firstWhere((e) => e['type'] == 'error');
      expect(
        error['error']['message'],
        contains('does not fit in the context'),
      );
      expect(all.last['reason'], 'server');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a model that does not load gives model_load', () async {
      if (!hasFiles) return;
      final session = fllama.fllamaRealtimeOpen(
        fllama.FllamaRealtimeRequest(
          modelPath: '$model.missing',
          mmprojPath: mmproj,
        ),
      );
      final all = await _Events(session).all();
      expect(all.map((e) => e['type']), ['error', _closed]);
      expect(all.first['error']['type'], 'model_load');
      expect(all.last['reason'], 'error');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

void _voxtralTests() {
  group('realtime API, Voxtral live transcription', () {
    late String model;
    late String mmproj;
    late Uint8List speech;
    var hasFiles = false;

    setUpAll(() async {
      prepareTestBindings();
      await preparePathProviderAsync();
      if (_voxtralDir.isEmpty) {
        print('[realtime test] skipping: FLLAMA_VOXTRAL_DIR is not set');
        return;
      }
      final files = [
        File('$_voxtralDir/Voxtral-Mini-4B-Realtime-2602-Q4_K_M.gguf'),
        File('$_voxtralDir/mmproj-Voxtral-Mini-4B-Realtime-2602-Q8_0.gguf'),
        File('$_voxtralDir/water_plants.wav'),
      ];
      for (final f in files) {
        if (!await f.exists()) {
          print('[realtime test] skipping: ${f.path} is missing');
          return;
        }
      }
      model = (await _stageForSandbox(files[0])).path;
      mmproj = (await _stageForSandbox(files[1])).path;
      speech = _wavPcm(await (await _stageForSandbox(files[2])).readAsBytes());
      hasFiles = true;
    });

    test('speech is transcribed in full', () async {
      if (!hasFiles) return;
      final session = fllama.fllamaRealtimeOpen(
        fllama.FllamaRealtimeRequest(
          modelPath: model,
          mmprojPath: mmproj,
          contextSize: 8192,
        ),
      );
      final events = _Events(session);
      final created = await events.next('session.created');
      expect(created['session']['type'], 'transcription');

      _append(session, speech);
      // Silence after the speech: the model transcribes with a delay.
      _append(session, Uint8List(32000));
      session.send({'type': 'input_audio_buffer.commit'});
      final completed = await events.next(
        'conversation.item.input_audio_transcription.completed',
      );
      final text = (completed['transcript'] as String).toLowerCase();
      print('[realtime test] transcript: $text');
      // A request without a token limit stopped after the first token.
      expect(text, contains('water the plants'));

      session.close();
      expect((await events.next(_closed))['reason'], 'client');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

/// The events of a session, read in order.
class _Events {
  _Events(fllama.FllamaRealtimeSession session) {
    _sub = session.events.listen(
      (e) {
        _buffer.add(e);
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Map<String, dynamic>> _sub;
  final _buffer = <Map<String, dynamic>>[];
  var _done = false;
  Completer<void>? _waiter;

  void _wake() {
    _waiter?.complete();
    _waiter = null;
  }

  Future<Map<String, dynamic>?> _take() async {
    while (_buffer.isEmpty) {
      if (_done) return null;
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    return _buffer.removeAt(0);
  }

  /// The next event of [type]. Fails on an error or the end of the session.
  Future<Map<String, dynamic>> next(String type) async {
    while (true) {
      final e = await _take();
      if (e == null) fail('The session ended before $type');
      if (e['type'] == type) return e;
      if (e['type'] == 'error' || e['type'] == _closed) {
        fail('Waiting for $type: $e');
      }
    }
  }

  /// The events up to and including the next one of [type].
  Future<List<Map<String, dynamic>>> until(String type) async {
    final out = <Map<String, dynamic>>[];
    while (true) {
      final e = await _take();
      if (e == null) fail('The session ended before $type');
      out.add(e);
      if (e['type'] == type) return out;
      if (e['type'] == 'error') fail('Waiting for $type: $e');
    }
  }

  /// Every event up to the end of the stream.
  Future<List<Map<String, dynamic>>> all() async {
    final out = <Map<String, dynamic>>[];
    for (var e = await _take(); e != null; e = await _take()) {
      out.add(e);
    }
    await _sub.cancel();
    return out;
  }

  /// True when the stream ends with no more events.
  Future<bool> get done async => await _take() == null;
}

/// Appends PCM16 in 100 ms chunks, as a microphone would.
void _append(fllama.FllamaRealtimeSession session, Uint8List pcm) {
  const chunk = 3200;
  for (var i = 0; i < pcm.length; i += chunk) {
    final end = i + chunk < pcm.length ? i + chunk : pcm.length;
    session.send({
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(Uint8List.sublistView(pcm, i, end)),
    });
  }
}

/// The samples of the "data" chunk of a PCM WAV file.
Uint8List _wavPcm(Uint8List wav) {
  final data = ByteData.sublistView(wav);
  var p = 12;
  while (p + 8 <= wav.length) {
    final id = ascii.decode(wav.sublist(p, p + 4));
    final size = data.getUint32(p + 4, Endian.little);
    if (id == 'data') return Uint8List.sublistView(wav, p + 8, p + 8 + size);
    p += 8 + size + (size & 1);
  }
  throw const FormatException('No data chunk');
}

Future<File> _stageForSandbox(File source) async {
  final documents = await getApplicationDocumentsDirectory();
  final dir = Directory('${documents.path}/fllama_realtime_test_files');
  await dir.create(recursive: true);
  final staged = File('${dir.path}/${source.uri.pathSegments.last}');
  if (await staged.exists() && await staged.length() == await source.length()) {
    return staged;
  }
  if (await staged.exists()) await staged.delete();
  final ln = await Process.run('ln', [source.path, staged.path]);
  if (ln.exitCode == 0 && await staged.exists()) return staged;
  return source.copy(staged.path);
}
