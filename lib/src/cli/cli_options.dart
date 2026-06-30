import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'console.dart';
import 'destination.dart';

/// 构建所有叶子工具共用的 ArgParser（-o / -n / -h）。
ArgParser buildCommonParser() => ArgParser()
  ..addOption(
    'output',
    abbr: 'o',
    help:
        '输出路径。单文件时为目标文件；目录时为目标根目录（保留原相对结构）。'
        '省略则覆写原文件。',
    valueHelp: 'path',
  )
  ..addFlag(
    'dry-run',
    abbr: 'n',
    negatable: false,
    help: '预览模式：仅打印将要变更的内容，不执行任何磁盘写入。',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助信息并退出。');

/// 解析后的公共选项。
class CommonOptions {
  final String inputPath;
  final String? outputPath;
  final bool dryRun;
  final bool isInputDirectory;

  const CommonOptions({
    required this.inputPath,
    required this.outputPath,
    required this.dryRun,
    required this.isInputDirectory,
  });
}

/// 解析并校验公共参数，出错则打印错误并 exit(1)。
///
/// [toolName] 用于错误信息，[outputExtension] 用于 --output 兼容性校验。
CommonOptions parseAndValidate(
  List<String> args,
  ArgParser parser, {
  required String toolName,
  String outputExtension = '.dart',
  void Function(ArgParser)? onHelp,
}) {
  late final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    Console.error('错误：${e.message}');
    if (onHelp != null) onHelp(parser);
    exit(1);
  }

  if (results['help'] as bool) {
    if (onHelp != null) onHelp(parser);
    exit(0);
  }

  if (results.rest.isEmpty) {
    Console.error('错误：缺少必填参数 <路径>');
    if (onHelp != null) onHelp(parser);
    exit(1);
  }

  if (results.rest.length > 1) {
    Console.error(
      '错误：只接受一个位置参数 <路径>，实际收到 ${results.rest.length} 个：'
      '${results.rest.map((s) => '"$s"').join(', ')}',
    );
    exit(1);
  }

  final rawInput = results.rest.first;
  final inputPath = p.canonicalize(rawInput);

  final inputType = FileSystemEntity.typeSync(inputPath);
  if (inputType == FileSystemEntityType.notFound) {
    Console.error('错误：路径不存在：$inputPath');
    exit(1);
  }

  final isInputDirectory = inputType == FileSystemEntityType.directory;

  if (!isInputDirectory) {
    if (inputType != FileSystemEntityType.file) {
      Console.error('错误：不支持的路径类型：$inputPath');
      exit(1);
    }
    if (!inputPath.endsWith('.dart')) {
      Console.error('错误：输入文件不是 .dart 文件：$inputPath');
      exit(1);
    }
  }

  final rawOutput = results['output'] as String?;
  final outputPath = rawOutput != null ? p.canonicalize(rawOutput) : null;

  if (outputPath != null) {
    final err = checkOutputCompatibility(
      outputPath: outputPath,
      isInputDirectory: isInputDirectory,
      outputExtension: outputExtension,
    );
    if (err != null) {
      Console.error('错误：$err');
      exit(1);
    }
  }

  return CommonOptions(
    inputPath: inputPath,
    outputPath: outputPath,
    dryRun: results['dry-run'] as bool,
    isInputDirectory: isInputDirectory,
  );
}
