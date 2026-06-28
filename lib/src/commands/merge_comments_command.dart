// lib/src/commands/merge_comments_command.dart
//
// 将文档注释（///）块内连续多行的同一段落合并为一行，段落间纯空行注释转为普通
// 空行；代码围栏（``` ... ```）与各类 Markdown 块级元素按规则原样保留。
//
// 分段/合并引擎（DocCommentRegion、_segmentRegion、buildReplacement、
// applyReplacements 及全部 Markdown 识别规则）与原工具完全一致；仅把
// 「解析上下文、写盘、dry-run、统计输出」交给共享 harness。

import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';

import '../dry_run.dart';
import '../files.dart';
import '../harness.dart';

/// 合并文档注释中可合并的多行段落（保留代码块与 Markdown 块级元素）。
class MergeCommentsCommand extends FileCommand {
  @override
  UsageSpec get usage => const UsageSpec(
    invocation: 'dart run bin/merge_comments.dart',
    description: '将 /// 注释中连续多行的同一段落合并为一行（代码块与 Markdown 块原样保留）。',
    examples: [
      UsageExample(
        '处理单文件（覆写原文件，建议先备份）',
        'dart run bin/merge_comments.dart lib/my_widget.dart',
      ),
      UsageExample(
        '递归处理目录，输出到另一目录（保留相对结构）',
        'dart run bin/merge_comments.dart lib/ -o out/',
      ),
      UsageExample(
        '预览将变更的文件（不写盘）',
        'dart run bin/merge_comments.dart lib/ --dry-run',
      ),
    ],
  );

  @override
  Future<FileOutcome> transform(FileContext ctx) async {
    // 优先已解析单元，失败回退纯语法分析（merge 只需 token 流与 lineInfo）。
    final unit = await ctx.compilationUnit();

    final stats = _MergeStats();
    final docTokens = collectDocCommentTokens(unit.beginToken);
    final regions = groupTokensIntoRegions(docTokens, unit.lineInfo);
    final transformed = applyReplacements(ctx.source, regions, stats: stats);

    if (transformed == ctx.source) return const Unchanged();
    return Transformed(transformed, ChangeStats(merges: stats.merges));
  }
}

/// 合并次数计数（buildReplacement 内累加）。
class _MergeStats {
  int merges = 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 数据结构
// ═══════════════════════════════════════════════════════════════════════════════

/// 源文件中一段连续的 `///` 注释行序列（相邻行号相差恰为 1）。
class DocCommentRegion {
  final List<Token> tokens;
  final List<int> lineNumbers;

  DocCommentRegion(this.tokens, this.lineNumbers)
    : assert(tokens.length == lineNumbers.length),
      assert(tokens.isNotEmpty);

  int get firstOffset => tokens.first.offset;
  int get lastEnd => tokens.last.end;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 步骤 1：收集所有文档注释 token
// ═══════════════════════════════════════════════════════════════════════════════

/// 遍历 token stream，返回所有 `///` 注释 token（按 offset 升序）。
List<Token> collectDocCommentTokens(Token firstToken) {
  final result = <Token>[];

  Token? current = firstToken;
  while (current != null && current.type != TokenType.EOF) {
    _collectPrecedingDocComments(current, result);
    current = current.next;
  }
  if (current != null) {
    _collectPrecedingDocComments(current, result);
  }

  result.sort((a, b) => a.offset.compareTo(b.offset));
  return result;
}

void _collectPrecedingDocComments(Token token, List<Token> out) {
  Token? comment = token.precedingComments;
  while (comment != null) {
    if (_isDocCommentToken(comment)) {
      out.add(comment);
    }
    comment = comment.next;
  }
}

bool _isDocCommentToken(Token t) =>
    t.type == TokenType.SINGLE_LINE_COMMENT && t.lexeme.startsWith('///');

// ═══════════════════════════════════════════════════════════════════════════════
// 步骤 2：按连续行号分组
// ═══════════════════════════════════════════════════════════════════════════════

List<DocCommentRegion> groupTokensIntoRegions(
  List<Token> docTokens,
  LineInfo lineInfo,
) {
  if (docTokens.isEmpty) return const [];

  final regions = <DocCommentRegion>[];
  var curTokens = <Token>[];
  var curLines = <int>[];

  for (final token in docTokens) {
    final line = lineInfo.getLocation(token.offset).lineNumber;

    if (curTokens.isEmpty) {
      curTokens.add(token);
      curLines.add(line);
    } else if (line == curLines.last + 1) {
      curTokens.add(token);
      curLines.add(line);
    } else {
      regions.add(DocCommentRegion(List.of(curTokens), List.of(curLines)));
      curTokens = [token];
      curLines = [line];
    }
  }

  if (curTokens.isNotEmpty) {
    regions.add(DocCommentRegion(List.of(curTokens), List.of(curLines)));
  }

  return regions;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 步骤 3：为每个 Region 生成合并后的替换文本
// ═══════════════════════════════════════════════════════════════════════════════

bool _isBlankDocCommentLine(Token t) => t.lexeme.substring(3).trim().isEmpty;

String _extractCommentContent(Token t) => t.lexeme.substring(3).trimLeft();

String _extractRawCommentContent(Token t) {
  final rest = t.lexeme.substring(3);
  if (rest.startsWith(' ')) {
    return rest.substring(1);
  }
  return rest;
}

bool _isFenceMarker(String content) => content.trimLeft().startsWith('```');

// ─────────────────────────────────────────────────────────────────────────────
// Markdown 语法元素识别
// ─────────────────────────────────────────────────────────────────────────────

final RegExp _orderedListPattern = RegExp(r'^\d+[.)]\s');
final RegExp _unorderedListPattern = RegExp(r'^[-+*]\s');

final List<RegExp> _markdownBlockPatterns = [
  // ATX 标题
  RegExp(r'^#{1,6}(\s|$)'),
  // Setext 标题下划线
  RegExp(r'^[=\-]{2,}\s*$'),
  // 有序 / 无序（含任务）列表
  _orderedListPattern,
  _unorderedListPattern,
  // 块引用
  RegExp(r'^>'),
  // 水平分割线
  RegExp(r'^(\s*[-*_]){3,}\s*$'),
  // HTML 块标签
  RegExp(
    r'^<(address|article|aside|blockquote|canvas|dd|details|dialog|div|'
    r'dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hgroup|'
    r'hr|li|main|nav|noscript|ol|p|pre|script|section|summary|table|'
    r'tbody|td|template|tfoot|th|thead|title|tr|ul|video)'
    r'(\s|>|/>|$)',
    caseSensitive: false,
  ),
  // 表格行
  RegExp(r'^\|'),
  RegExp(r'\|.*\|'),
  // 定义列表
  RegExp(r'^:\s'),
];

bool _isMarkdownBlockElement(String content) {
  final trimmed = content.trimLeft();
  final leadingSpaces = content.length - trimmed.length;
  if (leadingSpaces > 3) return false;

  for (final pattern in _markdownBlockPatterns) {
    if (pattern.hasMatch(trimmed)) return true;
  }
  return false;
}

bool _isListItemLine(String content) {
  final trimmed = content.trimLeft();
  final leadingSpaces = content.length - trimmed.length;
  if (leadingSpaces > 3) return false;

  return _orderedListPattern.hasMatch(trimmed) ||
      _unorderedListPattern.hasMatch(trimmed);
}

// ─────────────────────────────────────────────────────────────────────────────

int _lineStartOffset(String source, int tokenOffset) {
  int i = tokenOffset - 1;
  while (i >= 0 && source[i] != '\n') {
    i--;
  }
  return i + 1;
}

String _extractIndent(String source, int tokenOffset) {
  final lineStart = _lineStartOffset(source, tokenOffset);
  final buffer = StringBuffer();
  for (int j = lineStart; j < tokenOffset; j++) {
    final ch = source[j];
    if (ch == ' ' || ch == '\t') {
      buffer.write(ch);
    } else {
      break;
    }
  }
  return buffer.toString();
}

// 段落片段类型
sealed class _Segment {}

class _TextSegment extends _Segment {
  final List<Token> tokens;
  _TextSegment(this.tokens);
}

class _BlankSegment extends _Segment {}

class _FenceSegment extends _Segment {
  final List<Token> tokens;
  _FenceSegment(this.tokens);
}

class _MarkdownBlockSegment extends _Segment {
  final Token token;
  _MarkdownBlockSegment(this.token);
}

class _ListItemSegment extends _Segment {
  final List<Token> tokens;
  _ListItemSegment(this.tokens);
}

/// 将一个 region 的 token 列表切分为若干 [_Segment]。
List<_Segment> _segmentRegion(List<Token> tokens) {
  final segments = <_Segment>[];
  var currentParagraph = <Token>[];

  void flushParagraph() {
    if (currentParagraph.isNotEmpty) {
      segments.add(_TextSegment(List.of(currentParagraph)));
      currentParagraph = [];
    }
  }

  var i = 0;
  while (i < tokens.length) {
    final token = tokens[i];
    final raw = _extractRawCommentContent(token);

    // 优先级 1：围栏代码块起始
    if (_isFenceMarker(raw)) {
      flushParagraph();

      final fenceTokens = <Token>[token];
      var j = i + 1;
      while (j < tokens.length) {
        final innerRaw = _extractRawCommentContent(tokens[j]);
        fenceTokens.add(tokens[j]);
        if (_isFenceMarker(innerRaw)) {
          j++;
          break;
        }
        j++;
      }
      segments.add(_FenceSegment(fenceTokens));
      i = j;
      continue;
    }

    // 优先级 2：纯空行注释
    if (_isBlankDocCommentLine(token)) {
      flushParagraph();
      segments.add(_BlankSegment());
      i++;
      continue;
    }

    // 优先级 3：列表项（含续行合并）
    if (_isListItemLine(raw)) {
      flushParagraph();

      final listTokens = <Token>[token];
      var j = i + 1;
      while (j < tokens.length) {
        final nextToken = tokens[j];
        final nextRaw = _extractRawCommentContent(nextToken);

        if (_isBlankDocCommentLine(nextToken) ||
            _isFenceMarker(nextRaw) ||
            _isMarkdownBlockElement(nextRaw)) {
          break;
        }

        listTokens.add(nextToken);
        j++;
      }
      segments.add(_ListItemSegment(listTokens));
      i = j;
      continue;
    }

    // 优先级 4：其它 Markdown 块级元素
    if (_isMarkdownBlockElement(raw)) {
      flushParagraph();
      segments.add(_MarkdownBlockSegment(token));
      i++;
      continue;
    }

    // 优先级 5：普通文本
    currentParagraph.add(token);
    i++;
  }

  flushParagraph();
  return segments;
}

/// 为一个 [DocCommentRegion] 生成合并/拆分后的替换字符串。
String buildReplacement(
  DocCommentRegion region,
  String source, {
  _MergeStats? stats,
}) {
  final indent = _extractIndent(source, region.firstOffset);

  final segments = _segmentRegion(region.tokens);

  final outputLines = <String>[];
  for (final segment in segments) {
    switch (segment) {
      case _BlankSegment():
        outputLines.add('');

      case _TextSegment(tokens: final paragraphTokens):
        final parts = paragraphTokens
            .map(_extractCommentContent)
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isEmpty) continue;
        if (stats != null && paragraphTokens.length > 1) {
          stats.merges++;
        }
        final merged = parts.join(' ');
        outputLines.add('$indent/// $merged');

      case _ListItemSegment(tokens: final listTokens):
        final parts = listTokens
            .map(_extractCommentContent)
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isEmpty) continue;
        if (stats != null && listTokens.length > 1) {
          stats.merges++;
        }
        final merged = parts.join(' ');
        outputLines.add('$indent/// $merged');

      case _FenceSegment(tokens: final fenceTokens):
        for (final t in fenceTokens) {
          final raw = _extractRawCommentContent(t);
          if (raw.isEmpty) {
            outputLines.add('$indent///');
          } else {
            outputLines.add('$indent/// $raw');
          }
        }

      case _MarkdownBlockSegment(token: final t):
        final raw = _extractRawCommentContent(t);
        if (raw.isEmpty) {
          outputLines.add('$indent///');
        } else {
          outputLines.add('$indent/// $raw');
        }
    }
  }

  while (outputLines.isNotEmpty && outputLines.first.isEmpty) {
    outputLines.removeAt(0);
  }
  while (outputLines.isNotEmpty && outputLines.last.isEmpty) {
    outputLines.removeLast();
  }

  return outputLines.join('\n');
}

// ═══════════════════════════════════════════════════════════════════════════════
// 步骤 4：将所有替换应用到源文本（从后往前，避免 offset 失效）
// ═══════════════════════════════════════════════════════════════════════════════

String applyReplacements(
  String source,
  List<DocCommentRegion> regions, {
  _MergeStats? stats,
}) {
  if (regions.isEmpty) return source;

  final sorted = List.of(regions)
    ..sort((a, b) => b.firstOffset.compareTo(a.firstOffset));

  var result = source;
  for (final region in sorted) {
    if (region.tokens.length <= 1) {
      continue;
    }

    final replacement = buildReplacement(region, result, stats: stats);

    final rangeStart = _lineStartOffset(result, region.firstOffset);
    final rangeEnd = region.lastEnd;

    result =
        result.substring(0, rangeStart) +
        replacement +
        result.substring(rangeEnd);
  }

  return result;
}
