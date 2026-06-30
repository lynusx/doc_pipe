import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli/ansi.dart';
import '../cli/console.dart';

// 管道步骤定义（严格顺序，禁止修改、禁止重排）
final kSteps = <({int index, String script})>[
  (index: 1, script: 'dart_doc_inserter.dart'),
  (index: 2, script: 'strip_private.dart'),
  (index: 3, script: 'merge_comments.dart'),
  (index: 4, script: 'extract_doc_comments.dart'),
  (index: 5, script: 'remove_doc_comments.dart'),
  (index: 6, script: 'rename_to_md.dart'),
];

/// 运行完整管道，返回退出码。
Future<int> runPipeline({
  required String inputPath,
  required String? outputPath,
  required bool isDryRun,
  required bool isResume,
  required bool isVerbose,
  required String scriptDir,
}) async {
  // 预检：所有子命令脚本必须存在
  for (final step in kSteps) {
    final scriptPath = p.join(scriptDir, step.script);
    if (!File(scriptPath).existsSync()) {
      Console.error('子命令脚本缺失，请检查路径: $scriptPath');
      return 1;
    }
  }

  final stateFile = resolveStateFile(inputPath);
  final passthroughArgs = buildPassthrough(
    inputPath: inputPath,
    outputPath: outputPath,
    isDryRun: isDryRun,
  );

  // 续跑 vs 全新运行
  int skipUpTo = 0;
  late Map<String, dynamic> state;

  if (isResume) {
    final loaded = tryLoadState(stateFile, inputPath);
    if (loaded != null) {
      state = loaded;
      skipUpTo = (state['lastSuccessfulStep'] as num).toInt();
      if (skipUpTo >= kSteps.length) {
        Console.info(
          '${Ansi.bold}${Ansi.green}[提示]${Ansi.reset} 管道已全部完成，无需恢复。',
        );
        Console.info('       状态文件: $stateFile');
        return 0;
      }
      Console.info(
        '${Ansi.bold}${Ansi.cyan}[续跑]${Ansi.reset} '
        '跳过前 $skipUpTo 步，从 Step ${skipUpTo + 1} 继续。\n',
      );
    } else {
      Console.info('${Ansi.yellow}[提示]${Ansi.reset} 未找到有效状态文件，从头执行。\n');
      state = newState(inputPath, outputPath);
      writeState(stateFile, state);
    }
  } else {
    state = newState(inputPath, outputPath);
    writeState(stateFile, state);
  }

  printHeader(inputPath, outputPath, isDryRun, stateFile);

  int lastSuccessful = skipUpTo;
  final total = kSteps.length;

  for (final step in kSteps) {
    if (step.index <= skipUpTo) continue;

    final scriptPath = p.join(scriptDir, step.script);
    final displayCmd = 'dart run ${step.script}';

    Console.info(
      '${Ansi.bold}[Step ${step.index}/$total]${Ansi.reset} 正在执行: '
      '$displayCmd ${passthroughArgs.join(' ')}',
    );

    final t0 = DateTime.now();

    late final ProcessResult result;
    try {
      result = await Process.run(
        'dart',
        ['run', scriptPath, ...passthroughArgs],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (e) {
      Console.error(
        '${Ansi.red}✗ 无法启动子进程 "$displayCmd": ${e.message}${Ansi.reset}',
      );
      return 2;
    }

    final durationMs = DateTime.now().difference(t0).inMilliseconds;
    final durationStr = (durationMs / 1000).toStringAsFixed(1);
    final exitCode = result.exitCode;

    final stdoutStr = (result.stdout as String).trim();
    if (stdoutStr.isNotEmpty) {
      for (final line in stdoutStr.split('\n')) {
        Console.info('  │ $line');
      }
    }

    (state['steps'] as List<dynamic>).add(<String, dynamic>{
      'step': step.index,
      'command': displayCmd,
      'args': List<String>.from(passthroughArgs),
      'exitCode': exitCode,
      'durationMs': durationMs,
      'completedAt': _nowIso8601(),
    });

    if (exitCode == 0) {
      lastSuccessful = step.index;
      state['lastSuccessfulStep'] = lastSuccessful;
      writeState(stateFile, state);
      Console.info(
        '${Ansi.green}✓ 完成${Ansi.reset} (耗时 ${durationStr}s, 退出码 $exitCode)',
      );
      Console.info('');
    } else {
      writeState(stateFile, state);
      Console.error(
        '${Ansi.red}✗ [Step ${step.index}/$total] 失败${Ansi.reset} '
        '(退出码 $exitCode, 耗时 ${durationStr}s)',
      );

      final stderrStr = (result.stderr as String).trim();
      if (stderrStr.isNotEmpty) {
        Console.error('错误输出:');
        final lines = stderrStr.split('\n');
        final shown = isVerbose ? lines : lines.take(20).toList();
        for (final line in shown) {
          Console.error('  $line');
        }
        if (!isVerbose && lines.length > 20) {
          Console.error(
            '  ${Ansi.yellow}... 共 ${lines.length} 行。'
            '使用 --verbose 查看完整输出${Ansi.reset}',
          );
        }
      }

      Console.error('');
      Console.error(
        '${Ansi.red}管道在 Step ${step.index} 处中断。'
        '已保留 Step 1–$lastSuccessful 的中间产物。${Ansi.reset}',
      );
      if (lastSuccessful + 1 <= total) {
        Console.error(
          '${Ansi.yellow}提示: 修正问题后，使用 --resume 从 '
          'Step ${lastSuccessful + 1} 重试。${Ansi.reset}',
        );
      }

      return exitCode;
    }
  }

  final finalPath = outputPath ?? inputPath;
  Console.info(
    '${Ansi.bold}${Ansi.green}[完成]${Ansi.reset} 管道执行完毕，产物位于: $finalPath',
  );
  return 0;
}

// ── 状态文件辅助 ──────────────────────────────────────────────────────────────

String resolveStateFile(String inputPath) {
  final type = FileSystemEntity.typeSync(inputPath);
  final dir = type == FileSystemEntityType.directory
      ? inputPath
      : p.dirname(inputPath);
  return p.join(dir, '.doc_pipeline_state.json');
}

Map<String, dynamic> newState(String inputPath, String? outputPath) => {
  'inputPath': inputPath,
  'outputPath': outputPath ?? inputPath,
  'startedAt': _nowIso8601(),
  'lastSuccessfulStep': 0,
  'steps': <dynamic>[],
};

void writeState(String filePath, Map<String, dynamic> state) {
  try {
    final json = const JsonEncoder.withIndent('  ').convert(state);
    final tmpFile = File('$filePath.tmp');
    tmpFile.writeAsStringSync(json, flush: true);
    try {
      tmpFile.renameSync(filePath);
    } catch (_) {
      File(filePath).writeAsStringSync(json, flush: true);
      try {
        tmpFile.deleteSync();
      } catch (_) {}
    }
  } catch (e) {
    Console.warn('${Ansi.yellow}[警告] 无法写入状态文件 $filePath: $e${Ansi.reset}');
  }
}

Map<String, dynamic>? tryLoadState(String filePath, String inputPath) {
  final file = File(filePath);
  if (!file.existsSync()) return null;
  try {
    final state = (jsonDecode(file.readAsStringSync()) as Map)
        .cast<String, dynamic>();
    final savedInput = state['inputPath'] as String?;
    if (savedInput != null && savedInput != inputPath) {
      Console.warn(
        '${Ansi.yellow}[警告] 状态文件中的 inputPath ("$savedInput") '
        '与当前输入 ("$inputPath") 不符，续跑结果可能异常。${Ansi.reset}',
      );
    }
    return state;
  } catch (e) {
    Console.warn(
      '${Ansi.yellow}[警告] 无法解析状态文件 $filePath ($e)，将从头执行。${Ansi.reset}',
    );
    return null;
  }
}

List<String> buildPassthrough({
  required String inputPath,
  required String? outputPath,
  required bool isDryRun,
}) => [
  inputPath,
  if (outputPath != null) ...['-o', outputPath],
  if (isDryRun) '--dry-run',
];

void printHeader(
  String inputPath,
  String? outputPath,
  bool isDryRun,
  String stateFile,
) {
  Console.info(
    '${Ansi.bold}${Ansi.cyan}╔══════════════════════════════════════════════╗${Ansi.reset}',
  );
  Console.info(
    '${Ansi.bold}${Ansi.cyan}║     文档注释处理管道  (6 个步骤)             ║${Ansi.reset}',
  );
  Console.info(
    '${Ansi.bold}${Ansi.cyan}╚══════════════════════════════════════════════╝${Ansi.reset}',
  );
  Console.info('  输入路径 : $inputPath');
  Console.info('  输出路径 : ${outputPath ?? "（省略 → 覆写原文件）"}');
  if (isDryRun) {
    Console.info('  ${Ansi.yellow}预览模式 : 已启用（不执行任何磁盘写入）${Ansi.reset}');
  }
  Console.info('  状态文件 : $stateFile');
  Console.info('');
}

String _nowIso8601() {
  final utc = DateTime.now().toUtc();
  return DateTime.fromMillisecondsSinceEpoch(
    utc.millisecondsSinceEpoch,
    isUtc: true,
  ).toIso8601String();
}
