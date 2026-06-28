/// bin/strip_private.dart
///
/// A command-line tool that removes all private declarations (and their
/// associated comments / annotations) from Dart source files using the
/// `package:analyzer` AST API.
///
/// Usage:
///   dart run strip_private.dart <path> [options]
///
/// See `--help` for the full option list.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

// ═══════════════════════════════════════════════════════════════════════════
// Entry point
// ═══════════════════════════════════════════════════════════════════════════

Future<void> main(List<String> args) async {
  final parser = _buildArgParser();

  ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (results['help'] as bool) {
    _printHelp(parser);
    exit(0);
  }

  if (results.rest.isEmpty) {
    stderr.writeln('Error: Missing required <path> argument.');
    stderr.writeln(parser.usage);
    exit(1);
  }

  final targetPath = results.rest.first;
  final dryRun = results['dry-run'] as bool;
  final outputPath = results['output'] as String?;

  // ── Collect target .dart files ──────────────────────────────────────────

  final targetType = FileSystemEntity.typeSync(targetPath);
  if (targetType == FileSystemEntityType.notFound) {
    stderr.writeln('Error: Path not found: $targetPath');
    exit(1);
  }

  final isSingleFile = targetType == FileSystemEntityType.file;
  final files = <File>[];

  if (isSingleFile) {
    if (!targetPath.endsWith('.dart')) {
      stderr.writeln('Error: File is not a .dart file: $targetPath');
      exit(1);
    }
    files.add(File(targetPath));
  } else {
    files.addAll(_collectDartFiles(Directory(targetPath)));
  }

  if (files.isEmpty) {
    stdout.writeln('No .dart files found under $targetPath.');
    exit(0);
  }

  // ── Validate --output type compatibility ─────────────────────────────────
  //
  // Guard against mismatched modes: a single-file input must not target an
  // existing directory, and a directory input must not target an existing file.
  // (Non-existent output paths are created lazily in _processFile.)

  if (outputPath != null) {
    final outType = FileSystemEntity.typeSync(outputPath);
    if (isSingleFile && outType == FileSystemEntityType.directory) {
      stderr.writeln(
        'Error: --output "$outputPath" is a directory, '
        'but <path> is a single file.',
      );
      exit(1);
    }
    if (!isSingleFile && outType == FileSystemEntityType.file) {
      stderr.writeln(
        'Error: --output "$outputPath" is a file, '
        'but <path> is a directory.',
      );
      exit(1);
    }
  }

  // ── Process each file ───────────────────────────────────────────────────

  var hadErrors = false;
  for (final file in files) {
    final success = await _processFile(
      file: file,
      dryRun: dryRun,
      outputPath: outputPath,
      isSingleFile: isSingleFile,
      rootPath: targetPath,
    );
    if (!success) hadErrors = true;
  }

  exit(hadErrors ? 1 : 0);
}

// ═══════════════════════════════════════════════════════════════════════════
// CLI helpers
// ═══════════════════════════════════════════════════════════════════════════

ArgParser _buildArgParser() => ArgParser()
  ..addFlag(
    'dry-run',
    abbr: 'n',
    negatable: false,
    help: 'Preview mode: print regions that would be deleted (no disk writes).',
  )
  ..addOption(
    'output',
    abbr: 'o',
    valueHelp: 'path',
    help:
        'Output path. Single-file input: target file path. '
        'Directory input: target root directory (preserving relative structure). '
        'Omitted means overwrite in place.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Show this help message.',
  );

void _printHelp(ArgParser parser) {
  stdout
    ..writeln('Usage: dart run strip_private.dart <path> [options]\n')
    ..writeln('Arguments:')
    ..writeln(
      '  <path>    Target .dart file or directory (absolute or relative)\n',
    )
    ..writeln('Options:')
    ..writeln(parser.usage);
}

// ═══════════════════════════════════════════════════════════════════════════
// File collection
// ═══════════════════════════════════════════════════════════════════════════

/// Recursively collects all `.dart` files under [dir], skipping `.dart_tool/`
/// and `build/` subdirectories.
List<File> _collectDartFiles(Directory dir) {
  final results = <File>[];
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final path = entity.path;

    // Skip compiler / tool artefact directories.
    final parts = p.split(path);
    if (parts.any((s) => s == '.dart_tool' || s == 'build')) continue;

    if (!path.endsWith('.dart')) continue;

    results.add(entity);
  }
  return results;
}

// ═══════════════════════════════════════════════════════════════════════════
// Dry-run logging
// ═══════════════════════════════════════════════════════════════════════════

/// Emits a single `[dry-run]` log line to [stdout].
///
/// Format: `[dry-run]  (√/×) <path> (<summary>)`
///
/// [path]    – absolute or cwd-relative path to the file.
/// [ok]      – `true` for success `(√)`, `false` for failure `(×)`.
/// [summary] – operation summary string, e.g. `"5 deletes"` or `"parse error"`.
void _logDryRun({
  required String path,
  required bool ok,
  required String summary,
}) {
  final mark = ok ? '(√)' : '(×)';
  stdout.writeln('[dry-run]  $mark $path ($summary)');
}

/// Builds a human-readable operation-count summary from a [_DryRunStats] object.
///
/// Examples:
///   `"no changes"` – nothing to do.
///   `"3 deletes"` – only deletions.
///   `"3 deletes, 1 skip"` – multiple operation types.
String _formatStats(_DryRunStats stats) {
  if (stats.isEmpty) return 'no changes';

  final parts = <String>[];

  void add(int n, String singular, String plural) {
    if (n > 0) parts.add('$n ${n == 1 ? singular : plural}');
  }

  add(stats.deletes, 'delete', 'deletes');
  add(stats.inserts, 'insert', 'inserts');
  add(stats.modifies, 'modify', 'modifies');
  add(stats.merges, 'merge', 'merges');
  add(stats.skips, 'skip', 'skips');

  return parts.join(', ');
}

// ═══════════════════════════════════════════════════════════════════════════
// Per-file orchestration
// ═══════════════════════════════════════════════════════════════════════════

/// Processes a single file.
///
/// Returns `true` on success, `false` when an error occurs.
/// In dry-run mode, emits a single `[dry-run]` log line instead of writing
/// to disk; errors are reported on [stderr] with a `(×)` summary on [stdout].
Future<bool> _processFile({
  required File file,
  required bool dryRun,
  required String? outputPath,
  required bool isSingleFile,
  required String rootPath,
}) async {
  // p.canonicalize resolves symlinks and removes any `.` / `..` segments,
  // producing the fully-normalized absolute path that AnalysisContextCollection
  // requires on all platforms (including Windows where `.\` is not stripped
  // by p.absolute alone).
  final absolutePath = p.canonicalize(file.path);

  String source;
  try {
    source = file.readAsStringSync();
  } catch (e) {
    if (dryRun) {
      _logDryRun(path: absolutePath, ok: false, summary: 'io error');
      stderr.writeln('[error] ${file.path}: $e');
    } else {
      stderr.writeln('Error processing ${file.path}: $e');
    }
    return false;
  }

  // Use AnalysisContextCollection so that `package:` imports can be resolved
  // and the analysis inherits the nearest `analysis_options.yaml` / pubspec.
  final collection = AnalysisContextCollection(
    includedPaths: [absolutePath],
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );

  final context = collection.contextFor(absolutePath);
  final session = context.currentSession;

  ResolvedUnitResult unitResult;
  try {
    final raw = await session.getResolvedUnit(absolutePath);
    if (raw is! ResolvedUnitResult) {
      throw Exception(
        'Could not obtain a resolved unit for ${file.path}. '
        'Result type: ${raw.runtimeType}',
      );
    }
    unitResult = raw;
  } catch (e, st) {
    if (dryRun) {
      _logDryRun(path: absolutePath, ok: false, summary: 'parse error');
      stderr.writeln('[error] ${file.path}: $e\n$st');
    } else {
      stderr.writeln('Error processing ${file.path}: $e\n$st');
    }
    return false;
  }

  // Surface hard parse errors (warnings / hints are intentionally ignored).
  final parseErrors = unitResult.errors
      .where((e) => e.severity == ErrorSeverity.ERROR)
      .toList();
  if (parseErrors.isNotEmpty) {
    if (dryRun) {
      _logDryRun(path: absolutePath, ok: false, summary: 'parse error');
      final msg = parseErrors.map((e) => e.toString()).join('\n  ');
      stderr.writeln('[error] ${file.path}: parse errors\n  $msg');
    } else {
      final msg = parseErrors.map((e) => e.toString()).join('\n  ');
      stderr.writeln('Error processing ${file.path}: parse errors\n  $msg');
    }
    return false;
  }

  // Collect the intervals to delete using the AST visitor.
  final collector = _PrivateRegionCollector(source);
  collector.visitCompilationUnit(unitResult.unit);
  final intervals = collector.mergedIntervals();

  if (dryRun) {
    final stats = _DryRunStats(deletes: intervals.length);
    _logDryRun(path: absolutePath, ok: true, summary: _formatStats(stats));
    return true;
  }

  if (intervals.isEmpty) return true; // Nothing to change.

  final result = _applyDeletions(source, intervals);

  // ── Determine output destination ────────────────────────────────────────
  //
  // Single-file mode: --output is the verbatim target file path.
  // Directory mode:   --output is the root; relative structure is preserved.
  // No --output:      overwrite the source file in place.

  final File dest;
  if (outputPath != null) {
    if (isSingleFile) {
      dest = File(outputPath);
    } else {
      final relPath = p.relative(file.path, from: rootPath);
      dest = File(p.join(outputPath, relPath));
    }
    dest.parent.createSync(recursive: true);
  } else {
    dest = file;
  }

  try {
    dest.writeAsStringSync(result);
  } catch (e) {
    stderr.writeln('Error writing ${dest.path}: $e');
    return false;
  }

  stdout.writeln('Processed: ${file.path}');
  return true;
}

// ═══════════════════════════════════════════════════════════════════════════
// Dry-run statistics value type
// ═══════════════════════════════════════════════════════════════════════════

/// Holds per-file operation counts for dry-run reporting.
///
/// Extend with additional fields (inserts, modifies, merges, skips) when
/// the tool gains those capabilities; [_formatStats] already handles them.
final class _DryRunStats {
  const _DryRunStats({
    this.deletes = 0,
    this.inserts = 0,
    this.modifies = 0,
    this.merges = 0,
    this.skips = 0,
  });

  final int deletes;
  final int inserts;
  final int modifies;
  final int merges;
  final int skips;

  /// Returns `true` when no operations of any kind were recorded.
  bool get isEmpty =>
      deletes == 0 &&
      inserts == 0 &&
      modifies == 0 &&
      merges == 0 &&
      skips == 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Source transformation
// ═══════════════════════════════════════════════════════════════════════════

/// Builds the final source string by removing all [intervals] from [source]
/// and collapsing consecutive blank lines.
///
/// [intervals] must already be sorted and non-overlapping (use
/// [_PrivateRegionCollector.mergedIntervals]).
String _applyDeletions(String source, List<_Interval> intervals) {
  final buf = StringBuffer();
  var cursor = 0;

  for (final iv in intervals) {
    if (iv.start > cursor) {
      buf.write(source.substring(cursor, iv.start));
    }
    cursor = iv.end;
  }
  if (cursor < source.length) {
    buf.write(source.substring(cursor));
  }

  var result = buf.toString();

  // §III.3 — Compress any run of 3+ consecutive newlines (2+ blank lines)
  // down to 2 newlines (1 blank line).  We iterate until stable so that
  // longer runs are fully compressed.
  String prev;
  do {
    prev = result;
    result = result.replaceAll('\n\n\n', '\n\n');
  } while (result != prev);

  // §III.4 — If only whitespace remains, write an empty file.
  if (result.trim().isEmpty) return '';

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// Core AST visitor
// ═══════════════════════════════════════════════════════════════════════════

/// Walks [CompilationUnit.declarations] and the members of every public
/// [ClassDeclaration], collecting source intervals to delete.
///
/// **Design decisions:**
/// - We do NOT recurse into function bodies.  This is intentional: local
///   variables, formal parameters, and pattern-match bindings that happen to
///   start with `_` are explicitly excluded (§I.3).
/// - We use [CompilationUnitMember] / [ClassMember] node kinds rather than
///   visiting every node in the tree, so we never accidentally delete inner
///   locals even if they carry a `_` prefix.
class _PrivateRegionCollector {
  _PrivateRegionCollector(this._source);

  final String _source;
  final List<_Interval> _raw = [];

  // ── Public entry point ────────────────────────────────────────────────

  void visitCompilationUnit(CompilationUnit unit) {
    for (final decl in unit.declarations) {
      _handleTopLevel(decl);
    }
  }

  // ── Top-level declarations (§I.1) ────────────────────────────────────

  void _handleTopLevel(CompilationUnitMember decl) {
    // Resolve the primary identifier of this top-level declaration so we can
    // check whether it starts with '_'.
    final name = _primaryName(decl);

    if (name != null && _isPrivate(name)) {
      // Private top-level node → delete entirely; do NOT recurse.
      _collectNode(decl);
      return;
    }

    // Public ClassDeclaration → inspect each member individually (§I.2).
    // (EnumDeclaration / MixinDeclaration / ExtensionDeclaration members are
    // NOT subject to per-member stripping; they are only removed when the
    // containing declaration itself is private, handled above.)
    if (decl is ClassDeclaration) {
      _handleClassMembers(decl);
    }
  }

  /// Returns the single primary identifier lexeme of [decl], or `null` when
  /// the node has no name (e.g. an unnamed `extension on X {}`).
  ///
  /// For [TopLevelVariableDeclaration] we return a sentinel only when ALL
  /// variables in the declaration are private; mixed-visibility multi-variable
  /// declarations are left untouched.
  String? _primaryName(CompilationUnitMember decl) {
    // ClassDeclaration  →  `class Foo { … }`
    if (decl is ClassDeclaration) return decl.name.lexeme;

    // ClassTypeAlias  →  `class Foo = Bar with Mixin;`
    if (decl is ClassTypeAlias) return decl.name.lexeme;

    // EnumDeclaration  →  `enum Foo { … }`
    if (decl is EnumDeclaration) return decl.name.lexeme;

    // MixinDeclaration  →  `mixin Foo on Base { … }`
    if (decl is MixinDeclaration) return decl.name.lexeme;

    // ExtensionDeclaration  →  `extension Foo on Type { … }`
    // Unnamed extensions have `name == null`; we return null so they are kept.
    if (decl is ExtensionDeclaration) return decl.name?.lexeme;

    // FunctionDeclaration  →  `void foo() { … }` / `get foo => …`
    if (decl is FunctionDeclaration) return decl.name.lexeme;

    // TopLevelVariableDeclaration  →  `final _x = 1, _y = 2;`
    // Delete only when every declared variable in the list is private.
    if (decl is TopLevelVariableDeclaration) {
      final vars = decl.variables.variables;
      if (vars.isNotEmpty && vars.every((v) => _isPrivate(v.name.lexeme))) {
        return vars.first.name.lexeme; // Any private name works as a sentinel.
      }
      return null;
    }

    // GenericTypeAlias  →  `typedef Foo<T> = …;`
    if (decl is GenericTypeAlias) return decl.name.lexeme;

    // FunctionTypeAlias  →  `typedef void Foo()`  (legacy syntax)
    if (decl is FunctionTypeAlias) return decl.name.lexeme;

    return null;
  }

  // ── Class members of a PUBLIC class (§I.2) ───────────────────────────

  /// Inspects each member of a public [ClassDeclaration] and collects the
  /// ones that are private.
  void _handleClassMembers(ClassDeclaration classDecl) {
    for (final member in classDecl.members) {
      _handleMember(member);
    }
  }

  void _handleMember(ClassMember member) {
    // MethodDeclaration covers: instance methods, static methods,
    // getters (`get _prop`), setters (`set _prop`), and operators.
    // Operators cannot start with '_', so the _isPrivate check naturally
    // excludes them.
    if (member is MethodDeclaration) {
      if (_isPrivate(member.name.lexeme)) {
        _collectNode(member);
      }
      return;
    }

    // FieldDeclaration: `final _x = 1, _y = 2;`
    // Delete the entire declaration only when ALL variables in it are private.
    if (member is FieldDeclaration) {
      final vars = member.fields.variables;
      if (vars.isNotEmpty && vars.every((v) => _isPrivate(v.name.lexeme))) {
        _collectNode(member);
      }
      return;
    }

    // ConstructorDeclaration:
    //   - Unnamed default constructor  → `name == null`     → never private
    //   - Named constructor            → `ClassName._()`    → `name` is `_…`
    if (member is ConstructorDeclaration) {
      final ctorName = member.name?.lexeme;
      if (ctorName != null && _isPrivate(ctorName)) {
        _collectNode(member);
      }
    }
  }

  // ── Interval collection for a single node ────────────────────────────

  /// Records the full source interval that must be erased for [node],
  /// including any attached preceding comments and annotations (§II).
  void _collectNode(AstNode node) {
    final start = _commentStartOf(node);
    final end = _extendToLineEnd(node.end);
    _raw.add(_Interval(start, end));
  }

  // ── Preceding-comment resolution (§II) ───────────────────────────────

  /// Returns the source offset at which deletion should begin for [node].
  ///
  /// Rules (in priority order):
  /// 1. Walk the `precedingComments` chain on the first "real" token
  ///    (i.e. the token that begins the declaration proper, after any
  ///    doc-comment and metadata).  Collect comments that are contiguous
  ///    with the declaration — stopping as soon as a blank-line gap appears.
  /// 2. If [node] is an [AnnotatedNode], also consider its
  ///    `documentationComment.offset` (always deleted, §II table row 1).
  /// 3. Return the smallest of the offsets found, or `node.offset` if none.
  int _commentStartOf(AstNode node) {
    // The "first real token" after doc-comment and @annotations.
    final Token firstReal;
    if (node is AnnotatedNode) {
      firstReal = node.firstTokenAfterCommentAndMetadata;
    } else {
      firstReal = node.beginToken;
    }

    // Walk the precedingComments chain.
    // The chain is ordered oldest-to-newest (i.e. the first comment in the
    // file appears first in the linked list).
    int? earliestCommentOffset;
    Token? comment = firstReal.precedingComments;
    while (comment != null) {
      final nextOffset = comment.next?.offset ?? firstReal.offset;
      final between = _source.substring(comment.end, nextOffset);
      if (_hasBlankLine(between)) {
        // A blank line separates this comment from what follows.
        // This comment belongs to the surrounding context — stop collecting.
        break;
      }
      // This comment is contiguous; track its offset.
      earliestCommentOffset = comment.offset;
      comment = comment.next as Token?;
    }

    // For AnnotatedNode, also include the doc-comment (if any).
    int? docOffset;
    if (node is AnnotatedNode) {
      docOffset = node.documentationComment?.offset;
    }

    // Choose the smallest applicable start offset.
    final candidates = [
      if (earliestCommentOffset != null) earliestCommentOffset,
      if (docOffset != null) docOffset,
      node.offset,
    ];
    return candidates.reduce((a, b) => a < b ? a : b);
  }

  /// Returns `true` when [between] contains at least one blank line, i.e.
  /// two consecutive newlines (`\n\n`).
  bool _hasBlankLine(String between) => between.contains('\n\n');

  // ── Line-end extension (§III.1) ──────────────────────────────────────

  /// Advances [offset] past the end of its current line, including the
  /// trailing `\n`, so the deletion removes the entire line.
  int _extendToLineEnd(int offset) {
    var end = offset;
    while (end < _source.length && _source[end] != '\n') {
      end++;
    }
    if (end < _source.length) end++; // include the '\n'
    return end;
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  bool _isPrivate(String name) => name.startsWith('_');

  // ── Interval merging (§III.2) ─────────────────────────────────────────

  /// Sorts and merges all collected raw intervals, returning a minimal list
  /// of non-overlapping, non-adjacent intervals suitable for a single-pass
  /// deletion.
  List<_Interval> mergedIntervals() {
    if (_raw.isEmpty) return const [];

    _raw.sort((a, b) => a.start.compareTo(b.start));
    final merged = <_Interval>[_raw.first];

    for (var i = 1; i < _raw.length; i++) {
      final next = _raw[i];
      final last = merged.last;
      if (next.start <= last.end) {
        // Overlapping or adjacent intervals: extend the last merged interval.
        merged[merged.length - 1] = _Interval(
          last.start,
          next.end > last.end ? next.end : last.end,
        );
      } else {
        merged.add(next);
      }
    }
    return merged;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Value type: source interval [start, end)
// ═══════════════════════════════════════════════════════════════════════════

/// An exclusive source-offset range: characters in `[start, end)` will be
/// deleted.
final class _Interval {
  const _Interval(this.start, this.end);

  final int start; // inclusive
  final int end; // exclusive

  @override
  String toString() => 'Interval($start, $end)';
}
