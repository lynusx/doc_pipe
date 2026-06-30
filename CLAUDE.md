# 重构提示词：将 `doc_pipe` 工具集重构为「抽象基类 + 共享库」的模块化项目

使用方式：将本文件整体作为提示词交给执行重构的 AI（或工程师）。执行方应**先读仓库实际代码再动手**，本提示词中的「现状勘察」仅为导航，一切以仓库为准。

---

## 0. 角色与目标

你是一名精通 Dart、CLI 工具架构、面向对象设计与模块化重构的资深工程师。你的任务：

把现有的一组功能相关、却各自复制了大量相同 CLI 脚手架代码的 Dart 命令行工具，重构为**「抽象基类（模板方法）+ 共享库」**的模块化项目，使得：

1. 所有重复的 CLI 样板（参数解析、路径校验、文件收集、dry-run 预览、退出码、用法打印）只存在**一份**；
2. **新增一个工具时，只需新建一个继承基类的子类并实现"核心业务逻辑"**，无需再抄一遍样板；
3. **对外行为保持不变**：每个工具的命令行接口、转换结果、退出码、dry-run 输出格式与现状逐字节一致（除非在第 4 节中被显式批准修改）；
4. **散落的 **`**print()**`** / **`**stderr.writeln()**`** 全部收敛至 **`**logger**`** 包**：通过 `console.dart` 统一路由，输出内容与格式严格保持不变。

这是一次**结构性重构**，不是功能迭代。除第 4 节列出的、需要你确认的少数一致性问题外，不得改变任何工具的转换语义或可观察输出。

---

## 1. 代码现状（已为你勘察，务必以仓库代码为准）

项目当前形态：`pubspec.yaml`（包名 `doc_pipe`，SDK `^3.11.1`）+ 一批位于 `bin/` 的独立脚本。依赖：`args ^2.7.0`、`path ^1.9.1`、`analyzer ^6.4.1`、`logger ^2.7.0`；dev 依赖 `lints ^6.0.0`。

（注意：`logger` 已在 pubspec 声明，但当前所有脚本均未使用，统一用 `print` / `stderr.writeln` 输出——本次重构将统一收敛至 `logger`，实现详见 §2.4，约束见 §3 第 7 条，无需新增依赖。）

### 1.1 文件清单

| 文件                        | 角色       | 核心转换                                                                 | AST 依赖层级                                                   | 注释/提示语言              | 需特别注意之处                                                                                     |
| --------------------------- | ---------- | ------------------------------------------------------------------------ | -------------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------- |
| `dart_doc_inserter.dart`    | 叶子工具   | 为声明插入生成的文档摘要注释                                             | **已解析单元**（`getResolvedUnit`<br/>，需类型信息）           | 英文                       | 仅在产生 edits 时写盘；无 edits 静默跳过                                                           |
| `strip_private.dart`        | 叶子工具   | 删除私有声明及其关联注释/注解                                            | AST（`AnalysisContextCollection`<br/>，基于节点+源码偏移区间） | 英文（含 `library;`<br/>） | 多变量声明仅当**全部**私有时才删除                                                                 |
| `merge_comments.dart`       | 叶子工具   | 合并 `///`<br/> 段落为单行（Markdown 感知：代码块/标题/列表/表格等保留） | **已解析单元**（token + `lineInfo`<br/>）                      | 中文                       | 汇总/写入信息走 **stderr**（与他者不同）                                                           |
| `extract_doc_comments.dart` | 叶子工具   | 抽取全部 `///`<br/> 注释组并以之替换文件内容                             | 已解析单元（`parseString`<br/>）                               | 英文                       | 用 `_Result`<br/> 枚举区分 written/skipped/error；无 `///`<br/> 时跳过                             |
| `remove_doc_comments.dart`  | 叶子工具   | 逐行删除 `///`<br/> 标识符（保留正文）                                   | **无 AST**（纯正则）                                           | 中文                       | 不需要 analyzer                                                                                    |
| `rename_to_md.dart`         | 叶子工具   | `.dart`<br/> → `.md`<br/> 重命名（**不改内容**）                         | **无 AST**                                                     | 中文                       | **异类**：输出扩展名为 `.md`<br/>；就地模式是 **rename（原文件消失）** 而非覆写                    |
| `doc_pipe.dart`             | **编排器** | 以子进程方式按固定顺序串行调用上述叶子工具                               | 无                                                             | 中文                       | 有额外 flag `-r/--resume`<br/>、`-v/--verbose`<br/>；维护 `.doc_pipeline_state.json`<br/> 状态文件 |

### 1.2 共享的 CLI 契约（重复的根源）

六个叶子工具几乎逐字复制了同一套契约，实现差异很小：

- **参数解析器**：`-o/--output`、`-n/--dry-run`、`-h/--help`。
- **位置参数 **`**<path>**`：必填、且只接受一个。
- **输入校验**：`notFound` 报错；单文件必须以 `.dart` 结尾；区分 file / directory。
- `**--output**`** 与输入类型一致性校验**：单文件输入不得指向已存在目录；目录输入不得指向已存在文件；不存在的路径视为待创建。
- **目录递归收集 **`**.dart**`** 文件**。
- **逐文件流程**：读取 → 转换 → 写盘（或 dry-run 预览）→ 写盘前 `createSync(recursive: true)` 建父目录。
- **目标路径解析**：无 `-o` 则就地；单文件 `-o` 即目标文件；目录 `-o` 则在输出根下镜像相对结构。
- **统一 dry-run 行格式**（在至少 4 个文件中被各自重新实现，含各自的 stats 结构、格式化器，甚至一份重复的 LCS 行 diff）：

```plain
[dry-run]  (√) <path> (<n insert, n delete, n modify, n merge, ...>)
[dry-run]  (√) <path> (no changes)
[dry-run]  (×) <path> (<error reason>)
```

- **汇总行 +** `**exit(hasError ? 1 : 0)**`。
- **用法/帮助打印器**（带示例）。

### 1.3 真正"因工具而异"的部分（即应保留为子类核心逻辑的内容）

- **转换本身**：纯字符串/正则（`remove`、`rename`）、基于 token/AST 的改写（`merge`、`extract`、`strip_private`）、或需类型信息的解析单元（`dart_doc_inserter`）。
- **所需的解析层级**：无解析 / `parseString`（已解析）/ `getResolvedUnit`（已解析+类型）。
- **输出扩展名**：除 `rename_to_md` 为 `.md` 外，其余均为 `.dart`。
- **"无变化"的处理**：静默跳过 vs 照常写入。
- **dry-run 统计的词汇**（inserts/deletes/modifies/merges/skips）——但**格式是共享的**。
- **工具名、描述、用法示例、帮助文案**。

---

## 2. 目标架构（必须采用）

### 2.1 目录结构（建议布局，可在保持等价的前提下微调）

```plain
doc_pipe/
├─ pubspec.yaml
├─ bin/                          # 仅保留极薄的入口（解析交给 lib，不含业务逻辑）
│  ├─ dart_doc_inserter.dart     # => DartDocInserterTool().run(args)
│  ├─ strip_private.dart
│  ├─ merge_comments.dart
│  ├─ extract_doc_comments.dart
│  ├─ remove_doc_comments.dart
│  ├─ rename_to_md.dart
│  └─ doc_pipeline.dart          # 编排器（复用共享库，但不继承 DartFileTool）
└─ lib/
   ├─ doc_tools.dart             # barrel：对外导出
   └─ src/
      ├─ cli/
      │  ├─ dart_file_tool.dart   # 抽象基类（模板方法）：掌管全生命周期
      │  ├─ cli_options.dart      # 共享 ArgParser 构建、解析、--output 一致性校验
      │  ├─ file_collector.dart   # 递归 .dart 收集（统一一套过滤策略）
      │  ├─ destination.dart      # 目标路径解析（含扩展名替换）
      │  ├─ dry_run.dart          # 统一 [dry-run] 行 + ChangeStats + 格式化
      │  ├─ line_diff.dart        # LCS 行 diff（供需要 insert/delete/modify 统计的工具复用）
      │  ├─ ansi.dart             # TTY 感知着色（编排器与汇总输出复用）
      │  └─ console.dart          # stdout/stderr 统一路由；内含 Logger 实例（见 §2.4）
      ├─ analysis/
      │  └─ ast_loader.dart       # 封装 parseString 与 resolved-unit 两条路径
      └─ pipeline/
         └─ pipeline_runner.dart  # 编排器的子进程/状态/续跑逻辑
```

关键原则：`**bin/**`** 下每个文件都应是几行的薄入口**（构造对应工具实例并调用 `run`）；业务逻辑全部移入 `lib/`。

### 2.2 抽象基类 `DartFileTool`（模板方法）

基类拥有**整个执行生命周期**，对外只暴露一个入口（如 `Future<int> run(List<String> args)` 或 `Future<void> run(...)`，由其内部决定退出码）。生命周期固定为：

解析参数 → 初始化 `Console`（日志级别） → 校验输入与 `--output` → 收集 `.dart` 文件 → （按需）建立分析上下文 → 逐文件转换/预览 → 汇总 → 退出码。

子类通过实现少量**钩子**来定制，分两类：

**必须实现（abstract）**

- `String get name;` —— 工具名（用于用法、错误信息）。
- `String get description;` —— 一句话描述。
- `List<UsageExample> get examples;` —— 用法示例（驱动统一的 `--help`）。
- 核心转换。由于各工具所需输入层级不同，建议统一为**单一方法**，让基类按需懒加载输入视图：

dart

```dart
/// 对单个源文件执行转换。基类已根据 [analysisNeed] 准备好 input。
  FutureOr<FileChange> transform(SourceFile input);
```

其中 `SourceFile` 懒提供 `text` / `parsedUnit` / `resolvedUnit`（只有在 `analysisNeed` 允许时才 materialize 对应单元）；`FileChange` 携带 `{ newContent, ChangeStats stats, FileOutcome outcome }`，`outcome ∈ {changed, unchanged, skipped}`，使"无变化/跳过"能与"已改"区分，并驱动 dry-run 统计。

**可覆写（带默认实现）**

- `String get outputExtension => '.dart';` —— `rename_to_md` 覆写为 `.md`。
- `AnalysisNeed get analysisNeed => AnalysisNeed.none;` —— `none` / `parsed` / `resolved`；基类据此决定是否、以何种方式建立 `AnalysisContextCollection`（仅在需要时建立）。
- 目录过滤策略（默认：跳过 `.dart_tool/`、`build/` 与隐藏目录——见第 4 节统一决策）。
- "未变化是否仍写盘"的策略（默认：跳过不写）。
- **就地写入策略**：默认覆写；`rename_to_md` 覆写为 rename（删除源文件）。

> 设计验收红线：`**rename_to_md**`** 是这套抽象的压力测试。** 它无转换、扩展名不同、就地即 rename。若你的基类无法用上述钩子干净地表达它，而被迫在 `main`/子类里塞特例分支，说明抽象设计错了——请重新设计基类，而非打补丁。

### 2.3 编排器的处理

`doc_pipeline.dart`（编排器）**不是逐文件转换**，**不要**强行让它继承 `DartFileTool`。但它应复用共享库：`cli_options`（它有 `-o/-n` 外加 `-r/-v`）、`ansi`、`console`、路径规范化等。其"子进程调用 + 状态文件 + `--resume`"逻辑收敛到 `lib/src/pipeline/pipeline_runner.dart`，`bin/doc_pipeline.dart` 仅作薄入口。

编排器在解析完参数后，须调用 `Console.init(level: verbose ? Level.debug : Level.info)` 以开启 debug 日志（见 §2.4）。

---

### 2.4 Logger 统一约定（已确认引入）

`pubspec.yaml` 已声明 `logger ^2.7.0`，**无需新增依赖**。本次重构必须将所有散落的 `print()` / `stderr.writeln()` 全部收敛至 `console.dart` 内部的 `Logger` 实例，禁止在其他位置直接调用 IO 输出。

#### Logger 配置（在 `console.dart` 内部实现）

dart

```dart
import 'dart:io';
import 'package:logger/logger.dart';

/// 仅输出消息本体，不追加时间戳、级别标签或 ANSI 装饰。
class _PlainPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) => [event.message.toStringfunction toString() { [native code] }()];
}

/// 按级别路由：Level.warning 及以上 → stderr，其余 → stdout。
class _SplitOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    final sink = event.level.index >= Level.warning.index
        ? stderr
        : stdout;
    for (final line in event.lines) sink.writeln(line);
  }
}

Logger _logger = Logger(
  printer: _PlainPrinter(),
  output: _SplitOutput(),
  level: Level.info, // 默认 info；由 Console.init() 覆盖
);
```

#### `Console` 对外 API

`console.dart` 导出一个纯静态类 `Console`，其他所有模块通过它访问日志，**不直接持有 **`**Logger**`** 引用**：

dart

```dart
class Console {
  Console._();

  /// 在参数解析完成后、首次输出前调用一次。
  static void init({Level level = Level.info}) {
    _logger = Logger(
      printer: _PlainPrinter(),
      output: _SplitOutput(),
      level: level,
    );
  }

  /// 调试信息（仅 Level.debug 时可见，默认不展示）。
  static void debug(Object msg) => _logger.d(msg);

  /// 正常用户可见输出：dry-run 行、汇总行、文件路径等。→ stdout
  static void info(Object msg)  => _logger.i(msg);

  /// 非致命警告：跳过文件、输出类型不匹配提示等。→ stderr
  static void warn(Object msg)  => _logger.w(msg);

  /// 可恢复错误或致命错误。→ stderr
  static void error(Object msg) => _logger.e(msg);
}
```

#### 级别与路由一览

| `Console`<br/> 方法 | Logger 级别     | 输出流 | 典型用途                                           |
| ------------------- | --------------- | ------ | -------------------------------------------------- |
| `Console.debug()`   | `Level.debug`   | stdout | 工具内部流程跟踪；仅编排器 `--verbose`<br/> 时可见 |
| `Console.info()`    | `Level.info`    | stdout | dry-run 行、汇总统计、文件写入路径                 |
| `Console.warn()`    | `Level.warning` | stderr | 跳过文件提示、可忽略异常                           |
| `Console.error()`   | `Level.error`   | stderr | 致命错误（路径不存在、写盘失败等）                 |

#### 迁移映射规则

| 重构前写法                           | 重构后写法                                                           |
| ------------------------------------ | -------------------------------------------------------------------- |
| `print('...')`                       | `Console.info('...')`                                                |
| `stderr.writeln('...')`              | `Console.error('...')`                                               |
| dry-run 行 `[dry-run] ...`           | `Console.info(dryRunLine)`<br/>（由 `dry_run.dart`<br/> 生成后传入） |
| 汇总行（文件数、错误数等）           | `Console.info(summaryLine)`                                          |
| 编排器 `--verbose`<br/> 展开错误详情 | `Console.debug(detail)`                                              |

#### 关键约束

- **输出内容与格式严格不变**：`_PlainPrinter` 只透传消息原文，不附加任何前缀；`_SplitOutput` 的路由规则与现状惯例（见 §4 第 4 条）完全一致，不产生任何可观察行为变化。
- `**Console.init()**`** 调用时机**：`DartFileTool` 基类在参数解析完成后立即调用 `Console.init()`（叶子工具始终用 `Level.info`）；编排器在解析 `--verbose` 后调用 `Console.init(level: verbose ? Level.debug : Level.info)`。
- **不新增 **`**--log-level**`** flag**：叶子工具无 debug 级别开关，日志级别由基类固定为 `info`；仅编排器的既有 `--verbose` 触发 debug 级别。
- `**console.dart**`** 是唯一例外**：整个项目中仅此文件内部允许直接调用 `stdout` / `stderr`；其他所有模块（含 `dry_run.dart`、`pipeline_runner.dart`、各子类）一律通过 `Console.*` 方法输出。

---

## 3. 硬性约束（不可违反）

1. **行为保持（最高优先级）**：重构后每个工具对同一输入的转换结果必须与重构前**逐字节一致**；退出码语义不变；dry-run 的 stdout 输出格式不变。
2. **CLI 兼容**：保留全部 flag（`-o/-n/-h`，编排器额外 `-r/-v`）、保留 `bin/` 下的**文件名**（编排器的 `_kSteps` 与 `Platform.script` 依赖这些文件名）、保留 `dart run bin/<tool>.dart <path> [opts]` 的调用方式。
3. **编排器联动**：编排器以子进程方式按文件名调用叶子工具并透传 `[<path>, (-o <out>)?, (--dry-run)?]`。因此叶子工具的文件名与可接受 flag 必须保持，或在同一次提交中同步更新编排器，二者不得脱节。
4. **核心逻辑原样迁移**：第 1.3 节所述的转换/AST 逻辑应**原样搬运**到对应子类，**不得借机重写或"优化"**。只合并样板。
5. **依赖与工具链**：沿用 `pubspec.yaml` 现有依赖与 SDK 约束。完成后须 `dart analyze` 零问题、`dart format` 无改动残留。
6. **范围控制**：不新增功能、不调整转换语义、不更改默认 flag 行为。任何超出"消除重复 + 模块化"的改动都需先暂停并征询。
7. **日志收口（强制）**：重构后整个代码库中（`console.dart` 内部实现除外）不得存在任何直接调用 `print()`、`stdout.write*()`、`stderr.write*()` 的语句；所有日志与用户可见输出一律通过 `Console.debug/info/warn/error` 路由。验收时须用 `grep -rn 'stderr\.write\|stdout\.write\|^ *print(' lib/ bin/` 确认零残留（`console.dart` 本身排除在外）。

---

## 4. 必须显式决策并向我确认的一致性问题

各工具在以下方面已经"漂移"，统一时**每一条都要么严格保留各自现状、要么统一并在交付报告中明确标注为有意修改**。下面给出推荐默认，但最终以我的确认为准——涉及用户可见输出的，默认偏向"保留现状 + 在报告中列出差异供我裁决"：

1. **注释/提示语言**：现状中英混杂（英文：inserter/strip_private/extract；中文：merge/remove/rename + 编排器 + pubspec）。**推荐统一为中文**（与编排器、pubspec、用户语境一致）。但这会改变用户可见的帮助/错误文案——属行为变更，须经确认。
2. **编排器步数显示不一致（疑似 bug）**：`_kSteps` 实际有 **6** 步（第 6 步为 `rename_to_md.dart`），而头部横幅写"(5 个步骤)"、`_printUsage` 只列出 Step 1–5（漏掉 rename）。须裁决：rename 究竟是否管道的一步？**推荐**：保留实际执行的步骤集合不变，仅修正展示文案使之与 `_kSteps` 一致，并在报告中标注。
3. **目录过滤策略**：仅 `strip_private`、`merge` 跳过 `.dart_tool/`、`build/`、隐藏目录，其余未跳过。**推荐**统一为"跳过 `.dart_tool/`、`build/` 与隐藏目录"，但须确认（会改变某些工具收集到的文件集合）。
4. **汇总输出走 stdout 还是 stderr**：`merge` 把"已写入/汇总"写到 stderr，其余多写到 stdout；dry-run 行各处一致走 stdout。**推荐**统一约定（dry-run→stdout，常规汇总→stdout，错误/诊断→stderr），并标注哪些工具的可观察输出因此改变。统一后分别对应 `Console.info` 与 `Console.error`（见 §2.4 路由规则）。
5. **路径规范化**：`inserter`、`merge`、编排器 `canonicalize`，其余不做。**推荐**统一在入口 `canonicalize`，但须确认（会改变打印出来的路径字符串及个别边界行为）。
6. **日志收口**：**已决策——引入 **`**logger**`** 并通过 **`**console.dart**`** 统一实现（详见 §2.4）；输出文本与格式与现状严格一致。** 此条不再需要确认，执行时直接落地。

---

## 5. 执行步骤（建议顺序）

1. **勘察与基线**：通读全部 7 个文件，列出共享契约与各自差异；选一棵真实的 `.dart` 目录样本，跑一遍**全部工具（含 **`**--dry-run**`**）并保存输出与产物**作为"黄金基线"，用于后续逐字节对比。
2. **先搭共享库与基类骨架**（此步不引入任何行为变化）：依序实现：
   - `console.dart`：配置 `_PlainPrinter`、`_SplitOutput`、`Logger` 实例，以及 `Console.init/debug/info/warn/error` 静态 API——**这是第一个要写的文件**，后续所有输出都通过它；
   - `cli_options`、`file_collector`、`destination`、`dry_run`、`line_diff`、`ansi`、`ast_loader` 与抽象 `DartFileTool`；
   - 以上文件内部输出**只能**调用 `Console.*`，不得有任何 `print()` / `stderr.writeln()`。
3. **迁移一个最简单的工具作为参照**（建议 `remove_doc_comments`，纯正则、`AnalysisNeed.none`）：改为薄入口 + 子类，**对照黄金基线证明等价**，同时确认 `Console.info` 产生与原 `print()` 完全相同的输出。这一对照通过后，模式即被锁定。
4. **迁移异类 **`**rename_to_md**`：作为基类抽象的压力测试，验证 `outputExtension`/就地 rename 钩子是否够用（不够则回到第 2 步改基类）。
5. **迁移 4 个 analyzer 系工具**（`merge`、`extract`、`strip_private`、`dart_doc_inserter`）：把核心 AST/转换逻辑**原样搬入**各自子类，仅替换样板与输出调用（`print` → `Console.info`，`stderr.writeln` → `Console.error`）；逐个对照黄金基线。
6. **重构编排器**：抽出子进程/状态/续跑到 `pipeline_runner`，复用共享 CLI/ANSI/路径工具；在参数解析后调用 `Console.init(level: verbose ? Level.debug : Level.info)`；端到端验证（含 `--resume`、`--dry-run`、`--verbose`）。
7. **去重收尾**：删除已被基类取代的所有重复样板，确保不存在第二份 dry-run/LCS/校验逻辑；运行 `grep -rn 'stderr\.write\|stdout\.write\|^ *print(' lib/ bin/` 确认日志收口零残留（`console.dart` 除外）。

---

## 6. 验收标准（Definition of Done）

- **黄金对比**：对样本目录，重构前后运行每个工具（含 `--dry-run`、`-o 输出到镜像目录`、单文件三种形态）的**产物与 stdout 逐字节一致**，退出码一致。
- `dart analyze` 零问题；`dart format` 无残余 diff。
- 每个工具的 `--help`/用法输出与现状对齐（语言策略见第 4 节决策）。
- **日志收口验证**：`grep -rn 'stderr\.write\|stdout\.write\|^ *print(' lib/ bin/` 输出为空（`console.dart` 文件本身除外），确认无直接 IO 调用残留。
- **Logger 级别验证**：对编排器分别以默认模式和 `--verbose` 模式运行相同的失败场景，确认：默认模式不输出 `Console.debug` 内容；`--verbose` 模式正确展开错误详情（且内容与现状的 verbose 展开完全一致）。
- **"新增工具"冒烟测试**：另写一个**几十行内**的玩具工具（例如把所有 `///` 注释正文转大写的 `UppercaseDocTool`），仅需"继承基类 + 实现 `transform` + 提供 name/description/examples"即可跑通，且其输出全部通过 `Console.*`（无任何 `print()`）——以此证明抽象达成了"新增工具只写核心逻辑"的目标。完成验证后该玩具工具可删除或留作示例。
- 编排器端到端可用：正常串行、失败中断后 `--resume` 续跑、`--dry-run` 透传、`--verbose` 展开错误，状态文件读写正常。

---

## 7. 你应交付的内容

1. **重构后的完整项目树**（薄入口 + 共享库 + 子类）。
2. **一份简短的迁移报告**，说明：哪些样板移到了哪里、第 4 节各决策的最终取舍、logger 迁移映射表（原始调用位置 → 对应 `Console.*` 方法）、任何与现状的有意偏差及其理由、以及你如何完成黄金对比与冒烟测试。
3. 报告中明确指出：是否存在任何**破坏性/不可逆**的改动（例如 `rename_to_md` 的就地 rename 会删除源文件——这是现状行为，须如实复述并在执行前征得确认）。

---

## 8. 护栏

- **不改转换语义**：若在迁移中产生"顺手把这段逻辑改好"的冲动——停下，记录，征询，**不要擅自改**。
- **抽象优先于特例**：若发现需要在 `main` 或子类里写 `if (this is RenameTool)` 之类的特例分支，说明基类钩子设计不足——回去改基类。
- **语言与文案默认保持原样**，仅在第 4 节决策被批准后统一。
- `**Console**`** 是唯一出口**：若在迁移过程中产生"这里只是临时 print 一下"的冲动——停下，一律改成 `Console.*`，无例外。`console.dart` 之外出现任何 `print()`、`stdout.*`、`stderr.*` 均视为未完成。
- **遇到第 4 节之外的歧义**：先在不改变可观察行为的前提下做最小、最保守的处理，并在报告中列出，交由我裁决。
