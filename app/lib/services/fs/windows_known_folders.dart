/// 探出「桌面 / 文档 / 下载」在本机上到底是哪个目录。
///
/// ## 为什么不能直接 `%USERPROFILE%\Desktop`
///
/// OneDrive 的"备份文件夹"会把桌面和文档搬到 `OneDrive\桌面`、`OneDrive\文档`，
/// 搬完之后 `C:\Users\x\Desktop` **还留在原地，但是个空壳**。
/// 照着名字拼路径写进去，文件确实写成功了，用户在桌面上什么也看不见——
/// 这是"看着全对、结果全错"的那种坑。
///
/// ## 为什么走 PowerShell 而不是 `reg query`
///
/// 🩸 `reg query` 按**控制台代码页**输出，中文 Windows 上是 GBK，而路径里
/// 就有中文（`C:\Users\liuwa\OneDrive\文档`）。Dart 没有 GBK 解码器，
/// 按 UTF-8 硬解得到一串 U+FFFD，路径直接废掉。这一点在本机实测过：
/// `reg query` 的输出里那个值是 `C:\Users\liuwa\OneDrive\<?><?>`。
///
/// PowerShell 里先设 `[Console]::OutputEncoding` 再输出，就是干净的 UTF-8，
/// Dart 按 UTF-8 读，中文原样带回来。实测这一条通、`chcp 65001` 那条不通
/// （cmd 会把自己的版本横幅和提示符一起混进 stdout）。
///
/// ## 为什么注册表也不能全信
///
/// 本机实测：`Personal` 指向 `C:\Users\liuwa\Documents`（有内容），
/// 而现代已知文件夹 GUID `{24D89E24…}` 指向 `C:\Users\liuwa\OneDrive\文档`
/// （**空的**）。一次 OneDrive 重定向开过又关掉，就会留下这种新旧并存的状态。
/// 所以最后一步不是"按优先级取第一个"，而是"取真的在用的那个"，见 [pickInUseFolder]。
library;

import 'dart:convert';
import 'dart:io';

import '../../core/n1_core.dart';

/// 读注册表原始值（名字 → 值）。抽成函数是为了测试能塞假的，
/// 不用真去起 PowerShell——顺带也不用担心测试跑在非 Windows 上。
typedef ShellFolderQuery = Future<Map<String, String>> Function();

/// 桌面 / 文档 / 下载 在现代注册表里的 GUID 形式。
const _desktopGuid = '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}';
const _documentsGuid = '{24D89E24-2F19-4534-9DDE-6A6671FBB8FE}';
const _downloadsGuid = '{374DE290-123F-4565-9164-39C4925E467B}';

/// 一个位置的所有可能来源，**按"更像真的"排序**。
List<String> shellFolderCandidates(
  KnownFolder folder,
  Map<String, String> registry,
  Map<String, String> environment,
) {
  final profile = _env(environment, 'USERPROFILE');
  final oneDrive = _env(environment, 'OneDrive');
  final home = profile ?? _env(environment, 'HOME');

  String? fromRegistry(String name) {
    final raw = registry[name];
    if (raw == null || raw.isEmpty) return null;
    return expandEnvVars(raw, environment);
  }

  String? under(String? base, String child) =>
      base == null || base.isEmpty ? null : '$base\\$child';

  final out = <String>[];
  void add(String? value) {
    if (value != null && value.isNotEmpty) out.add(value);
  }

  switch (folder) {
    case KnownFolder.desktop:
      add(fromRegistry('Desktop'));
      add(fromRegistry(_desktopGuid));
      add(under(home, 'Desktop'));
      add(under(oneDrive, '桌面'));
    case KnownFolder.documents:
      add(fromRegistry(_documentsGuid));
      add(fromRegistry('Personal'));
      add(under(home, 'Documents'));
      add(under(oneDrive, '文档'));
    case KnownFolder.downloads:
      add(fromRegistry(_downloadsGuid));
      add(under(home, 'Downloads'));
      add(under(oneDrive, '下载'));
  }
  return out;
}

/// 从候选里挑出**真的在用**的那一个。
///
/// 规则分三档，顺序不能换：
/// 1. 存在**且有内容**的——有内容说明用户真在这儿放东西，它就是在用的那个；
/// 2. 退一步，存在的——新建的账号桌面就是空的，不能因为空就判它不是；
/// 3. 都没有 → **返回 null**。
///
/// ⚠️ 第 3 档不许"随便挑一个"。挑一个不存在的目录往下写，`write_file` 带上
/// `create_parents` 就会造出一个 Explorer 根本不认的文件夹，用户永远看不见它。
/// 宁可让工具如实报"我没探到桌面在哪儿，请给绝对路径"。
String? pickInUseFolder(
  List<String> candidates, {
  required bool Function(String path) exists,
  required bool Function(String path) hasEntries,
}) {
  final seen = <String>{};
  final unique = <String>[];
  for (final c in candidates) {
    final key = c.toLowerCase();
    if (seen.add(key)) unique.add(c);
  }

  for (final path in unique) {
    if (exists(path) && hasEntries(path)) return path;
  }
  for (final path in unique) {
    if (exists(path)) return path;
  }
  return null;
}

/// 探一遍。任何一步出问题（PowerShell 被策略挡了、注册表读不到）
/// 都只是**少几个候选**，最后还有 `%USERPROFILE%` 那一档兜着。
Future<Map<KnownFolder, String>> discoverKnownFolders({
  Map<String, String> environment = const {},
  ShellFolderQuery? readRegistry,
}) async {
  final env = environment.isEmpty ? Platform.environment : environment;
  if (!Platform.isWindows) return const {};

  Map<String, String> registry = const {};
  try {
    registry = await (readRegistry ?? readUserShellFolders)();
  } catch (_) {
    registry = const {};
  }

  final result = <KnownFolder, String>{};
  for (final folder in KnownFolder.values) {
    final picked = pickInUseFolder(
      shellFolderCandidates(folder, registry, env),
      exists: (path) => Directory(path).existsSync(),
      hasEntries: _directoryHasEntries,
    );
    if (picked != null) result[folder] = picked;
  }
  return result;
}

/// 注册表里 `User Shell Folders` 的原始内容。
Future<Map<String, String>> readUserShellFolders() async {
  const key =
      r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders';

  // 名字里的 `'` 用两个单引号转义，避免路径里带引号时把脚本拆坏。
  final script =
      '[Console]::OutputEncoding=[Text.Encoding]::UTF8; '
      "try { \$p = Get-ItemProperty '$key' } catch { exit 0 }; "
      "foreach (\$n in @('Desktop','$_desktopGuid','Personal',"
      "'$_documentsGuid','$_downloadsGuid')) { "
      "\$v = \$p.\$n; if (\$v) { Write-Output \"\$n=\$v\" } }";

  final result = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
  ], stdoutEncoding: utf8).timeout(const Duration(seconds: 8));

  if (result.exitCode != 0) return const {};

  final out = <String, String>{};
  for (final line in const LineSplitter().convert('${result.stdout}')) {
    final cut = line.indexOf('=');
    if (cut <= 0) continue;
    out[line.substring(0, cut).trim()] = line.substring(cut + 1).trim();
  }
  return out;
}

/// 展开 `%VAR%`。注册表里的值基本都是 `REG_EXPAND_SZ`，
/// 存的是 `%USERPROFILE%\Desktop` 这种带变量的形式，得自己展开。
///
/// 展开不了的**留原样**——这里跟 [PathResolver] 的策略故意相反：
/// 那边是用户给的输入，认不出来要报错；这边是系统给的数据，
/// 少一个候选不影响正确性（后面还有别的档），没必要因此整条失败。
String expandEnvVars(String raw, Map<String, String> environment) {
  return raw.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
    final value = _env(environment, m.group(1)!);
    return value ?? m.group(0)!;
  });
}

String? _env(Map<String, String> env, String name) {
  final direct = env[name];
  if (direct != null) return direct;
  final want = name.toLowerCase();
  for (final e in env.entries) {
    if (e.key.toLowerCase() == want) return e.value;
  }
  return null;
}

/// 目录里有没有东西。
///
/// **不算隐藏文件**：OneDrive 搬走之后会在旧目录留一个 `desktop.ini`，
/// 只按"有条目"判的话，那个空壳会被当成"有内容"，正好挑错。
/// 普通的点开头文件（`.gitignore`）不算数也无所谓——这里判的是
/// 桌面/文档/下载，用户往那儿放正经东西时不会只放一个点文件。
bool _directoryHasEntries(String path) {
  try {
    return Directory(path).listSync(followLinks: false).any((e) {
      final name = e.path.split(RegExp(r'[\\/]')).last;
      return name != 'desktop.ini' && name != 'Thumbs.db' && !name.startsWith('.');
    });
  } catch (_) {
    return false;
  }
}
