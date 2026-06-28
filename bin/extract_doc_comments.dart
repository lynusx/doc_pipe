// bin/extract_doc_comments.dart

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
//
// Unified CLI contract:
//
//   dart run extract_doc_comments.dart <path> [options]
//
//   <path>              Required. A .dart file or directory (recursed).
//   -o, --output=<p>    Output file (single-file input) or output root
//                        directory (directory input — relative structure is
//                        preserved). Omit to overwrite the input in place.
//   -n, --dry-run       Preview mode: print what would be written, write
//                        nothing to disk.
//   -h, --help          Show usage and exit.

void main(List<String> args) {
  final parser = ArgParser()
    ..addOption(
      'output',
      abbr: 'o',
      help:
          'Output file (single-file input) or directory (dir input). '
          'Omit to overwrite the input in place.',
    )
    ..addFlag(
      'dry-run',
      abbr: 'n',
      negatable: false,
      help: 'Preview mode: print what would change, write nothing to disk.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  late final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    stderr.writeln('Error: $e');
    _printUsage(parser);
    exit(1);
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  if (results.rest.isEmpty) {
    stderr.writeln('Error: no input path supplied.');
    _printUsage(parser);
    exit(1);
  }

  final inputPath = results.rest.first;
  final outputArg = results['output'] as String?;
  final dryRun = results['dry-run'] as bool;

  final entityType = FileSystemEntity.typeSync(inputPath);
  if (entityType == FileSystemEntityType.notFound) {
    stderr.writeln('Error: path not found: $inputPath');
    exit(1);
  }

  final isSingleFile = entityType == FileSystemEntityType.file;

  _validateOutputType(outputArg: outputArg, isSingleFile: isSingleFile);

  if (isSingleFile) {
    _runSingleFile(inputPath, outputArg, dryRun: dryRun);
  } else {
    _runDirectory(inputPath, outputArg, dryRun: dryRun);
  }
}

// ---------------------------------------------------------------------------
// --output vs <path> type validation
// ---------------------------------------------------------------------------

/// Ensures `--output` is compatible with the input's type.
///
/// A *file* input must not be pointed at something that is clearly a
/// directory (an existing directory, or a path ending in a separator). A
/// *directory* input must not be pointed at an existing file. Paths that
/// don't exist yet and aren't directory-shaped are accepted — they will be
/// created as needed by the relevant run path.
void _validateOutputType({
  required String? outputArg,
  required bool isSingleFile,
}) {
  if (outputArg == null) return;

  final looksLikeDir =
      outputArg.endsWith('/') || outputArg.endsWith(p.separator);
  final outputType = FileSystemEntity.typeSync(outputArg);

  if (isSingleFile &&
      (outputType == FileSystemEntityType.directory || looksLikeDir)) {
    stderr.writeln(
      'Error: input is a file but --output points to a directory: '
      '$outputArg',
    );
    exit(1);
  }

  if (!isSingleFile && outputType == FileSystemEntityType.file) {
    stderr.writeln(
      'Error: input is a directory but --output points to an existing '
      'file: $outputArg',
    );
    exit(1);
  }
}

// ---------------------------------------------------------------------------
// Single-file run
// ---------------------------------------------------------------------------

void _runSingleFile(
  String inputPath,
  String? outputArg, {
  required bool dryRun,
}) {
  if (!inputPath.endsWith('.dart')) {
    stderr.writeln('Error: not a .dart file: $inputPath');
    exit(1);
  }

  final outPath = outputArg ?? inputPath;
  final result = _processFile(
    inputPath,
    outPath,
    isSingleFile: true,
    dryRun: dryRun,
  );

  if (result == _Result.error) {
    exit(1);
  } else if (!dryRun) {
    // In dry-run mode, _processFile has already emitted the unified
    // `[dry-run]` log line for this file — nothing more to print here.
    if (result == _Result.written) {
      print('Written: $outPath');
    } else {
      print('Skipped (no /// comments): $inputPath');
    }
  }
}

// ---------------------------------------------------------------------------
// Directory run
// ---------------------------------------------------------------------------

void _runDirectory(
  String inputPath,
  String? outputArg, {
  required bool dryRun,
}) {
  final files = _collectDartFiles(inputPath);
  if (files.isEmpty) {
    print('No .dart files found under: $inputPath');
    exit(0);
  }

  int written = 0;
  int errors = 0;

  for (final file in files) {
    final outPath = outputArg == null
        ? file
        : p.join(outputArg, p.relative(file, from: inputPath));

    final result = _processFile(
      file,
      outPath,
      isSingleFile: false,
      dryRun: dryRun,
    );

    switch (result) {
      case _Result.written:
        written++;
      case _Result.error:
        errors++;
      case _Result.skipped:
        break; // silent (and, in dry-run mode, already logged as no-change)
    }
  }

  // Aggregate, not a per-file dry-run log line, so the unified
  // `[dry-run]` format above doesn't apply to this summary.
  final verb = dryRun ? 'Would write' : 'Written';
  print(
    'Summary — $verb: $written file(s)${errors > 0 ? ', Errors: $errors' : ''}.',
  );
  if (errors > 0) exit(1);
}

// ---------------------------------------------------------------------------
// Per-file pipeline
// ---------------------------------------------------------------------------

enum _Result { written, skipped, error }

_Result _processFile(
  String inputPath,
  String outputPath, {
  required bool isSingleFile,
  required bool dryRun,
}) {
  // 1. Read ─────────────────────────────────────────────────────────────────
  String source;
  try {
    source = File(inputPath).readAsStringSync();
  } catch (e) {
    stderr.writeln('Error reading "$inputPath": $e');
    if (dryRun) {
      _printDryRunLine(ok: false, path: inputPath, errorReason: 'io error');
    }
    if (isSingleFile) exit(1);
    return _Result.error;
  }

  // 2. Parse ────────────────────────────────────────────────────────────────
  late final ParseStringResult parsed;
  try {
    parsed = parseString(
      content: source,
      path: inputPath,
      throwIfDiagnostics: false, // surface errors ourselves
    );
  } catch (e) {
    stderr.writeln('Error parsing "$inputPath": $e');
    if (dryRun) {
      _printDryRunLine(ok: false, path: inputPath, errorReason: 'parse error');
    }
    return _Result.error;
  }

  // 3. Extract via AST token walk (core logic — unchanged) ──────────────────
  final groups = _extractDocCommentGroups(parsed);

  if (groups.isEmpty) {
    if (dryRun) {
      final label = isSingleFile ? inputPath : outputPath;
      _printDryRunLine(ok: true, path: label, stats: _DryRunStats.noChanges);
    }
    return _Result.skipped; // no /// comments – do not write
  }

  // 4. Format: groups joined by a single blank line; trailing newline ───────
  final output = _formatGroups(groups);

  // 5. Write — or, in dry-run mode, just preview ─────────────────────────────
  if (dryRun) {
    final label = isSingleFile ? inputPath : outputPath;
    final stats = _computeDryRunStats(
      outputPath: outputPath,
      newContent: output,
      groups: groups,
    );
    _printDryRunLine(ok: true, path: label, stats: stats);
    return stats.hasChanges ? _Result.written : _Result.skipped;
  }

  try {
    final outFile = File(outputPath);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(output);
  } catch (e) {
    stderr.writeln('Error writing "$outputPath": $e');
    if (isSingleFile) exit(1);
    return _Result.error;
  }

  return _Result.written;
}

// ---------------------------------------------------------------------------
// Dry-run logging
// ---------------------------------------------------------------------------
//
// Unified single-line format, e.g.:
//   [dry-run]  (√) lib/src/widget.dart (3 inserts, 2 deletes, 1 modify)
//   [dry-run]  (×) lib/src/broken.dart (parse error)
//
// "inserts/deletes/modifies" come from a real line diff between what is
// currently on disk at the output path (if anything) and what this run
// would write there — so re-running with no source changes correctly
// reports "(no changes)" instead of fabricated activity.
//
// "merges" is not diff-based: it's an honest count of the one real merge
// operation this tool performs regardless of any previous run — joining
// N contiguous `///` lines into a single block is N-1 line merges.
//
// TODO: colorize (√)/(×)/[dry-run] when stdout is a terminal, respecting
// NO_COLOR. Intentionally not implemented yet.

class _DryRunStats {
  final int inserts;
  final int deletes;
  final int modifies;
  final int merges;
  final bool hasChanges;

  const _DryRunStats({
    required this.inserts,
    required this.deletes,
    required this.modifies,
    required this.merges,
    required this.hasChanges,
  });

  static const noChanges = _DryRunStats(
    inserts: 0,
    deletes: 0,
    modifies: 0,
    merges: 0,
    hasChanges: false,
  );
}

_DryRunStats _computeDryRunStats({
  required String outputPath,
  required String newContent,
  required List<List<String>> groups,
}) {
  // Real, algorithm-grounded stat: every group of N (N > 1) contiguous
  // `///` lines is joined into one block, i.e. N-1 merges per group.
  final merges = groups.fold<int>(
    0,
    (sum, g) => sum + (g.length > 1 ? g.length - 1 : 0),
  );

  String? oldContent;
  final destFile = File(outputPath);
  if (destFile.existsSync()) {
    try {
      oldContent = destFile.readAsStringSync();
    } catch (e) {
      // Diagnostics go to stderr; the dry-run preview on stdout stays
      // a single clean line and just falls back to "nothing on disk yet".
      stderr.writeln(
        'Warning: could not read existing "$outputPath" for diff preview: $e',
      );
    }
  }

  if (oldContent == null) {
    final lineCount = newContent.isEmpty
        ? 0
        : const LineSplitter().convert(newContent).length;
    return _DryRunStats(
      inserts: lineCount,
      deletes: 0,
      modifies: 0,
      merges: merges,
      hasChanges: lineCount > 0,
    );
  }

  if (oldContent == newContent) {
    return _DryRunStats.noChanges;
  }

  final diff = _diffLines(
    const LineSplitter().convert(oldContent),
    const LineSplitter().convert(newContent),
  );

  return _DryRunStats(
    inserts: diff.inserts,
    deletes: diff.deletes,
    modifies: diff.modifies,
    merges: merges,
    hasChanges: true,
  );
}

void _printDryRunLine({
  required bool ok,
  required String path,
  _DryRunStats? stats,
  String? errorReason,
}) {
  final mark = ok ? '(√)' : '(×)';
  final detail = ok ? _formatStats(stats!) : '(${errorReason ?? 'error'})';
  print('[dry-run]  $mark $path $detail');
}

String _formatStats(_DryRunStats stats) {
  if (!stats.hasChanges) return '(no changes)';

  final parts = <String>[];
  void add(int n, String singular, String plural) {
    if (n > 0) parts.add('$n ${n == 1 ? singular : plural}');
  }

  add(stats.inserts, 'insert', 'inserts');
  add(stats.deletes, 'delete', 'deletes');
  add(stats.modifies, 'modify', 'modifies');
  add(stats.merges, 'merge', 'merges');

  return parts.isEmpty ? '(no changes)' : '(${parts.join(', ')})';
}

// ---------------------------------------------------------------------------
// Line diff (LCS-based) — used only to derive honest dry-run stats
// ---------------------------------------------------------------------------

enum _EditOp { equal, insert, delete }

class _LineDiffResult {
  final int inserts;
  final int deletes;
  final int modifies;
  const _LineDiffResult({
    required this.inserts,
    required this.deletes,
    required this.modifies,
  });
}

/// Diffs [oldLines] against [newLines] and classifies the differences.
///
/// A contiguous run of deletes immediately followed by a contiguous run of
/// inserts is treated as a "change block": lines are paired 1:1 as
/// modifications, with any length mismatch reported as leftover pure
/// inserts or deletes.
_LineDiffResult _diffLines(List<String> oldLines, List<String> newLines) {
  final ops = _lcsDiffOps(oldLines, newLines);

  int inserts = 0, deletes = 0, modifies = 0;
  int i = 0;
  while (i < ops.length) {
    if (ops[i] == _EditOp.equal) {
      i++;
      continue;
    }
    int delRun = 0, insRun = 0;
    while (i < ops.length && ops[i] == _EditOp.delete) {
      delRun++;
      i++;
    }
    while (i < ops.length && ops[i] == _EditOp.insert) {
      insRun++;
      i++;
    }
    final paired = delRun < insRun ? delRun : insRun;
    modifies += paired;
    deletes += delRun - paired;
    inserts += insRun - paired;
  }

  return _LineDiffResult(
    inserts: inserts,
    deletes: deletes,
    modifies: modifies,
  );
}

/// Classic O(n*m) LCS-based line diff. Doc-comment blocks are small enough
/// in practice (extracted comments, not full source trees) that the
/// quadratic table is not a real concern.
List<_EditOp> _lcsDiffOps(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] > lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final ops = <_EditOp>[];
  int i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      ops.add(_EditOp.equal);
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      ops.add(_EditOp.delete);
      i++;
    } else {
      ops.add(_EditOp.insert);
      j++;
    }
  }
  while (i < n) {
    ops.add(_EditOp.delete);
    i++;
  }
  while (j < m) {
    ops.add(_EditOp.insert);
    j++;
  }
  return ops;
}

// ---------------------------------------------------------------------------
// Core extraction logic (AST-based, no regex) — UNCHANGED
// ---------------------------------------------------------------------------

/// A "group" is a contiguous block of adjacent /// lines in the source.
/// Adjacent means: each line's [lineNumber] == previous + 1.
///
/// Returns a list of groups; each group is a list of `/// …` lexemes.
List<List<String>> _extractDocCommentGroups(ParseStringResult parsed) {
  final LineInfo lineInfo = parsed.unit.lineInfo;

  // Collect every doc-comment-shaped SINGLE_LINE_COMMENT token in source
  // order, together with its 1-based line number so we can detect adjacency.
  final List<({int lineNumber, String lexeme})> docTokens = [];

  Token tok = parsed.unit.beginToken;
  while (true) {
    // Each main-stream token may have a chain of preceding comment tokens.
    Token? comment = tok.precedingComments;
    while (comment != null) {
      if (comment.type == TokenType.SINGLE_LINE_COMMENT &&
          comment.lexeme.startsWith('///') &&
          !comment.lexeme.startsWith('////')) {
        final line = lineInfo.getLocation(comment.offset).lineNumber;
        docTokens.add((lineNumber: line, lexeme: comment.lexeme));
      }
      comment = comment.next;
    }
    if (tok.type == TokenType.EOF) break;
    tok = tok.next!;
  }

  if (docTokens.isEmpty) return [];

  // Group into contiguous blocks (consecutive line numbers).
  final List<List<String>> groups = [];
  List<String> currentGroup = [docTokens.first.lexeme];
  int prevLine = docTokens.first.lineNumber;

  for (int i = 1; i < docTokens.length; i++) {
    final entry = docTokens[i];
    if (entry.lineNumber == prevLine + 1) {
      // Adjacent to previous – same group.
      currentGroup.add(entry.lexeme);
    } else {
      // Gap → start a new group.
      groups.add(currentGroup);
      currentGroup = [entry.lexeme];
    }
    prevLine = entry.lineNumber;
  }
  groups.add(currentGroup);

  return groups;
}

// ---------------------------------------------------------------------------
// Formatting — UNCHANGED
// ---------------------------------------------------------------------------

String _formatGroups(List<List<String>> groups) {
  // Within each group: join lines with '\n' (trim trailing whitespace).
  // Between groups: single blank line.
  final sb = StringBuffer();
  for (int i = 0; i < groups.length; i++) {
    if (i > 0) sb.write('\n'); // blank separator line between groups
    for (final line in groups[i]) {
      sb.writeln(line.trimRight());
    }
  }
  // Ensure file ends with exactly one newline (writeln already adds one
  // after the last line of the last group, so nothing extra needed).
  return sb.toString();
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

List<String> _collectDartFiles(String dirPath) {
  return Directory(dirPath)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.path)
      .toList()
    ..sort();
}

void _printUsage(ArgParser parser) {
  print('''
Usage: dart run extract_doc_comments.dart <path> [options]

  <path>   A .dart file or a directory (processed recursively).

${parser.usage}

Examples:
  # Overwrite a single file in-place:
  dart run extract_doc_comments.dart lib/src/my_widget.dart

  # Write to a different output file:
  dart run extract_doc_comments.dart -o /tmp/docs.dart lib/src/my_widget.dart

  # Process a whole directory tree, overwriting each file in-place:
  dart run extract_doc_comments.dart lib/

  # Process a directory tree, writing results to another directory:
  dart run extract_doc_comments.dart -o /tmp/out/ lib/

  # Preview what a directory run would write, without touching disk:
  dart run extract_doc_comments.dart -n lib/
''');
}
