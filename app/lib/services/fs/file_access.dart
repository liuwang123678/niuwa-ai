import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/n1_core.dart';
import 'local_file_backups.dart';
import 'windows_known_folders.dart';

/// 文件工具要用的一整套东西：路径解析 + 访问策略 + 覆盖前的备份。
///
/// 打成一件是因为它们**必须一起换**：只换了 `PathResolver`（比如换一套已知
/// 文件夹的来源）而不换 policy，测试就会在一个"以为封着 C:\Windows"的策略下
/// 真去写系统目录。捆在一起之后，注入点只有一个。
class FileAccess {
  const FileAccess({
    required this.paths,
    required this.policy,
    required this.backups,
  });

  final PathResolver paths;
  final FilePolicy policy;
  final FileBackupStore backups;
}

/// 造一套文件访问环境。**不是 Windows 就返回 null。**
///
/// 返回 null 的意思是"这个平台上**不注册**文件工具"，不是"降级成只读"。
/// 理由：安卓是 scoped storage，绝大多数绝对路径根本读写不了；`/sdcard`
/// 那条路要 `MANAGE_EXTERNAL_STORAGE`，有应用商店政策风险，不走。
///
/// 注册了会怎样：模型看到 `read_file` 就去调，撞一鼻子灰，然后换个路径再撞。
/// 这是 `tool_registry.dart` 里那条"注册了再返回不支持，比不注册更坏"。
///
/// 各个参数都留了口子，是因为这一路**没法在真机上活着测**：得能塞一个假的
/// 注册表读取、假的 home、假的 realizer，才能验"OneDrive 下的桌面认不认得出"
/// 和"写 C:\Windows 到底拦不拦得住"。
Future<FileAccess?> createFileAccess({
  /// 备份放哪。生产传 `<appSupport>`，测试传临时目录。
  required Directory appSupport,
  Map<String, String>? environment,
  String? home,
  bool? isWindows,
  PathRealizer? realizer,
  ShellFolderQuery? readRegistry,
  int backupKeep = 200,
}) async {
  final env = environment ?? Platform.environment;
  final windows = isWindows ?? Platform.isWindows;
  if (!windows) return null;

  final resolvedHome = home ?? _envOf(env, 'USERPROFILE') ?? '';

  // 探一次已知文件夹。**这一步失败不算致命**：探不到就是"桌面/文档/下载
  // 这几个词认不出来"，绝对路径照样能用，`PathResolver` 会如实说没探到。
  //
  // `discoverKnownFolders` 内部已经吞了大部分失败（PowerShell 被策略挡了、
  // 注册表读不到），漏到这儿的是更意外的情况。文件工具不该因为这个词典建不
  // 起来就整个不给——那等于为了一个便利功能砍掉主要功能。
  Map<KnownFolder, String> folders;
  try {
    folders = await discoverKnownFolders(
      environment: env,
      readRegistry: readRegistry,
    );
  } catch (_) {
    folders = const {};
  }

  return FileAccess(
    paths: PathResolver(
      home: resolvedHome,
      environment: env,
      knownFolders: folders,
      isWindows: true,
    ),
    policy: FilePolicy.standard(
      environment: env,
      isWindows: true,
      realizer: realizer,
    ),
    backups: LocalFileBackupStore(
      dir: Directory(p.join(appSupport.path, 'backups')),
      keep: backupKeep,
    ),
  );
}

/// 环境变量按**大小写不敏感**查。
///
/// Windows 上变量名本来就不分大小写，而模型爱写 `%UserProfile%` 这种跟真实
/// 名字对不上的形式。这里再补一道，是因为 `USERPROFILE` 拿不到等于主目录是
/// 空串，`~` 解析会当场失败——症状是"所有带 ~ 的路径都不认识"。
String? _envOf(Map<String, String> env, String name) {
  final direct = env[name];
  if (direct != null && direct.isNotEmpty) return direct;
  final lower = name.toLowerCase();
  for (final entry in env.entries) {
    if (entry.key.toLowerCase() == lower && entry.value.isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}
