# 提醒与主动关怀 · 设计

日期：2026-09-25
状态：待评审
范围：路线「甲·分两步」的第一步——骨架 + 一次性提醒

---

## 一、为什么做这个

N1 现在的 agent 能力全是**被动**的：你说一句，它答一句。工具表里只有时间、抓网页、
记忆存取、读技能这六样，没有任何一样能让它"在你不说话的时候做点什么"。

这个功能要把 N1 从"你问我才答"变成"它自己会想起你"。三件事按优先级：

1. **用户说「提醒我 X」→ 到点提醒**（本文件范围）
2. 每日/固定时间的问候（第二步）
3. 久未打开 App 就关心一句（第二步）

选「定时/主动关怀」而不是"浏览器自动化"，理由：它是唯一手机和电脑都能跑的，
最贴「情感陪伴」这条宗旨，而且它天然属于 agent 能力——N1 靠一个工具自己判断
什么时候该设提醒、该说什么。

## 二、核心决定：提前写好

**到点说的那句话，在设提醒的那一刻就生成好、存下来，到点由系统闹钟直接弹出。**

不做到点唤醒 App 现场调模型，理由：

- 安卓后台唤醒和后台联网都不可靠（Doze、厂商省电策略），"该响的时候没响"是这类
  功能唯一的死刑
- 不需要 API Key 在系统后台可用
- 你当场就能看见 N1 写了什么，不会有"它背着我发消息"的感觉

落到代码上，这个决定体现为：**`reminder_create` 工具收一个 `say` 参数，
由 N1 在设提醒的当下把这句到点要说的话写好并传进来。** 不需要单独的文案生成器。

### 顺带的一个简化

**「明天下午三点」翻译成绝对时间，也由 N1 完成。** 工具只收具体时间戳，
内核里不写中文时间解析。

时间解析又难写又难测（"下周三""月底""你上次说的那天"），而且永远写不全。
现在这段活在模型的强项上，内核只处理一个干净的 `DateTime`。

## 三、范围

**做**：用户明确要求的一次性提醒，含创建、存储、调度、通知、管理页、响过之后落回聊天。

**不做**（第二步或更远）：

- 每日/重复提醒
- 手机与电脑之间同步
- 久未打开 App 自动关心
- 提醒页里用中文输入时间（用系统日期选择器）
- N1 未经用户要求主动设提醒（明确禁止，见 §7）

## 四、架构与部件

内核保持纯 Dart（项目铁律，`test/core_is_pure_test.dart` 钉死），平台能力在 services 层注入。

### `lib/core/reminder/`（纯 Dart）

| 文件 | 职责 |
|---|---|
| `reminder.dart` | `Reminder` 数据模型 + `ReminderKind` / `ReminderState` 枚举 |
| `reminder_store.dart` | `ReminderStore` 接口 + `InMemoryReminderStore`（测试用） |
| `reminder_scheduler.dart` | `ReminderScheduler` 接口：`schedule` / `cancel` / `syncAll` |

### `lib/core/tools/builtin/reminder_tools.dart`

| 工具 | 职责 |
|---|---|
| `reminder_create` | N1 用它设一条提醒 |
| `reminder_list` | N1 用它回答"我设了哪些提醒" |

### `lib/services/`

| 文件 | 职责 |
|---|---|
| `reminder_store.dart` | `SqliteReminderStore.fromDatabase(db)` + `createSchema(db)` |
| `notification_scheduler.dart` | `NotificationScheduler implements ReminderScheduler`，包 `flutter_local_notifications` |

### `lib/pages/reminders_page.dart` + `lib/providers/reminders_provider.dart`

### 接线点

- `N1Runtime._openDatabase()` 里加 `SqliteReminderStore.createSchema(db)`
- `N1Runtime.newSession()` 里注册两个提醒工具
- `AppShell` 不变（提醒页从聊天页进，不占导航位）

## 五、数据模型

```dart
enum ReminderKind { once }           // 以后加 daily / inactivity
enum ReminderState { pending, fired, cancelled }

class Reminder {
  final String id;
  final DateTime fireAt;      // 什么时候响，本地时间
  final String message;       // 到点说的那句话（提前写好）
  final String sourceText;    // 用户原话，给用户看的"你当时是这么说的"
  final ReminderKind kind;
  final ReminderState state;
  final DateTime createdAt;
  final DateTime? firedAt;
  final String? messageId;    // 响过之后落进聊天记录那条消息的 id
}
```

时区：用户在中国，无夏令时，一律本地时间，不做时区处理。

## 六、数据库迁移（版本 1 → 2）

现在库是 version 1，只有 `memories` 和 `messages` 两张表。

**这一步要动 `messages` 表**：加一列 `origin TEXT`，用来标记"这条是定时提醒产生的"。
不落库的话，「提醒」那行小字重启一次就没了，用户会看见同一个界面两种样子。

迁移内容：

1. `CREATE TABLE reminders (...)` + 索引
2. `ALTER TABLE messages ADD COLUMN origin TEXT`

**两条路必须建出一模一样的表结构**：

- 全新安装走 `onCreate`，不会走 `onUpgrade`
- 老用户升级走 `onUpgrade`，不会走 `onCreate`

项目已经踩过同款的坑（两个 store 各自建表，第二个看到版本号对了就跳过建表，
那张表永远建不出来，直到第一次写数据才炸 `no such table`）。所以有专门的测试
拿一份版本 1 的库升级，再跟全新安装的库逐列对比结构（见 §9）。

保持 `N1Runtime._openDatabase()` 是"schema 唯一真相"的落点。

## 七、工具设计

### `reminder_create`

参数：

| 参数 | 必填 | 说明 |
|---|---|---|
| `fire_at` | 是 | 绝对时间，`YYYY-MM-DD HH:MM`（本地时间） |
| `say` | 是 | 到点要说的话。一到两句话，像人说话，不要写"提醒：交作业" |
| `source_text` | 否 | 用户原话。不给就用 `say` 兜底 |

校验（不通过就返回明确的失败原因，让 N1 自己改）：

- `fire_at` 解析不了 → 报错，附上期望格式
- `fire_at` 已经过去了 → 报错
- `fire_at` 超过一年后 → 报错。防的是 N1 手滑把 2026 写成 2062，
  那条提醒永远不会响，而你看不出来
- `say` 为空 → 报错
- `say` 超过 200 字 → 截断，并在返回里说明"太长了给你截了"，别默默改掉 N1 写的话

成功后：写库 → 立刻调 `scheduler.schedule()` → 回 N1 一句简短确认。
**排闹钟失败不能吞**：返回里要带"设是设了，但系统没让排闹钟，可能不会响"，
让 N1 如实转告用户。

### `reminder_list`

收一个可选的 `include_fired`。回一张清单：时间、内容、状态。
空白时回"还没设过提醒"。

### 工具描述里要写死的分寸

- **只在用户明确要求提醒、并且时间说得清楚时使用。**
- 用户说"晚点提醒我""过会儿再说"这种没有具体时间点的，**先追问**，
  不要自己猜一个时间塞进去。猜错比不设更烦人。
- 用户要"每天提醒我"的，如实说这轮只能设一次性的，并问要不要先设最近的这一次。
- **绝不主动给用户设提醒。**

## 八、界面

### 入口

聊天页 AppBar 右上角加铃铛图标 → 提醒页。有待响提醒时铃铛带小圆点。

不加第五个导航标签：底栏四个已经满了，而且提醒是"你跟 N1 的约定"，
属于对话的一部分，不是独立资料库。日常发现路径是对话本身。

### 提醒页

分「待响」「已响」两段。每条卡片三行：

```
🔔 明天 15:00
「三点了，作业交了没？」
你说：明天下午三点提醒我
```

点开可改时间（系统日期选择器）、改内容、删除。已响的折叠在下半部分。

无通知权限时页面顶部出一条提示条 + "去开启"按钮。

### 系统通知

- 标题：`牛蛙`（跟人设一致。不写 `niuwa v2`，通知栏里那像软件名不像人名）
- 正文：`say` 的内容
- 点击：打开 App → 滚到聊天里那条消息 → 轻微高亮

**点击的落点必须准。** 点进来还得自己找，这个功能就断在那儿了。

### 响过之后在聊天里的样子

跟普通 N1 消息视觉上几乎一样，只多一行极淡的小字：

```
        ┌─────────────────┐
        │ 三点了，作业交了没？ │
        └─────────────────┘
          提醒 · 15:00
```

不做卡片、不加图标、不上颜色。用户要的是"它想起我了"这种连续感；
做成卡片就变成工具了。那行小字的作用是区分"现场回的"和"之前约好的"，
点一下跳到提醒页对应那条。

## 九、平台限制与降级

| 情况 | 后果 | 处理 |
|---|---|---|
| 安卓未授予"闹钟与提醒"权限（12+ 需单独授权） | 系统攒批，晚十几分钟到半小时 | 首次设提醒时引导授权；不授权则用不精确闹钟，并如实告知 |
| 手机重启 | 闹钟全丢 | 声明 `RECEIVE_BOOT_COMPLETED` 权限（插件自带开机接收器，理论上会重排已排的通知——**这一点实现时先验证，我没实测过**）。无论插件是否接管，App 每次启动都调一次 `scheduler.syncAll()` 对账：库是真相，系统闹钟是派生物 |
| 厂商省电策略（小米尤其凶）杀后台 | 不响 | 引导开启"自启动/后台运行"。无法代替用户决定，只能提示 |
| Windows 非 MSIX 安装 | 已排出的通知**取消不掉**（官方 README 明确） | 需要撤销的场景改走 App 内显示，不排系统通知 |
| Windows 便携版能否弹 toast | **未知** | 见 §10 |

**失败必须说出口。** 没有权限、系统拒绝排闹钟，N1 在对话里如实说明，
提醒页顶部出提示条。不许假装设成功——那是最伤信任的失败方式。

## 十、未决事项（动手第一步就要解决）

**Windows 便携 exe 能不能弹系统 toast。** `flutter_local_notifications` 22.3.1
支持 Windows（C++/WinRT），但官方 README 只写了"非 MSIX 打包的程序无法取消
已发出的通知、`getActiveNotifications` 返回空"，**没有说明非安装版显示通知本身
是否需要注册 AppUserModelID**。

如果便携 exe 弹不出来，Windows 侧的方案要改成"App 开着 → 应用内提醒；App 关着 →
托盘/角标"。**这会改掉一段实现，所以要在动手第一步就实测，不留到验收。**

## 十一、测试与验证

关卡按项目规矩：`flutter analyze` 零 issue + `flutter test` 全绿 + 真跑一遍有输出为证。

### 单元测试（内核纯 Dart，全覆盖）

- `Reminder` 模型的序列化往返
- `InMemoryReminderStore` 的增删查与排序
- `reminder_create` 的每一条校验：时间格式错、时间已过去、时间超一年、
  `say` 为空、`say` 过长截断
- `reminder_list` 的空白与有内容两种情况

### 存储测试

- `SqliteReminderStore` 与 `InMemoryReminderStore` 行为逐条对齐
  （照 `memory_store_test.dart` 的套路）

### 迁移测试（最该测的一条）

- 造一个 **version 1** 的库（只有 memories + messages）→ 走 `onUpgrade` 升到 2 →
  断言 `reminders` 表存在、`messages.origin` 列存在、**原有数据一行没丢**
- 新建一个空库走 `onCreate` → 断言最终结构跟上面升级来的**逐列相同**

出问题只在老用户身上露头，全新安装一辈子碰不到，所以这条必须测。

### 真跑

- 手机：设一个两分钟后的提醒 → **锁屏** → 等它响 → 点通知 → 确认落在那句话上
- 电脑：设一个两分钟后的提醒 → **关掉 App** → 等它响
- 没给通知权限时，确认 N1 在对话里如实说了

**只有真机响过才算这个功能做完了。** 单测全绿不算。

## 十二、这轮之后

第二步在同一套模型上扩展，不用推倒重来：

- `ReminderKind` 加 `daily`（重复提醒，Windows 不支持系统重复，
  要在应用层展开成一条条具体时间的通知）
- `ReminderKind` 加 `inactivity`（久未打开 → 走 App 内显示，不排系统通知，
  打开即视为撤销，正好绕开 Windows 取消不掉的限制）
