import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/llm/providers.dart';

void main() {
  group('chatCompletionsUrl', () {
    test('普通 base 后面补一段', () {
      expect(
        chatCompletionsUrl('https://api.example.com'),
        'https://api.example.com/chat/completions',
      );
    });

    test('带 /v1 的 base 也补在后面，不去动那一段', () {
      // 那一段各家长得不一样（有的要有的不要），猜错了会拿到一个
      // 看起来特别像"网断了"的 404。所以只加尾巴，不改中间。
      expect(
        chatCompletionsUrl('https://api.example.com/v1'),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('末尾多带斜杠也拼得对', () {
      expect(
        chatCompletionsUrl('https://api.example.com/v1/'),
        'https://api.example.com/v1/chat/completions',
      );
      expect(
        chatCompletionsUrl('https://api.example.com//'),
        'https://api.example.com/chat/completions',
      );
    });

    test('整条接口地址粘进来就原样用，不再往后拼', () {
      // 不处理的话会拼成 .../chat/completions/chat/completions，
      // 报出来的错跟"地址填错了"完全看不出关系。
      const full = 'https://api.example.com/v1/chat/completions';
      expect(chatCompletionsUrl(full), full);
      expect(chatCompletionsUrl('$full/'), full);
    });

    test('首尾空白会被剪掉（复制粘贴的常见坑）', () {
      expect(
        chatCompletionsUrl('  https://api.example.com/v1  '),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('空串还是空串，不拼出一个半截地址', () {
      expect(chatCompletionsUrl(''), '');
      expect(chatCompletionsUrl('   '), '');
    });
  });

  group('预置清单', () {
    test('默认那家真的在清单里', () {
      // 不在的话，首次启动会拿着一个查不到的 id 去构造客户端。
      expect(providerById(kDefaultProviderId), isNotNull);
    });

    test('id 不重复', () {
      final ids = kLlmProviders.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('查不到的 id 返回 null，而不是抛异常', () {
      // 设置里可能存着一个已经被删掉的供应商，那是用户升级上来的正常情况，
      // 不该让 App 起不来。
      expect(providerById('这家已经没有了'), isNull);
    });

    test('「自定义」那条被标记出来，且地址和模型名留空等用户填', () {
      final custom = providerById(kCustomProviderId)!;
      expect(custom.isCustom, isTrue);
      expect(custom.baseUrl, isEmpty);
      expect(custom.defaultModel, isEmpty);
    });

    test('预置的那几家都要有地址和默认模型名', () {
      // 「选完就能开箱试一下」靠的就是这两个字段。漏一个的话，
      // 用户在下拉里选中它，直接就报"还没填接口地址"。
      for (final p in kLlmProviders.where((p) => !p.isCustom)) {
        expect(p.baseUrl, isNotEmpty, reason: '${p.id} 没有地址');
        expect(p.defaultModel, isNotEmpty, reason: '${p.id} 没有默认模型名');
        expect(
          p.baseUrl.startsWith('http'),
          isTrue,
          reason: '${p.id} 的地址不像个 URL',
        );
      }
    });

    test('要 Key 的那几家都给了申请地址', () {
      // 本机跑的那家（Ollama）不需要 Key，所以 keyUrl 为空是合理的。
      for (final p in kLlmProviders.where((p) => !p.isCustom)) {
        if (p.id == 'ollama') continue;
        expect(p.keyUrl, isNotNull, reason: '${p.id} 没说去哪申请 Key');
      }
    });
  });
}
