// lib/src/commands/strip_private_command.dart
//
// 删除 Dart 源文件中所有私有声明（及其关联注释/注解），基于 analyzer AST。
// 收集逻辑（_PrivateRegionCollector / _Interval / _applyDeletions）与原工具
// 完全一致，仅把「解析上下文搭建 + 写盘 + dry-run」交给共享 harness。

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import '../dry_run.dart';
import '../files.dart';
import '../harness.dart';

/// 删除所有私有顶层声明，以及公有类中的私有成员（含其注释与注解）。
class StripPrivateCommand extends FileCommand {
  @override
  UsageSpec get usage => const UsageSpec(
    invocation: 'dart run bin/strip_private.dart',
    description: '删除所有私有声明（_ 前缀）及其关联的注释与注解。',
    examples: [
      UsageExample(
        '处理单文件（覆写原文件）',
        'dart run bin/strip_private.dart lib/src/foo.dart',
      ),
      UsageExample(
        '处理目录，输出到另一目录',
        'dart run bin/strip_private.dart lib/ -o out/',
      ),
      UsageExample(
        '预览将删除的区域（不写盘）',
        'dart run bin/strip_private.dart lib/ --dry-run',
      ),
    ],
  );

  @override
  Future<FileOutcome> transform(FileContext ctx) async {
    // surfaceErrors: true —— 存在 ERROR 级诊断时视为解析失败（原工具语义）。
    final resolved = await ctx.resolvedUnit(surfaceErrors: true);

    final collector = _PrivateRegionCollector(ctx.source);
    collector.visitCompilationUnit(resolved.unit);
    final intervals = collector.mergedIntervals();

    if (intervals.isEmpty) return const Unchanged();

    final result = _applyDeletions(ctx.source, intervals);
    return Transformed(result, ChangeStats(deletes: intervals.length));
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 源文本变换：删除区间并压缩多余空行 —— 与原实现一致
// ═══════════════════════════════════════════════════════════════════════════

String _applyDeletions(String source, List<_Interval> intervals) {
  final buf = StringBuffer();
  var cursor = 0;

  for (final iv in intervals) {
    if (iv.start > cursor) {
      buf.write(source.substring(cursor, iv.start));
    }
    cursor = iv.end;
  }
  if (cursor < source.length) {
    buf.write(source.substring(cursor));
  }

  var result = buf.toString();

  // 压缩 3+ 连续换行（2+ 空行）为 2 个换行（1 空行），迭代至稳定。
  String prev;
  do {
    prev = result;
    result = result.replaceAll('\n\n\n', '\n\n');
  } while (result != prev);

  // 若仅余空白，写空文件。
  if (result.trim().isEmpty) return '';

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// 核心 AST 访问器 —— 与原实现一致
// ═══════════════════════════════════════════════════════════════════════════

/// 遍历顶层声明及每个公有类的成员，收集需删除的源区间。
///
/// 设计：不递归进入函数体；以 [CompilationUnitMember] / [ClassMember] 节点
/// 类别为单位，避免误删带 `_` 前缀的内部局部变量。
class _PrivateRegionCollector {
  _PrivateRegionCollector(this._source);

  final String _source;
  final List<_Interval> _raw = [];

  void visitCompilationUnit(CompilationUnit unit) {
    for (final decl in unit.declarations) {
      _handleTopLevel(decl);
    }
  }

  // ── 顶层声明 ───────────────────────────────────────────────────────────
  void _handleTopLevel(CompilationUnitMember decl) {
    final name = _primaryName(decl);

    if (name != null && _isPrivate(name)) {
      _collectNode(decl);
      return;
    }

    if (decl is ClassDeclaration) {
      _handleClassMembers(decl);
    }
  }

  String? _primaryName(CompilationUnitMember decl) {
    if (decl is ClassDeclaration) return decl.name.lexeme;
    if (decl is ClassTypeAlias) return decl.name.lexeme;
    if (decl is EnumDeclaration) return decl.name.lexeme;
    if (decl is MixinDeclaration) return decl.name.lexeme;
    if (decl is ExtensionDeclaration) return decl.name?.lexeme;
    if (decl is FunctionDeclaration) return decl.name.lexeme;

    if (decl is TopLevelVariableDeclaration) {
      final vars = decl.variables.variables;
      if (vars.isNotEmpty && vars.every((v) => _isPrivate(v.name.lexeme))) {
        return vars.first.name.lexeme;
      }
      return null;
    }

    if (decl is GenericTypeAlias) return decl.name.lexeme;
    if (decl is FunctionTypeAlias) return decl.name.lexeme;

    return null;
  }

  // ── 公有类的成员 ───────────────────────────────────────────────────────
  void _handleClassMembers(ClassDeclaration classDecl) {
    for (final member in classDecl.members) {
      _handleMember(member);
    }
  }

  void _handleMember(ClassMember member) {
    if (member is MethodDeclaration) {
      if (_isPrivate(member.name.lexeme)) {
        _collectNode(member);
      }
      return;
    }

    if (member is FieldDeclaration) {
      final vars = member.fields.variables;
      if (vars.isNotEmpty && vars.every((v) => _isPrivate(v.name.lexeme))) {
        _collectNode(member);
      }
      return;
    }

    if (member is ConstructorDeclaration) {
      final ctorName = member.name?.lexeme;
      if (ctorName != null && _isPrivate(ctorName)) {
        _collectNode(member);
      }
    }
  }

  // ── 单个节点的区间收集 ─────────────────────────────────────────────────
  void _collectNode(AstNode node) {
    final start = _commentStartOf(node);
    final end = _extendToLineEnd(node.end);
    _raw.add(_Interval(start, end));
  }

  // ── 前置注释解析 ───────────────────────────────────────────────────────
  int _commentStartOf(AstNode node) {
    final Token firstReal;
    if (node is AnnotatedNode) {
      firstReal = node.firstTokenAfterCommentAndMetadata;
    } else {
      firstReal = node.beginToken;
    }

    int? earliestCommentOffset;
    Token? comment = firstReal.precedingComments;
    while (comment != null) {
      final nextOffset = comment.next?.offset ?? firstReal.offset;
      final between = _source.substring(comment.end, nextOffset);
      if (_hasBlankLine(between)) {
        break;
      }
      earliestCommentOffset = comment.offset;
      comment = comment.next as Token?;
    }

    int? docOffset;
    if (node is AnnotatedNode) {
      docOffset = node.documentationComment?.offset;
    }

    final candidates = [
      if (earliestCommentOffset != null) earliestCommentOffset,
      if (docOffset != null) docOffset,
      node.offset,
    ];
    return candidates.reduce((a, b) => a < b ? a : b);
  }

  bool _hasBlankLine(String between) => between.contains('\n\n');

  // ── 行尾扩展 ───────────────────────────────────────────────────────────
  int _extendToLineEnd(int offset) {
    var end = offset;
    while (end < _source.length && _source[end] != '\n') {
      end++;
    }
    if (end < _source.length) end++;
    return end;
  }

  bool _isPrivate(String name) => name.startsWith('_');

  // ── 区间合并 ───────────────────────────────────────────────────────────
  List<_Interval> mergedIntervals() {
    if (_raw.isEmpty) return const [];

    _raw.sort((a, b) => a.start.compareTo(b.start));
    final merged = <_Interval>[_raw.first];

    for (var i = 1; i < _raw.length; i++) {
      final next = _raw[i];
      final last = merged.last;
      if (next.start <= last.end) {
        merged[merged.length - 1] = _Interval(
          last.start,
          next.end > last.end ? next.end : last.end,
        );
      } else {
        merged.add(next);
      }
    }
    return merged;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 值类型：源偏移区间 [start, end)
// ═══════════════════════════════════════════════════════════════════════════

/// 半开区间：`[start, end)` 内的字符将被删除。
final class _Interval {
  const _Interval(this.start, this.end);

  final int start; // 含
  final int end; // 不含

  @override
  String toString() => 'Interval($start, $end)';
}
