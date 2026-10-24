import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/services/prefs_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// 便携设置的落盘。
///
/// 这个类存在的唯一理由是：**`shared_preferences` 的 Windows 实现绕开了
/// `PathProviderPlatform.instance`**，设置会脱离便携目录单独落到 C 盘。
/// 所以这里最要紧的不是"能存能取"，而是"存到哪去了"——第一条测试盯的就是这个。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1_prefs_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File fileIn(Directory dir) => File(p.join(dir.path, FileSharedPreferencesStore.fileName));

  group('落到哪', () {
    test('写进的是交给它的那个目录，不是别处', () async {
      final store = await FileSharedPreferencesStore.open(tmp);

      await store.setValue('String', 'flutter.settings.provider_id', 'deepseek');

      final file = fileIn(tmp);
      expect(file.existsSync(), isTrue, reason: '设置文件必须落在指定目录里');

      // 内容就是一份普通的 JSON，键**带前缀原样存**——跟原来
      // shared_preferences_windows 写的格式一致，方便肉眼对账。
      final decoded = json.decode(file.readAsStringSync()) as Map;
      expect(decoded['flutter.settings.provider_id'], 'deepseek');
    });

    test('换个目录开就是另一份设置，两边互不影响', () async {
      final other = Directory.systemTemp.createTempSync('n1_prefs_test_other');
      addTearDown(() => other.deleteSync(recursive: true));

      final a = await FileSharedPreferencesStore.open(tmp);
      final b = await FileSharedPreferencesStore.open(other);

      await a.setValue('String', 'flutter.settings.provider_id', 'deepseek');
      await b.setValue('String', 'flutter.settings.provider_id', 'dashscope');

      final reopenedA = await FileSharedPreferencesStore.open(tmp);
      final reopenedB = await FileSharedPreferencesStore.open(other);
      expect(reopenedA.snapshot['flutter.settings.provider_id'], 'deepseek');
      expect(reopenedB.snapshot['flutter.settings.provider_id'], 'dashscope');
    });
  });

  group('存和取', () {
    test('写进去的值重启之后还在，类型也不变形', () async {
      final store = await FileSharedPreferencesStore.open(tmp);
      await store.setValue('String', 'flutter.settings.provider_id', 'deepseek');
      await store.setValue('Double', 'flutter.settings.temperature', 0.7);
      await store.setValue('Bool', 'flutter.settings.stream_reasoning', true);
      await store.setValue('StringList', 'flutter.settings.tags', <String>['a', 'b']);

      final reopened = await FileSharedPreferencesStore.open(tmp);
      final all = await reopened.getAll();
      expect(all['flutter.settings.provider_id'], 'deepseek');
      // JSON 里 0.7 回来必须是 double 不是 int，否则上层强转会炸
      expect(all['flutter.settings.temperature'], isA<double>());
      expect(all['flutter.settings.temperature'], 0.7);
      expect(all['flutter.settings.stream_reasoning'], isTrue);
      expect(all['flutter.settings.tags'], <String>['a', 'b']);
    });

    test('remove 掉之后就没了，而且落了盘', () async {
      final store = await FileSharedPreferencesStore.open(tmp);
      await store.setValue('String', 'flutter.settings.provider_id', 'deepseek');

      await store.remove('flutter.settings.provider_id');

      expect((await store.getAll()), isEmpty);
      final reopened = await FileSharedPreferencesStore.open(tmp);
      expect(await reopened.getAll(), isEmpty);
    });
  });

  group('前缀口径（跟 InMemorySharedPreferencesStore 对齐）', () {
    test('getAll 只给 flutter. 开头的键', () async {
      final store = await FileSharedPreferencesStore.open(tmp);
      await store.setValue('String', 'flutter.settings.provider_id', 'deepseek');
      await store.setValue('String', '别人的键', '不该被看到');

      final all = await store.getAll();

      expect(all.keys, ['flutter.settings.provider_id']);
    });

    test('clear 只清 flutter. 开头的，别的不动', () async {
      final store = await FileSharedPreferencesStore.open(tmp);
      await store.setValue('String', 'flutter.settings.provider_id', 'deepseek');
      await store.setValue('String', '别人的键', '留着');

      await store.clear();

      expect((await store.getAll()), isEmpty);
      expect(store.snapshot['别人的键'], '留着');
    });

    test('带 allowList 的时候只清名单里的', () async {
      final store = await FileSharedPreferencesStore.open(tmp);
      await store.setValue('String', 'flutter.a', '1');
      await store.setValue('String', 'flutter.b', '2');

      await store.clearWithParameters(
        ClearParameters(
          filter: PreferencesFilter(prefix: 'flutter.', allowList: {'flutter.a'}),
        ),
      );

      final all = await store.getAll();
      expect(all.keys, ['flutter.b']);
    });
  });

  group('容错', () {
    test('文件是坏的当空设置起步，不抛', () async {
      fileIn(tmp).writeAsStringSync('这不是 JSON{{{');

      final store = await FileSharedPreferencesStore.open(tmp);

      expect(await store.getAll(), isEmpty);
      // 而且还能正常写回去，把坏的盖掉
      await store.setValue('String', 'flutter.a', '1');
      expect((await FileSharedPreferencesStore.open(tmp)).snapshot['flutter.a'], '1');
    });

    test('目录还不存在时会自己建出来', () async {
      final deep = Directory(p.join(tmp.path, 'a', 'b'));
      expect(deep.existsSync(), isFalse);

      final store = await FileSharedPreferencesStore.open(deep);
      await store.setValue('String', 'flutter.a', '1');

      expect(fileIn(deep).existsSync(), isTrue);
    });
  });

  group('接上 SharedPreferences 本体', () {
    // ⚠️ 这一组**只能有一个**测试调 SharedPreferences.getInstance()：
    // 它内部把实例缓存在一个静态里，换掉 store 之后再调拿到的还是老的。
    // 真实启动顺序（main.dart）恰好满足这个前提：installPortableDataRoot()
    // 在 N1Runtime.boot() 之前跑，也就是在任何一次 getInstance 之前。
    test('换掉 store 之后，getInstance 读到的就是我们这个文件', () async {
      final dir = Directory.systemTemp.createTempSync('n1_prefs_live');
      addTearDown(() => dir.deleteSync(recursive: true));

      // 先照真实用法摆一份设置进去
      final seeded = await FileSharedPreferencesStore.open(dir);
      await seeded.setValue('String', 'flutter.settings.provider_id', 'deepseek');

      SharedPreferencesStorePlatform.instance = await FileSharedPreferencesStore.open(dir);

      final prefs = await SharedPreferences.getInstance();

      // 键前缀由 SharedPreferences 自己剥掉，所以这里是裸键名
      expect(prefs.getString('settings.provider_id'), 'deepseek');

      // 反向也走一遍：从 SharedPreferences 写，落到我们那个文件里
      await prefs.setDouble('settings.temperature', 1.3);
      final decoded = json.decode(fileIn(dir).readAsStringSync()) as Map;
      expect(decoded['flutter.settings.temperature'], 1.3);
    });
  });
}
