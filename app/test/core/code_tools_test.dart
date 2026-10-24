import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

import '../support/fake_code_runner.dart';
import '../support/fake_llm.dart';

/// 盯执行类工具这一层：**参数有没有原样传下去、该注册的注册了没有、
/// 失败的时候是给模型一句话还是抛异常**。
///
/// 真起进程那一路在 `test/services/process_code_runner_test.dart`。
/// 两个文件分工明确：这里验接线，那里验实现。
void main() {
  late FakeCodeRunner runner;

  setUp(() => runner = FakeCodeRunner());

  group('该注册哪些', () {
    test('两个都行：命令行和脚本都在', () {
      final names = codeTools(runner: runner).map((t) => t.name).toList();
      expect(names, containsAll(['run_command', 'run_code']));
    });

    test('没探到解释器：只给命令行，不给脚本', () {
      // 这台机器没装 Python 和 Node，`cmd` / `dir` / `ping` 照样跑得动。
      // 用一个 isAvailable 管住两个工具是错的——那会**连带把命令行也关掉**。
      final names = codeTools(
        runner: FakeCodeRunner(available: false, languages: const {}),
      ).map((t) => t.name).toList();
      expect(names, contains('run_command'));
      expect(names, isNot(contains('run_code')));
    });

    test('连命令行都跑不了：一个都不给', () {
      // 给一个"调了就失败"的工具比一个都不给更糟：模型会反复重试，
      // 最后把回合全花在它上面。
      final names = codeTools(
        runner: FakeCodeRunner(
          available: false,
          commandSupported: false,
          languages: const {},
        ),
      ).map((t) => t.name).toList();
      expect(names, isEmpty);
    });
  });

  group('run_command', () {
    test('命令原样传下去，工作目录和超时也传', () async {
      final tool = RunCommandTool(runner: runner);
      await tool.call({
        'command': 'git status',
        'working_directory': r'C:\proj',
        'timeout_seconds': 30,
      }, testContext());

      expect(runner.commandRequests, hasLength(1));
      final sent = runner.commandRequests.single;
      expect(sent.command, 'git status');
      expect(sent.workingDirectory, r'C:\proj');
      expect(sent.timeout, const Duration(seconds: 30));
    });

    test('没填超时：给 0，让执行器用它自己的默认值', () async {
      // 这里写死 60 秒的话，以后调执行器的默认超时，工具这一路永远不跟着变，
      // 而且看不出来——`_clampTimeout` 只把 0 当成"没填"。
      await RunCommandTool(runner: runner).call({
        'command': 'dir',
      }, testContext());

      expect(runner.commandRequests.single.timeout, Duration.zero);
    });

    test('结果原样给模型看，退出码也带上', () async {
      runner.result = const CodeResult(
        exitCode: 2,
        stdout: '部分输出',
        stderr: '出错了',
      );
      final result = await RunCommandTool(runner: runner).call({
        'command': 'dir',
      }, testContext());

      expect(result.ok, isTrue, reason: '命令跑完了就是跑完了，退出码非 0 由内容说');
      expect(result.content, contains('退出码：2'));
      expect(result.content, contains('出错了'));
      expect(result.meta?['exit_code'], 2);
    });

    test('执行器说跑不了：给模型一句人话，不抛异常', () async {
      final tool = RunCommandTool(
        runner: FakeCodeRunner(
          available: false,
          commandSupported: false,
          unavailableReason: '这台设备上跑不了命令行。',
        ),
      );
      final result = await tool.call({'command': 'dir'}, testContext());

      expect(result.ok, isFalse);
      expect(result.content, contains('跑不了命令行'));
      expect(runner.commandRequests, isEmpty);
    });

    test('执行器自己抛 CodeException：翻成失败结果，别让模型看见类名', () async {
      runner.failWith = const CodeException('起不来：pythn —— 系统找不到指定的文件');
      final result = await RunCommandTool(runner: runner).call({
        'command': 'pythn -V',
      }, testContext());

      expect(result.ok, isFalse);
      expect(result.content, contains('系统找不到指定的文件'));
      // `ToolRegistry` 的兜底分支会写成 `CodeException: ...`，
      // 模型不认识那个类名，得在工具这一层就翻干净。
      expect(result.content, isNot(contains('CodeException')));
    });

    test('危险命令要问用户，安全命令不问', () {
      final tool = RunCommandTool(runner: runner);

      expect(tool.approvalReason({'command': 'dir'}), isNull);
      expect(tool.approvalReason({'command': 'git status'}), isNull);

      final reason = tool.approvalReason({'command': 'del /s /q C:\\重要资料'});
      expect(reason, isNotNull);
      // 弹窗上那句话必须是**给用户看的中文**，不是规则的英文 id。
      expect(reason, startsWith('会'));
    });

    test('命令没给或者不是字符串：不判危险（注册表会先报参数错）', () {
      final tool = RunCommandTool(runner: runner);
      expect(tool.approvalReason(const {}), isNull);
      expect(tool.approvalReason({'command': 42}), isNull);
      expect(tool.approvalReason({'command': '   '}), isNull);
    });
  });

  group('run_code', () {
    test('源码原样传下去——开头的缩进一个字都不能少', () async {
      // trim 一下对命令没影响，对 Python 是灾难：报 `IndentationError`，
      // 而模型会去查自己的逻辑，完全想不到是工具动了它的字符串。
      const source = 'def f():\n    return 1\n\nprint(f())\n';
      await RunCodeTool(runner: runner).call({
        'language': 'python',
        'source': source,
      }, testContext());

      expect(runner.codeRequests.single.source, source);
      expect(runner.codeRequests.single.language, CodeLanguage.python);
    });

    test('语言枚举按实际探测结果给，不写死一份全语言清单', () {
      final tool = RunCodeTool(
        runner: FakeCodeRunner(
          languages: const {CodeLanguage.python, CodeLanguage.node},
        ),
      );
      final properties = tool.inputSchema['properties']! as Map;
      final language = properties['language']! as Map;
      expect(language['enum'], ['python', 'node']);
    });

    test('安卓上只给 javascript——给 python 等于让模型白试一轮', () {
      final tool = RunCodeTool(
        runner: FakeCodeRunner(languages: const {CodeLanguage.javascript}),
      );
      final properties = tool.inputSchema['properties']! as Map;
      expect((properties['language']! as Map)['enum'], ['javascript']);
    });

    test('一个语言都没有：不给 enum，也不编一个出来', () {
      // 编 `['javascript']` 出来 schema 就在撒谎，而且撒谎的方向是
      // "去试一个这台设备上跑不了的语言"。
      final tool = RunCodeTool(
        runner: FakeCodeRunner(available: false, languages: const {}),
      );
      final properties = tool.inputSchema['properties']! as Map;
      expect((properties['language']! as Map).containsKey('enum'), isFalse);
    });

    test('语言写错：报错时把能用的列出来，不然模型不知道该怎么改', () async {
      await expectLater(
        RunCodeTool(runner: runner).call({
          'language': 'ruby',
          'source': 'puts 1',
        }, testContext()),
        throwsA(
          isA<ToolInputException>().having(
            (e) => e.message,
            'message',
            contains('Python'),
          ),
        ),
      );
    });

    test('语言没装：失败结果里说清跑不了哪个、能跑哪个', () async {
      final tool = RunCodeTool(
        runner: FakeCodeRunner(languages: const {CodeLanguage.python}),
      );
      final result = await tool.call({
        'language': 'node',
        'source': '1+1',
      }, testContext());

      expect(result.ok, isFalse);
      expect(result.content, contains('Node.js'));
      expect(result.content, contains('Python'));
      expect(runner.codeRequests, isEmpty);
    });

    test('脚本里的危险动作也要问——不经过 shell 不等于安全', () async {
      // 只拦命令行的话，绕过它就是"换个工具调"这么简单：
      // `run_code` 压根不经过 shell，删除动作藏在 Python 源码里。
      final tool = RunCodeTool(runner: runner);

      expect(tool.approvalReason({'source': 'print(1 + 1)'}), isNull);

      final reason = tool.approvalReason({
        'source': 'import shutil\nshutil.rmtree("/tmp/whatever")\n',
      });
      expect(reason, isNotNull);
      expect(reason, startsWith('会'));
    });

    test('执行器没探到解释器：说整件事为什么做不了，不去调', () async {
      // ⚠️ 这里钉的是一个**顺序**问题：语言检查如果排在执行器可用性前面，
      // 模型会收到"跑不了 Python。能跑的是：。"——既没说出真正的原因，
      // 也没给出"去哪儿装"这句有用的话。
      final tool = RunCodeTool(
        runner: FakeCodeRunner(
          available: false,
          languages: const {},
          unavailableReason: '这台电脑上没找到 Python 或 Node.js，装一个就能用。',
        ),
      );
      final result = await tool.call({
        'language': 'python',
        'source': 'print(1)',
      }, testContext());

      expect(result.ok, isFalse);
      expect(result.content, contains('没找到 Python'));
      expect(result.content, isNot(contains('能跑的是：。')));
    });
  });

  group('描述和参数要跟着平台变', () {
    /// 手机那一路：只有 JS、摸不到文件、异步等不到。
    ///
    /// 这里的 [FakeCodeRunner.scriptEnvironmentNote] 用的是**真实现里那句话**
    /// （`WebViewJsRunner.scriptEnvironmentNote`）——这不是为了好看：下面那条
    /// 断言要验的正是"环境特有的限制真的被说出来了"，随便编一句短的（只写
    /// 文件系统）会让测试红，而红得莫名其妙。
    FakeCodeRunner phoneRunner() => FakeCodeRunner(
      languages: const {CodeLanguage.javascript},
      scriptHasFileSystem: false,
      scriptEnvironmentNote:
          '它跑在手机自带浏览器的 JS 引擎里，有两件事和电脑上不一样：'
          '**摸不到文件系统**（要读写文件得用电脑版），'
          '**异步等不到结果**（Promise / async / await / 定时器都不行，'
          '只能同步算完直接给结果）。',
    );

    test('描述里必须写"摸不到文件系统"和"异步等不到"', () {
      // 这两条是模型按电脑上的预期写代码时**一定会踩**的。少写一句，
      // 它就会去写 `await fetch(...)`，然后拿到一个看不懂的失败，
      // 而它连"这条路根本没有文件系统"都想不到。
      final description = RunCodeTool(runner: phoneRunner()).description;

      expect(description, contains('文件系统'));
      expect(description, contains('异步'));
      expect(
        description,
        isNot(contains('临时文件')),
        reason: '那是电脑上那套（落临时文件再交给解释器），别串到手机上来',
      );
    });

    test('手机不给 working_directory——留着它就是个永远不起作用的参数', () {
      final properties =
          RunCodeTool(runner: phoneRunner()).inputSchema['properties']! as Map;

      expect(properties.containsKey('working_directory'), isFalse);
      expect(properties.containsKey('source'), isTrue);
    });

    test('电脑上那一路没被顺手改掉：还落临时文件，还收工作目录', () {
      final tool = RunCodeTool(runner: FakeCodeRunner());
      final properties = tool.inputSchema['properties']! as Map;

      expect(tool.description, contains('临时文件'));
      expect(properties.containsKey('working_directory'), isTrue);
    });
  });

  group('两个工具都别把异常漏出去', () {
    test('执行器抛出没见过的异常：翻成一句人话', () async {
      final runner = _ThrowerRunner();
      final result = await RunCommandTool(runner: runner).call({
        'command': 'dir',
      }, testContext());

      expect(result.ok, isFalse);
      expect(result.content, contains('跑的时候出错了'));
      expect(result.content, contains('说不清的怪问题'));
    });
  });
}

/// 抛一个**不是** [CodeException] 的异常。
///
/// 真实世界里的对应物：驱动内部某个库抛了它自己的异常类型。这种不能漏到
/// `ToolRegistry` 的兜底分支上去，否则模型收到的是 `_Exception: ...`。
class _ThrowerRunner extends CodeRunner {
  @override
  bool get isAvailable => true;

  @override
  bool get supportsCommand => true;

  @override
  Set<CodeLanguage> get supportedLanguages => const {CodeLanguage.python};

  @override
  Future<CodeResult> runCommand(CommandRequest request) async =>
      throw _WeirdException('说不清的怪问题');

  @override
  Future<CodeResult> run(CodeRequest request) async =>
      throw _WeirdException('说不清的怪问题');

  @override
  Future<void> dispose() async {}
}

class _WeirdException implements Exception {
  const _WeirdException(this.message);

  final String message;

  @override
  String toString() => message;
}
