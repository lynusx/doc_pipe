import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:doc_pipe/src/cli/dart_file_tool.dart';

class ExtractDocCommentsTool extends DartFileTool {
  @override
  String get name => 'extract_doc_comments';

  @override
  String get description => '抽取全部 /// 注释组并以之替换文件内容。';

  @override
  List<UsageExample> get examples => const [
    UsageExample(
      '就地覆写单文件',
      'dart run bin/extract_doc_comments.dart lib/src/my_widget.dart',
    ),
    UsageExample('处理整个目录（就地覆写）', 'dart run bin/extract_doc_comments.dart lib/'),
    UsageExample(
      '处理目录，输出到另一目录',
      'dart run bin/extract_doc_comments.dart lib/ -o /tmp/out/',
    ),
    UsageExample(
      '预览将写入的内容（不写磁盘）',
      'dart run bin/extract_doc_comments.dart -n lib/',
    ),
  ];

  @override
  AnalysisNeed get analysisNeed => AnalysisNeed.parsed;

  @override
  Future<FileChange> transform(SourceFile input) async {
    final parsed = input.parsedUnit as ParseStringResult;
    final groups = _extractDocCommentGroups(parsed);

    if (groups.isEmpty) return FileChange.skipped();

    final output = _formatGroups(groups);

    final merges = groups.fold<int>(
      0,
      (sum, g) => sum + (g.length > 1 ? g.length - 1 : 0),
    );

    return FileChange(
      newContent: output,
      stats: ChangeStats(merges: merges),
      outcome: FileOutcome.changed,
    );
  }
}

// ── 核心提取逻辑（原样搬运）──────────────────────────────────────────────────

List<List<String>> _extractDocCommentGroups(ParseStringResult parsed) {
  final LineInfo lineInfo = parsed.unit.lineInfo;
  final List<({int lineNumber, String lexeme})> docTokens = [];

  Token tok = parsed.unit.beginToken;
  while (true) {
    Token? comment = tok.precedingComments;
    while (comment != null) {
      if (comment.type == TokenType.SINGLE_LINE_COMMENT &&
          comment.lexeme.startsWith('///') &&
          !comment.lexeme.startsWith('////')) {
        final line = lineInfo.getLocation(comment.offset).lineNumber;
        docTokens.add((lineNumber: line, lexeme: comment.lexeme));
      }
      comment = comment.next;
    }
    if (tok.type == TokenType.EOF) break;
    tok = tok.next!;
  }

  if (docTokens.isEmpty) return [];

  final List<List<String>> groups = [];
  List<String> currentGroup = [docTokens.first.lexeme];
  int prevLine = docTokens.first.lineNumber;

  for (int i = 1; i < docTokens.length; i++) {
    final entry = docTokens[i];
    if (entry.lineNumber == prevLine + 1) {
      currentGroup.add(entry.lexeme);
    } else {
      groups.add(currentGroup);
      currentGroup = [entry.lexeme];
    }
    prevLine = entry.lineNumber;
  }
  groups.add(currentGroup);
  return groups;
}

String _formatGroups(List<List<String>> groups) {
  final sb = StringBuffer();
  for (int i = 0; i < groups.length; i++) {
    if (i > 0) sb.write('\n');
    for (final line in groups[i]) {
      sb.writeln(line.trimRight());
    }
  }
  return sb.toString();
}
