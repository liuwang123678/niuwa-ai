# 牛蛙落地页

一个纯静态站。没有后端、没有构建步骤、没有依赖——三个文件加一堆素材，
扔到任何能托管静态文件的地方就能跑。

线上地址：**https://niuwa-ai.pages.dev**

```
web/
  index.html          页面本身
  styles.css          所有样式，配色和间距全部对齐 app/lib/design/tokens.dart
  app.js              四件事：滚动出现 / 青蛙看鼠标 / 演示对话 / 顶栏分隔线
  favicon.svg         标签页图标
  assets/
    pkg/              安装包（不进 git，见下）
    fonts/            Space Grotesk（自托管，不连 Google Fonts）
    img/              app_icon.png 等
```

页面上的青蛙、配色、圆角、动画曲线都是从 App 那边搬过来的：
形状出自 `app/lib/widgets/n1_mark.dart` 的 `FrogShape.standard`，
颜色和曲线出自 `app/lib/design/tokens.dart`。
**改 App 的造型或主色，这里要跟着改**，否则网站和 App 会长成两个东西。
index.html 底部和 favicon.svg 顶部各有一张坐标对照表。

---

## 部署

```bash
cd /d/temp                      # 别在项目根跑，见下面的坑
node /d/npm-global/node_modules/wrangler/bin/wrangler.js \
    pages deploy /d/niuwa-ai/web --project-name niuwa-ai --branch main
```

首次建项目（只做一次）：

```bash
node .../wrangler.js pages project create niuwa-ai --force --production-branch main
```

### 两个踩过的坑

1. **`--force` 的位置不能换。** 得写在 `--production-branch` 前面。
   反过来写报 `code: 8000000`，长得像权限问题，其实是参数顺序。
   新版 wrangler 会把 Pages 代理到 Workers，`--force` 是绕开这个代理的开关；
   但 `--force` 只能用在 `project create` 上，部署时别加。

2. **别在 `D:\niuwa-ai` 根目录跑 wrangler。** 它会自己生成一个
   `wrangler.jsonc`，还顺手改 `package.json` 和 `.gitignore`，
   而且会把整棵树当资源扫一遍——`app/release/` 里那个 95 MB 的 exe
   会撞上 Pages 单文件 25 MiB 的上限，直接失败。
   在 `/d/temp` 这类空目录里跑，用绝对路径指过去。

---

## 安装包怎么来的

`assets/pkg/` 里的三个文件是构建产物，加起来 56.3 MB，**不进 git**
（见根目录 `.gitignore`）。重新生成：

```bash
cd /d/niuwa-ai/app

# 安卓。必须加 --split-per-abi —— 不分架构的通用包有 57.9 MB，
# 超过 Cloudflare Pages 单文件 25 MiB 的上限，传不上去。
flutter build apk --release --split-per-abi
# 产物 → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk (22.0 MB)
#        → build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk (19.9 MB)

# Windows
flutter build windows --release
# 打便携包：python app/tool/build_windows_portable.py
# 再压成 zip（16.4 MB）。压缩时**明确跳过 userdata/**，见下一节。
```

改完名字放回 `web/assets/pkg/`，和 index.html 里写的大小对一下：

| 页面上的文件 | 实际产物 |
| --- | --- |
| `niuwa-v11-arm64.apk`（23.8 MB） | `app-arm64-v8a-release.apk` |
| `niuwa-v11-arm32.apk`（21.9 MB） | `app-armeabi-v7a-release.apk` |
| `niuwa-v11-windows.zip`（16.4 MB） | 暂存目录压出来的 zip |

### 版本号不用再手工对了（2026-09-25 起）

以前这里写着"页面上写的大小、下载链接、版本号，换版本时都得跟着改"——
全靠人记，而人就一定会忘。**v4 那次就忘出事了**：App 升到 v4，站上还挂着
v3 的包，而那个包是坏的（消息顺序 bug，用几次就永久发不出话）。
更要命的是看不出来——下载页写得没错、链接也不报错，点下去下到的就是旧包。

现在 `app/test/app_info_test.dart` 里有一组「网站落地页」测试盯着：

- 页面里出现的**每一个** `niuwa v<数字>` 都等于 `appVersionNumber`
- 页头那颗光写 `v5` 的版本药丸（唯一不带 `niuwa ` 前缀的一处）也等于它
- 每一条 `assets/pkg/` 链接都必须指向真实存在的文件，且文件名里带对版本号

（第二颗药丸是 v5 这次才补上的。原来只查 `niuwa v<数字>`，而**前缀就把药丸
漏过去了**——它写的是 `v5`，前面没有 `niuwa `。升到 v6 时页面顶上还挂着 v5，
测试照样绿。是 v5 换包时数了一遍页面上的版本号才发现只有 4 处、跟记忆里的
"12 次"对不上，顺着查出来的。）

静态站点没有构建期校验，这组测试就是替代品。加/删/改包之后跑
`flutter test test/app_info_test.dart` 再部署。

Windows 便携包的 `使用说明.txt` 也一样：`build_windows_portable.py`
现在从 `lib/app_info.dart` 现读版本号（那份说明从 v1 一路漂到 v3 才被发现）。

**还有一处手工的**：`assets/pkg/` 里旧版本的包要顺手删掉，别留着。
但见下面「删掉的包还会被端出来」。

### 打包前必须查一件事：zip 里不能有 `userdata/`

**2026-09-25 出过事。** v3 的 Windows 包直接从
`app/build/windows/x64/runner/Release/` 压出来，而那个目录里躺着一份
真跑留下的 `userdata/`——里面有 `n1.db`（明文 SQLite，装着那次对话，
包括一张截图转成的 68 KB base64）和 `flutter_secure_storage.dat`。
包上传到 Pages 之后大约半小时才发现，那段时间**任何下载到它的人都能拿到**。

所以打 Windows 包时**不要**直接压 `Release/`：

```bash
# 对的做法：先挑出该发的东西，放进一个干净的暂存目录
mkdir -p /d/temp/<stage> && cd /d/temp/<stage>
cp /d/niuwa-ai/app/build/windows/x64/runner/Release/{niuwa_ai.exe,dartjni.dll,*.dll} .
cp -r /d/niuwa-ai/app/build/windows/x64/runner/Release/data .
# 三个 VC++ 运行时 DLL（msvcp140 / vcruntime140 / vcruntime140_1）必须带上，
# 否则干净的电脑上双击报缺少 DLL —— 使用说明里承诺了随包带
```

打完包、上传前，**逐条查一遍**（这条命令是关卡，不是提醒）：

```bash
python -c "import zipfile; print([n for n in zipfile.ZipFile('niuwa-v5-windows.zip').namelist() if 'userdata' in n])"
# 必须输出 []。有东西就说明打错了，别部署。
```

`assets/pkg/` 在 `.gitignore` 里，所以包里发出去的东西**没有 git 记录可查**，
这条检查只能靠跑。

### 还有个坑

**别设 `PUB_CACHE`。** 环境里本来就有对的 `D:\pub-cache`，
手动设成 `D:pub-cache`（少一个反斜杠）会被 Dart 当成"当前盘符下的相对路径"，
于是报 `Windows paths with drive letter must be absolute`，
还在 `app/` 里偷偷造一个同名目录。而且这个错误会被 `| tail` 吞掉——
管道最后一条命令的退出码才是整条管道的，pub 明明失败了它却返回 0。
写日志文件，别用管道。

---

## 删掉的包还会被端出来（Pages 的资源保留缓存）

**2026-09-25 实测。** `assets/pkg/` 里的旧包从目录里删掉、重新部署之后，
那几个 URL **仍然返回旧文件**，字节数一模一样：

```
/assets/pkg/niuwa-v3-arm64.apk   →  HTTP 200  22582333B  application/vnd.android.package-archive
（这个文件已经不在 web/assets/pkg/ 里了）
```

官方说法是删掉的文件最多还能被访问一周，而且**没法手动清**。
页面本身不会指过去（线上 HTML 里 `v3` 出现 0 次），所以只有"存了直链"
这种情况会碰到。

要堵掉这一周的话，用**同内容占住那个路径**（Pages 按内容哈希去重，
同一份字节放两个文件名不会多传）：把 `niuwa-v4-arm64.apk` 复制成
`niuwa-v3-arm64.apk` 一起部署，旧链接就会下到修好的包。v4 这次没这么做
（站上线才几小时，存了直链的人基本为零），要做得先想清楚
"文件名写 v3、内容是 v4"这个别扭之处。

**注意别把它和「占位空文件」搞混**：占位是为了让路径别再冒出来，
而这里要的是**让旧链接下到好东西**。两者目的相反。

---

## 验收时别被 fullPage 截图骗了

页面上有 28 个 `.reveal` 元素，默认 `opacity: 0`，靠 `app.js` 里的
IntersectionObserver 进场时才加 `is-in` 变可见。**`page.screenshot({fullPage: true})`
不会滚动**，所以拍出来是"首屏 + 一大片空白 + 页脚"，看着像页面坏了。

实测对照：

```
刚加载（未滚动） : .dl__card  opacity "0"  class "dl__card reveal"
滚到 #download 后: .dl__card  opacity "1"  class "dl__card reveal is-in"
```

要拍完整页面，先 `scrollIntoViewIfNeeded()` 走一遍再截，或者直接断言
`getComputedStyle(el).opacity === '1'`。只看截图会得出错结论。
