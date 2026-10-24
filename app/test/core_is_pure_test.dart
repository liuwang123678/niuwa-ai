import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守住 `lib/core/` 的纯度。
///
/// 这条线一旦破了就收不回来：内核里混进 Flutter，就没法脱离界面测、也抽不成命令行。
/// 所以用测试卡死，而不是靠自觉。
void main() {
  test('lib/core 不许依赖 Flutter', () {
    final coreDir = Directory('lib/core');
    expect(
      coreDir.existsSync(),
      isTrue,
      reason: '找不到 lib/core —— 测试要在 app/ 目录下跑',
    );

    final flutterImport = RegExp(
      r'''import\s+['"]package:flutter/''',
    );

    final offenders = <String>[];
    for (final entity in coreDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (flutterImport.hasMatch(source)) {
        offenders.add(entity.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '内核必须保持纯 Dart。以下文件 import 了 Flutter：\n${offenders.join('\n')}',
    );
  });
}
