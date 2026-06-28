// bin/rename_to_md.dart
//
// 职责：将 .dart 文件（或目录下所有 .dart 文件）重命名为 .md 文件。
//       不修改文件内容；不做任何注释删除。
//
// 用法：dart run rename_to_md.dart <路径> [选项]
//
//   <路径>   .dart 文件或包含 .dart 文件的目录（必填）
//
// 选项：
//   -o, --output   输出路径。
//                  单文件时为目标 .md 文件；
//                  目录时为目标根目录（保留原相对结构）。
//                  省略则在原位重命名（原 .dart 文件将不再存在）。
//   -n, --dry-run  预览模式：仅打印将要变更的内容，不执行任何磁盘写入。
//   -h, --help     显示帮助信息。
//
// 示例：
//   # 原位重命名单文件（foo.dart → foo.md）
//   dart run rename_to_md.dart lib/src/foo.dart
//
//   # 目录下所有 .dart 原位重命名为 .md
//   dart run rename_to_md.dart lib/
//
//   # 处理目录，输出到另一目录（保留相对结构）
//   dart run rename_to_md.dart lib/ -o lib_md/
//
//   # 处理单文件，输出到指定路径
//   dart run rename_to_md.dart lib/src/foo.dart -o out/foo.md
//
//   # 预览将重命名的文件（不写磁盘）
//   dart run rename_to_md.dart lib/ --dry-run

import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

// ── 入口 ────────────────────────────────────────────────────────────

void main(List<String> arguments) async {
  final parser = _buildParser();

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('错误：${e.message}');
    _printUsage(parser);
    exit(1);
  }

  if (args['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  if (args.rest.isEmpty) {
    stderr.writeln('错误：缺少必填参数 <路径>');
    _printUsage(parser);
    exit(1);
  }

  final inputPath = args.rest.first;
  final outputPath = args['output'] as String?;
  final isDryRun = args['dry-run'] as bool;

  // ── 验证输入路径 ────────────────────────────────────────────────────
  final inputType = FileSystemEntity.typeSync(inputPath);
  if (inputType == FileSystemEntityType.notFound) {
    stderr.writeln('错误：路径不存在：$inputPath');
    exit(1);
  }

  final bool isInputDirectory = inputType == FileSystemEntityType.directory;

  if (!isInputDirectory) {
    if (inputType != FileSystemEntityType.file) {
      stderr.writeln('错误：不支持的路径类型：$inputPath');
      exit(1);
    }
    if (!inputPath.endsWith('.dart')) {
      stderr.writeln('错误：输入文件不是 .dart 文件：$inputPath');
      exit(1);
    }
  }

  // ── 验证 --output 与输入类型一致性 ─────────────────────────────────
  if (outputPath != null) {
    final mismatchError = _checkOutputCompatibility(
      outputPath: outputPath,
      isInputDirectory: isInputDirectory,
    );
    if (mismatchError != null) {
      stderr.writeln('错误：$mismatchError');
      exit(1);
    }
  }

  // ── 收集待处理文件 ──────────────────────────────────────────────────
  final List<File> dartFiles;
  if (isInputDirectory) {
    dartFiles = _collectDartFiles(Directory(inputPath));
  } else {
    dartFiles = [File(inputPath)];
  }

  if (isDryRun) {
    stdout.writeln('[dry-run] 预览模式（不执行任何磁盘写入）\n');
  }

  // ── 处理 / 预览文件 ─────────────────────────────────────────────────
  int processedCount = 0;
  bool hasError = false;

  for (final sourceFile in dartFiles) {
    // 计算中间目标路径（.dart），再推导最终 .md 路径
    final dartDestPath = _resolveDestination(
      sourcePath: sourceFile.path,
      inputRoot: inputPath,
      isInputDirectory: isInputDirectory,
      outputRoot: outputPath,
    );
    final mdDestPath = p.setExtension(dartDestPath, '.md');

    if (isDryRun) {
      stdout.writeln('  ${sourceFile.path}  →  $mdDestPath');
      processedCount++;
      continue;
    }

    stdout.writeln('处理：${sourceFile.path}  →  $mdDestPath');

    try {
      final mdFile = File(mdDestPath);

      // 确保目标目录存在
      final parent = mdFile.parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }

      if (dartDestPath == sourceFile.path) {
        // 原位重命名：直接 rename，原 .dart 文件随之消失
        if (mdFile.existsSync()) mdFile.deleteSync();
        sourceFile.renameSync(mdDestPath);
      } else {
        // 跨路径：先复制内容，再删除旧的中间文件（若存在），最后 rename 临时文件
        // 这里直接读取源内容写入目标 .md，避免多余的中间文件
        final content = sourceFile.readAsStringSync();
        if (mdFile.existsSync()) mdFile.deleteSync();
        mdFile.writeAsStringSync(content);
      }

      processedCount++;
    } on FileSystemException catch (e) {
      stderr.writeln(
        '错误：无法写入/重命名：$mdDestPath（${e.osError?.message ?? e.message}）',
      );
      hasError = true;
    } catch (e) {
      stderr.writeln('错误：处理失败：${sourceFile.path}（$e）');
      hasError = true;
    }
  }

  // ── 汇总输出 ────────────────────────────────────────────────────────
  if (isDryRun) {
    stdout.writeln(
      '\n[dry-run] 共 $processedCount 个文件将被重命名（.dart → .md），未执行任何磁盘写入。',
    );
  } else {
    stdout.writeln('完成：共重命名 $processedCount 个文件（.dart → .md）');
  }

  exit(hasError ? 1 : 0);
}

// ── ArgParser 构建 ──────────────────────────────────────────────────

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'output',
    abbr: 'o',
    help:
        '输出路径。单文件时为目标 .md 文件；目录时为目标根目录（保留原相对结构）。'
        '省略则在原位重命名（原 .dart 文件将不再存在）。',
    valueHelp: 'path',
  )
  ..addFlag(
    'dry-run',
    abbr: 'n',
    negatable: false,
    help: '预览模式：仅打印将要变更的内容，不执行任何磁盘写入。',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助信息');

// ── --output 兼容性校验 ─────────────────────────────────────────────

/// 当 [outputPath] 指向的路径类型与 [isInputDirectory] 矛盾时，
/// 返回可读的错误描述；否则返回 null。
///
/// 仅在 [outputPath] 对应路径**已存在**时才能确定类型冲突；
/// 路径不存在时视为将由工具自行创建，不报错。
String? _checkOutputCompatibility({
  required String outputPath,
  required bool isInputDirectory,
}) {
  final outputType = FileSystemEntity.typeSync(outputPath);

  if (outputType == FileSystemEntityType.directory && !isInputDirectory) {
    return '--output 指向已存在的目录，但输入为单文件：$outputPath\n'
        '       单文件输入时，--output 应指定目标文件路径（如 -o out/foo.md）';
  }

  if (outputType == FileSystemEntityType.file && isInputDirectory) {
    return '--output 指向已存在的文件，但输入为目录：$outputPath\n'
        '       目录输入时，--output 应指定目标根目录路径（如 -o out/）';
  }

  return null; // 类型一致或目标尚不存在
}

// ── 工具函数 ────────────────────────────────────────────────────────

List<File> _collectDartFiles(Directory dir) {
  final result = <File>[];
  try {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        result.add(entity);
      }
    }
  } on FileSystemException catch (e) {
    stderr.writeln('错误：无法读取目录：${dir.path}（${e.osError?.message ?? e.message}）');
    exit(1);
  }
  return result;
}

String _resolveDestination({
  required String sourcePath,
  required String inputRoot,
  required bool isInputDirectory,
  required String? outputRoot,
}) {
  if (outputRoot == null) return sourcePath;
  if (!isInputDirectory) return outputRoot;
  final rel = p.relative(sourcePath, from: inputRoot);
  return p.join(outputRoot, rel);
}

void _printUsage(ArgParser parser) {
  stdout.writeln('用法：dart run rename_to_md.dart <路径> [选项]');
  stdout.writeln();
  stdout.writeln('  <路径>   .dart 文件或包含 .dart 文件的目录（必填）');
  stdout.writeln();
  stdout.writeln('选项：');
  stdout.writeln(parser.usage);
  stdout.writeln();
  stdout.writeln('示例：');
  stdout.writeln('  # 原位重命名单文件（foo.dart → foo.md）');
  stdout.writeln('  dart run rename_to_md.dart lib/src/foo.dart');
  stdout.writeln();
  stdout.writeln('  # 目录下所有 .dart 原位重命名为 .md');
  stdout.writeln('  dart run rename_to_md.dart lib/');
  stdout.writeln();
  stdout.writeln('  # 处理目录，输出到另一目录');
  stdout.writeln('  dart run rename_to_md.dart lib/ -o lib_md/');
  stdout.writeln();
  stdout.writeln('  # 处理单文件，输出到指定路径');
  stdout.writeln('  dart run rename_to_md.dart lib/src/foo.dart -o out/foo.md');
  stdout.writeln();
  stdout.writeln('  # 预览将重命名的文件（不写磁盘）');
  stdout.writeln('  dart run rename_to_md.dart lib/ --dry-run');
}
