// lib/src/dry_run.dart
//
// 统一的「变更统计 / dry-run 日志 / 错误归类」基础设施。
//
// 重构前，6 个子命令各自重复实现了：
//   * 一个统计类（strip_private/extract 的 `_DryRunStats`、merge 的
//     `FileChangeStats`、inserter 的 `Map<String,int>`）；
//   * 一个 `N inserts, M deletes` 的格式化函数（含 modify→modifies 的不规则
//     复数，在三处各写了一遍）；
//   * 一个 `[dry-run]  (√/×) <path> (<detail>)` 的输出函数（四处各写一遍）；
//   * 一个「异常 → 简短标签」的归类函数（io error / parse error /
//     permission denied）。
//
// 这里把它们收敛为唯一实现。

import 'dart:io';

/// 单个文件一次处理中各类编辑操作的计数。
///
/// 不同子命令只会用到其中部分字段（如 merge 只用 [merges]，strip_private 只用
/// [deletes]），其余保持为 0 即可——[describe] 会自动跳过 0 值字段。
class ChangeStats {
  final int inserts;
  final int deletes;
  final int modifies;
  final int merges;
  final int skips;
  final int renames;

  const ChangeStats({
    this.inserts = 0,
    this.deletes = 0,
    this.modifies = 0,
    this.merges = 0,
    this.skips = 0,
    this.renames = 0,
  });

  /// 「无任何变更」的共享常量，供 `Unchanged` 等场景复用。
  static const none = ChangeStats();

  /// 是否记录到了任意一类操作。
  bool get hasChanges =>
      inserts > 0 ||
      deletes > 0 ||
      modifies > 0 ||
      merges > 0 ||
      skips > 0 ||
      renames > 0;

  /// 生成括号内的统计描述，例如 `3 inserts, 1 modify`；无变更时返回
  /// `no changes`。这是所有子命令 dry-run 输出共用的措辞。
  String describe() {
    if (!hasChanges) return 'no changes';

    final parts = <String>[];
    void add(int n, String label) {
      if (n > 0) parts.add('$n ${_plural(label, n)}');
    }

    add(inserts, 'insert');
    add(deletes, 'delete');
    add(modifies, 'modify');
    add(merges, 'merge');
    add(skips, 'skip');
    add(renames, 'rename');
    return parts.join(', ');
  }
}

/// 对动作标签做复数化。除 `modify`→`modifies` 这个不规则形式外，其余统一加
/// `s`。未知标签也回退到加 `s`，便于未来新增动作类型时无需改动此处。
String _plural(String action, int count) {
  if (count == 1) return action;
  return action == 'modify' ? 'modifies' : '${action}s';
}

/// 构造一行统一格式的 dry-run 状态文本（不负责输出，交由调用方写 stdout）。
///
///   `[dry-run]  (√) <route> (<detail>)`   成功
///   `[dry-run]  (×) <route> (<reason>)`   失败
///
/// [route] 通常是文件路径；当存在跨路径输出时为 `src → dst`。
/// 成功时传入 [stats]（渲染为 `describe()`）；失败时传入 [errorReason]。
String dryRunLine({
  required String route,
  required bool ok,
  ChangeStats? stats,
  String? errorReason,
}) {
  final mark = ok ? '(√)' : '(×)';
  final detail = ok
      ? (stats ?? ChangeStats.none).describe()
      : (errorReason ?? 'error');
  return '[dry-run]  $mark $route ($detail)';
}

/// 将任意异常归类为 dry-run 失败行括号内的简短标签。
///
/// 合并了原 inserter `_errorReason` 与 merge `_shortErrorMessage` 的规则：
///   * 文件系统权限错误（errno 13/5 或消息含 permission）→ `permission denied`
///   * 其它 [FileSystemException] → `io error`
///   * 解析失败（[ParseFailure]/[FormatException]/含 parse 的 [StateError]）
///     → `parse error`
///   * 其余 → `error`
String classifyError(Object e) {
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    final msg = e.message.toLowerCase();
    if (code == 13 || code == 5 || msg.contains('permission')) {
      return 'permission denied';
    }
    return 'io error';
  }
  if (e is ParseFailure) return 'parse error';
  if (e is FormatException) return 'parse error';
  if (e is StateError) {
    final msg = e.message.toLowerCase();
    if (msg.contains('解析') || msg.contains('parse') || msg.contains('dart')) {
      return 'parse error';
    }
    return 'error';
  }
  return 'error';
}

/// 解析/分析阶段的统一失败类型。
///
/// 各子命令在无法解析源码时抛出它，[classifyError] 会将其归类为
/// `parse error`，harness 则负责输出与计数。
class ParseFailure implements Exception {
  final String message;
  ParseFailure(this.message);
  @override
  String toString() => 'ParseFailure: $message';
}
