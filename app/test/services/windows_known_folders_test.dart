import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/fs/windows_known_folders.dart';
import 'package:path/path.dart' as p;

/// 探「桌面 / 文档 / 下载」到底在哪儿。
///
/// 这里最值钱的部分是**[pickInUseFolder]**：注册表里同一个位置会同时留着
/// 新旧两个值，而且**旧的那个往往还有内容**。按优先级取第一个是错的
/// （本机实测就是错的），得取"真的在用的那个"。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1-known-folders');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Directory dir(String name, {List<String> files = const []}) {
    final d = Directory(p.join(tmp.path, name))..createSync(recursive: true);
    for (final f in files) {
      File(p.join(d.path, f)).writeAsStringSync('x');
    }
    return d;
  }

  bool exists(String path) => Directory(path).existsSync();
  bool hasEntries(String path) {
    try {
      return Directory(path).listSync().any((e) {
        final name = p.basename(e.path);
        return name != 'desktop.ini' && !name.startsWith('.');
      });
    } catch (_) {
      return false;
    }
  }

  group('候选从哪来', () {
    test('注册表优先，环境变量兜底', () {
      final candidates = shellFolderCandidates(
        KnownFolder.desktop,
        const {'Desktop': r'%USERPROFILE%\Redir桌面'},
        const {'USERPROFILE': r'C:\Users\x'},
      );

      expect(candidates.first, r'C:\Users\x\Redir桌面');
      expect(candidates, contains(r'C:\Users\x\Desktop'));
    });

    test('注册表里的 %变量% 要展开', () {
      // 注册表存的是 REG_EXPAND_SZ，给的是 `%USERPROFILE%\Desktop` 这种
      // 带变量的形式，不展开的话会造出一个叫 `%USERPROFILE%` 的目录。
      final candidates = shellFolderCandidates(
        KnownFolder.documents,
        const {'Personal': r'%USERPROFILE%\Personal'},
        const {'USERPROFILE': r'C:\Users\x'},
      );

      expect(candidates.first, r'C:\Users\x\Personal');
    });

    test('OneDrive 的中文重定向也在候选里', () {
      final candidates = shellFolderCandidates(
        KnownFolder.documents,
        const {},
        const {'USERPROFILE': r'C:\Users\x', 'OneDrive': r'C:\Users\x\OneDrive'},
      );

      expect(
        candidates,
        containsAllInOrder([r'C:\Users\x\Documents', r'C:\Users\x\OneDrive\文档']),
      );
    });

    test('一个值都没有时不会塞进空串', () {
      final candidates = shellFolderCandidates(
        KnownFolder.downloads,
        const {},
        const {},
      );
      expect(candidates, isEmpty);
    });
  });

  group('挑真的在用的那个', () {
    test('有内容的那一个胜出，哪怕它排在后面', () {
      // 本机的真实状态：`Personal` → 本地 Documents（有内容），
      // GUID → `OneDrive\文档`（空的）。排在前面的反而不能要。
      final empty = dir('OneDrive文档');
      final used = dir('本地文档', files: ['a.txt']);

      final picked = pickInUseFolder([empty.path, used.path], exists: exists, hasEntries: hasEntries);

      expect(picked, used.path);
    });

    test('都是空的时候退一步取存在的那个', () {
      // 新建的账号桌面就是空的，不能因为空就判它不是桌面。
      final first = dir('空一');
      final second = dir('空二');

      final picked = pickInUseFolder([first.path, second.path], exists: exists, hasEntries: hasEntries);

      expect(picked, first.path);
    });

    test('只有 desktop.ini 的算空——OneDrive 搬走后会留这么一个壳', () {
      final shell = dir('旧桌面', files: ['desktop.ini']);
      final used = dir('新桌面', files: ['note.txt']);

      final picked = pickInUseFolder([shell.path, used.path], exists: exists, hasEntries: hasEntries);

      expect(picked, used.path);
    });

    test('哪个都不存在就返回 null，不随便挑一个', () {
      // 挑一个不存在的目录往下写，配上 create_parents 就会造出一个
      // Explorer 根本不认的文件夹，用户永远看不见它。
      final picked = pickInUseFolder(
        [p.join(tmp.path, 'nope-a'), p.join(tmp.path, 'nope-b')],
        exists: exists,
        hasEntries: hasEntries,
      );

      expect(picked, isNull);
    });

    test('重复的候选只算一次', () {
      final used = dir('桌面', files: ['a.txt']);

      final picked = pickInUseFolder([used.path, used.path], exists: exists, hasEntries: hasEntries);

      expect(picked, used.path);
    });
  });

  group('整体探一遍', () {
    test('注册表给的东西不存在时，靠环境变量兜住', () async {
      if (!Platform.isWindows) return;
      final used = dir('真桌面', files: ['x.txt']);

      final found = await discoverKnownFolders(
        environment: const {'USERPROFILE': '', 'OneDrive': ''},
        readRegistry: () async => {
          'Desktop': p.join(tmp.path, '不存在的地方'),
        },
      );

      // 候选全都不存在 → 桌面探不到，如实缺席，而不是报一个假路径。
      expect(found.containsKey(KnownFolder.desktop), isFalse);
      expect(used.path, isNotEmpty);
    });

    test('注册表探失败也不影响其他来源', () async {
      if (!Platform.isWindows) return;
      // 环境变量那一档是 `%USERPROFILE%\Desktop`。
      Directory(p.join(tmp.path, 'Desktop')).createSync();

      final found = await discoverKnownFolders(
        environment: {'USERPROFILE': tmp.path},
        readRegistry: () async => throw StateError('PowerShell 被挡了'),
      );

      expect(found[KnownFolder.desktop], p.join(tmp.path, 'Desktop'));
    });

    test('真跑一次 PowerShell：桌面探出来的是个真目录', () async {
      // 这一条是**源码证据变真机证据**的那一步。上面那些都把
      // readRegistry 换成了假的，只有这条走真的注册表 + 真的编码转换。
      if (!Platform.isWindows) return;

      final registry = await readUserShellFolders();
      expect(registry, isNotEmpty, reason: '真机上 User Shell Folders 不该是空的');

      final found = await discoverKnownFolders();
      expect(found.containsKey(KnownFolder.desktop), isTrue);
      expect(Directory(found[KnownFolder.desktop]!).existsSync(), isTrue);
    });

    test('中文路径不会变成乱码', () async {
      // `reg query` 那一条路会在这里烂掉：它按 GBK 输出，
      // Dart 按 UTF-8 解，中文全变成 U+FFFD，路径直接废掉。
      if (!Platform.isWindows) return;

      final registry = await readUserShellFolders();
      final values = registry.values.join('\n');
      expect(
        values.contains('\uFFFD'),
        isFalse,
        reason: '注册表值里有替换字符，说明读取的编码搞错了',
      );
    });
  });

  group('环境变量展开', () {
    test('大小写不敏感', () {
      expect(
        expandEnvVars(r'%userProfile%\x', const {'USERPROFILE': r'C:\Users\a'}),
        r'C:\Users\a\x',
      );
    });

    test('认不出来的变量留原样——这里是系统数据，少一个候选无所谓', () {
      expect(expandEnvVars(r'%NOPE%\x', const {}), r'%NOPE%\x');
    });
  });
}
