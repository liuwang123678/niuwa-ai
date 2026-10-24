import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/code/code_runner_factory.dart';
import 'package:niuwa_ai/services/fs/file_access.dart';
import 'package:niuwa_ai/services/fs/local_file_backups.dart';
import 'package:niuwa_ai/services/n1_runtime.dart';

import '../support/fake_browser.dart';
import '../support/fake_code_runner.dart';
import '../support/fake_llm.dart';

/// 盯「跑代码的工具到底有没有进这次会话」这一件事。
///
/// 跟 `session_browser_tools_test.dart` 是同一类问题，但这里多一层坑：
/// 浏览器只有一个可用条件（`isAvailable`），跑代码有**两个**——
/// `run_command` 看 `supportsCommand`，`run_code` 看 `isAvailable`。
/// 说错了的症状是"模型说它不能跑代码"，而 registry 里其实一个工具都没有。
N1Session buildSession({
  required ToolRegistry tools,
  required CodeRunner runner,
  WorkLevel level = WorkLevel.standard,
}) {
  final context = testContext();
  return N1Session(
    tools: tools,
    context: context,
    level: level,
    loop: AgentLoop(
      llm: FakeLlmClient(const []),
      tools: tools,
      context: context,
      promptBuilder: testPromptBuilder(),
      maxTurns: level.maxTurns,
    ),
  );
}

List<String> codeToolNames(ToolRegistry tools) => tools.specs
    .map((s) => s.name)
    .where((n) => n == 'run_command' || n == 'run_code')
    .toList();

List<String> fileToolNames(ToolRegistry tools) => tools.specs
    .map((s) => s.name)
    .where((n) => const {'read_file', 'write_file', 'edit_file', 'list_dir'}.contains(n))
    .toList();

/// 一套文件访问环境，**不碰真盘**：路径解析和策略是纯数据，备份目录指到
/// 系统临时目录（测试不会真的往里写，只验注册表里多了几个工具）。
///
/// 这里刻意不调 `createFileAccess()`：那个函数会去读真注册表（探桌面在哪），
/// 在测试机上跑得慢还可能因为策略差异给出不同结果。要验的只是"注册了几样"。
FileAccess fakeFileAccess() {
  return FileAccess(
    paths: PathResolver(home: r'C:\Users\test', isWindows: true),
    policy: FilePolicy.standard(
      environment: const {'SystemRoot': r'C:\Windows'},
      isWindows: true,
    ),
    // 这个目录**不建**：这些测试只验"注册表里多了几个工具"，一次都不写盘。
    // 真往备份目录里写的是 `local_file_backups_test.dart`。
    backups: LocalFileBackupStore(
      dir: Directory('${Directory.systemTemp.path}/n1-session-code-tools'),
    ),
  );
}

void main() {
  group('进会话', () {
    test('都可用：两个工具都进 registry，回合数放宽到 30', () {
      final tools = ToolRegistry();
      final runner = FakeCodeRunner();
      final session = buildSession(tools: tools, runner: runner);

      // 先钉住"没接线时是什么样"，否则下面可能是假绿。
      expect(codeToolNames(tools), isEmpty);
      expect(session.loop.maxTurns, 8);

      session.installCodeTools(runner);

      expect(codeToolNames(tools), hasLength(2));
      expect(codeToolNames(tools), contains('run_command'));
      expect(codeToolNames(tools), contains('run_code'));
      // 写→跑→看报错→改→再跑，8 轮**恰好在最该继续的时候**停下。
      expect(session.loop.maxTurns, 30);
    });

    test('两个工具用 150 秒超时，不是默认的 30 秒', () {
      // 顺序要紧：注册表这一层必须比执行器自己的硬上限（120 秒）宽，
      // 不然先超时的是注册表，模型收到一句干巴巴的"超时"，
      // 而进程还在跑、谁也不知道。
      final tools = ToolRegistry();
      final runner = FakeCodeRunner();
      buildSession(tools: tools, runner: runner).installCodeTools(runner);

      for (final name in codeToolNames(tools)) {
        expect(
          tools.timeoutFor(name),
          N1Runtime.codeToolTimeout,
          reason: '$name 没拿到放宽后的超时',
        );
      }
      // 这条断言本身也要钉住，不然上面那句变成"两个错的值相等"。
      expect(
        N1Runtime.codeToolTimeout,
        greaterThan(const Duration(seconds: 120)),
      );
    });

    test('没探到解释器：命令行进，脚本不进，回合数也不动', () {
      final tools = ToolRegistry();
      final runner = FakeCodeRunner(available: false, languages: const {});
      final session = buildSession(tools: tools, runner: runner);

      session.installCodeTools(runner);

      // `cmd` 一定在，`python` 不一定——这两件事没关系，不能一起关掉。
      expect(codeToolNames(tools), ['run_command']);
      // 放宽回合是给"写→跑→改"那个循环的，光有命令行不需要。
      expect(session.loop.maxTurns, 8);
    });

    test('连命令行都跑不了：一个都不进', () {
      final tools = ToolRegistry();
      final runner = FakeCodeRunner(
        available: false,
        commandSupported: false,
        languages: const {},
      );
      final session = buildSession(tools: tools, runner: runner);

      session.installCodeTools(runner);

      expect(codeToolNames(tools), isEmpty);
      expect(session.loop.maxTurns, 8);
    });

    test('幂等：每轮都调也只有一份', () {
      final tools = ToolRegistry();
      final runner = FakeCodeRunner();
      final session = buildSession(tools: tools, runner: runner);

      session.installCodeTools(runner);
      session.installCodeTools(runner);
      session.installCodeTools(runner);

      expect(codeToolNames(tools), hasLength(2));
    });

    test('先没探到、后来才探到——这正是真跑里的时序', () {
      // 真实时序：boot 只是**后台**探解释器，用户打字那会儿多半还没好。
      // 会话是先建的（那会儿 run_code 进不来），之后每一轮再补。
      //
      // ⚠️ 这条是**一个 bool 会坏掉的那个用例**：如果用一个"补过了"的开关，
      // 第一次调（只补上 run_command）就把开关置成 true，等预热完成再调直接
      // return——`run_code` 一整场都进不来，而且不报错，看起来就是
      // "模型从来不用这个工具"。按名字记账才对。
      final tools = ToolRegistry();
      final runner = FakeCodeRunner(available: false, languages: const {});
      final session = buildSession(tools: tools, runner: runner);

      session.installCodeTools(runner);
      expect(codeToolNames(tools), ['run_command']);
      expect(session.loop.maxTurns, 8);

      runner.available = true; // 预热完成，探到 python 了
      session.installCodeTools(runner);

      expect(codeToolNames(tools), contains('run_code'));
      expect(codeToolNames(tools), hasLength(2));
      expect(session.loop.maxTurns, 30);

      // 再补一次也不会重复。
      session.installCodeTools(runner);
      expect(codeToolNames(tools), hasLength(2));
    });

    test('会话的 dispose 不碰执行器——它的命归 runtime 管', () async {
      // 执行器是 runtime 级的（整场会话共用、预热一次），会话级关掉的话，
      // 用户点一次"新建对话"，代码执行器就没了，而且下一轮也补不回来
      // （`warmUp` 已经幂等过了）。
      final runner = FakeCodeRunner();
      final session = buildSession(tools: ToolRegistry(), runner: runner);

      session.dispose();

      expect(runner.disposeCount, 0);
    });
  });

  group('工作强度决定回合数', () {
    test('省着用：装了 run_code 也只给 codeTurns 那么多，比标准少', () {
      final tools = ToolRegistry();
      final session = buildSession(
        tools: tools,
        runner: FakeCodeRunner(),
        level: WorkLevel.frugal,
      );

      session.installCodeTools(FakeCodeRunner());

      expect(session.loop.maxTurns, WorkLevel.frugal.codeTurns);
      expect(
        session.loop.maxTurns,
        lessThan(WorkLevel.standard.codeTurns),
        reason: '不然这一档就跟标准一样了',
      );
    });

    test('放开干：给得比标准多——这一档是拿 token 换"别在中途停下"', () {
      final session = buildSession(
        tools: ToolRegistry(),
        runner: FakeCodeRunner(),
        level: WorkLevel.thorough,
      );

      session.installCodeTools(FakeCodeRunner());

      expect(session.loop.maxTurns, WorkLevel.thorough.codeTurns);
      expect(
        session.loop.maxTurns,
        greaterThan(WorkLevel.standard.codeTurns),
      );
    });

    test('会话不带 level 时就是标准档——测试里那些裸造的地方行为不变', () {
      final tools = ToolRegistry();
      final context = testContext();
      final session = N1Session(
        tools: tools,
        context: context,
        loop: AgentLoop(
          llm: FakeLlmClient(const []),
          tools: tools,
          context: context,
          promptBuilder: testPromptBuilder(),
        ),
      );

      expect(session.level, WorkLevel.standard);
      session.installCodeTools(FakeCodeRunner());
      expect(session.loop.maxTurns, 30, reason: '标准档等于加旋钮之前的数');
    });
  });

  group('按平台造执行器', () {
    test('Windows 走真起进程那个', () {
      final fake = FakeCodeRunner();
      final made = createCodeRunner(
        platform: TargetPlatform.windows,
        windowsRunner: fake,
      );
      expect(identical(made, fake), isTrue);
    });

    test('安卓给的是**真**实现（借 WebView 跑 JS），不是"没有"', () {
      // 曾经这里是"没有"——那是对的，因为那时候确实没有。现在有了，
      // 但**不能因此把测试改成"有"就完事**：这里要钉的是"给的是真的那条路"，
      // 而不是"给了一个 isAvailable 为 true 的东西"。后者拿空壳也能过，
      // 而空壳的症状（模型调 run_code 拿到空结果、反复重试到撞回合上限）
      // 比"看不见这个工具"糟得多。
      final made = createCodeRunner(platform: TargetPlatform.android);
      expect(
        made.runtimeType.toString(),
        'WebViewJsRunner',
        reason: '安卓那条路就是借 WebView 跑 JS，不该退化成空壳',
      );
    });

    test('刚造出来是**未预热**：如实说没准备好，不是谎报能用', () {
      // ⚠️ 这条跟上面那条是一对：真实现 + 还没热，`isAvailable` 就该是 false。
      // 预热要建一个 WebView，是异步的；`isAvailable` 提前返回 true 的话，
      // 模型会在第一轮里调到一个还不能跑的 runner。
      // （注册那一层按"还没探到"先不给这个工具，热完的回合再补。）
      final made = createCodeRunner(platform: TargetPlatform.android);
      expect(made.isAvailable, isFalse);
      expect(made.unavailableReason, isNotNull);
      expect(made.unavailableReason, contains('还没准备好'));
      expect(made.supportsCommand, isFalse, reason: '普通 App 没有 shell');
    });

    test('macOS / Linux 也如实说没有，不硬塞一个 Windows 实现', () {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
        final made = createCodeRunner(platform: platform);
        expect(made.isAvailable, isFalse, reason: '$platform');
        expect(made.supportsCommand, isFalse, reason: '$platform');
      }
    });

    test('安卓那一路可以注入——真造 WebView 得插件在 Activity 里注册过', () {
      final fake = FakeCodeRunner(languages: const {CodeLanguage.javascript});
      final made = createCodeRunner(
        platform: TargetPlatform.android,
        androidRunner: fake,
      );
      expect(identical(made, fake), isTrue);
    });

    test('Windows 那一路可以注入——上层测试不用真起进程', () {
      final made = createCodeRunner(platform: TargetPlatform.windows);
      expect(made, isA<CodeRunner>());
      expect(
        made.runtimeType.toString(),
        'ProcessCodeRunner',
        reason: '默认应该是真起进程那个',
      );
    });
  });

  group('总开关关掉', () {
    test('一个代码工具都不进，回合数也不放宽', () {
      final tools = ToolRegistry();
      final session = buildSession(tools: tools, runner: FakeCodeRunner());

      session.installCodeTools(FakeCodeRunner(), allowed: false);

      expect(codeToolNames(tools), isEmpty);
      expect(
        session.loop.maxTurns,
        8,
        reason: '工具都没给，"多给几轮去跑代码"就没意义了',
      );
    });

    test('**先装后关要摘掉**，不是"以后不再装"', () {
      // 这一条是总开关的**真正语义**。只做"不再装"的话，症状是：
      // 用户刚看见一个弹窗、决定不想让它碰自己电脑，去设置里关掉，
      // 回来接着打字——这一轮里 `write_file` 照样在注册表里。
      //
      // 为什么不能靠 `resetSession()` 补救：用户是在**一轮对话正跑着的时候**
      // 关的，那时候 reset 只是记账（等这一轮收完摊才真丢会话），
      // 而这个开关恰恰最该在当下生效。
      final tools = ToolRegistry();
      final session = buildSession(tools: tools, runner: FakeCodeRunner());

      session.installCodeTools(FakeCodeRunner());
      expect(codeToolNames(tools), hasLength(2));

      session.installCodeTools(FakeCodeRunner(), allowed: false);

      expect(codeToolNames(tools), isEmpty, reason: '关掉要**摘掉**，不是"以后不再装"');
    });

    test('关掉时记账也清干净了——不然关一次就永久废了', () {
      // 摘掉工具但留着名字记账的话，再打开时 `_installed.add(...)` 会发现
      // "这个名字已经有了"，于是**一个都不补回来**，而且不报错。
      final tools = ToolRegistry();
      final session = buildSession(tools: tools, runner: FakeCodeRunner());

      session.installCodeTools(FakeCodeRunner());
      session.installCodeTools(FakeCodeRunner(), allowed: false);

      session.installCodeTools(FakeCodeRunner());

      expect(
        codeToolNames(tools),
        hasLength(2),
        reason: '记账没清干净的话，这个开关只能关不能开',
      );
    });
  });

  group('进会话 · 文件工具', () {
    test('都可用：四个工具都进 registry，回合数按 codeTurns 放宽', () {
      final tools = ToolRegistry();
      final session = buildSession(tools: tools, runner: FakeCodeRunner());

      expect(fileToolNames(tools), isEmpty);
      expect(session.loop.maxTurns, 8);

      final fs = fakeFileAccess();
      session.installFileTools(
        paths: fs.paths,
        policy: fs.policy,
        backups: fs.backups,
      );

      expect(fileToolNames(tools), hasLength(4));
      expect(fileToolNames(tools), contains('read_file'));
      expect(fileToolNames(tools), contains('list_dir'));
      expect(fileToolNames(tools), contains('write_file'));
      expect(fileToolNames(tools), contains('edit_file'));
      expect(session.loop.maxTurns, WorkLevel.standard.codeTurns);
    });

    test('幂等：每轮都调也只有一份', () {
      final tools = ToolRegistry();
      final session = buildSession(tools: tools, runner: FakeCodeRunner());
      final fs = fakeFileAccess();

      for (var i = 0; i < 3; i++) {
        session.installFileTools(
          paths: fs.paths,
          policy: fs.policy,
          backups: fs.backups,
        );
      }

      expect(fileToolNames(tools), hasLength(4));
    });

    test('总开关管着文件工具那一份：先装后关同样要摘掉', () {
      final tools = ToolRegistry();
      final session = buildSession(tools: tools, runner: FakeCodeRunner());
      final fs = fakeFileAccess();

      session.installFileTools(
        paths: fs.paths,
        policy: fs.policy,
        backups: fs.backups,
      );
      expect(fileToolNames(tools), hasLength(4));

      session.installFileTools(
        paths: fs.paths,
        policy: fs.policy,
        backups: fs.backups,
        allowed: false,
      );

      expect(fileToolNames(tools), isEmpty);

      // 再打开要能全补回来（记账清了）。
      session.installFileTools(
        paths: fs.paths,
        policy: fs.policy,
        backups: fs.backups,
      );
      expect(fileToolNames(tools), hasLength(4));
    });
  });

  group('放宽回合只往上调', () {
    test('先代码后浏览器，也不会被浏览器那一档调小', () {
      // 原来是直接赋值，于是三路工具安装的**先后顺序会决定最终值**。
      // 目前调用顺序固定（浏览器先、代码后、文件最后），结果一直是对的
      // ——但那是巧合。标准档 browserTurns(20) < codeTurns(30)，
      // 反过来装就会把它调小，而且完全没有症状。
      final tools = ToolRegistry();
      final session = buildSession(
        tools: tools,
        runner: FakeCodeRunner(),
        level: WorkLevel.standard, // 30 > 20
      );

      session.installCodeTools(FakeCodeRunner());
      expect(session.loop.maxTurns, 30);

      session.installBrowserTools(FakeBrowserDriver());

      expect(session.loop.maxTurns, 30, reason: '浏览器那一档更小，不该把它压下去');
    });

    test('两档都更小时用大的那个——挑一档能验出方向的', () {
      // 省着用这一档 browserTurns(12) < codeTurns(18)，跟标准档同向；
      // 用它是为了说明上面那条不是"标准档特有"的巧合。
      final tools = ToolRegistry();
      final session = buildSession(
        tools: tools,
        runner: FakeCodeRunner(),
        level: WorkLevel.frugal,
      );

      session.installCodeTools(FakeCodeRunner());
      session.installBrowserTools(FakeBrowserDriver());

      expect(session.loop.maxTurns, WorkLevel.frugal.codeTurns);
      expect(
        WorkLevel.frugal.codeTurns,
        greaterThan(WorkLevel.frugal.browserTurns),
        reason: '这一档就是靠这两档的大小关系验的，值改了这条测试要跟着改',
      );
    });

    test('较小的那一路先装，大的后装，照样取最大', () {
      final tools = ToolRegistry();
      final session = buildSession(tools: tools, runner: FakeCodeRunner());

      session.installBrowserTools(FakeBrowserDriver());
      expect(session.loop.maxTurns, 20);

      session.installCodeTools(FakeCodeRunner());
      expect(session.loop.maxTurns, 30);
    });
  });
}
