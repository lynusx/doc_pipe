import 'package:doc_pipe/src/cli/dart_file_tool.dart';

class RenameToMdTool extends DartFileTool {
  @override
  String get name => 'rename_to_md';

  @override
  String get description => '将 .dart 文件重命名为 .md 文件，不修改文件内容。';

  @override
  List<UsageExample> get examples => const [
    UsageExample(
      '原位重命名单文件（foo.dart → foo.md）',
      'dart run bin/rename_to_md.dart lib/src/foo.dart',
    ),
    UsageExample(
      '目录下所有 .dart 原位重命名为 .md',
      'dart run bin/rename_to_md.dart lib/',
    ),
    UsageExample(
      '处理目录，输出到另一目录（保留相对结构）',
      'dart run bin/rename_to_md.dart lib/ -o lib_md/',
    ),
    UsageExample(
      '预览将重命名的文件（不写磁盘）',
      'dart run bin/rename_to_md.dart lib/ --dry-run',
    ),
  ];

  @override
  String get outputExtension => '.md';

  @override
  bool get inPlaceIsRename => true;

  @override
  AnalysisNeed get analysisNeed => AnalysisNeed.none;

  @override
  Future<FileChange> transform(SourceFile input) async {
    // 内容原样复制；文件名变更由基类根据 outputExtension 和 inPlaceIsRename 处理。
    return FileChange(
      newContent: input.text,
      stats: const ChangeStats(),
      outcome: FileOutcome.changed,
    );
  }
}
