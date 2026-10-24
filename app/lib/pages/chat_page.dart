import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';
import '../core/n1_core.dart';
import '../design/tokens.dart';
import '../models/chat_item.dart';
import '../platform.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/attachment_intake.dart';
import '../services/image_intake.dart';
import '../theme.dart';
import '../widgets/auto_approve_dialog.dart';
import '../widgets/composer.dart';
import '../widgets/message_view.dart';
import '../widgets/n1_mark.dart';
import '../widgets/todo_strip.dart';
import '../widgets/tool_approval_dialog.dart';

/// 聊天页。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, this.onOpenSettings});

  /// 没配 Key 时引导用户去设置。
  final VoidCallback? onOpenSettings;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scroll = ScrollController();

  /// 是不是"贴着底"。用户往上翻看历史时置 false，滚回底部再置 true。
  ///
  /// 没有这个开关的话，用户正在往回读的时候模型吐了一个字，滚动条就会把他
  /// 拽到底部——这是聊天界面最招人烦的毛病之一。
  bool _stick = true;

  final _intake = ImageIntake();

  /// 换掉 Composer 的 key 就让它从零重建。
  ///
  /// 为什么需要：待发的图存在 Composer 自己的 state 里，而清空对话走的是
  /// `chat.clear()` —— provider 和 Composer 是同一棵树里的**兄弟节点**，
  /// 清空传不到它。不换 key 的话，清完对话输入框上还挂着一张待发的图。
  int _composerGeneration = 0;

  /// 已经为哪一次审批开过弹窗了。
  ///
  /// 判据是**对象本身**而不是"有没有在等"：`build` 会跑很多遍，只看
  /// `pendingApproval != null` 的话每一遍都会再弹一个出来，叠成一摞。
  ToolApprovalRequest? _asking;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// 用户翻上去了，给他一个"回到最新"的按钮。
  bool _showJump = false;

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // 40 的容差：触屏上"到底"很难精确，差几个像素就判定为没贴底的话，
    // 自动滚动会时灵时不灵。
    final stick = pos.pixels >= pos.maxScrollExtent - 40;
    if (stick == _stick) return;
    _stick = stick;
    // 只在状态真的翻转时 setState——滚动监听每秒来几十次，每次都 setState
    // 等于自己给自己制造卡顿。
    if (mounted) setState(() => _showJump = !stick);
  }

  void _jumpToLatest() {
    _stick = true;
    setState(() => _showJump = false);
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// 内容变了之后把视图带到最新处。
  ///
  /// 放在 post-frame 里：这一刻布局还没算完，`maxScrollExtent` 还是旧值，
  /// 直接滚会永远差一截。
  void _followIfSticky() {
    if (!_stick) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      // jumpTo 而不是 animateTo：流式输出时这个方法每几十毫秒就被调一次，
      // 动画还没跑完就被下一次打断，反而是一顿一顿的。直接跳到最新的位置
      // 才是连续的。
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _confirmClear(ChatProvider chat) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空对话？'),
        content: const Text('聊天记录会删掉。它记住的关于你的事不会动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清空', style: TextStyle(color: N1Colors.of(ctx).danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await chat.clear();
      // `clear()` 是异步的，await 回来的时候这一页可能已经不在树上了。
      // 少了这句就是 setState-after-dispose 的 FlutterError。
      if (!mounted) return;
      // 换掉 key，Composer 从零重建，待发的那张图跟着没。
      setState(() => _composerGeneration++);
    }
  }

  /// 要一张图。返回 null 表示用户取消，或者出错了（已经提示过）。
  ///
  /// 失败处理**全在这里**，Composer 那边只负责显示和删除。这样 Composer
  /// 在测试里不需要 mock 任何插件。
  Future<ImagePart?> _pickImage() async {
    final source = await _chooseImageSource();
    if (source == null) return null;

    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        // 安卓那边这三个参数是**原生实现**：`ImageResizer.java` 用
        // `inSampleSize` 采样解码，不把整张图铺成位图（一张 12MP 的照片
        // 铺开是 48MB），再用原生 compress 编码。手机上正常的一张照片
        // 会压到 200KB 上下，根本轮不到纯 Dart 出手。
        //
        // ⚠️ Windows 那边会**静默忽略**这三个参数（`image_picker_windows`
        // 的源码里三处注释写明了），拿回来永远是原图。真正的兜底在
        // ImageIntake 里，不在这里。
        maxWidth: kMaxEdge.toDouble(),
        maxHeight: kMaxEdge.toDouble(),
        imageQuality: kQuality,
      );
      if (picked == null) return null; // 用户取消
      return await _intake.prepare(picked);
    } on ImageIntakeException catch (e) {
      // 内核给的就是人话，直接说。
      _toast(e.message);
      return null;
    } catch (e) {
      _toast('选图出了点问题，再试一次。');
      debugPrint('[pick] 选图失败：$e');
      return null;
    }
  }

  /// 要一个文本文件。返回 null 表示取消或出错（已经提示过）。
  ///
  /// 跟 [_pickImage] 一样，失败处理全在这里，Composer 不碰异常。
  Future<Attachment?> _pickFile() async {
    try {
      final file = await openFile();
      if (file == null) return null; // 用户取消
      return await const AttachmentIntake().prepare(file);
    } on AttachmentIntakeException catch (e) {
      _toast(e.message);
      return null;
    } catch (e) {
      _toast('读这个文件出了点问题，换一个试试。');
      debugPrint('[pick] 读文件失败：$e');
      return null;
    }
  }

  /// 问用户从哪来。
  ///
  /// 桌面端**不弹菜单**：只有一个选项的菜单是无谓的一次点击，而且 Windows
  /// 上根本没有相机——`image_picker_windows` 的相机分支会抛 StateError
  /// （除非自己塞一个 cameraDelegate）。
  Future<ImageSource?> _chooseImageSource() async {
    if (isDesktopPlatform) return ImageSource.gallery;

    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍一张'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  /// 换工作强度。
  ///
  /// 这几个数字都是**建会话那一刻**抄进去的（回合数在 AgentLoop 上、
  /// 工具结果上限在注册表上、记忆索引在 PromptBuilder 上）。
  /// 不重建会话的话，换完档下一句还是老样子，看起来就像开关坏了。
  void _setWorkLevel(WorkLevel level, ChatProvider chat) {
    context.read<SettingsProvider>().setWorkLevel(level);
    chat.resetSession();
  }

  /// 开/关自动模式。
  ///
  /// **打开要先过一道确认框**，关掉不问。「输入条上那颗胶囊」和「设置页那个
  /// 开关」都走这里，所以两条路的措辞和后果完全一致。
  ///
  /// 不重建会话：`askUser` 每次现读设置，改完当下就生效。
  Future<void> _setAutoApprove(bool value) async {
    final settings = context.read<SettingsProvider>();
    if (!value) {
      await settings.setAutoApprove(false);
      return;
    }

    if (!await confirmAutoApprove(context) || !mounted) return;
    await settings.setAutoApprove(true);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 有工具在等确认就弹窗。`build` 里调，所以**不能直接开弹窗**
  /// （在建树的过程中改导航栈会炸），得挪到 post-frame。
  void _syncApproval(ChatProvider chat) {
    final request = chat.pendingApproval;
    if (request == null) {
      _asking = null;
      return;
    }
    if (identical(request, _asking)) return;
    _asking = request;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _openApproval(chat, request),
    );
  }

  Future<void> _openApproval(
    ChatProvider chat,
    ToolApprovalRequest request,
  ) async {
    // 等到真正执行的时候这件事可能已经有结果了（用户按了停、超时）。
    // 不看这一眼的话会弹出一个"点了也没用"的窗。
    if (!mounted || !identical(chat.pendingApproval, request)) return;

    final approved = await showDialog<bool>(
      context: context,
      // **不点按钮就不走**。点外面或按返回键关掉的话，`showDialog` 回的是
      // null，下面按"拒绝"处理——含糊的关掉一律当成"不要"，
      // 因为这是唯一安全的一边。
      barrierDismissible: false,
      builder: (ctx) => Consumer<ChatProvider>(
        builder: (ctx, c, _) {
          // 等待被别处收掉了（超时 / 这一轮被停 / 出错）。**弹窗得自己关掉**：
          // 留着的话用户点哪个按钮都不起作用，看起来像是 App 卡了。
          if (c.pendingApproval == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              // **不能直接 pop。** 用户点了按钮时弹窗已经在退场，再 pop 一次
              // 弹掉的是底下的聊天页（窗口全黑）。判栈顶的活儿交给它。
              closeApprovalDialogIfCurrent(ctx);
            });
          }
          return ToolApprovalDialog(request: request);
        },
      ),
    );

    chat.resolveApproval(approved: approved == true);
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    // 工作强度也在这里看：档位胶囊就在输入条上，得跟着选择立刻变。
    final settings = context.watch<SettingsProvider>();
    final c = N1Colors.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    _followIfSticky();
    _syncApproval(chat);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        titleSpacing: wide ? S.x6 : S.x4,
        title: const _Title(),
        actions: [
          if (chat.items.isNotEmpty)
            IconButton(
              tooltip: '清空对话',
              onPressed: () => _confirmClear(chat),
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
          const SizedBox(width: S.x2),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                _body(chat, c, wide),
                // 翻上去看历史的时候它才出现。浮在列表右下角，不挡正文。
                AnimatedSlide(
                  offset: _showJump ? Offset.zero : const Offset(0, 0.4),
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: _showJump ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: IgnorePointer(
                      ignoring: !_showJump,
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: wide ? S.x6 : S.x4,
                            bottom: S.x3,
                          ),
                          child: _JumpToLatest(onTap: _jumpToLatest),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (chat.error != null) _ErrorBanner(chat: chat),
          Padding(
            padding: EdgeInsets.fromLTRB(
              wide ? S.x6 : S.x4,
              0,
              wide ? S.x6 : S.x4,
              S.x4,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (chat.todos.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: S.x2),
                        child: TodoStrip(items: chat.todos),
                      ),
                    Composer(
                      key: ValueKey(_composerGeneration),
                      running: chat.running,
                      hint: chat.items.isEmpty ? '随便说点什么…' : null,
                      onSend: (text, images, attachments) => chat.send(
                        text,
                        images: images,
                        attachments: attachments,
                      ),
                      onPickImage: _pickImage,
                      onPickFile: _pickFile,
                      onStop: chat.stop,
                      workLevel: settings.workLevel,
                      onWorkLevelChanged: (level) =>
                          _setWorkLevel(level, chat),
                      autoApprove: settings.autoApprove,
                      onAutoApproveChanged: _setAutoApprove,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ChatProvider chat, N1Colors c, bool wide) {
    if (chat.loading) {
      return Center(
        child: N1Mark(size: 40, color: c.lineStrong),
      );
    }

    if (chat.items.isEmpty) return _EmptyState(onOpenSettings: widget.onOpenSettings);

    final pad = wide ? S.x6 : S.x4;

    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(pad, S.x4, pad, S.x5),
      itemCount: chat.items.length,
      itemBuilder: (context, i) {
        final item = chat.items[i];
        return Padding(
          // 用户消息跟上面拉开得多一点，形成"一轮"的分组感；
          // assistant 内部的元素之间只留一点点。
          padding: EdgeInsets.only(
            top: i == 0 ? 0 : (item is UserItem ? S.x7 : S.x5),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: MessageView(item: item),
            ),
          ),
        );
      },
    );
  }
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const N1Mark(size: 22),
        const SizedBox(width: S.x3),
        Text(
          appName,
          style: n1Text(size: 17, weight: 600, color: c.ink, height: 1.2),
        ),
      ],
    );
  }
}

/// 第一次打开时的样子。这里要一眼说清"这是个什么、下一步干什么"。
class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final hasKey = context.watch<SettingsProvider>().hasKey;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(S.x8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              N1Mark(size: 64, color: c.lineStrong),
              const SizedBox(height: S.x7),
              Text(
                '我在这儿',
                style: n1Text(
                  size: 22,
                  weight: 600,
                  color: c.ink,
                  height: 1.3,
                  tracking: -0.02,
                ),
              ),
              const SizedBox(height: S.x3),
              Text(
                hasKey
                    ? '想说什么都行。也可以让我去查点东西、记点事。'
                    : '先去设置里填一个 API Key，我就能开口了。',
                textAlign: TextAlign.center,
                style: n1Text(size: 14, height: 1.7, color: c.dim),
              ),
              if (!hasKey) ...[
                const SizedBox(height: S.x7),
                FilledButton(
                  onPressed: onOpenSettings,
                  child: const Text('去设置'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// "回到最新"。
///
/// 没有它的时候，模型还在吐字、用户又往上翻了两屏，就只能自己一路划回来。
/// 这枚按钮只在用户离开底部时出现，贴底时完全隐形。
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    return Semantics(
      button: true,
      label: '回到最新',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: c.raised,
            shape: BoxShape.circle,
            border: Border.all(color: c.lineStrong),
            boxShadow: c.elevation,
          ),
          child: Icon(
            Icons.arrow_downward_rounded,
            size: 18,
            color: c.accentInk,
          ),
        ),
      ),
    );
  }
}

/// 出错时贴在输入条上方的一条。不弹窗——弹窗要用户点掉才能继续，
/// 而这类错误（网络、限流）往往过一会儿自己就好了。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.chat});

  final ChatProvider chat;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(S.x6, 0, S.x6, S.x3),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Container(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x3, S.x3),
            decoration: BoxDecoration(
              color: c.danger.withValues(alpha: 0.08),
              borderRadius: R.smAll,
              border: Border.all(color: c.danger.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: c.danger),
                const SizedBox(width: S.x3),
                Expanded(
                  child: Text(
                    chat.error!,
                    style: n1Text(size: 12.5, height: 1.5, color: c.danger),
                  ),
                ),
                if (chat.canRetry)
                  TextButton(
                    onPressed: chat.retry,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: S.x3),
                    ),
                    child: const Text('重试'),
                  ),
                IconButton(
                  tooltip: '知道了',
                  onPressed: chat.dismissError,
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                  color: c.danger,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
