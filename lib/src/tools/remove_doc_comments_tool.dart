import 'package:doc_pipe/src/cli/dart_file_tool.dart';

final _docCommentRe = RegExp(r'^(.*?)///(.*)$');

class RemoveDocCommentsTool extends DartFileTool {
  @override
  String get name => 'remove_doc_comments';

  @override
  String get description => '逐行删除 /// 文档注释标识符，保留注释正文。';

  @override
  List<UsageExample> get examples => const [
    UsageExample(
      '处理单文件（覆写原文件）',
      'dart run bin/remove_doc_comments.dart lib/src/foo.dart',
    ),
    UsageExample(
      '处理目录，输出到另一目录',
      'dart run bin/remove_doc_comments.dart lib/ -o lib_stripped/',
    ),
    UsageExample(
      '预览将处理的文件（不写磁盘）',
      'dart run bin/remove_doc_comments.dart lib/ --dry-run',
    ),
  ];

  @override
  AnalysisNeed get analysisNeed => AnalysisNeed.none;

  @override
  Future<FileChange> transform(SourceFile input) async {
    final processed = _stripDocComments(input.text);
    if (processed == input.text) return FileChange.unchanged();
    return FileChange(
      newContent: processed,
      stats: const ChangeStats(),
      outcome: FileOutcome.changed,
    );
  }
}

/// 逐行删除 `///` 标识符（保留 `///` 后的注释正文）。
String _stripDocComments(String content) {
  final lines = content.split('\n');
  final buffer = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final match = _docCommentRe.firstMatch(line);
    if (match != null) {
      buffer.write('${match.group(1)}${match.group(2)}');
    } else {
      buffer.write(line);
    }
    if (i < lines.length - 1) buffer.write('\n');
  }
  return buffer.toString();
}
