// bin/merge_comments.dart
//
// 用法：dart run merge.dart <path> [options]
//
// 功能：
//   解析 Dart 源文件，将文档注释（///）块内连续多行的同一段落合并为一行，
//   段落之间的纯空行注释（///）转换为普通空行。
//   代码块（``` ... ```）内的内容原样保留，不合并、不删除空行。
//
//   Markdown 语法元素所在行原样保留，不与相邻行合并，包括：
//   - ATX 标题（# ~ ######）
//   - Setext 标题下划线（=== 或 ---）
//   - 块引用（> 开头）
//   - 水平分割线（--- *** ___ 纯分隔线）
//   - HTML 块标签（<tag> 开头）
//   - 表格行（| 开头或含 | 分隔符）
//   - 定义列表（: 开头）
//
//   有序列表 / 无序列表 / 任务列表（数字加点、- + * 开头、- [ ] 或 - [x]）：
//   同属一个列表项的多行会被合并为一行——即列表标记行之后，
//   直到遇到空行、新的列表项或其它 Markdown 块级元素为止的所有"续行"，
//   都会拼接到该列表项内；不同列表项之间不会被合并。
//
//   若 <path> 为目录，则递归处理其下所有 .dart 文件（跳过隐藏目录）。
//
// 依赖（pubspec.yaml）：
//   analyzer: ^6.4.1
//   args:     ^2.7.0
//   path:     ^1.9.1

import 'dart:io';
import 'package:args/args.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

// ═══════════════════════════════════════════════════════════════════════════════
// 数据结构
// ═══════════════════════════════════════════════════════════════════════════════

/// 源文件中一段连续的 `///` 注释行序列。
///
/// "连续"定义：相邻两个 `///` token 所在行号相差恰好为 1。
/// 这意味着 `///` 与 `///` 之间不能有非 `///` 行（否则形成两个 region）。
class DocCommentRegion {
  final List<Token> tokens; // 该区域内所有 `///` token（升序）
  final List<int> lineNumbers; // 对应的 1-based 行号

  DocCommentRegion(this.tokens, this.lineNumbers)
    : assert(tokens.length == lineNumbers.length),
      assert(tokens.isNotEmpty);

  int get firstOffset => tokens.first.offset;
  int get lastEnd => tokens.last.end;
}

// ─────────────────────────────────────────────────────────────────────────────
// Dry-run 操作统计
// ─────────────────────────────────────────────────────────────────────────────

/// 单个文件在 dry-run 模式下的操作统计数据。
///
/// 当前工具仅执行注释行合并（merge）操作；其余字段预留扩展用。
class FileChangeStats {
  int merges;
  int inserts;
  int deletes;
  int modifies;
  int skips;

  FileChangeStats({
    this.merges = 0,
    this.inserts = 0,
    this.deletes = 0,
    this.modifies = 0,
    this.skips = 0,
  });

  /// 是否有任何变更。
  bool get hasChanges =>
      merges > 0 || inserts > 0 || deletes > 0 || modifies > 0 || skips > 0;

  /// 生成操作统计描述字符串，例如 `5 merges` 或 `3 inserts, 2 deletes`。
  /// 若无变更，返回 `no changes`。
  String describe() {
    if (!hasChanges) return 'no changes';

    final parts = <String>[];

    void addPart(int count, String singular, String plural) {
      if (count > 0) {
        parts.add('$count ${count == 1 ? singular : plural}');
      }
    }

    addPart(merges, 'merge', 'merges');
    addPart(inserts, 'insert', 'inserts');
    addPart(deletes, 'delete', 'deletes');
    addPart(modifies, 'modify', 'modifies');
    addPart(skips, 'skip', 'skips');

    return parts.join(', ');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dry-run 日志输出
// ─────────────────────────────────────────────────────────────────────────────

/// 向 stdout 输出一条统一格式的 dry-run 日志行。
///
/// 格式：`[dry-run]  (√/×) <path> (<stats-or-error>)`
///
/// [path]    文件绝对路径或相对路径。
/// [success] `true` 表示处理成功，使用 `(√)`；`false` 表示失败，使用 `(×)`。
/// [detail]  括号内的统计描述或错误摘要，例如 `5 merges`、`parse error`。
void _dryRunLog(String path, {required bool success, required String detail}) {
  final mark = success ? '(√)' : '(×)';
  stdout.writeln('[dry-run]  $mark $path ($detail)');
}

// ═══════════════════════════════════════════════════════════════════════════════
// 步骤 1：从 token stream 中收集所有文档注释 token
// ═══════════════════════════════════════════════════════════════════════════════

/// 遍历 token stream，返回所有 `///` 类型的注释 token（按 offset 升序）。
///
/// `package:analyzer` 将注释存储在"真正"token 的 [Token.precedingComments]
/// 单链表中，并非 AST 节点树的直接子节点。
/// 我们遍历整个 token stream，对每个 token 枚举其 precedingComments。
List<Token> collectDocCommentTokens(Token firstToken) {
  final result = <Token>[];

  Token? current = firstToken;
  while (current != null && current.type != TokenType.EOF) {
    _collectPrecedingDocComments(current, result);
    current = current.next;
  }

  // EOF token 本身也可能挂有注释（文件末尾的孤立注释块）
  if (current != null) {
    _collectPrecedingDocComments(current, result);
  }

  // 保险起见按 offset 排序（通常 token stream 已有序）
  result.sort((a, b) => a.offset.compareTo(b.offset));
  return result;
}

/// 提取 [token] 的 precedingComments 链表中所有文档注释，追加到 [out]。
void _collectPrecedingDocComments(Token token, List<Token> out) {
  // precedingComments 是 CommentToken?，.next 在 analyzer v6 中返回 Token?
  Token? comment = token.precedingComments;
  while (comment != null) {
    if (_isDocCommentToken(comment)) {
      out.add(comment);
    }
    // CommentToken.next 在 v6+ 返回 Token?，需要安全转型
    comment = comment.next;
  }
}

/// 判断 token 是否为文档注释（`///` 开头的单行注释）。
bool _isDocCommentToken(Token t) {
  return t.type == TokenType.SINGLE_LINE_COMMENT && t.lexeme.startsWith('///');
}

// ═══════════════════════════════════════════════════════════════════════════════
// 步骤 2：按连续行号分组为 DocCommentRegion
// ═══════════════════════════════════════════════════════════════════════════════

/// 将扁平的文档注释 token 列表，按行号连续性分组为若干 [DocCommentRegion]。
List<DocCommentRegion> groupTokensIntoRegions(
  List<Token> docTokens,
  LineInfo lineInfo,
) {
  if (docTokens.isEmpty) return const [];

  final regions = <DocCommentRegion>[];
  var curTokens = <Token>[];
  var curLines = <int>[];

  for (final token in docTokens) {
    // getLocation 返回 CharacterLocation，lineNumber 是 1-based
    final line = lineInfo.getLocation(token.offset).lineNumber;

    if (curTokens.isEmpty) {
      curTokens.add(token);
      curLines.add(line);
    } else if (line == curLines.last + 1) {
      // 与上一个 token 相邻行 → 同一 region
      curTokens.add(token);
      curLines.add(line);
    } else {
      // 不连续 → 提交当前 region，开始新的
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

/// 判断 `///` token 是否为纯空行注释（`///` 后只有空白或无内容）。
bool _isBlankDocCommentLine(Token t) {
  return t.lexeme.substring(3).trim().isEmpty;
}

/// 提取 `///` token 的文本内容（去掉 `///` 前缀及其后的前导空格）。
String _extractCommentContent(Token t) {
  return t.lexeme.substring(3).trimLeft();
}

/// 提取 `///` token 的"原始"文本内容，仅去掉 `///` 前缀本身，
/// 不去除内容前的空格（用于代码块内逐行原样保留时维持原有缩进/对齐）。
///
/// 注意：`///` 与正文之间通常恰好有一个空格（如 `/// foo`），
/// 这个空格被视为注释标记的一部分而非内容，因此仅去除这一个空格（如果存在）。
String _extractRawCommentContent(Token t) {
  final rest = t.lexeme.substring(3);
  if (rest.startsWith(' ')) {
    return rest.substring(1);
  }
  return rest;
}

/// 判断字符串内容是否为围栏代码块的起始/结束标记（``` 开头，可带语言名/属性）。
///
/// 兼容 `///```` 和 `/// ``` ` 两种写法（即 `///` 与标记之间有无空格均可），
/// 语言名大小写不敏感（如 `dart`、`DART`、`Dart` 均可识别）。
bool _isFenceMarker(String content) {
  return content.trimLeft().startsWith('```');
}

// ─────────────────────────────────────────────────────────────────────────────
// Markdown 语法元素识别
// ─────────────────────────────────────────────────────────────────────────────

/// 有序列表项标记：数字 + `.` 或 `)` + 空格（或行尾，如 `1. `、`2) `）。
final RegExp _orderedListPattern = RegExp(r'^\d+[.)]\s');

/// 无序列表项标记（含任务列表）：- / + / * + 空格（或行尾）。
/// 任务列表 `- [ ] ` 和 `- [x] ` 也会被此规则覆盖。
final RegExp _unorderedListPattern = RegExp(r'^[-+*]\s');

/// 所有需要原样保留（不与相邻行合并）的 Markdown 块级语法元素的正则表达式。
///
/// 匹配规则均针对 `///` 之后的内容（已去掉 `///` 前缀及紧随的一个空格）。
/// 即传入的 [content] 为 [_extractRawCommentContent] 的返回值。
///
/// 包含的元素类型：
/// - ATX 标题：# / ## / ### / #### / ##### / ######
/// - Setext 标题下划线：仅由 `=` 或 `-` 组成（至少 2 个字符）
/// - 有序列表 / 无序列表 / 任务列表：见 [_orderedListPattern]、[_unorderedListPattern]
/// - 块引用：`>` 开头
/// - 水平分割线：仅由 `---`、`***`、`___`（至少 3 个，可含空格）组成
/// - HTML 块标签：`<` 开头并匹配常见块级标签或自闭合标签
/// - 表格行：`|` 开头，或包含至少两个 `|` 的行
/// - 定义列表（PHP Markdown Extra 风格）：`:` 后跟空格
final List<RegExp> _markdownBlockPatterns = [
  // ATX 标题：# 到 ######，`///` 和 # 之间可以有空格也可以没有
  RegExp(r'^#{1,6}(\s|$)'),

  // Setext 标题下划线：整行仅由 = 或 - 组成（至少 2 个），可含空格
  RegExp(r'^[=\-]{2,}\s*$'),

  // 有序列表 / 无序列表（含任务列表）
  _orderedListPattern,
  _unorderedListPattern,

  // 块引用
  RegExp(r'^>'),

  // 水平分割线：整行仅由 ---、***、___ 组成（可含内部空格，至少 3 个字符）
  RegExp(r'^(\s*[-*_]){3,}\s*$'),

  // HTML 块标签（常见块级元素，开标签或自闭合标签）
  RegExp(
    r'^<(address|article|aside|blockquote|canvas|dd|details|dialog|div|'
    r'dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hgroup|'
    r'hr|li|main|nav|noscript|ol|p|pre|script|section|summary|table|'
    r'tbody|td|template|tfoot|th|thead|title|tr|ul|video)'
    r'(\s|>|/>|$)',
    caseSensitive: false,
  ),

  // 表格行：以 | 开头，或行内包含至少两个 |（分隔列）
  RegExp(r'^\|'),
  RegExp(r'\|.*\|'),

  // 定义列表（PHP Markdown Extra）：行首 `: ` 开头
  RegExp(r'^:\s'),
];

/// 判断给定的注释内容（已去掉 `///` 前缀）是否为 Markdown 块级语法元素行。
///
/// [content] 为 [_extractRawCommentContent] 的返回值（可含前导空格）。
/// 匹配前先去除内容最左侧的空格（CommonMark 允许块元素前有 0~3 个空格缩进）。
bool _isMarkdownBlockElement(String content) {
  // CommonMark 规范：块级元素前最多允许 3 个空格的缩进
  // 超过 3 个空格的缩进视为代码块，不做特殊处理
  final trimmed = content.trimLeft();
  final leadingSpaces = content.length - trimmed.length;
  if (leadingSpaces > 3) return false;

  for (final pattern in _markdownBlockPatterns) {
    if (pattern.hasMatch(trimmed)) return true;
  }
  return false;
}

/// 判断给定的注释内容（已去掉 `///` 前缀）是否为列表项标记行
/// （有序列表、无序列表或任务列表的起始行）。
///
/// 与 [_isMarkdownBlockElement] 共用同样的缩进限制（最多 3 个空格），
/// 用于在 [_segmentRegion] 中识别"新列表项的开始"，
/// 从而把它和它自身的续行聚合为一个 [_ListItemSegment]。
bool _isListItemLine(String content) {
  final trimmed = content.trimLeft();
  final leadingSpaces = content.length - trimmed.length;
  if (leadingSpaces > 3) return false;

  return _orderedListPattern.hasMatch(trimmed) ||
      _unorderedListPattern.hasMatch(trimmed);
}

// ─────────────────────────────────────────────────────────────────────────────

/// 计算 [source] 中 [tokenOffset] 位置所在行的行首 offset。
int _lineStartOffset(String source, int tokenOffset) {
  int i = tokenOffset - 1;
  while (i >= 0 && source[i] != '\n') {
    i--;
  }
  return i + 1; // '\n' 的下一位，或 0（文件开头）
}

/// 返回 [tokenOffset] 所在行、token 之前的纯空白前缀（即缩进字符串）。
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

/// 段落片段类型：
/// - text：普通文本段落，内部多行需合并为一行
/// - blank：单个空行（来自纯空行 `///` 注释）
/// - fence：围栏代码块（``` ... ```），内部逐行原样保留，不合并、不去除空行
/// - markdownBlock：单个 Markdown 块级语法元素行，原样输出，不与相邻行合并
sealed class _Segment {}

class _TextSegment extends _Segment {
  final List<Token> tokens;
  _TextSegment(this.tokens);
}

class _BlankSegment extends _Segment {}

class _FenceSegment extends _Segment {
  final List<Token> tokens; // 包含起始 ``` 行和结束 ``` 行
  _FenceSegment(this.tokens);
}

/// 单个 Markdown 块级语法元素行（原样输出，不参与段落合并）。
class _MarkdownBlockSegment extends _Segment {
  final Token token;
  _MarkdownBlockSegment(this.token);
}

/// 一个列表项（有序/无序/任务列表）及其所有续行。
///
/// 第一个 token 是列表标记行（如 `1. foo` 或 `- bar`），
/// 其余 token 是属于同一列表项的"续行"——即标记行之后，
/// 直到遇到空行、新的列表项或其它 Markdown 块级元素为止的连续行。
/// 整个列表项最终会被合并为一行输出。
class _ListItemSegment extends _Segment {
  final List<Token> tokens;
  _ListItemSegment(this.tokens);
}

/// 将一个 region 的 token 列表切分为若干 [_Segment]：
/// 文本段落、空行、围栏代码块、列表项、Markdown 块级元素行。
///
/// 优先级（从高到低）：
/// 1. 围栏代码块（``` ... ```）：整块原样保留
/// 2. 纯空行注释（`///` 后无内容）：转为段落间空行
/// 3. 列表项（有序/无序/任务列表）：标记行 + 其后的续行合并为一行，
///    不同列表项之间不合并
/// 4. 其它 Markdown 块级语法元素：单行原样保留，不与相邻行合并
/// 5. 普通文本行：归入当前文本段落，最终合并为一行
///
/// 围栏代码块的识别：一行内容（去除 `///` 前缀及紧随其后的一个空格）
/// 以 ``` 开头，视为代码块边界。第一次遇到视为开始，
/// 之后再次遇到以 ``` 开头的行视为结束（区间为闭区间，包含首尾两行）。
/// 若代码块未闭合（文件结尾前没有匹配的结束 ```），则将其后所有行都视为代码块内容。
///
/// 列表项续行的识别：列表标记行之后，只要后续行不是空行、不是围栏标记，
/// 也不是任何 Markdown 块级元素（包括新的列表项），就视为该列表项的续行，
/// 与标记行一起合并为一行；一旦遇到上述任一情况，续行收集即终止。
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

    // ── 优先级 1：围栏代码块起始 ──────────────────────────────────────────
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

    // ── 优先级 2：纯空行注释 ───────────────────────────────────────────────
    if (_isBlankDocCommentLine(token)) {
      flushParagraph();
      segments.add(_BlankSegment());
      i++;
      continue;
    }

    // ── 优先级 3：列表项（有序/无序/任务列表），含续行合并 ──────────────────
    if (_isListItemLine(raw)) {
      flushParagraph();

      final listTokens = <Token>[token];
      var j = i + 1;
      while (j < tokens.length) {
        final nextToken = tokens[j];
        final nextRaw = _extractRawCommentContent(nextToken);

        // 空行 / 围栏标记 / 任意 Markdown 块级元素（含新列表项）→ 续行结束
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

    // ── 优先级 4：其它 Markdown 块级语法元素 ─────────────────────────────
    if (_isMarkdownBlockElement(raw)) {
      // Markdown 块级元素独占一行：先结束当前文本段落，再单独输出，再继续
      flushParagraph();
      segments.add(_MarkdownBlockSegment(token));
      i++;
      continue;
    }

    // ── 优先级 5：普通文本，归入当前段落 ──────────────────────────────────
    currentParagraph.add(token);
    i++;
  }

  flushParagraph();
  return segments;
}

/// 为一个 [DocCommentRegion] 生成合并/拆分后的替换字符串。
///
/// 规则：
/// - 纯空行注释（`///` 后无内容）→ 输出一个空行（不含 `///`）
/// - 围栏代码块（``` ... ```）内的所有行 → 原样逐行保留，
///   不合并为一行，也不把内部空行转换为段落空行
/// - 列表项（有序/无序/任务列表）→ 标记行与其续行以空格拼接，合并为一行；
///   不同列表项之间不合并
/// - 其它 Markdown 块级语法元素所在行 → 原样输出，不与相邻行合并
/// - 围栏代码块、列表项和其它 Markdown 块级元素之外的其余连续行
///   → 内容以空格拼接，合并为一行 `/// ...`
/// - 每个 region 可能被多个空行注释切分为多个段落，段落间以空行分隔
/// - 缩进与第一个 token 所在行的缩进一致
///
/// [source] 是当前（可能已被之前替换改写的）文件内容，用于提取缩进。
/// [stats]  若不为 null，则在本次构建过程中记录实际执行了多少次合并操作。
String buildReplacement(
  DocCommentRegion region,
  String source, {
  FileChangeStats? stats,
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
        // 超过 1 个 token 的文本段落会被合并 → 计为一次 merge
        if (stats != null && paragraphTokens.length > 1) {
          stats.merges++;
        }
        final merged = parts.join(' ');
        outputLines.add('$indent/// $merged');

      case _ListItemSegment(tokens: final listTokens):
        // 列表标记行 + 续行：内容以空格拼接，合并为一行
        final parts = listTokens
            .map(_extractCommentContent)
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isEmpty) continue;
        // 超过 1 个 token 的列表项（含续行）会被合并 → 计为一次 merge
        if (stats != null && listTokens.length > 1) {
          stats.merges++;
        }
        final merged = parts.join(' ');
        outputLines.add('$indent/// $merged');

      case _FenceSegment(tokens: final fenceTokens):
        // 原样逐行输出：每个 token 还原为 `///` + 原始内容（保留内部空白/缩进）
        for (final t in fenceTokens) {
          final raw = _extractRawCommentContent(t);
          if (raw.isEmpty) {
            outputLines.add('$indent///');
          } else {
            outputLines.add('$indent/// $raw');
          }
        }

      case _MarkdownBlockSegment(token: final t):
        // Markdown 块级元素：原样还原该行，不与任何相邻行合并
        final raw = _extractRawCommentContent(t);
        if (raw.isEmpty) {
          outputLines.add('$indent///');
        } else {
          outputLines.add('$indent/// $raw');
        }
    }
  }

  // 去除首尾多余空行（region 首/末为空行注释时产生）
  while (outputLines.isNotEmpty && outputLines.first.isEmpty) {
    outputLines.removeAt(0);
  }
  while (outputLines.isNotEmpty && outputLines.last.isEmpty) {
    outputLines.removeLast();
  }

  return outputLines.join('\n');
}

// ═══════════════════════════════════════════════════════════════════════════════
// 步骤 4：将所有替换应用到源文本
// ═══════════════════════════════════════════════════════════════════════════════

/// 对 [source] 应用所有 [regions] 对应的文本替换，返回新的源文本。
///
/// 单行 doc comment region（只有 1 个 token）按规则原样保留，跳过。
/// 替换从后往前进行，避免 offset 失效。
///
/// 替换范围 = [该 region 第一个 token 所在行的行首 offset, 最后一个 token 的 end)
/// 这样可以把行首缩进一并替换掉，由 [buildReplacement] 重新输出正确缩进。
///
/// [stats] 若不为 null，则累计记录各类操作次数，用于 dry-run 统计输出。
String applyReplacements(
  String source,
  List<DocCommentRegion> regions, {
  FileChangeStats? stats,
}) {
  if (regions.isEmpty) return source;

  // 按起始 offset 降序，从后往前替换
  final sorted = List.of(regions)
    ..sort((a, b) => b.firstOffset.compareTo(a.firstOffset));

  var result = source;
  for (final region in sorted) {
    if (region.tokens.length <= 1) {
      // 单行 doc comment → 原样保留
      continue;
    }

    final replacement = buildReplacement(region, result, stats: stats);

    // 替换范围：从行首到 region 最后一个 token 的 end
    final rangeStart = _lineStartOffset(result, region.firstOffset);
    final rangeEnd = region.lastEnd;

    result =
        result.substring(0, rangeStart) +
        replacement +
        result.substring(rangeEnd);
  }

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 主流程：解析文件 + 执行转换
// ═══════════════════════════════════════════════════════════════════════════════

/// 读取 [inputPath] 文件，执行文档注释合并处理，返回处理后的源文本及操作统计。
///
/// 返回值为 `(transformed: String, stats: FileChangeStats)` 具名记录。
Future<({String transformed, FileChangeStats stats})> processFile(
  String inputPath,
) async {
  final absolutePath = p.canonicalize(inputPath);
  final file = File(absolutePath);

  if (!await file.exists()) {
    throw FileSystemException('输入文件不存在', absolutePath);
  }

  final source = await file.readAsString();
  final fileStats = FileChangeStats();

  // 创建 analyzer 分析上下文
  // includedPaths 必须使用绝对路径
  final collection = AnalysisContextCollection(includedPaths: [absolutePath]);
  final context = collection.contextFor(absolutePath);
  final session = context.currentSession;

  // 获取完整的 resolved unit（包含类型信息，但我们只需要 token stream 和 lineInfo）
  // 若文件有语法错误，仍可获取 parse result；如需容错可改用 getParsedUnit
  final result = await session.getResolvedUnit(absolutePath);

  if (result is! ResolvedUnitResult) {
    // 回退：尝试仅解析（不做类型检查）
    final parseResult = session.getParsedUnit(absolutePath);
    if (parseResult is! ParsedUnitResult) {
      throw StateError('无法解析文件，请检查文件内容是否为有效的 Dart 源码');
    }
    final unit = parseResult.unit;
    final docTokens = collectDocCommentTokens(unit.beginToken);
    final regions = groupTokensIntoRegions(docTokens, unit.lineInfo);
    final transformed = applyReplacements(source, regions, stats: fileStats);
    return (transformed: transformed, stats: fileStats);
  }

  final unit = result.unit;
  final docTokens = collectDocCommentTokens(unit.beginToken);
  final regions = groupTokensIntoRegions(docTokens, unit.lineInfo);
  final transformed = applyReplacements(source, regions, stats: fileStats);
  return (transformed: transformed, stats: fileStats);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 收集 .dart 文件（始终递归）
// ═══════════════════════════════════════════════════════════════════════════════

/// 递归扫描 [dirPath] 目录，返回所有 `.dart` 文件的绝对路径列表（按字典序）。
///
/// 始终跳过隐藏目录（路径片段以 `.` 开头且长度 > 1，例如 `.dart_tool`、`.git`）。
Future<List<String>> collectDartFiles(String dirPath) async {
  final dir = Directory(p.canonicalize(dirPath));
  if (!await dir.exists()) {
    throw FileSystemException('目录不存在', dir.path);
  }

  final files = <String>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    final relativeParts = p.split(p.relative(entity.path, from: dir.path));
    final insideHidden = relativeParts.any(
      (part) => part.startsWith('.') && part.length > 1,
    );
    if (insideHidden) continue;

    if (entity is File && entity.path.endsWith('.dart')) {
      files.add(entity.path);
    }
  }

  files.sort();
  return files;
}

// ═══════════════════════════════════════════════════════════════════════════════
// 批量处理目录（始终递归）
// ═══════════════════════════════════════════════════════════════════════════════

/// 递归处理 [dirPath] 下的所有 `.dart` 文件。
///
/// [outputDir]：输出根目录；`null` 时覆写原文件，否则按原相对路径写入目标目录。
/// [dryRun]：预览模式，仅统计并输出将要发生的变更，不执行任何磁盘写入。
///
/// 在 dry-run 模式下，每个文件的处理结果以统一格式输出到 stdout（单行）；
/// 真正的错误堆栈输出到 stderr。
///
/// 单个文件失败不中断批量处理，继续处理剩余文件。
/// 返回 `({int processed, int skipped, int failed})`。
Future<({int processed, int skipped, int failed})> processDirectory(
  String dirPath, {
  String? outputDir,
  bool dryRun = false,
}) async {
  final absInputDir = p.canonicalize(dirPath);
  final files = await collectDartFiles(absInputDir);

  if (files.isEmpty) {
    stderr.writeln('（未找到任何 .dart 文件）');
    return (processed: 0, skipped: 0, failed: 0);
  }

  int processed = 0, skipped = 0, failed = 0;

  for (final filePath in files) {
    try {
      final original = await File(filePath).readAsString();
      final (:transformed, :stats) = await processFile(filePath);

      if (dryRun) {
        // dry-run 模式：统一格式输出到 stdout，无论有无变更
        _dryRunLog(filePath, success: true, detail: stats.describe());
        if (transformed != original) {
          processed++;
        } else {
          skipped++;
        }
        continue;
      }

      if (transformed == original) {
        stderr.writeln('  跳过（无变化）：$filePath');
        skipped++;
        continue;
      }

      final targetPath = outputDir != null
          ? p.join(
              p.canonicalize(outputDir),
              p.relative(filePath, from: absInputDir),
            )
          : filePath;

      await Directory(p.dirname(targetPath)).create(recursive: true);
      await File(targetPath).writeAsString(transformed);
      stderr.writeln('  ✓ 已处理：$targetPath');
      processed++;
    } catch (e, stackTrace) {
      if (dryRun) {
        // dry-run 失败：统一格式输出到 stdout，错误详情输出到 stderr
        _dryRunLog(filePath, success: false, detail: _shortErrorMessage(e));
        stderr.writeln('    详细错误（$filePath）：$e');
        stderr.writeln(stackTrace);
      } else {
        stderr.writeln('  ✗ 错误（$filePath）：$e');
        stderr.writeln(stackTrace);
      }
      failed++;
    }
  }

  return (processed: processed, skipped: skipped, failed: failed);
}

/// 将任意异常转换为简短的错误摘要字符串，用于 dry-run 日志的括号内描述。
///
/// 例如：`FileSystemException` → `io error`，
///        `StateError`（含"解析"）→ `parse error`，
///        其它 → `error`。
String _shortErrorMessage(Object e) {
  if (e is FileSystemException) return 'io error';
  if (e is StateError) {
    final msg = e.message.toLowerCase();
    if (msg.contains('解析') || msg.contains('parse') || msg.contains('dart')) {
      return 'parse error';
    }
    return 'error';
  }
  if (e is FormatException) return 'parse error';
  return 'error';
}

// ═══════════════════════════════════════════════════════════════════════════════
// CLI 参数解析
// ═══════════════════════════════════════════════════════════════════════════════

ArgParser _buildParser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助信息并退出')
  ..addFlag(
    'dry-run',
    abbr: 'n',
    negatable: false,
    help: '预览模式：统计各文件将要发生的变更并输出到 stdout，不执行任何磁盘写入',
  )
  ..addOption(
    'output',
    abbr: 'o',
    valueHelp: 'path',
    help:
        '指定输出路径（单文件→目标文件；目录→目标根目录，保留相对结构）\n'
        '省略则覆写原文件',
  );

void _printUsage(ArgParser parser) {
  stderr.writeln('''
用法：
  dart run merge.dart <path> [options]

参数：
  <path>   （必填）目标 .dart 文件或目录路径；为目录时递归处理所有子目录

选项：
${parser.usage}

示例：
  # 处理单个文件（覆写原文件，建议先备份）
  dart run merge.dart lib/my_widget.dart

  # 处理单个文件，输出到新路径
  dart run merge.dart lib/my_widget.dart -o lib/my_widget_merged.dart

  # 递归处理整个 lib/ 目录（覆写原文件）
  dart run merge.dart lib/

  # 递归处理目录，输出到另一个目录（保留相对结构）
  dart run merge.dart lib/ --output=out/lib/

  # 预览将要变更的文件，不写入磁盘（结果输出到 stdout）
  dart run merge.dart lib/ --dry-run
''');
}

// ═══════════════════════════════════════════════════════════════════════════════
// main
// ═══════════════════════════════════════════════════════════════════════════════

Future<void> main(List<String> args) async {
  final parser = _buildParser();

  ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('错误：${e.message}');
    _printUsage(parser);
    exit(1);
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  if (results.rest.isEmpty) {
    stderr.writeln('错误：缺少必填参数 <path>');
    _printUsage(parser);
    exit(1);
  }

  final inputPath = p.canonicalize(results.rest.first);
  final outputPath = results['output'] as String?;
  final dryRun = results['dry-run'] as bool;

  final inputIsFile = await File(inputPath).exists();
  final inputIsDir = !inputIsFile && await Directory(inputPath).exists();

  if (!inputIsFile && !inputIsDir) {
    stderr.writeln('错误：路径不存在：$inputPath');
    exit(1);
  }

  // --output 类型与 <path> 类型不匹配检查
  if (outputPath != null) {
    if (inputIsFile && await Directory(outputPath).exists()) {
      stderr.writeln(
        '错误：输入为文件，但 --output 指向已有目录：$outputPath\n'
        '      请指定目标文件路径，例如：-o path/to/output.dart',
      );
      exit(1);
    }
    if (inputIsDir && await File(outputPath).exists()) {
      stderr.writeln(
        '错误：输入为目录，但 --output 指向已有文件：$outputPath\n'
        '      请指定目标目录路径，例如：-o path/to/output_dir/',
      );
      exit(1);
    }
  }

  // ── 单文件模式 ────────────────────────────────────────────────────────────
  if (inputIsFile) {
    try {
      final original = await File(inputPath).readAsString();
      final (:transformed, :stats) = await processFile(inputPath);

      if (dryRun) {
        _dryRunLog(inputPath, success: true, detail: stats.describe());
        exit(0);
      }

      final targetPath = outputPath != null
          ? p.canonicalize(outputPath)
          : inputPath;

      if (transformed == original) {
        stderr.writeln('跳过（无变化）：$inputPath');
      } else {
        await Directory(p.dirname(targetPath)).create(recursive: true);
        await File(targetPath).writeAsString(transformed);
        stderr.writeln('✓ 已写入：$targetPath');
      }
    } catch (e, stackTrace) {
      if (dryRun) {
        _dryRunLog(inputPath, success: false, detail: _shortErrorMessage(e));
        stderr.writeln('详细错误（$inputPath）：$e');
        stderr.writeln(stackTrace);
      } else {
        stderr.writeln('✗ 错误（$inputPath）：$e');
        stderr.writeln(stackTrace);
      }
      exit(1);
    }
    return;
  }

  // ── 目录模式（始终递归）──────────────────────────────────────────────────
  try {
    if (!dryRun) {
      stderr.writeln('扫描目录（递归）：$inputPath');
    }

    final (:processed, :skipped, :failed) = await processDirectory(
      inputPath,
      outputDir: outputPath,
      dryRun: dryRun,
    );

    // 汇总信息始终输出到 stderr，与 dry-run 的 stdout 日志分离
    stderr.writeln('');
    if (dryRun) {
      stderr.writeln('预览完成：$processed 个将变更，$skipped 个无变化，$failed 个出错');
    } else {
      stderr.writeln('完成：处理 $processed 个，跳过 $skipped 个，失败 $failed 个');
    }

    exit(failed > 0 ? 1 : 0);
  } on FileSystemException catch (e) {
    stderr.writeln('文件系统错误：${e.message}（路径：${e.path ?? inputPath}）');
    exit(1);
  } catch (e, stackTrace) {
    stderr.writeln('未预期的错误：$e');
    stderr.writeln(stackTrace);
    exit(1);
  }
}
