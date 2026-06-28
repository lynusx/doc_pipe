// bin/doc_pipeline.dart
//
// 一键式文档注释处理管道
// 将 5 个子命令脚本按固定顺序串行执行，统一接收输入路径并自动透传参数。
//
// 用法:
//   dart run bin/doc_pipeline.dart <path> [选项]
//
// 所有子命令脚本须与本文件位于同一目录（bin/）下。

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// 管道步骤定义（严格顺序，禁止修改、禁止重排）
// ─────────────────────────────────────────────────────────────────────────────

final _kSteps = <({int index, String script})>[
  (index: 1, script: 'dart_doc_inserter.dart'),
  (index: 2, script: 'strip_private.dart'),
  (index: 3, script: 'merge_comments.dart'),
  (index: 4, script: 'extract_doc_comments.dart'),
  (index: 5, script: 'remove_doc_comments.dart'),
  (index: 6, script: 'rename_to_md.dart'),
];

// ─────────────────────────────────────────────────────────────────────────────
// ANSI 终端着色（stdout 非 TTY 时自动降级为空字符串，支持管道重定向）
// ─────────────────────────────────────────────────────────────────────────────

bool get _isTTY => stdout.hasTerminal;
String _esc(String code) => _isTTY ? '\x1B[${code}m' : '';

String get _reset => _esc('0'); // 重置所有属性
String get _bold => _esc('1'); // 粗体
String get _red => _esc('31'); // 红色（错误）
String get _green => _esc('32'); // 绿色（成功）
String get _yellow => _esc('33'); // 黄色（警告/提示）
String get _cyan => _esc('36'); // 青色（信息头部）

// ─────────────────────────────────────────────────────────────────────────────
// 入口
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main(List<String> arguments) async {
  final parser = _buildParser();

  // ── 参数解析 ───────────────────────────────────────────────────────────────
  late final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    _die('参数解析错误: ${e.message}\n使用 --help 查看用法。');
  }

  if (args['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  // ── 位置参数校验 ───────────────────────────────────────────────────────────
  if (args.rest.isEmpty) {
    _die('缺少必填位置参数 <path>。使用 --help 查看用法。');
  }
  if (args.rest.length > 1) {
    _die(
      '只接受一个位置参数 <path>，实际收到 ${args.rest.length} 个: '
      '${args.rest.map((s) => '"$s"').join(', ')}',
    );
  }

  // ── 路径解析（统一转为绝对路径，避免后续传参歧义） ──────────────────────
  final inputPath = p.canonicalize(args.rest.first);
  final outputPath = args.wasParsed('output')
      ? p.canonicalize(args['output'] as String)
      : null;
  final isDryRun = args['dry-run'] as bool;
  final isResume = args['resume'] as bool;
  final isVerbose = args['verbose'] as bool;

  // ── 输入路径存在性校验 ─────────────────────────────────────────────────────
  if (FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.notFound) {
    _die('输入路径不存在: $inputPath');
  }

  // ── 脚本目录（与 doc_pipeline.dart 同级） ─────────────────────────────────
  final scriptDir = p.dirname(p.canonicalize(Platform.script.toFilePath()));

  // ── 预检：所有子命令脚本必须存在，否则立即报错退出 ────────────────────────
  for (final step in _kSteps) {
    final scriptPath = p.join(scriptDir, step.script);
    if (!File(scriptPath).existsSync()) {
      _die('子命令脚本缺失，请检查路径: $scriptPath');
    }
  }

  // ── 状态文件路径 ───────────────────────────────────────────────────────────
  final stateFile = _resolveStateFile(inputPath);

  // ── 透传参数列表（通过 List 传递，禁止拼接字符串，避免空格注入） ──────────
  final passthroughArgs = _buildPassthrough(
    inputPath: inputPath,
    outputPath: outputPath,
    isDryRun: isDryRun,
  );

  // ── 续跑 vs 全新运行 ───────────────────────────────────────────────────────
  int skipUpTo = 0; // 跳过 step.index <= skipUpTo 的步骤
  late Map<String, dynamic> state;

  if (isResume) {
    final loaded = _tryLoadState(stateFile, inputPath);
    if (loaded != null) {
      state = loaded;
      skipUpTo = (state['lastSuccessfulStep'] as num).toInt();

      if (skipUpTo >= _kSteps.length) {
        print('$_bold$_green[提示]$_reset 管道已全部完成，无需恢复。');
        print('       状态文件: $stateFile');
        exit(0);
      }
      print(
        '$_bold$_cyan[续跑]$_reset '
        '跳过前 $skipUpTo 步，从 Step ${skipUpTo + 1} 继续。\n',
      );
    } else {
      // 状态文件不存在或损坏：降级为全新运行
      print('$_yellow[提示]$_reset 未找到有效状态文件，从头执行。\n');
      state = _newState(inputPath, outputPath);
      _writeState(stateFile, state);
    }
  } else {
    // 非 --resume：清空并重建状态文件
    state = _newState(inputPath, outputPath);
    _writeState(stateFile, state);
  }

  // ── 管道头部 ───────────────────────────────────────────────────────────────
  _printHeader(inputPath, outputPath, isDryRun, stateFile);

  // ─────────────────────────────────────────────────────────────────────────
  // 主循环：严格串行执行，任一步骤失败则立即中断
  // ─────────────────────────────────────────────────────────────────────────

  int lastSuccessful = skipUpTo;
  final total = _kSteps.length;

  for (final step in _kSteps) {
    if (step.index <= skipUpTo) continue; // --resume 跳过已完成步骤

    final scriptPath = p.join(scriptDir, step.script);
    final displayCmd = 'dart run ${step.script}';

    print(
      '$_bold[Step ${step.index}/$total]$_reset 正在执行: '
      '$displayCmd ${passthroughArgs.join(' ')}',
    );

    final t0 = DateTime.now();

    // 通过 arguments 列表启动子进程（禁止字符串拼接）
    late final ProcessResult result;
    try {
      result = await Process.run(
        'dart',
        ['run', scriptPath, ...passthroughArgs],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (e) {
      stderr.writeln('$_red✗ 无法启动子进程 "$displayCmd": ${e.message}$_reset');
      exit(2);
    }

    final durationMs = DateTime.now().difference(t0).inMilliseconds;
    final durationStr = (durationMs / 1000).toStringAsFixed(1);
    final exitCode = result.exitCode;

    // 子命令 stdout 添加缩进前缀，便于区分层级
    final stdoutStr = (result.stdout as String).trim();
    if (stdoutStr.isNotEmpty) {
      for (final line in stdoutStr.split('\n')) {
        print('  │ $line');
      }
    }

    // 记录本步骤到状态
    (state['steps'] as List<dynamic>).add(<String, dynamic>{
      'step': step.index,
      'command': displayCmd,
      'args': List<String>.from(passthroughArgs),
      'exitCode': exitCode,
      'durationMs': durationMs,
      'completedAt': _nowIso8601(),
    });

    if (exitCode == 0) {
      // ── 步骤成功 ────────────────────────────────────────────────────────
      lastSuccessful = step.index;
      state['lastSuccessfulStep'] = lastSuccessful;
      _writeState(stateFile, state);

      print('$_green✓ 完成$_reset (耗时 ${durationStr}s, 退出码 $exitCode)');
      print('');
    } else {
      // ── 步骤失败：更新状态、打印错误、终止管道 ──────────────────────────
      _writeState(stateFile, state);

      stderr.writeln(
        '$_red✗ [Step ${step.index}/$total] 失败$_reset '
        '(退出码 $exitCode, 耗时 ${durationStr}s)',
      );

      final stderrStr = (result.stderr as String).trim();
      if (stderrStr.isNotEmpty) {
        stderr.writeln('错误输出:');
        final lines = stderrStr.split('\n');
        final shown = isVerbose ? lines : lines.take(20).toList();
        for (final line in shown) {
          stderr.writeln('  $line');
        }
        if (!isVerbose && lines.length > 20) {
          stderr.writeln(
            '  $_yellow... 共 ${lines.length} 行。'
            '使用 --verbose 查看完整输出$_reset',
          );
        }
      }

      stderr.writeln('');
      stderr.writeln(
        '$_red管道在 Step ${step.index} 处中断。'
        '已保留 Step 1–$lastSuccessful 的中间产物。$_reset',
      );
      if (lastSuccessful + 1 <= total) {
        stderr.writeln(
          '$_yellow提示: 修正问题后，使用 --resume 从 '
          'Step ${lastSuccessful + 1} 重试。$_reset',
        );
      }

      exit(exitCode);
    }
  }

  // ── 全部步骤成功 ───────────────────────────────────────────────────────────
  final finalPath = outputPath ?? inputPath;
  print('$_bold$_green[完成]$_reset 管道执行完毕，产物位于: $finalPath');
}

// ─────────────────────────────────────────────────────────────────────────────
// 参数解析器
// ─────────────────────────────────────────────────────────────────────────────

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'output',
    abbr: 'o',
    help:
        '指定输出路径。单文件时为目标文件；目录时为目标根目录\n'
        '（保留原相对目录结构）。省略则覆写原文件。',
    valueHelp: 'path',
  )
  ..addFlag(
    'dry-run',
    abbr: 'n',
    negatable: false,
    help: '预览模式：仅打印将要变更的内容，不执行任何磁盘写入。',
  )
  ..addFlag(
    'resume',
    abbr: 'r',
    negatable: false,
    help: '从上次中断处继续，跳过已成功完成的步骤（依赖状态文件）。',
  )
  ..addFlag(
    'verbose',
    abbr: 'v',
    negatable: false,
    help: '输出子命令完整 stderr（失败时默认仅显示前 20 行）。',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: '显示本帮助信息并退出。');

// ─────────────────────────────────────────────────────────────────────────────
// 状态文件辅助
// ─────────────────────────────────────────────────────────────────────────────

/// 状态文件路径规则：
/// - 输入为 **目录** → `<inputPath>/.doc_pipeline_state.json`
/// - 输入为 **文件** → `<parent_dir>/.doc_pipeline_state.json`
String _resolveStateFile(String inputPath) {
  final type = FileSystemEntity.typeSync(inputPath);
  final dir = type == FileSystemEntityType.directory
      ? inputPath
      : p.dirname(inputPath);
  return p.join(dir, '.doc_pipeline_state.json');
}

/// 构建全新状态 Map（非 --resume 时调用）。
Map<String, dynamic> _newState(String inputPath, String? outputPath) => {
  'inputPath': inputPath,
  'outputPath': outputPath ?? inputPath,
  'startedAt': _nowIso8601(),
  'lastSuccessfulStep': 0,
  'steps': <dynamic>[],
};

/// 将状态 Map 序列化为 JSON 并写入文件。
///
/// 先写 `.tmp` 文件再原子重命名，防止进程崩溃时写入损坏的半截文件。
/// Windows 下若目标已存在 rename 会失败，此时退回到直接覆盖写入。
void _writeState(String filePath, Map<String, dynamic> state) {
  try {
    final json = const JsonEncoder.withIndent('  ').convert(state);
    final tmpFile = File('$filePath.tmp');
    tmpFile.writeAsStringSync(json, flush: true);
    try {
      tmpFile.renameSync(filePath);
    } catch (_) {
      // Windows 上 rename 若目标已存在会抛出；退回到直接覆盖
      File(filePath).writeAsStringSync(json, flush: true);
      try {
        tmpFile.deleteSync();
      } catch (_) {}
    }
  } catch (e) {
    stderr.writeln('$_yellow[警告] 无法写入状态文件 $filePath: $e$_reset');
  }
}

/// 尝试加载并解析已有状态文件。
///
/// - 文件不存在或 JSON 无效 → 返回 `null`，调用方负责降级处理。
/// - inputPath 与记录不符 → 打印警告后仍返回状态（用户自担风险）。
Map<String, dynamic>? _tryLoadState(String filePath, String inputPath) {
  final file = File(filePath);
  if (!file.existsSync()) return null;
  try {
    final state = (jsonDecode(file.readAsStringSync()) as Map)
        .cast<String, dynamic>();
    final savedInput = state['inputPath'] as String?;
    if (savedInput != null && savedInput != inputPath) {
      stderr.writeln(
        '$_yellow[警告] 状态文件中的 inputPath ("$savedInput") '
        '与当前输入 ("$inputPath") 不符，续跑结果可能异常。$_reset',
      );
    }
    return state;
  } catch (e) {
    stderr.writeln('$_yellow[警告] 无法解析状态文件 $filePath ($e)，将从头执行。$_reset');
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 参数与路径辅助
// ─────────────────────────────────────────────────────────────────────────────

/// 构建透传给每个子命令的参数列表。
///
/// 参数通过 [Process.run] 的 `arguments` 列表传递，
/// 禁止拼接为单个字符串，避免路径中空格等字符引发注入问题。
///
/// 生成结构: `[<inputPath>, (可选) -o <outputPath>, (可选) --dry-run]`
List<String> _buildPassthrough({
  required String inputPath,
  required String? outputPath,
  required bool isDryRun,
}) => [
  inputPath,
  if (outputPath != null) ...['-o', outputPath],
  if (isDryRun) '--dry-run',
];

// ─────────────────────────────────────────────────────────────────────────────
// 时间工具
// ─────────────────────────────────────────────────────────────────────────────

/// 返回当前 UTC 时间的 ISO 8601 字符串，精确到毫秒。
///
/// Dart 的 [DateTime.toIso8601String] 在某些平台上产生微秒精度
/// (e.g. `2026-06-27T08:00:00.000123Z`)，此处统一截断至毫秒级
/// (e.g. `2026-06-27T08:00:00.000Z`)，与规范示例保持一致。
String _nowIso8601() {
  final utc = DateTime.now().toUtc();
  return DateTime.fromMillisecondsSinceEpoch(
    utc.millisecondsSinceEpoch,
    isUtc: true,
  ).toIso8601String();
}

// ─────────────────────────────────────────────────────────────────────────────
// 输出辅助
// ─────────────────────────────────────────────────────────────────────────────

/// 打印管道启动头部信息。
void _printHeader(
  String inputPath,
  String? outputPath,
  bool isDryRun,
  String stateFile,
) {
  print('$_bold$_cyan╔══════════════════════════════════════════════╗$_reset');
  print('$_bold$_cyan║     文档注释处理管道  (5 个步骤)             ║$_reset');
  print('$_bold$_cyan╚══════════════════════════════════════════════╝$_reset');
  print('  输入路径 : $inputPath');
  print('  输出路径 : ${outputPath ?? "（省略 → 覆写原文件）"}');
  if (isDryRun) {
    print('  $_yellow预览模式 : 已启用（不执行任何磁盘写入）$_reset');
  }
  print('  状态文件 : $stateFile');
  print('');
}

/// 打印用法帮助并返回（调用方负责 exit(0)）。
void _printUsage(ArgParser parser) {
  stdout.write('''
$_bold用法:$_reset
  dart run bin/doc_pipeline.dart <path> [选项]

$_bold描述:$_reset
  将以下 5 个文档处理子命令按固定顺序串行执行，实现"一键式文档注释处理管道"。
  主命令接收的 <path> 与选项均原样透传给每个子命令阶段。

$_bold管道步骤（严格顺序，不可跳过、不可重排）:$_reset
  Step 1  dart_doc_inserter.dart
  Step 2  strip_private.dart
  Step 3  merge_comments.dart
  Step 4  extract_doc_comments.dart
  Step 5  remove_doc_comments.dart

$_bold位置参数:$_reset
  <path>    目标 .dart 文件或目录路径（必填）。
            若为目录，递归处理所有子目录下的 .dart 文件。
            支持绝对路径与相对路径（内部均转换为绝对路径后传递）。

$_bold选项:$_reset
${parser.usage}

$_bold示例:$_reset
  # 处理整个 lib/ 目录，输出到 out/ 目录
  dart run bin/doc_pipeline.dart lib/ -o out/

  # 预览模式（不写磁盘，仅打印变更）
  dart run bin/doc_pipeline.dart lib/ --dry-run

  # 处理单个文件（覆写原文件）
  dart run bin/doc_pipeline.dart src/foo.dart

  # 从上次中断的步骤继续执行
  dart run bin/doc_pipeline.dart lib/ -o out/ --resume

  # 失败时查看子命令完整错误日志
  dart run bin/doc_pipeline.dart src/foo.dart --verbose
''');
}

/// 输出错误信息到 stderr 并以退出码 1 终止程序。
Never _die(String message) {
  stderr.writeln('$_red错误: $message$_reset');
  exit(1);
}
