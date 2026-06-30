import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:analyzer/dart/analysis/results.dart';

import '../analysis/ast_loader.dart';
import 'cli_options.dart';
import 'console.dart';
import 'destination.dart';
import 'dry_run.dart';
import 'file_collector.dart';

export '../analysis/ast_loader.dart' show AnalysisNeed;
export 'dry_run.dart' show ChangeStats;

// ─────────────────────────────────────────────────────────────────────────────
// 单文件输入视图
// ─────────────────────────────────────────────────────────────────────────────

/// 传入 [DartFileTool.transform] 的源文件视图。
///
/// 字段按需懒加载：只有 [analysisNeed] 允许的字段才会被 materialize。
class SourceFile {
  final String path;
  final String text;

  // 仅当 analysisNeed >= parsed 时有效
  final Object? _parsedUnit;

  // 仅当 analysisNeed >= resolved 时有效
  final Object? _resolvedUnit;

  const SourceFile._({
    required this.path,
    required this.text,
    Object? parsedUnit,
    Object? resolvedUnit,
  }) : _parsedUnit = parsedUnit,
       _resolvedUnit = resolvedUnit;

  /// 已解析的 AST 单元（需要 [AnalysisNeed.parsed] 或以上）。
  dynamic get parsedUnit => _parsedUnit;

  /// 完全解析单元（需要 [AnalysisNeed.resolved]）。
  dynamic get resolvedUnit => _resolvedUnit;
}

// ─────────────────────────────────────────────────────────────────────────────
// 转换结果
// ─────────────────────────────────────────────────────────────────────────────

enum FileOutcome { changed, unchanged, skipped }

class FileChange {
  final String? newContent; // null 表示不需要写盘（unchanged/skipped）
  final ChangeStats stats;
  final FileOutcome outcome;

  const FileChange({
    required this.newContent,
    required this.stats,
    required this.outcome,
  });

  static FileChange unchanged() => const FileChange(
    newContent: null,
    stats: ChangeStats.noChanges,
    outcome: FileOutcome.unchanged,
  );

  static FileChange skipped() => const FileChange(
    newContent: null,
    stats: ChangeStats.noChanges,
    outcome: FileOutcome.skipped,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 用法示例
// ─────────────────────────────────────────────────────────────────────────────

class UsageExample {
  final String comment;
  final String command;

  const UsageExample(this.comment, this.command);
}

// ─────────────────────────────────────────────────────────────────────────────
// 抽象基类
// ─────────────────────────────────────────────────────────────────────────────

abstract class DartFileTool {
  // ── 子类必须实现 ──────────────────────────────────────────────────────────

  String get name;
  String get description;
  List<UsageExample> get examples;

  /// 对单个源文件执行核心转换。
  Future<FileChange> transform(SourceFile input);

  // ── 子类可覆写 ────────────────────────────────────────────────────────────

  /// 输出文件扩展名，默认 `.dart`；rename_to_md 覆写为 `.md`。
  String get outputExtension => '.dart';

  /// 所需解析层级，默认不需要 AST。
  AnalysisNeed get analysisNeed => AnalysisNeed.none;

  /// 就地写入策略：默认覆写；rename_to_md 覆写为先写后删源文件。
  bool get inPlaceIsRename => false;

  // ── 主入口 ────────────────────────────────────────────────────────────────

  Future<void> run(List<String> args) async {
    final parser = buildCommonParser();
    _addExtraOptions(parser);

    final opts = parseAndValidate(
      args,
      parser,
      toolName: name,
      outputExtension: outputExtension,
      onHelp: (p) => _printUsage(p),
    );

    Console.init();

    final files = opts.isInputDirectory
        ? collectDartFiles(Directory(opts.inputPath))
        : [File(opts.inputPath)];

    if (files.isEmpty) {
      Console.info('未找到任何 .dart 文件：${opts.inputPath}');
      exit(0);
    }

    // 如需 resolved，批量建立分析上下文（性能优化）
    final resolvedCollection = analysisNeed == AnalysisNeed.resolved
        ? buildCollection(files.map((f) => p.canonicalize(f.path)).toList())
        : null;

    int changed = 0, skipped = 0, errors = 0;

    for (final file in files) {
      final absPath = p.canonicalize(file.path);
      final destPath = resolveDestination(
        sourcePath: absPath,
        inputRoot: opts.inputPath,
        isInputDirectory: opts.isInputDirectory,
        outputRoot: opts.outputPath,
        outputExtension: outputExtension,
      );

      // ── 读取源文件 ──────────────────────────────────────────────────────
      String source;
      try {
        source = file.readAsStringSync();
      } catch (e) {
        Console.error('错误：无法读取：$absPath（$e）');
        if (opts.dryRun) {
          printDryRunLine(path: absPath, ok: false, errorReason: 'io error');
        }
        errors++;
        continue;
      }

      // ── 构建 SourceFile（按需加载 AST） ─────────────────────────────────
      late SourceFile sourceFile;
      try {
        sourceFile = await _buildSourceFile(
          absPath: absPath,
          source: source,
          resolvedCollection: resolvedCollection,
        );
      } catch (e) {
        Console.error('错误：解析失败：$absPath（$e）');
        if (opts.dryRun) {
          printDryRunLine(path: absPath, ok: false, errorReason: 'parse error');
        }
        errors++;
        continue;
      }

      // ── 执行核心转换 ─────────────────────────────────────────────────────
      late FileChange change;
      try {
        change = await transform(sourceFile);
      } catch (e, st) {
        Console.error('错误：转换失败：$absPath（$e）');
        Console.error(st.toString());
        if (opts.dryRun) {
          printDryRunLine(path: absPath, ok: false, errorReason: 'error');
        }
        errors++;
        continue;
      }

      // ── Dry-run 预览 ─────────────────────────────────────────────────────
      if (opts.dryRun) {
        if (change.outcome == FileOutcome.skipped) {
          printDryRunLine(
            path: destPath,
            ok: true,
            stats: ChangeStats.noChanges,
          );
        } else {
          final dryStats = change.newContent != null
              ? computeDiffStats(
                  outputPath: destPath,
                  newContent: change.newContent!,
                  merges: change.stats.merges,
                )
              : ChangeStats.noChanges;
          printDryRunLine(path: destPath, ok: true, stats: dryStats);
          if (dryStats.hasChanges) changed++;
        }
        continue;
      }

      // ── 写盘 ─────────────────────────────────────────────────────────────
      if (change.outcome != FileOutcome.changed || change.newContent == null) {
        skipped++;
        continue;
      }

      try {
        final destFile = File(destPath);
        destFile.parent.createSync(recursive: true);
        destFile.writeAsStringSync(change.newContent!);

        // 就地 rename（outputExtension != .dart，且无 -o）：源文件消失
        if (inPlaceIsRename && opts.outputPath == null) {
          file.deleteSync();
        }

        changed++;
      } on FileSystemException catch (e) {
        Console.error('错误：无法写入：$destPath（${e.osError?.message ?? e.message}）');
        errors++;
      }
    }

    // ── 汇总 ─────────────────────────────────────────────────────────────────
    if (opts.dryRun) {
      Console.info(
        '\n[dry-run] 共 ${files.length} 个文件，'
        '$changed 个将变更，${files.length - changed - errors} 个无变化，$errors 个出错。',
      );
    } else {
      Console.info('完成：处理 $changed 个，跳过 $skipped 个，失败 $errors 个。');
    }

    exit(errors > 0 ? 1 : 0);
  }

  // ── 内部辅助 ──────────────────────────────────────────────────────────────

  /// 子类可覆写以向 parser 添加额外选项（默认无操作）。
  void _addExtraOptions(ArgParser parser) {}

  Future<SourceFile> _buildSourceFile({
    required String absPath,
    required String source,
    required dynamic resolvedCollection,
  }) async {
    switch (analysisNeed) {
      case AnalysisNeed.none:
        return SourceFile._(path: absPath, text: source);

      case AnalysisNeed.parsed:
        final parsed = loadParsed(absPath, source);
        return SourceFile._(path: absPath, text: source, parsedUnit: parsed);

      case AnalysisNeed.resolved:
        if (resolvedCollection != null) {
          final ctx = resolvedCollection.contextFor(absPath);
          final raw = await ctx.currentSession.getResolvedUnit(absPath);
          if (raw is! ResolvedUnitResult) {
            throw StateError(
              '无法获取 ResolvedUnitResult：$absPath（${raw.runtimeType}）',
            );
          }
          return SourceFile._(path: absPath, text: source, resolvedUnit: raw);
        }
        final resolved = await loadResolved(absPath);
        return SourceFile._(
          path: absPath,
          text: source,
          resolvedUnit: resolved,
        );
    }
  }

  void _printUsage(ArgParser parser) {
    Console.info('用法：dart run bin/$name.dart <路径> [选项]\n');
    Console.info('描述：$description\n');
    Console.info('参数：');
    Console.info('  <路径>   .dart 文件或包含 .dart 文件的目录（必填）\n');
    Console.info('选项：');
    Console.info(parser.usage);
    if (examples.isNotEmpty) {
      Console.info('\n示例：');
      for (final ex in examples) {
        Console.info('  # ${ex.comment}');
        Console.info('  ${ex.command}');
        Console.info('');
      }
    }
  }
}
