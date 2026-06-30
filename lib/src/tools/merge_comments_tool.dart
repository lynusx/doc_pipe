import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:doc_pipe/src/cli/dart_file_tool.dart';

class MergeCommentsTool extends DartFileTool {
  @override
  String get name => 'merge_comments';

  @override
  String get description =>
      '将 /// 块内连续多行的同一段落合并为一行，段落间空行注释转换为普通空行。'
      '代码块内容原样保留，Markdown 块级元素单行保留。';

  @override
  List<UsageExample> get examples => const [
    UsageExample(
      '处理单个文件（覆写原文件）',
      'dart run bin/merge_comments.dart lib/my_widget.dart',
    ),
    UsageExample(
      '递归处理整个 lib/ 目录（覆写原文件）',
      'dart run bin/merge_comments.dart lib/',
    ),
    UsageExample(
      '递归处理目录，输出到另一个目录',
      'dart run bin/merge_comments.dart lib/ --output=out/lib/',
    ),
    UsageExample(
      '预览将要变更的文件（不写磁盘）',
      'dart run bin/merge_comments.dart lib/ --dry-run',
    ),
  ];

  @override
  AnalysisNeed get analysisNeed => AnalysisNeed.resolved;

  @override
  Future<FileChange> transform(SourceFile input) async {
    final result = input.resolvedUnit as ResolvedUnitResult;
    final source = input.text;
    final fileStats = _FileChangeStats();

    final docTokens = _collectDocCommentTokens(result.unit.beginToken);
    final regions = _groupTokensIntoRegions(docTokens, result.unit.lineInfo);
    final transformed = _applyReplacements(source, regions, stats: fileStats);

    if (transformed == source) return FileChange.unchanged();

    return FileChange(
      newContent: transformed,
      stats: ChangeStats(merges: fileStats.merges),
      outcome: FileOutcome.changed,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 以下为原 merge_comments.dart 的核心逻辑，原样搬运
// ══════════════════════════════════════════════════════════════════════════════

class _DocCommentRegion {
  final List<Token> tokens;
  final List<int> lineNumbers;

  _DocCommentRegion(this.tokens, this.lineNumbers)
    : assert(tokens.length == lineNumbers.length),
      assert(tokens.isNotEmpty);

  int get firstOffset => tokens.first.offset;
  int get lastEnd => tokens.last.end;
}

class _FileChangeStats {
  int merges = 0;
}

List<Token> _collectDocCommentTokens(Token firstToken) {
  final result = <Token>[];
  Token? current = firstToken;
  while (current != null && current.type != TokenType.EOF) {
    _collectPrecedingDocComments(current, result);
    current = current.next;
  }

  if (current != null) _collectPrecedingDocComments(current, result);
  result.sort((a, b) => a.offset.compareTo(b.offset));
  return result;
}

void _collectPrecedingDocComments(Token token, List<Token> out) {
  Token? comment = token.precedingComments;
  while (comment != null) {
    if (_isDocCommentToken(comment)) out.add(comment);
    comment = comment.next;
  }
}

bool _isDocCommentToken(Token t) =>
    t.type == TokenType.SINGLE_LINE_COMMENT && t.lexeme.startsWith('///');

List<_DocCommentRegion> _groupTokensIntoRegions(
  List<Token> docTokens,
  LineInfo lineInfo,
) {
  if (docTokens.isEmpty) return const [];
  final regions = <_DocCommentRegion>[];
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
      regions.add(_DocCommentRegion(List.of(curTokens), List.of(curLines)));
      curTokens = [token];
      curLines = [line];
    }
  }
  if (curTokens.isNotEmpty) {
    regions.add(_DocCommentRegion(List.of(curTokens), List.of(curLines)));
  }
  return regions;
}

bool _isBlankDocCommentLine(Token t) => t.lexeme.substring(3).trim().isEmpty;

String _extractCommentContent(Token t) => t.lexeme.substring(3).trimLeft();

String _extractRawCommentContent(Token t) {
  final rest = t.lexeme.substring(3);
  return rest.startsWith(' ') ? rest.substring(1) : rest;
}

bool _isFenceMarker(String content) => content.trimLeft().startsWith('```');

final RegExp _orderedListPattern = RegExp(r'^\d+[.)]\s');
final RegExp _unorderedListPattern = RegExp(r'^[-+*]\s');

final List<RegExp> _markdownBlockPatterns = [
  RegExp(r'^#{1,6}(\s|$)'),
  RegExp(r'^[=\-]{2,}\s*$'),
  _orderedListPattern,
  _unorderedListPattern,
  RegExp(r'^>'),
  RegExp(r'^(\s*[-*_]){3,}\s*$'),
  RegExp(
    r'^<(address|article|aside|blockquote|canvas|dd|details|dialog|div|'
    r'dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hgroup|'
    r'hr|li|main|nav|noscript|ol|p|pre|script|section|summary|table|'
    r'tbody|td|template|tfoot|th|thead|title|tr|ul|video)'
    r'(\s|>|/>|$)',
    caseSensitive: false,
  ),
  RegExp(r'^\|'),
  RegExp(r'\|.*\|'),
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

    if (_isBlankDocCommentLine(token)) {
      flushParagraph();
      segments.add(_BlankSegment());
      i++;
      continue;
    }

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

    if (_isMarkdownBlockElement(raw)) {
      flushParagraph();
      segments.add(_MarkdownBlockSegment(token));
      i++;
      continue;
    }

    currentParagraph.add(token);
    i++;
  }

  flushParagraph();
  return segments;
}

String _buildReplacement(
  _DocCommentRegion region,
  String source, {
  _FileChangeStats? stats,
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
        if (stats != null && paragraphTokens.length > 1) stats.merges++;
        outputLines.add('$indent/// ${parts.join(' ')}');

      case _ListItemSegment(tokens: final listTokens):
        final parts = listTokens
            .map(_extractCommentContent)
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isEmpty) continue;
        if (stats != null && listTokens.length > 1) stats.merges++;
        outputLines.add('$indent/// ${parts.join(' ')}');

      case _FenceSegment(tokens: final fenceTokens):
        for (final t in fenceTokens) {
          final raw = _extractRawCommentContent(t);
          outputLines.add(raw.isEmpty ? '$indent///' : '$indent/// $raw');
        }

      case _MarkdownBlockSegment(token: final t):
        final raw = _extractRawCommentContent(t);
        outputLines.add(raw.isEmpty ? '$indent///' : '$indent/// $raw');
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

String _applyReplacements(
  String source,
  List<_DocCommentRegion> regions, {
  _FileChangeStats? stats,
}) {
  if (regions.isEmpty) return source;
  final sorted = List.of(regions)
    ..sort((a, b) => b.firstOffset.compareTo(a.firstOffset));

  var result = source;
  for (final region in sorted) {
    if (region.tokens.length <= 1) continue;
    final replacement = _buildReplacement(region, result, stats: stats);
    final rangeStart = _lineStartOffset(result, region.firstOffset);
    final rangeEnd = region.lastEnd;
    result =
        result.substring(0, rangeStart) +
        replacement +
        result.substring(rangeEnd);
  }
  return result;
}
