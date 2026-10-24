import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:path/path.dart' as p;

/// 哪些路径不许写。
///
/// 这一层是"防手滑"的，所以测试的重点不是"能不能挡住铁了心的攻击"，
/// 而是**判定必须打在真实路径上**——只比字符串的话，`C:\Windows.`、
/// `C:\PROGRA~1`、`C:\a\..\Windows` 三个写法都能穿过去，
/// 而它们指向的是同一个地方。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1-policy-test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('真实路径判定（跑在真磁盘上）', () {
    test('封住的目录本身被拒', () {
      final policy = FilePolicy(sealedRoots: [tmp.path]);
      expect(policy.refuseWrite(tmp.path), isNotNull);
    });

    test('封住的目录下面的文件被拒', () {
      final policy = FilePolicy(sealedRoots: [tmp.path]);
      expect(policy.refuseWrite(p.join(tmp.path, 'a.txt')), isNotNull);
    });

    test('文件还不存在也要拦住——祖先目录算数', () {
      // 覆盖已存在的文件时才拦，等于"新建路径随便写"，
      // 而"往 System32 里新建一个 dll"恰恰是最该拦的那一下。
      final policy = FilePolicy(sealedRoots: [tmp.path]);
      expect(
        policy.refuseWrite(p.join(tmp.path, 'deep', 'nope', 'a.dll')),
        isNotNull,
      );
    });

    test('用 .. 绕回去照样被拒', () {
      final policy = FilePolicy(sealedRoots: [tmp.path]);
      final sneaky = p.join(tmp.path, 'sub', '..', 'evil.txt');
      expect(policy.refuseWrite(sneaky), isNotNull);
    });

    test('大小写换了照样被拒', () {
      // Windows 上 `C:\Windows` 和 `c:\WINDOWS` 是同一个目录。
      // 只比字符串的话改个大小写就绕过去了。
      final policy = FilePolicy(sealedRoots: [tmp.path]);
      expect(policy.refuseWrite(p.join(tmp.path, 'A.TXT').toUpperCase()), isNotNull);
    });

    test('封住的目录外面可以写', () {
      final policy = FilePolicy(sealedRoots: [tmp.path]);
      final outside = p.join(tmp.parent.path, 'n1-policy-outside.txt');
      expect(policy.refuseWrite(outside), isNull);
    });

    test('和封住目录只是名字前缀相同的不算在里面', () {
      // `C:\Windows-old` 不该因为以 `C:\Windows` 开头就被拦。
      // 这是"比前缀"最容易写错的那一下：少了分隔符比较。
      final sibling = Directory('${tmp.path}-sibling')..createSync();
      addTearDown(() => sibling.deleteSync(recursive: true));

      final policy = FilePolicy(sealedRoots: [tmp.path]);
      expect(policy.refuseWrite(p.join(sibling.path, 'a.txt')), isNull);
    });

    test('读封住的目录里的东西是允许的', () {
      // 拦读会让"帮我看下这个系统文件"这种正常请求莫名失败，
      // 而读没有危害。
      final policy = FilePolicy(sealedRoots: [tmp.path]);
      expect(policy.refuseRead(p.join(tmp.path, 'a.txt')), isNull);
    });

    test('目录本身也能拿来判（走的是 Directory 那一支）', () {
      // 一个只在 Windows 上会犯的错：拿 `File` 去解析目录，抛异常，
      // 然后实现一路往上退，最后把原路径原样返回——**看着没出错，
      // 防护却是关着的**。
      final policy = FilePolicy(sealedRoots: [tmp.path]);
      final inner = Directory(p.join(tmp.path, 'inner'))..createSync();
      expect(policy.refuseWrite(inner.path), isNotNull);
    });
  });

  group('真实系统目录（Windows）', () {
    test('8.3 短名指到 Program Files 也要被拒', () {
      // 这是把判定压在 `resolveSymbolicLinks` 上的全部理由：
      // 它落到 `GetFinalPathNameByHandle`，顺带把短名还原成长名。
      if (!Platform.isWindows) return;
      if (!Directory(r'C:\PROGRA~1').existsSync()) return;

      final policy = FilePolicy.standard();
      expect(policy.refuseWrite(r'C:\PROGRA~1\n1-evil.txt'), isNotNull);
    });

    test('Windows 目录被拒', () {
      if (!Platform.isWindows) return;
      final policy = FilePolicy.standard();
      expect(policy.refuseWrite(r'C:\Windows\n1-evil.txt'), isNotNull);
    });

    test('尾部加个点绕不过去', () {
      // Win32 会把尾部多余的点吃掉，`C:\Windows.\` 就是 `C:\Windows\`。
      if (!Platform.isWindows) return;
      final policy = FilePolicy.standard();
      expect(policy.refuseWrite(r'C:\Windows.\n1-evil.txt'), isNotNull);
    });

    test('盘根没封——那是故意的', () {
      // 封了的话整个 C 盘都写不了。往盘根扔个文件只是不整洁，不危险。
      if (!Platform.isWindows) return;
      final policy = FilePolicy.standard();
      expect(policy.refuseWrite(r'C:\n1-just-a-file.txt'), isNull);
    });

    test('标准封禁清单里确实有 SystemRoot', () {
      // 环境变量被清空时会退成硬编码那三条，这里顺带钉一下非空。
      final policy = FilePolicy.standard();
      expect(policy.sealedRoots, isNotEmpty);
    });
  });

  group('形状不对的路径', () {
    test('设备路径读写都拒', () {
      final policy = const FilePolicy.unrestricted();
      expect(policy.refuseWrite(r'\\.\PhysicalDrive0'), isNotNull);
      expect(policy.refuseRead(r'\\.\PhysicalDrive0'), isNotNull);
    });

    test('ADS（冒号）不写', () {
      // `报告.txt:hidden` 写进去的内容在资源管理器里看不到也删不掉。
      final policy = const FilePolicy.unrestricted();
      expect(policy.refuseWrite(r'C:\temp\报告.txt:hidden'), isNotNull);
    });

    test('盘符上的冒号不算 ADS', () {
      final policy = const FilePolicy.unrestricted();
      expect(policy.refuseWrite(r'C:\temp\报告.txt'), isNull);
    });

    test('\\\\?\\ 前缀里的盘符冒号也不算 ADS', () {
      // 去掉前缀再找冒号，不然 `\\?\C:\x` 会被自己误伤。
      final policy = const FilePolicy.unrestricted();
      expect(policy.refuseWrite(r'\\?\C:\temp\x.txt'), isNull);
    });

    test('ADS 读是放行的——拦的是写', () {
      final policy = const FilePolicy.unrestricted();
      expect(policy.refuseRead(r'C:\temp\报告.txt:hidden'), isNull);
    });
  });

  group('不封任何东西', () {
    test('普通的路径都放行', () {
      const policy = FilePolicy.unrestricted();
      expect(policy.refuseWrite(r'C:\Windows\n1-evil.txt'), isNull);
      expect(policy.refuseWrite(r'C:\Users\tester\Desktop\a.txt'), isNull);
    });
  });
}
