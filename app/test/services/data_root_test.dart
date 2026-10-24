import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/services/data_root.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 假装自己是"原来那个"平台实现，用来验证转发有没有漏。
/// 每个方法返回一个独特的哨兵值，转发错了立刻能看出来转到了哪去。
class _FakeInner extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => 'TEMP';

  @override
  Future<String?> getApplicationSupportPath() async => 'INNER_SUPPORT';

  @override
  Future<String?> getLibraryPath() async => 'LIB';

  @override
  Future<String?> getApplicationDocumentsPath() async => 'DOCS';

  @override
  Future<String?> getApplicationCachePath() async => 'CACHE';

  @override
  Future<String?> getExternalStoragePath() async => 'EXT';

  @override
  Future<List<String>?> getExternalCachePaths() async => ['EXT_CACHE'];

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async =>
      ['EXT_STORAGE'];

  @override
  Future<String?> getDownloadsPath() async => 'DOWNLOADS';
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('n1-data-root-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('tryPreparePortableRoot', () {
    test('目录不存在就建出来，并返回它', () async {
      final root = await tryPreparePortableRoot(tmp);

      expect(root, isNotNull);
      expect(root!.path, p.join(tmp.path, portableDataDirName));
      expect(await root.exists(), isTrue);
    });

    test('已经存在就直接复用，不报错', () async {
      final first = await tryPreparePortableRoot(tmp);
      final second = await tryPreparePortableRoot(tmp);

      expect(second!.path, first!.path);
    });

    test('探针文件不留在磁盘上', () async {
      final root = await tryPreparePortableRoot(tmp);

      // 探针是"这里能不能写"的实测手段，不是要留下的东西。
      // 用户打开 data/ 只该看见自己的东西。
      final leftovers = await root!.list().toList();
      expect(leftovers, isEmpty);
    });

    test('建不出来时返回 null 而不是抛异常', () async {
      // 在 data 该在的位置放一个**文件**，create() 必然失败。
      // 这条测的是"装不上便携目录要能平静退回系统默认"，而不是把
      // 整个 App 带崩——装在 C:\Program Files 下就是这种情况。
      await File(p.join(tmp.path, portableDataDirName)).writeAsString('占位');

      final root = await tryPreparePortableRoot(tmp);

      expect(root, isNull);
    });
  });

  group('PortablePathProvider', () {
    late PortablePathProvider provider;

    setUp(() {
      provider = PortablePathProvider(inner: _FakeInner(), root: r'D:\app\data');
    });

    test('app support 被换成便携目录', () async {
      expect(await provider.getApplicationSupportPath(), r'D:\app\data');
    });

    test('其余八个方法原样转发给原来的实现', () async {
      // 这些是"下载/文档/临时文件"一类，本来就该由系统决定。
      // 转发漏一个的症状是某个功能拿到 null 或者走到默认实现去。
      expect(await provider.getTemporaryPath(), 'TEMP');
      expect(await provider.getLibraryPath(), 'LIB');
      expect(await provider.getApplicationDocumentsPath(), 'DOCS');
      expect(await provider.getApplicationCachePath(), 'CACHE');
      expect(await provider.getExternalStoragePath(), 'EXT');
      expect(await provider.getExternalCachePaths(), ['EXT_CACHE']);
      expect(await provider.getExternalStoragePaths(), ['EXT_STORAGE']);
      expect(await provider.getDownloadsPath(), 'DOWNLOADS');
    });
  });
}
