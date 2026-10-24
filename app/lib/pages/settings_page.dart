import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';
import '../core/agent/work_level.dart';
import '../core/mcp/mcp_config.dart';
import '../design/tokens.dart';
import '../platform.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/skills_provider.dart';
import '../theme.dart';
import '../widgets/auto_approve_dialog.dart';
import '../widgets/model_picker_dialog.dart';
import '../widgets/n1_mark.dart';

/// 设置页。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final s = context.watch<SettingsProvider>();

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(S.x6, S.x2, S.x6, S.x8),
            children: [
              const _SectionLabel('接哪家模型'),
              _ModelCard(settings: s),
              const SizedBox(height: S.x7),

              const _SectionLabel('它是什么样'),
              _PersonaCard(settings: s),
              const SizedBox(height: S.x7),

              const _SectionLabel('对话'),
              _ConversationCard(settings: s),
              const SizedBox(height: S.x7),

              const _SectionLabel('工作强度'),
              _WorkLevelCard(settings: s),
              const SizedBox(height: S.x7),

              const _SectionLabel('自动模式'),
              _AutoApproveCard(settings: s),
              const SizedBox(height: S.x7),

              const _SectionLabel('它能碰你电脑上的什么'),
              _AccessCard(settings: s),
              const SizedBox(height: S.x7),

              const _SectionLabel('外接工具（MCP）'),
              _McpCard(settings: s),
              const SizedBox(height: S.x7),

              const _SectionLabel('关于'),
              const _AboutCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: S.x1, bottom: S.x3),
    child: Text(
      text,
      style: n1Text(
        size: 12,
        color: N1Colors.of(context).dim,
        height: 1.3,
      ).n1W(600),
    ),
  );
}

/// 卡片外壳。三个设置卡片长得一样，抽出来免得每处重复一遍装饰代码。
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(S.x5),
    decoration: N1Colors.of(context).surface(radius: R.md, outline: true),
    child: child,
  );
}

// ══════════════════════════════════════════════════════════════════
// 接哪家模型
// ══════════════════════════════════════════════════════════════════

/// 供应商 + 接口地址 + 模型名 + API Key。
///
/// **两个输入框的状态放在 State 里，不是每次 build 从设置里现取。** 因为：
/// 每敲一个字就写回设置，设置一写回就通知重建；如果输入框的内容跟着重建
/// 重新赋值，光标会被顶到末尾——中文打一半时基本没法用。
///
/// 只有**真的换了供应商**才重填输入框（那时候本来就该整片换掉）。
class _ModelCard extends StatefulWidget {
  const _ModelCard({required this.settings});

  final SettingsProvider settings;

  @override
  State<_ModelCard> createState() => _ModelCardState();
}

class _ModelCardState extends State<_ModelCard> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;

  /// 上一次看到的供应商 id。用来区分"真的换了一家"和"别的设置变了导致的
  /// 重建"——后者不该动用户已经打进去的字。
  late String _providerId;

  @override
  void initState() {
    super.initState();
    _providerId = widget.settings.providerId;
    _baseUrl = TextEditingController(text: widget.settings.baseUrl);
    _model = TextEditingController(text: widget.settings.model);
    widget.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    final id = widget.settings.providerId;
    if (id == _providerId) return;
    _providerId = id;
    _baseUrl.text = widget.settings.baseUrl;
    _model.text = widget.settings.model;
  }

  /// 换了供应商 / 换了模型 / 换了地址之后，旧会话手里还攥着上一套配置，
  /// 必须丢掉重建，否则「设置改完了，说的还是老样子」。
  void _invalidateSession() => context.read<ChatProvider>().resetSession();

  Future<void> _changeProvider(String id) async {
    await widget.settings.selectProvider(id);
    if (!mounted) return;
    _invalidateSession();
  }

  /// 拉一次这个平台的模型列表，拉到了就摆出来让用户挑。
  ///
  /// 失败**不做成弹窗**，而是留在卡片里一行红字（`modelListError`）：拉不到
  /// 是个会反复发生的事（网络、Key、平台没这条接口），弹窗要点掉才能继续，
  /// 而用户这时候多半只是想接着手填。
  Future<void> _fetchModelList() async {
    final s = widget.settings;
    await s.fetchModels();
    if (!mounted || !s.hasFetchedModels) return;

    final picked = await showDialog<String>(
      context: context,
      builder: (_) => ModelPickerDialog(
        models: s.fetchedModels,
        current: s.model,
      ),
    );
    if (picked == null || !mounted) return;
    await _applyPickedModel(picked);
  }

  /// 挑完落回**那个可编辑的输入框**，而不是锁成只读的下拉。
  ///
  /// 列表是平台自己给的、我们没验证过，所以它只能是个建议：落进输入框之后
  /// 用户照样能改，改成列表里没有的名字也不拦着。
  Future<void> _applyPickedModel(String model) async {
    _model.text = model;
    await widget.settings.setModel(model);
    if (!mounted) return;
    _invalidateSession();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('模型名已换成 $model')));
  }

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final s = widget.settings;
    final provider = s.provider;
    final has = s.hasKey;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            // 跟着 id 重建，免得表单里留着上一家的值。
            key: ValueKey(s.providerId),
            initialValue: s.providerId,
            decoration: const InputDecoration(
              labelText: '供应商',
              isDense: true,
            ),
            items: [
              for (final p in s.providers)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (v) {
              if (v != null && v != s.providerId) _changeProvider(v);
            },
          ),
          const SizedBox(height: S.x4),

          _LabeledField(
            label: '接口地址',
            controller: _baseUrl,
            // 预置那几家的地址是固定的，做成只读——让人看得见正在用哪个，
            // 又不会出现"地址改了但还是那家"这种说不清的状态。
            // 想自己改地址就选「自定义」。
            enabled: provider.isCustom,
            hint: 'https://…/v1',
            onChanged: provider.isCustom
                ? (v) {
                    s.setBaseUrl(v);
                    _invalidateSession();
                  }
                : null,
          ),
          const SizedBox(height: S.x4),

          _LabeledField(
            label: '模型名',
            controller: _model,
            hint: '填平台给你的模型名',
            onChanged: (v) {
              s.setModel(v);
              _invalidateSession();
            },
          ),
          const SizedBox(height: S.x2),
          Text(
            '模型名各家会更新，用了退役的旧名字接口会回「模型不存在」。'
            '换完先发一句话试试，报错就去对应平台的官网查当前的名字。',
            style: n1Text(size: 12, height: 1.6, color: c.faint),
          ),
          const SizedBox(height: S.x3),
          _ModelListRow(settings: s, onFetch: _fetchModelList),
          if (s.modelListError case final error?) ...[
            const SizedBox(height: S.x2),
            Text(
              error,
              style: n1Text(size: 12.5, height: 1.6, color: c.danger),
            ),
          ],

          const Divider(height: S.x8),

          Row(
            children: [
              Icon(
                has ? Icons.check_circle_outline : Icons.key_outlined,
                size: 18,
                color: has ? c.accentInk : c.faint,
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Text(
                  s.keyLoading
                      ? '读取中…'
                      : has
                      ? 'Key 已设置（${s.keyLength} 位）'
                      : '还没设置 Key',
                  style: n1Text(
                    size: 14.5,
                    height: 1.4,
                    color: c.ink,
                  ).n1W(500),
                ),
              ),
            ],
          ),
          const SizedBox(height: S.x3),
          Text(
            '每家一个 Key，换供应商不会把原来那家的冲掉。'
            'Key 存在系统的安全存储里（安卓走 Keystore，桌面走系统凭据库），'
            '不会写进聊天记录，也不会跟着 App 数据一起被拷走。',
            style: n1Text(size: 12.5, height: 1.65, color: c.dim),
          ),
          if (s.keyUrl != null) ...[
            const SizedBox(height: S.x2),
            SelectableText(
              '在这申请：${s.keyUrl}',
              style: n1Text(size: 12, height: 1.6, color: c.accentInk),
            ),
          ],
          if (s.keyError != null) ...[
            const SizedBox(height: S.x3),
            Text(
              s.keyError!,
              style: n1Text(size: 12.5, height: 1.6, color: c.danger),
            ),
          ],
          const SizedBox(height: S.x4),
          Row(
            children: [
              FilledButton(
                onPressed: _edit,
                child: Text(has ? '换一个' : '填一个'),
              ),
              if (has) ...[
                const SizedBox(width: S.x3),
                TextButton(
                  onPressed: _confirmClear,
                  child: Text('清除', style: TextStyle(color: c.danger)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _edit() async {
    final controller = TextEditingController();
    final providerName = widget.settings.provider.name;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('填 $providerName 的 API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              style: n1Text(size: 14, height: 1.4),
              decoration: const InputDecoration(hintText: '粘贴 Key', isDense: true),
            ),
            if (widget.settings.keyUrl case final url?) ...[
              const SizedBox(height: S.x4),
              Text(
                '去 $url 申请。',
                style: n1Text(size: 12, height: 1.6, color: N1Colors.of(ctx).dim),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    // 先取值再 dispose：TextField 一销毁 controller 就空了，
    // 在 dispose 之后再读会拿到空串，然后"保存成功但没存上"。
    final value = controller.text;
    controller.dispose();

    if (saved != true || !mounted) return;
    final ok = await widget.settings.saveApiKey(value);
    if (!ok || !mounted) return;
    // 换 Key 等于换身份，旧会话带着旧 Key，必须重建。
    _invalidateSession();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Key 已保存')));
  }

  Future<void> _confirmClear() async {
    final c = N1Colors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除 API Key？'),
        content: const Text('清掉之后就聊不了了，得重新填一个。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清除', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.settings.clearApiKey();
    if (!mounted) return;
    _invalidateSession();
  }
}

/// 一行「标签 + 输入框」。
///
/// [enabled] 为 false 时只读——预置供应商的地址栏就是这样：看得见，改不了。
class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.controller,
    required this.hint,
    this.enabled = true,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Padding(
            // 跟 TextField 的文字对齐（输入框有自己的内边距）。
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              label,
              style: n1Text(size: 13, height: 1.4, color: c.dim),
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            readOnly: !enabled,
            onChanged: onChanged,
            style: n1Text(size: 13, height: 1.4, color: enabled ? c.ink : c.dim),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              // 只读时压掉输入框的底色，免得看着像能填的。
              filled: enabled,
            ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 人设
// ══════════════════════════════════════════════════════════════════

/// 「拉取模型列表」那一行：一个按钮 + 一句状态。
///
/// 存在的理由：模型名是会烂的（各家一年退役一两个），而烂掉之后回的是
/// 404「模型不存在」，看着像网络故障。与其让用户一年去官网查一次，不如给个
/// 当场能问平台的动作。见 `services/model_catalog.dart`。
class _ModelListRow extends StatelessWidget {
  const _ModelListRow({required this.settings, required this.onFetch});

  final SettingsProvider settings;

  /// 拉 + 弹选择框。逻辑在 `_ModelCardState` 里（它拿着 context）。
  final VoidCallback onFetch;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final busy = settings.fetchingModels;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        OutlinedButton(
          onPressed: busy ? null : onFetch,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.list_alt_outlined, size: 16, color: c.ink),
              const SizedBox(width: S.x2),
              Text(busy ? '正在拉…' : '拉取模型列表'),
            ],
          ),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Text(
            settings.hasFetchedModels
                ? '拉到了 ${settings.fetchedModels.length} 个。再点一次重新拉。'
                : '不知道该填哪个名字就点它——它是去问平台"你现在有哪些模型"。'
                      '拉不到也不要紧，手填一样能用。',
            style: n1Text(size: 12, height: 1.6, color: c.faint),
          ),
        ),
      ],
    );
  }
}

/// 挑一个模型。独立成 widget 是为了能单独测（筛选框那块是有逻辑的）。
/// 里面的道理写在它自己的文档里。


class _PersonaCard extends StatelessWidget {
  const _PersonaCard({required this.settings});

  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final overridden = settings.isPersonaOverridden;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                overridden ? '你自己写的' : '出厂人设',
                style: n1Text(
                  size: 14.5,
                  height: 1.4,
                  color: c.ink,
                ).n1W(500),
              ),
              const Spacer(),
              if (overridden)
                TextButton(
                  onPressed: () async {
                    await settings.resetPersona();
                    if (!context.mounted) return;
                    context.read<ChatProvider>().resetSession();
                  },
                  child: const Text('恢复出厂'),
                ),
            ],
          ),
          const SizedBox(height: S.x3),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 180),
            padding: const EdgeInsets.all(S.x4),
            decoration: BoxDecoration(
              color: c.hasShadow
                  ? Color.alphaBlend(
                      Colors.black.withValues(alpha: 0.035),
                      c.bg,
                    )
                  : c.bg,
              borderRadius: R.smAll,
              border: Border.all(color: c.line),
            ),
            child: SingleChildScrollView(
              child: Text(
                settings.effectivePersona,
                style: n1Text(size: 12.5, height: 1.7, color: c.dim),
              ),
            ),
          ),
          const SizedBox(height: S.x4),
          Text(
            '这段文字每个字都会进 system prompt，而且排在最前面。'
            '改它等于改它是谁——所以改了之后得开一段新会话才生效。',
            style: n1Text(size: 12.5, height: 1.65, color: c.dim),
          ),
          const SizedBox(height: S.x4),
          FilledButton.tonal(
            onPressed: () => _edit(context),
            child: const Text('改一改'),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final controller = TextEditingController(text: settings.personaOverride);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('人设'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 14,
            minLines: 8,
            style: n1Text(size: 13, height: 1.7),
            decoration: const InputDecoration(
              hintText: '留空就用出厂的。',
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    final value = controller.text;
    controller.dispose();

    if (ok != true) return;
    await settings.setPersonaOverride(value);
    if (!context.mounted) return;
    // 人设是 prompt 的快照，改了必须重建会话——不然要等重启才生效，
    // 用户会以为设置没保存。
    context.read<ChatProvider>().resetSession();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('人设已更新')));
  }
}

// ══════════════════════════════════════════════════════════════════
// 对话
// ══════════════════════════════════════════════════════════════════

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({required this.settings});

  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            value: settings.streamReasoning,
            onChanged: settings.setStreamReasoning,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '显示思考过程',
              style: n1Text(size: 14.5, height: 1.4, color: c.ink),
            ),
            subtitle: Text(
              '它想事情的过程会以折叠的形式显示出来。关掉只会看不见，'
              '不影响它怎么想。',
              style: n1Text(size: 12.5, height: 1.6, color: c.dim),
            ),
          ),
          const Divider(height: S.x8),
          Row(
            children: [
              Text(
                '发散程度',
                style: n1Text(size: 14.5, height: 1.4, color: c.ink),
              ),
              const Spacer(),
              Text(
                settings.temperature.toStringAsFixed(1),
                style: n1Text(
                  size: 13,
                  height: 1.4,
                  color: c.accentInk,
                  mono: true,
                ).n1W(600),
              ),
            ],
          ),
          Slider(
            value: settings.temperature,
            min: 0,
            max: 2,
            divisions: 20,
            onChanged: (v) {
              settings.setTemperature(v);
              // 温度是在建会话那一刻抄进客户端的（见 N1Runtime.newSession）。
              // 不重建会话的话，这个滑块拖到底也影响不到下一句——要等下次
              // App 启动、或者碰巧改了人设才生效，看起来就像"滑块坏了"。
              context.read<ChatProvider>().resetSession();
            },
          ),
          Text(
            '调低更稳、更像同一个人；调高更活、但可能前后不一致。'
            '陪伴这件事上，稳通常比活重要。',
            style: n1Text(size: 12.5, height: 1.65, color: c.dim),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 工作强度
// ══════════════════════════════════════════════════════════════════

/// 三档的"肯花多少 token"旋钮。
///
/// ⚠️ 文案上有一条不能破的规矩：**省着用那一档砍掉了什么，必须写出来**。
/// 砍回合、砍工具结果、只带最近一段历史——这些都会让用户觉得"它变笨了"，
/// 而如果界面只写"省 token"，用户碰上了只会以为是 bug。省钱可以，
/// 靠瞒着用户省钱不行。
class _WorkLevelCard extends StatelessWidget {
  const _WorkLevelCard({required this.settings});

  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final current = settings.workLevel;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<WorkLevel>(
              segments: [
                for (final level in WorkLevel.values)
                  ButtonSegment(value: level, label: Text(level.label)),
              ],
              selected: {current},
              showSelectedIcon: false,
              onSelectionChanged: (picked) {
                final level = picked.first;
                settings.setWorkLevel(level);
                // 这些数字都是**建会话那一刻**抄进去的（回合数在 AgentLoop
                // 上、工具结果上限在注册表上、记忆索引在 PromptBuilder 上）。
                // 不重建会话的话，换完档位下一句还是老样子，看起来就像
                // "这个开关坏了"。
                context.read<ChatProvider>().resetSession();
              },
            ),
          ),
          const SizedBox(height: S.x4),
          Text(
            current.summary,
            style: n1Text(size: 13, height: 1.7, color: c.ink),
          ),
          const SizedBox(height: S.x3),
          Text(
            '它能花多少 token，主要看四件事：一轮里最多来回几次、'
            '一条工具结果回喂多少字、记得的事带几条、以前的对话带多少。'
            '上面这一档同时调这四个。',
            style: n1Text(size: 12.5, height: 1.65, color: c.dim),
          ),
          const SizedBox(height: S.x2),
          Text(
            '「标准」就是它原本的样子——不选它也不会发现哪里变了。'
            '「放开干」不比标准省，是拿 token 换"别在中途停下"。',
            style: n1Text(size: 12.5, height: 1.65, color: c.faint),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 自动模式
// ══════════════════════════════════════════════════════════════════

/// 「危险操作不再问我」。
///
/// ⚠️ 文案规矩跟 [confirmAutoApprove] 一致，而且**不能比那边轻**：
/// 关掉的是一整道防线，用户有权在设置页里也看到同样的后果。
class _AutoApproveCard extends StatelessWidget {
  const _AutoApproveCard({required this.settings});

  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final on = settings.autoApprove;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            value: on,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '需要确认的操作，不再问我',
              style: n1Text(size: 14.5, height: 1.4, color: c.ink),
            ),
            subtitle: Text(
              on
                  ? '现在是开着的：删文件、覆盖文件、跑命令都会直接执行。'
                      '输入条上那颗胶囊也是红的，随时可以点掉。'
                  : '现在是关着的：删除、覆盖、跑命令这类操作会先弹窗，'
                      '你点「允许」它才执行。',
              style: n1Text(size: 12.5, height: 1.6, color: c.dim),
            ),
            onChanged: (v) async {
              if (!v) {
                await settings.setAutoApprove(false);
                return;
              }
              if (!await confirmAutoApprove(context)) return;
              await settings.setAutoApprove(true);
            },
          ),
          const SizedBox(height: S.x2),
          Text(
            on
                ? '**打开时它就不再停下来了。** 系统目录照样不让写、每一步照样记进'
                    '审计日志（标成「自动」），但删错、买错这一类事后没法撤销。'
                : '打开之后它会在这一类操作上**直接动手**，不再停下来问你。'
                    '不确定要跑什么的时候，建议保持关闭。',
            style: n1Text(size: 12.5, height: 1.65, color: c.faint),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 文件和运行程序的总开关
// ══════════════════════════════════════════════════════════════════

/// 「允许 N1 操作文件和运行程序」。
///
/// ⚠️ 文案上有一条不能破的规矩：**说清它到底能干什么，不能写得像"安全模式"。**
/// 关掉之后它读不了文件、跑不了命令，这会让"帮我看看这个报错"这类事直接做不了，
/// 用户有权知道代价。
///
/// 另外要如实说清"**危险操作还会单独问**"——不然用户会以为开这个开关等于
/// 把电脑交出去，于是宁可不小心地关着它。
class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.settings});

  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final on = settings.allowCodeTools;
    final desktop = isDesktopPlatform;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            value: on,
            contentPadding: EdgeInsets.zero,
            title: Text(
              desktop ? '允许它动你电脑上的文件、跑程序' : '允许它跑代码',
              style: n1Text(size: 14.5, height: 1.4, color: c.ink),
            ),
            subtitle: Text(
              desktop
                  ? '打开之后它能读你电脑上的文件、在你电脑上跑命令和脚本。'
                      '**危险的操作会先弹窗问你**，你不点"允许"它就不执行。'
                  : '手机上它能跑 JavaScript（算个数、转个格式那种）。'
                      '手机上的 JS 碰不到你的文件和照片，也跑不了命令行。',
              style: n1Text(size: 12.5, height: 1.6, color: c.dim),
            ),
            onChanged: (v) {
              settings.setAllowCodeTools(v);
              // 工具表是**建会话那一刻**定下来的，所以改完得重建。
              // 不重建的话开关看着动了，实际上那一轮它照样能读能跑。
              //
              // ⚠️ 这条不是唯一的一道：`installCodeTools` / `installFileTools`
              // 在开关关着时会**把已经装上的摘掉**。正跑着的时候
              // `resetSession()` 只是记账（等这一轮收完摊），光靠它的话
              // 用户关掉之后这一轮还能继续跑——而关掉的动机往往正是
              // 他刚看见一个弹窗。
              context.read<ChatProvider>().resetSession();
            },
          ),
          const SizedBox(height: S.x2),
          Text(
            on
                ? '关掉之后，读文件、写文件、跑命令这些工具**不会给它**'
                    '（不是"给它但拒绝执行"——它不会知道有这些工具存在，'
                    '所以也不会跟你说"我做不到"这种假话）。'
                : '现在是关着的。它读不了文件、跑不了命令，'
                    '"帮我看看这个报错""把这个脚本改一下"这类事都做不了。',
            style: n1Text(size: 12.5, height: 1.65, color: c.dim),
          ),
          const SizedBox(height: S.x3),
          Text(
            '另外：**别指望它当防火墙**。判断"危不危险"靠的是关键词名单，'
            '绕过它的法子多得是。真正管用的是弹窗上那份**原样的命令**加上'
            '你点的那一下——所以看清楚再点。',
            style: n1Text(size: 12.5, height: 1.65, color: c.faint),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 外接工具（MCP）
// ══════════════════════════════════════════════════════════════════

/// 用户自己接的 MCP 服务器。
///
/// 设计上只有一件事要保证：**连不上时用户得看见原因**。MCP 服务器是一个
/// 外部进程，它可能命令写错、依赖没装、握手卡住；这些都不会弹窗，只会让
/// 工具表里凭空少几个。所以每台服务器下面直接挂最近一次的连接错误。
class _McpCard extends StatefulWidget {
  const _McpCard({required this.settings});

  final SettingsProvider settings;

  @override
  State<_McpCard> createState() => _McpCardState();
}

class _McpCardState extends State<_McpCard> {
  /// 正在连。连一台失败的服务器可能要等 20 秒超时，得让用户看见它在干活。
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final runtime = context.watch<ChatProvider>().runtime;
    final servers = widget.settings.mcpServers;

    final connectedIds = {
      for (final conn in runtime.mcpConnections) conn.config.id,
    };
    final toolCount = runtime.mcpConnections.fold<int>(
      0,
      (sum, conn) => sum + conn.tools.length,
    );

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _busy
                ? '正在连接…'
                : runtime.mcpConnections.isEmpty
                ? '还没有连上任何服务器'
                : '已连上 ${runtime.mcpConnections.length} 台，'
                      '共 $toolCount 个工具',
            style: n1Text(
              size: 14.5,
              height: 1.4,
              color: c.ink,
            ).n1W(500),
          ),
          const SizedBox(height: S.x2),
          Text(
            'MCP 是给 AI 接外接工具的一套通用协议。配好一台服务器，'
            '它提供的工具就会像内置工具一样出现在对话里（名字前面带 '
            'mcp_ 前缀）。服务器是本地进程，用你填的命令启动。',
            style: n1Text(size: 12.5, height: 1.65, color: c.dim),
          ),
          if (servers.isEmpty) ...[
            const SizedBox(height: S.x4),
            Text(
              '还没有配置。点下面的「添加服务器」填一条试试。',
              style: n1Text(size: 12.5, height: 1.6, color: c.faint),
            ),
          ],
          for (final server in servers) ...[
            const Divider(height: S.x8),
            _serverRow(
              context,
              server,
              connected: connectedIds.contains(server.id),
              toolCount: runtime.mcpConnections
                  .where((conn) => conn.config.id == server.id)
                  .fold<int>(0, (sum, conn) => sum + conn.tools.length),
              error: runtime.mcpErrors[server.name],
            ),
          ],
          const SizedBox(height: S.x5),
          Wrap(
            spacing: S.x3,
            runSpacing: S.x2,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _edit(null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加服务器'),
              ),
              TextButton.icon(
                onPressed: _busy || servers.isEmpty ? null : _reload,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新连接'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _serverRow(
    BuildContext context,
    McpServerConfig server, {
    required bool connected,
    required int toolCount,
    required String? error,
  }) {
    final c = N1Colors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              connected
                  ? Icons.check_circle_outline
                  : server.enabled
                  ? Icons.error_outline
                  : Icons.pause_circle_outline,
              size: 18,
              color: connected
                  ? c.accentInk
                  : server.enabled
                  ? c.danger
                  : c.faint,
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Text(
                server.name,
                style: n1Text(size: 14.5, height: 1.4, color: c.ink),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (connected)
              Text(
                '$toolCount 个工具',
                style: n1Text(size: 12, height: 1.4, color: c.dim),
              ),
            Switch.adaptive(
              value: server.enabled,
              onChanged: _busy
                  ? null
                  : (v) => _save([
                      for (final s in widget.settings.mcpServers)
                        if (s.id == server.id) s.copyWith(enabled: v) else s,
                    ]),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 27),
          child: Text(
            [server.command, ...server.args].join(' '),
            style: n1Text(
              size: 12,
              height: 1.5,
              color: c.faint,
              mono: true,
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: S.x2),
          Padding(
            padding: const EdgeInsets.only(left: 27),
            child: Text(
              error,
              style: n1Text(size: 12.5, height: 1.6, color: c.danger),
            ),
          ),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _busy ? null : () => _edit(server),
              child: const Text('编辑'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _confirmDelete(server),
              child: Text('删除', style: TextStyle(color: c.danger)),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _edit(McpServerConfig? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final cmdCtrl = TextEditingController(text: existing?.command ?? '');
    final argsCtrl = TextEditingController(
      text: (existing?.args ?? const <String>[]).join('\n'),
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: existing == null,
                  style: n1Text(size: 14, height: 1.4),
                  decoration: const InputDecoration(
                    labelText: '名字',
                    hintText: '随便起，比如「文件服务器」',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: S.x4),
                TextField(
                  controller: cmdCtrl,
                  style: n1Text(size: 14, height: 1.4),
                  decoration: const InputDecoration(
                    labelText: '启动命令',
                    hintText: 'npx / python / 一个绝对路径',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: S.x4),
                TextField(
                  controller: argsCtrl,
                  minLines: 2,
                  maxLines: 5,
                  style: n1Text(size: 13, height: 1.5, mono: true),
                  decoration: const InputDecoration(
                    labelText: '参数（一行一个）',
                    hintText: '-y\n@modelcontextprotocol/server-filesystem\nD:\\某个目录',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: S.x3),
                Text(
                  '参数一行一个，这样带空格的路径不用加引号。'
                  '服务器由你在本机启动，能跑什么取决于那个命令本身。',
                  style: n1Text(
                    size: 12,
                    height: 1.6,
                    color: N1Colors.of(ctx).faint,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    // 先取值再 dispose。dispose 之后 controller 就空了。
    final name = nameCtrl.text.trim();
    final command = cmdCtrl.text.trim();
    final args = argsCtrl.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    nameCtrl.dispose();
    cmdCtrl.dispose();
    argsCtrl.dispose();

    if (saved != true || !mounted) return;
    if (command.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('启动命令不能为空')));
      return;
    }

    final config = McpServerConfig(
      id:
          existing?.id ??
          'mcp-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name.isEmpty ? command : name,
      command: command,
      args: args,
      enabled: existing?.enabled ?? true,
    );

    final list = [...widget.settings.mcpServers];
    final index = list.indexWhere((s) => s.id == config.id);
    if (index >= 0) {
      list[index] = config;
    } else {
      list.add(config);
    }
    await _save(list);
  }

  Future<void> _confirmDelete(McpServerConfig server) async {
    final c = N1Colors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${server.name}」？'),
        content: const Text('删掉之后它提供的工具会从对话里消失，配置不会留备份。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await _save([
      for (final s in widget.settings.mcpServers)
        if (s.id != server.id) s,
    ]);
  }

  Future<void> _reload() async {
    setState(() => _busy = true);
    await context.read<ChatProvider>().reloadMcp();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// 存配置 → 丢旧会话 → 立刻重连。
  ///
  /// 三步缺一不可：配置存了不重连，界面会显示"没连上"；重连了不丢会话，
  /// 正在用的那个会话还攥着上一批工具。
  Future<void> _save(List<McpServerConfig> servers) async {
    setState(() => _busy = true);
    await widget.settings.setMcpServers(servers);
    if (!mounted) return;
    context.read<ChatProvider>().resetSession();
    await context.read<ChatProvider>().reloadMcp();
    if (!mounted) return;
    setState(() => _busy = false);
  }
}

// ══════════════════════════════════════════════════════════════════
// 关于
// ══════════════════════════════════════════════════════════════════

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.of(context);
    final skills = context.watch<SkillsProvider>();
    final settings = context.watch<SettingsProvider>();

    return _Card(
      child: Column(
        children: [
          const N1Mark(size: 48),
          const SizedBox(height: S.x4),
          Text(
            appName,
            style: n1Text(
              size: 15,
              weight: 600,
              height: 1.4,
              color: c.ink,
            ),
          ),
          const SizedBox(height: S.x5),
          Text(
            '技能 ${skills.skills.length} 个 · 对话用的是 ${settings.provider.name}',
            textAlign: TextAlign.center,
            style: n1Text(size: 12.5, height: 1.6, color: c.dim),
          ),
          const SizedBox(height: S.x3),
          // 署名。比上面那行再轻一档（faint 而不是 dim）——它是落款不是信息，
          // 跟元数据抢视线就俗了。
          Text(
            '开发者：$appAuthor',
            textAlign: TextAlign.center,
            style: n1Text(size: 12.5, height: 1.6, color: c.faint),
          ),
        ],
      ),
    );
  }
}
