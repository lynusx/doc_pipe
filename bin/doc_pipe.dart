import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:doc_pipe/src/cli/ansi.dart';
import 'package:doc_pipe/src/cli/console.dart';
import 'package:doc_pipe/src/pipeline/pipeline_runner.dart';

Future<void> main(List<String> arguments) async {
  final parser = _buildParser();

  late final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    Console.error('${Ansi.red}错误: ${e.message}\n使用 --help 查看用法。${Ansi.reset}');
    exit(1);
  }

  if (args['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  if (args.rest.isEmpty) {
    Console.error(
      '${Ansi.red}错误: 缺少必填位置参数 <path>。使用 --help 查看用法。${Ansi.reset}',
    );
    exit(1);
  }

  if (args.rest.length > 1) {
    Console.error(
      '${Ansi.red}错误: 只接受一个位置参数 <path>，实际收到 ${args.rest.length} 个: '
      '${args.rest.map((s) => '"$s"').join(', ')}${Ansi.reset}',
    );
    exit(1);
  }

  final inputPath = p.canonicalize(args.rest.first);
  final outputPath = args.wasParsed('output')
      ? p.canonicalize(args['output'] as String)
      : null;
  final isDryRun = args['dry-run'] as bool;
  final isResume = args['resume'] as bool;
  final isVerbose = args['verbose'] as bool;

  Console.init();

  if (FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.notFound) {
    Console.error('${Ansi.red}错误: 输入路径不存在: $inputPath${Ansi.reset}');
    exit(1);
  }

  final scriptDir = p.dirname(p.canonicalize(Platform.script.toFilePath()));

  final exitCode = await runPipeline(
    inputPath: inputPath,
    outputPath: outputPath,
    isDryRun: isDryRun,
    isResume: isResume,
    isVerbose: isVerbose,
    scriptDir: scriptDir,
  );

  exit(exitCode);
}

// logger Level 无法直接 import 到这里，通过 Console.init 的默认值处理。
// 编排器对 verbose 的支持：verbose=true 时子进程 stderr 全量输出，
// 这一行为已在 pipeline_runner 内部实现（isVerbose 参数控制截断）。

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

void _printUsage(ArgParser parser) {
  Console.info('''
${Ansi.bold}用法:${Ansi.reset}
  dart run bin/doc_pipe.dart <path> [选项]

${Ansi.bold}描述:${Ansi.reset}
  将以下 6 个文档处理子命令按固定顺序串行执行，实现"一键式文档注释处理管道"。
  主命令接收的 <path> 与选项均原样透传给每个子命令阶段。

${Ansi.bold}管道步骤（严格顺序，不可跳过、不可重排）:${Ansi.reset}
  Step 1  dart_doc_inserter.dart
  Step 2  strip_private.dart
  Step 3  merge_comments.dart
  Step 4  extract_doc_comments.dart
  Step 5  remove_doc_comments.dart
  Step 6  rename_to_md.dart

${Ansi.bold}位置参数:${Ansi.reset}
  <path>    目标 .dart 文件或目录路径（必填）。
            若为目录，递归处理所有子目录下的 .dart 文件。
            支持绝对路径与相对路径（内部均转换为绝对路径后传递）。

${Ansi.bold}选项:${Ansi.reset}
${parser.usage}

${Ansi.bold}示例:${Ansi.reset}
  # 处理整个 lib/ 目录，输出到 out/ 目录
  dart run bin/doc_pipe.dart lib/ -o out/

  # 预览模式（不写磁盘，仅打印变更）
  dart run bin/doc_pipe.dart lib/ --dry-run

  # 处理单个文件（覆写原文件）
  dart run bin/doc_pipe.dart src/foo.dart

  # 从上次中断的步骤继续执行
  dart run bin/doc_pipe.dart lib/ -o out/ --resume

  # 失败时查看子命令完整错误日志
  dart run bin/doc_pipe.dart src/foo.dart --verbose
''');
}
