/// 把框架层和异步里没接住的异常写进文件。
///
/// ## 为什么必须有
///
/// Windows 上双击启动的 Flutter 程序**没有控制台**：`debugPrint`、未捕获异常、
/// 引擎报错全丢进虚空。用户看到的现象只有一句"窗口黑了"，而我们这边一个字
/// 都收不到——2026-10-17 就撞过一次，当时只能靠猜。
///
/// 这个文件不修任何东西，它只负责回答一个问题：
/// **出事的时候，是 Dart 这一层抛异常了，还是引擎/显卡压根没在画？**
/// 前者这里会有记录，后者这里干净——两种结论指向完全不同的修法。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 一个只追加、超了就从旧的一半截掉的错误日志。
///
/// 不做"每次启动清空"：黑屏往往发生在用户已经用了一阵之后，清空等于把
/// 现场抹掉。也不无限长：这文件是给排查用的，不是留档。
class ErrorLog {
  ErrorLog(this.file, {this.maxBytes = 64 * 1024});

  final File file;

  /// 超过这个字节数就把旧内容截掉一半。
  final int maxBytes;

  /// 写一条。**永远不抛**——记录错误的过程本身把 App 弄崩是最蠢的。
  Future<void> record(String kind, Object error, [StackTrace? stack]) async {
    final now = DateTime.now();
    final buffer = StringBuffer()
      ..writeln('===== ${_stamp(now)} [$kind]')
      ..writeln(error);
    if (stack != null) buffer.writeln(stack);
    await _append(buffer.toString());
  }

  /// 启动时留一行标记，出事时好判断"是不是这一次启动"。
  Future<void> recordLaunch(String appName, String platform) async {
    await _append('\n===== ${_stamp(DateTime.now())} [启动] $appName · $platform\n');
  }

  /// 整份日志的内容。排查时直接看它。
  Future<String> read() async {
    try {
      if (await file.exists()) return await file.readAsString();
    } catch (_) {}
    return '';
  }

  Future<void> _append(String text) async {
    try {
      await file.parent.create(recursive: true);
      await _trimIfNeeded(text.length);
      await file.writeAsString(text, mode: FileMode.append, flush: true);
    } catch (_) {
      // 磁盘满、目录只读——都不能让记录错误这件事变成第二个错误。
    }
  }

  Future<void> _trimIfNeeded(int incoming) async {
    if (!await file.exists()) return;
    final size = await file.length();
    if (size + incoming <= maxBytes) return;

    // 留后一半：越新的越有用，越旧的越可能是上一轮已经看过的。
    final content = await file.readAsString();
    final keepFrom = (content.length / 2).floor();
    await file.writeAsString(
      '（日志超过 ${maxBytes ~/ 1024} KB，前面的内容已截掉）\n'
      '${content.substring(keepFrom)}',
      flush: true,
    );
  }

  String _stamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  String _two(int n) => n.toString().padLeft(2, '0');
}

/// 装上全局兜底。返回的 [ErrorLog] 可以给别处继续记东西。
///
/// 必须在 `runApp` 之前装：晚于第一帧，启动阶段炸掉的那种就抓不到了。
ErrorLog installErrorLogging(Directory dir, {required String appName}) {
  final log = ErrorLog(File(p.join(dir.path, 'errors.log')));

  FlutterError.onError = (details) {
    unawaited(log.record('框架异常', details.exception, details.stack));
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(log.record('未捕获的异步异常', error, stack));
    // 已经落盘了，就别再走默认处理（release 下它也只是丢掉）。
    return true;
  };

  unawaited(log.recordLaunch(appName, Platform.operatingSystem));
  return log;
}
