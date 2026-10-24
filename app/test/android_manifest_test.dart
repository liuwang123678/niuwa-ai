import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// release 包的联网权限。
///
/// 这一组是补出来的：**正式包装到手机上，一发消息就报**
///
///     Failed host lookup: 'api.deepseek.com'
///     (OS Error: No address associated with hostname, errno = 7)
///
/// 真因不是域名、不是 Key、不是手机 DNS——手机 shell 里 `ping api.deepseek.com`
/// 是通的。真因是 **release 包根本没有联网权限**：Flutter 模板把
/// `android.permission.INTERNET` 只写进了 `src/debug/` 和 `src/profile/` 两份
/// manifest，而 release 构建只合并 `src/main/`，那份是空的。
///
/// 这个坑只有"正式包 + 真机"这一种组合会炸，所以别处一个测试都拦不住它：
/// Windows 桌面没有权限模型，debug/profile 包各自带着那份 manifest 也正常。
/// 也正因为如此，它一直躲到真机第一次装上才现形。
///
/// 所以这里直接盯源码——谁把这两行删了，测试就红。
void main() {
  /// manifest 里的注释本身会提到权限名（比如 main/ 那份的解释文字），
  /// 直接全文 contains 的话，注释里的字会被当成真的声明。先剥掉注释再找。
  String stripComments(String xml) =>
      xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  String read(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '找不到 $path，路径是不是变了？');
    return stripComments(file.readAsStringSync());
  }

  test('main 那份 manifest 声明了 INTERNET —— release 只吃这一份', () {
    final xml = read('android/app/src/main/AndroidManifest.xml');

    expect(
      RegExp(
        r'<uses-permission[^>]*android:name\s*=\s*"android\.permission\.INTERNET"',
      ).hasMatch(xml),
      isTrue,
      reason:
          'release 包没有联网权限的话，真机上所有请求都会以 Failed host lookup '
          '/ errno = 7 失败。注意要找的是真正的 <uses-permission> 标签，'
          '不是注释里的文字。',
    );
  });

  test('debug / profile 那两份也还在（别为了修上面那条把它们删了）', () {
    // 留着它们不影响 release（不参与合并），删了反而会让 debug 包的调试点连不上。
    for (final path in const [
      'android/app/src/debug/AndroidManifest.xml',
      'android/app/src/profile/AndroidManifest.xml',
    ]) {
      expect(
        read(path).contains('android.permission.INTERNET'),
        isTrue,
        reason: '$path 少了 INTERNET',
      );
    }
  });
}
