import '../util/ids.dart';

/// 提醒的类型。
///
/// 现在只有一次性。以后加 `daily`（每天重复）和 `inactivity`（久未打开就关心）
/// 往这里追加——**枚举值只能加，不能改名**：库里存的是 `name`，
/// 改名等于让已经落库的老数据变成认不出的值。
enum ReminderKind {
  once;

  /// 认不出就当成一次性。
  ///
  /// **不丢数据**——跟聊天记录那边「认不出 role 就丢整行」的态度不同，
  /// 理由是不一样的事：role 认错会让一条消息在协议层变得不合法，
  /// 而类型认不出只是少了个分类，时间点和内容都还好好的，丢掉太可惜。
  static ReminderKind parse(String? raw) {
    for (final k in ReminderKind.values) {
      if (k.name == raw) return k;
    }
    return ReminderKind.once;
  }
}

/// 提醒的生命周期。
enum ReminderState {
  /// 还没到点，系统闹钟排着队。
  pending,

  /// 已经响过了。
  fired,

  /// 用户取消掉了。
  cancelled;

  static ReminderState parse(String? raw) {
    for (final s in ReminderState.values) {
      if (s.name == raw) return s;
    }
    return ReminderState.pending;
  }
}

/// 一条提醒。
///
/// 设计成不可变（跟 `ChatMessage` 一致）：列表、界面、调度器到处在传同一个对象，
/// 可变对象迟早被某处就地改掉。
class Reminder {
  const Reminder({
    required this.id,
    required this.fireAt,
    required this.message,
    required this.sourceText,
    required this.createdAt,
    this.kind = ReminderKind.once,
    this.state = ReminderState.pending,
    this.firedAt,
    this.messageId,
  });

  factory Reminder.create({
    required DateTime fireAt,
    required String message,
    required String sourceText,
    ReminderKind kind = ReminderKind.once,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return Reminder(
      id: newId('rem'),
      fireAt: fireAt,
      message: message,
      sourceText: sourceText,
      kind: kind,
      createdAt: at,
    );
  }

  final String id;

  /// 什么时候响。**本地时间，不带时区**——用户在国内，没有夏令时，不折腾时区。
  final DateTime fireAt;

  /// 到点要说的那句话。**在设提醒的那一刻就写好了**，到点由系统闹钟直接弹出，
  /// 不需要唤醒 App 去调模型。完整理由见
  /// `docs/specs/2026-09-25-reminders-design.md` 第二节。
  final String message;

  /// 用户当时的原话。界面上显示「你当时是这么说的」用。
  final String sourceText;

  final ReminderKind kind;
  final ReminderState state;
  final DateTime createdAt;

  /// 真正响掉的时刻。没响过就是 null。
  final DateTime? firedAt;

  /// 响过之后，这句话落进聊天记录成为的那条消息的 id。
  /// 通知点击要跳到那条消息上，靠它找。
  final String? messageId;

  bool get isPending => state == ReminderState.pending;

  Reminder copyWith({
    DateTime? fireAt,
    String? message,
    String? sourceText,
    ReminderState? state,
    DateTime? firedAt,
    String? messageId,
  }) => Reminder(
    id: id,
    fireAt: fireAt ?? this.fireAt,
    message: message ?? this.message,
    sourceText: sourceText ?? this.sourceText,
    kind: kind,
    state: state ?? this.state,
    createdAt: createdAt,
    firedAt: firedAt ?? this.firedAt,
    messageId: messageId ?? this.messageId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'fire_at': fireAt.millisecondsSinceEpoch,
    'message': message,
    'source_text': sourceText,
    'kind': kind.name,
    'state': state.name,
    'created_at': createdAt.millisecondsSinceEpoch,
    'fired_at': firedAt?.millisecondsSinceEpoch,
    'message_id': messageId,
  };

  /// 一行 → 一条提醒。
  ///
  /// **坏数据不抛异常**（跟 `SqliteMemoryStore._entryOf` 一个态度）：库文件在应用
  /// 目录里，用户导入、手改、旧版本升级都可能留下脏行，一行坏数据不该让整个
  /// 提醒列表——甚至 App 启动——崩掉。
  ///
  /// 调用方要自己检查 [id] 是不是空的；空 id 的行应该整行丢掉，
  /// 因为主键都没有的行写不回去也删不掉。
  static Reminder fromJson(Map<String, Object?> json) => Reminder(
    id: (json['id'] as String?) ?? '',
    fireAt: _time(json['fire_at']),
    message: (json['message'] as String?) ?? '',
    sourceText: (json['source_text'] as String?) ?? '',
    kind: ReminderKind.parse(json['kind'] as String?),
    state: ReminderState.parse(json['state'] as String?),
    createdAt: _time(json['created_at']),
    firedAt: json['fired_at'] == null ? null : _time(json['fired_at']),
    messageId: json['message_id'] as String?,
  );

  /// 缺列、类型不对、超出 DateTime 能表示的范围，一律退回 epoch 0。
  static DateTime _time(Object? raw) =>
      DateTime.fromMillisecondsSinceEpoch(raw is int ? raw : 0);
}
