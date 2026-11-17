# JNI entry points are resolved by exact Java class and method names.
-keep class com.usque.dfathu.NativeEngine {
    *;
}
-keepclasseswithmembernames class * {
    native <methods>;
}

# Android instantiates these components from the manifest. Keep the service's
# @Keep callbacks as their names are also resolved by Rust through JNI.
-keep class com.usque.dfathu.MainActivity { *; }
-keep class com.usque.dfathu.UsqueVpnService { *; }
-keep class com.usque.dfathu.XrayVpnService { *; }

# hev-socks5-tunnel registers its natives from JNI_OnLoad by exact class
# name (hev/htproxy/TProxyService); R8 must never rename or strip it.
-keep class hev.htproxy.TProxyService { *; }
-keep @androidx.annotation.Keep class * { *; }
-keepclassmembers class * {
    @androidx.annotation.Keep <methods>;
}
