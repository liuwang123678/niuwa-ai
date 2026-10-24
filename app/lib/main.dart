import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'app_info.dart';
import 'design/tokens.dart';
import 'providers/chat_provider.dart';
import 'providers/memory_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/skills_provider.dart';
import 'services/data_root.dart';
import 'services/error_log.dart';
import 'services/n1_runtime.dart';
import 'shell/app_shell.dart';
import 'theme.dart';
import 'widgets/browser_host.dart';
import 'widgets/n1_mark.dart';
import 'widgets/splash_gate.dart';

/// N1 的入口。
///
/// 启动顺序是有讲究的：**内核先装好，界面才建立**。[N1Runtime.boot] 要开数据库、
/// 读人设、扫技能目录，这三件事在页面存在之前就得做完——因为
/// `PromptBuilder` 拿的是启动那一刻的人设快照。反过来做（页面先出现、再异步补）
/// 会有一段"界面在，但发消息会炸"的窗口期。
///
/// 以前这里是 `await N1Runtime.boot()` 之后才 `runApp`，代价是首帧之前屏幕上
/// 什么都没有：安卓是一块死白（深色下死黑），Windows 是一个空窗口。
/// 现在改成**先画启动动画、让 boot 在它背后跑**——两个时间重叠掉，
/// 界面仍然等到 boot 完成之后才构建，那条约束没有破。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 必须在读任何路径之前。这一步把 Windows 上的数据目录从 C 盘的
  // %APPDATA% 改成 exe 旁边的 userdata\（见 services/data_root.dart）。
  // 位置很关键：上面那行 ensureInitialized 才会注册 path_provider_windows，
  // 我们要包的正是它；下面 boot() 第一件事就是开数据库，晚了就来不及。
  await installPortableDataRoot();

  // 全局兜底落盘（services/error_log.dart）。必须在 runApp 之前装——晚于第一帧，
  // 启动阶段炸掉的那种就抓不到了。装不上也不能挡启动：日志是排查工具，
  // 不是运行前提。
  try {
    final support = await getApplicationSupportDirectory();
    installErrorLogging(support, appName: appName);
  } catch (e) {
    debugPrint('错误日志没装上：$e');
  }

  // 不 await：先让启动动画上屏，boot 在它背后跑。
  final boot = _boot();

  runApp(
    SplashGate<N1Runtime>(
      boot: boot,
      builder: (runtime) => N1App(runtime: runtime),
      // 起不来就**把原因摊给用户看**，不要白屏、也不要静默重试。
      // 绝大多数情况是本地存储没起来（权限、磁盘、动态库没打进包），
      // 白屏的话用户只会以为 App 坏了；摊出来至少能截图发出来。
      errorBuilder: (e) => _BootFailure(error: e.toString()),
    ),
  );
}

/// 把启动异常记进日志，再原样抛回去。
///
/// [SplashGate] 拿不到堆栈，但它负责把失败摊到界面上。日志留在这边落，
/// 两边各管一段。
Future<N1Runtime> _boot() async {
  try {
    return await N1Runtime.boot();
  } catch (e, stack) {
    debugPrint('N1 启动失败：$e');
    debugPrintStack(stackTrace: stack);
    rethrow;
  }
}

class N1App extends StatelessWidget {
  const N1App({super.key, required this.runtime});

  final N1Runtime runtime;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // [N1Runtime] 不是 ChangeNotifier。用 `.value` 是**故意**的：它声明
        // "这个对象由 main 持有，谁都别在卸载时去 dispose 它"——数据库连接是
        // 进程级的，跟着某个页面一起关掉就乱了。
        Provider<N1Runtime>.value(value: runtime),

        ChangeNotifierProvider(
          create: (_) => SettingsProvider(
            store: runtime.settings,
            secure: runtime.secure,
            builtInPersona: runtime.builtInPersona,
          ),
        ),

        // `..load()` 是"把上次的对话读回来"。**不 await**：它自己会 notify，
        // 让页面先画出来、读完再刷，比卡一段白屏好。
        ChangeNotifierProvider(
          create: (_) =>
              ChatProvider(runtime: runtime, store: runtime.messages)..load(),
        ),
        ChangeNotifierProvider(
          create: (_) => MemoryProvider(store: runtime.memory)..load(),
        ),
        ChangeNotifierProvider(create: (_) => SkillsProvider(runtime: runtime)),
      ],
      child: MaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,

        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: ThemeMode.system,

        // 界面只有中文，所以语言**锁死**。不锁的话，系统语言是英文时
        // Material 自带的那部分（文本选择菜单的"复制/粘贴"、对话框的无障碍
        // 标签）会跟着变英文，混在我们自己的中文界面里。
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],

        // 系统字号拉到 1.6 时，工具调用那种"图标 + 名字 + 耗时"全挤在一行的
        // 布局会开始互相压。上限压到 1.4——不是取消缩放（那是不把无障碍设置
        // 当回事），只削掉会把布局撑坏的那一段。
        //
        // 外面套一层 [BrowserHost] 是**安卓那边的硬需求**：它要往树里挂一块
        // 移出屏幕、但保持真实尺寸的 WebView，否则页面没有布局、快照读到零个
        // 元素。放这儿而不是某个页面里，是因为它是**进程级**的——换页面、
        // 进设置、开技能页，它都得一直在，挂在页面上就会跟着页面一起被销毁。
        // 非安卓平台上它是透明的（原样返回 child）。
        builder: (context, child) => BrowserHost(
          driver: runtime.browser,
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.4,
            child: child ?? const SizedBox.shrink(),
          ),
        ),

        home: const AppShell(),
      ),
    );
  }
}

/// 启动失败时的兜底界面。
///
/// 刻意做得跟正常界面同一套配色和同一个牛蛙标志：让用户一眼看出"这还是那个
/// App，只是它没起来"，而不是一个像系统报错的蓝屏。
class _BootFailure extends StatelessWidget {
  const _BootFailure({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final c = N1Colors.light;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(S.x8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Center(child: N1Mark(size: 56)),
                  const SizedBox(height: S.x7),
                  Text(
                    '起不来',
                    style: n1Text(size: 22, weight: 600, color: c.ink,
                        height: 1.38, tracking: -0.02),
                  ),
                  const SizedBox(height: S.x3),
                  Text(
                    '$appName 在启动的时候出错了。这通常是本地存储没起来'
                    '（权限、磁盘空间，或者打包时漏了某个动态库）。',
                    style: n1Text(size: 14, height: 1.7, color: c.dim),
                  ),
                  const SizedBox(height: S.x6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(S.x4),
                    decoration: BoxDecoration(
                      color: c.bg,
                      borderRadius: R.smAll,
                      border: Border.all(color: c.line),
                    ),
                    // 可选中：用户得能把它复制出来发给别人看。
                    child: SelectableText(
                      error,
                      style: n1Text(size: 12, height: 1.6, color: c.danger,
                          mono: true),
                    ),
                  ),
                  const SizedBox(height: S.x5),
                  Text(
                    '完整堆栈在调试日志里。',
                    style: n1Text(size: 12, color: c.faint, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
