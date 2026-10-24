import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/services/error_log.dart';

/// 这个文件存在的理由只有一个：Windows 上双击启动没有控制台，异常全丢进
/// 虚空。它要是坏了（比如悄悄写不进去），出事时我们还是什么都看不到——
/// 而且**不会有任何症状提醒我们它坏了**。所以行为得钉住。
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('n1-error-log-');
    file = File('${dir.path}${Platform.pathSeparator}errors.log');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('异常、堆栈、种类都落进文件', () async {
    final log = ErrorLog(file);

    await log.record('框架异常', StateError('窗口黑了'), StackTrace.current);

    final text = await log.read();
    expect(text, contains('[框架异常]'));
    expect(text, contains('窗口黑了'));
    expect(text, contains('error_log_test.dart'));
  });

  test('是追加不是覆盖：两次启动的记录都还在', () async {
    final log = ErrorLog(file);

    await log.recordLaunch('niuwa v9', 'windows');
    await log.record('未捕获的异步异常', Exception('第一次'));
    await log.record('未捕获的异步异常', Exception('第二次'));

    final text = await log.read();
    expect(text, contains('第一次'));
    expect(text, contains('第二次'));
    // 启动标记只有一行——说明 recordLaunch 自己的写入没被吃掉
    expect('启动'.allMatches(text).length, 1);
  });

  test('超过上限截掉旧的一半，新内容必须还在', () async {
    final log = ErrorLog(file, maxBytes: 400);

    for (var i = 0; i < 20; i++) {
      await log.record('框架异常', Exception('第 $i 条错误'));
    }

    final text = await log.read();
    expect(await file.length(), lessThan(400 + 200),
        reason: '只该在写入时截一次，不能无限长下去');
    expect(text, contains('第 19 条错误'), reason: '留旧不留新就等于没日志');
    expect(text, contains('已截掉'));
  });

  test('文件不存在时 read 给空串，不抛', () async {
    expect(await ErrorLog(file).read(), '');
  });

  test('目录不存在也能自己建出来', () async {
    final nested = File('${dir.path}${Platform.pathSeparator}a'
        '${Platform.pathSeparator}b${Platform.pathSeparator}errors.log');

    await ErrorLog(nested).record('框架异常', Exception('深层目录'));

    expect(await nested.exists(), isTrue);
  });
}
