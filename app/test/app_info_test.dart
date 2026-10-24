import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niuwa_ai/app_info.dart';

/// 版本号一致性。
///
/// 用户的要求是「以后更新就改 v 后面那个数」。但那个数其实是**五份**：
/// [appVersionNumber]、`pubspec.yaml`、`main.cpp` 的窗口标题、`Runner.rc` 的
/// ProductName/FileDescription、AndroidManifest 的 `android:label`。
/// 后四个在原生代码里，Dart 常量拼不进去，只能手工跟。
///
/// 手工跟就会漂——改了 v3 忘了改窗口标题，App 里写着 niuwa v3、任务管理器里
/// 还是 niuwa v2，谁看见都得愣一下。这组测试就是防这个：五份对不上就红，
/// 报错里直接告诉你要改哪个文件的哪一行。
///
/// 真值只有一个：[appVersionNumber]。其余四份都拿它比。
void main() {
  String read(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '找不到 $path，路径是不是变了？');
    return file.readAsStringSync();
  }

  final v = appVersionNumber;

  test('显示名就是 niuwa v<版本号>', () {
    expect(appName, 'niuwa v$v');
  });

  test('署名不是空的', () {
    // 关于页里挂着它。空的话那一行会渲染成「开发者：」，很难看。
    expect(appAuthor.trim(), isNotEmpty);
  });

  test('Windows 窗口标题跟着版本号走', () {
    expect(
      read('windows/runner/main.cpp'),
      contains('L"$appName"'),
      reason: 'main.cpp 的 window.Create 第一个参数要写成 L"niuwa v$v"',
    );
  });

  test('Runner.rc 的 ProductName / FileDescription 跟着版本号走', () {
    final rc = read('windows/runner/Runner.rc');
    for (final key in const ['ProductName', 'FileDescription']) {
      expect(
        rc,
        contains('VALUE "$key", "$appName"'),
        reason: 'Runner.rc 里 $key 要写成 "niuwa v$v"，'
            'exe 右键属性和任务管理器看的就是它',
      );
    }
  });

  test('安卓的 android:label 跟着版本号走', () {
    expect(
      read('android/app/src/main/AndroidManifest.xml'),
      contains('android:label="$appName"'),
      reason: '桌面图标下面那行字。注意得是 main/ 那份，debug/ 那份不参与 release',
    );
  });

  test('pubspec 的 description 也跟着版本号走', () {
    // 同一个文件里，只有 version 那一行有测试盯着。description 从 v1 一路漂到
    // v3 都没人报——它是 pubspec 里唯一能被外人看见的一行（pub.dev、编辑器
    // 的文件头、`flutter pub get` 的日志里都显示），漂了就是对外写着旧版本号。
    final match = RegExp(r'^description:\s*(.+)$', multiLine: true)
        .firstMatch(read('pubspec.yaml'));
    expect(match, isNotNull, reason: 'pubspec.yaml 里找不到 description 行');

    // YAML 里这个值是带引号的，去掉再比。
    final line = match!
        .group(1)!
        .trim()
        .replaceAll(RegExp(r'''^["']|["']$'''), '');

    expect(
      // 用 (?![0-9]) 而不是 startsWith：v4 的包不该让 "niuwa v40" 蒙混过关。
      RegExp('^${RegExp.escape(appName)}(?![0-9])').hasMatch(line),
      isTrue,
      reason: 'description 要写成 "niuwa v$v · 牛蛙AI —— …"，'
          '现在写的是「$line」',
    );
  });

  test('pubspec 的 version 跟着版本号走', () {
    // 现行的对应关系：v1 → 0.1.0+1，v2 → 0.2.0+2。次版本号和 build 号都跟
    // appVersionNumber 走。安卓系统里"应用版本"看的是它，跟 App 内显示的对不上
    // 会很怪。要换一套语义化版本规则就改这里，别绕过去。
    final expected = '0.$v.0+$v';
    expect(
      read('pubspec.yaml'),
      contains(RegExp('^version:\\s*${RegExp.escape(expected)}\\s*\$', multiLine: true)),
      reason: 'pubspec.yaml 的 version 要写成 $expected',
    );
  });

  // --------------------------------------------------------------------------
  // 网站落地页。
  //
  // 加这一组是因为真出过事：App 升到 v4 了，站上还挂着 v3 的包——而那个 v3 的包
  // 是坏的。更要命的是**看不出来**：下载页写的没错、链接也不报错，点下去下到的
  // 就是旧包。静态站点没有构建期校验，全靠人记得改，而人一定会忘。
  //
  // 版本号在页面上有两副面孔，两种都得盯，因为漏法不一样：
  //   - 带名字的 `niuwa v5`，出现在 eyebrow、两张下载卡、页脚（4 处）；
  //   - 光秃秃的 `v5`，只有页头那颗品牌药丸一处。
  // 第二种是后面才发现的漏洞：原来的正则写的是 `niuwa v(\d+)`，**前缀就把
  // 药丸漏过去了**——药丸上写的是 `v5`，前面没有 `niuwa `。于是升到 v6 时
  // 页面顶上还挂着 v5，测试照样绿。改一半漏一半是最可能的形态，所以这里
  // 不检查"改没改"，检查**全不全**。
  // --------------------------------------------------------------------------
  group('网站落地页', () {
    // 注意 read() 里带 expect()，只能在 test 体内调——写在 group 这一层会抛
    // OutsideTestException，而且报的是"加载失败"，看不出真正的原因。
    test('页面上出现的版本号全都等于 appVersionNumber', () {
      final found = RegExp(r'niuwa v(\d+)')
          .allMatches(read('../web/index.html'))
          .map((m) => m.group(1))
          .toSet();

      expect(found, isNotEmpty, reason: '页面里一个 "niuwa v<?>" 都没有？');
      expect(
        found,
        {'$v'},
        reason: '页面上的版本号有 ${found.map((e) => 'v$e').join('、')}，'
            '期望全是 v$v。多半是改了一半——页头改了页脚没改这种。',
      );
    });

    test('页头那颗版本药丸也等于 appVersionNumber', () {
      // 它是页面上唯一一处光写 `v5`、前面不带 `niuwa ` 的版本号，所以上面
      // 那条正则够不着它。单独拎出来比，别让它成为"永远绿"的那一处。
      final pill = RegExp(r'class="brand__ver">\s*([^<]*?)\s*<')
          .firstMatch(read('../web/index.html'))
          ?.group(1);

      expect(
        pill,
        isNotNull,
        reason: '页头找不到 brand__ver 那颗药丸了。'
            '要么 class 名改了（那这里跟着改），要么它被删了（那这条测试也该删）。',
      );
      expect(pill, 'v$v', reason: '页头药丸写的还是 «$pill»，该是 «v$v»。');
    });

    test('每个安装包链接都指向真实存在的文件', () {
      final refs = RegExp(r'assets/pkg/([A-Za-z0-9._-]+)')
          .allMatches(read('../web/index.html'))
          .map((m) => m.group(1)!)
          .toSet();

      expect(refs, isNotEmpty, reason: '下载区一个 assets/pkg/ 链接都没有？');

      for (final name in refs) {
        expect(
          File('../web/assets/pkg/$name').existsSync(),
          isTrue,
          reason: '页面链到 assets/pkg/$name，但那个文件不在。'
              'Pages 是静态托管，缺文件不报错——用户点下去才知道。',
        );
        expect(
          name.contains('v$v'),
          isTrue,
          reason: '包名 «$name» 里的版本号不是 v$v，'
              '说明页面改了但包没换（或反过来）',
        );
      }
    });
  });
}
