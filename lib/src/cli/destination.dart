import 'dart:io';

import 'package:path/path.dart' as p;

/// 解析单个源文件的目标路径。
///
/// - [outputRoot] 为 null → 就地（返回 [sourcePath]，再由调用方替换扩展名）。
/// - 单文件输入 + [outputRoot] 非 null → [outputRoot] 即目标文件路径。
/// - 目录输入 + [outputRoot] 非 null → 在 [outputRoot] 下镜像相对结构。
///
/// [outputExtension] 不为空时替换最终路径的扩展名（如 '.md'）。
String resolveDestination({
  required String sourcePath,
  required String inputRoot,
  required bool isInputDirectory,
  required String? outputRoot,
  String outputExtension = '.dart',
}) {
  String base;
  if (outputRoot == null) {
    base = sourcePath;
  } else if (!isInputDirectory) {
    base = outputRoot;
  } else {
    final rel = p.relative(sourcePath, from: inputRoot);
    base = p.join(outputRoot, rel);
  }

  if (outputExtension != '.dart') {
    base = p.setExtension(base, outputExtension);
  }
  return base;
}

/// 检查 [outputPath] 与输入类型是否兼容，不兼容时返回可读错误描述，否则返回 null。
String? checkOutputCompatibility({
  required String outputPath,
  required bool isInputDirectory,
  String outputExtension = '.dart',
}) {
  final outputType = FileSystemEntity.typeSync(outputPath);

  if (outputType == FileSystemEntityType.directory && !isInputDirectory) {
    final example = isInputDirectory ? '' : '-o out/foo$outputExtension';
    return '--output 指向已存在的目录，但输入为单文件：$outputPath\n'
        '       单文件输入时，--output 应指定目标文件路径（如 $example）';
  }

  if (outputType == FileSystemEntityType.file && isInputDirectory) {
    return '--output 指向已存在的文件，但输入为目录：$outputPath\n'
        '       目录输入时，--output 应指定目标根目录路径（如 -o out/）';
  }

  return null;
}
