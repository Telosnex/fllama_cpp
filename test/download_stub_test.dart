import 'dart:io';

import 'package:test/test.dart';

/// src/fllama_download_stub.cpp replaces llama.cpp's download functions, so
/// fllama links without cpp-httplib. A stub must have the signature in
/// the upstream headers: a stub with another signature replaces nothing.
void main() {
  test('the download stubs match the upstream headers', () async {
    final result = await Process.run('c++', [
      '-std=c++17',
      '-fsyntax-only',
      '-Isrc/llama.cpp/common',
      '-Isrc/llama.cpp/include',
      '-Isrc/llama.cpp/ggml/include',
      '-Isrc/llama.cpp/vendor',
      'src/fllama_download_stub.cpp',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
