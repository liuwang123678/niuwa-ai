/// 工作强度：一个旋钮管住「这一轮它肯花多少 token」。
///
/// ## 为什么要有这个
///
/// 用户的原话是「加个工作强度调节，控制 token 消耗的」。agent 这一路烧 token
/// 的地方不多，全在这儿列成数字：
///
///   - **[maxTurns]** 一轮对话里最多"想一步 + 调一次工具"几回。这是最狠的一项，
///     因为它**不是线性**的：每一回合都要把整段历史连前面所有工具结果再发一遍，
///     第 N 回合的输入约等于前 N-1 回合的总和。
///   - **[toolResultChars]** 单条工具结果回喂给模型的字数上限。工具结果一旦进了
///     上下文，后面每一轮都会跟着重发——一条 5 万字的文件内容，在 20 回合的会话里
///     就是 100 万字的输入。
///   - **[memoryIndexLimit]** 记忆索引条数。每次请求都在 system prompt 里，
///     按条数线性涨。
///   - **[historyMessages]** 带多少条历史。纯聊天时的大头。
///
/// ## 三档是怎么定的
///
/// **`standard` 必须等于加这个功能之前的行为，一项不差。** 这条是硬要求：
/// 升级完什么都不选的人，不该发现它变笨了或者变抠了。所以"标准"那一档里每一项
/// 都照着原来的值填（原来是"不限"的就还是"不限"），另外两档都在它两边挪。
///
/// ## 这一档管不到什么
///
/// **不拿"少给几个工具"来省 token。**工具声明确实每次请求都发一遍，但把它藏起来
/// 之后模型不会说"这档省着用所以我不开网页了"，它会说"我做不到"——省下来的那点
/// 声明长度，远不值一次假的"我做不到"。工具表只按**这台设备有没有这个能力**决定。
enum WorkLevel {
  /// 省着用。工具结果只回喂一小截、回合少、只带最近一段历史。
  ///
  /// 代价都写在 [summary] 里，设置页直接显示给用户看——他选了这一档，
  /// 就该知道"它可能看不见你半小时前说的话"。省 token 不能靠瞒着用户省。
  frugal(
    id: 'frugal',
    label: '省着用',
    summary: '工具结果只回喂前一段，回合数和记忆索引都收紧，'
        '只带最近一段历史。适合闲聊和简单问题。',
    maxTurns: 5,
    browserTurns: 12,
    codeTurns: 18,
    toolResultChars: 3000,
    memoryIndexLimit: 8,
    recallLimit: 3,
    historyMessages: 40,
  ),

  /// 标准。**就是加这个功能之前的行为。**
  standard(
    id: 'standard',
    label: '标准',
    summary: '工具结果原样回喂，回合数和记忆索引都是默认值，历史全带。'
        '平时用这个。',
    maxTurns: 8,
    browserTurns: 20,
    codeTurns: 30,
    // null = 不限。这里**不能**图省事编一个"看着挺大"的数：
    // `read_file` 默认就能返回 2000 行，随手截一下是真的会让它读不全文件，
    // 而"标准"这一档承诺的是和以前一模一样。
    toolResultChars: null,
    memoryIndexLimit: 20,
    recallLimit: 6,
    historyMessages: null,
  ),

  /// 放开干。回合数和记忆索引给得更宽，适合让它自己啃一个长任务。
  ///
  /// 它**不比标准省**，这是个纯往上的档——所以 [summary] 里不提省钱，
  /// 只说"宁可在中途多试几次也别停下"。写成"又省又能干"就是骗人。
  thorough(
    id: 'thorough',
    label: '放开干',
    summary: '回合数和记忆索引给得更宽，宁可在中途多试几次也不停下。'
        '跑长任务用这个，比标准费。',
    maxTurns: 16,
    browserTurns: 40,
    codeTurns: 60,
    toolResultChars: null,
    memoryIndexLimit: 40,
    recallLimit: 8,
    historyMessages: null,
  );

  const WorkLevel({
    required this.id,
    required this.label,
    required this.summary,
    required this.maxTurns,
    required this.browserTurns,
    required this.codeTurns,
    required this.toolResultChars,
    required this.memoryIndexLimit,
    required this.recallLimit,
    required this.historyMessages,
  });

  /// 存进设置里的是这个，不是 [label]——显示名以后想改就改，改不动老用户已存的选择。
  final String id;

  /// 界面上显示的名字。
  final String label;

  /// 一句话讲清这一档的代价。设置页直接显示。
  final String summary;

  /// 普通聊天最多几回合。
  final int maxTurns;

  /// 装上浏览器工具之后放宽到多少。
  ///
  /// 浏览器任务跟普通聊天不是一个量级：
  /// open → snapshot → click → snapshot → type → click → snapshot → screenshot
  /// 这一串正好吃满默认那 8 轮，然后**停在最需要它继续干的那一步**。
  final int browserTurns;

  /// 装上 `run_code` 之后放宽到多少。写→跑→看报错→改→再跑是常态。
  final int codeTurns;

  /// 单条工具结果回喂给模型的字数上限。**null = 不限**。
  final int? toolResultChars;

  /// system prompt 里带几条记忆索引。
  final int memoryIndexLimit;

  /// 每句话额外按话题捞几条相关记忆。
  ///
  /// 跟 [memoryIndexLimit] 是两回事：索引是"重要度最高的那几条，固定挂在
  /// system prompt 上"（更新一条记忆就不动，缓存友好）；这一份是**跟着用户
  /// 这句话现查的**，只有真聊到某个话题时才会出现。所以条数要小——它每一轮
  /// 都跟着最后一条用户消息重发，越多越贵，而且捞出来十条无关的只会打断它。
  final int recallLimit;

  /// 一次请求最多带多少条历史。**null = 不限**（全带）。
  final int? historyMessages;

  /// 从存下来的 id 认回来。认不出就用 [WorkLevel.standard]。
  ///
  /// 设置里可能存着一个已经删掉的档位名（比如以后合并了两档），
  /// 那时候退回标准，而不是让界面拿着一个查不到的东西去炸。
  static WorkLevel fromId(String? id) {
    for (final level in values) {
      if (level.id == id) return level;
    }
    return WorkLevel.standard;
  }
}
