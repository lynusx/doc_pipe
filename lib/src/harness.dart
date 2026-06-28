// lib/src/harness.dart
//
// 子命令骨架。
//
// 这里是消除重复的核心：所有 6 个子命令原本各写一份近乎相同的 `main()`——
// 解析参数、校验输入路径、校验 --output、收集 .dart 文件、逐文件处理、
// dry-run 日志、错误隔离、汇总与退出码。本文件把这套生命周期收敛为唯一的
// [runCommand]，子命令只需提供：
//   * [FileCommand.usage]：用法元信息；
//   * [FileCommand.transform]：对单个文件源码的纯变换（不直接写盘）。
//
// 「是否写盘」由变换返回的 [FileOutcome] 类型决定（[Transformed] 写、
// [Unchanged] 跳过），从而精确复刻各命令原有的写/跳语义，且把 dry-run 与真实
// 写盘彻底分离——dry-run 只调用变换并打印，绝不触碰磁盘。

import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'analysis.dart';
import 'dry_run.dart';
import 'files.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 单文件变换的输入与输出
// ─────────────────────────────────────────────────────────────────────────────

/// 传入 [FileCommand.transform] 的单文件上下文。
///
/// 同时提供按需的 analyzer 访问能力——不需要的命令（如纯文本处理的
/// remove/rename）永远不会触发解析上下文的创建。
class FileContext {
  /// 当前文件的 canonicalize 绝对路径。
  final String path;

  /// 文件内容（由 harness 统一读取一次）。
  final String source;

  /// 本文件的最终写入目标（已应用 [FileCommand.rewriteDestination]）。
  /// 多数命令用不到；rename 等需要据此报告 `→ 目标` 时可读取。
  final String destination;

  final AnalysisService _analysis;

  FileContext({
    required this.path,
    required this.source,
    required this.destination,
    required AnalysisService analysis,
  }) : _analysis = analysis;

  /// 已解析单元（含类型信息）。失败抛 [ParseFailure]。
  /// [surfaceErrors] 为 true 时，ERROR 级诊断也会抛出。
  Future<ResolvedUnitResult> resolvedUnit({bool surfaceErrors = false}) =>
      _analysis.resolved(path, surfaceErrors: surfaceErrors);

  /// [CompilationUnit]：优先已解析，失败回退纯语法分析。
  Future<CompilationUnit> compilationUnit() => _analysis.unit(path);

  /// 轻量语法分析（不建解析上下文），用于只需 AST/token 的场景。
  ParseStringResult parsed() => parseSource(source, path);
}

/// 单文件变换的结果。
sealed class FileOutcome {
  const FileOutcome();
}

/// 该文件应被写入 [content]，[stats] 描述其变更。
class Transformed extends FileOutcome {
  final String content;
  final ChangeStats stats;
  const Transformed(this.content, this.stats);
}

/// 该文件无需变更（不写盘）。
class Unchanged extends FileOutcome {
  final ChangeStats stats;
  const Unchanged([this.stats = ChangeStats.none]);
}

// ─────────────────────────────────────────────────────────────────────────────
// 子命令基类
// ─────────────────────────────────────────────────────────────────────────────

/// 所有「逐 .dart 文件处理」子命令的基类。
///
/// 子类只实现 [usage] 与 [transform]；公共生命周期见 [runCommand]。
abstract class FileCommand {
  /// 用法元信息（命令名、描述、示例）。
  UsageSpec get usage;

  /// 对单个文件执行变换，返回 [Transformed]（写盘）或 [Unchanged]（跳过）。
  ///
  /// **不得直接写盘**：写入与 dry-run 预览均由 harness 统一处理。无法解析等
  /// 失败应抛出异常（推荐 [ParseFailure]），harness 会归类、记录并继续。
  Future<FileOutcome> transform(FileContext ctx);

  /// 改写最终写入路径。默认原样返回；rename 覆写为改扩展名为 `.md`。
  String rewriteDestination(String destination) => destination;

  /// 原地处理（无 --output）且写入路径与源不同（如改了扩展名）时，是否删除
  /// 原文件。默认 false；rename 覆写为 true。
  bool get removesOriginalOnInPlace => false;

  /// 程序入口：解析 [args] 并执行，返回进程退出码。
  Future<int> run(List<String> args) => runCommand(this, args);
}

// ─────────────────────────────────────────────────────────────────────────────
// 统一生命周期
// ─────────────────────────────────────────────────────────────────────────────

/// 驱动一个 [FileCommand]：解析参数 → 校验 → 收集 → 逐文件处理 → 汇总。
/// 返回退出码（有错误为 1，否则为 0）。
Future<int> runCommand(FileCommand command, List<String> args) async {
  final parser = buildStandardParser();

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('错误：${e.message}');
    printUsage(command.usage, parser);
    return 1;
  }

  if (parsed['help'] as bool) {
    printUsage(command.usage, parser);
    return 0;
  }

  if (parsed.rest.isEmpty) {
    stderr.writeln('错误：缺少必填参数 <path>');
    printUsage(command.usage, parser);
    return 1;
  }
  if (parsed.rest.length > 1) {
    stderr.writeln(
      '错误：只接受一个 <path>，实际收到 ${parsed.rest.length} 个：'
      '${parsed.rest.map((s) => '"$s"').join(', ')}',
    );
    printUsage(command.usage, parser);
    return 1;
  }

  // ── 输入路径校验 ──────────────────────────────────────────────────────────
  final inputRoot = p.canonicalize(parsed.rest.first);
  final inputType = FileSystemEntity.typeSync(inputRoot);
  if (inputType == FileSystemEntityType.notFound) {
    stderr.writeln('错误：路径不存在：$inputRoot');
    return 1;
  }

  final bool inputIsDirectory;
  if (inputType == FileSystemEntityType.directory) {
    inputIsDirectory = true;
  } else if (inputType == FileSystemEntityType.file) {
    inputIsDirectory = false;
    if (!inputRoot.endsWith('.dart')) {
      stderr.writeln('错误：输入文件不是 .dart 文件：$inputRoot');
      return 1;
    }
  } else {
    stderr.writeln('错误：不支持的路径类型：$inputRoot');
    return 1;
  }

  // ── --output 一致性校验 ───────────────────────────────────────────────────
  final outputRoot = parsed['output'] as String?;
  if (outputRoot != null) {
    final err = checkOutputCompatibility(
      outputPath: outputRoot,
      inputIsDirectory: inputIsDirectory,
    );
    if (err != null) {
      stderr.writeln('错误：$err');
      return 1;
    }
  }

  final isDryRun = parsed['dry-run'] as bool;

  // ── 收集待处理文件 ────────────────────────────────────────────────────────
  final files = inputIsDirectory ? collectDartFiles(inputRoot) : [inputRoot];
  if (files.isEmpty) {
    stdout.writeln('未在以下路径找到 .dart 文件：$inputRoot');
    return 0;
  }

  final analysis = AnalysisService(inputRoot);

  var processed = 0;
  var changed = 0;
  var skipped = 0;
  var errors = 0;

  for (final path in files) {
    // 读取源码
    final String source;
    try {
      source = File(path).readAsStringSync();
    } catch (e, st) {
      stderr.writeln('错误：无法读取 $path：$e');
      stderr.writeln(st);
      if (isDryRun) {
        stdout.writeln(
          dryRunLine(route: path, ok: false, errorReason: classifyError(e)),
        );
      }
      errors++;
      continue;
    }

    final destBase = resolveDestination(
      sourcePath: path,
      inputRoot: inputRoot,
      inputIsDirectory: inputIsDirectory,
      outputRoot: outputRoot,
    );
    final dest = command.rewriteDestination(destBase);
    final route = dest == path ? path : '$path → $dest';

    // 执行变换
    final FileOutcome outcome;
    try {
      outcome = await command.transform(
        FileContext(
          path: path,
          source: source,
          destination: dest,
          analysis: analysis,
        ),
      );
    } catch (e, st) {
      stderr.writeln('错误：处理失败 $path：$e');
      stderr.writeln(st);
      if (isDryRun) {
        stdout.writeln(
          dryRunLine(route: route, ok: false, errorReason: classifyError(e)),
        );
      }
      errors++;
      continue;
    }

    processed++;

    // dry-run：只打印，不写盘
    if (isDryRun) {
      final stats = switch (outcome) {
        Transformed(:final stats) => stats,
        Unchanged(:final stats) => stats,
      };
      stdout.writeln(dryRunLine(route: route, ok: true, stats: stats));
      if (outcome is Transformed) {
        changed++;
      } else {
        skipped++;
      }
      continue;
    }

    // 真实写盘
    switch (outcome) {
      case Unchanged():
        stdout.writeln('跳过（无变化）：$path');
        skipped++;
      case Transformed(:final content, :final stats):
        try {
          final destFile = File(dest);
          final parent = destFile.parent;
          if (!parent.existsSync()) parent.createSync(recursive: true);
          destFile.writeAsStringSync(content);

          // 原地改名场景：删除已不再需要的源文件。
          if (command.removesOriginalOnInPlace &&
              dest != path &&
              outputRoot == null) {
            final original = File(path);
            if (original.existsSync()) original.deleteSync();
          }

          stdout.writeln('已处理：$route（${stats.describe()}）');
          changed++;
        } on FileSystemException catch (e) {
          stderr.writeln('错误：无法写入 $dest（${e.osError?.message ?? e.message}）');
          errors++;
        }
    }
  }

  // ── 汇总 ──────────────────────────────────────────────────────────────────
  final summary = StringBuffer();
  if (isDryRun) {
    summary.write('[dry-run] 预览完成：$changed 个将变更，$skipped 个无变化');
  } else {
    summary.write('完成：处理 $processed 个，修改 $changed 个，跳过 $skipped 个');
  }
  if (errors > 0) summary.write('，$errors 个出错');
  stdout.writeln(summary.toString());

  return errors > 0 ? 1 : 0;
}
