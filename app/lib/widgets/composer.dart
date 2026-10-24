import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/n1_core.dart';
import '../design/tokens.dart';
import '../platform.dart';
import '../theme.dart';
import 'attachment_chip.dart';
import 'b64_image.dart';

/// 输入条。
///
/// 桌面端回车发送、Shift+回车换行；触屏端回车就是换行，靠右边的按钮发。
/// **两端必须区别对待**：手机上打字时手一抖碰到回车就把半句话发出去了，
/// 那是很难受的；而桌面端每句话都去够鼠标更难受。
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    required this.onStop,
    required this.running,
    this.enabled = true,
    this.hint,
    this.onPickImage,
    this.onPickFile,
    this.workLevel,
    this.onWorkLevelChanged,
    this.autoApprove = false,
    this.onAutoApproveChanged,
  });

  final void Function(
    String text,
    List<ImagePart> images,
    List<Attachment> attachments,
  )
  onSend;
  final VoidCallback onStop;

  /// 正在跑。按钮变成"停"。
  final bool running;

  /// 没有 API Key 之类的状态下禁用。
  final bool enabled;

  final String? hint;

  /// 去要一张图。返回 null 表示用户取消了。
  ///
  /// **可空是故意的**：为 null 时不显示 ＋ 按钮。测试里不传它就看不到附件入口，
  /// 于是现有那些用例一行都不用改。
  final Future<ImagePart?> Function()? onPickImage;

  /// 去要一个文本文件。返回 null 表示用户取消了。
  ///
  /// 跟 [onPickImage] 一样，为 null 就不显示文件入口。
  final Future<Attachment?> Function()? onPickFile;

  /// 当前的工作强度。**为 null 就整条不显示**——测试和别的宿主不用跟着改。
  ///
  /// 放在输入条这一层、跟着 codex 的做法：档位是"这一句话打算花多少"，
  /// 跟发送按钮是同一个决定，不该藏在设置页的第二屏里。
  final WorkLevel? workLevel;

  /// 用户挑了一档。宿主负责存起来并重建会话（数字都是建会话时抄进去的）。
  final ValueChanged<WorkLevel>? onWorkLevelChanged;

  /// 自动模式：需要确认的操作不问，直接执行。
  ///
  /// **打开时是红的**，而且跑着的时候也能点——用户想中途叫停自动模式，
  /// 不该被迫先去一趟设置页。
  final bool autoApprove;

  /// 为 null 就不显示那颗胶囊。宿主负责弹确认框和落盘；输入条只管画。
  final ValueChanged<bool>? onAutoApproveChanged;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _focused = false;
  bool _hasText = false;
  ImagePart? _image;

  /// 待发的文本文件。可以攒好几个——把一份日志和一份配置一起丢进去问，
  /// 比来回贴两遍自然。
  final List<Attachment> _attachments = [];

  bool _picking = false;

  /// 正在选的是图还是文件。选文件时不显示那个图片占位框——
  /// 空着转圈会让人以为"图还没准备好"。
  _AttachKind? _pickingWhat;

  /// 能不能往输入条里加东西。两个回调至少要有一个。
  bool get _canAttach =>
      widget.onPickImage != null || widget.onPickFile != null;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    final image = _image;
    final files = List<Attachment>.of(_attachments);
    // 图、文件、字**全**空才拦。发一张图不写字是合法的用例。
    if ((text.isEmpty && image == null && files.isEmpty) ||
        widget.running ||
        !widget.enabled) {
      return;
    }
    _controller.clear();
    // 图、文件、文字一起归零。只清文字的话，同一张图会连着发两次。
    setState(() {
      _image = null;
      _attachments.clear();
      _hasText = false;
    });
    // 按下去得有点手感。桌面端没有振动马达，调了也是空操作。
    if (!isDesktopPlatform) HapticFeedback.lightImpact();
    widget.onSend(text, image == null ? const [] : [image], files);
    // 发完把焦点要回来，方便连着说下一句。手机上没有物理键盘，
    // 但这一步会保持软键盘不收起，同样是对的。
    _focus.requestFocus();
  }

  /// 点加号。图片和文件两个入口都在时，先问他要哪个。
  Future<void> _pick() async {
    if (_picking) return;
    final hasImage = widget.onPickImage != null;
    final hasFile = widget.onPickFile != null;
    if (!hasImage && !hasFile) return;

    if (hasImage && hasFile) {
      final choice = await _askWhatToAttach();
      if (choice == null || !mounted) return;
      await _pickOne(images: choice == _AttachKind.image);
    } else {
      await _pickOne(images: hasImage);
    }
  }

  Future<_AttachKind?> _askWhatToAttach() {
    final c = N1Colors.of(context);
    return showModalBottomSheet<_AttachKind>(
      context: context,
      backgroundColor: c.raised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.lg)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.image_outlined, color: c.ink),
              title: Text('照片', style: n1Text(size: 15, color: c.ink)),
              onTap: () => Navigator.pop(sheetContext, _AttachKind.image),
            ),
            ListTile(
              leading: Icon(Icons.description_outlined, color: c.ink),
              title: Text('文件', style: n1Text(size: 15, color: c.ink)),
              subtitle: Text(
                '文本、代码、日志这类能当文字读的',
                style: n1Text(size: 12.5, color: c.faint),
              ),
              onTap: () => Navigator.pop(sheetContext, _AttachKind.file),
            ),
            const SizedBox(height: S.x2),
          ],
        ),
      ),
    );
  }

  Future<void> _pickOne({required bool images}) async {
    setState(() {
      _picking = true;
      _pickingWhat = images ? _AttachKind.image : _AttachKind.file;
    });
    try {
      if (images) {
        final picked = await widget.onPickImage?.call();
        if (picked != null && mounted) setState(() => _image = picked);
      } else {
        final picked = await widget.onPickFile?.call();
        if (picked != null && mounted) {
          setState(() {
            // 同名文件选了两次：换成新读到的那份，不留两行。
            // 留两行等于把同一段文本给模型两遍，白烧 token。
            _attachments.removeWhere((a) => a.name == picked.name);
            _attachments.add(picked);
          });
        }
      }
    } catch (e, s) {
      // 这里必须 catch，而且必须**报出去**、不能吞。
      //
      // 不 catch 的后果**不是**"异常冒到 zone 上、测试里 takeException 拿得到"——
      // 实测拿不到：`_pick` 的 future 没人接，异常走的是 zone 的
      // `handleUncaughtError`（`flutter_test/lib/src/binding.dart`），那条路
      // **直接判整条用例失败**，而 `takeException()` 读的
      // `_pendingExceptionDetails` 一直是 null。于是"输入条不崩"根本没法断言。
      //
      // `FlutterError.reportError` 是框架认的"我接住了，但要让人知道"：
      // dev 下控制台照样看得见，测试里 `takeException()` 也就拿得到。
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: s,
          library: 'niuwa_ai',
          context: ErrorDescription('选附件回调抛异常'),
        ),
      );
    } finally {
      // 不管成败都要把转圈关掉——不关的话加号会永远卡在"正在选"。
      if (mounted) {
        setState(() {
          _picking = false;
          _pickingWhat = null;
        });
      }
    }
  }

  /// 挑工作强度。跟 codex 那个一样：贴着输入条，选完立刻生效。
  Future<void> _openWorkLevel() async {
    final current = widget.workLevel;
    final onChanged = widget.onWorkLevelChanged;
    if (current == null || onChanged == null) return;

    final picked = await showModalBottomSheet<WorkLevel>(
      context: context,
      backgroundColor: N1Colors.of(context).raised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.lg)),
      ),
      builder: (sheetContext) {
        final c = N1Colors.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '工作强度',
                  style: n1Text(size: 16, weight: 600, color: c.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  '它肯为这一轮花多少 token。换档立刻生效。',
                  style: n1Text(size: 12.5, color: c.faint),
                ),
                const SizedBox(height: S.x3),
                for (final level in WorkLevel.values)
                  _WorkLevelTile(
                    level: level,
                    selected: level == current,
                    colors: c,
                    onTap: () => Navigator.pop(sheetContext, level),
                  ),
                const SizedBox(height: S.x2),
              ],
            ),
          ),
        );
      },
    );

    if (picked == null || picked == current) return;
    HapticFeedback.selectionClick();
    onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: widget.enabled,
      minLines: 1,
      maxLines: 6,
      textInputAction: TextInputAction.newline,
      keyboardType: TextInputType.multiline,
      style: n1Text(size: 15.5, height: 1.55, color: c.ink),
      cursorColor: c.accentInk,
      cursorWidth: 1.6,
      cursorRadius: const Radius.circular(1),
      decoration: InputDecoration(
        hintText: widget.hint ?? '说点什么…',
        hintStyle: n1Text(size: 15.5, height: 1.55, color: c.faint),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: S.x2,
          vertical: S.x4,
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: S.x4,
        vertical: S.x3,
      ),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(R.lg),
        border: Border.all(
          // 聚焦时描边转成主色。整个输入区只有这一处变色，安静但明确。
          color: _focused ? c.accentInk : c.lineStrong,
          width: _focused ? 1.5 : 1,
        ),
        boxShadow: _focused ? c.elevation : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 预览条和输入行在**同一个** Container 里，那圈描边才会把两者一起框住。
          if (_image != null || _pickingWhat == _AttachKind.image) ...[
            _PendingImage(
              picked: _image,
              picking: _pickingWhat == _AttachKind.image,
              colors: c,
              onRemove: () => setState(() => _image = null),
            ),
            const SizedBox(height: S.x3),
          ],
          if (_attachments.isNotEmpty) ...[
            _PendingFiles(
              attachments: _attachments,
              colors: c,
              onRemove: (a) => setState(() => _attachments.remove(a)),
            ),
            const SizedBox(height: S.x3),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 跑着的时候不给攒附件：这时候按了也发不出去。
              if (_canAttach && !widget.running) ...[
                _AttachButton(
                  active: !_picking,
                  onTap: _pick,
                  colors: c,
                ),
                const SizedBox(width: S.x2),
              ],
              Expanded(
                child: isDesktopPlatform
                    ? Shortcuts(
                        shortcuts: const {
                          SingleActivator(LogicalKeyboardKey.enter):
                              _SendIntent(),
                        },
                        child: Actions(
                          actions: {
                            _SendIntent: CallbackAction<_SendIntent>(
                              onInvoke: (_) {
                                _submit();
                                return null;
                              },
                            ),
                          },
                          child: field,
                        ),
                      )
                    : field,
              ),
              const SizedBox(width: S.x3),
              _ActionButton(
                running: widget.running,
                // 跑着的时候"停"永远可点——哪怕输入框是空的，用户就是想打断它。
                // 有图或有文件也算"有内容"，这时候发送按钮该亮着。
                active: widget.running ||
                    ((_hasText || _image != null || _attachments.isNotEmpty) &&
                        widget.enabled),
                onTap: widget.running ? widget.onStop : _submit,
                colors: c,
              ),
            ],
          ),
          // 档位行。只占一行、贴着输入框右下角，安静但随时摸得到。
          if (widget.workLevel != null ||
              widget.onAutoApproveChanged != null) ...[
            const SizedBox(height: S.x2),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onAutoApproveChanged != null) ...[
                    _AutoChip(
                      on: widget.autoApprove,
                      colors: c,
                      onTap: () =>
                          widget.onAutoApproveChanged!(!widget.autoApprove),
                    ),
                    if (widget.workLevel != null) const SizedBox(width: 6),
                  ],
                  if (widget.workLevel != null)
                    _WorkLevelChip(
                      level: widget.workLevel!,
                      colors: c,
                      enabled: !widget.running,
                      onTap: _openWorkLevel,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

enum _AttachKind { image, file }

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.running,
    required this.active,
    required this.onTap,
    required this.colors,
  });

  final bool running;
  final bool active;
  final VoidCallback onTap;
  final N1Colors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    const size = 36.0;

    return Semantics(
      button: true,
      label: running ? '停止' : '发送',
      child: GestureDetector(
        onTap: active ? onTap : null,
        child: AnimatedContainer(
          duration: M.fast,
          curve: M.out,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: active ? kAccent : c.line,
            shape: BoxShape.circle,
          ),
          child: AnimatedSwitcher(
            duration: M.fast,
            switchInCurve: M.out,
            switchOutCurve: M.out,
            // 默认的 AnimatedSwitcher 会让新旧两个子叠着做淡入淡出，
            // 在这个尺寸下看起来是"糊"的。缩放一下才像"变形"。
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: running
                ? Center(
                    key: const ValueKey('stop'),
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  )
                : const Icon(
                    Icons.arrow_upward_rounded,
                    key: ValueKey('send'),
                    size: 19,
                    color: Colors.white,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 左下角那个加号。
class _AttachButton extends StatelessWidget {
  const _AttachButton({
    required this.active,
    required this.onTap,
    required this.colors,
  });

  final bool active;
  final VoidCallback onTap;
  final N1Colors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Semantics(
      button: true,
      label: '添加附件',
      child: GestureDetector(
        onTap: active ? onTap : null,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: c.line,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.add_rounded,
            size: 20,
            color: active ? c.ink : c.faint,
          ),
        ),
      ),
    );
  }
}

/// 输入条右下角那个档位胶囊。
///
/// 只显示档位名，不显示解释——解释在点开之后。常驻一行说明会把输入区撑高，
/// 而这一行 90% 的时间没人看。
class _WorkLevelChip extends StatelessWidget {
  const _WorkLevelChip({
    required this.level,
    required this.colors,
    required this.enabled,
    required this.onTap,
  });

  final WorkLevel level;
  final N1Colors colors;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Semantics(
      button: true,
      label: '工作强度：${level.label}，点一下换档',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.fromLTRB(S.x2, 3, 6, 3),
          decoration: BoxDecoration(
            color: c.line,
            borderRadius: BorderRadius.circular(R.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bolt_rounded,
                size: 13,
                color: enabled ? c.accentInk : c.faint,
              ),
              const SizedBox(width: 3),
              Text(
                level.label,
                style: n1Text(
                  size: 11.5,
                  color: enabled ? c.dim : c.faint,
                ),
              ),
              Icon(Icons.expand_more_rounded, size: 13, color: c.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自动模式那颗胶囊。
///
/// 两种状态差别做得大：关着的时候跟工作强度一样安静，开着的时候是**红的**，
/// 带一圈描边。它不该看起来像一次普通的设置——用户扫一眼输入条就知道
/// "现在它删东西不会问我"。
class _AutoChip extends StatelessWidget {
  const _AutoChip({
    required this.on,
    required this.colors,
    required this.onTap,
  });

  final bool on;
  final N1Colors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Semantics(
      button: true,
      label: on ? '自动模式已开：危险操作不再确认，点一下关掉' : '自动模式：关，点一下打开',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: 3),
          decoration: BoxDecoration(
            color: on ? c.danger.withValues(alpha: 0.12) : c.line,
            borderRadius: BorderRadius.circular(R.sm),
            border: on
                ? Border.all(color: c.danger.withValues(alpha: 0.35))
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                on ? Icons.auto_awesome_rounded : Icons.auto_awesome_outlined,
                size: 13,
                color: on ? c.danger : c.faint,
              ),
              const SizedBox(width: 3),
              Text(
                on ? '自动·已开' : '自动',
                style: n1Text(size: 11.5, color: on ? c.danger : c.faint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹层里的一档。
class _WorkLevelTile extends StatelessWidget {
  const _WorkLevelTile({
    required this.level,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final WorkLevel level;
  final bool selected;
  final N1Colors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(R.md),
      child: Container(
        margin: const EdgeInsets.only(bottom: S.x2),
        padding: const EdgeInsets.fromLTRB(S.x3, S.x3, S.x3, S.x3),
        decoration: BoxDecoration(
          color: selected ? c.accentWash : Colors.transparent,
          borderRadius: BorderRadius.circular(R.md),
          border: Border.all(
            color: selected ? c.accentInk.withValues(alpha: 0.35) : c.line,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    level.label,
                    style: n1Text(
                      size: 14.5,
                      weight: selected ? 600 : 400,
                      color: c.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    level.summary,
                    style: n1Text(size: 12, height: 1.55, color: c.dim),
                  ),
                ],
              ),
            ),
            const SizedBox(width: S.x3),
            // 选中的那档给个明确的勾，别只靠底色——底色在暗色主题里很淡。
            Icon(
              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 18,
              color: selected ? c.accentInk : c.lineStrong,
            ),
          ],
        ),
      ),
    );
  }
}

/// 待发的几个文件。挤成一排、放不下的自动换行。
class _PendingFiles extends StatelessWidget {
  const _PendingFiles({
    required this.attachments,
    required this.colors,
    required this.onRemove,
  });

  final List<Attachment> attachments;
  final N1Colors colors;
  final void Function(Attachment) onRemove;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: S.x2,
      runSpacing: S.x2,
      children: [
        for (final a in attachments)
          // key 用名字：去掉中间一个时，剩下的标签不能互相串位。
          AttachmentChip(
            key: ValueKey('pending-${a.name}'),
            attachment: a,
            onRemove: () => onRemove(a),
          ),
      ],
    );
  }
}

/// 待发的那张图。压好之前先占个位转圈。
class _PendingImage extends StatelessWidget {
  const _PendingImage({
    required this.picked,
    required this.picking,
    required this.colors,
    required this.onRemove,
  });

  final ImagePart? picked;
  final bool picking;
  final N1Colors colors;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 64,
          height: 64,
          child: picking
              ? Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.accentInk,
                    ),
                  ),
                )
              : (picked == null
                  ? const SizedBox.shrink()
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(R.sm),
                      // ⚠️ 这里**必须**用 `B64Image`（Task 5 那个带缓存的），
                      // 不能直接写 `Image.memory(base64Decode(...))`。
                      //
                      // 直觉会说"待发预览是一次性的小控件，不用管缓存"——**错的**。
                      // `_ComposerState` 的 `_hasText` 监听器每敲一个字就 setState，
                      // 也就是输入框每变一次整条输入区就重建一次。每重建一次就
                      // 造一个新的 `Uint8List`，而 `ImageCache` 拿字节数组的相等性
                      // 当 key——新旧不相等，判定为新图，**重新解码一遍**。
                      // 打一句二十个字的话，这张预览图就被解码了二十遍。
                      //
                      // 在 Task 5 那套 `B64Image` 上加个 `fit` 参数就行，
                      // 不用另写一个。
                      child: B64Image(
                        base64Data: picked!.base64Data,
                        fit: BoxFit.cover,
                      ),
                    )),
        ),
        if (picked != null) ...[
          const SizedBox(width: S.x2),
          Semantics(
            button: true,
            label: '去掉这张图',
            child: GestureDetector(
              onTap: onRemove,
              child: Icon(
                Icons.close_rounded,
                key: const ValueKey('remove-image'),
                size: 18,
                color: c.faint,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
