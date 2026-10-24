import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_llm.dart';

ToolCall _call(String name, [Map<String, Object?> args = const {}]) =>
    ToolCall(id: 'c1', name: name, arguments: args);

void main() {
  late ToolRegistry registry;
  late ToolContext ctx;

  setUp(() {
    registry = ToolRegistry();
    ctx = testContext();
  });

  group('注册表', () {
    test('按名字查、能删、声明顺序稳定', () {
      registry
        ..register(ProbeTool('zeta'))
        ..register(ProbeTool('alpha'));

      expect(registry.byName('alpha'), isNotNull);
      expect(registry.byName('nope'), isNull);
      expect(registry.specs.map((s) => s.name).toList(), ['alpha', 'zeta']);

      expect(registry.remove('alpha'), isTrue);
      expect(registry.remove('alpha'), isFalse);
      expect(registry.specs.map((s) => s.name).toList(), ['zeta']);
    });

    test('同名覆盖', () {
      registry
        ..register(ProbeTool('x', description: '旧的'))
        ..register(ProbeTool('x', description: '新的'));

      expect(registry.all.length, 1);
      expect(registry.byName('x')!.description, '新的');
    });

    test('spec 把 schema 带出去', () {
      registry.register(
        ProbeTool(
          'echo',
          description: '回显',
          schema: const {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        ),
      );

      final spec = registry.specs.single;
      expect(spec.name, 'echo');
      expect(spec.description, '回显');
      expect((spec.parameters['required'] as List).single, 'text');
    });
  });

  group('执行', () {
    test('正常返回', () async {
      registry.register(ProbeTool('ok', result: const ToolResult.ok('做完了')));

      final inv = await registry.invoke(_call('ok'), ctx);

      expect(inv.result.ok, isTrue);
      expect(inv.result.content, '做完了');
      expect(inv.call.name, 'ok');
    });

    test('参数原样传给工具', () async {
      final probe = ProbeTool('ok');
      registry.register(probe);

      await registry.invoke(_call('ok', {'a': 1, 'b': '二'}), ctx);

      expect(probe.receivedInputs.single, {'a': 1, 'b': '二'});
    });

    test('缺参数抛 ToolInputException 时转成清楚的失败文本', () async {
      registry.register(
        _ThrowingTool(const ToolInputException('缺少必填参数 `url`')),
      );

      final inv = await registry.invoke(_call('thrower'), ctx);

      expect(inv.result.ok, isFalse);
      expect(inv.result.content, contains('参数错误'));
      expect(inv.result.content, contains('url'));
    });

    test('超时被兜住并说明是超时', () async {
      registry.register(
        ProbeTool('slow', delay: const Duration(seconds: 2)),
        timeout: const Duration(milliseconds: 40),
      );

      final inv = await registry.invoke(_call('slow'), ctx);

      expect(inv.result.ok, isFalse);
      expect(inv.result.content, contains('超时'));
    });

    test('未知工具的错误信息里列出可用工具', () async {
      registry.register(ProbeTool('real'));

      final inv = await registry.invoke(_call('ghost'), ctx);

      expect(inv.result.ok, isFalse);
      expect(inv.result.content, contains('ghost'));
      expect(inv.result.content, contains('real'));
    });

    test('参数是坏 JSON 时提示重新生成，而不是去执行', () async {
      final probe = ProbeTool('echo');
      registry.register(probe);

      final inv = await registry.invoke(
        ToolCall(id: 'c', name: 'echo', arguments: const {'__raw': 'bad'}),
        ctx,
      );

      expect(inv.result.ok, isFalse);
      expect(inv.result.content, contains('JSON'));
      expect(probe.receivedInputs, isEmpty, reason: '坏参数不该真去执行');
    });

    test('记录耗时', () async {
      registry.register(
        ProbeTool('slow', delay: const Duration(milliseconds: 60)),
      );

      final inv = await registry.invoke(_call('slow'), ctx);

      expect(inv.duration.inMilliseconds, greaterThanOrEqualTo(50));
    });
  });

  group('参数取值 helper', () {
    test('requireString 缺了就抛', () {
      expect(
        () => N1Tool.requireString({}, 'url'),
        throwsA(isA<ToolInputException>()),
      );
      expect(
        () => N1Tool.requireString({'url': '   '}, 'url'),
        throwsA(isA<ToolInputException>()),
      );
      expect(N1Tool.requireString({'url': ' a '}, 'url'), 'a');
    });

    test('optionalString 空当没有', () {
      expect(N1Tool.optionalString({}, 'k'), isNull);
      expect(N1Tool.optionalString({'k': ''}, 'k'), isNull);
      expect(N1Tool.optionalString({'k': ' v '}, 'k'), 'v');
    });

    test('optionalInt 兼容数字和字符串', () {
      expect(N1Tool.optionalInt({'n': 7}, 'n', fallback: 1), 7);
      expect(N1Tool.optionalInt({'n': 7.9}, 'n', fallback: 1), 7);
      expect(N1Tool.optionalInt({'n': '7'}, 'n', fallback: 1), 7);
      expect(N1Tool.optionalInt({'n': 'abc'}, 'n', fallback: 1), 1);
      expect(N1Tool.optionalInt({}, 'n', fallback: 1), 1);
    });
  });
}

class _ThrowingTool extends N1Tool {
  const _ThrowingTool(this.error);

  final Object error;

  @override
  String get name => 'thrower';

  @override
  String get description => '总是抛异常';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) async {
    throw error;
  }
}
