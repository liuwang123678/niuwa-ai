/// 危险命令判定：**纯函数，不看磁盘也不起进程。**
///
/// ⚠️ 用之前先读这段：**这是「手滑拦截 + 知情同意」的触发器，不是安全边界。**
///
/// 挡得住的是"用户扫一眼就能发现不对"的那种——`format c:`、
/// `del /s /q C:\*`、把一长串 base64 塞进 `powershell -enc`。
/// 挡不住：字符混淆（`d^el`、变量拼接）、先 `write_file` 写个脚本再跑、
/// `curl | sh` 的各种变体、以及任何真正想绕的人。
///
/// 那为什么还写它？因为**提问本身就是防护**——弹窗把原样命令摆到用户面前，
/// 人比正则强。真正的边界是那套组合：展示原文 + 用户能拒 + 超时杀进程树 +
/// 审计日志 + 总开关 + 绝不提权。别把它当成"安全防护"去宣传。
///
/// 两个设计取舍：
///   - **宁可多问，不可漏问。** 误报的代价是多点一下「允许」，
///     漏报的代价是文件没了。所以边界画得偏保守。
///   - **先归一化再匹配。** 统一小写、合并空白、剥掉 `cmd /c` 这层壳、
///     按 `&&`/`|`/`;` 拆段——不归一化的话 `CMD /C DEL ...` 和
///     `cmd /c "del ..."` 就是两条漏网的命令。
library;

/// 判定结论。
class DangerVerdict {
  const DangerVerdict._(this.reason, this.rule);

  /// 不用问。
  const DangerVerdict.safe() : this._(null, null);

  /// 要问。[reason] 是给用户看的一句话，**以「会」开头**（工具层会拿它拼
  /// 「这条命令会……，要你确认一下」）；[rule] 是命中的规则名，进审计日志。
  const DangerVerdict.ask(String reason, String rule) : this._(reason, rule);

  /// 要问的原因。安全时是 null。
  final String? reason;

  /// 命中的规则名。安全时是 null。
  final String? rule;

  bool get needsApproval => rule != null;
}

/// 判一条命令行。
DangerVerdict judgeCommand(String command) => _judge(command);

/// 判一段脚本源码。
///
/// 两步：先过一遍 [judgeCommand] 的**命令行规则**，没过再加一遍**源码规则**。
/// 分两套是因为它们认的东西不一样：
///
///   - 命令行规则认的是"这个位置是个命令"（`del`、`reg add`），
///     源码里那句 `os.system("del /s /q ...")` 靠"引号后是命令位置"这条能认出来；
///   - 源码规则认的是**语言层面的 API**——`shutil.rmtree`、`os.remove`、
///     `subprocess.run`。这些在命令行规则里一个字都对不上，可不认就等于
///     `import shutil; shutil.rmtree('C:/')` 一路绿灯。
///
/// 局限写在这里，免得以后有人以为它管用：字符串拼接出来的命令
/// （`os.system('d'+'el ...')`）、base64 解出来的、从网上拉下来的，都扫不到。
DangerVerdict judgeScript(String source) {
  final fromCommandRules = _judge(source);
  if (fromCommandRules.needsApproval) return fromCommandRules;

  final text = normalizeCommand(source);
  if (text.isEmpty) return const DangerVerdict.safe();
  for (final rule in _scriptRules) {
    if (rule.pattern.hasMatch(text)) {
      return DangerVerdict.ask(rule.reason, rule.id);
    }
  }
  return const DangerVerdict.safe();
}

/// 只有扫源码时才用的规则。见 [judgeScript] 里的分工说明。
final List<_Rule> _scriptRules = [
  _Rule('script-delete', _scriptDeletePattern, '会删掉文件或目录'),
  _Rule('script-shell', _scriptShellPattern, '脚本里在调系统命令'),
  _Rule('script-eval', _scriptEvalPattern, '在动态执行拼出来的代码'),
];

final RegExp _scriptDeletePattern = RegExp(
  r'shutil\.rmtree|os\.(?:remove|unlink|rmdir|removedirs|truncate)|'
  r'unlink(?:Sync)?|rmdirsync|rmsync|fs\.rm(?:sync)?\b|directory\.delete|'
  r'\.delete\(\s*\)|\.removefile\b|file\.delete\b',
);
final RegExp _scriptShellPattern = RegExp(
  r'\bos\.(?:system|popen|spawn\w*)\b|\bsubprocess\b|\bchild_process\b|'
  r'\b(?:exec|spawn|execfile)(?:sync)?\s*\(|\bshell\.run\b|'
  r'\bctypes\.|\bwin32api\b|\bprocessbuilder\b',
);
final RegExp _scriptEvalPattern = RegExp(r'\beval\s*\(|\bexec\s*\(');

DangerVerdict _judge(String raw) {
  final text = normalizeCommand(raw);
  if (text.isEmpty) return const DangerVerdict.safe();

  // 整串 + 每个分段都过一遍。分段是为了让"以命令开头"这类规则不被前面的
  // 参数干扰（`echo hi && format c:` 里的 `format` 是新一段的第一个词）；
  // 整串是为了那些会跨段的模式（`... | sh`）。
  final targets = <String>[text, ...commandSegments(text)];

  for (final rule in _rules) {
    for (final target in targets) {
      if (rule.pattern.hasMatch(target)) {
        return DangerVerdict.ask(rule.reason, rule.id);
      }
    }
  }
  return const DangerVerdict.safe();
}

/// 统一小写、剥壳、折叠空白、把 Windows 目录写法归一到 `<win>`。
///
/// 抽成公开函数是为了让测试能直接钉住归一化的结果——规则命不命中全靠它，
/// 它错了是"整片规则集体失效"，症状却是"某些命令不问"，很难从弹窗上看出来。
String normalizeCommand(String raw) {
  var s = raw.toLowerCase();
  s = _unwrap(s);
  s = _foldSystemPaths(s);
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

/// 按 `&&` `||` `;` `|` `&` 和换行拆段，去空。
List<String> commandSegments(String raw) {
  final normalized = normalizeCommand(raw);
  if (normalized.isEmpty) return const [];
  // `&&` / `||` 必须排在 `&` / `|` 前面，正则的选择分支是从左往右试的。
  return normalized
      .split(RegExp(r'&&|\|\||[;|&\r\n]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

/// 反复剥掉外层壳，直到剥不动为止。
///
/// 反复是为了对付嵌套：`cmd /c powershell -c "..."`。只剥一层的话，
/// 内层的 `-enc` 之类就露不出来。
String _unwrap(String s) {
  var out = s.trim();
  var changed = true;
  while (changed) {
    changed = false;
    for (final prefix in _wrappers) {
      if (out.startsWith(prefix)) {
        out = out.substring(prefix.length).trim();
        changed = true;
      }
    }
    // 整条被引号裹起来的情况：`"del /s /q c:\"`。剥一层引号，
    // 里面往往才是真正的命令行。
    if (out.length >= 2 && out.startsWith('"') && out.endsWith('"')) {
      out = out.substring(1, out.length - 1).trim();
      changed = true;
    }
  }
  return out;
}

const List<String> _wrappers = [
  'cmd /c ',
  'cmd /k ',
  'cmd.exe /c ',
  'cmd.exe /k ',
  'powershell -command ',
  'powershell.exe -command ',
  'powershell -c ',
  'powershell.exe -c ',
  'pwsh -command ',
  'pwsh -c ',
  'bash -c ',
  'sh -c ',
  'zsh -c ',
  'sudo ',
];

/// 把 `c:\windows`、`%windir%`、`$env:systemroot` 这些**写法不同但指向同一个
/// 地方**的路径归一成 `<win>`。
///
/// 不归一化的话，"别动 Windows 目录"这条规则要写四份，而且漏一份就是漏洞。
/// 这里刻意**不去读真实的环境变量**：判定必须跟"在哪台机器上跑"无关，
/// 否则同一串命令在测试机上安全、在用户机上危险。
String _foldSystemPaths(String s) {
  var out = s;
  for (final alias in const [
    r'%windir%',
    r'%systemroot%',
    r'$env:windir',
    r'$env:systemroot',
    r'${env:windir}',
    r'${env:systemroot}',
    r'c:\windows',
    r'c:\winnt',
  ]) {
    out = out.replaceAll(alias, '<win>');
  }
  return out;
}

/// 造一条"**这个位置是命令名**"的正则。
///
/// 为什么不直接 `\bdel\b`：`\b` 会把**参数和引号里的词**也算上。实测两个反例：
///
///   - `git commit -m "add del support"` —— 那个 `del` 是提交信息里的一个词，
///     `\bdel\b` 照样命中。而这是**本项目的日常操作**，一天要问好几次，
///     问多了用户就会把总开关关掉，那才是真的没了防护。
///   - `xcopy C:\rd\a b` —— 那个 `rd` 是目录名。
///
/// 所以要求它出现在"命令位置"：段首、分隔符之后、引号之后、或者
/// `do` / `call` / `start` / `then` / `else` 这几个"接着执行子命令"的关键字之后
/// （`for %f in (*) do del %f` 这种写法要能认出来）。
///
/// 引号也算命令位置，是给 [judgeScript] 用的：脚本里危险命令长这样——
/// `os.system('del /s /q ...')`。`del` 紧跟在一个开引号后面。
/// 注意它**不会**让 `git commit -m "add del support"` 误报：那里的 `del`
/// 前面是空格，不是引号。
///
/// **代价写在明处**：`find . -name x -exec rm {} \;` 这类把命令当参数的写法会漏掉。
/// 这正是"这是触发器不是安全边界"的一个具体例子。
RegExp _command(List<String> words) {
  final group = words.map(RegExp.escape).join('|');
  return RegExp(
    '(?:^|[;&|()\'"]|\\b(?:do|call|start|then|else)\\s)'
    '(?:$group)(?=[\\s&|;)\'"]|\$)',
  );
}

class _Rule {
  _Rule(this.id, this.pattern, this.reason);

  final String id;
  final RegExp pattern;

  /// 给用户看的一句话，**以「会」开头**。
  final String reason;
}

/// 规则表。**顺序即优先级**，第一个命中的说了算。
///
/// 排在前面的都是"光看形状就不对"的：一段 base64、`-enc`、下载完直接丢给
/// shell。它们在列表最前面，是因为命中它们时用户几乎不需要读命令内容。
final List<_Rule> _rules = [
  // ---- 看不见内容的执行 ----
  _Rule(
    'encoded-command',
    _encodedCommandPattern,
    '会执行一段编码过的命令，看不出它到底要干什么',
  ),
  _Rule(
    'base64-blob',
    _base64BlobPattern,
    '会执行藏在 base64 里的东西，看不出它是什么',
  ),
  _Rule(
    'download-and-run',
    _downloadAndRunPattern,
    '会把网上下载来的东西直接交给 shell 执行',
  ),
  _Rule(
    'pipe-to-shell',
    _pipeToShellPattern,
    '会把上一个命令的输出直接交给 shell 执行',
  ),

  // ---- 带破坏性的系统操作 ----
  _Rule('format', _formatPattern, '会格式化或改写磁盘分区'),
  _Rule('boot', _bootPattern, '会改动系统启动配置'),
  _Rule('vssadmin', _vssPattern, '会删掉卷影副本（勒索软件的典型动作）'),
  _Rule('dism', _dismPattern, '会改动系统映像'),
  _Rule('reg-write', _regWritePattern, '会改注册表'),
  _Rule('delete', _deletePattern, '会删掉文件或目录'),
  _Rule('remove-item', _removeItemPattern, '会删掉文件或目录'),
  _Rule('find-delete', _findDeletePattern, '会删掉文件或目录'),
  _Rule('disk-write', _diskWritePattern, '直接动了 Windows 目录里的东西'),
  _Rule('ownership', _takeownPattern, '会改文件的属主或权限'),
  _Rule('robocopy-mirror', _mirrorPattern, '会镜像复制目录（目标里多出来的会被删掉）'),

  // ---- 进程与系统控制 ----
  _Rule('taskkill', _taskkillPattern, '会强杀进程（连子进程一起）'),
  _Rule('power', _powerPattern, '会关机或重启'),
  _Rule('sc-delete', _scDeletePattern, '会删掉系统服务'),
  _Rule('scheduled-task', _scheduledTaskPattern, '会建或删计划任务'),
  _Rule('wmi', _wmiPattern, '用了 WMI（常被拿来执行代码或删东西）'),
  _Rule('firewall', _firewallPattern, '会改防火墙设置'),

  // ---- 权限与账号 ----
  _Rule('runas', _runasPattern, '会以管理员权限运行'),
  _Rule('execution-policy', _executionPolicyPattern, '会改 PowerShell 的执行策略'),
  _Rule('net-accounts', _netAccountsPattern, '会增删改本地账号或用户组'),

  // ---- 常规执行器里"用得不对劲"的 ----
  _Rule('hidden-window', _hiddenWindowPattern, '刻意把窗口藏起来（正常脚本不需要这样）'),
  _Rule('lolbin', _lolbinPattern, '用了常被拿来执行代码的系统程序'),
  _Rule('certutil', _certutilPattern, '用了系统自带的下载/解码工具（常被拿来绕过检测）'),
  _Rule('inline-code', _inlineCodePattern, '把代码直接塞在命令行里执行'),

  // ---- 数据 ----
  _Rule('credentials', _credentialsPattern, '在读 SSH 私钥、.env、浏览器密码库这类凭据文件'),
  _Rule('persistence', _persistencePattern, '会往开机自启的地方写东西'),
  _Rule('git-destructive', _gitDestructivePattern, '是不可逆的 git 操作'),
];

// 正则单独提出来：`const` 规则表里用不了插值，混在规则里读起来也吵。

final RegExp _encodedCommandPattern = RegExp(
  r'-(?:enc|encodedcommand)\b|frombase64string\b|\[convert\]::frombase64',
);
final RegExp _base64BlobPattern = RegExp(r'[a-z0-9+/]{80,}={0,2}');
final RegExp _downloadAndRunPattern = RegExp(
  r'(?:iwr|invoke-webrequest|curl|wget|bitsadmin|certutil)[^\n]{0,200}'
  r'(?:\||iex|invoke-expression|downloadstring|downloadfile|-urlcache)'
  r'|downloadstring\b|net\.webclient\b',
);
final RegExp _pipeToShellPattern = RegExp(
  r'\|\s*(?:ba|z|k)?sh\b|\|\s*(?:iex|invoke-expression)\b|\|\s*python\b',
);
final RegExp _formatPattern = _command([
  'format',
  'diskpart',
  'diskcomp',
  'diskcopy',
  'format-volume',
]);
final RegExp _bootPattern = _command(['bcdedit', 'bootrec', 'bootsect']);
final RegExp _vssPattern = RegExp(r'vssadmin\b[^\n]*\bdelete\b');
final RegExp _dismPattern = _command(['dism', 'dism.exe']);
final RegExp _regWritePattern = RegExp(
  r'\breg(?:\.exe)?\s+(?:add|delete|import|load|restore|copy)\b'
  r'|set-itemproperty\b[^\n]*(?:hklm|hkcu|hkey_)'
  r'|new-itemproperty\b[^\n]*(?:hklm|hkcu|hkey_)',
);
final RegExp _deletePattern = _command(['del', 'erase', 'rm', 'rmdir', 'rd', 'deltree']);
final RegExp _removeItemPattern = RegExp(r'\bremove-item\b|\bri\s+-');
/// `find . -name '*.tmp' -delete`——命令不以 `rm` 开头，上面那条按命令位置
/// 匹配的规则够不着，只能单独认这个参数。
final RegExp _findDeletePattern = RegExp(r'\s-delete\b');
final RegExp _diskWritePattern = RegExp(r'(?:>>?|copy|move|ren|del|echo)[^\n]{0,200}<win>');
final RegExp _takeownPattern = _command(['takeown', 'icacls', 'cacls']);
final RegExp _mirrorPattern = RegExp(r'\brobocopy\b[^\n]*\s/mir\b');
final RegExp _taskkillPattern = RegExp(r'\btaskkill\b[^\n]*\s/[ft]\b|\bstop-process\b[^\n]*\s-force\b');
final RegExp _powerPattern = _command([
  'shutdown',
  'logoff',
  'stop-computer',
  'restart-computer',
]);
final RegExp _scDeletePattern = RegExp(r'\bsc(?:\.exe)?\s+delete\b');
final RegExp _scheduledTaskPattern = _command(['schtasks']);
final RegExp _wmiPattern = _command(['wmic', 'get-wmiobject', 'invoke-cimmethod']);
final RegExp _firewallPattern = RegExp(
  r'netsh\s+(?:advfirewall|firewall)\b|set-netfirewallprofile\b[^\n]*\s-off\b',
);
final RegExp _runasPattern = RegExp(r'\brunas\b|-verb\s+runas\b');
final RegExp _executionPolicyPattern = RegExp(r'set-executionpolicy\b');
final RegExp _netAccountsPattern = RegExp(r'\bnet\s+(?:user|localgroup)\b');
final RegExp _hiddenWindowPattern = RegExp(r'-windowstyle\s+hidden\b|-w\s+hidden\b');
final RegExp _lolbinPattern = _command([
  'mshta',
  'rundll32',
  'regsvr32',
  'wscript',
  'cscript',
  'installutil',
]);
final RegExp _certutilPattern = _command(['certutil', 'bitsadmin']);
final RegExp _inlineCodePattern = RegExp(
  r'\b(?:python|python3|py|node|nodejs|perl|ruby|php)\b\s+(?:-c|-e|--eval)\b',
);
final RegExp _credentialsPattern = RegExp(
  r'\.ssh\b|\bid_rsa\b|\bid_ed25519\b|\.aws[\\/]credentials|'
  r'(?:^|[\\/\s])\.env\b|login data\b|[\\/]cookies\b|cookies\.sqlite|'
  r'\bcredential\b|vaultcmd\b',
);
final RegExp _persistencePattern = RegExp(
  r'[\\/]startup[\\/]|shell:startup|new-scheduledtask\b|'
  r'\breg\b[^\n]*[\\/]run\b|'
  r'currentversion[\\/]run\b',
);
final RegExp _gitDestructivePattern = RegExp(
  r'\bgit\s+reset\s+--hard\b|\bgit\s+clean\s+-\w*f|\bgit\s+push\b[^\n]*\s(?:-f|--force)\b|'
  r'\bgit\s+checkout\s+--\s|\bgit\s+branch\s+-d\b|\bgit\s+filter-branch\b',
);
