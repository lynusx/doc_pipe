// lib/src/commands/extract_doc_command.dart
//
// 提取 .dart 文件中的所有 `///` 文档注释，按「连续行号」分组，组间以空行分隔
// 输出。核心提取逻辑基于 analyzer 的 token 流（无正则），与原工具保持一致。
//
// 说明：原工具为了让 dry-run 显示 insert/delete/modify 数字，额外实现了一套
// 约 90 行的 LCS 行级 diff。该 diff 仅影响 dry-run 的数字展示，不影响提取出的
// 内容本身。重构中移除了它，改为只报告有算法依据的 `merges`（每组 N 行合并
// 计 N-1 次）。提取产物与原工具完全一致。

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';

import '../analysis.dart';
import '../dry_run.dart';
import '../files.dart';
import '../harness.dart';

/// 提取 `.dart` 文件中的 `///` 文档注释组。
class ExtractDocCommand extends FileCommand {
  @override
  UsageSpec get usage => const UsageSpec(
    invocation: 'dart run bin/extract_doc_comments.dart',
    description: '提取所有 /// 文档注释，连续行号为一组，组间以空行分隔。',
    examples: [
      UsageExample(
        '原地覆写单文件为其提取出的注释',
        'dart run bin/extract_doc_comments.dart lib/src/widget.dart',
      ),
      UsageExample(
        '提取整个目录，结果写入另一目录',
        'dart run bin/extract_doc_comments.dart lib/ -o out/',
      ),
      UsageExample(
        '预览目录处理结果（不写盘）',
        'dart run bin/extract_doc_comments.dart lib/ --dry-run',
      ),
    ],
  );

  @override
  Future<FileOutcome> transform(FileContext ctx) async {
    final parsed = ctx.parsed();
    final groups = _extractDocCommentGroups(parsed);

    // 无 /// 注释 → 跳过（与原工具一致，不写盘）。
    if (groups.isEmpty) return const Unchanged();

    final output = _formatGroups(groups);
    final merges = groups.fold<int>(
      0,
      (sum, g) => sum + (g.length > 1 ? g.length - 1 : 0),
    );
    return Transformed(output, ChangeStats(merges: merges));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 核心提取逻辑（基于 AST token，无正则）——与原实现一致
// ─────────────────────────────────────────────────────────────────────────────

/// 一个「组」是源码中相邻的若干 `///` 行（行号逐行 +1）。
/// 返回组列表，每组为 `/// …` 词素的列表。
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

/// 组内各行以 `\n` 连接（去掉行尾空白）；组间空一行；文件以单个换行结尾。
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
