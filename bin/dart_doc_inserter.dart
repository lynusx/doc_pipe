// bin/dart_doc_inserter.dart
//
// 瘦包装：为公有声明插入文档注释块。
// 实际逻辑在 package:doc_pipe（共享 harness + 命令实现）中。

import 'dart:io';

import 'package:doc_pipe/doc_pipe.dart';

Future<void> main(List<String> args) async =>
    exit(await DocInsertCommand().run(args));
