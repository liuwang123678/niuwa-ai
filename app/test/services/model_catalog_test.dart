import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:niuwa_ai/services/model_catalog.dart';

/// 记下每一次请求，方便断言"打到哪个地址去了、带没带 Key"。
class _Probe {
  final List<http.BaseRequest> requests = [];

  Uri get lastUri => requests.last.url;

  String? get lastAuth => requests.last.headers['Authorization'];
}

/// 按剧本回一个 JSON 200。
http.Client _ok(String body, _Probe probe) => MockClient((request) async {
  probe.requests.add(request);
  return http.Response(body, 200, headers: {'content-type': 'application/json'});
});

http.Client _fail(int status, String body, _Probe probe) =>
    MockClient((request) async {
      probe.requests.add(request);
      return http.Response(body, status);
    });

ModelCatalog _catalog(http.Client client) =>
    ModelCatalog(clientFactory: () => client);

void main() {
  group('地址怎么拼', () {
    test('末尾没斜杠：补成 {base}/models', () async {
      final probe = _Probe();
      await _catalog(_ok('{"data":[{"id":"a"}]}', probe)).fetch(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'k',
      );
      expect(probe.lastUri.toString(), 'https://api.deepseek.com/models');
    });

    test('末尾带斜杠、带了整个接口地址：都归到同一个地方', () async {
      // 同一个输入框里会出现这三种填法（`chatCompletionsUrl` 认的那三种），
      // 拉列表这条也得认，不然"能聊天但拉不了列表"会显得像平台不支持。
      for (final base in const [
        'https://api.deepseek.com/',
        'https://api.deepseek.com/chat/completions',
        'https://api.deepseek.com/v1',
      ]) {
        final probe = _Probe();
        await _catalog(_ok('{"data":[{"id":"a"}]}', probe)).fetch(
          baseUrl: base,
          apiKey: 'k',
        );
        expect(probe.lastUri.toString(), startsWith('https://api.deepseek.com'));
        expect(probe.lastUri.path, endsWith('/models'));
        expect(probe.lastUri.path, isNot(contains('chat/completions')));
      }
    });

    test('本机 Ollama 那种短主机名也认', () async {
      final probe = _Probe();
      await _catalog(_ok('{"data":[{"id":"qwen3:8b"}]}', probe)).fetch(
        baseUrl: 'http://localhost:11434/v1',
        apiKey: '',
      );
      expect(probe.lastUri.toString(), 'http://localhost:11434/v1/models');
    });
  });

  group('鉴权头', () {
    test('有 Key 就带上，首尾空白先 trim', () async {
      // 从网页上复制 Key 十有八九带换行，进了头就是非法请求，
      // 而报错完全看不出原因。
      final probe = _Probe();
      await _catalog(_ok('{"data":[{"id":"a"}]}', probe)).fetch(
        baseUrl: 'https://a.example.com/v1',
        apiKey: '  sk-abc\n',
      );
      expect(probe.lastAuth, 'Bearer sk-abc');
    });

    test('没 Key 就不发这个头——空 Authorization 会被某些网关当鉴权失败', () async {
      final probe = _Probe();
      await _catalog(_ok('{"data":[{"id":"a"}]}', probe)).fetch(
        baseUrl: 'http://localhost:11434/v1',
        apiKey: '',
      );
      // 注意：不是断言 "Bearer "，是断言**压根没这个头**。
      expect(probe.requests.last.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('回包怎么读', () {
    test('OpenAI 那套 data[].id', () async {
      final ids = await _catalog(
        _ok('{"object":"list","data":[{"id":"kimi-k3"},{"id":"kimi-k2.6"}]}', _Probe()),
      ).fetch(baseUrl: 'https://x.example.com/v1', apiKey: 'k');
      expect(ids, ['kimi-k3', 'kimi-k2.6']);
    });

    test('有些网关回 models[].name', () async {
      final ids = await _catalog(
        _ok('{"models":[{"name":"qwen3:8b"},{"name":"llama3:8b"}]}', _Probe()),
      ).fetch(baseUrl: 'http://localhost:11434/v1', apiKey: '');
      expect(ids, ['qwen3:8b', 'llama3:8b']);
    });

    test('简化到只剩字符串的顶层数组也认', () async {
      final ids = await _catalog(
        _ok('["a","b"]', _Probe()),
      ).fetch(baseUrl: 'https://x.example.com/v1', apiKey: 'k');
      expect(ids, ['a', 'b']);
    });

    test('**保持平台给的顺序**，不按字母重排', () async {
      // 各家把新的、主推的放前面，按字母重排等于把这份策展打乱，
      // 用户得在几百个名字里自己找。
      final ids =
          await _catalog(
            _ok('{"data":[{"id":"zzz-new"},{"id":"aaa-old"}]}', _Probe()),
          ).fetch(baseUrl: 'https://x.example.com/v1', apiKey: 'k');
      expect(ids, ['zzz-new', 'aaa-old']);
    });

    test('去重、跳过空名和形状不对的项，而不是把 null 塞进列表', () async {
      final ids =
          await _catalog(
            _ok(
              jsonEncode({
                'data': [
                  {'id': 'a'},
                  {'id': 'a'},
                  {'id': '  '},
                  {'id': 42},
                  {'name': 'b'},
                  'c',
                  {'nope': 'x'},
                ],
              }),
              _Probe(),
            ),
          ).fetch(baseUrl: 'https://x.example.com/v1', apiKey: 'k');
      expect(ids, ['a', 'b', 'c']);
    });

    test('字段旁边挤着一堆别的也不影响——只抠名字', () async {
      final ids =
          await _catalog(
            _ok(
              jsonEncode({
                'object': 'list',
                'data': [
                  {
                    'id': 'glm-5.3',
                    'object': 'model',
                    'created': 1750000000,
                    'owned_by': 'zhipu',
                  },
                ],
              }),
              _Probe(),
            ),
          ).fetch(baseUrl: 'https://x.example.com/v1', apiKey: 'k');
      expect(ids, ['glm-5.3']);
    });
  });

  group('失败要说人话', () {
    Future<ModelCatalogException> grab(
      http.Client client, {
      String baseUrl = 'https://x.example.com/v1',
      String apiKey = 'k',
    }) async {
      try {
        await _catalog(client).fetch(baseUrl: baseUrl, apiKey: apiKey);
      } on ModelCatalogException catch (e) {
        return e;
      }
      fail('本该失败的');
    }

    test('401 指到"去填 Key"这个动作上', () async {
      final e = await grab(
        _fail(401, '{"error":{"message":"Invalid API key"}}', _Probe()),
      );
      expect(e.statusCode, 401);
      expect(e.message, contains('Key'));
      // 上游那句英文也要带上，用户拿去搜才有东西可搜。
      expect(e.message, contains('Invalid API key'));
    });

    test('404 说实话：这家没有这条接口，手填', () async {
      final e = await grab(_fail(404, '{"error":"not found"}', _Probe()));
      expect(e.message, contains('手填'));
      expect(e.message, contains('404'));
    });

    test('回的不是 JSON：点破是地址填成了网站首页', () async {
      // 这个一定要说破。含糊过去的话用户会以为"这家平台不支持拉列表"，
      // 然后去别处找问题——而真正的原因是他把首页地址粘进来了。
      final e = await grab(_ok('<!DOCTYPE html><html>...</html>', _Probe()));
      expect(e.message, contains('网站首页'));
    });

    test('200 但是空清单：不装成功，说清是平台没给', () async {
      final e = await grab(_ok('{"data":[]}', _Probe()));
      expect(e.message, contains('一个模型名都没有'));
      expect(e.message, contains('手填'));
    });

    test('地址没填：先说自己少填了一栏，不去连', () async {
      final probe = _Probe();
      final e = await grab(_ok('{}', probe), baseUrl: '');
      expect(e.message, contains('还没填接口地址'));
      expect(probe.requests, isEmpty);
    });

    test('地址不像网址：直说，不发请求', () async {
      final probe = _Probe();
      final e = await grab(_ok('{}', probe), baseUrl: '随便写的');
      expect(e.message, contains('不像个网址'));
      expect(probe.requests, isEmpty);
    });

    test('连不上：包一句中文，别把英文异常直接甩给用户', () async {
      final e = await grab(MockClient((_) async => throw 'connection refused'));
      expect(e.message, contains('连不上'));
      expect(e.statusCode, isNull);
    });

    test('超时：说出来等了多久', () async {
      // 超时和"连不上"要分开说：一种是地址根本不通，一种是这平台慢/被墙，
      // 用户该做的事不一样。
      final slow = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response('{"data":[]}', 200);
      });
      final catalog = ModelCatalog(
        clientFactory: () => slow,
        timeout: const Duration(milliseconds: 50),
      );
      try {
        await catalog.fetch(baseUrl: 'https://x.example.com/v1', apiKey: 'k');
        fail('本该超时');
      } on ModelCatalogException catch (e) {
        expect(e.message, contains('没反应'));
      }
    });
  });
}
