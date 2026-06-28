// lib/doc_pipe.dart
//
// 包的公共入口（barrel）。聚合导出全部子命令、编排器，以及构建自定义
// 「逐 .dart 文件处理」命令所需的核心骨架类型。
//
// bin/ 下的各包装脚本仅从这里导入对应命令并调用 `run`。

// 核心骨架：自定义命令时需要的契约类型。
export 'src/harness.dart'
    show FileCommand, FileContext, FileOutcome, Transformed, Unchanged;
export 'src/dry_run.dart' show ChangeStats, ParseFailure;
export 'src/files.dart' show UsageSpec, UsageExample;

// 六个子命令。
export 'src/commands/doc_insert_command.dart' show DocInsertCommand;
export 'src/commands/strip_private_command.dart' show StripPrivateCommand;
export 'src/commands/merge_comments_command.dart' show MergeCommentsCommand;
export 'src/commands/extract_doc_command.dart' show ExtractDocCommand;
export 'src/commands/remove_doc_command.dart' show RemoveDocCommand;
export 'src/commands/rename_to_md_command.dart' show RenameToMdCommand;

// 编排器。
export 'src/pipeline.dart' show Pipeline;
