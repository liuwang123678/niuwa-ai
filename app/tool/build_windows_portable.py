# -*- coding: utf-8 -*-
"""打 N1 的 Windows 便携版。

用法：
    python app/tool/build_windows_portable.py

干的事：
  1. 确认 Release 构建产物在（不在就提示先跑 flutter build windows --release）
  2. 把 Release\\* 覆盖到目标文件夹 —— **只覆盖同名文件，绝不删**
  3. **跳过 userdata\\** —— 那是用户数据，不是构建产物（见下面的警告）
  4. 补 VC++ 运行时三个 DLL（干净电脑上缺了会弹窗打不开）
  5. 写 使用说明.txt，**版本号从 lib/app_info.dart 现读**
  6. 打印 data/app.so 的大小和 sha256（对账用）

可重复执行，幂等。

--------------------------------------------------------------------------
⚠️ 为什么必须跳过 userdata\\
--------------------------------------------------------------------------
N1 的数据（聊天记录、技能文件、设置、API Key）存在 **exe 旁边的 userdata\\**
里，而不是 C 盘的 %APPDATA%（见 lib/services/data_root.dart）。

于是有个陷阱：只要谁在 build\\...\\Release\\ 里双击跑过一次 App，那个目录下就
会生成 userdata\\。之后打包时如果照搬整个 Release 目录，就会把构建目录里那份
**"我自己测试时留下的"数据**覆盖到目标目录，**把用户真实的聊天记录冲掉**。

所以 copy_release 里显式跳过 userdata\\。这不是洁癖，是防数据丢失。
"""

import hashlib
import os
import re
import shutil
import sys

APP_DIR = r'D:\niuwa-ai\app'
RELEASE = os.path.join(APP_DIR, 'build', 'windows', 'x64', 'runner', 'Release')
APP_INFO = os.path.join(APP_DIR, 'lib', 'app_info.dart')

# 目标。用户要求放 D 盘。
TARGETS = [
    r'D:\niuwa-ai-Windows',
]

EXE_NAME = 'niuwa_ai.exe'

# 用户数据目录名，必须和 lib/services/data_root.dart 里的
# portableDataDirName 一致。对不上就会把用户数据当构建产物覆盖掉。
USER_DATA_DIR = 'userdata'

# VC++ 运行时。**Flutter 的 Release 构建不会带上它们**，而干净的 Windows 上
# 不一定装了 VC++ Redistributable —— 缺了就是弹窗"找不到 msvcp140.dll"，
# 这是"拷到别人电脑上打不开"最常见的原因。
# 放 exe 同级即可：Windows 的 DLL 搜索顺序会优先用同目录里的，
# 目标电脑什么都不用装。（从 System32 取属于微软允许的 app-local 部署。）
MSVC_DLLS = ['vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll']
SYSTEM32 = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')

def app_name():
    """显示名，从 lib/app_info.dart 的 appVersionNumber 现读。

    **别在这里写死一个 v几。** 这份说明从 v1 一路发到 v3 都没人发现，
    就因为它把版本号抄了一遍——而真值只有一个，在 app_info.dart 里。
    （同一个坑，Dart 那边有 test/app_info_test.dart 守着五处；
    这一处是 Python，那边管不着，所以它自己读。）
    """
    with open(APP_INFO, encoding='utf-8') as f:
        m = re.search(r'appVersionNumber\s*=\s*(\d+)', f.read())
    if not m:
        sys.exit('[ERROR] 在 %s 里找不到 appVersionNumber' % APP_INFO)
    return 'niuwa v' + m.group(1)


# 第一行的版本号在写盘时替换，见 main()。占位符故意用 @@ 包起来而不是
# 花括号：正文里已经有 `{地址}` 这种看着像模板的东西，走 str.format 会把
# 它当字段名、直接抛 KeyError。@@ 不是合法字段名，也不像模板语法。
APP_TOKEN = '@@APPNAME@@'

README_TEMPLATE = """@@APPNAME@@ - Windows 便携版
========================================

【怎么用】
1. 把整个「niuwa-ai-Windows」文件夹拷到任何一台 Windows 电脑（放桌面、放 D 盘、放 U 盘都行）
2. 双击 niuwa_ai.exe
3. 首次打开会看到「先去设置里填一个 API Key，我就能开口了」，点那个绿按钮进设置

【第一次要先配一下模型】
程序本身不带 Key，得用你自己的。设置页最上面那张卡片就是干这个的：

1. 在「供应商」下拉里选一家（预置了几家常用的，都在下拉里）
2. 点「填一个」，把 Key 粘进去
   —— 去哪申请，卡片上直接写着地址，可以选中复制
3. 「模型名」那一栏一般不用动，用的是选的那家的默认值；想换别的模型，
   把它改成那家官网上的名字就行

想接下拉里没有的服务？选「自定义」，把接口地址和模型名自己填进去。
只要对方提供 OpenAI 兼容的接口（能接受 POST {地址}/chat/completions），就能用。
本机跑了 Ollama 的话，下拉里也有。

Key 存在系统的加密存储里，不会明文落盘。每家一个 Key，换供应商不会互相覆盖。

【你的数据在哪】
就在这个文件夹里的 userdata\\ 目录下：

    userdata\\n1.db                       聊天记录 + 记忆
    userdata\\skills\\                     技能文件（可以自己改）
    userdata\\shared_preferences.json      设置
    userdata\\flutter_secure_storage.dat  API Key（DPAPI 加密）

好处是整个文件夹拷到别的盘、别的电脑、U 盘，**聊天记录和 Key 都跟着走**，
不占 C 盘、也不写注册表。

⚠️ 换电脑时请**整个文件夹一起拷**。只拷 exe 的话，程序能开，但记录是空的。

【特点】
- 不绑定任何一家模型：供应商随时换，换完在设置页点一下就行
- 绿色便携：不装系统、不写注册表、不留自启动项。删掉文件夹就是卸载
- 数据跟着程序走，换盘符（D: 变 E:）也不影响
- 中文界面，深色主题，宽窗口用左侧栏、窄窗口自动换成底部标签栏
- 技能可改：userdata\\skills\\ 下每个 SKILL.md 都能自己编辑，改完在技能页点刷新

【常见问题】
- 双击没反应：可能被杀毒软件拦了，点允许
- 提示缺少 msvcp140.dll：说明 VC++ 运行时的三个 DLL 被删了。本文件夹里本来带了，
  从回收站找回来，或者去微软官网装一个 "Visual C++ Redistributable"
- 想把数据挪走：关掉程序，把 userdata\\ 整个剪切到别处，再在原位置放一个
  指向新位置的快捷方式（目录符号链接）

【技术要求】
- Windows 10/11 64 位
- VC++ 运行时已经随包带了，目标电脑**不需要**装
- 需要联网（对话要发到你选的那家模型服务）
"""


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def copy_release(target):
    """把 Release 下的文件覆盖过去。只覆盖，不删除目标里已有的东西。

    **跳过 userdata/**：那是用户数据。见文件头的警告。
    """
    copied = 0
    for root, dirs, files in os.walk(RELEASE):
        rel = os.path.relpath(root, RELEASE)

        # 在顶层把 userdata 从 dirs 里摘掉。os.walk 不会走进被摘掉的目录，
        # 整棵子树一次性跳过 —— 不需要在下面逐层判断。
        if rel == '.' and USER_DATA_DIR in dirs:
            dirs.remove(USER_DATA_DIR)

        dest_dir = target if rel == '.' else os.path.join(target, rel)
        os.makedirs(dest_dir, exist_ok=True)
        for name in files:
            src = os.path.join(root, name)
            dst = os.path.join(dest_dir, name)
            shutil.copy2(src, dst)
            copied += 1
    return copied, _count_userdata_files()


def _count_userdata_files():
    """构建目录里那份（如果有）有几个文件。只用来打一行提示，
    让人看见"确实跳过了东西"，而不是默默不看。"""
    ud = os.path.join(RELEASE, USER_DATA_DIR)
    if not os.path.isdir(ud):
        return 0
    n = 0
    for _root, _dirs, files in os.walk(ud):
        n += len(files)
    return n


def drive_ready(target):
    """目标所在盘在不在。U 盘没插的时候不能直接 makedirs ——
    直接建会抛 FileNotFoundError，把整轮打包带崩。"""
    drive = os.path.splitdrive(os.path.abspath(target))[0]
    return os.path.isdir(drive + os.sep)


def main():
    if not os.path.isdir(RELEASE):
        print('[ERROR] 没找到构建产物：%s' % RELEASE)
        print('        先跑：cd /d %s && flutter build windows --release' % APP_DIR)
        return 1

    exe = os.path.join(RELEASE, EXE_NAME)
    if not os.path.isfile(exe):
        print('[ERROR] Release 里没有 %s，构建不完整' % EXE_NAME)
        return 1

    app_so = os.path.join(RELEASE, 'data', 'app.so')
    if not os.path.isfile(app_so):
        print('[ERROR] Release\\data\\app.so 不存在，构建不完整')
        return 1

    rc = 0
    for target in TARGETS:
        if not drive_ready(target):
            print('[SKIP] %s —— 这个盘不在' % target)
            continue

        os.makedirs(target, exist_ok=True)
        n, skipped = copy_release(target)

        # 补 VC++ 运行时。已经在了就不覆盖（有些机器上版本更新）。
        msvc_missing = []
        for dll in MSVC_DLLS:
            dst = os.path.join(target, dll)
            if os.path.isfile(dst):
                continue
            src = os.path.join(SYSTEM32, dll)
            if os.path.isfile(src):
                shutil.copy2(src, dst)
            else:
                msvc_missing.append(dll)
        if msvc_missing:
            print('[WARN] %s 里没有：%s' % (SYSTEM32, '、'.join(msvc_missing)))

        # 便携版的命根子
        if not os.path.isfile(os.path.join(target, EXE_NAME)):
            print('[ERROR] %s 里没有 %s' % (target, EXE_NAME))
            rc = 1
            continue

        readme = README_TEMPLATE.replace(APP_TOKEN, app_name())
        if APP_TOKEN in readme:
            print('[ERROR] 说明模板里的占位符没被替换，别把 %s 发出去' % APP_TOKEN)
            rc = 1
            continue

        with open(os.path.join(target, '使用说明.txt'), 'w',
                  encoding='utf-8-sig', newline='\r\n') as f:
            f.write(readme)

        print('[OK] %s' % target)
        print('     覆盖 %d 个文件；跳过 userdata %d 个' % (n, skipped))
        print('     app.so %d 字节，sha256 %s'
              % (os.path.getsize(app_so), sha256_of(app_so)[:16]))

        ud = os.path.join(target, USER_DATA_DIR)
        if os.path.isdir(ud):
            print('     已有用户数据：%s（原样保留）' % ud)

    return rc


if __name__ == '__main__':
    sys.exit(main())
