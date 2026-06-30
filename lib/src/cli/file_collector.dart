import 'dart:io';

import 'package:path/path.dart' as p;

import 'console.dart';

/// 递归收集 [dir] 下所有 `.dart` 文件，跳过 `.dart_tool/`、`build/` 及隐藏目录。
List<File> collectDartFiles(Directory dir) {
  final result = <File>[];
  try {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      final parts = p.split(path);
      final skip = parts.any(
        (s) =>
            s == '.dart_tool' ||
            s == 'build' ||
            (s.startsWith('.') && s.length > 1),
      );
      if (skip) continue;
      if (!path.endsWith('.dart')) continue;
      result.add(entity);
    }
  } on FileSystemException catch (e) {
    Console.error('无法读取目录：${dir.path}（${e.osError?.message ?? e.message}）');
    exit(1);
  }
  return result;
}
