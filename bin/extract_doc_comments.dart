// bin/extract_doc_comments.dart
//
// 瘦包装：提取 /// 文档注释组。
// 实际逻辑在 package:doc_pipe（共享 harness + 命令实现）中。

import 'dart:io';

import 'package:doc_pipe/doc_pipe.dart';

Future<void> main(List<String> args) async =>
    exit(await ExtractDocCommand().run(args));
