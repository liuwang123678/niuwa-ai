import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:niuwa_ai/core/llm/providers.dart';
import 'package:niuwa_ai/providers/settings_provider.dart';
import 'package:niuwa_ai/services/model_catalog.dart';
import 'package:niuwa_ai/services/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 盯「拉模型列表」这一路的**状态机**：拉到没有、出错有没有话说、
/// 中途换了一家会不会把上一家的名单落到新那家头上。
Future<SettingsProvider> build({http.Client? client}) async {
  SharedPreferences.setMockInitialValues({});
  final store = SettingsStore(await SharedPreferences.getInstance());
  final secure = SecureStore(backend: InMemorySecureKeyBackend());
  return SettingsProvider(
    store: store,
    secure: secure,
    builtInPersona: '（测试用的人设）',
    catalog: ModelCatalog(clientFactory: () => client ?? _stub()),
  );
}

http.Client _stub([String body = '{"data":[{"id":"m"}]}']) =>
    MockClient((_) async => http.Response(body, 200));

/// 同 [build]，但**不清掉**已经写进去的值。
///
/// 用来验"这个值真的落到 prefs 里了"：`SettingsStore` 的 getter 每次都是现读
/// `_prefs`，所以换一个 store 实例还读得到，就说明它不是被某个对象攥在字段里。
Future<SettingsProvider> buildReusing() async {
  final store = SettingsStore(await SharedPreferences.getInstance());
  return SettingsProvider(
    store: store,
    secure: SecureStore(backend: InMemorySecureKeyBackend()),
    builtInPersona: '（测试用的人设）',
    catalog: ModelCatalog(clientFactory: _stub),
  );
}

void main() {
  group('拉成功', () {
    test('列表落地、状态收干净', () async {
      final s = await build(
        client: MockClient(
          (_) async => http.Response('{"data":[{"id":"kimi-k3"},{"id":"kimi-k2.6"}]}', 200),
        ),
      );

      await s.fetchModels();

      expect(s.fetchedModels, ['kimi-k3', 'kimi-k2.6']);
      expect(s.hasFetchedModels, isTrue);
      expect(s.fetchingModels, isFalse);
      expect(s.modelListError, isNull);
    });

    test('带上的是**这一家**的 Key', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      await store.setProviderId('moonshot');
      final secure = SecureStore(backend: InMemorySecureKeyBackend());
      await secure.writeApiKey('sk-moon', providerId: 'moonshot');
      await secure.writeApiKey('sk-deep', providerId: 'deepseek');

      String? seen;
      final s = SettingsProvider(
        store: store,
        secure: secure,
        builtInPersona: 'x',
        catalog: ModelCatalog(
          clientFactory: () => MockClient((request) async {
            // 换供应商没重读 Key 的话，这里拿到的是上一家的——界面上一切
            // 正常，一发请求就 401。
            seen = request.headers['Authorization'];
            return http.Response('{"data":[{"id":"kimi-k3"}]}', 200);
          }),
        ),
      );

      await s.fetchModels();

      expect(seen, 'Bearer sk-moon');
    });

    test('没配 Key 也能拉——本机 Ollama 就没有 Key', () async {
      final s = await build();
      await s.fetchModels();
      expect(s.modelListError, isNull);
      expect(s.hasFetchedModels, isTrue);
    });
  });

  group('拉失败', () {
    test('错误落在状态里，不进列表', () async {
      final s = await build(
        client: MockClient(
          (_) async => http.Response('{"error":{"message":"Invalid API key"}}', 401),
        ),
      );

      await s.fetchModels();

      expect(s.modelListError, contains('Invalid API key'));
      expect(s.fetchedModels, isEmpty);
      expect(s.hasFetchedModels, isFalse);
      expect(s.fetchingModels, isFalse, reason: '失败了也得把开关放回去，不然按钮永远灰着');
    });

    test('拉过一次失败，再拉成功：上一句错误话要消掉', () async {
      // 不清的话，用户拉成功了列表摆在眼前，底下还挂着"Key 不对"那行红字。
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      final secure = SecureStore(backend: InMemorySecureKeyBackend());

      var fail = true;
      final s = SettingsProvider(
        store: store,
        secure: secure,
        builtInPersona: 'x',
        catalog: ModelCatalog(
          clientFactory: () => MockClient(
            (_) async => fail
                ? http.Response('{"error":"nope"}', 401)
                : http.Response('{"data":[{"id":"a"}]}', 200),
          ),
        ),
      );

      await s.fetchModels();
      expect(s.modelListError, isNotNull);

      fail = false;
      await s.fetchModels();

      expect(s.modelListError, isNull);
      expect(s.fetchedModels, ['a']);
    });
  });

  group('中途换供应商', () {
    test('换一家会把上一家的名单清掉', () async {
      final s = await build(
        client: MockClient((_) async => http.Response('{"data":[{"id":"deepseek-flash"}]}', 200)),
      );
      await s.fetchModels();
      expect(s.fetchedModels, isNotEmpty);

      await s.selectProvider('moonshot');

      // 不清的话，用户在 Kimi 底下看见一堆"deepseek-xxx"，点一下就把
      // 模型名设成了一个那家不存在的值。
      expect(s.fetchedModels, isEmpty);
      expect(s.hasFetchedModels, isFalse);
      expect(s.modelListError, isNull);
      expect(s.fetchingModels, isFalse);
    });

    test('拉一半换了一家：结果不落到新那家头上', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      final secure = SecureStore(backend: InMemorySecureKeyBackend());

      // 卡住不回的请求，模拟"拉列表拉到一半用户去点下拉框了"。
      final gate = Completer<http.Response>();
      final s = SettingsProvider(
        store: store,
        secure: secure,
        builtInPersona: 'x',
        catalog: ModelCatalog(clientFactory: () => MockClient((_) => gate.future)),
      );

      expect(s.providerId, 'deepseek');
      final inflight = s.fetchModels();

      await s.selectProvider('moonshot');
      gate.complete(http.Response('{"data":[{"id":"deepseek-flash"}]}', 200));
      await inflight;

      expect(s.providerId, 'moonshot');
      expect(s.fetchedModels, isEmpty);
      expect(s.hasFetchedModels, isFalse);
      expect(s.modelListError, isNull);
    });
  });

  group('列表只是建议，不是白名单', () {
    test('清单外的名字照样能存下来', () async {
      // 这条钉的是产品承诺：拉回来的名单是给用户挑的，不是"只能用这些"。
      // 平台筛不筛、排不排序各家不一样，当成真理比让人手填更糟。
      final s = await build(
        client: MockClient((_) async => http.Response('{"data":[{"id":"a"}]}', 200)),
      );
      await s.fetchModels();

      await s.setModel('某个清单里没有的名字');

      expect(s.model, '某个清单里没有的名字');
    });
  });

  group('预置表', () {
    test('每条预置都有非空默认模型名（自定义那条除外）', () {
      for (final p in kLlmProviders) {
        if (p.isCustom) continue;
        expect(p.defaultModel, isNotEmpty, reason: '${p.name} 没写默认模型名');
      }
    });

    test('Kimi 那条不再是退役的 kimi-k2.5', () {
      // 用户报的就是这只虫：k2.5 于 2026-08-31 退役，用下去回 404
      // 「模型不存在」，症状看着像"这家用不了"。
      expect(
        providerById('moonshot')!.defaultModel,
        isNot('kimi-k2.5'),
      );
    });

    test('modelsUrl 对三种填法都给同一个地方', () {
      for (final base in const [
        'https://api.deepseek.com',
        'https://api.deepseek.com/',
        'https://api.deepseek.com/chat/completions',
      ]) {
        expect(modelsUrl(base), 'https://api.deepseek.com/models');
      }
      expect(modelsUrl(''), '');
    });
  });

  group('总开关的转发', () {
    test('读得到，改了也存得住', () async {
      final s = await build();
      expect(s.allowCodeTools, isTrue);

      await s.setAllowCodeTools(false);

      expect(s.allowCodeTools, isFalse);
      // 换一个 provider 读同一份存储：值是从 prefs 来的，不是这个对象攥着。
      final reopened = await buildReusing();
      expect(reopened.allowCodeTools, isFalse);
    });

    test('改一下，**provider 自己**要通知——设置页那个开关靠这个当场翻面', () async {
      // `SettingsStore` 那一层已经测过它自己 notify 了。这里多测一层是因为
      // 界面 watch 的是 provider：转发链断在中间的话，症状是"点了开关，
      // 手一松它又弹回去了"，而且没有任何报错。
      final s = await build();
      var notified = 0;
      s.addListener(() => notified++);

      await s.setAllowCodeTools(false);

      expect(notified, greaterThan(0));
    });
  });

  group('自动模式', () {
    test('默认关——这是唯一一个会关掉安全兜底的开关', () async {
      final s = await build();
      expect(s.autoApprove, isFalse);
    });

    test('打开之后换个 provider 还读得到', () async {
      final s = await build();
      await s.setAutoApprove(true);

      expect(s.autoApprove, isTrue);
      final reopened = await buildReusing();
      expect(reopened.autoApprove, isTrue);
    });

    test('改一下要通知——输入条上那颗胶囊靠这个当场变红', () async {
      final s = await build();
      var notified = 0;
      s.addListener(() => notified++);

      await s.setAutoApprove(true);

      expect(notified, greaterThan(0));
    });
  });
}
