// 端到端冒烟：打真接口，验证「提问 → 调工具 → 回填 → 再回答」整条链路。
//
// 单元测试用的是假模型，证明不了协议层真能跑通。这个脚本才是。
//
// 跑法（在 app/ 目录下）：
//   N1_API_KEY=sk-xxxx dart run tool/smoke.dart
// 或者把 key 写在一行文件里：
//   dart run tool/smoke.dart C:/path/to/key.txt
//
// 换别家冒烟（可选，不给就用预置清单里默认那家）：
//   N1_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1 \
//   N1_MODEL=qwen-flash \
//   N1_API_KEY=sk-xxxx dart run tool/smoke.dart
import 'dart:io';

import 'package:niuwa_ai/core/n1_core.dart';

Future<void> main(List<String> args) async {
  final apiKey = _loadKey(args);
  if (apiKey == null) {
    stderr.writeln('没有 API Key。设 N1_API_KEY 环境变量，或者把 key 文件路径作为第一个参数。');
    exit(2);
  }

  final skills = _loadSkillsFromDisk();
  final memory = _InMemoryLog();
  final tools = ToolRegistry()
    ..register(GetTimeTool())
    ..register(const HttpFetchTool())
    ..register(const MemorySaveTool())
    ..register(const MemorySearchTool())
    ..register(const SkillListTool())
    ..register(const SkillReadTool());

  final ctx = ToolContext(
    memory: memory,
    skills: skills,
    browser: const UnavailableBrowserDriver('冒烟脚本不测浏览器'),
    // 冒烟脚本不测提醒，给个内存的占位就够——本来也不会真的落盘。
    reminders: InMemoryReminderStore(),
    logger: (m) => stdout.writeln('  [log] $m'),
  );

  // 不写死哪一家。不设环境变量就用预置清单里默认那家，
  // 这样"换一家能不能跑通"不用改代码，改环境变量就行。
  final fallback = providerById(kDefaultProviderId)!;
  final llm = OpenAiCompatClient(
    apiKey: apiKey,
    baseUrl: Platform.environment['N1_BASE_URL'] ?? fallback.baseUrl,
    model: Platform.environment['N1_MODEL'] ?? fallback.defaultModel,
  );
  final loop = AgentLoop(
    llm: llm,
    tools: tools,
    context: ctx,
    promptBuilder: PromptBuilder(
      persona: _readFile('assets/persona/default.md') ?? '你是 N1。',
      skills: skills,
      memory: memory,
    ),
  );

  stdout
    ..writeln('接口：${llm.baseUrl}')
    ..writeln('模型：${llm.model}')
    ..writeln('技能：${skills.all.map((s) => s.name).join('、')}')
    ..writeln('工具：${tools.specs.map((t) => t.name).join('、')}')
    ..writeln();

  final history = <ChatMessage>[];

  // 这三轮分别覆盖：纯文本 / 触发工具 / 让模型记东西
  for (final prompt in const [
    '你好，简单介绍一下你自己，一句话就行。',
    '现在几点了？',
    '记住一下：我不吃香菜。',
  ]) {
    stdout
      ..writeln('──────────────────────────────────────')
      ..writeln('用户：$prompt')
      ..writeln();

    final input = ChatMessage.user(prompt);
    var reasoningShown = false;
    final produced = <ChatMessage>[];

    await for (final event in loop.run(history: history, input: input)) {
      switch (event) {
        case TurnStarted(:final turn, :final isContinuation):
          if (isContinuation) stdout.writeln('  ↻ 第 ${turn + 1} 轮（工具结果回填后）');
        case ReasoningDelta(:final text):
          if (!reasoningShown) {
            stdout.write('  [思考] ');
            reasoningShown = true;
          }
          stdout.write(text);
        case ContextTrimmed(:final droppedMessages, :final approxTokens):
          stdout.writeln(
            '  ✂ 上下文超预算，丢了 $droppedMessages 条老消息（剩约 $approxTokens token）',
          );
        case TextDelta(:final text):
          stdout.write(text);
        case ToolCallStarted(:final call):
          stdout.writeln('\n  [调用] ${call.name}(${call.arguments})');
        case ToolCallFinished(:final invocation):
          final r = invocation.result;
          stdout.writeln(
            '  [结果] ${r.ok ? "成功" : "失败"} '
            '${r.content.replaceAll('\n', ' ').trim()} '
            '(${invocation.duration.inMilliseconds}ms)',
          );
        case UsageReported(:final usage):
          stdout.writeln(
            '  [用量] 输入 ${usage.promptTokens}'
            '${usage.cachedTokens > 0 ? "（缓存命中 ${usage.cachedTokens}）" : ""}'
            ' / 输出 ${usage.completionTokens}',
          );
        case TurnComplete():
          stdout.writeln();
        case RunComplete(produced: final p, :final stopReason):
          stdout.writeln('  [结束] stopReason=$stopReason');
          produced.addAll(p);
        case AgentFailed(:final message):
          stdout.writeln('  [失败] $message');
          exit(1);
      }
    }

    stdout.writeln();
    history
      ..clear()
      ..addAll(produced);
  }

  stdout
    ..writeln('──────────────────────────────────────')
    ..writeln('记忆里现在有 ${await memory.count()} 条：');
  for (final e in await memory.index()) {
    stdout.writeln('  ${e.toIndexLine()}');
  }
  stdout.writeln('\n冒烟通过。');
  ctx.dispose();
}

String? _loadKey(List<String> args) {
  final fromEnv = Platform.environment['N1_API_KEY'];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) return fromEnv.trim();

  if (args.isNotEmpty) {
    final file = File(args.first);
    if (file.existsSync()) {
      final key = file.readAsStringSync().replaceAll(RegExp(r'\s'), '');
      if (key.isNotEmpty) return key;
    }
  }
  return null;
}

String? _readFile(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : null;
}

/// 直接从磁盘读技能，不走 Flutter 的 asset 机制——这个脚本是纯 Dart。
SkillRegistry _loadSkillsFromDisk() {
  final dir = Directory('assets/skills');
  if (!dir.existsSync()) {
    stderr.writeln('警告：找不到 assets/skills，技能会是空的');
    return SkillRegistry();
  }

  final sources = <String, String>{};
  for (final entry in dir.listSync()) {
    if (entry is! Directory) continue;
    final file = File('${entry.path}/SKILL.md');
    if (file.existsSync()) sources[file.path] = file.readAsStringSync();
  }

  final result = SkillRegistry.fromMarkdown(sources);
  for (final bad in result.failures) {
    stderr.writeln('警告：技能解析失败，已跳过 —— $bad');
  }
  return result.registry;
}

/// 把内存实现包一层，顺便打印写入，方便肉眼确认记忆真的存进去了。
class _InMemoryLog extends MemoryStore {
  final InMemoryMemoryStore _inner = InMemoryMemoryStore();

  @override
  Future<int> count() => _inner.count();

  @override
  Future<List<MemoryEntry>> all() => _inner.all();

  @override
  Future<void> save(MemoryEntry entry) async {
    stdout.writeln('  [记忆] 写入：${entry.toIndexLine()}');
    await _inner.save(entry);
  }

  @override
  Future<void> delete(String id) => _inner.delete(id);
}
