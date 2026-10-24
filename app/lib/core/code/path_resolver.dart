/// 把用户和模型嘴里说的位置翻成绝对路径。
///
/// 这个文件**不碰文件系统**——不知道桌面到底存不存在，只知道"桌面这个词
/// 对应哪个字符串"。探路（读注册表、判断目录空不空）在
/// `lib/services/fs/windows_known_folders.dart` 里，那边探到结果再灌进来。
/// 这样一来这里的规则全是纯函数，测试给一张环境变量表就能覆盖。
library;

/// 用户会说的那几个位置。
enum KnownFolder {
  desktop,
  documents,
  downloads;

  /// 用户可能用的叫法。**小写，ASCII 的按小写比，中文原样比。**
  ///
  /// 收录标准是"真有人这么说过"，不是穷举同义词：`我的文档` 是 Windows
  /// 中文版文件夹的显示名，`doc` 是开发者顺口说的。宁可漏几个让它老老实实
  /// 报"不认识"，也别收太宽——猜错位置比报错烦人得多。
  List<String> get aliases => switch (this) {
    KnownFolder.desktop => const ['桌面', 'desktop'],
    KnownFolder.documents => const ['文档', '我的文档', 'documents', 'doc'],
    KnownFolder.downloads => const ['下载', '下载文件夹', 'downloads', 'download'],
  };

  String get label => switch (this) {
    KnownFolder.desktop => '桌面',
    KnownFolder.documents => '文档',
    KnownFolder.downloads => '下载',
  };
}

/// 解析不出来。工具层把它翻成给模型看的一句失败。
class PathResolveException implements Exception {
  const PathResolveException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PathResolver {
  PathResolver({
    required this.home,
    Map<String, String> environment = const {},
    Map<KnownFolder, String> knownFolders = const {},
    this.workingDirectory,
    this.isWindows = true,
  }) : environment = Map.unmodifiable(environment),
       knownFolders = Map.unmodifiable(knownFolders);

  /// 用户主目录。`~` 就是它。
  final String home;

  /// 环境变量表。**查的时候大小写不敏感**——Windows 上是这样，
  /// 而模型经常会写 `%UserProfile%` 这种大小写跟真实变量名对不上的形式。
  final Map<String, String> environment;

  /// 探到的已知位置。没探到的就是缺键，用的时候会如实报"没探到"。
  final Map<KnownFolder, String> knownFolders;

  /// 相对路径的基准。给了才允许相对路径。
  final String? workingDirectory;

  final bool isWindows;

  String? knownFolder(KnownFolder folder) => knownFolders[folder];

  /// 把 [raw] 翻成绝对路径。
  ///
  /// 能认这些写法：
  /// - `~` / `~/x` / `~\x`
  /// - `桌面` / `文档` / `下载`，以及 `桌面/报告.txt` 这种带后缀的
  /// - `%USERPROFILE%\x`，变量名大小写随便写
  /// - 绝对路径（`C:\...`、`\\server\share\...`）
  ///
  /// 认不出来就抛 [PathResolveException]，不猜。
  String resolve(String raw) {
    var s = raw.trim();
    if (s.isEmpty) {
      throw const PathResolveException('路径是空的。');
    }
    if (s.length > 4096) {
      throw const PathResolveException('路径长得不正常（超过 4096 字符）。');
    }

    s = _expandKnownFolderWord(s);
    s = _expandHome(s);
    s = _expandVariables(s);

    if (isWindows) {
      s = _toBackslashes(s);
    } else {
      s = s.replaceAll(r'\', '/');
    }
    s = _normalize(s);

    if (!_isAbsolute(s)) {
      final base = workingDirectory;
      if (base == null || !_isAbsolute(base)) {
        // **不拿"进程的当前目录"或者主目录顶上。** 顶上去会安静地把
        // `报表.xlsx` 写进程序安装目录或者用户主目录，用户在哪儿都找不到；
        // 而且和本文件另外两条规则自相矛盾——认不出「桌面」时是报错，
        // 认不出相对基准时却猜一个，逻辑上说不过去。
        throw PathResolveException(
          '`$raw` 是相对路径，但不知道相对于哪儿。请给绝对路径，'
          '或者用「桌面」「文档」「下载」开头。',
        );
      }
      s = _normalize(_join(base, s));
    }
    return s;
  }

  // ---- 四种展开 ----

  /// `桌面/报告.txt` → `<探到的桌面>\报告.txt`
  ///
  /// 只看**第一段**。中间出现的"桌面"只是个普通文件夹名，
  /// 替换它会把 `C:\备份\桌面\a.txt` 改得莫名其妙。
  String _expandKnownFolderWord(String s) {
    final head = _firstSegment(s);
    if (head == null || head.isEmpty) return s;

    final lower = head.toLowerCase();
    for (final folder in KnownFolder.values) {
      if (!folder.aliases.contains(lower) &&
          !folder.aliases.contains(head)) {
        continue;
      }
      final target = knownFolders[folder];
      if (target == null) {
        throw PathResolveException(
          '我没探到「${folder.label}」在哪儿。请改用绝对路径。',
        );
      }
      final rest = s.substring(head.length);
      return '$target$rest';
    }
    return s;
  }

  String _expandHome(String s) {
    if (s == '~') return home;
    if (s.startsWith('~/') || s.startsWith(r'~\')) {
      return '$home${s.substring(1)}';
    }
    return s;
  }

  /// `%USERPROFILE%\x` → 展开。反复扫到不动为止，因为变量值里可能还带变量
  /// （`%USERPROFILE%` 本身就可能展开成一个带 `%` 的串）。
  ///
  /// 遇到没定义的变量**直接报错而不是留原样**：留着的话路径会变成一个
  /// 字面量 `%FOO%` 目录名，在磁盘上悄悄造出一个垃圾文件夹。
  String _expandVariables(String s) {
    var out = s;
    for (var pass = 0; pass < 5; pass++) {
      final next = out.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
        final name = m.group(1)!;
        final value = lookupEnv(name);
        if (value == null || value.isEmpty) {
          throw PathResolveException('环境变量 `%$name%` 没有值，认不出这个路径。请改用绝对路径。');
        }
        return value;
      });
      if (next == out) return out;
      out = next;
    }
    return out;
  }

  /// 大小写不敏感的环境变量查询。**按需查，不预先建小写索引**——
  /// 建索引会让构造函数多一份状态，而且 `foo` 和 `FOO` 同时存在时
  /// 覆盖顺序变得依赖 Map 的迭代序，是那种"平时都对、偶尔莫名"的坑。
  String? lookupEnv(String name) {
    final direct = environment[name];
    if (direct != null) return direct;
    final want = name.toLowerCase();
    for (final entry in environment.entries) {
      if (entry.key.toLowerCase() == want) return entry.value;
    }
    return null;
  }

  // ---- 字符串整理 ----

  static String? _firstSegment(String s) {
    final cut = s.indexOf(RegExp(r'[\\/]'));
    return cut < 0 ? s : s.substring(0, cut);
  }

  /// 只把分隔符换掉，别的不碰。
  ///
  /// 开头的 `\\` 是 UNC（`\\server\share`）或设备路径（`\\?\C:\`），
  /// 原样保留——把它压成一个 `\` 就成了"当前盘根目录下的 server"，
  /// 完全不同的东西。
  static String _toBackslashes(String s) {
    if (s.startsWith(r'\\')) {
      // 这里不能用 raw string：`r'...'` 里的 `${...}` 是字面量，
      // 而且里面那个 `'` 会把字符串直接截断。
      return '\\\\${s.substring(2).replaceAll('/', r'\')}';
    }
    return s.replaceAll('/', r'\');
  }

  /// 折叠 `.` 和 `..`，压掉重复分隔符。**纯字符串操作，不碰磁盘。**
  ///
  /// `..` 在开头（或者吃掉了根）就丢弃——`C:\..\Windows` 就是 `C:\Windows`，
  /// 留着它只会让后面的路径比较更难写。真正的防绕过判定不靠这里，
  /// 靠 `FilePolicy` 拿 `resolveSymbolicLinks` 之后的真实路径去比。
  String _normalize(String s) {
    final sep = isWindows ? r'\' : '/';
    final prefix = _rootPrefix(s, sep);
    var body = s.substring(prefix.length);

    final parts = <String>[];
    for (final piece in body.split(RegExp(r'[\\/]+'))) {
      if (piece.isEmpty || piece == '.') continue;
      if (piece == '..') {
        if (parts.isNotEmpty && parts.last != '..') {
          parts.removeLast();
        }
        continue;
      }
      parts.add(piece);
    }
    final joined = parts.join(sep);
    if (prefix.isEmpty) {
      // ⚠️ 这里**不能**补一个前导分隔符。补了的话 `foo\bar` 会变成 `\foo\bar`，
      // 而 `_isAbsolute` 认定它是绝对路径——于是相对路径悄悄落到当前盘的根目录，
      // 还绕过了后面"相对路径要报错"的检查。
      return joined;
    }
    // `C:` / `\\server\share` 后面得跟一个分隔符才是完整的根。
    if (joined.isEmpty) return '$prefix$sep';
    return prefix.endsWith(sep) ? '$prefix$joined' : '$prefix$sep$joined';
  }

  /// 把开头的"根"切出来：`C:\`、`\\server\share\`、或者一个 `\`。
  static String _rootPrefix(String s, String sep) {
    if (s.startsWith(r'\\')) {
      // UNC 或设备路径：`\\server\share` 是根，`\\?\C:` 也算根。
      final rest = s.substring(2);
      final parts = rest.split(RegExp(r'[\\/]+'));
      if (parts.length >= 2 && parts[1].isNotEmpty) {
        return '$sep$sep${parts[0]}$sep${parts[1]}';
      }
      return '$sep$sep${parts.isEmpty ? '' : parts[0]}';
    }
    final drive = RegExp(r'^[A-Za-z]:');
    final m = drive.firstMatch(s);
    if (m != null) return '${m.group(0)!}$sep';
    if (s.startsWith('/') || s.startsWith(r'\')) return sep;
    return '';
  }

  bool _isAbsolute(String s) {
    if (isWindows) {
      return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(s) ||
          s.startsWith(r'\\') ||
          s.startsWith('/');
    }
    return s.startsWith('/');
  }

  String _join(String base, String rest) {
    final sep = isWindows ? r'\' : '/';
    final trimmed = rest.replaceFirst(RegExp(r'^[\\/]+'), '');
    return base.endsWith(sep) || base.endsWith('/')
        ? '$base$trimmed'
        : '$base$sep$trimmed';
  }
}
