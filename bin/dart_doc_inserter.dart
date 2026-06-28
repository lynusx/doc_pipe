// bin/dart_doc_inserter.dart
//
// Dart CLI tool: inserts formatted declaration-summary doc comments into .dart
// files using the package:analyzer AST API.
//
// Usage:
//   dart pub get
//   dart run bin/dart_doc_inserter.dart <path> [options]
//
// <path> may be a single .dart file or a directory (processed recursively).
// Errors in individual files are reported and skipped; the run continues with
// remaining files and exits with code 1 if any file failed.
//
// Options
// | Flag                    | Description                                        |
// | ----------------------- | -------------------------------------------------- |
// | `-o`, `--output=<path>` | Output file (single-file input) or root directory  |
// |                         | (directory input). Omit to overwrite in place.     |
// | `-n`, `--dry-run`       | Print what would change without writing any files  |
// | `-h`, `--help`          | Show usage                                         |
//
// Examples
// ```bash
// # Process a single file (overwrite in place)
// dart run bin/dart_doc_inserter.dart lib/models/user.dart
//
// # Process a single file, write result to a different path
// dart run bin/dart_doc_inserter.dart lib/models/user.dart -o out/user.dart
//
// # Recursively process an entire package (overwrite in place)
// dart run bin/dart_doc_inserter.dart lib/
//
// # Recursively process, mirror output under a different root
// dart run bin/dart_doc_inserter.dart lib/ --output out/lib/
//
// # Preview changes only
// dart run bin/dart_doc_inserter.dart --dry-run lib/
// ```

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main(List<String> rawArgs) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addFlag(
      'dry-run',
      abbr: 'n',
      negatable: false,
      help: 'Show what would change without writing files.',
    )
    ..addOption(
      'output',
      abbr: 'o',
      valueHelp: 'path',
      help:
          'Output file (single-file input) or root directory\n'
          '(directory input). Omit to overwrite in place.',
    );

  late final ArgResults args;
  try {
    args = parser.parse(rawArgs);
  } catch (e) {
    stderr.writeln('Error: $e');
    _usage(parser);
    exit(1);
  }

  if (args['help'] as bool) {
    _usage(parser);
    exit(0);
  }

  // ── Validate positional <path> ───────────────────────────────────────────

  if (args.rest.isEmpty) {
    stderr.writeln('Error: <path> argument is required.');
    _usage(parser);
    exit(1);
  }

  if (args.rest.length > 1) {
    stderr.writeln(
      'Error: expected exactly one <path>, got ${args.rest.length}.',
    );
    _usage(parser);
    exit(1);
  }

  final dryRun = args['dry-run'] as bool;
  final inputRaw = args.rest[0];
  final outputRaw = args['output'] as String?;

  // ── Resolve and validate input path ─────────────────────────────────────

  final inputAbs = p.canonicalize(inputRaw);
  final inputFsType = FileSystemEntity.typeSync(inputAbs);

  if (inputFsType == FileSystemEntityType.notFound) {
    stderr.writeln('Error: path not found: $inputAbs');
    exit(1);
  }

  if (inputFsType == FileSystemEntityType.file) {
    if (!inputAbs.endsWith('.dart')) {
      stderr.writeln('Error: input file is not a .dart file: $inputAbs');
      exit(1);
    }
  } else if (inputFsType != FileSystemEntityType.directory) {
    stderr.writeln('Error: unsupported path type: $inputAbs');
    exit(1);
  }

  final isInputFile = inputFsType == FileSystemEntityType.file;

  // ── Validate --output / input-type consistency ───────────────────────────

  String? outputAbs;
  if (outputRaw != null) {
    outputAbs = p.canonicalize(outputRaw);
    final outFsType = FileSystemEntity.typeSync(outputAbs);

    if (isInputFile && outFsType == FileSystemEntityType.directory) {
      stderr.writeln(
        'Error: input is a file but --output is an existing directory: '
        '$outputAbs',
      );
      exit(1);
    }
    if (!isInputFile && outFsType == FileSystemEntityType.file) {
      stderr.writeln(
        'Error: input is a directory but --output is an existing file: '
        '$outputAbs',
      );
      exit(1);
    }
  }

  // ── Collect .dart files ─────────────────────────────────────────────────

  final dartFiles = isInputFile ? [inputAbs] : _collectDart(inputAbs);

  if (dartFiles.isEmpty) {
    stderr.writeln('No .dart files found under: $inputAbs');
    exit(0);
  }

  // ── Build analysis context ───────────────────────────────────────────────

  final collection = AnalysisContextCollection(includedPaths: dartFiles);

  int processed = 0;
  int changed = 0;
  bool anyError = false;

  for (final path in dartFiles) {
    try {
      final ctx = collection.contextFor(path);
      final result = await ctx.currentSession.getResolvedUnit(path);

      if (result is! ResolvedUnitResult) {
        stderr.writeln('Cannot resolve: $path');
        anyError = true;
        if (dryRun) {
          stdout.writeln(
            _dryRunLine(path: path, ok: false, errorReason: 'parse error'),
          );
        }
        continue;
      }

      final edits = _DocInserter(
        result.content,
        result.lineInfo,
      ).collectEdits(result.unit);

      processed++;

      // In dry-run mode we never touch the filesystem: just report what
      // would happen for this file and move on.
      if (dryRun) {
        stdout.writeln(
          _dryRunLine(
            path: path,
            ok: true,
            actionCounts: {'insert': edits.length},
          ),
        );
        continue;
      }

      if (edits.isEmpty) continue;

      // Apply edits in reverse offset order so earlier offsets stay valid.
      edits.sort((a, b) => b.offset.compareTo(a.offset));

      var src = result.content;
      for (final e in edits) {
        src = src.substring(0, e.offset) + e.text + src.substring(e.offset);
      }

      // Resolve destination path for this file.
      final destPath = _destinationPath(
        sourcePath: path,
        inputRoot: inputAbs,
        isInputFile: isInputFile,
        outputRoot: outputAbs,
      );

      final n = edits.length;
      final suffix = '($n insert${n == 1 ? '' : 's'})';
      final route = destPath == path ? path : '$path → $destPath';

      File(destPath).parent.createSync(recursive: true);
      File(destPath).writeAsStringSync(src);
      stdout.writeln('Modified  $route  $suffix');
      changed++;
    } catch (e, st) {
      stderr.writeln('ERROR processing $path\n  $e');
      stderr.writeln(st);
      anyError = true;
      if (dryRun) {
        stdout.writeln(
          _dryRunLine(path: path, ok: false, errorReason: _errorReason(e)),
        );
      }
    }
  }

  stdout.writeln(
    '\nDone. $processed file(s) processed, $changed file(s) modified.',
  );

  if (anyError) exit(1);
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI helpers
// ─────────────────────────────────────────────────────────────────────────────

void _usage(ArgParser parser) {
  stdout.writeln(
    'dart_doc_inserter – insert declaration-summary doc comments into Dart files\n'
    '\n'
    'Usage: dart run bin/dart_doc_inserter.dart <path> [options]\n'
    '\n'
    'Arguments:\n'
    '  <path>    A .dart file or directory (recursively traversed).\n'
    '\n'
    'Options:\n'
    '${parser.usage}',
  );
}

List<String> _collectDart(String dir) {
  return Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => p.canonicalize(f.path))
      .toList();
}

/// Resolves the destination path for [sourcePath].
///
/// - [outputRoot] is `null` → write back in place (returns [sourcePath]).
/// - [isInputFile] is `true` → [outputRoot] is the target file path directly.
/// - Otherwise, the relative path from [inputRoot] to [sourcePath] is mirrored
///   under [outputRoot], preserving the original directory structure.
String _destinationPath({
  required String sourcePath,
  required String inputRoot,
  required bool isInputFile,
  required String? outputRoot,
}) {
  if (outputRoot == null) return sourcePath;
  if (isInputFile) return outputRoot;
  return p.join(outputRoot, p.relative(sourcePath, from: inputRoot));
}

// ─────────────────────────────────────────────────────────────────────────────
// Dry-run logging
// ─────────────────────────────────────────────────────────────────────────────
//
// Unified, single-line, machine-parseable status format for `--dry-run`:
//
//   [dry-run]  (√) <path> (<num> <action>, ...)
//   [dry-run]  (√) <path> (no changes)
//   [dry-run]  (×) <path> (<error reason>)
//
// Exactly one line per file, written to stdout, in processing order, with no
// extra progress/percentage/timestamp noise and no redundant "Success"/"Done"
// wording. Detailed exceptions and stack traces stay on stderr.

/// Builds a single `--dry-run` status line for one file.
///
/// [ok] selects the `(√)`/`(×)` marker. For a success line, supply
/// [actionCounts] (action name → count); an empty/all-zero map renders as
/// `(no changes)`. For a failure line, supply a short [errorReason] (e.g.
/// `parse error`, `io error`, `permission denied`) instead.
String _dryRunLine({
  required String path,
  required bool ok,
  Map<String, int>? actionCounts,
  String? errorReason,
}) {
  final marker = ok ? '(√)' : '(×)';
  final detail = ok
      ? _formatActionCounts(actionCounts ?? const {})
      : '(${errorReason ?? 'error'})';
  return '[dry-run]  $marker $path $detail';
}

/// Formats action-name → count pairs into the parenthesised suffix used in a
/// dry-run status line, e.g. `(3 inserts, 2 deletes, 1 modify)`. Entries with
/// a zero count are omitted; if nothing remains, the result is `(no
/// changes)`.
String _formatActionCounts(Map<String, int> counts) {
  final parts = <String>[
    for (final entry in counts.entries)
      if (entry.value > 0)
        '${entry.value} ${_pluralizeAction(entry.key, entry.value)}',
  ];
  return parts.isEmpty ? '(no changes)' : '(${parts.join(', ')})';
}

/// Pluralises a dry-run action label for [count]. `insert`, `delete`,
/// `merge`, and `skip` take a plain `s`; `modify` is the one irregular form
/// (`modifies`). Unrecognised action names fall back to a plain `s` suffix
/// so new action types remain readable without code changes here.
String _pluralizeAction(String action, int count) {
  if (count == 1) return action;
  return action == 'modify' ? 'modifies' : '${action}s';
}

/// Maps a caught exception to the short, parenthesised reason shown on a
/// failed dry-run line. The exception and stack trace are still logged in
/// full on stderr by the caller — this is only the terse stdout label.
String _errorReason(Object e) {
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    final msg = e.message.toLowerCase();
    if (code == 13 || code == 5 || msg.contains('permission')) {
      return 'permission denied';
    }
    return 'io error';
  }
  return 'parse error';
}

// ─────────────────────────────────────────────────────────────────────────────
// Edit model
// ─────────────────────────────────────────────────────────────────────────────

class _Edit {
  /// Offset in the *original* source at which [text] should be inserted.
  final int offset;

  /// The text to insert (already indented, already ends with '\n').
  final String text;

  _Edit(this.offset, this.text);
}

// ─────────────────────────────────────────────────────────────────────────────
// _DocInserter – collects all edits for one file
// ─────────────────────────────────────────────────────────────────────────────

class _DocInserter extends RecursiveAstVisitor<void> {
  final String _src;
  final LineInfo _li;
  final List<_Edit> edits = [];

  /// Stack of class contexts (name + declared field types) as we descend into
  /// class-like nodes.
  final List<_ClassCtx> _stack = [];

  _DocInserter(this._src, this._li);

  List<_Edit> collectEdits(CompilationUnit unit) {
    unit.accept(this);
    return edits;
  }

  _ClassCtx? get _cls => _stack.isEmpty ? null : _stack.last;

  /// True when we are at top level, or inside a class/mixin/enum/extension/
  /// extension-type whose own name is public. Members declared inside a
  /// *private* container are not reachable from outside the library no
  /// matter what their own name looks like, so they must not be treated as
  /// public API and must not receive a doc-comment block.
  bool get _inPublicContainer => _cls == null || _public(_cls!.name);

  // ── Visitor overrides ─────────────────────────────────────────────────────

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (_public(node.name.lexeme)) {
      _emit(
        level: '/// #',
        title: node.name.lexeme,
        sig: _classHeader(node),
        doc: node.documentationComment,
        meta: node.metadata,
        first: node.firstTokenAfterCommentAndMetadata,
      );
    }
    _stack.add(_ClassCtx(node.name.lexeme, _fields(node.members)));
    super.visitClassDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    if (_public(node.name.lexeme)) {
      _emit(
        level: '/// #',
        title: node.name.lexeme,
        sig: _mixinHeader(node),
        doc: node.documentationComment,
        meta: node.metadata,
        first: node.firstTokenAfterCommentAndMetadata,
      );
    }
    _stack.add(_ClassCtx(node.name.lexeme, _fields(node.members)));
    super.visitMixinDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final name = node.name?.lexeme;
    // Anonymous extensions have no name → skip entirely.
    if (name != null && _public(name)) {
      _emit(
        level: '/// #',
        title: name,
        sig: _extensionHeader(node),
        doc: node.documentationComment,
        meta: node.metadata,
        first: node.firstTokenAfterCommentAndMetadata,
      );
    }
    if (name != null) {
      _stack.add(_ClassCtx(name, _fields(node.members)));
      super.visitExtensionDeclaration(node);
      _stack.removeLast();
    }
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    if (_public(node.name.lexeme)) {
      _emit(
        level: '/// #',
        title: node.name.lexeme,
        sig: 'enum ${node.name.lexeme} {}',
        doc: node.documentationComment,
        meta: node.metadata,
        first: node.firstTokenAfterCommentAndMetadata,
      );
    }
    _stack.add(_ClassCtx(node.name.lexeme, _fields(node.members)));
    // Visit only non-constant members (methods, etc.).
    for (final m in node.members) {
      if (m is! EnumConstantDeclaration) m.accept(this);
    }
    _stack.removeLast();
    // Do NOT call super – that would revisit enum constants.
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    if (_public(node.name.lexeme)) {
      _emit(
        level: '/// #',
        title: node.name.lexeme,
        sig: _extensionTypeHeader(node),
        doc: node.documentationComment,
        meta: node.metadata,
        first: node.firstTokenAfterCommentAndMetadata,
      );
    }
    _stack.add(_ClassCtx(node.name.lexeme, _fields(node.members)));
    super.visitExtensionTypeDeclaration(node);
    _stack.removeLast();
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    // Mixin application: `class Foo = Bar with Mixin;`
    if (_public(node.name.lexeme)) {
      _emit(
        level: '/// #',
        title: node.name.lexeme,
        sig: _mixinAppHeader(node),
        doc: node.documentationComment,
        meta: node.metadata,
        first: node.firstTokenAfterCommentAndMetadata,
      );
    }
    // No body → no members to descend into.
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // Only top-level functions, not local functions inside method bodies.
    if (_cls != null) return;
    if (!_public(node.name.lexeme)) return;

    // Top-level getters/setters behave like properties (no parentheses).
    final isProperty = node.isGetter || node.isSetter;
    final title = isProperty ? node.name.lexeme : '${node.name.lexeme}()';

    _emit(
      level: '/// #',
      title: title,
      sig: _fnSig(node),
      doc: node.documentationComment,
      meta: node.metadata,
      first: node.firstTokenAfterCommentAndMetadata,
    );
    // Intentionally do NOT recurse into the function body.
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final v in node.variables.variables) {
      if (!_public(v.name.lexeme)) continue;
      _emit(
        level: '/// #',
        title: v.name.lexeme,
        sig: _topVarSig(node, v),
        doc: node.documentationComment,
        meta: node.metadata,
        first: node.firstTokenAfterCommentAndMetadata,
      );
      // Insert only once per variable declaration statement (the doc comment /
      // metadata span the whole statement).  Break after the first public
      // variable so we don't emit the same offset twice.
      break;
    }
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    if (!_public(node.name.lexeme)) return;
    _emit(
      level: '/// #',
      title: node.name.lexeme,
      sig: _typedefSig(node),
      doc: node.documentationComment,
      meta: node.metadata,
      first: node.firstTokenAfterCommentAndMetadata,
    );
  }

  // ── Class members ─────────────────────────────────────────────────────────

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // A private enclosing class/mixin/enum/extension-type has no public API
    // of its own, so none of its constructors should be documented either,
    // regardless of the constructor's own name.
    if (!_inPublicContainer) return;

    final cn = _cls?.name ?? '';
    final named = node.name?.lexeme;
    // Private named constructor → skip.
    if (named != null && named.startsWith('_')) return;

    final title = named != null ? '$cn.$named()' : '$cn()';
    _emit(
      level: '/// ###',
      title: title,
      sig: _ctorSig(node, cn),
      doc: node.documentationComment,
      meta: node.metadata,
      first: node.firstTokenAfterCommentAndMetadata,
    );
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    // Methods of a private enclosing container are not part of the public
    // API even when the method's own name doesn't start with `_`.
    if (!_inPublicContainer) return;
    if (!_public(node.name.lexeme)) return;

    final String title;
    if (node.isOperator) {
      title = 'operator ${node.name.lexeme}()';
    } else if (node.isGetter || node.isSetter) {
      title = node.name.lexeme; // no parentheses
    } else {
      title = '${node.name.lexeme}()';
    }

    _emit(
      level: '/// ###',
      title: title,
      sig: _methodSig(node),
      doc: node.documentationComment,
      meta: node.metadata,
      first: node.firstTokenAfterCommentAndMetadata,
    );
    // Do NOT recurse into the method body.
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    // Fields of a private enclosing container are not part of the public
    // API even when the field's own name doesn't start with `_`.
    if (!_inPublicContainer) return;

    for (final v in node.fields.variables) {
      if (!_public(v.name.lexeme)) continue;
      _emit(
        level: '/// ###',
        title: v.name.lexeme,
        sig: _fieldSig(node, v),
        doc: node.documentationComment,
        meta: node.metadata,
        first: node.firstTokenAfterCommentAndMetadata,
      );
      break; // one doc comment block per field declaration statement
    }
  }

  // ── Core emit ─────────────────────────────────────────────────────────────

  void _emit({
    required String level,
    required String title,
    required String sig,
    required Comment? doc,
    required List<Annotation> meta,
    required Token first,
  }) {
    // Determine insertion point.
    final insertAt = _insertionPoint(doc, meta, first);

    // Detect if this declaration was already processed.
    if (_alreadyProcessed(doc, insertAt, level)) return;

    final indent = _indentAt(insertAt);
    final block = _buildBlock(level, title, sig, indent);

    edits.add(_Edit(insertAt, block));
  }

  // ── Already-processed detection ───────────────────────────────────────────

  /// Returns true if the declaration already has a summary block at the right
  /// position.
  ///
  /// Two cases per the spec:
  ///  1. Has a doc comment whose FIRST line is a summary line and whose SECOND
  ///     line is `/// ```dart`.
  ///  2. Has no doc comment, but the source immediately before [insertAt]
  ///     (skipping blank lines) ends with `/// ```dart` preceded by a summary
  ///     line.  (We handle this via the source text rather than the AST.)
  bool _alreadyProcessed(Comment? doc, int insertAt, String level) {
    if (doc != null) {
      // Walk the tokens of the doc comment.
      final tokens = _docTokens(doc);
      if (tokens.length >= 2) {
        final first = tokens[0].lexeme.trim(); // e.g. '/// # Foo'
        final second = tokens[1].lexeme.trim(); // e.g. '/// ```dart'
        if (_isSummaryLine(first) && second == '/// ```dart') return true;
      }
      return false;
    }

    // No doc comment: check the raw source above insertAt.
    // Look backwards for a `/// ```dart` line preceded by a `/// #` line.
    if (insertAt == 0) return false;
    final before = _src.substring(0, insertAt).trimRight();
    final lines = before.split('\n');
    // Find the last non-empty line.
    int li = lines.length - 1;
    while (li >= 0 && lines[li].trim().isEmpty) {
      li--;
    }
    if (li < 1) return false;
    final lastLine = lines[li].trim();
    final prevLine = lines[li - 1].trim();
    if (lastLine == '/// ```dart' && _isSummaryLine(prevLine)) return true;
    return false;
  }

  bool _isSummaryLine(String trimmed) =>
      trimmed.startsWith('/// # ') ||
      trimmed.startsWith('/// ## ') ||
      trimmed.startsWith('/// ### ');

  List<Token> _docTokens(Comment comment) {
    final result = <Token>[];
    Token? t = comment.beginToken;
    while (t != null && t.offset <= comment.end) {
      if (t.type == TokenType.SINGLE_LINE_COMMENT) result.add(t);
      if (t == comment.endToken) break;
      t = t.next;
    }
    return result;
  }

  // ── Insertion point ───────────────────────────────────────────────────────

  /// Where in the source to insert the summary block.
  ///
  /// - If [doc] exists → insert at the very start of the doc comment.
  /// - Else if [meta] is non-empty → insert before the first annotation's `@`.
  /// - Else → insert before the first declaration token.
  int _insertionPoint(Comment? doc, List<Annotation> meta, Token first) {
    if (doc != null) return doc.offset;
    if (meta.isNotEmpty) return meta.first.offset;
    return first.offset;
  }

  // ── Indentation ───────────────────────────────────────────────────────────

  String _indentAt(int offset) {
    final loc = _li.getLocation(offset);
    final lineStart = _li.getOffsetOfLine(loc.lineNumber - 1);
    var i = lineStart;
    while (i < _src.length && (_src[i] == ' ' || _src[i] == '\t')) {
      i++;
    }
    return _src.substring(lineStart, i);
  }

  // ── Block builder ─────────────────────────────────────────────────────────

  /// Builds the 4-line doc-comment block.
  ///
  /// ```
  /// {indent}/// {level} {title}
  /// {indent}/// ```dart
  /// {indent}/// {sig}
  /// {indent}/// ```
  /// ```
  ///
  /// A trailing newline is included so the block ends on its own line.
  String _buildBlock(String level, String title, String sig, String indent) {
    return '$indent$level $title\n'
        '$indent/// ```dart\n'
        '$indent/// $sig\n'
        '$indent/// ```\n';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Signature builders
  // ─────────────────────────────────────────────────────────────────────────

  // ── Class-like headers ───────────────────────────────────────────────────

  String _classHeader(ClassDeclaration n) {
    final sb = StringBuffer();
    // Class modifiers (Dart 3.x) – keep all.
    _tok(sb, n.abstractKeyword);
    _tok(sb, n.baseKeyword);
    _tok(sb, n.interfaceKeyword);
    _tok(sb, n.finalKeyword);
    _tok(sb, n.sealedKeyword);
    _tok(sb, n.mixinKeyword);
    if (sb.isNotEmpty) sb.write(' ');
    sb.write('class ');
    sb.write(n.name.lexeme);
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    if (n.extendsClause != null) {
      sb.write(' extends ${n.extendsClause!.superclass.toSource()}');
    }
    if (n.withClause != null) {
      sb.write(
        ' with ${n.withClause!.mixinTypes.map((t) => t.toSource()).join(', ')}',
      );
    }
    if (n.implementsClause != null) {
      sb.write(
        ' implements ${n.implementsClause!.interfaces.map((t) => t.toSource()).join(', ')}',
      );
    }
    sb.write(' {}');
    return sb.toString();
  }

  String _mixinHeader(MixinDeclaration n) {
    final sb = StringBuffer();
    _tok(sb, n.baseKeyword);
    if (sb.isNotEmpty) sb.write(' ');
    sb.write('mixin ');
    sb.write(n.name.lexeme);
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    if (n.onClause != null) {
      sb.write(
        ' on ${n.onClause!.superclassConstraints.map((t) => t.toSource()).join(', ')}',
      );
    }
    if (n.implementsClause != null) {
      sb.write(
        ' implements ${n.implementsClause!.interfaces.map((t) => t.toSource()).join(', ')}',
      );
    }
    sb.write(' {}');
    return sb.toString();
  }

  String _extensionHeader(ExtensionDeclaration n) {
    final sb = StringBuffer();
    sb.write('extension ');
    if (n.name != null) sb.write(n.name!.lexeme);
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    sb.write(' on ${n.extendedType.toSource()} {}');
    return sb.toString();
  }

  String _extensionTypeHeader(ExtensionTypeDeclaration n) {
    final sb = StringBuffer();
    sb.write('extension type ');
    sb.write(n.name.lexeme);
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    sb.write(n.representation.toSource());
    sb.write(' {}');
    return sb.toString();
  }

  String _mixinAppHeader(ClassTypeAlias n) {
    // `class Foo = Bar with MixinA, MixinB;`
    final sb = StringBuffer();
    _tok(sb, n.abstractKeyword);
    _tok(sb, n.baseKeyword);
    _tok(sb, n.interfaceKeyword);
    _tok(sb, n.finalKeyword);
    _tok(sb, n.sealedKeyword);
    _tok(sb, n.mixinKeyword);
    if (sb.isNotEmpty) sb.write(' ');
    sb.write('class ');
    sb.write(n.name.lexeme);
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    sb.write(' = ');
    sb.write(n.superclass.toSource());
    if (n.withClause.mixinTypes.isNotEmpty) {
      sb.write(
        ' with ${n.withClause.mixinTypes.map((t) => t.toSource()).join(', ')}',
      );
    }
    if (n.implementsClause != null) {
      sb.write(
        ' implements ${n.implementsClause!.interfaces.map((t) => t.toSource()).join(', ')}',
      );
    }
    sb.write(';');
    return sb.toString();
  }

  // ── Top-level ────────────────────────────────────────────────────────────

  String _fnSig(FunctionDeclaration n) {
    final sb = StringBuffer();
    if (n.returnType != null) {
      sb.write('${n.returnType!.toSource()} ');
    }
    if (n.isGetter) sb.write('get ');
    if (n.isSetter) sb.write('set ');
    sb.write(n.name.lexeme);
    final expr = n.functionExpression;
    if (expr.typeParameters != null) sb.write(expr.typeParameters!.toSource());
    if (expr.parameters != null) {
      sb.write(_params(expr.parameters!, null));
    }
    return sb.toString();
  }

  String _topVarSig(TopLevelVariableDeclaration d, VariableDeclaration v) {
    final type = d.variables.type?.toSource() ?? 'dynamic';
    return '$type ${v.name.lexeme}';
  }

  String _typedefSig(GenericTypeAlias n) {
    final tp = n.typeParameters != null ? n.typeParameters!.toSource() : '';
    return 'typedef ${n.name.lexeme}$tp = ${n.type.toSource()}';
  }

  // ── Members ───────────────────────────────────────────────────────────────

  String _ctorSig(ConstructorDeclaration n, String className) {
    final sb = StringBuffer();
    sb.write(className);
    if (n.name != null) {
      sb.write('.${n.name!.lexeme}');
    }
    sb.write(_params(n.parameters, _cls));
    return sb.toString();
  }

  String _methodSig(MethodDeclaration n) {
    final sb = StringBuffer();
    // Return type (not present on constructors, but this is a method).
    if (n.returnType != null) {
      sb.write('${n.returnType!.toSource()} ');
    }
    if (n.isGetter) {
      sb.write('get ');
    } else if (n.isSetter) {
      sb.write('set ');
    } else if (n.isOperator) {
      sb.write('operator ');
    }
    sb.write(n.name.lexeme);
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    if (n.parameters != null) {
      sb.write(_params(n.parameters!, _cls));
    }
    return sb.toString();
  }

  String _fieldSig(FieldDeclaration d, VariableDeclaration v) {
    final type = d.fields.type?.toSource() ?? 'dynamic';
    return '$type ${v.name.lexeme}';
  }

  // ── Parameter list ────────────────────────────────────────────────────────

  /// Serialises a [FormalParameterList] into signature form, expanding
  /// `this.field` and `super.field` shorthand.
  String _params(FormalParameterList list, _ClassCtx? ctx) {
    final buf = StringBuffer('(');
    bool openedBracket = false;
    bool openedBrace = false;
    bool first = true;

    void sep() {
      if (!first) buf.write(', ');
      first = false;
    }

    for (final param in list.parameters) {
      // Open optional-positional bracket.
      if (!openedBracket && param.isOptionalPositional) {
        sep();
        buf.write('[');
        openedBracket = true;
        first = true; // reset sep inside bracket
      }
      // Open named brace.
      if (!openedBrace && param.isNamed) {
        sep();
        buf.write('{');
        openedBrace = true;
        first = true;
      }

      sep();
      buf.write(_param(param, ctx));
    }

    if (openedBracket) buf.write(']');
    if (openedBrace) buf.write('}');
    buf.write(')');
    return buf.toString();
  }

  String _param(FormalParameter p, _ClassCtx? ctx) {
    if (p is DefaultFormalParameter) {
      final inner = _param(p.parameter, ctx);
      if (p.defaultValue != null) {
        return '$inner = ${p.defaultValue!.toSource()}';
      }
      return inner;
    }

    final required = p.isRequiredNamed ? 'required ' : '';

    if (p is FieldFormalParameter) {
      // `this.field` → look up type in class fields.
      final name = p.name.lexeme;
      final type = ctx?.fieldTypes[name] ?? 'dynamic';
      final innerParams = p.parameters != null
          ? _params(p.parameters!, ctx)
          : '';
      // type params on function-typed `this.field` (rare).
      final tpStr = p.typeParameters != null
          ? p.typeParameters!.toSource()
          : '';
      if (p.parameters != null) {
        // Function-typed: `ReturnType this.fn<T>(params)` → `ReturnType fn<T>(params)`
        final ret = p.type?.toSource() ?? 'Function';
        return '$required$ret $name$tpStr$innerParams';
      }
      return '$required$type $name';
    }

    if (p is SuperFormalParameter) {
      // `super.field` → try to resolve via the element model.
      final name = p.name.lexeme;
      final type = _superParamType(p);
      final innerParams = p.parameters != null
          ? _params(p.parameters!, ctx)
          : '';
      final tpStr = p.typeParameters != null
          ? p.typeParameters!.toSource()
          : '';
      if (p.parameters != null) {
        final ret = p.type?.toSource() ?? 'Function';
        return '$required$ret $name$tpStr$innerParams';
      }
      return '$required$type $name';
    }

    if (p is SimpleFormalParameter) {
      final type = p.type?.toSource() ?? 'dynamic';
      final name = p.name?.lexeme ?? '';
      return '$required$type $name';
    }

    if (p is FunctionTypedFormalParameter) {
      final ret = p.returnType?.toSource() ?? 'dynamic';
      final name = p.name.lexeme;
      final tpStr = p.typeParameters != null
          ? p.typeParameters!.toSource()
          : '';
      return '$required$ret $name$tpStr${_params(p.parameters, ctx)}';
    }

    // Fallback: strip modifiers from the raw source.
    return '$required${_stripMods(p.toSource())}';
  }

  String _superParamType(SuperFormalParameter p) {
    // The resolved element type is the most accurate source.
    final elem = p.declaredElement;
    if (elem != null) {
      final type = elem.type;
      if (type is! DynamicType && type is! InvalidType) {
        return type.getDisplayString(withNullability: true);
      }
    }
    // Fallback: explicit type annotation on the parameter.
    if (p.type != null) return p.type!.toSource();
    return 'dynamic';
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  /// Appends a keyword token to [sb] with surrounding spacing, if non-null.
  void _tok(StringBuffer sb, Token? token) {
    if (token == null) return;
    if (sb.isNotEmpty) sb.write(' ');
    sb.write(token.lexeme);
  }

  bool _public(String name) => !name.startsWith('_');

  /// Strips declaration-keyword modifiers that should not appear in the
  /// signature body of *non-class* declarations.
  static final RegExp _modPattern = RegExp(
    r'\b(final|const|static|abstract|async\*|sync\*|async|external|covariant|late|factory)\b',
  );

  String _stripMods(String s) =>
      s.replaceAll(_modPattern, '').replaceAll(RegExp(r'  +'), ' ').trim();

  /// Extracts the field types declared in [members] (for `this.` expansion).
  Map<String, String> _fields(List<ClassMember> members) {
    final map = <String, String>{};
    for (final m in members) {
      if (m is FieldDeclaration) {
        final typeStr = m.fields.type?.toSource() ?? 'dynamic';
        for (final v in m.fields.variables) {
          map[v.name.lexeme] = typeStr;
        }
      }
    }
    return map;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Class context for this./super. expansion
// ─────────────────────────────────────────────────────────────────────────────

class _ClassCtx {
  final String name;
  final Map<String, String> fieldTypes;

  _ClassCtx(this.name, this.fieldTypes);
}
