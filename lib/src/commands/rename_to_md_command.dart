// lib/src/commands/rename_to_md_command.dart
//
// 将 .dart 文件重命名为 .md 文件（不修改内容）。
//
// 借助 harness 的两个钩子实现，无需自有写盘逻辑：
//   * rewriteDestination：把目标扩展名改为 .md；
//   * removesOriginalOnInPlace：原地处理时删除旧的 .dart。
// 变换本身只是把源内容原样返回——harness 据 rewriteDestination 写入 .md 路径。

import 'package:path/path.dart' as p;

import '../dry_run.dart';
import '../files.dart';
import '../harness.dart';

/// 将 `.dart` 重命名/另存为 `.md`（内容不变）。
class RenameToMdCommand extends FileCommand {
  @override
  UsageSpec get usage => const UsageSpec(
    invocation: 'dart run bin/rename_to_md.dart',
    description: '将 .dart 文件重命名为 .md（不修改内容，不删除注释）。',
    examples: [
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
    ],
  );

  @override
  String rewriteDestination(String destination) =>
      p.setExtension(destination, '.md');

  @override
  bool get removesOriginalOnInPlace => true;

  @override
  Future<FileOutcome> transform(FileContext ctx) async {
    // 内容原样保留；写入目标（.md）与可能的删除旧文件由 harness 处理。
    return Transformed(ctx.source, const ChangeStats(renames: 1));
  }
}
