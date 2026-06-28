// bin/doc_pipe.dart
//
// 瘦包装：一键式文档注释处理管道编排器。
// 按固定顺序串行调用同目录下的其余 6 个包装脚本（子进程）。
// 实际逻辑在 package:doc_pipe 的 Pipeline 中。

import 'dart:io';

import 'package:doc_pipe/doc_pipe.dart';

Future<void> main(List<String> args) async =>
    exit(await const Pipeline().run(args));
