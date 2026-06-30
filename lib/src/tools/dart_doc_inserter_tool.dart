import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:doc_pipe/src/cli/dart_file_tool.dart';

class DartDocInserterTool extends DartFileTool {
  @override
  String get name => 'dart_doc_inserter';

  @override
  String get description => '为 Dart 声明插入格式化的文档摘要注释块。';

  @override
  List<UsageExample> get examples => const [
    UsageExample(
      '处理单文件（就地覆写）',
      'dart run bin/dart_doc_inserter.dart lib/models/user.dart',
    ),
    UsageExample('处理整个包（就地覆写）', 'dart run bin/dart_doc_inserter.dart lib/'),
    UsageExample(
      '输出到另一目录',
      'dart run bin/dart_doc_inserter.dart lib/ --output out/lib/',
    ),
    UsageExample(
      '预览变更（不写磁盘）',
      'dart run bin/dart_doc_inserter.dart --dry-run lib/',
    ),
  ];

  @override
  AnalysisNeed get analysisNeed => AnalysisNeed.resolved;

  @override
  Future<FileChange> transform(SourceFile input) async {
    final result = input.resolvedUnit as ResolvedUnitResult;

    final edits = _DocInserter(
      result.content,
      result.lineInfo,
    ).collectEdits(result.unit);

    if (edits.isEmpty) return FileChange.unchanged();

    edits.sort((a, b) => b.offset.compareTo(a.offset));
    var src = result.content;
    for (final e in edits) {
      src = src.substring(0, e.offset) + e.text + src.substring(e.offset);
    }

    return FileChange(
      newContent: src,
      stats: ChangeStats(inserts: edits.length),
      outcome: FileOutcome.changed,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 以下为原 dart_doc_inserter.dart 的核心逻辑，原样搬运
// ══════════════════════════════════════════════════════════════════════════════

class _Edit {
  final int offset;
  final String text;
  _Edit(this.offset, this.text);
}

class _DocInserter extends RecursiveAstVisitor<void> {
  final String _src;
  final LineInfo _li;
  final List<_Edit> edits = [];
  final List<_ClassCtx> _stack = [];

  _DocInserter(this._src, this._li);

  List<_Edit> collectEdits(CompilationUnit unit) {
    unit.accept(this);
    return edits;
  }

  _ClassCtx? get _cls => _stack.isEmpty ? null : _stack.last;

  bool get _inPublicContainer => _cls == null || _public(_cls!.name);

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
    for (final m in node.members) {
      if (m is! EnumConstantDeclaration) m.accept(this);
    }
    _stack.removeLast();
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
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (_cls != null) return;
    if (!_public(node.name.lexeme)) return;
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

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (!_inPublicContainer) return;
    final cn = _cls?.name ?? '';
    final named = node.name?.lexeme;
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
    if (!_inPublicContainer) return;
    if (!_public(node.name.lexeme)) return;
    final String title;
    if (node.isOperator) {
      title = 'operator ${node.name.lexeme}()';
    } else if (node.isGetter || node.isSetter) {
      title = node.name.lexeme;
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
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
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
      break;
    }
  }

  void _emit({
    required String level,
    required String title,
    required String sig,
    required Comment? doc,
    required List<Annotation> meta,
    required Token first,
  }) {
    final insertAt = _insertionPoint(doc, meta, first);
    if (_alreadyProcessed(doc, insertAt, level)) return;
    final indent = _indentAt(insertAt);
    final block = _buildBlock(level, title, sig, indent);
    edits.add(_Edit(insertAt, block));
  }

  bool _alreadyProcessed(Comment? doc, int insertAt, String level) {
    if (doc != null) {
      final tokens = _docTokens(doc);
      if (tokens.length >= 2) {
        final first = tokens[0].lexeme.trim();
        final second = tokens[1].lexeme.trim();
        if (_isSummaryLine(first) && second == '/// ```dart') return true;
      }
      return false;
    }
    if (insertAt == 0) return false;
    final before = _src.substring(0, insertAt).trimRight();
    final lines = before.split('\n');
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

  int _insertionPoint(Comment? doc, List<Annotation> meta, Token first) {
    if (doc != null) return doc.offset;
    if (meta.isNotEmpty) return meta.first.offset;
    return first.offset;
  }

  String _indentAt(int offset) {
    final loc = _li.getLocation(offset);
    final lineStart = _li.getOffsetOfLine(loc.lineNumber - 1);
    var i = lineStart;
    while (i < _src.length && (_src[i] == ' ' || _src[i] == '\t')) {
      i++;
    }
    return _src.substring(lineStart, i);
  }

  String _buildBlock(String level, String title, String sig, String indent) =>
      '$indent$level $title\n'
      '$indent/// ```dart\n'
      '$indent/// $sig\n'
      '$indent/// ```\n';

  // ── Signature builders ────────────────────────────────────────────────────

  String _classHeader(ClassDeclaration n) {
    final sb = StringBuffer();
    _tok(sb, n.abstractKeyword);
    _tok(sb, n.baseKeyword);
    _tok(sb, n.interfaceKeyword);
    _tok(sb, n.finalKeyword);
    _tok(sb, n.sealedKeyword);
    _tok(sb, n.mixinKeyword);
    if (sb.isNotEmpty) sb.write(' ');
    sb.write('class ${n.name.lexeme}');
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
    sb.write('mixin ${n.name.lexeme}');
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
    sb.write('extension type ${n.name.lexeme}');
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    sb.write(n.representation.toSource());
    sb.write(' {}');
    return sb.toString();
  }

  String _mixinAppHeader(ClassTypeAlias n) {
    final sb = StringBuffer();
    _tok(sb, n.abstractKeyword);
    _tok(sb, n.baseKeyword);
    _tok(sb, n.interfaceKeyword);
    _tok(sb, n.finalKeyword);
    _tok(sb, n.sealedKeyword);
    _tok(sb, n.mixinKeyword);
    if (sb.isNotEmpty) sb.write(' ');
    sb.write('class ${n.name.lexeme}');
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    sb.write(' = ${n.superclass.toSource()}');
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

  String _fnSig(FunctionDeclaration n) {
    final sb = StringBuffer();
    if (n.returnType != null) sb.write('${n.returnType!.toSource()} ');
    if (n.isGetter) sb.write('get ');
    if (n.isSetter) sb.write('set ');
    sb.write(n.name.lexeme);
    final expr = n.functionExpression;
    if (expr.typeParameters != null) sb.write(expr.typeParameters!.toSource());
    if (expr.parameters != null) sb.write(_params(expr.parameters!, null));
    return sb.toString();
  }

  String _topVarSig(TopLevelVariableDeclaration d, VariableDeclaration v) {
    final type = d.variables.type?.toSource() ?? 'dynamic';
    return '$type ${v.name.lexeme}';
  }

  String _typedefSig(GenericTypeAlias n) {
    final tp = n.typeParameters?.toSource() ?? '';
    return 'typedef ${n.name.lexeme}$tp = ${n.type.toSource()}';
  }

  String _ctorSig(ConstructorDeclaration n, String className) {
    final sb = StringBuffer();
    sb.write(className);
    if (n.name != null) sb.write('.${n.name!.lexeme}');
    sb.write(_params(n.parameters, _cls));
    return sb.toString();
  }

  String _methodSig(MethodDeclaration n) {
    final sb = StringBuffer();
    if (n.returnType != null) sb.write('${n.returnType!.toSource()} ');
    if (n.isGetter) {
      sb.write('get ');
    } else if (n.isSetter) {
      sb.write('set ');
    } else if (n.isOperator) {
      sb.write('operator ');
    }
    sb.write(n.name.lexeme);
    if (n.typeParameters != null) sb.write(n.typeParameters!.toSource());
    if (n.parameters != null) sb.write(_params(n.parameters!, _cls));
    return sb.toString();
  }

  String _fieldSig(FieldDeclaration d, VariableDeclaration v) {
    final type = d.fields.type?.toSource() ?? 'dynamic';
    return '$type ${v.name.lexeme}';
  }

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
      if (!openedBracket && param.isOptionalPositional) {
        sep();
        buf.write('[');
        openedBracket = true;
        first = true;
      }
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
      final name = p.name.lexeme;
      final type = ctx?.fieldTypes[name] ?? 'dynamic';
      final innerParams = p.parameters != null
          ? _params(p.parameters!, ctx)
          : '';
      final tpStr = p.typeParameters?.toSource() ?? '';
      if (p.parameters != null) {
        final ret = p.type?.toSource() ?? 'Function';
        return '$required$ret $name$tpStr$innerParams';
      }
      return '$required$type $name';
    }

    if (p is SuperFormalParameter) {
      final name = p.name.lexeme;
      final type = _superParamType(p);
      final innerParams = p.parameters != null
          ? _params(p.parameters!, ctx)
          : '';
      final tpStr = p.typeParameters?.toSource() ?? '';
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
      final tpStr = p.typeParameters?.toSource() ?? '';
      return '$required$ret $name$tpStr${_params(p.parameters, ctx)}';
    }

    return '$required${_stripMods(p.toSource())}';
  }

  String _superParamType(SuperFormalParameter p) {
    final elem = p.declaredElement;
    if (elem != null) {
      final type = elem.type;
      if (type is! DynamicType && type is! InvalidType) {
        return type.getDisplayString(withNullability: true);
      }
    }
    if (p.type != null) return p.type!.toSource();
    return 'dynamic';
  }

  void _tok(StringBuffer sb, Token? token) {
    if (token == null) return;
    if (sb.isNotEmpty) sb.write(' ');
    sb.write(token.lexeme);
  }

  bool _public(String name) => !name.startsWith('_');

  static final RegExp _modPattern = RegExp(
    r'\b(final|const|static|abstract|async\*|sync\*|async|external|covariant|late|factory)\b',
  );

  String _stripMods(String s) =>
      s.replaceAll(_modPattern, '').replaceAll(RegExp(r'  +'), ' ').trim();

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

class _ClassCtx {
  final String name;
  final Map<String, String> fieldTypes;
  _ClassCtx(this.name, this.fieldTypes);
}
