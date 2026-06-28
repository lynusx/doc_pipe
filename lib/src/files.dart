// lib/src/files.dart
//
// 文件/路径相关的共享工具，外加统一的 ArgParser 与用法渲染。
//
// 收敛了以下在 6 个子命令中重复出现的逻辑：
//   * `_collectDartFiles` / `_collectDart`（递归收集 .dart 文件，各文件略有
//     差异：是否跳过隐藏目录 / build 目录、是否排序、是否 canonicalize）；
//   * `_resolveDestination` / `_destinationPath`（输出路径推导，逻辑完全一致）；
//   * `_checkOutputCompatibility` / `_validateOutputType`（--output 与输入类型
//     的一致性校验）；
//   * 各自手搓的 `ArgParser`（三个选项 -o/-n/-h 完全相同）；
//   * 各自的 `_printUsage`（结构一致）。
//
// 收集规则在此统一为一套：跳过隐藏目录（以 `.` 开头，如 `.git`/`.dart_tool`）
// 与 `build` 目录，结果按字典序排序，且全部 canonicalize 为绝对路径。这样
// 管道中每个步骤面对的文件集合一致，避免「某步处理了某文件、下一步却跳过」
// 的不一致。

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// .dart 文件收集
// ─────────────────────────────────────────────────────────────────────────────

/// 判断路径片段 [segment] 是否应被跳过（隐藏目录或 `build`）。
bool _isSkippedDirSegment(String segment) =>
    (segment.startsWith('.') && segment.length > 1) || segment == 'build';

/// 递归收集 [rootDir] 下的所有 `.dart` 文件，返回 **canonicalize 后的绝对
/// 路径**，按字典序排序。
///
/// 跳过任意一段路径命中 [_isSkippedDirSegment] 的文件（隐藏目录 / build）。
List<String> collectDartFiles(String rootDir) {
  final root = Directory(rootDir);
  final results = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.dart')) continue;

    final rel = p.relative(entity.path, from: rootDir);
    if (p.split(rel).any(_isSkippedDirSegment)) continue;

    results.add(p.canonicalize(entity.path));
  }
  results.sort();
  return results;
}

// ─────────────────────────────────────────────────────────────────────────────
// 输出路径推导
// ─────────────────────────────────────────────────────────────────────────────

/// 计算 [sourcePath] 的目标写入路径。
///
/// - [outputRoot] 为 null → 原地覆写（返回 [sourcePath]）。
/// - 单文件输入（[inputIsDirectory] 为 false）→ [outputRoot] 即目标文件路径。
/// - 目录输入 → 在 [outputRoot] 下按相对 [inputRoot] 的结构镜像写入。
String resolveDestination({
  required String sourcePath,
  required String inputRoot,
  required bool inputIsDirectory,
  required String? outputRoot,
}) {
  if (outputRoot == null) return sourcePath;
  if (!inputIsDirectory) return outputRoot;
  return p.join(outputRoot, p.relative(sourcePath, from: inputRoot));
}

// ─────────────────────────────────────────────────────────────────────────────
// --output 与输入类型一致性校验
// ─────────────────────────────────────────────────────────────────────────────

/// 当 [outputPath] 的类型与输入类型矛盾时返回可读的错误描述，否则返回 null。
///
/// 仅当 [outputPath] 已存在、或形如目录（以路径分隔符结尾）时才能判定冲突；
/// 不存在且非目录形态的路径视为将被惰性创建，不报错。
String? checkOutputCompatibility({
  required String outputPath,
  required bool inputIsDirectory,
}) {
  final looksLikeDir =
      outputPath.endsWith('/') || outputPath.endsWith(p.separator);
  final type = FileSystemEntity.typeSync(outputPath);

  if (!inputIsDirectory &&
      (type == FileSystemEntityType.directory || looksLikeDir)) {
    return '输入为单文件，但 --output 指向目录：$outputPath\n'
        '       单文件输入时，--output 应为目标文件路径（如 -o out/foo.dart）';
  }
  if (inputIsDirectory && type == FileSystemEntityType.file) {
    return '输入为目录，但 --output 指向已存在的文件：$outputPath\n'
        '       目录输入时，--output 应为目标根目录路径（如 -o out/）';
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 统一 ArgParser
// ─────────────────────────────────────────────────────────────────────────────

/// 构建所有子命令共用的标准参数解析器：`-o/--output`、`-n/--dry-run`、
/// `-h/--help`。
ArgParser buildStandardParser() => ArgParser()
  ..addOption(
    'output',
    abbr: 'o',
    valueHelp: 'path',
    help:
        '输出路径。单文件输入→目标文件；目录输入→目标根目录（保留相对结构）。'
        '省略则覆写原文件。',
  )
  ..addFlag(
    'dry-run',
    abbr: 'n',
    negatable: false,
    help: '预览模式：仅打印将要发生的变更，不执行任何磁盘写入。',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助信息并退出。');

// ─────────────────────────────────────────────────────────────────────────────
// 用法渲染
// ─────────────────────────────────────────────────────────────────────────────

/// 一个子命令的用法元信息，用于渲染统一风格的帮助文本。
class UsageSpec {
  /// 调用命令名，例如 `dart run bin/merge_comments.dart`。
  final String invocation;

  /// 一句话功能描述。
  final String description;

  /// 示例行（每项为「注释 + 命令」两行的列表）。
  final List<UsageExample> examples;

  const UsageSpec({
    required this.invocation,
    required this.description,
    this.examples = const [],
  });
}

/// 单条用法示例：一行注释 + 一行命令。
class UsageExample {
  final String comment;
  final String command;
  const UsageExample(this.comment, this.command);
}

/// 按统一格式将 [spec] 与 [parser] 的选项说明渲染到 stdout。
void printUsage(UsageSpec spec, ArgParser parser) {
  final out = StringBuffer()
    ..writeln('用法：${spec.invocation} <path> [选项]')
    ..writeln()
    ..writeln('说明：')
    ..writeln('  ${spec.description}')
    ..writeln()
    ..writeln('参数：')
    ..writeln('  <path>   .dart 文件或包含 .dart 文件的目录（必填，目录将递归处理）')
    ..writeln()
    ..writeln('选项：')
    ..writeln(parser.usage);

  if (spec.examples.isNotEmpty) {
    out
      ..writeln()
      ..writeln('示例：');
    for (final ex in spec.examples) {
      out
        ..writeln('  # ${ex.comment}')
        ..writeln('  ${ex.command}')
        ..writeln();
    }
  }
  stdout.write(out.toString());
}
