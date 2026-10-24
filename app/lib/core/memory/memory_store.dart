import '../util/ids.dart';

/// 记忆的类别。跟 `note-taking` 技能里教的分类一一对应。
enum MemoryKind {
  fact,
  preference,
  event,
  relation,
  summary;

  static MemoryKind parse(String? raw) => MemoryKind.values.firstWhere(
    (k) => k.name == raw,
    orElse: () => MemoryKind.fact,
  );
}

/// 一条长期记忆。
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.kind,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.subject,
    this.tags = const [],
    this.importance = 3,
    this.lastUsedAt,
    this.useCount = 0,
  });

  factory MemoryEntry.create({
    required MemoryKind kind,
    required String content,
    String? subject,
    List<String> tags = const [],
    int importance = 3,
    int? now,
  }) {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;
    return MemoryEntry(
      id: newId('mem'),
      kind: kind,
      content: content,
      subject: subject,
      tags: tags,
      importance: importance.clamp(1, 5),
      createdAt: ts,
      updatedAt: ts,
    );
  }

  final String id;
  final MemoryKind kind;
  final String content;

  /// 关于谁 / 关于什么。检索和去重都靠它。
  final String? subject;

  final List<String> tags;

  /// 1..5。影响注入排序和是否被淘汰。
  final int importance;

  final int createdAt;
  final int updatedAt;
  final int? lastUsedAt;
  final int useCount;

  /// 注入进 prompt 的一行。
  ///
  /// **格式必须稳定**——它是 system prompt 的一部分，一变就会打掉提示缓存。
  /// 日期只精确到天：写"三天前"这种相对说法，隔夜就变，缓存立刻全灭。
  String toIndexLine() {
    final who = (subject == null || subject!.isEmpty) ? '' : '（$subject）';
    final when = formatDay(updatedAt);
    final stamp = when.isEmpty ? '' : '[$when]';
    return '- [${kind.name}]$stamp$who $content';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'content': content,
    'subject': subject,
    'tags': tags,
    'importance': importance,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'last_used_at': lastUsedAt,
    'use_count': useCount,
  };

  static MemoryEntry fromJson(Map<String, Object?> json) => MemoryEntry(
    id: json['id'] as String,
    kind: MemoryKind.parse(json['kind'] as String?),
    content: (json['content'] as String?) ?? '',
    subject: json['subject'] as String?,
    tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
    importance: (json['importance'] as int?) ?? 3,
    createdAt: (json['created_at'] as int?) ?? 0,
    updatedAt: (json['updated_at'] as int?) ?? 0,
    lastUsedAt: json['last_used_at'] as int?,
    useCount: (json['use_count'] as int?) ?? 0,
  );

  MemoryEntry copyWith({
    String? content,
    String? subject,
    List<String>? tags,
    int? importance,
    int? updatedAt,
    int? lastUsedAt,
    int? useCount,
  }) => MemoryEntry(
    id: id,
    kind: kind,
    content: content ?? this.content,
    subject: subject ?? this.subject,
    tags: tags ?? this.tags,
    importance: importance ?? this.importance,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    useCount: useCount ?? this.useCount,
  );
}

/// `memory_save` 这一次到底发生了什么。
enum MemorySaveAction {
  /// 新存了一条。
  created,

  /// 命中了旧记忆，合并更新了它（id 不变）。
  updated,

  /// 存下了，但发现一条可能重复的旧记忆——要让模型知道，它可以选择
  /// 带 `replace_id` 重来一次把两条合成一条。
  needsReview,
}

class MemorySaveResult {
  const MemorySaveResult({
    required this.action,
    required this.entry,
    this.similar,
  });

  final MemorySaveAction action;
  final MemoryEntry entry;
  final MemoryEntry? similar;
}

/// 记忆存储。
///
/// 抽成接口有两个目的：内核不依赖 SQLite 就能跑测试；以后换存储不用动 agent。
///
/// **排序、检索、去重、淘汰都写在基类里，子类只负责存取。** 以前
/// `SqliteMemoryStore` 把打分公式照抄了一份，靠注释和测试保证两边一致——
/// 那种设计在改公式时必然分叉，而分叉只在真机上显形。现在只有一条路径。
abstract class MemoryStore {
  /// 全部记忆。条数以百千计，直接取回来在 Dart 里算足够快，
  /// 换来的是"测试环境和真机行为一模一样"。
  Future<List<MemoryEntry>> all();

  Future<void> save(MemoryEntry entry);

  Future<void> delete(String id);

  Future<int> count();

  /// 按关键词找记忆。[query] 为空时返回按重要度排的最近若干条。
  ///
  /// [track] 为真时会把命中的条目记一次"用过"（`useCount` / `lastUsedAt`）。
  /// 用户在记忆页里手动搜索应该传 `false`——那不是模型在用记忆。
  Future<List<MemoryEntry>> search(
    String query, {
    int limit = 10,
    bool track = true,
  }) async {
    final q = query.trim().toLowerCase();
    final entries = await all();
    if (q.isEmpty) {
      entries.sort(compareIndexOrder);
      return entries.take(limit).toList();
    }

    final scored = <(int, MemoryEntry)>[];
    for (final e in entries) {
      final score = scoreEntry(e, q);
      if (score > 0) scored.add((score, e));
    }
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : compareIndexOrder(a.$2, b.$2);
    });

    final hits = scored.take(limit).map((s) => s.$2).toList();
    if (track && hits.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final e in hits) {
        await save(
          e.copyWith(lastUsedAt: now, useCount: e.useCount + 1),
        );
      }
    }
    return hits;
  }

  /// 注入 system prompt 用的记忆索引。
  ///
  /// **排序必须确定性**——同样的一批记忆每次都要排出同样的顺序，否则提示缓存全灭。
  /// 规则：重要度 → 用过几次 → 更新时间 → id（兜底，保证不出现并列抖动）。
  Future<List<MemoryEntry>> index({int limit = 20}) async {
    final entries = await all();
    entries.sort(compareIndexOrder);
    return entries.take(limit).toList();
  }

  /// 存一条记忆，顺手处理"这是不是同一件事"。
  ///
  /// 三种结果：
  /// - **完全重复 / 新内容把旧内容包住了** → 直接更新旧条目（id 不变）；
  /// - **长得像但不确定** → 照样存下，同时把旧条目报回去，让模型自己决定
  ///   要不要带 `replace_id` 重来（宁多一条，不丢信息）；
  /// - **全新** → 存。
  ///
  /// [replaceId] 是模型明确说"这条旧记忆被这条新的取代了"。
  ///
  /// [maxEntries] 超过后按"最不重要、最没用过、最久没更新"淘汰，
  /// 但重要度 5 的永远不淘汰——用户亲口强调的东西不能悄悄消失。
  Future<MemorySaveResult> saveSmart(
    MemoryEntry entry, {
    String? replaceId,
    int maxEntries = 500,
  }) async {
    final entries = await all();

    if (replaceId != null) {
      for (final old in entries) {
        if (old.id == replaceId && old.kind == entry.kind) {
          final merged = _merge(old, entry);
          await save(merged);
          return MemorySaveResult(
            action: MemorySaveAction.updated,
            entry: merged,
          );
        }
      }
      // replace_id 指向一条不存在的（或类别不同、没法合并的）记忆：
      // 当没传处理，正常往下走。**不报错**——模型记错 id 不该让这次记忆丢掉。
    }

    final sameSubject = entries.where(
      (e) =>
          e.kind == entry.kind &&
          normalizeSubject(e.subject) == normalizeSubject(entry.subject),
    );

    // 1. 规范化之后一模一样 → 把时间刷新一下就算更新。
    final normalized = normalizeContent(entry.content);
    for (final old in sameSubject) {
      if (normalizeContent(old.content) == normalized) {
        final merged = _merge(old, entry, keepOldContent: true);
        await save(merged);
        return MemorySaveResult(
          action: MemorySaveAction.updated,
          entry: merged,
        );
      }
    }

    // 2. 新内容把旧内容整段包住了（"不吃香菜" → "不吃香菜和葱"）→ 更新。
    for (final old in sameSubject) {
      final oldNorm = normalizeContent(old.content);
      if (oldNorm.isNotEmpty && normalized.contains(oldNorm)) {
        final merged = _merge(old, entry);
        await save(merged);
        return MemorySaveResult(
          action: MemorySaveAction.updated,
          entry: merged,
        );
      }
    }

    // 3. 长得像但不确定。先存，再把候选报回去。
    MemoryEntry? similar;
    var best = 0.0;
    for (final old in sameSubject) {
      final s = similarity(old.content, entry.content);
      if (s >= _reviewThreshold && s > best) {
        best = s;
        similar = old;
      }
    }

    await save(entry);
    await _evictIfNeeded(maxEntries: maxEntries);

    return MemorySaveResult(
      action: similar == null
          ? MemorySaveAction.created
          : MemorySaveAction.needsReview,
      entry: entry,
      similar: similar,
    );
  }

  /// 超过上限时淘汰最不值得留的。
  ///
  /// 分两步：先按"重要度最低 → 用得最少 → 最久没动过"排序，再从最差那头删，
  /// 跳过重要度 5 的。删到上限为止；如果剩下的全是 5 分，那就让它超。
  Future<void> _evictIfNeeded({required int maxEntries}) async {
    var total = await count();
    if (total <= maxEntries) return;

    final entries = await all();
    entries.sort(compareEvictionOrder);
    for (final e in entries) {
      if (total <= maxEntries) break;
      if (e.importance >= 5) continue;
      await delete(e.id);
      total--;
    }
  }

  static MemoryEntry _merge(
    MemoryEntry old,
    MemoryEntry fresh, {
    bool keepOldContent = false,
  }) {
    final tags = <String>[...old.tags];
    for (final t in fresh.tags) {
      if (!tags.contains(t)) tags.add(t);
    }
    return old.copyWith(
      content: keepOldContent ? old.content : fresh.content,
      tags: tags.take(8).toList(),
      importance: fresh.importance > old.importance
          ? fresh.importance
          : old.importance,
      updatedAt: fresh.updatedAt,
    );
  }
}

/// 纯内存实现。测试用，也可以当作数据库没就绪时的兜底。
class InMemoryMemoryStore extends MemoryStore {
  InMemoryMemoryStore([List<MemoryEntry> seed = const []]) {
    for (final e in seed) {
      _entries[e.id] = e;
    }
  }

  final Map<String, MemoryEntry> _entries = {};

  @override
  Future<int> count() async => _entries.length;

  @override
  Future<List<MemoryEntry>> all() async => _entries.values.toList();

  @override
  Future<void> save(MemoryEntry entry) async {
    _entries[entry.id] = entry;
  }

  @override
  Future<void> delete(String id) async {
    _entries.remove(id);
  }
}

// ------------------------------------------------------------------ 排序与打分
//
// 这些是自由函数而不是某个类的私有方法：两个实现（内存 / SQLite）共用同一份，
// 测试也可以直接盯着它们。**改公式只改这里一处。**

/// 索引顺序：重要度 → 用过几次 → 更新时间 → id。
///
/// `useCount` 进来是为了让"真被想起来过的事"排在前面；它只在搜索命中时变，
/// 不随时间漂移，所以同一批数据排出来的顺序仍然稳定。
int compareIndexOrder(MemoryEntry a, MemoryEntry b) {
  final byImportance = b.importance.compareTo(a.importance);
  if (byImportance != 0) return byImportance;

  final aUses = a.useCount.clamp(0, 20);
  final bUses = b.useCount.clamp(0, 20);
  final byUses = bUses.compareTo(aUses);
  if (byUses != 0) return byUses;

  final byUpdated = b.updatedAt.compareTo(a.updatedAt);
  if (byUpdated != 0) return byUpdated;
  return a.id.compareTo(b.id);
}

/// 淘汰顺序：最该扔的排最前。
int compareEvictionOrder(MemoryEntry a, MemoryEntry b) {
  final byImportance = a.importance.compareTo(b.importance);
  if (byImportance != 0) return byImportance;

  final aUses = a.useCount.clamp(0, 20);
  final bUses = b.useCount.clamp(0, 20);
  final byUses = aUses.compareTo(bUses);
  if (byUses != 0) return byUses;

  final byUpdated = a.updatedAt.compareTo(b.updatedAt);
  if (byUpdated != 0) return byUpdated;
  return a.id.compareTo(b.id);
}

/// 关键词打分。
///
/// 中文没有空格，所以除了整串命中，还要看**二元组**：搜「猫咪」能靠单字
/// 「猫」够到「用户喜欢猫」，搜「不喜欢香菜」能靠「香菜」那一段够到。
/// 纯子串匹配修不了这两种情况，而这正是用户嘴里"它想不起来"的常见形态。
///
/// 分数绝对值不重要，排序才重要；这里多给几种信号，是为了让"更相关"的
/// 那条总能在同样命中时冒头。
int scoreEntry(MemoryEntry e, String lowercasedQuery) {
  final q = lowercasedQuery.trim();
  if (q.isEmpty) return 0;

  final haystack = [e.content, e.subject ?? '', e.tags.join(' ')]
      .join(' ')
      .toLowerCase();

  var score = 0;

  // 整串命中：最强信号。
  if (haystack.contains(q)) score += 10 + q.length;

  // 空格切开的词逐个命中（英文查询主要靠这条）。
  for (final t in q.split(RegExp(r'\s+')).where((t) => t.length >= 2)) {
    if (haystack.contains(t)) score += 3 + t.length;
  }

  final queryGrams = _grams(q);
  final hayGrams = _grams(haystack);

  // 二元组重叠（中文召回的主力）。
  var gramHits = 0;
  for (final g in queryGrams) {
    if (g.length == 2 && hayGrams.contains(g)) gramHits++;
  }
  score += gramHits * 2;

  // 单字命中：只认长字，而且要够一定比例，否则「我」「的」这种字
  // 会把整个库都捞回来。单字查询（搜「猫」）例外，直接给分。
  final chars = _cjkChars(q);
  if (chars.isNotEmpty) {
    final hitChars = chars.where((c) => haystack.contains(c)).length;
    if (chars.length == 1) {
      if (hitChars == 1) score += 3;
    } else {
      final needed = (chars.length / 2).ceil();
      if (hitChars >= needed) score += hitChars;
    }
  }

  if (score == 0) return 0;

  // 重要度做乘子，但只放大不归零。
  score += e.importance * 2;
  return score;
}

/// 两条记忆有多像（0..1）。只用来提示"可能重复"，不用来判决。
///
/// Dice 系数：2|A∩B| / (|A|+|B|)。特征同时含单字和二元组，
/// 「用户养了一只猫」和「用户养了一只狗」会得到偏高的分数——所以它只能
/// 触发一次"请模型确认"，绝不能直接合并。
double similarity(String a, String b) {
  final fa = _grams(a.toLowerCase());
  final fb = _grams(b.toLowerCase());
  if (fa.isEmpty || fb.isEmpty) return 0;
  var common = 0;
  for (final g in fa) {
    if (fb.contains(g)) common++;
  }
  return 2 * common / (fa.length + fb.length);
}

/// 只去掉空白和标点，用来判断"是不是同一句话"。
String normalizeContent(String raw) {
  final punctuation = RegExp('[\\s，。！？、,.!?;；:：\'"“”‘’（）()\\[\\]【】]+');
  return raw.toLowerCase().replaceAll(punctuation, '');
}

String normalizeSubject(String? raw) => normalizeContent(raw ?? '');

/// 把毫秒时间戳格式化成 `2026-10-17`（本地时区）。时间戳无效时返回空串。
String formatDay(int millis) {
  if (millis <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// 相似度到这一步就该提醒模型"可能重复"。低于它就不打扰。
const double _reviewThreshold = 0.55;

/// 提取匹配特征：英文/数字按词，中文按单字 + 二元组。
Set<String> _grams(String text) {
  final out = <String>{};
  for (final m in RegExp(r'[a-z0-9_]+').allMatches(text)) {
    final w = m.group(0)!;
    if (w.length >= 2) out.add(w);
  }
  for (final m in RegExp(r'[一-鿿]+').allMatches(text)) {
    final run = m.group(0)!;
    for (var i = 0; i < run.length; i++) {
      out.add(run[i]);
      if (i + 1 < run.length) out.add(run.substring(i, i + 2));
    }
  }
  return out;
}

List<String> _cjkChars(String text) =>
    RegExp(r'[一-鿿]').allMatches(text).map((m) => m[0]!).toList();
