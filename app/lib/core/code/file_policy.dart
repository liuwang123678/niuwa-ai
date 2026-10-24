import 'dart:io';

/// 把一个路径翻成"磁盘上真实的样子"，用来做包含判断。
///
/// 默认实现走 `resolveSymbolicLinksSync`，它在 Windows 上落到
/// `GetFinalPathNameByHandle`——**顺带把大小写和 8.3 短名一并规整了**：
/// `C:\PROGRA~1` 和 `c:\program files` 都会回到同一个长名。
/// 一条 API 解决三种绕过写法，比自己写字符串比较靠谱得多。
typedef PathRealizer = String Function(String absolutePath);

/// 哪些路径不许写。
///
/// **这是防手滑的，不是防攻击的。** 挡得住"模型把文件写到 System32 去了"，
/// 挡不住一个铁了心要绕的人（他能去写别的地方）。真正让用户放心的东西是
/// 那套组合：展示原样操作 + 用户能拒 + 超时杀进程 + 审计 + 总开关 + 不提权。
///
/// 只拦写，不拦读——`read_file` 读 `C:\Windows\win.ini` 没有任何危害，
/// 而拦了会让"帮我看下这个系统文件"这类正常请求莫名失败。
class FilePolicy {
  FilePolicy({required List<String> sealedRoots, PathRealizer? realizer})
    : sealedRoots = List.unmodifiable(sealedRoots),
      // 字段是私有的，具名参数不能叫 `_realizer`（私有名字不能做具名参数），
      // 所以这里只能手写赋值，linter 的建议在此不适用。跟 `ToolContext` 里
      // `_logger` 那处是同一个情况。
      // ignore: prefer_initializing_formals
      _realizer = realizer;

  /// 常用的系统目录都不许写。
  ///
  /// ⚠️ **故意不封盘根**（`C:\`）。封了的话整个 C 盘都写不了，而"往 C 盘根目录
  /// 扔个文件"其实不危险，只是不整洁。宁可漏这一条，也不要让正常的写失败。
  factory FilePolicy.standard({
    Map<String, String>? environment,
    PathRealizer? realizer,
    bool isWindows = true,
  }) {
    final env = environment ?? Platform.environment;
    final roots = <String>[];
    if (isWindows) {
      for (final name in const [
        'SystemRoot',
        'windir',
        'ProgramFiles',
        'ProgramFiles(x86)',
        'ProgramW6432',
        'ProgramData',
      ]) {
        final value = _env(env, name);
        if (value != null && value.isNotEmpty) roots.add(value);
      }
      // 环境变量被清空时也得有兜底，否则这台机器上就完全没防护了。
      if (roots.isEmpty) {
        roots.addAll(const [r'C:\Windows', r'C:\Program Files', r'C:\ProgramData']);
      }
    } else {
      roots.addAll(const [
        '/etc', '/usr', '/bin', '/sbin', '/boot', '/dev', '/proc', '/sys',
        '/System', '/Library',
      ]);
    }
    return FilePolicy(sealedRoots: roots, realizer: realizer);
  }

  /// 不封任何东西。**只给测试和明确知道自己在干什么的场景用。**
  const FilePolicy.unrestricted() : sealedRoots = const [], _realizer = null;

  /// 这些目录（含其下所有内容）不许写、不许删、不许覆盖。
  final List<String> sealedRoots;

  final PathRealizer? _realizer;

  /// 写这个路径行不行。行返回 null，不行返回一句给模型看的理由。
  String? refuseWrite(String absolutePath) {
    final shape = _shapeProblem(absolutePath, forWrite: true);
    if (shape != null) return shape;

    final real = _realize(absolutePath);
    for (final root in sealedRoots) {
      final realRoot = _realize(root);
      if (realRoot.isEmpty) continue;
      if (_isSameOrInside(real, realRoot)) {
        return '`$absolutePath` 在系统目录 `$realRoot` 里面，我不会往里写东西。'
            '换个位置——用户自己的桌面、文档、或者项目目录都行。';
      }
    }
    return null;
  }

  /// 读这个路径行不行。
  ///
  /// 只拦设备路径和非常规写法。系统目录**可以读**。
  String? refuseRead(String absolutePath) =>
      _shapeProblem(absolutePath, forWrite: false);

  /// 形状上就有问题的路径。
  ///
  /// 两条，都跟"内容写到哪里去了"有关，所以只在动手前判、判完再 memo 也没意义：
  /// - `\\.\` 设备路径：`\\.\PhysicalDrive0` 这种写一下不是"写个文件"，
  ///   是直接怼硬件。不碰。
  /// - ADS：`报告.txt:hidden` 在 NTFS 上是"文件的隐藏数据流"。它不显示在
  ///   资源管理器里，用户删不掉也看不见——正是"偷偷写东西"的形状。
  static String? _shapeProblem(String path, {required bool forWrite}) {
    if (path.startsWith(r'\\.\')) {
      return '`$path` 是设备路径，不是普通文件，我不碰。';
    }
    if (!forWrite) return null;

    // 去掉 `\\?\` 长路径前缀再找冒号，否则 `\\?\C:\x` 里 `C:` 的冒号会被误判。
    final withoutPrefix = path.startsWith(r'\\?\') ? path.substring(4) : path;
    if (withoutPrefix.indexOf(':', 2) >= 0) {
      return '`$path` 带冒号，这是 NTFS 的备用数据流（ADS）——'
          '写进去的内容用户在资源管理器里看不到、也删不掉，不写。';
    }
    return null;
  }

  /// 拿真实路径。文件还不存在时，**从最近的存在祖先往下接**——
  /// 光对不存在的路径调 `resolveSymbolicLinksSync` 会直接抛异常，
  /// 而"新建一个文件"恰恰是最需要判策略的时刻。
  String _realize(String path) {
    final custom = _realizer;
    if (custom != null) return custom(path);
    return _realizeOnDisk(path);
  }

  static String _realizeOnDisk(String path) {
    var current = path;
    final tail = <String>[];
    for (var depth = 0; depth < 64; depth++) {
      try {
        // 目录要走 `Directory` 那一支：在 Windows 上拿 `File` 打开一个目录
        // 是打不开的，会抛异常，然后这里会一路往上退，退到最后把整条路径
        // 原样返回——**看起来没出错，防护却是关着的**。
        final kind = FileSystemEntity.typeSync(current);
        final String real;
        if (kind == FileSystemEntityType.directory) {
          real = Directory(current).resolveSymbolicLinksSync();
        } else {
          real = File(current).resolveSymbolicLinksSync();
        }
        if (tail.isEmpty) return real;
        return _joinAll(real, tail.reversed);
      } on FileSystemException {
        // 不存在（或者没权限看）就往上一层，把它当成尾部留着。
      }
      final parent = _parentOf(current);
      if (parent == null || parent == current) return path;
      final name = _baseName(current);
      if (name.isNotEmpty) tail.add(name);
      current = parent;
    }
    return path;
  }

  static String _joinAll(String base, Iterable<String> parts) {
    final sep = base.contains(r'\') ? r'\' : '/';
    var out = base;
    for (final p in parts) {
      out = out.endsWith(sep) ? '$out$p' : '$out$sep$p';
    }
    return out;
  }

  static String? _parentOf(String path) {
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    if (cut <= 0) return null;
    // `C:\` 的父目录是它自己。
    if (cut == 2 && RegExp(r'^[A-Za-z]:').hasMatch(path)) return path;
    return path.substring(0, cut);
  }

  static String _baseName(String path) {
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    return cut < 0 ? path : path.substring(cut + 1);
  }

  /// [child] 是不是 [parent] 本身或者它下面的东西。
  ///
  /// 比之前都把尾部残留的分隔符削掉，比的时候大小写不敏感——
  /// 第几层是 Windows 的规矩，第几层是"别把 `C:\Windows\` 和 `C:\Windows` 判成两个"。
  static bool _isSameOrInside(String child, String parent) {
    var c = _trimSeparators(child);
    var p = _trimSeparators(parent);
    if (p.isEmpty) return false;
    final isWindows = p.contains(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(p);
    if (isWindows) {
      c = c.toLowerCase();
      p = p.toLowerCase();
    }
    if (c == p) return true;
    final sep = isWindows ? r'\' : '/';
    // 封的根可能本身就以分隔符结尾（`C:\` 那种削不掉的盘根），
    // 再补一个就变成 `C:\\` 了，永远比不中。
    final prefix = p.endsWith(sep) ? p : '$p$sep';
    return c.startsWith(prefix);
  }

  static String _trimSeparators(String s) {
    var out = s;
    while (out.length > 1 && (out.endsWith(r'\') || out.endsWith('/'))) {
      // 盘根（`C:\`）保留那一根，削掉会变成 `C:`，那是"当前目录在 C 盘"的意思。
      if (out.length == 3 && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(out)) break;
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static String? _env(Map<String, String> env, String name) {
    final direct = env[name];
    if (direct != null) return direct;
    final want = name.toLowerCase();
    for (final e in env.entries) {
      if (e.key.toLowerCase() == want) return e.value;
    }
    return null;
  }
}
