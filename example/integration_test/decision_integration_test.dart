// ignore_for_file: avoid_print

// The decision API (fllamaDecide) with LFM3 D1 Omni.
//
// Opt-in: the model is not in the CI cache. Put these files in one directory
// and pass it with --dart-define=FLLAMA_DECISION_DIR=<dir>:
//
// - d1-Omni-2B-Q8_0.gguf and mmproj-d1-Omni-2B-Q8_0.gguf (lfm3-d1-omni)
// - llama.png: fllama's logo, a llama (../fllama.png)
// - seven_times_eight.wav: "What is seven times eight?", 16 kHz mono PCM16
//
// cd example && flutter test -d macos integration_test/decision_integration_test.dart \
//   --dart-define=FLLAMA_DECISION_DIR=$PWD/.model_cache/d1

import 'dart:convert';
import 'dart:io';

import 'package:fllama_cpp/fllama_cpp.dart' as fllama;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'test/initialize.dart';

const _dir = String.fromEnvironment('FLLAMA_DECISION_DIR');

void main() {
  // This suite reads models and media from local file paths.
  if (kIsWeb) return;

  group('decision API', () {
    late String model;
    late String mmproj;
    late String image;
    late String audio;
    var hasFiles = false;

    setUpAll(() async {
      prepareTestBindings();
      await preparePathProviderAsync();
      if (_dir.isEmpty) {
        print('[decision test] skipping: FLLAMA_DECISION_DIR is not set');
        return;
      }
      final files = [
        File('$_dir/d1-Omni-2B-Q8_0.gguf'),
        File('$_dir/mmproj-d1-Omni-2B-Q8_0.gguf'),
        File('$_dir/llama.png'),
        File('$_dir/seven_times_eight.wav'),
      ];
      for (final f in files) {
        if (!await f.exists()) {
          print('[decision test] skipping: ${f.path} is missing');
          return;
        }
      }
      model = (await _stageForSandbox(files[0])).path;
      mmproj = (await _stageForSandbox(files[1])).path;
      image =
          'data:image/png;base64,${base64Encode(await files[2].readAsBytes())}';
      audio =
          'data:audio/wav;base64,${base64Encode(await files[3].readAsBytes())}';
      hasFiles = true;
    });

    fllama.FllamaDecisionRequest request({bool withMmproj = true}) =>
        fllama.FllamaDecisionRequest(
          modelPath: model,
          mmprojPath: withMmproj ? mmproj : null,
          logger: (line) {
            if (line.startsWith('[fllama]')) print(line);
          },
        );

    test('answers choice, yes/no and score questions about text', () async {
      if (!hasFiles) return;
      final response = await fllama.fllamaDecide(request(), {
        'state': 'Customer message: I was charged twice for my order last week '
            'and nobody has replied.',
        'questions': {
          'route': {
            'type': 'choice',
            'instructions': 'Which team should handle this?',
            'criteria': {'billing': null, 'shipping': null, 'technical': null},
          },
          'angry': {'type': 'noul', 'instructions': 'Is the customer angry?'},
          'urgency': {
            'type': 'score',
            'instructions': 'How urgent is this?',
            'criteria': ['can wait', 'this week', 'today', 'right now'],
          },
        },
      }).response;
      print('[decision test] text: ${jsonEncode(response['answers'])}');
      final answers = response['answers'] as Map<String, dynamic>;
      final route = answers['route'] as Map<String, dynamic>;
      expect(route['choice'], 'billing');
      final probabilities = (route['probabilities'] as Map)
          .values
          .cast<num>()
          .fold<double>(0, (a, b) => a + b);
      expect(probabilities, closeTo(1, 1e-6));
      expect(answers['angry']['noul'], inInclusiveRange(0, 1));
      expect(answers['urgency']['score'], inInclusiveRange(0, 3));
      expect(response['usage']['output_tokens'], 0);
      expect(response['usage']['input_tokens'], greaterThan(0));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('reads an image', () async {
      if (!hasFiles) return;
      final response = await fllama.fllamaDecide(request(), {
        'state': null,
        'images': [image],
        'questions': {
          'kind': {
            'type': 'choice',
            'instructions': 'What is in the image?',
            'criteria': {'llama': null, 'car': null, 'spreadsheet': null},
          },
        },
      }).response;
      print('[decision test] image: ${jsonEncode(response['answers'])}');
      expect(response['answers']['kind']['choice'], 'llama');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('hears audio', () async {
      if (!hasFiles) return;
      final response = await fllama.fllamaDecide(request(), {
        'state': null,
        'files': [audio],
        'questions': {
          'topic': {
            'type': 'choice',
            'instructions': 'What is the speaker asking about?',
            'criteria': {'weather': null, 'math': null, 'music': null},
          },
        },
      }).response;
      print('[decision test] audio: ${jsonEncode(response['answers'])}');
      expect(response['answers']['topic']['choice'], 'math');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('an invalid question fails with invalidRequest', () async {
      if (!hasFiles) return;
      final decision = fllama.fllamaDecide(request(), {
        'state': 'hello',
        'questions': {
          'x': {'type': 'choice', 'instructions': 'Which?'},
        },
      });
      await expectLater(
        decision.response,
        throwsA(
          isA<fllama.FllamaError>().having(
            (e) => e.type,
            'type',
            fllama.FllamaErrorType.invalidRequest,
          ),
        ),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('an image without a projector fails with notSupported', () async {
      if (!hasFiles) return;
      final decision = fllama.fllamaDecide(request(withMmproj: false), {
        'state': null,
        'images': [image],
        'questions': {
          'animal': {'type': 'noul', 'instructions': 'Is there an animal?'},
        },
      });
      await expectLater(
        decision.response,
        throwsA(
          isA<fllama.FllamaError>().having(
            (e) => e.type,
            'type',
            fllama.FllamaErrorType.notSupported,
          ),
        ),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('cancel ends the request', () async {
      if (!hasFiles) return;
      // Another load-time field: the model reloads, so the request is still
      // loading when it is cancelled.
      final decision = fllama.fllamaDecide(
        fllama.FllamaDecisionRequest(
          modelPath: model,
          mmprojPath: mmproj,
          contextSize: 2048,
        ),
        {
          'state': 'hello',
          'questions': {
            'greeting': {'type': 'noul', 'instructions': 'Is it a greeting?'},
          },
        },
      );
      decision.cancel();
      await expectLater(
        decision.response,
        throwsA(
          isA<fllama.FllamaError>().having(
            (e) => e.type,
            'type',
            fllama.FllamaErrorType.cancelled,
          ),
        ),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

Future<File> _stageForSandbox(File source) async {
  final documents = await getApplicationDocumentsDirectory();
  final dir = Directory('${documents.path}/fllama_decision_test_files');
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
