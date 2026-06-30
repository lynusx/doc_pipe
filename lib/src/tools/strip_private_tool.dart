import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:doc_pipe/src/cli/dart_file_tool.dart';

class StripPrivateTool extends DartFileTool {
  @override
  String get name => 'strip_private';

  @override
  String get description => '删除 Dart 源文件中所有私有声明及其关联注释和注解。';

  @override
  List<UsageExample> get examples => const [
    UsageExample(
      '处理单文件（覆写原文件）',
      'dart run bin/strip_private.dart lib/src/foo.dart',
    ),
    UsageExample(
      '处理目录，输出到另一目录',
      'dart run bin/strip_private.dart lib/ -o lib_stripped/',
    ),
    UsageExample(
      '预览将删除的私有声明（不写磁盘）',
      'dart run bin/strip_private.dart lib/ --dry-run',
    ),
  ];

  @override
  AnalysisNeed get analysisNeed => AnalysisNeed.resolved;

  @override
  Future<FileChange> transform(SourceFile input) async {
    final result = input.resolvedUnit as ResolvedUnitResult;
    final source = input.text;

    final parseErrors = result.errors
        .where((e) => e.severity.name == 'ERROR')
        .toList();
    if (parseErrors.isNotEmpty) {
      throw StateError(
        '解析错误：${parseErrors.map((e) => e.toString()).join(', ')}',
      );
    }

    final collector = _PrivateRegionCollector(source);
    collector.visitCompilationUnit(result.unit);
    final intervals = collector.mergedIntervals();

    if (intervals.isEmpty) return FileChange.unchanged();

    final transformed = _applyDeletions(source, intervals);
    return FileChange(
      newContent: transformed,
      stats: ChangeStats(deletes: intervals.length),
      outcome: FileOutcome.changed,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 以下为原 strip_private.dart 的核心逻辑，原样搬运
// ══════════════════════════════════════════════════════════════════════════════

String _applyDeletions(String source, List<_Interval> intervals) {
  final buf = StringBuffer();
  var cursor = 0;

  for (final iv in intervals) {
    if (iv.start > cursor) buf.write(source.substring(cursor, iv.start));
    cursor = iv.end;
  }
  if (cursor < source.length) buf.write(source.substring(cursor));

  var result = buf.toString();
  String prev;
  do {
    prev = result;
    result = result.replaceAll('\n\n\n', '\n\n');
  } while (result != prev);

  if (result.trim().isEmpty) return '';
  return result;
}

class _PrivateRegionCollector {
  _PrivateRegionCollector(this._source);

  final String _source;
  final List<_Interval> _raw = [];

  void visitCompilationUnit(CompilationUnit unit) {
    for (final decl in unit.declarations) {
      _handleTopLevel(decl);
    }
  }

  void _handleTopLevel(CompilationUnitMember decl) {
    final name = _primaryName(decl);
    if (name != null && _isPrivate(name)) {
      _collectNode(decl);
      return;
    }
    if (decl is ClassDeclaration) _handleClassMembers(decl);
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

  void _handleClassMembers(ClassDeclaration classDecl) {
    for (final member in classDecl.members) {
      _handleMember(member);
    }
  }

  void _handleMember(ClassMember member) {
    if (member is MethodDeclaration) {
      if (_isPrivate(member.name.lexeme)) _collectNode(member);
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
      if (ctorName != null && _isPrivate(ctorName)) _collectNode(member);
    }
  }

  void _collectNode(AstNode node) {
    final start = _commentStartOf(node);
    final end = _extendToLineEnd(node.end);
    _raw.add(_Interval(start, end));
  }

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
      if (_hasBlankLine(between)) break;
      earliestCommentOffset = comment.offset;
      comment = comment.next;
    }

    final docOffset = node is AnnotatedNode
        ? node.documentationComment?.offset
        : null;

    final candidates = [?earliestCommentOffset, ?docOffset, node.offset];
    return candidates.reduce((a, b) => a < b ? a : b);
  }

  bool _hasBlankLine(String between) => between.contains('\n\n');

  int _extendToLineEnd(int offset) {
    var end = offset;
    while (end < _source.length && _source[end] != '\n') {
      end++;
    }
    if (end < _source.length) end++;
    return end;
  }

  bool _isPrivate(String name) => name.startsWith('_');

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

final class _Interval {
  const _Interval(this.start, this.end);
  final int start;
  final int end;
}
