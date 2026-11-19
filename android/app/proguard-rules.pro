# R8 rules for the release build. Flutter's Gradle plugin adds this file next
# to proguard-android-optimize.txt and its own rules.
#
# Most of the keep rules come from the packages' own consumer rules and are
# fine as they are: the Flutter embedding and plugins (kept by name because the
# generated registrant is looked up by reflection), package:jni and
# jni_flutter (their Java side is called by name through JNI), AndroidX and
# Play services.
#
# The one set that was too broad is cronet_http's, which kept everything under
# org.chromium.net, including the Cronet logging and helper classes that
# nothing calls. android/build.gradle.kts empties that rule and the exact set
# is declared here instead.

# HTTP/3 on Android: native_dio_adapter -> cronet_http -> the Cronet module in
# Google Play services. The Dart bindings in cronet_http look up the public
# Cronet API by name and call its members through JNI, and the Play services
# module calls back into the same API, so it keeps its names and members.
# (This is also the rule Google's play-services-cronet ships.) Everything
# deeper in org.chromium.net is reached only through these classes and is
# shrunk and renamed normally.
-keep public class org.chromium.net.* {
    !private *;
    *;
}

# Cronet bundles protobuf-lite for its HTTP flags (org.chromium.net.httpflags),
# and protobuf-lite finds the fields of a generated message by name through
# reflection, so they keep their names. This is the rule protobuf's own
# consumer rules carry; the copy inside cronet-shared ships none.
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}

# The Java half of cronet_http: UrlRequestCallbackProxy is created and called
# from Dart through JNI.
-keep class io.flutter.plugins.cronet_http.** { *; }

# The "apiworkbench/sound" MethodChannel in MainActivity registers a lambda,
# and MainActivity itself is kept as a manifest entry point, so Chaos Mode
# sounds need no rule of their own. Nothing in the app uses reflection.
