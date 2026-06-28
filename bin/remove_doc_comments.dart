// bin/remove_doc_comments.dart
//
// 瘦包装：删除每行的 /// 文档注释标识符。
// 实际逻辑在 package:doc_pipe（共享 harness + 命令实现）中。

import 'dart:io';

import 'package:doc_pipe/doc_pipe.dart';

Future<void> main(List<String> args) async =>
    exit(await RemoveDocCommand().run(args));
