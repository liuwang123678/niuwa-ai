import 'dart:typed_data';

import 'package:niuwa_ai/core/n1_core.dart';

/// 造一个快照，参数按需给。
BrowserSnapshot fakeSnapshot({
  String url = 'https://example.com/',
  String title = '示例页',
  String text = '正文',
  String note = '',
  List<BrowserNode> nodes = const [],
}) => BrowserSnapshot(
  url: url,
  title: title,
  nodes: nodes,
  text: text,
  note: note,
);

/// 假的浏览器驱动：**记录收到了什么**，按剧本回什么。
///
/// 存在的理由：浏览器链路原来一行测试都没有。没有它，"工具确实把 ref 传给了
/// 驱动""驱动重拍了快照"这些话就只能靠读代码相信，改坏了也不会有人发现。
///
/// [snapshots] 是队列——每次 [snapshot] 取一个，取完就一直重复最后一个。
/// 这样就能表达"点之前是 A 页、点之后是 B 页"。
class FakeBrowserDriver extends BrowserDriver {
  FakeBrowserDriver({
    this.available = true,
    this.unavailableReason,
    this.canWarmUp = false,
    this.becomeAvailableOnWarmUp = false,
    List<BrowserSnapshot> snapshots = const [],
    this.screenshotBytes,
    Set<String> staleRefs = const <String>{},
    this.failWith,
  }) : _snapshots = [...snapshots],
       _staleRefs = {...staleRefs};

  /// 可以中途改——模拟"浏览器被用户关掉了"。
  bool available;

  /// 这个驱动所在的平台有没有浏览器能力（`supportsWarmUp`）。
  final bool canWarmUp;

  /// 预热一次就变成可用——模拟 Windows 上"Edge 拉起来了"。
  final bool becomeAvailableOnWarmUp;

  @override
  bool get supportsWarmUp => canWarmUp;

  @override
  String? unavailableReason;

  /// 非 null 时每个方法都抛它。用来测"驱动活着但操作失败"这条分支。
  final BrowserException? failWith;

  /// 截图返回什么。默认 null → 空字节，模拟"这个平台截不了"。
  Uint8List? screenshotBytes;

  final List<BrowserSnapshot> _snapshots;
  final Set<String> _staleRefs;

  // ── 收到的调用 ──────────────────────────────────────────────
  final List<String> opened = [];
  final List<String> clicked = [];
  final List<(String ref, String text)> typed = [];
  final List<ScrollDirection> scrolled = [];
  int warmUpCount = 0;
  int backCount = 0;
  int screenshotCount = 0;
  int snapshotCount = 0;

  BrowserSnapshot? _last;

  @override
  bool get isAvailable => available;

  @override
  Future<void> warmUp() async {
    warmUpCount++;
    if (becomeAvailableOnWarmUp) available = true;
  }

  void _guard() {
    final boom = failWith;
    if (boom != null) throw boom;
  }

  void _checkRef(String ref) {
    if (_staleRefs.contains(ref)) {
      throw BrowserException('编号 $ref 已经失效了，重新 browser_snapshot 一次再操作。');
    }
  }

  @override
  Future<void> open(String url) async {
    _guard();
    opened.add(url);
  }

  @override
  Future<BrowserSnapshot> snapshot() async {
    _guard();
    snapshotCount++;
    if (_snapshots.isNotEmpty) {
      _last = _snapshots.removeAt(0);
    }
    return _last ?? fakeSnapshot();
  }

  @override
  Future<void> click(String ref) async {
    _guard();
    _checkRef(ref);
    clicked.add(ref);
  }

  @override
  Future<void> type(String ref, String text) async {
    _guard();
    _checkRef(ref);
    typed.add((ref, text));
  }

  @override
  Future<void> scroll(ScrollDirection direction, {double amount = 0.8}) async {
    _guard();
    scrolled.add(direction);
  }

  @override
  Future<Uint8List> screenshot() async {
    _guard();
    screenshotCount++;
    return screenshotBytes ?? Uint8List(0);
  }

  @override
  Future<void> back() async {
    _guard();
    backCount++;
  }

  @override
  Future<void> dispose() async {}
}
