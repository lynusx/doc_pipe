import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/file_system/physical_file_system.dart';

/// 所需的 AST 解析层级。
enum AnalysisNeed {
  /// 不需要 AST（纯字符串/正则处理）。
  none,

  /// 需要语法解析单元（token stream + lineInfo）。
  parsed,

  /// 需要完全解析单元（含类型信息）。
  resolved,
}

/// 封装 parseString 调用，返回 [ParseStringResult]。
ParseStringResult loadParsed(String absolutePath, String source) {
  return parseString(
    content: source,
    path: absolutePath,
    throwIfDiagnostics: false,
  );
}

/// 封装 AnalysisContextCollection，返回 [ResolvedUnitResult]。
///
/// 抛出异常时由调用方（子类 transform）处理。
Future<ResolvedUnitResult> loadResolved(String absolutePath) async {
  final collection = AnalysisContextCollection(
    includedPaths: [absolutePath],
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );
  final context = collection.contextFor(absolutePath);
  final raw = await context.currentSession.getResolvedUnit(absolutePath);
  if (raw is! ResolvedUnitResult) {
    throw StateError(
      '无法获取 ResolvedUnitResult：$absolutePath（结果类型：${raw.runtimeType}）',
    );
  }
  return raw;
}

/// 为一批文件批量构建 [AnalysisContextCollection]（避免对每个文件单独创建上下文）。
AnalysisContextCollection buildCollection(List<String> absolutePaths) {
  return AnalysisContextCollection(
    includedPaths: absolutePaths,
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );
}
