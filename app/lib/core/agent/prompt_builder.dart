import '../memory/memory_store.dart';
import '../skills/skill_registry.dart';

/// 组装 system prompt。
///
/// **顺序是设计过的，别随手改**：不少家都有提示缓存，缓存按前缀命中。
/// 所以把最稳定的放最前、最容易变的放最后：
///
///   人设 → 工具说明 → 技能索引 → 记忆索引
///
/// ⚠️ **这里一个字都不许带"现在几点"。** 时间曾经写在这段的末尾，
/// 于是 system prompt 每分钟变一次——而 system prompt 是整段历史的**前缀**，
/// 它一变，后面所有对话的缓存全部作废，每一轮都在按原价重算整段历史。
/// 现在时间由 `AgentLoop` 拼进**最后一条用户消息**：它在末尾，
/// 变了也只影响它自己，前面的历史照旧命中缓存。
class PromptBuilder {
  PromptBuilder({
    required this.persona,
    required this.skills,
    required this.memory,
    this.memoryIndexLimit = 20,
  });

  /// 人设正文。来自 `assets/persona/default.md`，用户可以改。
  final String persona;

  final SkillRegistry skills;
  final MemoryStore memory;
  final int memoryIndexLimit;

  /// [toolNames] 是**这一轮实际在手的**工具名。
  ///
  /// 由调用方（`AgentLoop`）现取现传，不像人设那样在建的时候就定下来：
  /// 工具表是**会变的**——解释器预热完成之前 `run_code` 还没注册进来，
  /// 用户关掉总开关又把它们摘掉。拿一份建会话那一刻的快照，会出现
  /// "prompt 里写着你能改文件，实际表里没有"这种自相矛盾。
  Future<String> build({Iterable<String> toolNames = const []}) async {
    final buffer = StringBuffer();

    buffer
      ..writeln(persona.trim())
      ..writeln()
      ..writeln('---')
      ..writeln();

    _writeToolGuidance(buffer, toolNames);
    _writeSkills(buffer);
    await _writeMemory(buffer);

    return buffer.toString().trimRight();
  }

  void _writeToolGuidance(StringBuffer buffer, Iterable<String> toolNames) {
    buffer
      ..writeln('# 关于工具')
      ..writeln()
      ..writeln('你能调用工具。几个要点：')
      ..writeln()
      ..writeln('- 需要外部信息、需要在网页上操作、需要记住事情的时候，直接调工具，别跟用户说"我做不到"。')
      ..writeln('- 工具返回失败就换条路，或者如实告诉用户卡在哪。别反复重试同一个调用。')
      ..writeln('- 涉及付款、提交表单、删除数据、输入真实身份信息的操作，一律先问用户。')
      // 这句原来写的是"不要跟用户汇报你在调用工具"，和人设「做事时说清楚你在
      // 干什么」正面冲突，模型会犹豫要不要吭声。本意其实是**别报工具名和参数**
      // ——那才是机器人腔。用人的话说你在干嘛，是另一回事，而且是该说的。
      ..writeln('- **别跟用户报工具名和参数**（"我正在调用 browser_open"这种）。'
          '但要说人话讲你在干什么——"我去开下那个页面"，别闷头搞。')
      ..writeln();

    _writeCodeGuidance(buffer, toolNames);
  }

  /// 代码/文件这一路的额外交代。
  ///
  /// 为什么不靠技能文档就够了：技能是**要模型自己想起来去读**的
  /// （`skill_read`）。而"写代码跑代码"这件事，模型得先知道**这条路存在**
  /// 才会去读手册——它默认的自我认知是"我只能输出文字"。
  ///
  /// 这段只在这种工具**真的在手上**时才写：没注册的时候（用户关了总开关、
  /// 手机上没文件工具）写"你能改文件"就是让模型吹牛。
  void _writeCodeGuidance(StringBuffer buffer, Iterable<String> toolNames) {
    final names = toolNames.toSet();
    final canRun = names.contains('run_code') || names.contains('run_command');
    final canTouchFiles = names.contains('write_file') || names.contains('read_file');
    if (!canRun && !canTouchFiles) return;

    buffer
      ..writeln('# 关于写代码和动文件')
      ..writeln()
      ..writeln('**你是能真跑的，不是只能把代码打出来给用户看。**');

    if (canRun) {
      buffer
        ..writeln()
        ..writeln('- 要算个数、处理一批文件、做个转换，**直接写出来跑**，'
            '别在脑子里算完把结果告诉用户——那既可能算错，用户也没法复用。')
        ..writeln('- 跑完看退出码和 stderr，别看打印出来像对的就当成成了。');
    }
    if (canTouchFiles) {
      buffer
        ..writeln()
        ..writeln('- 改用户已有的文件用 `edit_file`，**不要用 `write_file` 整个覆盖**'
            '——那样他原来写的东西就没了。');
      buffer.writeln('- 路径给绝对路径。用户说"桌面"就用「桌面」这个词。');
    }

    if (canRun || canTouchFiles) {
      buffer
        ..writeln()
        ..writeln('- **危险操作会弹窗让用户确认**（删东西、改系统设置、装东西）。'
            '他点了「不要」就是不同意，**别换个写法再试一遍**。')
        ..writeln('- 系统目录只让读不让写，需要管理员权限的命令一律失败，也不要绕。')
        ..writeln('- 这类活有个手册：`coding`。真要做一件多步的事，'
            '先 `skill_read("coding")` 把流程读出来再动手。')
        ..writeln();
    }
  }

  Future<void> _writeMemory(StringBuffer buffer) async {
    final entries = await memory.index(limit: memoryIndexLimit);
    buffer
      ..writeln('# 你记得的事')
      ..writeln();

    if (entries.isEmpty) {
      buffer.writeln('（还没有。这是刚开始，慢慢会有的。）');
    } else {
      buffer.writeln('这些是你们之前聊到的，自然地在对话里用，别像念档案一样复述：');
      buffer.writeln();
      for (final e in entries) {
        buffer.writeln(e.toIndexLine());
      }
      buffer
        ..writeln()
        ..writeln('这里只有摘要。想起更多细节用 `memory_search`。'
            '发现新的、值得长期记住的事，用 `memory_save` 记下来。');
    }
    buffer.writeln();
  }

  void _writeSkills(StringBuffer buffer) {
    buffer
      ..writeln('# 你可以用的技能')
      ..writeln()
      ..writeln(skills.toIndexPrompt())
      ..writeln()
      ..writeln('技能是干活的流程手册。决定用某个技能时，'
          '先 `skill_read` 把它的完整内容读出来，再照着做——不要凭名字猜流程。')
      ..writeln()
      // 全篇原来一处示范都没有，只有"应该这么做"的说明。而"模型不主动用
      // 工具"最直接的解法就是给一个具体的样子——说明是规则，示范是路径。
      ..writeln('比如用户说"帮我查查 XX 手机到底怎么样"。看一眼上面的索引，'
          '`web-research` 那条对得上，就先 `skill_read("web-research")` '
          '把流程读出来再动手，而不是凭印象直接开始搜。')
      ..writeln();
  }

}
