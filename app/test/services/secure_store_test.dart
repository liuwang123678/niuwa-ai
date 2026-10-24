import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/agent/work_level.dart';
import 'package:niuwa_ai/core/llm/providers.dart';
import 'package:niuwa_ai/services/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureStore', () {
    late InMemorySecureKeyBackend backend;
    late SecureStore store;

    setUp(() {
      // 关键：测试里绝不能走真后端。`flutter test` 底下没有 Keystore / DPAPI，
      // 真调平台通道会以 MissingPluginException 挂掉。
      backend = InMemorySecureKeyBackend();
      store = SecureStore(backend: backend);
    });

    test('没配过的时候读出来是 null，hasApiKey 是 false', () async {
      expect(await store.readApiKey(), isNull);
      expect(await store.hasApiKey(), isFalse);
    });

    test('写入后能读出来，hasApiKey 变 true', () async {
      await store.writeApiKey('sk-test-123');
      expect(await store.readApiKey(), 'sk-test-123');
      expect(await store.hasApiKey(), isTrue);
    });

    test('clear 之后读不到了（真的从后端删掉，不是置空）', () async {
      await store.writeApiKey('sk-test-123');
      await store.clearApiKey();

      expect(await store.readApiKey(), isNull);
      expect(await store.hasApiKey(), isFalse);
      expect(backend.snapshot, isEmpty);
    });

    test('首尾空白会被剪掉（网页复制粘贴的常见坑）', () async {
      await store.writeApiKey('  sk-padded\n');
      expect(await store.readApiKey(), 'sk-padded');
    });

    test('只写了空白等于没写', () async {
      await store.writeApiKey('   ');
      expect(await store.hasApiKey(), isFalse);
    });

    test('覆盖写：同一个 Key 位置只留最后一份', () async {
      await store.writeApiKey('sk-old');
      await store.writeApiKey('sk-new');

      expect(await store.readApiKey(), 'sk-new');
      expect(backend.snapshot.length, 1);
    });

    test('后端里存的是 Key 本身的键名，换个 SecureStore 实例还读得到', () async {
      await store.writeApiKey('sk-persist');
      final reopened = SecureStore(backend: backend);
      expect(await reopened.readApiKey(), 'sk-persist');
    });
  });

  group('SecureStore · 每家一个 Key', () {
    late InMemorySecureKeyBackend backend;
    late SecureStore store;

    setUp(() {
      backend = InMemorySecureKeyBackend();
      store = SecureStore(backend: backend);
    });

    test('两家各存一个，互不覆盖', () async {
      await store.writeApiKey('甲家的', providerId: 'deepseek');
      await store.writeApiKey('乙家的', providerId: 'moonshot');

      expect(await store.readApiKey(providerId: 'deepseek'), '甲家的');
      expect(await store.readApiKey(providerId: 'moonshot'), '乙家的');
      expect(backend.snapshot.length, 2);
    });

    test('换一家再换回来，原来那家的 Key 还在（不用重填）', () async {
      await store.writeApiKey('甲家的', providerId: 'deepseek');
      await store.writeApiKey('乙家的', providerId: 'moonshot');

      expect(await store.readApiKey(providerId: 'deepseek'), '甲家的');
    });

    test('老键名里的 Key 在默认那家还读得到（升级上来不会"丢了"）', () async {
      // 老版本只有一家，Key 存在 n1.api_key 这个固定名字下。
      // 不认它的话，已经填过 Key 的人升级上来会看到"还没设置"，
      // 然后去重新申请一个——而他手里那个其实还能用。
      backend = InMemorySecureKeyBackend({
        SecureStore.legacyApiKeyName: '老-key',
      });
      store = SecureStore(backend: backend);

      expect(await store.readApiKey(providerId: kDefaultProviderId), '老-key');
      expect(await store.hasApiKey(providerId: kDefaultProviderId), isTrue);
    });

    test('老键名**不会**套到别家头上', () async {
      // 套过去的话，设置页显示"已设置"，发出去的却是一个不属于那家的 Key，
      // 换回一个 401，而用户完全看不出为什么。
      backend = InMemorySecureKeyBackend({
        SecureStore.legacyApiKeyName: '老-key',
      });
      store = SecureStore(backend: backend);

      expect(await store.readApiKey(providerId: 'moonshot'), isNull);
      expect(await store.hasApiKey(providerId: 'moonshot'), isFalse);
    });

    test('新键名有值时，不再去看老键名', () async {
      backend = InMemorySecureKeyBackend({
        SecureStore.legacyApiKeyName: '老-key',
      });
      store = SecureStore(backend: backend);

      await store.writeApiKey('新的', providerId: kDefaultProviderId);

      expect(await store.readApiKey(providerId: kDefaultProviderId), '新的');
    });

    test('清除默认那家会把老键名一起删掉', () async {
      // 不删的话读的时候会回退到它——用户点完"清除"再看一眼，Key 又回来了。
      backend = InMemorySecureKeyBackend({
        SecureStore.legacyApiKeyName: '老-key',
      });
      store = SecureStore(backend: backend);

      await store.clearApiKey(providerId: kDefaultProviderId);

      expect(await store.readApiKey(providerId: kDefaultProviderId), isNull);
      expect(backend.snapshot, isEmpty);
    });

    test('清除一家不碰另一家', () async {
      await store.writeApiKey('甲家的', providerId: 'deepseek');
      await store.writeApiKey('乙家的', providerId: 'moonshot');

      await store.clearApiKey(providerId: 'moonshot');

      expect(await store.readApiKey(providerId: 'deepseek'), '甲家的');
      expect(await store.readApiKey(providerId: 'moonshot'), isNull);
    });

    test('不传 providerId 就是默认那家', () async {
      await store.writeApiKey('x');
      expect(await store.readApiKey(providerId: kDefaultProviderId), 'x');
    });
  });

  group('SettingsStore', () {
    late SettingsStore settings;

    setUp(() async {
      // 内存版的 shared_preferences，不碰平台通道。
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsStore.open();
    });

    test('默认值：显示思考过程、温度 0.7、用人设文件', () {
      expect(settings.streamReasoning, isTrue);
      expect(settings.temperature, 0.7);
      expect(settings.personaOverride, '');
    });

    test('setter 会通知监听者（界面靠这个当场刷新）', () async {
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setStreamReasoning(false);
      await settings.setTemperature(1.2);
      await settings.setPersonaOverride('猫娘');

      expect(notified, 3);
    });

    test('写过的值读得回来（并且真的落到 prefs 里了）', () async {
      await settings.setStreamReasoning(false);
      await settings.setTemperature(1.2);
      await settings.setPersonaOverride('猫娘');

      expect(settings.streamReasoning, isFalse);
      expect(settings.temperature, 1.2);
      expect(settings.personaOverride, '猫娘');

      // 换一个 SettingsStore 实例再读一遍：值是从 prefs（存储）来的，
      // 不是被这个对象自己攥在字段里。
      final reopened = await SettingsStore.open();
      expect(reopened.streamReasoning, isFalse);
      expect(reopened.temperature, 1.2);
      expect(reopened.personaOverride, '猫娘');
    });

    test('温度被夹在 0..2（超了上游会直接拒）', () async {
      await settings.setTemperature(9);
      expect(settings.temperature, 2);

      await settings.setTemperature(-1);
      expect(settings.temperature, 0);
    });

    test('人设覆盖串会被 trim（空白串等于"没覆盖"）', () async {
      await settings.setPersonaOverride('  猫娘  ');
      expect(settings.personaOverride, '猫娘');

      await settings.setPersonaOverride('   ');
      expect(settings.personaOverride, '');
    });

    test('工作强度默认是标准——升级完不该发现哪里变了', () async {
      expect(settings.workLevel, WorkLevel.standard);
    });

    test('工作强度存得住，存的是 id 不是显示名', () async {
      await settings.setWorkLevel(WorkLevel.frugal);

      final reopened = await SettingsStore.open();
      expect(reopened.workLevel, WorkLevel.frugal);
      // 存显示名的话，以后改一次中文文案就把老用户的档位弄丢了。
      expect(
        reopened.workLevel.id,
        'frugal',
      );
    });

    // ── 总开关 ──

    test('默认**开着**——这一条是产品取舍，不是随手定的默认值', () async {
      // 默认关掉看着"更安全"，实际是自相矛盾的：普通操作本来就不问用户，
      // 于是它会说"我不能跑代码"，而设置里那个开关用户根本不知道在哪儿。
      // 而且用户要的就是这个能力（「牛蛙ai需要有写代码和跑代码的能力」）。
      expect(settings.allowCodeTools, isTrue);
    });

    test('关掉存得住，重开还是关着', () async {
      await settings.setAllowCodeTools(false);

      final reopened = await SettingsStore.open();
      expect(reopened.allowCodeTools, isFalse);
    });

    test('改开关会通知监听者——设置页那个开关靠这个当场动', () async {
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setAllowCodeTools(false);

      expect(notified, 1);
    });

    test('开关和工作强度是两个键，互不踩', () async {
      // 两个 `_k...` 常量抄成同一个值的话，症状是"关掉跑代码，它顺手也变抠了"
      // ——而且没有任何地方会报错。这两个设置有同一套 getter/setter 形状，
      // 复制粘贴的时候最容易出这种事。
      await settings.setAllowCodeTools(false);

      final reopened = await SettingsStore.open();
      expect(reopened.workLevel, WorkLevel.standard);
      expect(reopened.streamReasoning, isTrue);

      await reopened.setWorkLevel(WorkLevel.thorough);
      final again = await SettingsStore.open();
      expect(again.allowCodeTools, isFalse);
      expect(again.workLevel, WorkLevel.thorough);
    });

    test('存着一个不认识的档位名：退回标准，而不是拿着它去炸', () async {
      // 老用户带着一个以后可能被合并掉的档位名升级上来。
      SharedPreferences.setMockInitialValues({
        'settings.work_level': '这一档没有了',
      });
      final s = await SettingsStore.open();

      expect(s.workLevel, WorkLevel.standard);
    });

    test('只改一个设置不会碰其他设置', () async {
      await settings.setTemperature(1.5);
      await settings.setStreamReasoning(false);
      await settings.setPersonaOverride('猫娘');

      expect(settings.streamReasoning, isFalse);
      expect(settings.temperature, 1.5);
      expect(settings.personaOverride, '猫娘');
    });

    // ── 接哪家 ──

    test('默认就是清单里那家', () {
      expect(settings.providerId, kDefaultProviderId);
      expect(settings.provider.id, kDefaultProviderId);
    });

    test('换了供应商存得住', () async {
      await settings.setProviderId('moonshot');

      final reopened = await SettingsStore.open();
      expect(reopened.providerId, 'moonshot');
    });

    test('存着一个不认识的 id 时退回默认，而不是拿着它去炸', () async {
      // 用户升级上来时可能带着一个已经被删掉的供应商 id。
      SharedPreferences.setMockInitialValues({
        'settings.provider_id': '这家已经没有了',
      });
      final s = await SettingsStore.open();

      expect(s.providerId, kDefaultProviderId);
      expect(s.provider.id, kDefaultProviderId);
    });

    test('模型名按供应商分开记（各家名字不通用）', () async {
      await settings.setModelFor('deepseek', '模型甲');
      await settings.setModelFor('moonshot', '模型乙');

      expect(settings.modelFor('deepseek'), '模型甲');
      expect(settings.modelFor('moonshot'), '模型乙');
    });

    test('没自己改过就用预置的默认模型名', () {
      expect(settings.modelFor('moonshot'), providerById('moonshot')!.defaultModel);
    });

    test('把模型名清空等于用回预置默认值，而不是发一个空名字出去', () async {
      await settings.setModelFor('moonshot', '我自己填的');
      await settings.setModelFor('moonshot', '');

      expect(
        settings.modelFor('moonshot'),
        providerById('moonshot')!.defaultModel,
      );
    });

    test('接口地址：预置那家取预置的，「自定义」取填进去的', () async {
      await settings.setProviderId('moonshot');
      expect(settings.effectiveBaseUrl, providerById('moonshot')!.baseUrl);

      await settings.setProviderId(kCustomProviderId);
      await settings.setCustomBaseUrl(' https://自己填的/v1 ');
      expect(settings.effectiveBaseUrl, 'https://自己填的/v1');
    });

    test('生效的模型名跟着当前供应商走', () async {
      await settings.setModelFor('deepseek', '甲');
      await settings.setModelFor('moonshot', '乙');

      await settings.setProviderId('deepseek');
      expect(settings.effectiveModel, '甲');

      await settings.setProviderId('moonshot');
      expect(settings.effectiveModel, '乙');
    });

    test('换供应商会通知监听者（界面靠这个当场刷新）', () async {
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setProviderId('moonshot');

      expect(notified, 1);
    });

  });
}
