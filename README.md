# doc_pipe

一套文档注释处理 CLI 的**模块化重构**版本。原先是 7 个互相独立、彼此大量复制
粘贴的 Dart 脚本；现在收敛为一个共享同一套骨架的 package：6 个子命令各自仍可单独
运行，外加一个把它们按固定顺序串起来的管道编排器。

## 目录结构

```
doc_pipe/
├── bin/                      # 瘦包装（每个仅 1 行 main，转调 lib 中的实现）
│   ├── dart_doc_inserter.dart
│   ├── strip_private.dart
│   ├── merge_comments.dart
│   ├── extract_doc_comments.dart
│   ├── remove_doc_comments.dart
│   ├── rename_to_md.dart
│   └── doc_pipe.dart         # 管道编排器入口
├── lib/
│   ├── doc_pipe.dart         # 公共 barrel（导出命令、编排器、骨架类型）
│   └── src/
│       ├── harness.dart      # ★ 去重核心：统一的命令生命周期
│       ├── files.dart        # 文件收集 / 输出路径推导 / ArgParser / 用法渲染
│       ├── dry_run.dart      # 变更统计 / dry-run 日志 / 错误归类
│       ├── analysis.dart     # 统一的 analyzer 解析层（共享解析上下文）
│       ├── pipeline.dart     # 管道编排器（子进程调度 / 状态文件 / 续跑）
│       └── commands/         # 6 个子命令，各自只剩「纯源码变换」
│           ├── doc_insert_command.dart
│           ├── strip_private_command.dart
│           ├── merge_comments_command.dart
│           ├── extract_doc_command.dart
│           ├── remove_doc_command.dart
│           └── rename_to_md_command.dart
├── pubspec.yaml
└── analysis_options.yaml
```

## 架构

**一个命令 = 一次纯文本变换。** 所有「逐 .dart 文件处理」的命令都继承
`FileCommand`，只需提供两样东西：

```dart
abstract class FileCommand {
  UsageSpec get usage;                          // 用法元信息
  Future<FileOutcome> transform(FileContext);   // 对单个文件源码的纯变换（不写盘）
}
```

`transform` 返回 `Transformed(content, stats)`（应写盘）或 `Unchanged()`（应跳过）。
**是否写盘由返回类型决定**，从而精确复刻每个工具原有的写/跳语义。

公共生命周期收敛在 `runCommand()` 里，统一负责：参数解析 → 输入路径校验 →
`--output` 一致性校验 → 收集 `.dart` 文件 → 逐文件读取 → 调 `transform` →
（dry-run 仅打印 / 否则写盘）→ 错误隔离 → 汇总与退出码。dry-run 与真实写盘彻底
分离：dry-run 只调用变换并打印，绝不触碰磁盘。

`bin/` 下每个脚本因此只剩一行：

```dart
Future<void> main(List<String> args) async => exit(await StripPrivateCommand().run(args));
```

## 消除了哪些重复

重构前，6 个子命令各自重复实现了同一套样板。现已全部收敛到 `lib/src`：

| 原先各写一遍的东西                                         | 现在的唯一归宿                              |
| ---------------------------------------------------------- | ------------------------------------------- |
| `main()` 全套流程（解析/校验/收集/循环/汇总/退出码）       | `harness.dart` `runCommand`                 |
| `ArgParser`（`-o`/`-n`/`-h` 三个选项完全相同）             | `files.dart` `buildStandardParser`          |
| `_collectDartFiles`（6 份，跳过目录/排序规则各异）         | `files.dart` `collectDartFiles`（统一规则） |
| `_resolveDestination` / `_destinationPath`（逻辑完全一致） | `files.dart` `resolveDestination`           |
| `_checkOutputCompatibility` / `_validateOutputType`        | `files.dart` `checkOutputCompatibility`     |
| dry-run 统计类（`_DryRunStats`/`FileChangeStats`/`Map`）   | `dry_run.dart` `ChangeStats`                |
| `[dry-run] (√/×) <路径> (<详情>)` 输出（4 份）             | `dry_run.dart` `dryRunLine`                 |
| 异常 → 简短标签 的归类（io/parse/permission）              | `dry_run.dart` `classifyError`              |
| analyzer 解析上下文搭建（inserter/strip/merge 各一份）     | `analysis.dart` `AnalysisService`           |
| `_printUsage`（结构一致）                                  | `files.dart` `printUsage`                   |

各命令文件中保留下来的，只有真正体现该工具**独特价值**的算法本身（如插入器的
AST 访问器与签名构造、strip 的私有区间收集、merge 的 Markdown 感知段落合并、
extract 的注释组提取等），且与原实现逐字一致。

## 运行

本仓库未随附 `pub` 依赖；首次使用请在本地：

```bash
dart pub get
dart analyze        # 建议跑一次静态检查
```

单独运行某个子命令：

```bash
# 为公有声明插入文档注释（就地覆写）
dart run bin/dart_doc_inserter.dart lib/

# 删除私有声明，输出到另一目录
dart run bin/strip_private.dart lib/ -o out/

# 预览将发生的变更（不写盘）
dart run bin/merge_comments.dart lib/ --dry-run
```

运行整条管道（按固定顺序串行执行全部 6 步）：

```bash
# 处理整个目录，输出到 out/
dart run bin/doc_pipe.dart lib/ -o out/

# 预览模式
dart run bin/doc_pipe.dart lib/ --dry-run

# 从上次中断处续跑
dart run bin/doc_pipe.dart lib/ -o out/ --resume
```

管道步骤（严格顺序）：`dart_doc_inserter` → `strip_private` → `merge_comments`
→ `extract_doc_comments` → `remove_doc_comments` → `rename_to_md`。编排器以子进程
方式调用 `bin/` 下对应脚本，保留了输出捕获与缩进、JSON 状态文件（原子写）、续跑、
分步计时、stderr 截断等全部能力。

## 与原脚本相比的行为变化

重构以「行为等价」为目标，仅有以下刻意为之的细微差异：

1. **统一的文件收集规则**：合并为一套——跳过隐藏目录（以 `.` 开头，如 `.git`、
   `.dart_tool`）与 `build` 目录，结果排序并 canonicalize。这是原 strip/merge 行为
   的并集，对其余命令是超集；好处是管道每一步面对的文件集合一致。
2. **部分 dry-run 输出改为绝对路径**：输入路径统一 canonicalize（analyzer 本就需要
   绝对路径），因此 remove/rename/extract 的预览行也变为绝对路径——更准确。
3. **删除了 extract 的 LCS diff**（约 90 行）：它原本只用于在 dry-run 中显示
   插入/删除行号；提取出的注释**内容完全不变**，仅保留有意义的 `merges` 统计。
4. **移除未使用的 `logger` 依赖**：原 `pubspec.yaml` 声明了 `logger` 但全仓无任何
   引用，已删去。
5. **修正编排器「5 个步骤」文案**：步骤表一直是 6 步（含 `rename_to_md`），此前仅
   头部/用法文案滞后显示为 5，现已统一为 6 并在用法中补齐 Step 6。

> 注：当前环境未安装 Dart SDK 且无网络，无法在此处执行 `dart pub get` / `dart
analyze` 做编译验证。代码均按 analyzer `^6.4.1` 的 API 手工保留原始调用，请在本地
> 跑一次上述命令确认。
