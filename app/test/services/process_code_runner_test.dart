import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/code/process_code_runner.dart';
import 'package:path/path.dart' as p;

/// 真的起进程来跑。
///
/// **不用假 Process。** 这一层的验证点全是"外面看不见的行为"——超时之后那个
/// python 到底死没死、输出超过上限时管子有没有堵住、中文是不是真乱码。
/// 假 Process 会把这三件事一起变成"调用了我指定的那几个方法"，绿得毫无意义。
///
/// 代价是慢（几十毫秒一条）和依赖本机装了什么，都可以接受：
/// 项目里 `file_policy_test.dart` 同样真碰 `C:\Program Files`。
///
/// 下面几条结论是**实测出来的**，不是照抄别人的经验：
///   - `Process.start('echo hello', [], runInShell: true)` 能跑通；
///     **不带 runInShell 直接 `ProcessException: 系统找不到指定的文件`**。
///   - 本机的 `python` 跑一个脚本时会**再起一个子进程**，`taskkill` 的输出里
///     明写"已终止 PID xxxx (属于 PID yyyy 子进程)"——只杀父进程必然留孤儿。
///   - 🩸 **`runInShell: true` 那条路，只要命令里带引号就是坏的。** Dart 在那一层
///     按 MSVCRT 规则把 `"` 转成反斜杠加引号，而 cmd.exe **不认**反斜杠转义，
///     于是反斜杠原样进了子进程：`echo "a b"` 回来是反斜杠加引号，
///     `python "C:\有 空格\a.py"` 直接报 can't open file。而"路径带空格"恰恰
///     是最需要引号的场合。自己拼 `cmd /c`、改用 `%COMSPEC%` 两条绕法实测
///     掉进同一个坑——转义发生在 Dart 那一层，绕不过去。
///     **修法**：把命令写成临时 `.cmd` 再 `cmd /c <文件>`，转义层整个消失。
///   - 那个临时 `.cmd` 必须是 `@echo off` + `chcp 65001` + 命令，存成 UTF-8。
///     纯 UTF-8 会把中文路径读成乱码；UTF-8 带 BOM 会让 `@echo off` 那行不被识别；
///     只有加上 `chcp 65001` 三个条件（中文路径、中文输出、带空格的引号路径）
///     才一起过。顺带 cmd **自己**的话也从 GBK 乱码变回可读的 UTF-8 了
///     ——所以「命令名不存在」那条现在断言的是**不乱码**。
///   - 上一版这里写着"`chcp 65001` 改不了这一路的编码，`PYTHONUTF8=1` 可以"。
///     那是在旧的 `runInShell` 路径上量的，换成 `.cmd` 之后不成立了；两条都留着
///     ——`PYTHONUTF8=1` 仍然管着**子进程**自己的编码（`run_code` 走那条路）。
void main() {
  late Directory tmp;
  late Directory scripts;
  late Directory home;

  /// 本机有没有 python。没有就跳过需要它的那几条。
  late bool hasPython;

  setUpAll(() async {
    try {
      final r = await Process.run('python', ['--version']).timeout(
        const Duration(seconds: 10),
      );
      hasPython = r.exitCode == 0;
    } catch (_) {
      hasPython = false;
    }
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1-code-runner');
    scripts = Directory(p.join(tmp.path, 'scripts'))..createSync();
    home = Directory(p.join(tmp.path, 'home'))..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 造一个"只认指定的那几个解释器"的假探针。
  InterpreterProbe probeFor(List<List<String>> accepted) =>
      (candidate, {required Duration timeout}) async =>
          accepted.any((a) => a.join(' ') == candidate.join(' '));

  /// [probe] 不传就用**真的那一个**（`python --version` 真跑一次）。
  ///
  /// 默认写死"什么都探不到"曾经让九条测试一起红，而且报的是
  /// "这台电脑上跑不了 Python"——**看着像环境问题，其实是假探针在说没有**。
  /// 要模拟"什么都没装"就显式传 `probeFor(const [])`。
  ProcessCodeRunner runner({
    InterpreterProbe? probe,
    Duration? defaultTimeout,
    Duration? maxTimeout,
    int? maxOutputBytes,
    ProcessStarter? startProcess,
    int? keepScriptFiles,
  }) => ProcessCodeRunner(
    homeDirectory: () async => home.path,
    tempDirectory: () async => scripts,
    probe: probe,
    startProcess: startProcess,
    defaultTimeout: defaultTimeout ?? const Duration(seconds: 60),
    maxTimeout: maxTimeout ?? const Duration(seconds: 300),
    maxOutputBytes: maxOutputBytes ?? 64 * 1024,
    keepScriptFiles: keepScriptFiles ?? 200,
    logger: (_) {},
  );

  group('探测本机有什么', () {
    test('探不到任何解释器就是不可用，而且说得清为什么', () async {
      final r = runner(probe: probeFor(const []));
      await r.warmUp();

      expect(r.isAvailable, isFalse);
      expect(r.supportedLanguages, isEmpty);
      expect(r.unavailableReason, contains('Python'));
      expect(r.unavailableReason, contains('Node'));
      // 命令行跟解释器是两码事：这台机器没装 Python 和 Node，
      // 照样跑得了 cmd / dir / ping。
      expect(r.supportsCommand, isTrue);
    });

    test('一个候选跑通了就认它，后面的不再试', () async {
      final tried = <String>[];
      final r = ProcessCodeRunner(
        homeDirectory: () async => home.path,
        tempDirectory: () async => scripts,
        probe: (candidate, {required Duration timeout}) async {
          tried.add(candidate.join(' '));
          return candidate.first == 'python';
        },
        logger: (_) {},
      );

      await r.warmUp();

      expect(r.supportedLanguages, contains(CodeLanguage.python));
      expect(r.supportedLanguages, isNot(contains(CodeLanguage.node)));
      // python 的第一个候选就中了，`py -3` / `python3` 不该再试。
      expect(tried, contains('python'));
      expect(tried, isNot(contains('python3')));
    });

    test('预热是幂等的——重复调用不会再探一遍', () async {
      var calls = 0;
      final r = ProcessCodeRunner(
        homeDirectory: () async => home.path,
        tempDirectory: () async => scripts,
        probe: (candidate, {required Duration timeout}) async {
          calls++;
          return true;
        },
        logger: (_) {},
      );

      await r.warmUp();
      final afterFirst = calls;
      await r.warmUp();

      expect(afterFirst, greaterThan(0));
      expect(calls, afterFirst);
    });

    test('用出厂那个探针真探一次：本机装了 python 就探得到', () async {
      if (!hasPython) return;
      // 不注入探针，走 [ProcessCodeRunner] 自己的默认实现——
      // 那条"真跑一次 --version，不看 where"的逻辑才是要验的东西。
      final r = runner();

      await r.warmUp();

      expect(r.supportedLanguages, contains(CodeLanguage.python));
      expect(r.isAvailable, isTrue);
      expect(r.unavailableReason, isNull);
    });
  });

  group('跑命令行', () {
    test('跑得起来，输出拿得到', () async {
      final r = runner();
      final result = await r.runCommand(
        const CommandRequest(command: 'echo hello'),
      );

      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'hello');
      expect(result.ok, isTrue);
      expect(result.timedOut, isFalse);
    });

    test('退出码原样带回来——被跑的代码报错不等于工具坏了', () async {
      final r = runner();
      final result = await r.runCommand(
        const CommandRequest(command: 'exit 3'),
      );

      expect(result.exitCode, 3);
      expect(result.ok, isFalse);
      expect(result.timedOut, isFalse);
    });

    test('空命令直接说不清楚，不去起进程', () async {
      final r = runner();
      await expectLater(
        r.runCommand(const CommandRequest(command: '   ')),
        throwsA(
          isA<CodeException>().having((e) => e.message, 'message', contains('空')),
        ),
      );
    });

    test('命令名不存在：cmd 自己会说不认得它，而且这句话现在读得懂', () async {
      // 走的是 shell（`cmd /c ...`），shell 一定起得来，所以"命令不存在"
      // 是 shell 报的错，不是我们起进程失败。这个区别对模型有用：
      // 它能从 stderr 里读到"不是内部或外部命令"，知道是名字打错了。
      //
      // ⚠️ **这条以前钉的是乱码**。cmd 按控制台代码页（本机 GBK）往管道里写，
      // 这边按 UTF-8 解，回来是一串 U+FFFD。现在命令跑在临时 `.cmd` 里、
      // 开头一句 `chcp 65001`，cmd 自己写的也是 UTF-8 了——**读得懂**。
      // 模型能照着重打命令名，而不是对着一屏 U+FFFD 猜。见 `runCommand`。
      final r = runner();
      final result = await r.runCommand(
        const CommandRequest(command: 'n1-这个命令根本不存在-xyz'),
      );

      expect(result.exitCode, isNot(0));
      expect(result.ok, isFalse);
      expect(result.timedOut, isFalse);
      expect(result.stderr, isNotEmpty);
      expect(result.looksGarbled, isFalse);
      // 报错里会带上它不认识的那个名字——中文也完整回来了，
      // 顺便证明命令**发出去**的那一趟没有被打歪。
      expect(result.stderr, contains('n1-这个命令根本不存在-xyz'));
    });

    test('工作目录不存在就明说，不要默默跑到别处去', () async {
      final r = runner();
      await expectLater(
        r.runCommand(
          CommandRequest(
            command: 'echo hi',
            workingDirectory: p.join(tmp.path, '没有这个目录'),
          ),
        ),
        throwsA(
          isA<CodeException>().having(
            (e) => e.message,
            'message',
            contains('工作目录不存在'),
          ),
        ),
      );
    });

    test('工作目录会给子进程——脚本拿到的相对路径就落在那儿', () async {
      final r = runner();
      final result = await r.runCommand(
        CommandRequest(command: 'cd', workingDirectory: home.path),
      );

      expect(result.stdout.toLowerCase(), contains(home.path.toLowerCase()));
    });

    test('命令行里的中文，发出去和回来的都对了', () async {
      // 这一条原来钉的是"GBK 乱码，如实标注"这个**已知限制**——当时实测
      // `chcp 65001` 也救不回来。改成临时 `.cmd` + `chcp 65001` 之后就翻过来了：
      // 命令原文按 UTF-8 写进文件、cmd 按 UTF-8 读，它自己写的也按 UTF-8 回来。
      // 从"已知限制"变成"正常功能"。
      final r = runner();
      final result = await r.runCommand(
        const CommandRequest(command: 'echo 中文测试'),
      );

      expect(result.stdout.trim(), '中文测试');
      expect(result.looksGarbled, isFalse);
      expect(result.toModelText(), isNot(contains('乱码')));
    });
  });

  group('带引号的命令', () {
    // 这一组是**在 Windows 上真跑时撞出来的**，不是设计出来的。
    //
    // 整串命令原来直接塞给 `runInShell: true`。Dart 在那一层按 MSVCRT 规则把
    // `"` 转义成反斜杠加引号，而 **cmd.exe 不认反斜杠转义**——反斜杠原样传下去，
    // 引号也就带着反斜杠到了子进程手里。症状是**任何带引号的命令都坏**：
    //
    //   python "C:\Program Files\a.py"
    //     -> python: can't open file ...反斜杠引号 C:\Program Files\a.py 引号
    //
    // 而"路径里有空格"恰恰是最需要引号的场合。自己拼 `cmd /c`、改用
    // `%COMSPEC%` 两条绕法实测掉进同一个坑——转义发生在 Dart 那一层。
    // 修法：写成临时 `.cmd`，转义层整个消失。

    test('引号原样送到子进程手里，不会多出一个反斜杠', () async {
      // 这条是那个 bug 的正面。坏的时候 stdout 是反斜杠加引号。
      final r = runner();
      final result = await r.runCommand(
        const CommandRequest(command: 'echo "a b"'),
      );

      expect(result.stdout.trim(), '"a b"');
      expect(result.stdout, isNot(contains(r'\"')));
    });

    test('管道和 && 照旧——写进 .cmd 没有改掉 shell 语义', () async {
      final r = runner();
      final result = await r.runCommand(
        const CommandRequest(command: 'echo a && echo b | findstr b'),
      );

      final lines = result.stdout
          .trim()
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, ['a', 'b']);
    });

    test('%VAR% 还是 cmd 那套展开', () async {
      final r = runner();
      final result = await r.runCommand(
        CommandRequest(command: 'echo %CD%', workingDirectory: home.path),
      );

      expect(result.stdout.toLowerCase(), contains(home.path.toLowerCase()));
    });

    test('中文路径 + 引号：两个坑一起过', () async {
      if (!hasPython) return;
      // 带空格、还带中文的路径。少一个条件就测不到 chcp 那一行
      // ——纯 UTF-8 的 .cmd 在这台机器上会把中文读成乱码（实测过）。
      final dir = Directory(p.join(tmp.path, '重要 资料'))
        ..createSync(recursive: true);
      final script = File(p.join(dir.path, 'a.py'))
        ..writeAsStringSync('print(12345)');

      final r = runner();
      final result = await r.runCommand(
        CommandRequest(command: 'python "${script.path}"'),
      );

      expect(result.stderr, isEmpty, reason: '命令自己报错了：${result.stderr}');
      expect(result.stdout.trim(), '12345');
    });

    test('临时 .cmd 也会被清理，不会在磁盘上越攒越多', () async {
      final r = runner(keepScriptFiles: 3);
      for (var i = 0; i < 8; i++) {
        await r.runCommand(CommandRequest(command: 'echo $i'));
      }

      final left = scripts
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('n1_'))
          .length;
      expect(left, lessThanOrEqualTo(3));
    });
  });

  group('超时', () {
    test('超时就杀，而且立刻回来（不会等到命令自己结束）', () async {
      final r = runner();
      final sw = Stopwatch()..start();
      final result = await r.runCommand(
        const CommandRequest(
          command: 'ping -n 10 127.0.0.1',
          timeout: Duration(seconds: 1),
        ),
      );
      sw.stop();

      expect(result.timedOut, isTrue);
      expect(result.ok, isFalse);
      // ping -n 10 要跑约 9 秒。真杀了的话 5 秒内必定回来。
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('请求的超时被天花板夹住——模型写个 100000 也不能让命令挂半天', () async {
      final r = runner(maxTimeout: const Duration(seconds: 1));
      final sw = Stopwatch()..start();
      final result = await r.runCommand(
        const CommandRequest(
          command: 'ping -n 10 127.0.0.1',
          timeout: Duration(hours: 3),
        ),
      );
      sw.stop();

      expect(result.timedOut, isTrue);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('超时真的把进程树收干净了', () {
    test('一个睡 60 秒的脚本，超时之后它不在了', () async {
      if (!hasPython) return;
      // 记下我们起的那个 pid，然后按 pid 查——比"数 python 进程数"精确得多，
      // 也不会被这台机器上本来就有的 python 进程搅乱。
      final pids = <int>[];
      final r = runner(
        startProcess:
            (exe, args, {workingDirectory, environment, runInShell = false}) async {
              final proc = await Process.start(
                exe,
                args,
                workingDirectory: workingDirectory,
                environment: environment,
                runInShell: runInShell,
              );
              pids.add(proc.pid);
              return proc;
            },
      );
      await r.warmUp();

      final result = await r.run(
        const CodeRequest(
          language: CodeLanguage.python,
          source: 'import time\ntime.sleep(60)\n',
          timeout: Duration(seconds: 1),
        ),
      );

      expect(result.timedOut, isTrue);
      expect(pids, isNotEmpty, reason: '没记到 pid，下面查的是空气');

      // 给它一点时间退出（taskkill 是同步的，但系统回收 pid 有延迟）。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final pid in pids) {
        expect(
          await _pidAlive(pid),
          isFalse,
          reason: '超时之后 PID $pid 还活着——那就是每次留一个孤儿',
        );
      }
    });
  });

  group('跑脚本', () {
    test('写→跑→拿结果，而且脚本文件真的落在磁盘上', () async {
      if (!hasPython) return;
      final r = runner();
      await r.warmUp();

      const source = 'total = 0\n'
          'for i in range(1, 101):\n'
          '    total += i\n'
          'print(total)\n';
      final result = await r.run(
        const CodeRequest(language: CodeLanguage.python, source: source),
      );

      expect(result.exitCode, 0);
      expect(result.stdout.trim(), '5050');

      // 落成文件是有意的（躲开 -c 的转义地狱，也留个可核对的东西），
      // 那就得验它真落对了——不然"可核对"是句空话。
      final path = _scriptPathOf(result.note);
      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsStringSync(), source);
    });

    test('脚本里的中文输出是好的——PYTHONUTF8 实测有效', () async {
      if (!hasPython) return;
      final r = runner();
      await r.warmUp();

      final result = await r.run(
        const CodeRequest(
          language: CodeLanguage.python,
          source: 'print("中文输出测试")\n',
        ),
      );

      expect(result.stdout.trim(), '中文输出测试');
      expect(result.looksGarbled, isFalse);
    });

    test('脚本自己报错：如实带回来，不抛异常', () async {
      if (!hasPython) return;
      final r = runner();
      await r.warmUp();

      final result = await r.run(
        const CodeRequest(
          language: CodeLanguage.python,
          source: 'print(1/0)\n',
        ),
      );

      // 这是"写→跑→看报错→改→再跑"里的正常一轮。当成工具失败的话，
      // 模型收到的信号是"这个工具不работает"，而不是"我这段代码有 bug"。
      expect(result.exitCode, isNot(0));
      expect(result.stderr, isNotEmpty);
      expect(result.ok, isFalse);
      expect(result.toModelText(), contains('程序自己报错'));
    });

    test('语言没装就说没装，不硬跑', () async {
      final r = runner(probe: probeFor(const [['python']]));
      await r.warmUp();

      await expectLater(
        r.run(const CodeRequest(language: CodeLanguage.node, source: '1+1')),
        throwsA(
          isA<CodeException>().having(
            (e) => e.message,
            'message',
            contains('跑不了 Node.js'),
          ),
        ),
      );
    });

    test('空源码不跑', () async {
      final r = runner(probe: probeFor(const [['python']]));
      await r.warmUp();

      await expectLater(
        r.run(const CodeRequest(language: CodeLanguage.python, source: '\n  ')),
        throwsA(
          isA<CodeException>().having((e) => e.message, 'message', contains('空')),
        ),
      );
    });

    test('输出超上限：截断并**如实标明**，不是假装输出就这么点', () async {
      if (!hasPython) return;
      final r = runner(maxOutputBytes: 200);
      await r.warmUp();

      final result = await r.run(
        const CodeRequest(
          language: CodeLanguage.python,
          source: 'print("x" * 5000)\n',
        ),
      );

      expect(result.truncated, isTrue);
      expect(result.stdout.length, lessThanOrEqualTo(200));
      expect(result.toModelText(), contains('后面的丢掉了'));
      // 关键：超了上限也得把进程跑完，不能卡住。
      expect(result.exitCode, 0);
      expect(result.timedOut, isFalse);
    });

    test('输出特别多也不会把内存吃光，而且进程正常退出', () async {
      if (!hasPython) return;
      // 这条是给"管子满了子进程会阻塞"那个坑上保险：以前不排空的话，
      // 这个脚本会一直卡在 print 上，永远不退出，直到超时被杀。
      final r = runner(maxOutputBytes: 1024);
      await r.warmUp();

      final result = await r.run(
        const CodeRequest(
          language: CodeLanguage.python,
          source: 'for i in range(20000):\n    print(i)\n',
          timeout: Duration(seconds: 30),
        ),
      );

      expect(result.timedOut, isFalse);
      expect(result.exitCode, 0);
      expect(result.truncated, isTrue);
    });

    test('临时脚本攒多了会清理，而且只清自己写的那些', () async {
      final r = runner(probe: probeFor(const [['python']]), keepScriptFiles: 3);
      await r.warmUp();
      // 别人的文件不能动。
      final keepMe = File(p.join(scripts.path, '别人的.txt'))
        ..writeAsStringSync('x');

      for (var i = 0; i < 6; i++) {
        await r.run(
          CodeRequest(language: CodeLanguage.python, source: 'print($i)\n'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final mine = scripts
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('n1_'))
          .toList();
      expect(mine.length, lessThanOrEqualTo(3));
      expect(keepMe.existsSync(), isTrue);
    });
  });

  group('结果渲染成人话', () {
    test('正常：退出码 + 输出', () {
      const result = CodeResult(
        exitCode: 0,
        stdout: '5050',
        duration: Duration(milliseconds: 1500),
      );
      final text = result.toModelText();
      expect(text, contains('退出码：0'));
      expect(text, contains('1.5 秒'));
      expect(text, contains('5050'));
    });

    test('没输出也说一句，别让模型以为工具没返回', () {
      const result = CodeResult(exitCode: 0);
      expect(result.toModelText(), contains('什么都没输出'));
    });

    test('超时：说清楚是被杀掉的', () {
      const result = CodeResult(exitCode: -1, timedOut: true);
      final text = result.toModelText();
      expect(text, contains('超时'));
      expect(text, contains('杀掉'));
    });

    test('错误输出单独一节', () {
      const result = CodeResult(
        exitCode: 1,
        stdout: 'partial',
        stderr: 'Traceback',
      );
      final text = result.toModelText();
      expect(text, contains('错误输出：'));
      expect(text, contains('Traceback'));
    });
  });

  group('乱码启发式', () {
    test('正常中文不算乱码', () {
      expect(looksGarbledText('中文输出测试'), isFalse);
    });

    test('空串不算', () {
      expect(looksGarbledText(''), isFalse);
    });

    test('个别替换字符不算', () {
      // ⚠️ **这是比例判定，短串天然敏感**：43 个字里有一个坏字符就是 2.3%，
      // 直接过线。所以样例得用真实输出的量级（几十上百字），
      // 拿一行 15 个字去验只会验出"阈值太松"，验不出这段逻辑对不对。
      expect(
        looksGarbledText(
          '共处理 128 个文件，跳过 3 个，总耗时 1.2 秒。其中两个文件因为格式不'
          '受支持被跳过，剩下的都写进了目标目录，附带的清单里能看到每个文件的'
          '来源和处理结果，结尾处有一个字节没能解出来：\uFFFD',
        ),
        isFalse,
      );
    });

    test('刚好压线：100 个字里 3 个坏字符算乱码', () {
      expect(looksGarbledText('正' * 97 + '\uFFFD' * 3), isTrue);
    });

    test('刚好没压线：100 个字里 2 个坏字符不算', () {
      expect(looksGarbledText('正' * 98 + '\uFFFD' * 2), isFalse);
    });

    test('一片替换字符就算', () {
      expect(looksGarbledText('\uFFFD\uFFFD\uFFFD'), isTrue);
    });
  });
}

/// 从 [CodeResult.note] 里把脚本路径抠出来。
String _scriptPathOf(String? note) {
  final match = RegExp(r'`([^`]+)`').firstMatch(note ?? '');
  if (match == null) throw StateError('note 里没有脚本路径：$note');
  return match.group(1)!;
}

/// 这个 pid 现在还活着吗。按 pid 查，不受机器上别的同名进程影响。
Future<bool> _pidAlive(int pid) async {
  final result = await Process.run('tasklist', [
    '/FI',
    'PID eq $pid',
    '/NH',
  ]);
  final text = '${result.stdout}';
  if (text.contains('没有运行的任务') || text.contains('No tasks')) return false;
  return text.contains('$pid');
}
