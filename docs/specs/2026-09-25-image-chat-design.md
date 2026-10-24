# 看图聊天 · 设计

日期：2026-09-25
状态：待评审
范围：把已经修好的多模态管道两端接上——选图入口与图片渲染；+ 升到 v3 并更新网站安装包

---

## 一、为什么做这个

N1 的多模态管道**已经通了，而且是通的**：`ImagePart` 模型在、`toWire()` 能出
OpenAI 兼容的 `content` 数组（`content` 是含 `image_url` 的列表）、SQLite 的
`images` 列在、`ChatProvider.send` 收 `images` 参数、连 `retry()` 都带着
`old.images` 重发（`chat_provider.dart:175`）。

缺的只有两头：

- **进不来**：界面上没有任何地方能选一张图
- **看不见**：`message_view.dart:31` 把 `UserItem.images` 整个丢了

所以这不是"加一个功能"，是**把一条已经修好的管道两端接上**。本文件的范围因此很窄，
而且刻意窄——中间那段既然是对的，就不要动它。

## 二、核心决定：让原生去压，自己只兜底

压缩这件事有两个实现层次，代价差一个数量级：

| | 安卓原生（picker 内部） | 纯 Dart（`package:image`） |
|---|---|---|
| 解码 | `BitmapFactory` + **`inSampleSize` 采样解码** | 全尺寸解码成位图 |
| 内存峰值 | 约等于目标尺寸 | 一张 12MP 照片 = **约 48MB 位图** |
| 编码 | 原生 `bitmap.compress` | Dart 逐像素 |
| 速度 | 快 | 慢，手机上 1–3 秒 |

`image_picker` 的 `getImage()` 本身带 `maxWidth` / `maxHeight` / `imageQuality`。
**安卓那套是原生实现**（`ImageResizer.java`，第 42 行按这三个参数判断要不要缩放，
第 56 行用 `inSampleSize`，第 188 行原生编码），所以手机上正常的一张照片，
压到 1024 长边这件事**根本轮不到 Dart 插手**。

**但桌面那套会静默忽略这三个参数。** `image_picker_windows 0.2.2` 的源码里
三处注释互相印证（第 116、171、198 行）：

> `maxWidth`, `maxHeight`, and `imageQuality` arguments are not currently
> supported. If any of these arguments are supplied, they will be silently ignored.

不报错，当没传。所以 Windows 上拿回来的永远是原图。

**决定：两条路都走，用字节数分岔。** 纯 Dart 的压缩保留，但从"主路径"降级为
"保底路径"，只在这两种情况下被调用：

1. **Windows 全部**——picker 不干活
2. **安卓漏网的 PNG**——`ImageResizer.java:185` 写死了
   `"compressing is not supported for type PNG. Returning the image with original quality"`。
   **PNG 绕过压缩，原样返回全尺寸。** 而截图正好都是 PNG。

### 判定用字节数，不用尺寸

分岔条件是 `bytes.length > 400 * 1024`，不是"长边是否超过 1024"。

理由：我们最终要控制的是传输体积（token 和带宽），而字节数直接可测、零成本。
量尺寸必须先解码文件头，就得引入解码器、就得处理"这个格式的头部在哪"的一堆分支。

代价要说清楚：**一个压缩比极高的大尺寸 PNG 会漏过去**（比如 300KB 但 3000px 宽的
纯色截图），代价是那张图多花点 token，**不影响正确性**。这个交换我认为划算。

## 三、范围

**做**：安卓的拍照与相册、Windows 的文件选择、压缩与兜底、待发预览、气泡里的缩略图、
点开看大图、发往模型时的历史裁剪、发图失败的可读错误。

**不做**：

- 一次发多张（`ImagePart` 已经是 `List`，以后放开不费事）
- iOS（交付是 APK → exe → 网站，没有 iOS 目标）
- 视频、音频、任意文件
- 图片编辑（裁剪、旋转、标注）
- 图片存到本地文件系统（base64 进 SQLite，够用）
- 从相册批量导入

## 四、架构与部件

内核保持纯 Dart（`test/core_is_pure_test.dart` 钉死），平台能力在 services 层。

### 新增 `lib/core/image/`（纯 Dart）

| 文件 | 职责 |
|---|---|
| `image_prep.dart` | `downscaleForChat(bytes, {maxEdge, quality}) → Uint8List`。像素进、JPEG 出，同步纯函数。另含分岔判定 `needsReprep(int byteLength)` 与三个常量 `kMaxEdge` / `kQuality` / `kPassThroughBytes`。失败抛 `ImagePrepException` |
| `image_window.dart` | `pruneOldImages(history, {keep}) → List<ChatMessage>`。决定**发什么给模型**，不动库里存的 |

两个文件分开，是因为它们回答两个不同的问题——「像素怎么变」和「这段对话发多少」。
改一个不会牵到另一个。而且 `image_window` 不依赖 `package:image`，没图的那条路径
根本不碰这个重依赖。

### 新增 `lib/services/image_intake.dart`

唯一的壳。读 `XFile` 字节 → 判断该不该压 → 需要的话丢进 `compute()` 跑上面那个
纯函数 → 包成 `ImagePart`。isolate 的边界和错误翻译都在这一层，写一张便利贴就能说清。

```dart
/// 压缩函数。生产用 isolate 版，测试注入假货。
///
/// **只有一个位置参数。** Dart 的函数类型不允许给具名参数写默认值
/// （`{int maxEdge = kMaxEdge}` 是编译错误），而写成 `{int? maxEdge}` 又会把
/// 空值判断漏给每个实现。而这两个参数本来也没有让外面调的余地——生产实现
/// 固定用 `kMaxEdge`/`kQuality`，测试里那个假货直接忽略。类型上就不暴露它们。
///
/// 返回 `Future` 是因为生产实现要走 `compute()`。写成同步的话
/// isolate 那一步就没地方放了（spec 初稿就是写的同步，改掉了）。
typedef DownscaleFn = Future<Uint8List> Function(Uint8List raw);

class ImageIntake {
  ImageIntake({DownscaleFn? downscale});

  /// 从选中的文件做出一份能进对话的图。
  /// 失败抛 [ImageIntakeException]，message 是可以直接给用户看的人话。
  Future<ImagePart> prepare(XFile file);
}
```

### 改动

| 文件 | 改什么 |
|---|---|
| `pubspec.yaml` | 加 `image_picker`、`image` |
| `lib/core/models/chat_message.dart` | 加 `ChatMessage.withoutImages()`（见 §6） |
| `lib/widgets/composer.dart` | 附件按钮、待发预览、签名与门禁（见 §7） |
| `lib/widgets/message_view.dart:31` | `_UserBubble` 接住 `images` |
| `lib/pages/chat_page.dart` | 传新签名 |
| `lib/providers/chat_provider.dart:137` | 空文字守卫放宽 |
| `lib/providers/chat_provider.dart:234` | 历史组装处过 `pruneOldImages` |

### 依赖说明

`image_picker 1.2.3` 的 pubspec 里 endorsement 了 `image_picker_android ^0.8.13` 和
`image_picker_windows ^0.2.2`，所以**加一个依赖就够**，不要单独加那两个。

`image 4.10.1` 是纯 Dart（不是插件），进 core 不破纯度。
它是 core 里第一个"大"依赖，会捎带 `archive`、`xml` 这些传递依赖——但 core 已经在用
`http` 和 `html` 了，这不算破例。

## 五、数据流

```
点 ＋
  ├─ 安卓：ActionSheet（拍照 / 从相册选）
  └─ Windows：直接开文件对话框
        ↓
     XFile  →  读字节
        ↓
   字节数 > 400 KiB ?
        ├─ 否 → 原样透传，mimeType 按文件实际类型判
        └─ 是 → compute() 里 downscaleForChat → JPEG 字节
        ↓
    ImagePart(base64Data:, mimeType:)
        ↓
    待发预览条（可 ✕ 删）
        ↓
  按发送 → ChatProvider.send(text, images:)
        ↓
   落库（`images` 列已存在，schema 不动）
        ↓
   气泡渲染缩略图
        ↓
  发给模型时：pruneOldImages(_wire, keep: 3)
```

**mimeType 必须跟着实际字节走**，不能图省事写死。

`ImagePart` 的默认值是 `image/png`。如果透传一张 JPEG 却留着默认值，模型会拿 PNG 的
解码器去啃 JPEG 字节——**错在服务端，本地看不出任何异常**。

做法：**只允许四种格式原样透传**（`image/jpeg` / `image/png` / `image/gif` /
`image/webp`，这几家主流的看图接口都吃），判定顺序是 `XFile.mimeType` → 文件扩展名。
**认不出的一律走压缩那条路**，出来是确定的 JPEG。

> 这一条比初稿改了。初稿写的是"认不出就按扩展名兜底成 `image/jpeg` 透传"，
> 但那正是上面警告的那个错误——**给一串猜测的字节贴一个猜的 mime，错在服务端**。
> 改成"认不出就自己压"之后有两个好处：能压开的格式（BMP、TIFF）照样能用，
> 压不开的（HEIC）会走到 §9 那句人话上，**两种情况都是本地的、可观测的**。
>
> 顺带把 BMP 从透传名单里去掉了：它在 `package:image` 里解得开，压一下就是稳的，
> 多认一种格式只是多一种"传上去让对方拒"的机会。

自报的 `XFile.mimeType` 也要过一遍这个白名单——安卓上 `image/heic` 是能报出来的，
而那种字节我们宁愿自己压。

## 六、历史裁剪

`ChatProvider._run()` 第 234 行是唯一组装发给模型的历史的地方：

```dart
final history = List<ChatMessage>.unmodifiable(_wire);
```

这里过一遍 `pruneOldImages(history, keep: 3)`。

**语义**：从后往前数，保留最近 3 条**带图**消息的图。更早的图从要发的历史里摘掉，
**文字一个字都不动**。

**库里一个字都不删。** 用户往上翻还能看见老照片，只是模型看不见了。
裁剪是"发什么"，不是"存什么"——`retry()` 要靠 `_wire` 找目标、`_wire` 是"真实发生过的
对话"，所以它保持完整。

为什么是 3：每次发送都会把整段历史重发（`chat_provider.dart:234`），而 base64 图片
是这条链路上最贵的东西。3 组够覆盖"接着说上一张图"这种连续追问，又不至于让每轮
请求都驮着十几张图。

### 必须写死的边界

**一条只有图、没有字的旧消息，摘掉图之后就成了空消息。** 线格式里它会变成
`{'role': 'user', 'content': ''}`，上游直接 400。

所以这种情况要**整条从历史里剔除**，不是留一个空壳。对应地，`pruneOldImages` 的输出
必须满足"每条消息要么有文字、要么有图"，这条要写成断言测掉。

### 需要一个新方法

`copyWith` 现在的签名是 `copyWith({String? content, String? reasoning})`，
里面写死 `images: images` 透传——**没法用它把图去掉**（`List<ImagePart>?` 的空值
语义跟"不改"撞车）。

所以在 `copyWith` 旁边加一个明确的方法：

```dart
/// 摘掉图，其余原样。
///
/// `copyWith` 做不到这件事：它的 `images` 是透传的，而用可空参数表达
/// "清空"会和"不改"撞车。
ChatMessage withoutImages() => ChatMessage(
  id: id,
  role: role,
  content: content,
  images: const [],
  toolCalls: toolCalls,
  toolCallId: toolCallId,
  toolName: toolName,
  reasoning: reasoning,
  // origin 必须跟着带。漏了的话提醒消息被摘一次图就悄悄变成普通消息，
  // 界面上那行「提醒 · 15:00」莫名消失，而且不报错、不掉字段。
  // copyWith 上已经踩过一模一样的坑。
  origin: origin,
  createdAt: createdAt,
);
```

### 一个已知限制

`_wire` 由 `_store.recent({limit: 200})` 填充，所以它**有界**——上限是最近 200 条消息
里的图。按每张约 300KB 估，极端情况下是几十 MB 常驻内存。

不打算在这轮解决（懒加载图片要动 store 的返回结构，牵连太广）。**列为已知限制，
真跑时在安卓上看一眼实际占用**，超了再议。

## 七、界面

### `composer.dart`

现在 `onSend` 是 `void Function(String)`（第 26 行），`_submit()` 第 84 行用
`text.isEmpty` 卡着。六处改动：

1. `onSend` 签名 → `void Function(String text, List<ImagePart> images)`
2. `_submit()` 的门禁 → `if (text.isEmpty && _image == null) return;`
3. 发送按钮的 `active`（第 165 行）→ `(_hasText || _image != null) && widget.enabled`
4. Row 左边加 ＋ 按钮，`widget.running` 时隐藏（跑着的时候不该允许再攒一张图）
5. 外层 `Container` 的 child 从 `Row` 变成 `Column`：预览条在上、Row 在下，
   这样**输入框那圈描边把两者一起框住**
6. 新增状态 `ImagePart? _image`

只留一个槽位（`ImagePart?` 而不是 `List`），等于把"一次一张"写进类型里。

改动会牵到调用点：`chat_page.dart:131` 现在是 `onSend: (t) => chat.send(t)`，
要跟着变成 `(t, imgs) => chat.send(t, images: imgs)`。

**Windows 上不弹 ActionSheet**，点 ＋ 直接开文件对话框——只有一个选项的菜单是无谓的
一次点击。同样因为 Windows 不支持相机（`image_picker_windows` 源码第 145 行：
`ImageSource.camera` 会抛 `StateError`，除非自己塞一个 `cameraDelegate`），
**Windows 上不提供拍照入口**，免得点了报错。

### 选图归 `chat_page`，`Composer` 不碰插件

> 这一条比初稿改了。初稿说"判断复用 composer 里已有的 `_isDesktop`"，也就是让
> Composer 自己去弹菜单、自己调 `image_picker`。那样写的话，`composer_test.dart`
> 里那 8 个现有用例全都要开始 mock 插件。

`Composer` 只负责**界面**：点 ＋ → 等一个回调 → 显示/删除待发的图。回调签名
`Future<ImagePart?> Function()?`，返回 null 表示取消或失败。

真正的选图流程（弹哪个菜单、调 `ImagePicker`、压缩、出错提示）住在 `chat_page.dart`。
它拿去调 `ImageIntake`，把人话错误用 SnackBar 弹出来。

这么分之后 `Composer` 在 widget 测试里完全可控——注入一个返回假 `ImagePart` 的闭包
就能测完整的"选了图 → 预览 → 发送"，不需要任何插件。**回调为 null 时不显示 ＋
按钮**，所以现有那 8 个用例一个字都不用改。

`_isDesktop` 那个判断提到了新的 `lib/platform.dart`，公开成 `isDesktopPlatform`，
两端共用。搬的时候那段注释（为什么用 `defaultTargetPlatform` 而不是
`Platform.isWindows`）跟着走：

> 后者在安卓 AOT 编译时整个分支会被消掉（包体里连字符串都找不到），是 A1 项目上踩过的坑。

⚠️ `composer.dart` 顶部那个 `import 'package:flutter/foundation.dart';` 是**专门为
`_isDesktop` 引入的**，getter 一走就成了未使用 import，`flutter analyze` 会红。
必须一起删掉（`TextField`/`Shortcuts`/`setState` 都在 `material.dart` 里）。

### 压缩放在选图时，不放发送时

选完 → 预览位先放一个转圈 → 压完换成缩略图 → 用 ✕ 删。

好处是发送瞬间完成，而且**出错在选图那一刻就告诉你**，不会让你打完一整句话才说图读不了。
另一条路（发送时才压）会让发送按钮同时要表达"在压图"和"模型在想"两种状态，我不喜欢。

代价是选完要等一下（Windows 上压一张 5MB 的图可能到秒级）。转圈就是为这个准备的。

### `message_view.dart`

第 31 行现在是：

```dart
UserItem(:final text) => _UserBubble(text: text, maxWidth: maxWidth),
```

`images` 在这一行被丢掉。改成把 `images` 一起传下去，`_UserBubble` 内部从
`Text` 变成 `Column`：图在上、文字在下，`if (text.isNotEmpty)` 才渲染文字
（纯图消息不该留一行空文字）。

图用 `ConstrainedBox(maxWidth: …, maxHeight: 340)` + `Image.memory(fit: BoxFit.contain)`：
不知道原始比例也不用算，Flutter 会按内在比例在这个框里适配。

### 点开看大图

缩略图只有约 250px 宽，想确认"我到底发出去的是哪张"时会需要它。

做法取最便宜的：`showDialog` + `InteractiveViewer`（可捏合缩放）+ 点任意处关闭。
约 40 行，不新增路由。

**这条可以砍**——如果只想最小闭环，删掉不影响其它任何部分。

## 八、性能：两个具体的坑

### 一、`build` 里解码 base64 会让图片每帧重新解码

流式回复的每个文字 delta 都会触发 provider 通知 → 列表重建。如果直接在 `build` 里写
`Image.memory(base64Decode(image.base64Data))`：

1. 每帧解一次 base64（CPU 白烧）
2. 更要命的是，每帧产生一个**新的 `Uint8List`**。Flutter 的 `ImageCache` 拿字节数组的
   相等性当 key，新旧不相等 → 判定为新图 → **每帧重新解码一遍图片**

所以图片渲染要包一个小的 `StatefulWidget`，把解好的字节缓存在 state 里，
只在 base64 串真的变了时才重解。加 `gaplessPlayback: true` 避免换图时闪一下。

这条不是优化，是**不做就是错的**。

### 二、纯 Dart 解码不能在主线程上跑

`package:image` 的解码 + 缩放 + 编码是逐像素的 Dart 代码，一张 5MB 的图在桌面上能跑
到秒级。放主线程上就是几秒钟的界面冻结，用户会以为 App 卡死了。

所以 `image_intake.dart` 里那一步必须进 `compute()`。core 里的纯函数不知道有 isolate
这回事，isolate 只在 services 这一层的调用点出现。

## 九、失败与边界

| 情况 | 处理 |
|---|---|
| 用户取消选择 | `XFile` 返回 null，什么都不做，不进待发区 |
| 格式认不了（HEIC 等） | 捕获 → 「这张图我读不了，换一张试试」，不塞进待发区 |
| 图片超大（安卓 PNG 漏网） | 字节阈值兜底，走自己压 |
| 压完还是很大 | 允许进待发区，不拦。宁可发出去慢，也不要静默拒绝用户 |
| **用户配的是纯文本模型** | 上游 400。映射成人话：「当前这个模型可能不支持图片，去设置里换一个能看图的」 |
| 跑着的时候点 ＋ | 按钮隐藏，压根点不到 |
| 发送失败后重试 | `retry()` 已经带着 `old.images`（第 175 行），不用改 |
| 清除对话 | 见下方「清除对话之后待发区那一张」 |
| **安卓内存紧张时把选图 Activity 杀了** | 图**静默消失**，不报错、不弹窗。只有 `retrieveLostData()` 能救回来。本轮不做，见下方 |
| **图片自带的元数据（GPS／机型／拍摄时间／朝向）** | 压缩路径摘掉 EXIF；透传路径原样保留。**故意的差异**，见下方 |

**清除对话之后待发区那一张。** `chat_page.dart:88` 在确认框之后调 `chat.clear()`，
但待发的图存在 `Composer` 自己的 state 里（`_image`），而 Composer 是同一棵树里的
**兄弟节点**——provider 清空传不到它。不管的话，清完对话输入框上还挂着一张待发的图。

机制取最便宜的那个：`_ChatPageState` 里加一个 `int _composerGeneration = 0;`，
清空之后 `++`，然后 `Composer(key: ValueKey(_composerGeneration), …)`。
换 key 就让 Composer 从零重建，`_image` 自然没了。

**发完也要归零。** `composer.dart:85-86` 现在是 `_controller.clear()` 之后
`widget.onSend(text)`，加图之后要跟着把 `_image` 置空，否则同一张图会连着发两次。

倒数第二行值得说一句：**发图失败必须落到"换个模型"，而不是把裸 400 丢给用户。**
这个 App 的卖点就是"不绑任何一家模型"，所以用户手里真有可能是一个纯文本模型。
不做预防（没法可靠探测对方支不支持），但错误信息必须指对方向。

**安卓把选图 Activity 杀了，图会静默消失——这是已知限制，本轮不救。** 内存紧张时
安卓会回收我们的 Activity；用户从相册或相机选完图回来，进程可能已经被重启过，
`pickImage` 那次调用于是拿不到任何东西：不抛异常、也不给一个能区分"取消"的信号，
表现就是"点了 ＋、选了一张、什么都没发生"。`image_picker` 为这种情况留了另一个
入口 `retrieveLostData()`（启动时单独问一次"上次是不是有个没交回来的结果"），
本轮**不做**。记在这里有两个用处：真机验收撞上时知道这不是崩溃、别去找
（验收清单里有"杀后台再回来"这一条）；以及以后要救的时候，知道救它的东西叫什么。

**图片自带的元数据：两条路处理得不一样，这是故意的。** 大图（超阈值，走我们自己
的解码 → 缩放 → 重编码）出的是重新编码的 JPEG，**没有元数据**——重编码那一步显式
摘掉了 EXIF，里面有 GPS、机型、拍摄时间，而这张图要去的是用户自己配的第三方接口、
本地还要 base64 落库。小图和 Windows 上（原字节透传）**元数据原样发出去**，因为
透传这条路存在的全部理由就是"字节一个都不变"，它有一条测试钉着；想在 Dart 层给
一段原样保留的字节做 EXIF 重写，就等于把整张图重新编码一遍，那就不叫透传了。
一句话：**大图经过压缩 ⇒ 没有元数据；小图/Windows 透传 ⇒ 元数据原样发出去。**

**朝向和 EXIF 是两件事，摘之前必须先把它落到像素上。** orientation 这个 tag 不是
隐私问题，是"这张图该怎么摆"的问题——摘掉它而没把旋转应用到像素上，竖着拍的
照片发出去就是横的。这里踩到过一个真实的坑：JPEG 的**解码器**会替我们烘焙朝向
（`image` 库的 `getImageFromJpeg` 把 orientation 转进像素、顺手把 tag 抹掉），
所以光看 JPEG 会以为"摘 EXIF 是安全的"；但 **WebP 的解码器不烘焙**，tag 原样留在
解码结果里。压缩路径里"不缩放"那一支（长边 ≤ 1024）没有 `copyResize`，也就没有
它内部那次烘焙，于是 `exif.clear()` 就把朝向扔了。修法是解码之后自己统一烘焙一次
（见 `image_prep.dart`，带条件：没 tag 时不做，免得白白复制一遍像素）。
`image_prep_test.dart` 里有一条拿 WebP 当输入的测试钉着这件事——**红过才绿的**。

（PNG 的 eXIf 不用操心：`image` 库的 PNG 解码器压根不解析它，那段代码是注释掉的
TODO。所以带 EXIF 的 PNG 进来，朝向信息在解码那一步就没了，与我们摘不摘无关。）

## 十、动手第一步要实测的一件事

**合并后的 AndroidManifest 里有没有 `CAMERA`。** `image_picker` 用系统相机
Intent（`ACTION_IMAGE_CAPTURE`）加自己的 FileProvider，按安卓的平台行为：
**声明了 `CAMERA` 权限就必须先拿到运行时授权，不声明反而不需要。** 所以有没有这个
权限，决定了要不要加一段运行时请求。

做法：加完依赖就构建一次 APK，**读打包好的那个文件**（`aapt dump permissions`），
不读自己写的那份清单。结论出来之前**不写任何权限代码**——没有权限还去请求，
是画蛇添足，而且多一条没必要的权限声明会吓到用户。

### 已经从"实测项"降级成"验收项"的：HEIC

初稿把 HEIC 和 CAMERA 并列成"动手第一步的两条实测"，**这个并列是错的**，
只有 CAMERA 成立。

理由：HEIC 要回答的问题是"§9 那条兜底路径成不成立"，而**那条兜底路径本来就必须存在**。
`ImageResizer.java:185` 写死了 PNG 绕过压缩、Windows 整个忽略压缩参数——这两个已经
读源码确认了，它们各自都需要一次压缩兜底。既然兜底无论如何都要写，HEIC 支不支持
就不改变任何实现，它只是"兜底能不能救下 HEIC"这一个问题的答案。

而且它没法提前测：picker 的入口还没写出来，**在能选图之前根本造不出一个 HEIC 的
`XFile` 来喂给 `ImageIntake`**。所以它降级成真机验收里的一条，两种结果都算通过——
能发出去算通过，弹「这张图我读不了，换一张试试」也算通过，如实记录是哪种。

（`package:image` 大概率解不开 HEIC。所以预期是走弹人话那条路。**但这是预期，
不是结论**，验收时按实际结果记。）

这个项目已经吃过一次「合并后的清单和你写的那份不是一回事」的亏——release 包因为
Flutter 模板只把 INTERNET 写进 debug/profile 两份 manifest 而没法联网，症状
（`Failed host lookup ... errno = 7`）看着完全像别的问题。所以这次**看合并产物**，
不看自己写的那份。

## 十一、测试与验证

关卡按项目规矩：`flutter analyze` 零 issue + `flutter test` 全绿（当前基线 259）+ 真跑。

### 纯函数层（最该测的，不碰平台、不碰文件）

`test/core/image/image_prep_test.dart`

- 16×16 的 PNG → 压出来是 JPEG（开头三字节 `FF D8 FF`）
- **测试里把 `maxEdge` 传成 8**，长边正好压到 8、短边等比
- 本来就比 `maxEdge` 小的图**不被放大**
- `quality` 调到 30 和 95，后者字节数更大
- 坏字节 → 抛 `ImagePrepException`，不是崩溃、不是空返回

第二条要注意：**别想着内嵌一张 1024px 的 PNG 当测试素材**——那样常量本身就有几百 KB。
用一个 16×16 的小图配 `maxEdge: 8`，测的是同一段缩放逻辑，代价是几十字节。

素材用 `package:image` 现场编出来（`img.encodePng`），不内嵌 base64 串：编码和
"解码 + 缩放"是两条不同的代码路径，现场编还省掉一个几 KB 的常量。

> **quality 那条必须用噪声图，不能用纯色图。** 纯色图在任何 quality 下都会被压到
> 几十字节，30 和 95 出来的大小可能一模一样、甚至反过来——那条断言会变成偶尔红
> 偶尔绿的假测试。用一个确定性 LCG 生成像素，体积才跟 quality 单调。

`test/core/image/image_window_test.dart`

- 3 条带图 + 1 条纯文字 → 图全留
- 4 条带图 → 最老那条的图被摘、**文字还在**
- 一条只图无字的旧消息越过窗口 → **整条消失**，不是留空壳
- 不修改传入的列表（不可变性）
- 裁完的每一条 `toWire()` 出来的 `content` **都不为空**

最后一条是把 §6 那个边界钉死的地方。

### services 层

`test/services/image_intake_test.dart`

- 小于阈值的字节 → 原样透传，且 **mimeType 取自文件而不是硬编码**
- 大于阈值的字节 → 走压缩，输出 `image/jpeg`
- 坏文件 → 抛 `ImageIntakeException`，message 是人话

这里要注入同步的假 `DownscaleFn`，别在测试里起真的 isolate。

### widget 层

- 有图无文字时发送按钮是激活的
- 删掉图之后，发送按钮在文字也空的情况下变回灰的

### 真跑

- **手机**：拍一张 → 确认待发缩略图出来 → 发送 → 确认模型答得上来
- **手机**：从相册选一张已有的照片 → 同上
- **手机**：选一张**截图（PNG）** → 确认它被压小了（这条走的是兜底路径）
- **手机**：发一张图之后**关掉 App 再打开** → 确认图还在气泡里
- **电脑**：点 ＋ → 确认直接弹文件对话框、没有 ActionSheet、没有拍照选项
- **电脑**：选一张大图 → 确认预览位的转圈出现 → 压完出缩略图
- **两端**：连发 4 张图之后，往上翻确认**老图还在界面上**
- **配一个纯文本模型**发一张图 → 确认提示指向"换个模型"，不是裸 400
- **安卓**：发十来张图之后 `adb shell dumpsys meminfo <包名>` 看 `TOTAL` 那一行的
  PSS，把数字如实记下来

倒数第二条是这个功能最容易被跳过、又最该走的一条。

**裁剪那条没有别的验证手段**：界面本来就该照旧显示所有图，库里也一个字不该变，
所以"发出去的那份被裁了"从界面上看不出来。为此 `_run` 里留了一行
`debugPrint('[chat] 发出历史 N 条，其中带图 M 条')`，连发 4 张图时 M 应该是
**1 → 2 → 3 → 3**。这是唯一能看见它的地方。

**内存那条只测不改**：`_wire` 里驮着最近 200 条消息的 base64，几十 MB 是已知代价。
懒加载要动 `MessageStore.recent()` 的返回结构，牵连 provider、裁剪、重试三条路径，
是独立的一轮。数字要是大到离谱（超过 150MB）就停下来说一声，别顺手改。

## 十二、收尾：升到 v3 并更新网站

功能验完之后收尾，让网站上的安装包是最新构建。**用户明确要求了这一条。**

### 为什么不在动手之前就先更一次

网站上的包是 **11:11** 构建的，而提醒那一轮的四个提交落在 **13:37–13:45**——也就是说
网站现在落后一整轮。这个缺口是真实的，**但故意先不补**：

看图聊天做完之前，"最新构建"这个东西根本不存在，只能构建出"仓库当前 HEAD"。
而一次构建、一次部署、一个版本号 v3，比构建两遍、传两遍 53 MB 划算。

### 提醒这个功能的最终状态（写清楚，免得以后误判）

**功能不做了**（2026-09-25 用户决定），它的两份计划文件已删。但**内核代码留在仓库里
不摘**：4 个提交、测试全绿、界面上没有入口、模型只有被明确要求时才会调，而且调了会
如实说"到点不会响"（调度器是 `NoopReminderScheduler`，返回的就是这句）。摘掉要回退
4 个提交、把数据库版本从 2 退回 1，代价远大于收益。

设计文档 `docs/specs/2026-09-25-reminders-design.md` 保留，作为设计记录。

**所以 v3 的包里会带着这段提醒代码，这是知情的选择，不是漏删。**

### 版本号 v2 → v3

五处要同步：`appVersionNumber`、`pubspec.yaml` 的 `version`、`windows/runner/main.cpp`
的窗口标题、`windows/runner/Runner.rc` 的 ProductName / FileDescription、
`android/app/src/main/AndroidManifest.xml` 的 `android:label`。

不用手抄这个清单：`test/app_info_test.dart` 已经把它们全钉住了，期望值都从
`appVersionNumber` 推。操作是**改那一个数 → 跑测试 → 四条失败各自指着要改的文件和行**。

`pubspec.yaml` 那处的对应关系是 `0.$v.0+$v`，所以 v3 是 `0.3.0+3`。

### 网站要改 12 处

| 位置 | 现在 | 改成 |
|---|---|---|
| `index.html:37` | `v2` | `v3` |
| `index.html:55` | `niuwa v2` | `niuwa v3` |
| `index.html:251` | `niuwa v2` | `niuwa v3` |
| `index.html:253` | `niuwa-v2-arm64.apk` | `niuwa-v3-arm64.apk` |
| `index.html:254` | `20.4 MB` | 量出来的实际大小 |
| `index.html:255` | 下载链接 | 新文件名 |
| `index.html:260` | `18.0 MB` + 链接 | 实际大小 + 新文件名 |
| `index.html:267` | `niuwa v2` | `niuwa v3` |
| `index.html:269` | `niuwa-v2-windows.zip` | `niuwa-v3-windows.zip` |
| `index.html:270` | `13.6 MB` | 量出来的实际大小 |
| `index.html:271` | 下载链接 | 新文件名 |
| `index.html:296` | `niuwa v2` | `niuwa v3` |

**三个大小数字必须从实际产物 `ls -la` 量，不许沿用上面表里这些旧数**——加了图片选择之后
APK 会变，而页面上写的大小和真实文件对不上是最容易露馅的那种不严谨。

### 构建与部署

步骤 `docs/web-landing-page.md` 里全有，照它走，别重新发明。三条要点：

1. **必须 `--split-per-abi`。** 不分架构的通用包 57.9 MB，超过 Pages 单文件 25 MiB 上限。
2. **在 `/d/temp` 里跑 wrangler**，别在项目根跑——它会生成 `wrangler.jsonc`、改
   `package.json` 和 `.gitignore`，还会把 `app/release/` 里 95 MB 的 exe 当资源扫。
3. **别设 `PUB_CACHE`，别用管道。** 环境里本来就有对的 `D:\pub-cache`；管道会把 flutter 的
   失败退出码吞掉。

### 收尾动作

- `web/assets/pkg/` 里的旧 v2 三个文件删掉，换成 v3 的
- **`web/README.md` 那个 72 字节存根不要删**——Pages 有资源保留缓存，空掉的路径会冒回来，
  那个存根是故意占位的
- 部署完按老规矩验：三个文件都 200、**字节数与本地逐一相同**、线上 arm64 APK 的
  `sha256` 与本地一致、浏览器控制台 0 报错

判断文件到底发出去没有**不能看状态码**——整站有 SPA 兜底，不存在的路径也返回 200 +
首页 HTML。要看 `content-type` 和字节数。

**`web/` 目录就是公网上能看到的全部内容**，Pages 没有任何排除机制（`.assetsignore`
实测无效，而且它自己也会被发出去）。所以部署前的检查笔记一律写进
`docs/web-landing-page.md`，不许留在 `web/` 里。

### 明确不做

落地页上那段演示对话**不跟着加图片**。这是营销内容，不是安装包，用户这次要的是
"网站上能下到最新包"。要加另开一轮。

## 十三、这轮之后

同一套部件能承接的后续，不用推倒重来：

- 一次多张（`_image` 换成 `List<ImagePart>`，`pruneOldImages` 的计数口径改成按消息数
  而不是按张数——现在两者等价，放开之后要重新定义）
- `keep` 做成设置项（现在是写死的 3）
- 图片懒加载（`recent()` 不返回 base64，用时再取），解掉 §6 那个已知限制
- 图片存文件系统而不是 base64 进库，让聊天记录小下来
- 落地页的演示对话补一段看图（如果真要，另开一轮）
