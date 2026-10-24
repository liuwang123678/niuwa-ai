import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';

/// 路径解析。
///
/// 这一层要"猜"用户和模型心里的位置，所以每条规则都得钉住：
/// 猜错方向不一样，后果差很多——把 `~` 猜成字面量目录会凭空造文件夹，
/// 把 `..` 留着不折叠会让后面的防绕过判定失效。
void main() {
  const desktop = r'C:\Users\tester\Desktop';
  const documents = r'C:\Users\tester\Documents';

  PathResolver build({
    Map<KnownFolder, String> folders = const {},
    Map<String, String> env = const {},
    String? cwd,
  }) => PathResolver(
    home: r'C:\Users\tester',
    environment: env,
    knownFolders: folders,
    workingDirectory: cwd,
  );

  PathResolver withFolders() => build(
    folders: const {
      KnownFolder.desktop: desktop,
      KnownFolder.documents: documents,
      KnownFolder.downloads: r'C:\Users\tester\Downloads',
    },
  );

  group('已知位置的说法', () {
    test('光说「桌面」就给桌面', () {
      expect(withFolders().resolve('桌面'), desktop);
    });

    test('英文名也认，且不分大小写', () {
      expect(withFolders().resolve('Desktop'), desktop);
      expect(withFolders().resolve('DESKTOP'), desktop);
    });

    test('「桌面/报告.txt」——后面的部分跟着走', () {
      expect(withFolders().resolve('桌面/报告.txt'), r'C:\Users\tester\Desktop\报告.txt');
    });

    test('只在第一段做替换', () {
      // `C:\备份\桌面\a.txt` 里的"桌面"只是个普通文件夹名。
      // 替换它会把一个完全正常的绝对路径改到别处去。
      expect(
        withFolders().resolve(r'C:\备份\桌面\a.txt'),
        r'C:\备份\桌面\a.txt',
      );
    });

    test('「我的文档」也算文档', () {
      expect(withFolders().resolve('我的文档'), documents);
    });

    test('没探到这个位置就如实报，不猜一个', () {
      // 返回 `C:\Users\tester\Desktop` 这种"看着像"的路径最坏：
      // 文件写得进去，用户在桌面上什么也看不见。
      expect(
        () => build().resolve('桌面'),
        throwsA(
          isA<PathResolveException>().having(
            (e) => e.message,
            'message',
            allOf(contains('桌面'), contains('绝对路径')),
          ),
        ),
      );
    });
  });

  group('~ 和环境变量', () {
    test('~ 就是主目录', () {
      expect(build().resolve('~'), r'C:\Users\tester');
      expect(build().resolve('~/notes.txt'), r'C:\Users\tester\notes.txt');
    });

    test('%USERPROFILE% 展开', () {
      expect(
        build(env: const {'USERPROFILE': r'C:\Users\tester'})
            .resolve(r'%USERPROFILE%\a.txt'),
        r'C:\Users\tester\a.txt',
      );
    });

    test('变量名大小写随便写', () {
      // Windows 上环境变量本来就不分大小写，而模型经常写成 %UserProfile%。
      expect(
        build(env: const {'USERPROFILE': r'C:\Users\tester'})
            .resolve(r'%UserProfile%\a.txt'),
        r'C:\Users\tester\a.txt',
      );
    });

    test('变量没定义就报错，不留着 %FOO% 当目录名', () {
      // 留着原样的话，磁盘上会悄悄多出一个叫 `%FOO%` 的文件夹。
      expect(
        () => build().resolve(r'%NOPE%\a.txt'),
        throwsA(isA<PathResolveException>().having(
          (e) => e.message,
          'message',
          contains('%NOPE%'),
        )),
      );
    });
  });

  group('整理', () {
    test('正斜杠换成反斜杠', () {
      expect(build().resolve(r'C:/a/b/c.txt'), r'C:\a\b\c.txt');
    });

    test('折叠 .. 和 .', () {
      expect(build().resolve(r'C:\a\b\..\..\c.txt'), r'C:\c.txt');
      expect(build().resolve(r'C:\a\.\c.txt'), r'C:\a\c.txt');
    });

    test('.. 吃掉了根就丢掉，不往上跑', () {
      expect(build().resolve(r'C:\..\Windows'), r'C:\Windows');
    });

    test('串起来的 .. 保留（走到根以外就没意义了）', () {
      // 这里只是说明结果确定，不是"正确"。真判定在 FilePolicy 那边。
      expect(build().resolve(r'C:\..\..\x'), r'C:\x');
    });

    test('UNC 路径不被压成单个反斜杠', () {
      // 压成 `\server\share` 就成了"当前盘根目录下有个叫 server 的文件夹"，
      // 完全不同的东西。
      expect(build().resolve(r'\\server\share\a.txt'), r'\\server\share\a.txt');
    });

    test('\\\\?\\ 长路径前缀保留', () {
      expect(build().resolve(r'\\?\C:\a\b.txt'), r'\\?\C:\a\b.txt');
    });

    test('重复的分隔符压掉', () {
      expect(build().resolve(r'C:\a\\\b.txt'), r'C:\a\b.txt');
    });
  });

  group('相对路径', () {
    test('没给基准目录就报错', () {
      // 猜一个基准（比如进程的当前目录）会让"报表.xlsx"落到
      // 程序安装目录里，用户在哪儿都找不到。
      expect(
        () => build().resolve(r'notes\a.txt'),
        throwsA(isA<PathResolveException>().having(
          (e) => e.message,
          'message',
          contains('相对路径'),
        )),
      );
    });

    test('给了基准目录就拼上去', () {
      expect(
        build(cwd: r'C:\work').resolve(r'notes\a.txt'),
        r'C:\work\notes\a.txt',
      );
    });

    test('相对路径不会被当成绝对路径', () {
      // 这里原来有个坑：折叠 `..` 时给相对路径补了个前导分隔符，
      // 于是 `notes\a.txt` 变成 `\notes\a.txt`，而"以反斜杠开头"在
      // Windows 上算绝对路径（当前盘的根）——相对路径就这么绕过检查
      // 落到了盘根。
      expect(
        () => build().resolve(r'..\a.txt'),
        throwsA(isA<PathResolveException>()),
      );
    });
  });

  group('空的和离谱的', () {
    test('空路径报错', () {
      expect(() => build().resolve('   '), throwsA(isA<PathResolveException>()));
    });

    test('超长路径报错', () {
      expect(
        () => build().resolve('C:\\${'a' * 5000}'),
        throwsA(isA<PathResolveException>()),
      );
    });
  });
}
