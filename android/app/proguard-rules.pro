# TVBox spider jar 通过 DexClassLoader 在运行时加载，它们继承、调用的
# com.github.catvod.crawler.Spider 必须在 APK 里保留原名原签名，否则 R8
# 会把 stub 改名/抽掉，运行时抛：
#   Spider 执行失败: Class not found using the boot class loader
-keep class com.github.catvod.** { *; }
-keep interface com.github.catvod.** { *; }
-keepclassmembers class com.github.catvod.** { *; }
-dontwarn com.github.catvod.**

# 桥自身通过 MethodChannel 反射调用，保留入口
-keep class com.guoapp.SpiderBridge { *; }
-keep class com.guoapp.WebViewBridge { *; }
-keep class com.guoapp.MainActivity { *; }

# TVBox spider jar 在运行时链接的第三方库：R8 看不到静态引用，必须整包保留
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class com.google.gson.** { *; }
-keep class org.jsoup.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.jsoup.**
-dontwarn com.google.gson.**
