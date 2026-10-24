import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../code/file_backup.dart';
import '../../code/file_policy.dart';
import '../../code/path_resolver.dart';
import '../n1_tool.dart';
import '../tool_context.dart';
import 'doc_tools.dart';

/// 读文件时最多往内存里灌多少字节。
///
/// 为什么不整个读进来：一个 2 GB 的日志文件会把进程直接撑死，而这只是个
/// "看一眼文件"的工具。4 MiB 足够覆盖代码和配置，超了就如实说只读了前面一截。
const int _readByteCap = 4 * 1024 * 1024;

/// 路径不存在时，顺手报一下同目录里有什么。对模型来说这是**省一轮**的关键——
/// 否则它只能瞎猜下一个路径再撞一次。
const int _siblingHintLimit = 20;

/// 递归搜索时跳过的目录名，**按小写比较**（Windows 目录名不区分大小写）。
///
/// 这些目录里要么是生成物、要么是成千上万个第三方文件。搜进去的结果对模型
/// 没价值，还会把一次搜索拖成几分钟——比搜不到更糟，因为它以为自己在干活。
const Set<String> _skippedDirs = {
  '.git',
  '.hg',
  '.svn',
  '.dart_tool',
  '.gradle',
  '.idea',
  '.next',
  '.nuxt',
  '.pub-cache',
  '.venv',
  '.vscode',
  '__pycache__',
  'build',
  'dist',
  'node_modules',
  'out',
  'pods',
  'target',
  'venv',
};

/// 一次搜索最多看多少个文件。
///
/// 没有这个上限时，用户一句「在 D 盘搜一下」就能让 App 扫十分钟，而模型和
/// 用户都以为它卡死了。到上限就**明说没看完**，别装作搜完了。
const int _maxScannedFiles = 20000;

/// 文件类的公共部分。
abstract class FileToolBase extends N1Tool {
  const FileToolBase({required this.paths, required this.policy});

  /// 读写文件也要进审计日志：用户过两天发现桌面上多了个文件，
  /// 得有个地方能查到是谁写的、什么时候写的。
  ///
  /// 只读的（`read_file` / `list_dir`）也记——"它翻过我的什么"同样是用户
  /// 会想知道的，而且放进来之后这一族的行为是一致的，不用记"哪几个要审"。
  @override
  bool get audited => true;

  final PathResolver paths;
  final FilePolicy policy;

  /// 解析路径 + 判策略，两件事一起做，四个工具都从这儿进。
  ///
  /// 提上来不只是为了少写重复：**以后加 `delete_file` 之类的工具，只要走这个
  /// 入口，受保护路径就自动拦住了**。分散在各工具里迟早会漏一个。
  Future<ToolResult> guard(
    Map<String, Object?> input,
    Future<ToolResult> Function(String absolute) body, {
    required bool forWrite,
  }) async {
    final String absolute;
    try {
      absolute = paths.resolve(N1Tool.requireString(input, 'path'));
    } on PathResolveException catch (e) {
      return ToolResult.fail(e.message);
    }

    final refusal = forWrite
        ? policy.refuseWrite(absolute)
        : policy.refuseRead(absolute);
    if (refusal != null) return ToolResult.fail(refusal);

    return await body(absolute);
  }

  /// 要原样的字符串，**不 trim**。
  ///
  /// `N1Tool.requireString` 会 trim——对路径没问题，对文件内容就是灾难：
  /// 写一段代码，结尾的换行和开头缩进全没了；`old_string` 拿去匹配也永远
  /// 匹配不上。这里只要"这个参数确实给了字符串"，空串是合法的（写空文件、
  /// 把一段代码删掉都要用空串）。
  static String requireRaw(Map<String, Object?> input, String key) {
    final v = input[key];
    if (v is! String) {
      throw ToolInputException('缺少必填参数 `$key`（要字符串）');
    }
    return v;
  }

  /// 先写临时文件再改名。
  ///
  /// 直接往目标文件上写的话，写到一半进程没了（断电、被任务管理器杀了）
  /// 就留下一个**半截文件**——用户的源码就这样没了。同目录下的临时文件改名
  /// 是原子的，要么旧的要么新的，没有中间态。
  ///
  /// 临时文件必须**同目录**：跨卷改名不是原子操作，会被降级成复制。
  static Future<void> writeAtomically(File file, List<int> bytes) async {
    final parent = file.parent;
    final temp = File(
      '${parent.path}${Platform.pathSeparator}'
      '.${_baseName(file.path)}.niuwa-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsBytes(bytes, flush: true);
      try {
        await temp.rename(file.path);
      } on FileSystemException {
        // Windows 上改名撞到已存在的目标时，某些情况下会失败。退成
        // "删掉旧的再改名"——注意**顺序不能反**，先删了再发现改名失败就两头空。
        // 这里旧文件已经备份过，所以这一步是安全的。
        if (await file.exists()) await file.delete();
        await temp.rename(file.path);
      }
    } finally {
      // 失败路径上别把垃圾留在用户目录里。
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {}
      }
    }
  }

  /// 同级的目录名报给模型看。
  static Future<String> siblingHint(String absolute) async {
    final parent = _parentOf(absolute);
    if (parent == null) return '';
    try {
      final dir = Directory(parent);
      if (!await dir.exists()) return '\n（`$parent` 也不存在。）';
      final names = <String>[];
      await for (final e in dir.list(followLinks: false)) {
        if (names.length >= _siblingHintLimit) break;
        names.add(_baseName(e.path));
      }
      if (names.isEmpty) return '\n（`$parent` 是空的。）';
      return '\n`$parent` 里有：${names.join('、')}';
    } catch (_) {
      return '';
    }
  }

  static String? _parentOf(String path) {
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    if (cut <= 0) return null;
    return path.substring(0, cut);
  }

  static String _baseName(String path) {
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    return cut < 0 ? path : path.substring(cut + 1);
  }
}

class ReadFileTool extends FileToolBase {
  const ReadFileTool({required super.paths, required super.policy});

  @override
  bool get runsInParallel => true;

  @override
  String get name => 'read_file';

  @override
  String get description =>
      '读一个文本文件。返回内容**带行号前缀**（形如 `12\\t代码`），那串数字只是'
      '给你对齐用的，不是文件内容——拿去当 edit_file 的 old_string 会匹配不上。'
      '大文件用 offset/limit 只看一段。只认 UTF-8；GBK 的老文件会明确报错，'
      '这时别硬改，告诉用户。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': '文件路径。可以是绝对路径，也可以用「桌面」「文档」「下载」或 ~ 开头',
      },
      'offset': {'type': 'integer', 'description': '从第几行开始（从 1 数），默认第 1 行'},
      'limit': {'type': 'integer', 'description': '最多读多少行，默认 2000'},
    },
    'required': ['path'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      guard(input, (absolute) async {
        final offset = N1Tool.optionalInt(input, 'offset', fallback: 1);
        final limit = N1Tool.optionalInt(input, 'limit', fallback: 2000);

        final file = File(absolute);
        final kind = FileSystemEntity.typeSync(absolute);
        if (kind == FileSystemEntityType.notFound) {
          return ToolResult.fail(
            '找不到 `$absolute`。${await FileToolBase.siblingHint(absolute)}',
          );
        }
        if (kind == FileSystemEntityType.directory) {
          return ToolResult.fail('`$absolute` 是个目录，不是文件。要看里面有什么用 list_dir。');
        }

        final bytes = await _readCapped(file);
        if (bytes.isEmpty) {
          return ToolResult.ok('$absolute\t（空文件）');
        }

        // BOM 要吃掉，否则第一行会带上一个看不见的 U+FEFF，
        // 模型复制这行去做匹配，怎么都对不上。
        var body = bytes;
        if (body.length >= 3 &&
            body[0] == 0xEF &&
            body[1] == 0xBB &&
            body[2] == 0xBF) {
          body = body.sublist(3);
        }

        final String text;
        try {
          text = utf8.decode(body);
        } on FormatException {
          return ToolResult.fail(
            '`$absolute` 不是 UTF-8 文本（多半是 GBK 编码的老文件，也可能是二进制）。'
            '我不会猜着解码——猜错了你拿到的就是乱码，然后会基于乱码去改文件。'
            '告诉用户这个文件需要另存为 UTF-8。',
          );
        }

        final lines = const LineSplitter().convert(text);
        final total = lines.length;
        final start = offset < 1 ? 1 : offset;
        if (start > total) {
          return ToolResult.ok('$absolute 一共 $total 行，没有第 $start 行。');
        }
        final end = (start - 1 + (limit < 1 ? 1 : limit)).clamp(start, total);

        final buffer = StringBuffer()
          ..writeln('$absolute\t（共 $total 行${total > end ? '，下面给第 $start–$end 行' : ''}）')
          ..writeln();

        final width = end.toString().length;
        for (var i = start; i <= end; i++) {
          buffer.writeln('${i.toString().padLeft(width)}\t${lines[i - 1]}');
        }

        if (total > end) {
          buffer.writeln();
          buffer.writeln('（后面还有 ${total - end} 行，要看就带 offset: ${end + 1}）');
        }
        if (bytes.length >= _readByteCap) {
          buffer.writeln(
            '（文件超过 ${_readByteCap ~/ (1024 * 1024)} MiB，只读了前面这么多。）',
          );
        }

        return ToolResult.ok(
          buffer.toString().trimRight(),
          meta: {'path': absolute, 'lines': total},
        );
      }, forWrite: false);

  /// 一块一块读，凑够上限就停。`readAsBytes` 会整个读进来，正好是这里要避免的。
  static Future<List<int>> _readCapped(File file) async {
    final out = <int>[];
    await for (final chunk in file.openRead()) {
      out.addAll(chunk);
      if (out.length >= _readByteCap) {
        return out.sublist(0, _readByteCap);
      }
    }
    return out;
  }
}

class WriteFileTool extends FileToolBase {
  const WriteFileTool({
    required super.paths,
    required super.policy,
    required this.backups,
  });

  final FileBackupStore backups;

  @override
  String get name => 'write_file';

  @override
  String get description =>
      '写一个文本文件（整个覆盖）。改一个已有文件里的**小部分**时用 edit_file，'
      '别用这个——整个重写会把文件里你没看见的部分也抹掉。'
      '目录不存在时要显式带 create_parents: true，这是故意的：写错一个字母'
      '就凭空造出一棵目录树，比失败一次烦人得多。'
      '覆盖已有文件会自动备份，备份位置会告诉你。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': '写到哪个文件'},
      'content': {'type': 'string', 'description': '文件的完整内容'},
      'create_parents': {
        'type': 'boolean',
        'description': '父目录不存在时自动创建，默认 false',
      },
    },
    'required': ['path', 'content'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      guard(input, (absolute) async {
        final content = FileToolBase.requireRaw(input, 'content');
        final createParents = input['create_parents'] == true;

        final parentPath = _parent(absolute);
        if (parentPath != null) {
          final parent = Directory(parentPath);
          if (!await parent.exists()) {
            if (!createParents) {
              return ToolResult.fail(
                '`$parentPath` 这个目录不存在。'
                '如果确实要建，重新调一次并带上 create_parents: true；'
                '如果是路径写错了，先改对再来。',
              );
            }
            try {
              await parent.create(recursive: true);
            } on FileSystemException catch (e) {
              return ToolResult.fail('建不了目录 `$parentPath`：${e.osError?.message ?? e.message}');
            }
          }
        }

        final file = File(absolute);
        if (FileSystemEntity.typeSync(absolute) == FileSystemEntityType.directory) {
          return ToolResult.fail('`$absolute` 是个目录，写不了。');
        }

        final existed = await file.exists();
        FileBackup? backup;
        if (existed) {
          try {
            backup = await backups.backup(absolute);
          } catch (e) {
            // 备份失败就**不写**。继续写下去的话，结果里会含糊地说"已覆盖"，
            // 而用户以为自己有回滚阀——实际上没有。
            return ToolResult.fail(
              '要覆盖 `$absolute`，但备份失败（$e），所以没动它。'
              '告诉用户这件事，让他自己决定。',
            );
          }
        }

        try {
          await FileToolBase.writeAtomically(file, utf8.encode(content));
        } on FileSystemException catch (e) {
          return ToolResult.fail('写 `$absolute` 失败：${e.osError?.message ?? e.message}');
        }

        final bytes = utf8.encode(content).length;
        final lines = const LineSplitter().convert(content).length;
        final buffer = StringBuffer()
          ..write('${existed ? '已覆盖' : '已写入'} `$absolute`')
          ..write('（$bytes 字节，$lines 行）');
        if (backup != null) {
          // ⚠️ 这里必须写 `${backup.copyPath}`：写成 `$backup.copyPath` 的话
          // 插值的是 backup 对象本身，会打印出 `Instance of 'FileBackup'`，
          // 后面那截 `.copyPath` 变成字面量。跟 `tool_registry.dart` 里
          // `$call.name` 那处是同一个坑。
          buffer.write('\n原来的那份备份在 `${backup.copyPath}`');
          final pruned = await backups.prune();
          if (pruned > 0) buffer.write('（顺手清掉了 $pruned 个更老的备份）');
        }

        return ToolResult.ok(buffer.toString(), meta: {'path': absolute});
      }, forWrite: true);


  static String? _parent(String path) {
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    if (cut <= 0) return null;
    final parent = path.substring(0, cut);
    if (parent.length == 2 && RegExp(r'^[A-Za-z]:').hasMatch(parent)) {
      return '$parent\\';
    }
    return parent;
  }

}

class EditFileTool extends FileToolBase {
  const EditFileTool({
    required super.paths,
    required super.policy,
    required this.backups,
  });

  final FileBackupStore backups;

  @override
  String get name => 'edit_file';

  @override
  String get description =>
      '把文件里的一段文字换成另一段。**改代码默认用这个，别用 write_file。**'
      '`old_string` 必须在文件里只出现一次，否则会被拒绝——出现多次时'
      '多给几行上下文让它变唯一，或者确认要全改就带 replace_all: true。'
      '`old_string` 和 `new_string` 里**别带 read_file 的行号前缀**。'
      '换行符不用操心：文件是 CRLF 就按 CRLF 写回。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': '改哪个文件'},
      'old_string': {'type': 'string', 'description': '要被替换掉的原文字'},
      'new_string': {'type': 'string', 'description': '替换成什么；删除就传空串'},
      'replace_all': {
        'type': 'boolean',
        'description': '允许替换全部出现处，默认 false（只允许唯一匹配）',
      },
    },
    'required': ['path', 'old_string', 'new_string'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      guard(input, (absolute) async {
        final oldString = FileToolBase.requireRaw(input, 'old_string');
        final newString = FileToolBase.requireRaw(input, 'new_string');
        final replaceAll = input['replace_all'] == true;

        if (oldString.isEmpty) {
          return ToolResult.fail(
            '`old_string` 是空的——空串在文件里处处都匹配，没法知道你想改哪儿。'
            '把要替换掉的那段原文写进来。',
          );
        }
        if (oldString == newString) {
          return ToolResult.fail('`old_string` 和 `new_string` 一模一样，没什么可改的。');
        }

        final kind = FileSystemEntity.typeSync(absolute);
        if (kind == FileSystemEntityType.notFound) {
          return ToolResult.fail(
            '找不到 `$absolute`，没得改。${await FileToolBase.siblingHint(absolute)}',
          );
        }
        if (kind == FileSystemEntityType.directory) {
          return ToolResult.fail('`$absolute` 是个目录，不是文件。');
        }

        final String original;
        try {
          original = utf8.decode(await File(absolute).readAsBytes());
        } on FormatException {
          return ToolResult.fail('`$absolute` 不是 UTF-8 文本，改不了。别硬来，告诉用户。');
        }

        // 换行的处理走"整篇归一 → 改 → 按原来的风格写回"。
        //
        // 为什么不做"精确匹配失败再试 CRLF"：那要处理"匹配到了但偏移量算在
        // 另一套坐标里"，很容易改错位置。归一之后只有一套坐标，位置一定对。
        // 代价是**混着 CRLF 和 LF 的文件会被统一成占多数的那种**——
        // 少见，而且统一本身不是坏事，比改错位置强。
        final useCrlf = original.contains('\r\n');
        final normalized = original.replaceAll('\r\n', '\n');
        final needle = oldString.replaceAll('\r\n', '\n');
        final replacement = newString.replaceAll('\r\n', '\n');

        final hits = _findAll(normalized, needle);
        if (hits.isEmpty) {
          return ToolResult.fail(await _notFoundMessage(absolute, normalized, needle));
        }
        if (hits.length > 1 && !replaceAll) {
          return ToolResult.fail(_ambiguousMessage(absolute, normalized, hits.length, hits));
        }

        final targets = replaceAll ? hits : [hits.first];
        final buffer = StringBuffer();
        var cursor = 0;
        for (final hit in targets) {
          buffer
            ..write(normalized.substring(cursor, hit))
            ..write(replacement);
          cursor = hit + needle.length;
        }
        buffer.write(normalized.substring(cursor));

        var updated = buffer.toString();
        if (useCrlf) updated = updated.replaceAll('\n', '\r\n');
        if (updated == original) {
          return ToolResult.fail('改完之后内容没变——检查一下 `new_string`。');
        }

        try {
          await backups.backup(absolute);
        } catch (e) {
          return ToolResult.fail('要改 `$absolute`，但备份失败（$e），所以没动它。');
        }
        try {
          await File(absolute).writeAsString(updated, flush: true);
        } on FileSystemException catch (e) {
          return ToolResult.fail('写 `$absolute` 失败：${e.osError?.message ?? e.message}');
        }

        final lineNo = '\n'.allMatches(normalized.substring(0, targets.first)).length + 1;
        return ToolResult.ok(
          '已改 `$absolute`：替换了 ${targets.length} 处，'
          '第一处在第 $lineNo 行${useCrlf ? '（文件是 CRLF 换行，已按原样写回）' : ''}。',
          meta: {'path': absolute, 'replacements': targets.length},
        );
      }, forWrite: true);

  /// 所有不重叠的出现位置。
  static List<int> _findAll(String haystack, String needle) {
    final out = <int>[];
    var from = 0;
    while (true) {
      final at = haystack.indexOf(needle, from);
      if (at < 0) return out;
      out.add(at);
      from = at + needle.length;
    }
  }

  /// 找不到时的说法要**尽量让下一轮能改对**，不然模型会拿同一段原文反复撞。
  static Future<String> _notFoundMessage(
    String absolute,
    String content,
    String needle,
  ) async {
    final buffer = StringBuffer(
      '`$absolute` 里找不到这段原文。这不是"文件不存在"，是文字对不上——'
      '多半是缩进、空行或者换行符不一样。\n',
    );

    // 最常见的一类：首尾空白差一点。直接指出来，比让它猜强。
    final trimmed = needle.trim();
    if (trimmed.isNotEmpty && trimmed != needle && content.contains(trimmed)) {
      buffer.writeln(
        '提示：去掉首尾空白之后能在文件里找到，说明差在缩进或者空行上。'
        '先用 read_file 看一眼那段的确切样子再改。',
      );
      return buffer.toString();
    }

    // 其次常见：行号前缀被复制进来了，或者只错了一行。把最像的那几行摆出来。
    final firstLine = needle
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (firstLine.isNotEmpty) {
      final lines = const LineSplitter().convert(content);
      final near = <String>[];
      for (var i = 0; i < lines.length && near.length < 3; i++) {
        if (lines[i].contains(firstLine)) {
          final from = i - 1 < 0 ? 0 : i - 1;
          final to = (i + 2).clamp(0, lines.length);
          near.add(
            '  第 ${i + 1} 行附近：\n'
            '${lines.sublist(from, to).asMap().entries.map((e) => '    ${from + e.key + 1}\t${e.value}').join('\n')}',
          );
        }
      }
      if (near.isNotEmpty) {
        buffer
          ..writeln('文件里和 `$firstLine` 沾边的行：')
          ..writeln(near.join('\n'));
        return buffer.toString();
      }
    }

    buffer.write('先 read_file 把那个文件看一遍，照着原文复制。');
    return buffer.toString();
  }

  static String _ambiguousMessage(
    String absolute,
    String content,
    int count,
    List<int> hits,
  ) {
    final lines = const LineSplitter().convert(content);
    final buffer = StringBuffer(
      '`old_string` 在 `$absolute` 里出现了 $count 次，不确定你想改哪个，所以没动。\n'
      '两个办法：多带几行上下文让它变唯一；或者确认全都要改，带 replace_all: true。\n',
    );
    for (final hit in hits.take(3)) {
      final lineNo = '\n'.allMatches(content.substring(0, hit)).length + 1;
      final index = lineNo - 1;
      final from = index - 2 < 0 ? 0 : index - 2;
      final to = (index + 3).clamp(0, lines.length);
      buffer
        ..writeln('第 $lineNo 行附近：')
        ..writeln(
          lines
              .sublist(from, to)
              .asMap()
              .entries
              .map((e) => '  ${from + e.key + 1}\t${e.value}')
              .join('\n'),
        );
    }
    if (count > 3) buffer.writeln('（还有 ${count - 3} 处没列。）');
    return buffer.toString();
  }
}

class ListDirTool extends FileToolBase {
  const ListDirTool({required super.paths, required super.policy});

  @override
  bool get runsInParallel => true;

  @override
  String get name => 'list_dir';

  @override
  String get description =>
      '列一个目录里有什么。不知道文件叫什么、或者路径被拒了想看看附近有什么时用。'
      '只列这一层，不递归。返回里带类型、大小和修改时间。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': '目录路径'},
      'limit': {'type': 'integer', 'description': '最多列多少条，默认 200'},
    },
    'required': ['path'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      guard(input, (absolute) async {
        final limit = N1Tool.optionalInt(input, 'limit', fallback: 200);
        final cap = limit < 1 ? 1 : (limit > 2000 ? 2000 : limit);

        final kind = FileSystemEntity.typeSync(absolute);
        if (kind == FileSystemEntityType.notFound) {
          return ToolResult.fail(
            '找不到 `$absolute`。${await FileToolBase.siblingHint(absolute)}',
          );
        }
        if (kind != FileSystemEntityType.directory) {
          return ToolResult.fail('`$absolute` 是个文件，不是目录。看内容用 read_file。');
        }

        final rows = <_Row>[];
        var overflowed = false;
        try {
          await for (final entity in Directory(absolute).list(followLinks: false)) {
            if (rows.length >= cap) {
              overflowed = true;
              break;
            }
            rows.add(await _Row.of(entity));
          }
        } on FileSystemException catch (e) {
          return ToolResult.fail('列不了 `$absolute`：${e.osError?.message ?? e.message}');
        }

        if (rows.isEmpty) return ToolResult.ok('`$absolute` 是空的。');

        // 目录排前面，各自按名字排。跟资源管理器一个顺序，模型和人看着都顺。
        rows.sort((a, b) {
          final aDir = a.isContainer ? 0 : 1;
          final bDir = b.isContainer ? 0 : 1;
          if (aDir != bDir) return aDir - bDir;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

        final nameWidth = rows
            .map((r) => r.name.length)
            .reduce((a, b) => a > b ? a : b)
            .clamp(0, 48);

        final buffer = StringBuffer()
          ..writeln('$absolute（${rows.length} 项${overflowed ? '，只列了前面这些' : ''}）')
          ..writeln();
        for (final row in rows) {
          buffer.writeln(row.format(nameWidth));
        }
        if (overflowed) {
          buffer.writeln('（还有更多没列，用 limit 调大，或者换个更具体的目录。）');
        }

        return ToolResult.ok(buffer.toString().trimRight(), meta: {'path': absolute});
      }, forWrite: false);
}

class _Row {
  const _Row({
    required this.name,
    required this.isContainer,
    required this.isLink,
    required this.size,
    required this.modified,
  });

  final String name;
  final bool isContainer;
  final bool isLink;
  final int? size;
  final DateTime? modified;

  static Future<_Row> of(FileSystemEntity entity) async {
    final name = entity.path.split(RegExp(r'[\\/]')).last;
    final isLink = entity is Link;
    var isDir = entity is Directory;

    // 坏掉的链接拿不到目标，落到"文件"那一类，别让它把整次列目录带崩。
    if (isLink) {
      try {
        isDir = FileSystemEntity.isDirectorySync(entity.path);
      } catch (_) {
        isDir = false;
      }
    }

    int? size;
    DateTime? modified;
    try {
      final stat = await entity.stat();
      modified = stat.modified;
      if (!isDir) size = stat.size;
    } catch (_) {}

    return _Row(
      name: name,
      isContainer: isDir,
      isLink: isLink,
      size: size,
      modified: modified,
    );
  }

  String format(int nameWidth) {
    final tag = isLink ? '[链接]' : (isContainer ? '[目录]' : '[文件]');
    final sizeText = (size ?? 0).toString().padLeft(10);
    final time = modified == null ? '                ' : _stamp(modified!);
    return '$tag $sizeText  $time  $name';
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

// ---- 搜索类工具共用 ----

/// 深度遍历 [dir]，把每个文件交给 [visit]。
///
/// 自己写递归而不是 `Directory.list(recursive: true)`，因为**后者不能剪枝**：
/// 一旦递归下去，`node_modules` 里几万个文件就全被列出来了。这里在进入子目录
/// 之前就按 [_skippedDirs] 挡掉。
///
/// [visit] 返回 false 表示"够了，别再看后面的文件"。
Future<void> _walkFiles(
  Directory dir,
  Future<bool> Function(File file) visit, {
  int maxFiles = _maxScannedFiles,
}) async {
  var visited = 0;
  var stopped = false;

  Future<void> walk(Directory d) async {
    if (stopped || visited >= maxFiles) return;
    try {
      await for (final entity in d.list(followLinks: false)) {
        if (stopped || visited >= maxFiles) return;
        if (entity is Directory) {
          final name = FileToolBase._baseName(entity.path).toLowerCase();
          if (_skippedDirs.contains(name)) continue;
          await walk(entity);
        } else if (entity is File) {
          visited++;
          if (!await visit(entity)) stopped = true;
        }
      }
    } on FileSystemException {
      // 没权限的子目录跳过就行，不能因为一个目录把整次搜索打断。
    }
  }

  await walk(dir);
}

/// 前 8000 字节里出现 NUL 就当二进制。
///
/// 不判的话，搜一个 exe 或图片会捞出一堆乱码行，既没用又占上下文。
bool _looksBinary(List<int> bytes) {
  final n = bytes.length < 8000 ? bytes.length : 8000;
  for (var i = 0; i < n; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// 通配符转正则。支持 `*`（单层）、`**`（任意层）、`?`（单个字符）、
/// `{a,b}`（多选一）。
///
/// **不区分大小写**：这个实现只服务 Windows（文件工具在别的平台不注册），
/// 而 Windows 的文件名本来就不分大小写。分大小写会让 `*.DART` 找不到
/// `a.dart`，跟用户在资源管理器里的直觉相反。
RegExp _globToRegExp(String pattern) {
  final source = pattern.replaceAll('\\', '/');
  final buffer = StringBuffer('^');
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == '*') {
      final isDouble = i + 1 < source.length && source[i + 1] == '*';
      if (isDouble) {
        i += 2;
        // `**/` 里的斜杠要一起吃掉：`**/*.dart` 应该能匹配根目录下的
        // `a.dart`，而不是只匹配至少一层子目录里的文件。
        if (i < source.length && source[i] == '/') {
          buffer.write('(?:.*/)?');
          i++;
        } else {
          buffer.write('.*');
        }
      } else {
        buffer.write('[^/]*');
        i++;
      }
    } else if (c == '?') {
      buffer.write('[^/]');
      i++;
    } else if (c == '{') {
      final end = source.indexOf('}', i + 1);
      if (end < 0) {
        buffer.write(RegExp.escape(c));
        i++;
      } else {
        final parts = source.substring(i + 1, end).split(',');
        buffer.write('(?:${parts.map(RegExp.escape).join('|')})');
        i = end + 1;
      }
    } else {
      buffer.write(RegExp.escape(c));
      i++;
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString(), caseSensitive: false);
}

class GrepTool extends FileToolBase {
  const GrepTool({required super.paths, required super.policy});

  @override
  bool get runsInParallel => true;

  @override
  String get name => 'grep';

  @override
  String get description =>
      '在文件或整个目录里按正则搜内容，返回命中的行号和那一行。'
      '找"哪个文件里有这个函数/这句话"时用，别用 read_file 一个个翻。'
      '会自动跳过 .git、node_modules、build 这些目录，二进制文件和超过 4 MiB 的'
      '文件也会跳过。pattern 是正则，不是通配符；搜普通文字直接写就行。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': '正则表达式，例如 `class\\\\s+\\\\w+`；搜普通文字就直接写那几个字',
      },
      'path': {
        'type': 'string',
        'description': '在哪个文件或目录里搜。传目录会递归往下找。',
      },
      'glob': {
        'type': 'string',
        'description': '只看文件名匹配这个通配符的文件，例如 `*.dart`。不填就搜所有文本文件',
      },
      'case_sensitive': {
        'type': 'boolean',
        'description': '是否区分大小写，默认 false',
      },
      'context': {
        'type': 'integer',
        'description': '每条匹配前后各带几行上下文，默认 0，最多 5',
      },
      'max_results': {
        'type': 'integer',
        'description': '最多返回多少条匹配行，默认 100，最多 500',
      },
    },
    'required': ['pattern', 'path'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      guard(input, (absolute) async {
        final pattern = N1Tool.requireString(input, 'pattern');
        final globFilter = N1Tool.optionalString(input, 'glob');
        final caseSensitive = input['case_sensitive'] == true;
        final contextLines = _bounded(
          N1Tool.optionalInt(input, 'context', fallback: 0),
          0,
          5,
        );
        final maxResults = _bounded(
          N1Tool.optionalInt(input, 'max_results', fallback: 100),
          1,
          500,
        );

        final RegExp re;
        try {
          re = RegExp(pattern, caseSensitive: caseSensitive);
        } on FormatException catch (e) {
          return ToolResult.fail(
            '正则写错了：${e.message}。'
            '如果只是想搜一段普通文字，把括号、方括号、反斜杠这些转义一下再试。',
          );
        }
        final RegExp? fileFilter =
            globFilter == null ? null : _globToRegExp(globFilter);

        final type = FileSystemEntity.typeSync(absolute);
        if (type == FileSystemEntityType.notFound) {
          return ToolResult.fail(
            '找不到 `$absolute`。${await FileToolBase.siblingHint(absolute)}',
          );
        }
        if (type == FileSystemEntityType.link) {
          return ToolResult.fail('`$absolute` 是个链接，换个真实路径再搜。');
        }
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.directory) {
          return ToolResult.fail('`$absolute` 既不是文件也不是目录。');
        }

        final hits = <String>[];
        final hitFiles = <String>{};
        var matchCount = 0;
        var truncated = false;
        var skippedBig = 0;
        var skippedBinary = 0;

        Future<bool> searchFile(File file) async {
          if (fileFilter != null &&
              !fileFilter.hasMatch(FileToolBase._baseName(file.path))) {
            return true;
          }

          int size;
          try {
            size = await file.length();
          } on FileSystemException {
            return true;
          }
          if (size > _readByteCap) {
            skippedBig++;
            return true;
          }

          List<int> bytes;
          try {
            bytes = await file.readAsBytes();
          } on FileSystemException {
            return true;
          }
          if (_looksBinary(bytes)) {
            skippedBinary++;
            return true;
          }

          final text = utf8
              .decode(bytes, allowMalformed: true)
              .replaceAll('\r\n', '\n');
          final lines = text.split('\n');
          // 以换行结尾的文本会在末尾多出一个空串，那不是真实的一行。
          if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

          final printed = <int>{};
          for (var i = 0; i < lines.length; i++) {
            if (!re.hasMatch(lines[i])) continue;

            matchCount++;
            hitFiles.add(file.path);

            final from = _bounded(i - contextLines, 0, lines.length - 1);
            final to = _bounded(i + contextLines, 0, lines.length - 1);
            for (var j = from; j <= to; j++) {
              // 相邻两条命中共享的上下文只输出一次。
              if (!printed.add(j)) continue;
              final sep = j == i ? ':' : '-';
              hits.add('${file.path}:${j + 1}$sep ${lines[j]}');
            }

            if (matchCount >= maxResults) {
              truncated = true;
              return false;
            }
          }
          return true;
        }

        if (type == FileSystemEntityType.file) {
          await searchFile(File(absolute));
        } else {
          await _walkFiles(Directory(absolute), searchFile);
        }

        if (matchCount == 0) {
          final notes = <String>[];
          if (globFilter != null) notes.add('只看 `$globFilter`');
          if (skippedBig > 0) notes.add('跳过 $skippedBig 个超过 4 MiB 的文件');
          if (skippedBinary > 0) notes.add('跳过 $skippedBinary 个二进制文件');
          final suffix = notes.isEmpty ? '' : '（${notes.join('，')}）';
          return ToolResult.ok(
            '在 `$absolute` 里没有找到匹配 `$pattern` 的内容$suffix。',
          );
        }

        final buffer = StringBuffer()
          ..writeln(
            '在 ${hitFiles.length} 个文件里找到 $matchCount 处匹配'
            '（pattern: `$pattern`${caseSensitive ? '，区分大小写' : ''}）：',
          )
          ..writeln();
        for (final hit in hits) {
          buffer.writeln(hit);
        }
        if (truncated) {
          buffer.writeln(
            '（只列了前 $maxResults 条。用更具体的 pattern、加 glob、'
            '或者缩小 path 再搜。）',
          );
        }
        if (skippedBig > 0) {
          buffer.writeln('（另有 $skippedBig 个超过 4 MiB 的文件没搜。）');
        }
        return ToolResult.ok(
          buffer.toString().trimRight(),
          meta: {'files': hitFiles.length, 'matches': matchCount},
        );
      }, forWrite: false);
}

class GlobTool extends FileToolBase {
  const GlobTool({required super.paths, required super.policy});

  @override
  bool get runsInParallel => true;

  @override
  String get name => 'glob';

  @override
  String get description =>
      '按文件名找文件，支持 `*`、`**`、`?`、`{a,b}`。'
      '不知道文件在哪、只知道大概叫什么时用，比一层层 list_dir 快。'
      '例子：`**/*.dart`、`docs/**/*.md`、`*.{jpg,png}`。'
      '会自动跳过 .git、node_modules、build 这些目录，结果按修改时间从新到旧。';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': '相对 path 的通配符，例如 `**/*.dart`',
      },
      'path': {
        'type': 'string',
        'description': '从哪个目录开始找',
      },
      'limit': {
        'type': 'integer',
        'description': '最多返回多少个文件，默认 100，最多 1000',
      },
    },
    'required': ['pattern', 'path'],
  };

  @override
  Future<ToolResult> call(Map<String, Object?> input, ToolContext ctx) =>
      guard(input, (absolute) async {
        final rawPattern = N1Tool.requireString(input, 'pattern');
        final pattern = rawPattern.replaceAll('\\', '/');
        final limit = _bounded(
          N1Tool.optionalInt(input, 'limit', fallback: 100),
          1,
          1000,
        );

        final type = FileSystemEntity.typeSync(absolute);
        if (type == FileSystemEntityType.notFound) {
          return ToolResult.fail(
            '找不到 `$absolute`。${await FileToolBase.siblingHint(absolute)}',
          );
        }
        if (type != FileSystemEntityType.directory) {
          return ToolResult.fail('`$absolute` 不是目录。glob 要从一个目录开始找。');
        }

        final re = _globToRegExp(pattern);
        final root = Directory(absolute).absolute.path;
        final found = <({String path, DateTime modified})>[];
        var truncated = false;

        await _walkFiles(Directory(absolute), (file) async {
          final relative = _relativeTo(root, file.path);
          if (!re.hasMatch(relative)) return true;

          DateTime modified;
          try {
            modified = (await file.stat()).modified;
          } catch (_) {
            return true;
          }
          found.add((path: file.path, modified: modified));
          if (found.length >= limit) {
            truncated = true;
            return false;
          }
          return true;
        });

        if (found.isEmpty) {
          return ToolResult.ok(
            '在 `$absolute` 下没有匹配 `$rawPattern` 的文件。',
          );
        }

        found.sort((a, b) => b.modified.compareTo(a.modified));

        final buffer = StringBuffer()
          ..writeln(
            '找到 ${found.length} 个文件（pattern: `$rawPattern`，'
            '按修改时间从新到旧）：',
          )
          ..writeln();
        for (final item in found) {
          buffer.writeln(item.path);
        }
        if (truncated) {
          buffer.writeln('（只列了前 $limit 个。把 pattern 写具体一点再找。）');
        }
        return ToolResult.ok(
          buffer.toString().trimRight(),
          meta: {'count': found.length},
        );
      }, forWrite: false);
}

/// 把 [path] 变成相对 [root] 的斜杠路径。
///
/// 不用 `p.relative` 是为了让 core 层不多引一个包；这里的根目录来自
/// `Directory.absolute.path`，前缀关系是确定的。
String _relativeTo(String root, String path) {
  var relative = path;
  if (relative.startsWith(root)) {
    relative = relative.substring(root.length);
  }
  while (relative.startsWith('\\') || relative.startsWith('/')) {
    relative = relative.substring(1);
  }
  return relative.replaceAll('\\', '/');
}

int _bounded(int value, int min, int max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/// 造文件工具。
///
/// **平台不支持就别注册**（[available] 传 false 返回空表）。安卓是沙箱存储，
/// 绝大多数绝对路径根本读写不了，注册了模型也会去调然后撞一鼻子灰——
/// 这正是 `tool_registry.dart` 里说的"注册了再返回不支持，比不注册更坏"。
List<N1Tool> fileTools({
  required bool available,
  required PathResolver paths,
  required FilePolicy policy,
  required FileBackupStore backups,
  Future<ByteData?> Function()? loadFont,
}) {
  if (!available) return const [];
  return [
    ReadFileTool(paths: paths, policy: policy),
    ListDirTool(paths: paths, policy: policy),
    GrepTool(paths: paths, policy: policy),
    GlobTool(paths: paths, policy: policy),
    WriteFileTool(paths: paths, policy: policy, backups: backups),
    EditFileTool(paths: paths, policy: policy, backups: backups),
    // 文档生成和文件读写用同一套路径策略：能写到哪、哪些目录不许写，
    // 两边必须是同一个答案。
    WriteDocumentTool(
      paths: paths,
      policy: policy,
      backups: backups,
      loadFont: loadFont,
    ),
  ];
}
