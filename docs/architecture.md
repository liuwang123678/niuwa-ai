# N1 架构设计

配套 `CLAUDE.md`（协作规则 + 选型总表）。本文讲清楚每个模块的边界和职责。

---

## 0. 一句话

**一个纯 Dart 内核（`lib/core/`）负责"思考"，一层 Flutter 界面负责"好看"，两端各自提供平台能力（浏览器自动化）。**

```
┌───────────────────────────────────────────────┐
│  UI 层 (Flutter)   chat / memory / skills / 设置 │
└───────────────────┬───────────────────────────┘
                    │ AgentEvent stream
┌───────────────────▼───────────────────────────┐
│  内核 lib/core/  （禁 import flutter）          │
│                                                │
│   AgentLoop ──► LlmClient (OpenAI 兼容)        │
│      │                                         │
│      ├──► ToolRegistry ──► N1Tool 实现          │
│      ├──► MemoryStore  ──► SQLite              │
│      └──► SkillRegistry ──► skills/*/SKILL.md  │
└───────────────────┬───────────────────────────┘
                    │ 平台注入
        ┌───────────┴───────────┐
        │                       │
   CdpBrowserDriver       WebViewBrowserDriver
   (Windows, 连本机 Edge)  (Android, 隐藏 WebView)
```

内核只认接口，不认平台。平台能力通过构造时注入的 `BrowserDriver` 进来。

---

## 1. 数据模型

```dart
// core/models/

enum Role { system, user, assistant, tool }

class ChatMessage {
  final String id;
  final Role role;
  final String content;              // 文本内容
  final List<ImagePart>? images;     // 多模态（取决于所选模型是否支持视觉）
  final List<ToolCall>? toolCalls;   // assistant 发起
  final String? toolCallId;          // tool 结果回填
  final int createdAt;
}

class ToolCall {
  final String id;
  final String name;
  final Map<String, Object?> arguments;
}

class Conversation {
  final String id;
  final String title;
  final String personaId;
  final int createdAt, updatedAt;
}
```

---

## 2. LLM 层

`core/llm/llm_client.dart` —— 抽象接口：

```dart
abstract class LlmClient {
  Stream<LlmChunk> stream(List<ChatMessage> messages, {List<ToolSpec> tools, CancelToken? cancel});
}
```

`LlmChunk` 是 SSE 增量：`textDelta` / `toolCallDelta` / `usage` / `done`。

`core/llm/openai_compat_client.dart` —— 唯一实现，走 OpenAI 兼容的 `/chat/completions`：

| 项 | 值 |
|---|---|
| base url | 用户自选，也可填自定义地址 |
| 路径 | `/chat/completions` |
| 模型 | 用户自选，输入框填写（不锁死下拉，模型名会过期） |
| 鉴权 | `Authorization: Bearer <用户填的 key>` |
| 流式 | `stream: true`，SSE |

预置清单只提供默认值，不绑定任何一家；每家 Key 分开存。

### ✅ 协议实测结论（2026-09-25，打真接口验过）

三条全部通过，且捞到两个白送的好东西：

| 验的东西 | 结果 |
|---|---|
| `tools` / `tool_choice` | ✅ 支持。`finish_reason: "tool_calls"`，`message.tool_calls[]` 带 `id` / `function.name` / `function.arguments`（**JSON 字符串**，不是对象） |
| 流式 tool_call 格式 | ✅ OpenAI 兼容。`delta.tool_calls[{index, id?, type?, function:{name?, arguments}}]`。**首块带 `id`+`name`，后续块只有 `index`+`arguments` 的字符串碎片**，要按 index 累加拼接，拼完才 `jsonDecode` |
| `image_url` 多模态 | ✅ 支持 base64 data URL。给了张"左上红方块右下蓝方块"的测试图，回答准确（`data:image/png;base64,...`） |

**额外发现（不用白不用）**：

1. **`reasoning_content` 字段** —— 流式和非流式都有，是模型的思考过程，跟 `content` 分开推。这是给 UI 的礼物：可以像本机 U 盘那个 ollama chat.html 一样，把思考过程折叠展示。**N1 的"正在想…"体验直接用它，别再自己编占位动画。**
2. **提示缓存** —— 响应带 `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`。意味着 system prompt（人设+工具说明+技能索引+记忆索引）**要放在最前面且保持字节稳定**才能命中缓存，省钱又提速。所以记忆索引的排序必须**确定性**，不能每轮随机打乱。
   技能索引排在记忆索引**前面**：技能装上就不动，记忆每轮都在变。这行原来写反了（记忆在前），代码也是反的，两处一起改的，见 `prompt_builder.dart` 的文件头。

流式响应的收尾：最后一块 `delta: {content:"", reasoning_content:null}` + `finish_reason`，然后是 `data: [DONE]`。

**中文编码没问题**。第一轮探针里看到乱码是 Windows 控制台 GBK 的锅，不是接口的锅——写文件再按 UTF-8 读回来中文完整。

---

## 3. Agent 循环

`core/agent/agent_loop.dart`

```
run(userInput)
  ├─ 组装 messages: [system(人设 + 工具说明 + 技能索引 + 记忆索引 + 当前时间), ...历史, userInput]
  ├─ 循环 (最多 maxTurns 轮):
  │    ├─ llm.stream(messages, tools: registry.specs)
  │    ├─ 收流 → 发 TextDelta 事件给 UI
  │    ├─ 若本轮有 tool_calls:
  │    │     ├─ 对每个 call: 发 ToolCallStarted → tool.call() → 发 ToolCallFinished
  │    │     ├─ 结果作为 role=tool 消息塞回 messages
  │    │     └─ continue（回到循环顶部）
  │    └─ 否则 → 发 TurnComplete，结束
  └─ 落库：保存本轮所有消息
```

对外是 `Stream<AgentEvent>`，UI 边收边画。

```dart
sealed class AgentEvent {}
final class TextDelta      extends AgentEvent { final String text; }
final class ToolCallStarted extends AgentEvent { final String id, name; final Map<String, Object?> args; }
final class ToolCallFinished extends AgentEvent { final String id; final ToolResult result; }
final class TurnComplete   extends AgentEvent { final ChatMessage message; }
final class AgentFailed    extends AgentEvent { final Object error; }
```

**守卫**：`maxTurns`（默认 8）防死循环；`CancelToken` 支持用户中途掐断；单个工具超时（默认 30s）。

---

## 4. 工具系统

`core/tools/`

```dart
abstract class N1Tool {
  String get name;
  String get description;                    // 给模型看的，要写清楚什么时候用
  Map<String, Object?> get inputSchema;      // JSON Schema
  bool get requiresApproval => false;        // ⚠️ 死钩子——没人读它，见下面那段
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx);
}

class ToolResult {
  final bool ok;
  final String content;                      // 回给模型的文本
  final Map<String, Object?>? meta;          // 给 UI 用的附加信息（如截图 base64）
}
```

> ⚠️ **`requiresApproval` 是个死钩子，别信它。** 它声明在 `N1Tool` 上，但全仓库
> **没有任何地方读它**——`AgentLoop` 不看、注册表不存、界面上也没有对应的弹窗。
> 也就是说"点到提交订单/确认付款/删除"这种事**代码层面零拦截**，全靠
> `browser-task/SKILL.md` 那套"必须先问用户"的提示词自觉。
>
> 这段原来写的是"true = 执行前弹窗问用户"，那是**假的**，而且是个危险方向的假：
> 谁信了它，就会以为这里有护栏。真要做审批门，得走通
> `requiresApproval` → `AgentLoop` → `ChatProvider` → 界面弹窗一整条链，
> 是独立一摊活。等它真接上了，再把这段删掉。
>
> **为什么没顺手接上（2026-10-10 决定）**：原计划是"给 `browser_click` /
> `browser_type` 挂个最小的确认门"，真去想的时候发现那个形状是错的——
> 这两个工具是**每一次点击**都要过的，挂上去就是"模型点八下、用户确认八个弹窗"，
> 浏览器功能当场变得没法用。真正需要确认的不是"点了"，是"点的是不是提交/付款/
> 删除"——而那件事**工具层看不见**：它手上只有一个 `ref`，元素是什么得去问页面。
> 所以要么做成按意图分级（工具的 schema 里加一个 `risk` 让模型自报，但那等于
> 让当事人自己给自己发许可），要么在快照里标出高危控件、由 `AgentLoop` 拦。
> 两种都不是"最小的确认门"。
>
> 当下靠提示词兜着（`browser-task/SKILL.md` 的硬规矩那一段），而且**现实里炸不了
> 多大**：两端的浏览器都是干净实例，没有任何登录态，所以"下单 / 删除 / 改资料"
> 这类真正危险的动作基本**做不成**——不是被拦住了，是根本进不去。这也正是
> 现在可以不做它的理由。等哪天支持了登录态，这条就得先补上再谈登录。

`ToolContext` 提供：`memory` / `skills` / `browser` / `reminders` / `fetch()` /
`log()` / `defaultTimeout`。

（这里原来写着一个 `cancelToken`——**它不存在**。`tool_context.dart` 里没有这个
字段，也没有任何取消协议。）

### v1 工具清单

| 工具 | 三端可用 | 说明 |
|---|---|---|
| `get_time` | 全部 | 当前时间 |
| `http_fetch` | 全部 | 抓 URL → 抽正文纯文本（HTML 转文本 + 长度截断） |
| `memory_save` | 全部 | 主动记一条长期记忆 |
| `memory_search` | 全部 | 按关键词+时间检索记忆 |
| `skill_list` | 全部 | 列出可用技能 |
| `skill_read` | 全部 | 读某个技能全文 |
| `reminder_create` | 全部 | 建一个提醒 |
| `reminder_list` | 全部 | 列出提醒 |
| `browser_open` | 两端 | 打开 URL |
| `browser_snapshot` | 两端 | 拿页面可读快照（元素带 `ref` 编号） |
| `browser_click` | 两端 | 按 ref 点击 |
| `browser_type` | 两端 | 按 ref 输入文本 |
| `browser_scroll` | 两端 | 翻页（up / down / top / bottom） |
| `browser_screenshot` | 两端（**手机上必定失败**） | 截图。安卓那侧驱动没有截图接口，调了会收到一句明说的失败，让它改用 `browser_snapshot` |
| `browser_back` | 两端 | 后退 |

平台缺某个能力时，`ToolRegistry` 里直接不注册该工具（模型看不到，也就不会瞎调）。
这张表在安卓驱动写出来之前写的是"仅 exe"，那是对的；两个驱动都到位之后，七条
全部变成两端可用。

`screenshot` 是个例外：它在手机上**注册但还是会失败**。这不是漏了不注册，是刻意
的——驱动会抛一句明话（"手机上截不了页面图……要用 browser_snapshot"），模型读到
就知道换路子。工具自己的 description 早就写着"不是每个平台都支持"，就是为这条留的。

⚠️ 安卓侧的 `browser_*` 还多一个前置条件：`BrowserHost` 得先把 WebView 挂进
widget 树。没挂上时 `isAvailable` 是 false，工具照样不注册——理由见第 5 节。

两点接线细节，改这里的时候别弄丢：

- 这 7 个工具注册时**显式放宽到 60 秒**（`browserToolTimeout`）。注册表的默认值
  是 30 秒，而"等页面稳定 + 慢站"会撞上去，撞上去的表现是模型收到"超时了"，
  于是它以为那个站打不开。
- 带上浏览器工具的会话把 `maxTurns` 从 8 放到 20。一个普通的网页任务
  （`open → snapshot → click → snapshot → type → click → snapshot`）正好吃满 8 轮，
  再多一步就被掐断，用户看到的是"话说到一半停了"，而且停在最需要它继续的时候。

---

## 5. 浏览器自动化

统一接口 `BrowserDriver`（`core/browser/browser_driver.dart`），两端各一个实现：

```dart
abstract class BrowserDriver {
  bool get isAvailable;                        // 同步；由 warmUp() 那次异步探测写
  String? get unavailableReason => null;       // 说给模型听的人话，没做就是 null
  Future<void> warmUp() async {}               // 幂等，拉起浏览器 + 连上调试端口
  Future<void> open(String url);
  Future<BrowserSnapshot> snapshot();          // 快照，不是字符串
  Future<void> click(String ref);
  Future<void> type(String ref, String text);
  Future<void> scroll(ScrollDirection direction, {double amount = 0.8});
  Future<Uint8List> screenshot();
  Future<void> back();
  Future<void> dispose();
}
```

（`warmUp` / `unavailableReason` 是**带默认实现的具体成员**，不是抽象方法——
子类用 `extends` 继承它们就行。写成 `implements` 会逼每个子类抄一遍空实现。
`UnavailableBrowserDriver` 就是靠这个只写自己真正要覆盖的那几个。）

`snapshot()` 返回的是 `BrowserSnapshot`（`url` / `title` / `nodes` / `text` / `note`），
渲染成模型文本用 `toModelText()`，**只在这一处渲染**——两端格式一致靠的就是这个。

### Windows: `CdpBrowserDriver`
- 用本机已有的 Edge 或 Chrome（不下载 chromium，零额外依赖），**App 自己拉起一个干净实例**，
  跑完关掉、连临时 profile 一起删。
- 端口用 `--remote-debugging-port=0` 让系统分配，再从 profile 目录里的
  `DevToolsActivePort` 读实际端口。**不是写死的 9222**。那个文件是浏览器初始化
  之后才写的，所以要轮询带超时，不能读一次就放弃。
- 连上 `ws://…` 之后走 `web_socket_channel` 发 CDP 命令，`Runtime.evaluate` 跑 DOM 脚本。
- 🩸 **独立的 `--user-data-dir` 是硬要求**：不给的话 `msedge.exe` 会把参数交给
  已经在跑的那个实例然后自己退出，`--remote-debugging-port` 被静默忽略、端口
  永不打开，驱动永远 `isAvailable == false`——而你会去怀疑代码。
- 进程要**连子孙一起杀**：`Process.start` 拿到的可能是 launcher stub，它先退出，
  真正的 browser 是子进程，`process.kill()` 杀不掉 renderer。用 `taskkill /F /T`。

**没有登录态，这是设计。** 干净实例意味着需要登录的站（邮箱、订单、朋友圈）
做不了。这是选"干净实例"这条路时明说的代价，写进技能里了：遇到登录就停下来
告诉用户，而不是反复重试。这段原来写的是"复用用户已登录的账号"，**反了**。

### Android: `WebViewBrowserDriver`
驱动的是 **App 自己那个 WebView**，不是外部浏览器——所以没有"干不干净"的问题，
它一开始就一个 cookie 都没有，用完跟着页面一起没。

- 🩸 **视图必须挂进 widget 树，而且要真实尺寸。** 挂载点是 `BrowserHost`
  （在 `main.dart` 的 `MaterialApp.builder` 里，进程级），它把一块 390×844 的
  `WebViewWidget` 摆在屏幕左边外面（`left: -454`，`Clip.none`）。
  **不能**用 `Offstage`（不 paint，可能不触发布局），也不能用 1×1（视口太小，
  懒加载和滚动照样坏）。不挂的后果是**没有布局**：`getClientRects()` 全空
  → 快照读到**零个元素**，`window.innerHeight` 是 0 → 滚动原地踏步。
  最坏的是这些都不报错，模型只会以为自己的选择器写错了，一直换着试到回合烧完。
  所以 `WebViewBrowserDriver.isAvailable` 是 `_ready && _hostMounted && !_disposed`：
  **没挂上就报"不可用"**，宁可不让模型看见这些工具。
- 🩸 `setJavaScriptMode(JavaScriptMode.unrestricted)` 必须显式调（在
  `PlatformWebViewSurface.prepare` 里）。Android `WebSettings` **默认 JS 是关的**，
  不调的话所有 `runJavaScript` **静默无效**——不报错、不抛异常，就是不执行。
- 🩸 **`runJavaScriptReturningResult` 回传的字符串带引号**。安卓把返回值按 JSON
  编码往回带，`complete` 到手是 `"complete"`。所以等页面加载完那个比较必须先过
  `unwrapJsString`——不剥的话它永远为假，循环一直转到超时，症状是"页面好像永远
  加载不完"，而页面早就好了。同一条路上的整段 JSON 由 `decodeScriptPayload` 处理
  （三段式：直接解 → 剥一层再解 → 当纯文本）。
- `screenshot()` 是**诚实失败**：`webview_flutter` 没有截图 API，直接抛一句明话
  （"这个平台不给截图接口，改用 browser_snapshot"）。**不能**返回空字节让工具层
  去说"页面可能还没加载出来"——那是撒谎。下面这段原来写的 `RepaintBoundary`
  方案要求 WebView 在树上是**可见**的，而我们挂在屏幕外，根本不成立。
- `snapshot` / `click` / `type` / `scroll` 全部走共享脚本里那几个常量，
  解析走 `BrowserSnapshot.fromScriptResult`，工具状态判定走
  `ensureBrowserScriptOk`（`stale` / `error` / 看不懂，三种都翻成人话）。
- 驱动和真 WebView 之间隔了一层 `WebViewSurface`，纯粹是为了能测：真的
  `WebViewController` 要平台实现（插件在 `MainActivity` 里注册），单测里造不出来。
  假的换掉的只是"跟真 WebView 说话"这一层，驱动自己的状态机、超时、协议判定
  全是真的。
- ⚠️ **`http://` 的站在安卓上会被系统挡掉**（`targetSdk >= 28` 默认禁止明文）。
  manifest 里**没有**开 `usesCleartextTraffic`，所以这是当前的实际行为：
  撞上会得到一句翻译过的提示（"这个站是 http 的……改用 http_fetch"）。
  `http_fetch` 走 Dart 的 socket，不受这条限制，所以 http 站还能读、只是不能驱动。

**这一节里有一件事还没在真机上验过**：这个挂法（移出屏幕 + 真实尺寸）在
HyperOS 上到底有没有布局。真机验收的第一条就是它——读
`window.innerHeight`，是 0 就说明这个挂法不成立，得换 `flutter_inappwebview`
（它有官方的不挂 UI 也能跑的路子）。**在那之前，这一节是按源码推断的，不是实测的。**

**共同约定**（这一条现在是**真的**，不是纸面的）：脚本在
`core/browser/snapshot_script.dart` 里写一份、两端共用，解析也共用
`BrowserSnapshot.fromScriptResult`。ref → 元素的映射挂在页面的 `window.__n1.refs`
上，**每次执行都重置**，所以"ref 只在下一次快照前有效"是代码强制的，不是约定。

---

## 6. 记忆系统

`core/memory/`。两层，分开存，用途不同。

### 第一层：对话历史
SQLite 表 `conversations` / `messages`。原样存，界面「历史会话」读它。

### 第二层：长期记忆
表 `memories`，一条 = 一个事实/偏好/事件。

```sql
CREATE TABLE memories (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL,      -- fact | preference | event | relation | summary
  subject     TEXT,               -- 关于谁/关于什么（人、项目、习惯）
  content     TEXT NOT NULL,      -- 一句话说清
  tags        TEXT,               -- 逗号分隔
  importance  INTEGER DEFAULT 3,  -- 1..5
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  last_used_at INTEGER,
  use_count   INTEGER DEFAULT 0
);
```

**写进来的两条路**：
1. **主动**：agent 判断对话里出现了值得长期记住的东西 → 调 `memory_save`。system prompt 里明确告诉它什么时候该记（用户说"我喜欢/我不喜欢/我叫/我住/我打算…"）。
2. **被动**：会话超过 `N` 条消息 → 后台调 LLM 压成一条 `kind=summary` 的记忆，挂在会话上。

**注入策略**：每轮请求的 system prompt 里塞一个「记忆索引」——按 `importance × 时间衰减` 排序取前 `M` 条（默认 20），每条一行。不塞全文，agent 需要细节时自己 `memory_search`。

**v1 明确不做**：向量检索 / 嵌入模型。太重，且没有本地嵌入可用。等记忆条数上千再回来考虑。

---

## 7. 技能系统

`core/skills/skill_registry.dart`

**格式**（沿用本机既有 skill 约定，别发明新东西）：
```markdown
---
name: web-research
description: 联网调研某个主题并给出带来源的结论。当用户要求"查一下/调研/搜一下 X"时使用。
---

# Web Research — 联网调研

## 工作流
1. ...
```

frontmatter **只有 `name` + `description`** 两个字段。触发全靠 description——这条 description 会被整段塞进 system prompt，所以必须写清楚**什么时候用**。

**加载流程**：
1. 首次启动：`assets/skills/` → 释放到 `<appSupport>/skills/`（因为要可写、可增删）
2. 每次启动：扫 `<appSupport>/skills/*/SKILL.md` → 建索引
3. 索引注入 system prompt：`- <name>: <description>`（就是本机 `skills-radar` 那套思路）
4. agent 用 `skill_read(name)` 拉全文，然后照做

**预装技能（v1）**：`web-research`（联网调研）、`browser-task`（用浏览器完成一个操作流程）、`note-taking`（记笔记）、`companion-talk`（陪伴对话的人设指引）、`nuwa`（捏一个技能出来）、`coding`（写代码跑代码）、`debugging`（排错）、`testing`（写测试）、`planning`（多步任务做计划）、`review`（交付前自查）

（这行原来把第四个写成 `daily-companion`——**没有这个技能**，真名是 `companion-talk`；而且漏了 `nuwa`。
文档里列的名字要对得上 `assets/skills/` 下的目录，否则读者会去找一个不存在的东西。）

---

## 8. 存储布局

App 支持目录下（Windows: `%APPDATA%\com.niuwa\niuwa_ai`；Android: app files dir）：

```
<appSupport>/
├─ n1.db             SQLite 主库（会话 + 消息 + 记忆）
├─ skills/           释放出来的技能，可写
├─ persona/
│  └─ default.md     人设 system prompt（用户可改）
└─ logs/
```

**API Key 不走这里**——由 `flutter_secure_storage` 管（Android Keystore / Windows DPAPI 加密），文件系统里拿不到明文。

---

## 9. 界面结构（`app/lib/`）

沿用 A1 的分层命名习惯（`*_page` / `*_provider` / `*_service` / `*_widget`），别另起一套。

| 目录 | 内容 |
|---|---|
| `pages/` | `chat_page`（主界面）、`persona_page`、`memory_page`、`skills_page`、`settings_page`、`onboarding_page`（首次填 key） |
| `providers/` | `chat_provider`（ChangeNotifier，包 AgentLoop 的 stream）、`memory_provider`、`skills_provider`、`settings_provider` |
| `services/` | `n1_runtime`（组装 core 依赖）、`secure_store`（key 存取）、`db.dart` |
| `widgets/` | `message_bubble`、`tool_call_card`、`memory_card`、`skill_card`、`thinking_indicator`、… |
| `shell/` | `desktop_shell`（Windows 侧栏布局） |

---

## 10. 三端交付

| 端 | 做法 | 状态 |
|---|---|---|
| APK | `flutter build apk --release` | 已交付 |
| exe | `flutter build windows --release` + 便携打包（`app/tool/build_windows_portable.py`，含 VC++ DLL） | 已交付 |
| 网站 | 独立静态落地页，无后端、无 Key | 已上线 |

**网站为什么不做真聊天**：浏览器直连模型接口会遇到 CORS 和 Key 暴露。现在的做法是纯静态落地页 + 预设演示，不做后端、不在浏览器里存 Key。
