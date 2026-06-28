// bin/rename_to_md.dart
//
// 瘦包装：将 .dart 文件重命名为 .md。
// 实际逻辑在 package:doc_pipe（共享 harness + 命令实现）中。

import 'dart:io';

import 'package:doc_pipe/doc_pipe.dart';

Future<void> main(List<String> args) async =>
    exit(await RenameToMdCommand().run(args));
