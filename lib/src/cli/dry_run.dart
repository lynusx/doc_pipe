import 'dart:convert';
import 'dart:io';

import 'console.dart';
import 'line_diff.dart';

/// 单文件 dry-run 操作统计。
class ChangeStats {
  final int inserts;
  final int deletes;
  final int modifies;
  final int merges;
  final int skips;

  const ChangeStats({
    this.inserts = 0,
    this.deletes = 0,
    this.modifies = 0,
    this.merges = 0,
    this.skips = 0,
  });

  static const noChanges = ChangeStats();

  bool get hasChanges =>
      inserts > 0 || deletes > 0 || modifies > 0 || merges > 0 || skips > 0;

  String describe() {
    if (!hasChanges) return 'no changes';
    final parts = <String>[];
    void add(int n, String s, String p) {
      if (n > 0) parts.add('$n ${n == 1 ? s : p}');
    }

    add(inserts, 'insert', 'inserts');
    add(deletes, 'delete', 'deletes');
    add(modifies, 'modify', 'modifies');
    add(merges, 'merge', 'merges');
    add(skips, 'skip', 'skips');
    return parts.join(', ');
  }
}

/// 输出一条统一格式的 dry-run 日志行（via Console.info → stdout）。
///
/// 格式：`[dry-run]  (√/×) <path> (<stats-or-error>)`
void printDryRunLine({
  required String path,
  required bool ok,
  ChangeStats stats = ChangeStats.noChanges,
  String? errorReason,
}) {
  final mark = ok ? '(√)' : '(×)';
  final detail = ok ? '(${stats.describe()})' : '(${errorReason ?? 'error'})';
  Console.info('[dry-run]  $mark $path $detail');
}

/// 对比磁盘上的旧内容与新内容，计算 LCS diff 统计；[merges] 由调用方传入。
ChangeStats computeDiffStats({
  required String outputPath,
  required String newContent,
  int merges = 0,
}) {
  String? oldContent;
  final destFile = File(outputPath);
  if (destFile.existsSync()) {
    try {
      oldContent = destFile.readAsStringSync();
    } catch (e) {
      Console.warn('无法读取现有文件以计算 diff 预览：$outputPath（$e）');
    }
  }

  if (oldContent == null) {
    final lineCount = newContent.isEmpty
        ? 0
        : const LineSplitter().convert(newContent).length;
    return ChangeStats(inserts: lineCount, merges: merges);
  }

  if (oldContent == newContent) return ChangeStats.noChanges;

  final diff = diffLines(
    const LineSplitter().convert(oldContent),
    const LineSplitter().convert(newContent),
  );
  return ChangeStats(
    inserts: diff.inserts,
    deletes: diff.deletes,
    modifies: diff.modifies,
    merges: merges,
  );
}
