import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/n1_runtime.dart';

import '../support/fake_browser.dart';
import '../support/fake_llm.dart';

/// 盯「浏览器工具到底有没有进这次会话」这一件事。
///
/// 为什么单独一个文件：用户报的第一句话就是**"让它干活，它说做不到"**，
/// 而根因不是模型不会用，是**工具压根没注册进去**——`newSession` 里那句
/// `if (browser.isAvailable)` 永远为假，7 个 `browser_*` 工具一个都没进
/// registry，模型看不见，只能说做不到。
///
/// 这一环没有任何测试盯过。改坏了不会红，只会静悄悄地退回"做不到"。
N1Session buildSession({required ToolRegistry tools, required BrowserDriver browser}) {
  final context = testContext(browser: browser);
  return N1Session(
    tools: tools,
    context: context,
    loop: AgentLoop(
      llm: FakeLlmClient(const []),
      tools: tools,
      context: context,
      promptBuilder: testPromptBuilder(),
    ),
  );
}

ToolRegistry emptyRegistry() => ToolRegistry();

List<String> browserToolNames(ToolRegistry tools) =>
    tools.specs.map((s) => s.name).where((n) => n.startsWith('browser_')).toList();

void main() {
  test('驱动可用：浏览器工具真的进 registry，而且回合数被放宽', () {
    final tools = emptyRegistry();
    final driver = FakeBrowserDriver();
    final session = buildSession(tools: tools, browser: driver);

    // 补之前一个都没有——先把"没接线时是什么样"钉住，
    // 否则下面那句断言可能因为工具本来就注册了而假绿。
    expect(browserToolNames(tools), isEmpty);
    expect(session.loop.maxTurns, 8);

    session.installBrowserTools(driver);

    // 7 个，一个不少（open/snapshot/click/type/scroll/screenshot/back）
    expect(browserToolNames(tools), hasLength(7));
    expect(browserToolNames(tools), contains('browser_open'));
    expect(browserToolNames(tools), contains('browser_scroll'));

    // 8 轮会被一个普通网页任务吃满（open→snapshot→click→snapshot→type→
    // click→snapshot→screenshot 正好 8 步），然后停在最要紧的那一步。
    expect(session.loop.maxTurns, 20);
  });

  test('浏览器工具用的是 60 秒超时，不是默认的 30 秒', () {
    // 少了注册时那个 `timeout:`，"打开一个慢站 + 等它稳定"就会撞上默认
    // 30 秒，模型收到"超时了"就以为这个站打不开，然后放弃。
    final tools = emptyRegistry();
    final driver = FakeBrowserDriver();
    buildSession(tools: tools, browser: driver).installBrowserTools(driver);

    for (final name in browserToolNames(tools)) {
      expect(
        tools.timeoutFor(name),
        N1Runtime.browserToolTimeout,
        reason: '$name 没拿到放宽后的超时',
      );
    }
  });

  test('驱动不可用：一个都不注册，回合数也不动', () {
    final tools = emptyRegistry();
    final driver = FakeBrowserDriver(
      available: false,
      unavailableReason: '这台机器上没有浏览器',
    );
    final session = buildSession(tools: tools, browser: driver);

    session.installBrowserTools(driver);

    // 给一个"调了就失败"的工具比一个都不给更糟：模型会反复重试同一个工具，
    // 每次都失败，最后一轮里全花在这上面。
    expect(browserToolNames(tools), isEmpty);
    expect(session.loop.maxTurns, 8);
  });

  test('平台有能力但还没热：照注册，等真要用的时候再热', () {
    // 这是 Windows 现在的常态：开机**不**拉 Edge（否则每次开 App 都弹一个
    // about:blank），所以建会话时驱动一定是冷的。工具必须先注册上，
    // 否则模型永远看不见 browser_*，只能说做不到。
    final tools = emptyRegistry();
    final driver = FakeBrowserDriver(
      available: false,
      canWarmUp: true,
      unavailableReason: '还没启动',
    );
    final session = buildSession(tools: tools, browser: driver);

    session.installBrowserTools(driver);

    expect(browserToolNames(tools), hasLength(7));
    expect(session.loop.maxTurns, 20);
    // 注册本身不能预热——那还是会在没打算上网的时候拉起浏览器。
    expect(driver.warmUpCount, 0);
  });

  test('幂等：每轮都调也只有一份，不会重复注册', () {
    final tools = emptyRegistry();
    final session = buildSession(tools: tools, browser: FakeBrowserDriver());
    final driver = FakeBrowserDriver();

    session.installBrowserTools(driver);
    session.installBrowserTools(driver);
    session.installBrowserTools(driver);

    expect(browserToolNames(tools), hasLength(7));
  });

  test('先不可用、后来才可用——这正是真跑里最常见的时序', () {
    // 真实时序：boot 只是**后台**预热浏览器，用户打字那会儿多半还没好。
    // 于是会话是先建的（那会儿注册不进去），浏览器热好之后每一轮再补。
    // 补不上的话，第一句话之后建的会话会**永远**看不见浏览器工具。
    final tools = emptyRegistry();
    final driver = FakeBrowserDriver(
      available: false,
      unavailableReason: '还在启动',
    );
    final session = buildSession(tools: tools, browser: driver);

    session.installBrowserTools(driver);
    expect(browserToolNames(tools), isEmpty, reason: '还没热好就不该注册');

    driver.available = true; // 预热完成
    session.installBrowserTools(driver);

    expect(browserToolNames(tools), hasLength(7));
    expect(session.loop.maxTurns, 20);
  });
}
