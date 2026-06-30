# doc_pipe

一套 Dart 命令行文档注释处理工具集，可单独使用，也可通过编排器一键串行执行完整管道。

## 工具概览

| 工具                   | 功能                                                   |
| ---------------------- | ------------------------------------------------------ |
| `dart_doc_inserter`    | 为公开声明插入格式化的文档摘要注释块（需类型解析）     |
| `strip_private`        | 删除所有私有声明及其关联注释和注解                     |
| `merge_comments`       | 将多行 `///` 段落合并为一行，Markdown 语法元素原样保留 |
| `extract_doc_comments` | 抽取全部 `///` 注释组并以之替换文件内容                |
| `remove_doc_comments`  | 逐行删除 `///` 标识符，保留注释正文                    |
| `rename_to_md`         | 将 `.dart` 文件重命名为 `.md`，不修改内容              |
| `doc_pipe`             | 编排器，按上述顺序一键串行执行全部步骤                 |

## 环境要求

- Dart SDK `^3.11.1`

## 快速开始

```bash
dart pub get

# 一键处理整个目录
dart run bin/doc_pipe.dart lib/ -o out/

# 预览模式（不写磁盘）
dart run bin/doc_pipe.dart lib/ --dry-run
```

## 单工具用法

所有叶子工具共享相同的 CLI 接口：

```
dart run bin/<tool>.dart <路径> [选项]

选项：
  -o, --output   输出路径（单文件→目标文件；目录→目标根目录，省略则就地覆写）
  -n, --dry-run  预览模式，不写磁盘
  -h, --help     显示帮助
```

示例：

```bash
# 处理单文件
dart run bin/merge_comments.dart lib/src/foo.dart

# 处理目录，输出到另一目录
dart run bin/strip_private.dart lib/ -o lib_stripped/

# 预览
dart run bin/extract_doc_comments.dart lib/ --dry-run
```

## 编排器用法

```bash
dart run bin/doc_pipe.dart <路径> [选项]

选项：
  -o, --output   输出路径
  -n, --dry-run  预览模式（透传给每个步骤）
  -r, --resume   从上次中断处继续（依赖状态文件）
  -v, --verbose  失败时输出完整 stderr（默认截断至 20 行）
  -h, --help     显示帮助
```

管道步骤（严格顺序）：

```
Step 1  dart_doc_inserter
Step 2  strip_private
Step 3  merge_comments
Step 4  extract_doc_comments
Step 5  remove_doc_comments
Step 6  rename_to_md
```

每次运行会在输入路径旁写入 `.doc_pipeline_state.json`，记录各步骤执行结果。使用 `--resume` 可在中断后跳过已完成的步骤继续执行。

## dry-run 输出格式

所有工具的 `--dry-run` 输出遵循统一格式：

```
[dry-run]  (√) lib/src/foo.dart (3 inserts, 2 deletes)
[dry-run]  (√) lib/src/bar.dart (no changes)
[dry-run]  (×) lib/src/baz.dart (parse error)
```

## 项目结构

```
bin/          # 薄入口（每个文件 ~3 行）
lib/
  src/
    cli/      # 共享 CLI 基础设施（基类、参数解析、日志、diff）
    analysis/ # AST 加载封装
    pipeline/ # 编排器子进程/状态/续跑逻辑
    tools/    # 各工具核心转换逻辑
```

新增工具只需在 `lib/src/tools/` 下继承 `DartFileTool`，实现 `name`、`description`、`examples` 和 `transform`，再在 `bin/` 下写一个三行入口即可。
