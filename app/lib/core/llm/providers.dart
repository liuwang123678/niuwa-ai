/// 这个 App 能接哪些模型服务。
///
/// **不绑定任何一家**。国内主流这几家现在都提供 OpenAI 兼容的
/// `POST {base_url}/chat/completions`——流式、工具调用、多模态走的是同一套
/// 字段，所以一个 [OpenAiCompatClient] 加一张「地址 + 模型名」的表就够了，
/// 不需要每家写一个客户端。
///
/// ## 表里是预置值，不是唯一值
///
/// 模型名各家改得很勤，一年退役一两个是常态（旧名字用下去会直接返回
/// 「模型不存在」，报错却长得像网络故障）。所以：
///
/// - 界面上的**模型名必须是能改的输入框**，不能做成锁死的下拉
/// - 地址同理，用户从官网复制什么就填什么
/// - 下表里的默认值只求「选完能开箱试一下」，不求永远正确
/// - 设置页里有个「拉取这个平台现在有哪些模型」，见 [modelsUrl]
///
/// 加新供应商就在这里加一条；如果它兼容 OpenAI，别的代码一个字都不用动。
///
/// ## 🩸 2026-10-10 校正过一次
///
/// 起因：用户说「其他厂家的模型用不了，比如 Kimi」。
///
/// 根因**不是客户端接错了**，是这张表里的名字从来没跟各家线上对过——Kimi 那条
/// 写的 `kimi-k2.5` 已经于 2026-08-31 退役，请求直接回 404「模型不存在」，
/// 而用户看到的就是「这家用不了」。
///
/// 这次改动的原则：**只动已经死掉或者被官方明确归到「旧版」的，验过还活着的
/// 一律不动**。换掉一个能用的名字是净损失——多一次改动就多一次改错的机会。
///
/// 下面每条的注释里写了现状和证据，下次再校正时照这个格式记。
library;

class LlmProvider {
  const LlmProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.defaultModel,
    this.keyUrl,
  });

  /// 稳定标识。**存进设置里的是这个**，不是 [name]——
  /// 显示名以后想改就改，改不动老用户已经存下的选择。
  final String id;

  /// 界面上显示的名字。
  final String name;

  /// 接口地址（不含 `/chat/completions`，那一段由 [chatCompletionsUrl] 补）。
  /// 自定义供应商这里是空串，等用户填。
  final String baseUrl;

  /// 这个供应商的默认模型名。自定义供应商这里是空串。
  final String defaultModel;

  /// 去哪申请 Key。为空表示这个供应商不需要 Key（比如本机跑的）。
  final String? keyUrl;

  bool get isCustom => id == kCustomProviderId;
}

/// 「自己填」那条。选它会露出地址和模型名两个输入框。
const String kCustomProviderId = 'custom';

/// 没配过的时候默认选哪家。
///
/// 这只是找个能开箱试一下的起点，不代表 App 只支持它——设置页里随时能换。
const String kDefaultProviderId = 'deepseek';

/// 预置清单。顺序就是下拉里的顺序。
const List<LlmProvider> kLlmProviders = <LlmProvider>[
  LlmProvider(
    id: kDefaultProviderId,
    name: '深度求索',
    baseUrl: 'https://api.deepseek.com',
    defaultModel: 'deepseek-flash',
    keyUrl: 'https://platform.deepseek.com/api_keys',
  ),
  LlmProvider(
    id: 'dashscope',
    name: '通义千问',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    // 2026-10-10：`qwen-flash` 改掉。它还活着，但阿里官方已经把它列进
    // 「旧版Qwen」那一节，当前同档位是 `qwen3.8-flash`（官方自述「效果接近
    // 旗舰模型」）。想要更强就 `qwen3.7-plus`。
    defaultModel: 'qwen3.8-flash',
    keyUrl: 'https://bailian.console.aliyun.com',
  ),
  LlmProvider(
    id: 'zhipu',
    name: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    // 2026-10-10：**没动**。`glm-4.7` 在智谱自家平台上还活着，有独立文档页、
    // 定价页也还在给它标价。当前旗舰是 `glm-5.3`，快而便宜的是
    // `glm-5.3-flash`（原生多模态），免费档有 `glm-4.7-flash`。
    // ⚠️ 别把阿里云百炼托管版的结论搬过来——那边 `glm-4.6/4.7` 是 2026-10-10
    // 下架，跟智谱自家平台是两码事。
    defaultModel: 'glm-4.7',
    keyUrl: 'https://open.bigmodel.cn',
  ),
  LlmProvider(
    id: 'moonshot',
    name: '月之暗面 Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    // 2026-10-10：`kimi-k2.5` → `kimi-k3`。**这条是用户报的那只虫**：
    // k2.5 已于 2026-08-31 退役，用下去回 404「模型不存在」，
    // 症状看着像"这家用不了"。当前还有 `kimi-k2.7-code`（写代码）
    // 和 `kimi-k2.6`。
    defaultModel: 'kimi-k3',
    keyUrl: 'https://platform.moonshot.cn/console/api-keys',
  ),
  LlmProvider(
    id: 'siliconflow',
    name: '硅基流动',
    baseUrl: 'https://api.siliconflow.cn/v1',
    // 2026-10-10：**没动**。`Qwen/Qwen3-8B` 还在架、还免费（定价页里
    // status=normal、输入输出都标 0、没有排期下线）。
    // 这家的模型名是「厂商/模型」格式；同价位还有 `zai-org/GLM-5.3-Flash`
    // （1M 上下文、支持视觉，也标 ¥0）。拿不准就在设置页拉一次模型列表。
    defaultModel: 'Qwen/Qwen3-8B',
    keyUrl: 'https://cloud.siliconflow.cn/account/ak',
  ),
  LlmProvider(
    id: 'openai',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    // 2026-10-10：**没动**。`gpt-4o-mini` 没有被弃用（官方 SDK 的模型全集里
    // 在，两份下线清单里都没有它——只有它的 audio/search 变体在）。
    // 当前一代的小模型是 `gpt-5.4-mini` / `gpt-5.4-nano`。
    // ⚠️ **`gpt-5.1-mini` 不是有效 ID**，SDK 的注释里明写"仅为兼容保留，
    // 不受支持的模型名"——别往这个坑里跳。
    // ⚠️ 这一家的当前定价**没核实过**（定价页在本机被墙），所以这里不写
    // "更便宜"这种话。
    defaultModel: 'gpt-4o-mini',
    keyUrl: 'https://platform.openai.com/api-keys',
  ),
  LlmProvider(
    id: 'ollama',
    name: '本机 Ollama',
    // 本机跑的，不走外网、也不需要 Key。前提是自己 `ollama pull` 过
    // 同名模型（名字是用户自己起的，所以这里只是个常见值）。
    baseUrl: 'http://localhost:11434/v1',
    defaultModel: 'qwen3:8b',
  ),
  LlmProvider(
    id: kCustomProviderId,
    name: '自定义',
    baseUrl: '',
    defaultModel: '',
  ),
];

/// 按 id 找供应商。找不到返回 null（比如设置里存着一个已经被删掉的 id）。
LlmProvider? providerById(String id) {
  for (final p in kLlmProviders) {
    if (p.id == id) return p;
  }
  return null;
}

/// 把用户填的接口地址变成真正要 POST 的 URL。
///
/// 同一个输入框里会出现三种填法，三种都得认：
///
///     https://api.deepseek.com                    // 官网文档给的 base
///     https://api.deepseek.com/                   // 从浏览器地址栏复制的，多个斜杠
///     https://api.deepseek.com/chat/completions   // 有人把整个接口地址粘进来
///
/// 前两种补齐，第三种原样用。
///
/// **不去猜 `/v1`**：那一段各家长得不一样（有的要有的不要），猜错了会拿到
/// 一个 404，而那看起来特别像「网断了」，能把人带偏很久。
String chatCompletionsUrl(String baseUrl) {
  final t = baseUrl.trim();
  if (t.isEmpty) return '';

  final noTrailing = t.replaceAll(RegExp(r'/+$'), '');
  if (noTrailing.endsWith('/chat/completions')) return noTrailing;
  return '$noTrailing/chat/completions';
}

/// 「这个平台现在有哪些模型」的地址：`{base}/models`。
///
/// ## 为什么加这个
///
/// 预置表里的模型名**一定会烂**（见文件头那段）。烂掉之后的症状是 404
/// 「模型不存在」，而它看起来特别像网络故障或者 Key 不对，用户会去查错方向。
/// 与其一年手工校一次，不如让用户当场拉一份当前列表出来挑。
///
/// ## 依据
///
/// 2026-10-10 实测：**本机能连上的五家全部有这条路由**——不带 Key 请求
/// `{base}/models` 一律返回 401，而不是 404。探到的五家是 deepseek、
/// dashscope（compatible-mode）、智谱、moonshot、硅基流动。openai 那家本机
/// 连不上（网络被墙，返回 000），ollama 那家是没在跑。
///
/// ⚠️ 「路由在」只说明这条路走得通，**不保证带上 Key 之后回的列表对你可用**
/// （各家筛不筛、排不排序都不一样）。所以界面上的用法必须是「拉出来给你挑，
/// 挑完还能自己改」，**不能**做成"只有列表里有的才能用"——那等于把一份
/// 我们没验证过的名单当成真理，比让人手填更糟。
///
/// 地址粘的是整个 `/chat/completions` 也认（有人会把整条接口地址粘进来）。
String modelsUrl(String baseUrl) {
  final t = baseUrl.trim();
  if (t.isEmpty) return '';

  var base = t.replaceAll(RegExp(r'/+$'), '');
  const suffix = '/chat/completions';
  if (base.endsWith(suffix)) {
    base = base.substring(0, base.length - suffix.length);
  }
  return '$base/models';
}
