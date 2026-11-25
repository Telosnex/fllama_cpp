/// Builds the fllama web runtime: wllama at the commit of
/// web_build/wllama.json, with web_build/wllama.patch and llama.cpp at its
/// pinned commit. It writes wllama/index.js and two packed Wasm files to
/// --out: wllama/wasm/wllama.wasm (main) and wllama/compat/wllama.wasm.
/// Both carry the Emscripten JS glue in a custom section.
///
/// It runs in the emsdk image of wllama.json (kiln ADR 002 D10,
/// D11): the kiln release workflow runs it there, and so does a local build.
/// --toolchain-file gets the Emscripten and Node versions for web.json:
///
///     docker run --rm -v "$PWD:/src" -v /tmp/fllama_web:/out -w /src \
///       <emsdkImage> bash -c 'dart tool/kiln/build_web.dart --out /out'
///
/// The image needs Dart on the PATH. The script uses only dart:io, so it
/// needs no `pub get` (fllama needs Flutter). Then install the files with
///
///     dart run kiln:web install-dev --from /tmp/fllama_web
///
/// These are the steps of wllama's own build (`npm run build:wasm`,
/// `build:worker`, `build:tsup`), with every step checked.
library;

import 'dart:convert';
import 'dart:io';

const _usage =
    'dart tool/kiln/build_web.dart --out <dir> [--work <dir>] '
    '[--toolchain-file <file>]';

const _outputs = {
  'esm/index.js': 'wllama/index.js',
  'src/wasm/wllama.wasm': 'wllama/wasm/wllama.wasm',
  'compat/wasm/wllama.wasm': 'wllama/compat/wllama.wasm',
};

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final root = Directory.fromUri(
    Platform.script.resolve('../..'),
  ).absolute.path;
  final out = Directory(options['out']!).absolute;
  final work = Directory(
    options['work'] ?? '${Directory.systemTemp.path}/fllama_web_build',
  ).absolute;
  final pin =
      jsonDecode(await File('$root/web_build/wllama.json').readAsString())
          as Map<String, dynamic>;
  final llama = pin['llamaCpp'] as Map<String, dynamic>;
  final dawn = pin['dawn'] as Map<String, dynamic>;
  final binaryen = pin['binaryen'] as Map<String, dynamic>;

  final emcc = await _output(['emcc', '--version'], root);
  if (!emcc.split('\n').first.contains(' ${pin['emscripten']} ')) {
    _fail(
      'Emscripten ${pin['emscripten']} required: ${emcc.split('\n').first}',
    );
  }
  final node = (await _output(['node', '--version'], root)).trim();
  if (node != 'v${pin['node']}') _fail('Node ${pin['node']} required: $node');
  if (options['toolchain-file'] case final path?) {
    final version = RegExp(
      r'[0-9][0-9.]* \([0-9a-f]+\)',
    ).firstMatch(emcc.split('\n').first)?[0];
    await File(path).writeAsString(
      'Emscripten ${version ?? pin['emscripten']}, Node ${pin['node']}, '
      'Binaryen ${binaryen['commit']} (compat, patched)\n',
    );
  }

  if (await work.exists()) await work.delete(recursive: true);
  await work.create(recursive: true);
  final wllama = '${work.path}/wllama';

  // wllama at its pinned commit, with the fllama patch.
  await _run(['git', 'init', '-q', wllama], root);
  await _run([
    'git',
    '-C',
    wllama,
    'fetch',
    '-q',
    '--depth',
    '1',
    pin['repository'] as String,
    pin['commit'] as String,
  ], root);
  await _run([
    'git',
    '-C',
    wllama,
    'checkout',
    '-q',
    '--detach',
    'FETCH_HEAD',
  ], root);
  await _run([
    'git',
    '-C',
    wllama,
    'apply',
    '--index',
    '$root/${pin['patch']}',
  ], root);

  // llama.cpp with its history: build:worker names it b<commit count>.
  final llamaDir = '$wllama/llama.cpp';
  if (await Directory(llamaDir).exists()) {
    await Directory(llamaDir).delete(recursive: true);
  }
  await _run([
    'git',
    'clone',
    '-q',
    '--filter=blob:none',
    '--no-checkout',
    llama['repository'] as String,
    llamaDir,
  ], root);
  await _run([
    'git',
    '-C',
    llamaDir,
    'checkout',
    '-q',
    '--detach',
    llama['commit'] as String,
  ], root);
  // fllama's llama.cpp patches (patches/llama.cpp), also in src/llama.cpp
  // for native (test/llama_cpp_pin_test.dart checks that).
  final patches =
      Directory('$root/patches/llama.cpp')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.patch'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final patch in patches) {
    await _run(['git', '-C', llamaDir, 'apply', patch.path], root);
  }
  final gitlink = await _output([
    'git',
    '-C',
    wllama,
    'ls-files',
    '-s',
    'llama.cpp',
  ], root);
  if (!gitlink.contains(llama['commit'] as String)) {
    _fail('wllama does not pin llama.cpp ${llama['commit']}: $gitlink');
  }

  // The Dawn WebGPU package of wllama's build.
  final emdawn = Directory('$wllama/build/emdawn');
  await emdawn.create(recursive: true);
  final zip = File('${emdawn.path}/emdawn.zip');
  await _download(Uri.parse(dawn['url'] as String), zip);
  final hash = await _sha256(zip.path, root);
  if (hash != dawn['sha256']) {
    _fail('Dawn SHA-256 $hash, expected ${dawn['sha256']}');
  }
  await _run([
    'python3',
    '-c',
    'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])',
    zip.path,
    emdawn.path,
  ], root);

  // npm run build:wasm (scripts/docker-compose.yml): the default build, with
  // JSPI and relaxed SIMD, then compat with Asyncify. Both are wasm32 and
  // support sharing model weights across RPC workers when threading is enabled.
  final builds = {
    'build': (flags: ['-DGGML_WEBGPU_JSPI=ON'], wasmDir: 'src/wasm'),
    'build-compat': (
      flags: ['-DWLLAMA_COMPAT=ON', '-DGGML_WEBGPU_JSPI=OFF'],
      wasmDir: 'compat/wasm',
    ),
  };
  for (final MapEntry(key: dir, value: (:flags, :wasmDir)) in builds.entries) {
    final env = dir == 'build-compat'
        ? await _buildCompatBinaryen(binaryen, work.path, wllama)
        : const <String, String>{};
    final build = '$wllama/$dir';
    await Directory(build).create(recursive: true);
    await _run(
      [
        'emcmake',
        'cmake',
        '..',
        '-DEMSCRIPTEN_SYSTEM_PROCESSOR=wasm',
        '-DLLAMA_WASM_MEM64=OFF',
        '-DGGML_RPC=ON',
        '-DGGML_WEBGPU=ON',
        ...flags,
        '-DEMDAWNWEBGPU_DIR=${emdawn.path}/emdawnwebgpu_pkg',
        '-DWLLAMA_TEST_BACKEND=OFF',
      ],
      build,
      environment: env,
    );
    await _run(
      ['emmake', 'make', 'wllama', '-j${Platform.numberOfProcessors}'],
      build,
      environment: env,
    );
    await Directory('$wllama/$wasmDir').create(recursive: true);
    // Embed the worker glue and function names (for stack traces) in Wasm.
    await _run([
      'node',
      'scripts/pack_wasm.js',
      '$dir/wllama.wasm',
      '$wasmDir/wllama.wasm',
    ], wllama);
  }
  await _run(['npm', 'run', 'build:glue'], wllama);

  await _run(['npm', 'ci', '--no-audit', '--no-fund'], wllama);
  await _run(['npm', 'run', 'build:worker'], wllama);
  final generated = await File(
    '$wllama/src/workers-code/generated.ts',
  ).readAsString();
  if (!generated.contains("LIBLLAMA_VERSION = '${llama['version']}'")) {
    _fail('LIBLLAMA_VERSION is not ${llama['version']}');
  }
  // Upstream's check compares hashes only, to allow its shallow clones. Both
  // packed outputs here must contain the full stamp, including the build number.
  for (final file in ['src/wasm/wllama.wasm', 'compat/wasm/wllama.wasm']) {
    final wasm = latin1.decode(await File('$wllama/$file').readAsBytes());
    if (!wasm.contains('"version":"${llama['version']}"')) {
      _fail('$file does not contain the stamp ${llama['version']}');
    }
  }
  await _run(['node', 'scripts/check_wasm_version.js'], wllama);
  await _run(['npx', 'tsc', '--noEmit', '-p', 'tsconfig.build.json'], wllama);
  await _run(['npm', 'run', 'build:tsup'], wllama);

  // --out may have files from a previous (pre-v4) build.
  for (final dir in ['wasm', 'compat']) {
    final stale = File('${out.path}/wllama/$dir/wllama.js');
    if (await stale.exists()) await stale.delete();
  }
  stdout.writeln('Built:');
  for (final MapEntry(key: from, value: to) in _outputs.entries) {
    final target = File('${out.path}/$to');
    await target.parent.create(recursive: true);
    await File('$wllama/$from').copy(target.path);
    stdout.writeln(
      '  ${await _sha256(target.path, root)}  ${await target.length()}  $to',
    );
  }
}

// Compat uses Wasm exception handling with Asyncify. The pinned emsdk's
// wasm-opt does not support try in Asyncify without wllama's Binaryen patch.
// Overlay just that executable, instead of mutating a shared emsdk install.
Future<Map<String, String>> _buildCompatBinaryen(
  Map<String, dynamic> pin,
  String work,
  String wllama,
) async {
  final sdk = (await _output(['em-config', 'BINARYEN_ROOT'], wllama)).trim();
  final expected = pin['commit'] as String;
  final version = await _output(['$sdk/bin/wasm-opt', '--version'], wllama);
  final revision = RegExp(r'-g([0-9a-f]+)\)').firstMatch(version)?[1];
  if (revision == null || !expected.startsWith(revision)) {
    _fail('Binaryen $expected required, found ${version.trim()}');
  }
  final patch = '$wllama/${pin['patch']}';
  if (await _sha256(patch, wllama) != pin['patchSha256']) {
    _fail('Unexpected Binaryen patch checksum: $patch');
  }
  final source = '$work/binaryen';
  await _run(['git', 'init', '-q', source], wllama);
  await _run([
    'git',
    'fetch',
    '--depth',
    '1',
    pin['repository'] as String,
    expected,
  ], source);
  await _run(['git', 'checkout', '-q', '--detach', 'FETCH_HEAD'], source);
  await _run(['git', 'submodule', 'update', '--init', '--depth', '1'], source);
  await _run(['git', 'apply', patch], source);
  await _run([
    'cmake',
    '-S',
    '.',
    '-B',
    'build',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DBUILD_TESTS=OFF',
    '-DBUILD_STATIC_LIB=ON',
    '-DENABLE_WERROR=OFF',
  ], source);
  await _run([
    'cmake',
    '--build',
    'build',
    '--target',
    'wasm-opt',
    '--parallel',
    (Platform.numberOfProcessors > 8 ? 8 : Platform.numberOfProcessors)
        .toString(),
  ], source);
  final overlay = '$work/compat-binaryen';
  final bin = Directory('$overlay/bin');
  await bin.create(recursive: true);
  await for (final entry in Directory('$sdk/bin').list(followLinks: false)) {
    final name = entry.uri.pathSegments.last;
    if (name.isEmpty) continue;
    await Link(
      '${bin.path}/$name',
    ).create(name == 'wasm-opt' ? '$source/build/bin/wasm-opt' : entry.path);
  }
  return {'EM_BINARYEN_ROOT': overlay};
}

Map<String, String> _parse(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final name = switch (args[i]) {
      '--out' => 'out',
      '--work' => 'work',
      '--toolchain-file' => 'toolchain-file',
      _ => _fail('Unknown argument: ${args[i]}\n$_usage'),
    };
    if (i + 1 == args.length) _fail('${args[i]} needs a value.\n$_usage');
    options[name] = args[++i];
  }
  if (options['out'] == null) _fail('Pass --out.\n$_usage');
  return options;
}

Future<void> _download(Uri url, File to) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    if (response.statusCode != 200) {
      _fail('HTTP ${response.statusCode} for $url');
    }
    await response.pipe(to.openWrite());
  } finally {
    client.close();
  }
}

Future<String> _sha256(String path, String cwd) async =>
    (await _output(['sha256sum', path], cwd)).split(' ').first;

Future<String> _output(List<String> command, String cwd) async {
  final result = await Process.run(
    command.first,
    command.skip(1).toList(),
    workingDirectory: cwd,
  );
  if (result.exitCode != 0) {
    _fail('${command.join(' ')} failed: ${result.stderr}');
  }
  return '${result.stdout}';
}

Future<void> _run(
  List<String> command,
  String cwd, {
  Map<String, String>? environment,
}) async {
  stdout.writeln('+ ${command.join(' ')}');
  final process = await Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: cwd,
    mode: ProcessStartMode.inheritStdio,
    environment: environment,
  );
  final code = await process.exitCode;
  if (code != 0) _fail('${command.join(' ')} failed with exit code $code.');
}

Never _fail(String message) {
  stderr.writeln('build_web: $message');
  exit(1);
}
