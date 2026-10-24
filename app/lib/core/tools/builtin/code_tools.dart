import 'dart:async';

import '../../code/code_runner.dart';
import '../../code/danger_command.dart';
import '../n1_tool.dart';
import '../tool_context.dart';

/// 执行类的公共部分。
///
/// 跟 `_BrowserTool` 同一个套路，但多一层：**这里有两种"用不了"，一个工具
/// 只属于其中一种**。
///
///   - `run_command` 要的是 `supportsCommand`——这台机器没装 Python 和 Node，
///     `cmd` / `dir` / `ping` 照样跑得动，不该跟着一起消失。
///   - `run_code` 要的是 `isAvailable`（探到过解释器）——没探到就是真跑不了。
///
/// 早先想用一个 `isAvailable` 管住两个工具，结果是一台没装 Python 的机器上
/// `run_command` 也不见了。**没必要为了少写一个判断把这能力一起关掉。**
abstract class _CodeTool extends N1Tool {
  const _CodeTool({required this.runner});

  /// 跑命令和跑脚本都要进审计日志——这两个是"在用户电脑上执行东西"本身。
  /// 开在基类上，以后再加执行类工具不会漏。
  @override
  bool get audited => true;

  final CodeRunner runner;

  /// 拿执行器跑。把驱动那三种失败翻成模型看得懂的话。
  ///
  /// 跟浏览器那边一样\[**就地翻成失败结果，不要 rethrow**\]：`CodeException`
  /// 里那句话已经是给模型看的了，抛出去会被 `ToolRegistry.invoke` 的兜底分支
  /// 接住，那里是 `'${e.runtimeType}: $e'`——模型会收到
  /// `CodeException: 这台电脑上跑不了 Node.js`，前面挂个它不认识的类名。
  Future<ToolResult> withRunner(
    Future<ToolResult> Function(CodeRunner runner) body, {
    required bool needsCommand,
  }) async {
    final usable = needsCommand ? runner.supportsCommand : runner.isAvailable;
    if (!usable) {
      return ToolResult.fail(
        runner.unavailableReason ??
            '这台设备上跑不了${needsCommand ? '命令行' : '代码'}，'
                '如实告诉用户这件事做不到，别换个方式硬试。',
      );
    }

    try {
      return await body(runner);
    } on CodeException catch (e) {
      return ToolResult.fail(e.message);
    } on ToolInputException {
      rethrow; // 参数写错，注册表会翻成"参数错误"
    } on TimeoutException {
      rethrow; // 注册表会翻成超时
    } catch (e) {
      return ToolResult.fail('跑的时候出错了：$e');
    }
  }

  /// 超时参数。**缺省给 0，让执行器用它自己的默认值**。
  ///
  /// 这里写死一个数会有个阴间后果：以后调执行器的默认超时，工具这一路永远
  /// 不跟着变，而且看不出来（`_clampTimeout` 只认 0 当"没填"）。
  static Duration parseTimeout(Map<String, Object?> input) {
    final seconds = N1Tool.optionalInt(input, 'timeout_seconds', fallback: 0);
    return seconds > 0 ? Duration(seconds: seconds) : Duration.zero;
  }
}

class RunCommandTool extends _CodeTool {
  const RunCommandTool({required super.runner});

  /// 工具名。提成常量是因为 [N1Session.installCodeTools] 要按名字记账
  /// （两个执行类工具的就绪条件不一样，见那里的说明）。
  static const String toolName = 'run_command';

  @override
  String get name => toolName;

  @override
  String get description =>
      '在这台电脑上跑一条命令行，拿回退出码和输出。'
      '用它可以装依赖、跑测试、看目录、调系统工具、跑 git 这些。'
      '注意事项：'
      '① 命令是**原样**交给系统 shell 的，所以写法和你在终端里敲的一模一样'
      '（路径里有空格就照常加引号，引号不会被吃掉）；'
      '② 中文一般没问题——命令跑在一个 UTF-8 的临时脚本里，中文路径和中文输出都正常。'
      '  但按老代码页（GBK）输出的第三方工具仍可能乱码，真遇到会标出来，'
      '  别拿乱码去分析；'
      '③ 危险命令（删文件、改系统设置、下载来直接执行之类）会先弹窗问用户，'
      '  用户拒绝是正常的，别用同一句话反复重试，换个安全的做法或者直接说做不到；'
      '④ 有超时，默认一分钟，别写要跑很久的命令。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'command': {
        'type': 'string',
        'description': '要跑的命令，原样写，比如 `dir`、`git status`、`pip list`',
      },
      'working_directory': {
        'type': 'string',
        'description': '在哪个目录下跑。不填就是用户的家目录。可以写绝对路径',
      },
      'timeout_seconds': {
        'type': 'integer',
        'description': '最多跑多少秒，不填用默认值（一分钟）',
      },
    },
    'required': ['command'],
  };

  /// 危险命令才问。
  ///
  /// 判定在 `danger_command.dart`，那是个纯函数，有一整组单测钉着。
  /// ⚠️ **它是"手滑拦截 + 知情同意"的触发器，不是安全边界**——混淆过的命令
  /// （`d^el`）、变量拼接、先写脚本再跑都能绕过去。见那个文件的说明。
  @override
  String? approvalReason(Map<String, Object?> input) {
    final command = input['command'];
    if (command is! String || command.trim().isEmpty) return null;
    final verdict = judgeCommand(command);
    return verdict.needsApproval ? verdict.reason : null;
  }

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) {
    final command = N1Tool.requireString(input, 'command');
    return withRunner(needsCommand: true, (runner) async {
      final result = await runner.runCommand(
        CommandRequest(
          command: command,
          workingDirectory: N1Tool.optionalString(input, 'working_directory'),
          timeout: _CodeTool.parseTimeout(input),
        ),
      );
      return ToolResult.ok(
        result.toModelText(),
        meta: {
          'exit_code': result.exitCode,
          'timed_out': result.timedOut,
          'command': command,
        },
      );
    });
  }
}

class RunCodeTool extends _CodeTool {
  const RunCodeTool({required super.runner});

  /// 工具名。见 [RunCommandTool.toolName]。
  static const String toolName = 'run_code';

  @override
  String get name => toolName;

  @override
  String get description {
    // 平台不一样，开头这几句就得不一样。写死桌面那一版的话，手机上模型会
    // 按"我能读文件、能打中文"的预期写代码，然后拿到一堆它理解不了的失败。
    final environment =
        runner.scriptEnvironmentNote ??
        '源码会被存成一个临时文件再交给解释器执行，输出按 UTF-8 收，'
            '所以脚本里打中文是正常的、不会乱码。';

    return '**写一段代码然后跑起来**——这是写代码的主要方式，比 run_command 可靠。'
        '$environment'
        '用法上有几条要紧的：'
        '① **报错是正常的**。代码崩了会拿到一段错误输出，那是"你写的这段'
        '  有 bug"，不是工具坏了——照着错误改，再跑一次，这个循环就是正常的干活方式；'
        '② 一次只写一段能自己验证的代码，拿到输出再继续；'
        '③ 结果别全靠打印出来看，能自己断言的就断言；'
        '④ 代码里做危险动作（删文件、起别的进程、执行动态代码）会先弹窗问用户，'
        '  被拒绝就换个做法，别重试；'
        '⑤ 有超时，别写死循环或者要跑很久的。';
  }

  @override
  Map<String, Object?> get inputSchema {
    final ids = _languageIds();
    return {
      'type': 'object',
      'properties': {
        'language': {
          'type': 'string',
          // ⚠️ **按实际探测结果生成，不能写死一份全语言清单。**
          // 写死的话，安卓上模型会看到 `python`，试一次失败、再试一次，
          // 把回合全烧在这上面——正是 `tool_registry.dart` 说的
          // "注册了再返回不支持，比不注册更坏"。
          //
          // 一个都探不到时**不给 enum**，而不是编一个 `['javascript']` 出来：
          // 编出来的话 schema 就在撒谎，而且撒谎的方向是"去试一个跑不了的语言"。
          if (ids.isNotEmpty) 'enum': ids,
          'description': ids.isEmpty
              ? '用哪种语言写'
              : '用哪种语言写。这台设备上能跑的是：${ids.join('、')}',
        },
        'source': {'type': 'string', 'description': '完整的脚本源码'},
        // 摸不到文件系统的平台上不给这一栏。留着的话它是个**永远不起作用的
        // 参数**，模型会认真填一个目录，然后以为自己约束了什么。
        if (runner.scriptHasFileSystem)
          'working_directory': {
            'type': 'string',
            'description': '在哪个目录下跑。不填就是用户的家目录',
          },
        'timeout_seconds': {
          'type': 'integer',
          'description': '最多跑多少秒，不填用默认值（一分钟）',
        },
      },
      'required': ['language', 'source'],
    };
  }

  List<String> _languageIds() =>
      runner.supportedLanguages.map((l) => l.id).toList();

  /// 脚本源码**按同一套规则扫一遍**。
  ///
  /// 为什么不能只看命令：`run_code` 这条路压根不经过 shell，模型完全可以写一段
  /// `shutil.rmtree(...)` 或者 `subprocess.run([...])` 把危险动作藏在脚本里。
  /// 只拦命令行的话，绕过它就是"换个工具调"这么简单。
  ///
  /// 代价是会**多问几次**：一段用到 `subprocess` 的正经脚本也会弹窗。
  /// 这个代价是认下的——弹窗上给的是原样源码，用户看一眼就知道该不该放行。
  @override
  String? approvalReason(Map<String, Object?> input) {
    final source = input['source'];
    if (source is! String || source.trim().isEmpty) return null;
    final verdict = judgeScript(source);
    return verdict.needsApproval ? verdict.reason : null;
  }

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) {
    // ⚠️ **语言检查要放在 `withRunner` 里面。**
    //
    // 放外面的话，顺序就反了：一台既没探到解释器、又没有这门语言可用的设备上，
    // 模型收到的是"这台设备上跑不了 Python。能跑的是：。"——而真正的原因是
    // "这台电脑上没找到 Python 或 Node.js"，`unavailableReason` 里那句更有用的
    // 话（去哪儿装）根本没机会说出口。先说"整件事为什么做不了"，
    // 再说"具体这一步哪里不对"。
    return withRunner(needsCommand: false, (runner) async {
      final language = _resolveLanguage(input);
      final result = await runner.run(
        CodeRequest(
          language: language,
          source: _requireRawSource(input),
          workingDirectory: N1Tool.optionalString(input, 'working_directory'),
          timeout: _CodeTool.parseTimeout(input),
        ),
      );
      return ToolResult.ok(
        result.toModelText(),
        meta: {
          'exit_code': result.exitCode,
          'timed_out': result.timedOut,
          'language': language.id,
        },
      );
    });
  }

  /// 认一下语言名。两种错法给的话不一样：
  ///
  ///   - 名字压根不是我们支持的（写成了 `ruby`）→ 参数错，注册表会翻成"参数错误"；
  ///   - 名字对但这台设备上没装 → 一次正常的失败，模型该换个语言接着干。
  CodeLanguage _resolveLanguage(Map<String, Object?> input) {
    final raw = N1Tool.requireString(input, 'language');
    final language = CodeLanguage.fromId(raw);
    if (language == null) {
      throw ToolInputException('没有 "$raw" 这门语言。${_availableHint()}');
    }
    if (!runner.supportedLanguages.contains(language)) {
      throw CodeException('这台设备上跑不了 ${language.label}。${_availableHint()}');
    }
    return language;
  }

  /// 现在能跑什么。**一个都没有时不要拼出"能跑的是：。"这种半句话**——
  /// 那读起来像是"有什么东西是空的"，而不是"一个都没有"。
  String _availableHint() {
    final labels = runner.supportedLanguages.map((l) => l.label).toList();
    if (labels.isEmpty) return '这台设备上一个能跑的语言都没有。';
    return '这台设备上能跑的是：${labels.join('、')}。';
  }

  /// 源码要原样，**不 trim**。
  ///
  /// 跟文件工具里那条一个道理：Python 靠缩进吃饭，开头那一行进来的缩进被
  /// trim 掉，整个脚本就废了，而且报的是 `IndentationError`——模型会去查
  /// 自己的逻辑，完全想不到是工具动了它的字符串。
  static String _requireRawSource(Map<String, Object?> input) {
    final v = input['source'];
    if (v is! String) {
      throw const ToolInputException('缺少必填参数 `source`（要字符串）');
    }
    return v;
  }
}

/// 造执行类工具。
///
/// 两个工具**分别**判断该不该注册，理由见 `_CodeTool` 的类注释。
/// 都不可用就返回空表——模型看不见就不会反复试。
List<N1Tool> codeTools({required CodeRunner runner}) {
  final tools = <N1Tool>[];
  if (runner.supportsCommand) tools.add(RunCommandTool(runner: runner));
  if (runner.isAvailable) tools.add(RunCodeTool(runner: runner));
  return tools;
}
