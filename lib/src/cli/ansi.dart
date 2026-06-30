import 'dart:io';

/// TTY 感知 ANSI 着色工具。stdout 非 TTY 时自动降级为空字符串。
class Ansi {
  Ansi._();

  static bool get _tty => stdout.hasTerminal;

  static String _e(String code) => _tty ? '\x1B[${code}m' : '';

  static String get reset => _e('0');
  static String get bold => _e('1');
  static String get red => _e('31');
  static String get green => _e('32');
  static String get yellow => _e('33');
  static String get cyan => _e('36');
}
