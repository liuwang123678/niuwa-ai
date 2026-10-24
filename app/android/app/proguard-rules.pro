# Flutter 3.44 的 Gradle 插件默认给 release 开 R8（缩小 + 混淆）。
#
# 大部分插件走 MethodChannel，靠字符串通道名通信，混淆不影响它们。
# 但 shared_preferences_android 2.5.0 起改成了 **Dart JNI 直连**：Dart 侧拿
# 「类名 + 完整方法描述符」去 JVM 里反射找方法，描述符里带着参数类型的全名。
#
# R8 会把 kotlin.coroutines.Continuation 改名（实测成了 Lf2/d;），于是
#   Dart 找  : getAll(String, List, Lkotlin/coroutines/Continuation;)Object
#   dex 里是 : getAll(String, List, Lf2/d;)Object
# 对不上 → 启动就崩：
#   PlatformException(... NoSuchMethodError: no non-static method
#   "Lio/flutter/plugins/sharedpreferences/SharedPreferencesApiRegistrar;
#    .getAll(Ljava/lang/String;Ljava/util/List;Ljava/util/...)" ...)
#
# 保留这个接口名就行；它不是业务类，留着不心疼。

-keep interface kotlin.coroutines.Continuation { *; }

# 插件自己的类已经标了 @Keep，这里再兜一层：以后插件加新方法 / 新 Registrar
# 不会因为漏标 @Keep 又踩同一个坑。包很小，代价可以忽略。
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# package:jni 还要在 Dart 侧按名字反射几个 Kotlin 运行时类
# （jni-1.1.0/lib/src/kotlin.dart 的 JClass.forName）。这些类**没有任何 Java
# 调用点**——Dart 才是调用方，所以 R8 一律当死代码删掉。删掉后的症状：
#   PlatformException(... ClassNotFoundException: Didn't find class
#   "kotlin/coroutines/intrinsics/CoroutineSingletons" ...)
# 2026-10-17 真机撞到，v10 的启动就是卡在这个类上。Continuation 能活下来只是
# 因为上面那条 keep 顺手保住了；下面这些一个都不能少，否则会逐个轮流崩
# （CoroutineSingletons → IntrinsicsKt → Result → Unit）。
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.intrinsics.** { *; }
-dontwarn kotlin.coroutines.intrinsics.**
