import 'dart:io';

import 'package:logger/logger.dart';

// 仅输出消息本体，不追加时间戳、级别标签或 ANSI 装饰。
class _PlainPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) => [event.message.toString()];
}

// Level.warning 及以上 → stderr，其余 → stdout。
class _SplitOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    final sink = event.level.index >= Level.warning.index ? stderr : stdout;
    for (final line in event.lines) {
      sink.writeln(line);
    }
  }
}

Logger _logger = Logger(
  printer: _PlainPrinter(),
  output: _SplitOutput(),
  level: Level.info,
  filter: ProductionFilter(),
);

/// 统一日志路由。整个项目中 console.dart 之外禁止直接调用 stdout/stderr。
class Console {
  Console._();

  /// 在参数解析完成后、首次输出前调用一次。
  static void init({Level level = Level.info}) {
    _logger = Logger(
      printer: _PlainPrinter(),
      output: _SplitOutput(),
      level: level,
      filter: ProductionFilter(),
    );
  }

  /// 调试信息（仅 Level.debug 时可见）。→ stdout
  static void debug(Object msg) => _logger.d(msg);

  /// 正常用户可见输出：dry-run 行、汇总行、文件路径等。→ stdout
  static void info(Object msg) => _logger.i(msg);

  /// 非致命警告：跳过文件、可忽略异常等。→ stderr
  static void warn(Object msg) => _logger.w(msg);

  /// 错误（路径不存在、写盘失败等）。→ stderr
  static void error(Object msg) => _logger.e(msg);
}
