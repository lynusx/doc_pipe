// lib/src/commands/remove_doc_command.dart
//
// 删除每行的 `///` 文档注释标识符（保留 `///` 之后的正文）。
// 纯文本逐行处理，不依赖 analyzer。

import '../dry_run.dart';
import '../files.dart';
import '../harness.dart';

/// 匹配一行中的 `///`：分组 1 为其前缀，分组 2 为其后的正文。
final RegExp _docCommentRe = RegExp(r'^(.*?)///(.*)$');

/// 删除 `.dart` 文件中每行的 `///` 标识（保留正文，输入/输出仍为 .dart）。
class RemoveDocCommand extends FileCommand {
  @override
  UsageSpec get usage => const UsageSpec(
    invocation: 'dart run bin/remove_doc_comments.dart',
    description: '删除每行的 /// 文档注释标识符（保留其后的注释正文）；不做重命名。',
    examples: [
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
    ],
  );

  @override
  Future<FileOutcome> transform(FileContext ctx) async {
    final lines = ctx.source.split('\n');
    final buffer = StringBuffer();
    var modified = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final match = _docCommentRe.firstMatch(line);
      if (match != null) {
        buffer.write('${match.group(1)}${match.group(2)}');
        modified++;
      } else {
        buffer.write(line);
      }
      if (i < lines.length - 1) buffer.write('\n');
    }

    // 与原工具一致：始终写出处理后的内容（即便没有 /// 被删除）。
    return Transformed(buffer.toString(), ChangeStats(modifies: modified));
  }
}
