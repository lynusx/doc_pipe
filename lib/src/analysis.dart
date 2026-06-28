// lib/src/analysis.dart
//
// 统一的 `package:analyzer` 访问层。
//
// 重构前，inserter / strip_private / merge 各自重复了同一套样板：
//   canonicalize → new AnalysisContextCollection → contextFor → currentSession
//   → getResolvedUnit → 检查 is ResolvedUnitResult → 处理失败。
// extract 则走更轻量的 `parseString`（不做解析上下文/类型解析）。
//
// 这里把「解析上下文的创建与单元获取」收敛为一个按需懒加载、整轮共享一个
// AnalysisContextCollection 的服务对象，从而：
//   * 消除三处重复的上下文搭建代码；
//   * 让原本逐文件各建一个 collection 的 strip_private / merge 改为共享，
//     在常见的整目录处理中更快；
//   * 保留三种细分语义（普通解析 / 解析并暴露 ERROR 诊断 / 解析失败回退到
//     纯语法分析），分别对应三个方法。

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart' show parseString;
import 'package:analyzer/dart/ast/ast.dart' show CompilationUnit;
import 'package:analyzer/error/error.dart' show ErrorSeverity;
import 'package:analyzer/file_system/physical_file_system.dart';

import 'dry_run.dart' show ParseFailure;

export 'package:analyzer/dart/analysis/results.dart' show ResolvedUnitResult;
export 'package:analyzer/dart/analysis/utilities.dart' show ParseStringResult;
export 'package:analyzer/dart/ast/ast.dart';

/// 整轮处理共享的 analyzer 解析服务。
///
/// 以输入根（单文件输入时为该文件、目录输入时为该目录）为 `includedPaths`
/// 懒加载一个 [AnalysisContextCollection]。`contextFor` 可解析根目录下的任意
/// 文件，因此整轮只需一个 collection；跨文件引用（如 `super.field` 的类型
/// 解析）仍由 analyzer 通过常规 import 解析得到，与逐文件建 collection 的旧
/// 行为产出一致。
class AnalysisService {
  AnalysisService(this._rootPath);

  final String _rootPath;
  AnalysisContextCollection? _collection;

  AnalysisContextCollection get _coll =>
      _collection ??= AnalysisContextCollection(
        includedPaths: [_rootPath],
        resourceProvider: PhysicalResourceProvider.INSTANCE,
      );

  /// 获取 [absolutePath] 的已解析单元（含类型信息）。
  ///
  /// 解析失败抛出 [ParseFailure]。当 [surfaceErrors] 为 true 时，存在
  /// ERROR 级诊断也会抛出 [ParseFailure]（strip_private 的语义）。
  Future<ResolvedUnitResult> resolved(
    String absolutePath, {
    bool surfaceErrors = false,
  }) async {
    final session = _coll.contextFor(absolutePath).currentSession;
    final result = await session.getResolvedUnit(absolutePath);
    if (result is! ResolvedUnitResult) {
      throw ParseFailure('无法解析（结果类型：${result.runtimeType}）：$absolutePath');
    }
    if (surfaceErrors) {
      final errors = result.errors
          .where((e) => e.severity == ErrorSeverity.ERROR)
          .toList();
      if (errors.isNotEmpty) {
        final msg = errors.map((e) => e.toString()).join('\n  ');
        throw ParseFailure('parse errors\n  $msg');
      }
    }
    return result;
  }

  /// 获取 [absolutePath] 的 [CompilationUnit]：优先返回已解析单元，解析不成
  /// 功时回退到纯语法分析（merge 的语义——它只需要 token 流与 lineInfo）。
  Future<CompilationUnit> unit(String absolutePath) async {
    final session = _coll.contextFor(absolutePath).currentSession;
    final result = await session.getResolvedUnit(absolutePath);
    if (result is ResolvedUnitResult) return result.unit;

    final parsed = session.getParsedUnit(absolutePath);
    if (parsed is! ParsedUnitResult) {
      throw ParseFailure('无法解析文件，请检查是否为有效的 Dart 源码：$absolutePath');
    }
    return parsed.unit;
  }
}

/// 轻量解析：不创建解析上下文，直接对内存中的 [source] 做语法分析。
///
/// 对应 extract 的用法（只需 AST/token，不需类型解析），开销远小于
/// [AnalysisService.resolved]。诊断不抛出，由调用方按需检查 `result.errors`。
ParseStringResult parseSource(String source, String path) {
  return parseString(content: source, path: path, throwIfDiagnostics: false);
}
