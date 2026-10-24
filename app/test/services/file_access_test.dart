import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/core/n1_core.dart';
import 'package:niuwa_ai/services/fs/file_access.dart';
import 'package:niuwa_ai/services/fs/local_file_backups.dart';
import 'package:niuwa_ai/services/fs/windows_known_folders.dart';
import 'package:path/path.dart' as p;

/// 造一套文件访问环境的那一步。
///
/// 这里**不能只测"返回的东西不是 null"**：真正会出事的两处是
/// ①非 Windows 上返回了东西（安卓 scoped storage 下模型会去调然后撞墙），
/// ②Windows 上 `policy` 没封住系统目录（那是真的能写坏东西）。
/// 两条都得钉。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('n1-file-access');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 假的注册表读取：不碰真注册表，免得测试机上"桌面在哪"取决于这台机器的
  /// OneDrive 状态，跑出跟别人不一样的结果。
  ShellFolderQuery registry(Map<String, String> folders) => () async => folders;

  group('不是 Windows 就不给', () {
    test('返 null，而不是"降级成只读"或"给个空壳"', () async {
      final made = await createFileAccess(
        appSupport: tmp,
        isWindows: false,
        home: r'C:\Users\test',
      );

      // 关键在**不注册**。给一个空壳（`FileAccess` 齐活儿但 policy 不封任何
      // 东西）比不给更坏：安卓上模型看到 `write_file` 就会调，撞一鼻子灰之后
      // 换个路径再撞，轮数全烧在撞墙上。
      expect(made, isNull);
    });

    test('就算硬塞一个 Windows 风格的环境变量表也不给', () async {
      // 防的是"按环境变量猜平台"这种写法：安卓上 `USERPROFILE` 可能是空的，
      // 但没有 `USERPROFILE` 不等于就是 Windows。
      final made = await createFileAccess(
        appSupport: tmp,
        isWindows: false,
        environment: const {'SystemRoot': r'C:\Windows'},
      );
      expect(made, isNull);
    });
  });

  group('Windows 上给什么', () {
    test('三件套齐全，且 policy 真封着系统目录', () async {
      final made = await createFileAccess(
        appSupport: tmp,
        isWindows: true,
        home: r'C:\Users\test',
        environment: const {
          'USERPROFILE': r'C:\Users\test',
          'SystemRoot': r'C:\Windows',
        },
        readRegistry: registry(const {}),
      );

      expect(made, isNotNull);
      final fs = made!;

      // ① 路径解析
      expect(fs.paths.home, r'C:\Users\test');
      expect(fs.paths.resolve(r'~\报表.xlsx'), r'C:\Users\test\报表.xlsx');

      // ② 访问策略：系统目录**读可以、写不行**。
      //
      // 这一条是整套安全兜底里唯一"模型说什么都不管用"的那层，必须在这儿
      // 钉死。写 C:\Windows 不是"用户手滑"，是没有任何正常理由的。
      expect(fs.policy.refuseWrite(r'C:\Windows\System32\drivers\etc\hosts'),
          isNotNull);
      expect(fs.policy.refuseRead(r'C:\Windows\System32\drivers\etc\hosts'),
          isNull, reason: '读系统目录是合理的（看配置、查日志）');

      // 用户自己的地盘照样能写——封过头等于这个功能没做。
      expect(fs.policy.refuseWrite(r'C:\Users\test\Desktop\a.py'), isNull);

      // ③ 备份目录真的挂在传入的 appSupport 下面，不是别处。
      //
      // 断言要让类型退到具体实现：`FileAccess.backups` 声明的是接口，
      // 而"挂在哪儿"只有实现知道。落不到 appSupport 里的话，卸载 / 换机
      // 之后备份就跟着安装目录一起没了——而那正是它的用途。
      expect((fs.backups as LocalFileBackupStore).dir.path, p.join(tmp.path, 'backups'));
    });

    test('已知文件夹从**注入的注册表**来——OneDrive 桌面认得出', () async {
      // 中文 Windows + OneDrive 下桌面常是 `C:\Users\x\OneDrive\桌面`，
      // 不是 `USERPROFILE\Desktop`。这条直接决定"存到桌面"存到哪去。
      //
      // ⚠️ 目录得**真存在**：挑哪个候选不是"谁排前面用谁"，而是
      // ①有内容 → ②存在 → ③都没有就如实报"没探到"。这是刻意的——
      // 往下写一个不存在的目录，`create_parents` 会造出 Explorer 根本不认的
      // 文件夹，用户永远看不见它。所以这里建个真目录来喂它。
      final desktop = Directory(p.join(tmp.path, 'OneDrive-桌面'))
        ..createSync(recursive: true);
      File(p.join(desktop.path, '一个文件.txt')).writeAsStringSync('x');

      final made = await createFileAccess(
        appSupport: tmp,
        isWindows: true,
        home: r'C:\Users\test',
        environment: const {'USERPROFILE': r'C:\Users\test'},
        readRegistry: registry({'Desktop': desktop.path}),
      );

      expect(made!.paths.knownFolder(KnownFolder.desktop), desktop.path);
      expect(
        made.paths.resolve('桌面\\a.txt'),
        p.join(desktop.path, 'a.txt'),
      );
    });

    test('注册表里指着一个不存在的桌面：如实报没探到，不硬认', () async {
      // `%USERPROFILE%\Desktop` 这一档还在，而那个也不存在，于是整个探不到。
      // 症状是"存到桌面"失败并让模型给绝对路径——比悄悄造一个假桌面强。
      final made = await createFileAccess(
        appSupport: tmp,
        isWindows: true,
        home: r'C:\Users\test',
        environment: const {'USERPROFILE': r'C:\Users\test'},
        readRegistry: registry({'Desktop': p.join(tmp.path, '并不存在')}),
      );

      expect(made!.paths.knownFolder(KnownFolder.desktop), isNull);
    });

    test('注册表读挂了不算致命：照样给，只是几个词认不出来', () async {
      // 探注册表会被组策略、权限、非中文环境各种东西挡。挡了就不给文件工具
      // 的话，等于为了一个便利功能（"存到桌面"）砍掉主要功能（绝对路径读写）。
      final made = await createFileAccess(
        appSupport: tmp,
        isWindows: true,
        home: r'C:\Users\test',
        environment: const {'USERPROFILE': r'C:\Users\test'},
        readRegistry: () async => throw StateError('注册表读不了'),
      );

      expect(made, isNotNull);
      expect(made!.paths.knownFolder(KnownFolder.desktop), isNull);
      // 绝对路径照常。
      expect(made.paths.resolve(r'D:\work\a.py'), r'D:\work\a.py');
    });

    test('主目录从环境变量里按大小写不敏感地拿', () async {
      // Windows 变量名本来就不分大小写，而模型爱写 `%UserProfile%`。
      // 拿不到就是 home 空串，`~` 解析当场失败——症状是"所有带 ~ 的路径都不认识"。
      final made = await createFileAccess(
        appSupport: tmp,
        isWindows: true,
        environment: const {'UserProfile': r'C:\Users\mixed'},
        readRegistry: registry(const {}),
      );

      expect(made!.paths.home, r'C:\Users\mixed');
    });

    test('显式给的 home 优先于环境变量', () async {
      final made = await createFileAccess(
        appSupport: tmp,
        isWindows: true,
        home: r'C:\Users\explicit',
        environment: const {'USERPROFILE': r'C:\Users\from-env'},
        readRegistry: registry(const {}),
      );

      expect(made!.paths.home, r'C:\Users\explicit');
    });
  });
}
