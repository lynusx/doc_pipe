// bin/strip_private.dart
//
// 瘦包装：删除所有私有声明及其注释/注解。
// 实际逻辑在 package:doc_pipe（共享 harness + 命令实现）中。

import 'dart:io';

import 'package:doc_pipe/doc_pipe.dart';

Future<void> main(List<String> args) async =>
    exit(await StripPrivateCommand().run(args));
