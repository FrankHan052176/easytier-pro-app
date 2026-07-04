# EasyTier JNI is loaded and called through reflection from EasyTierNative.
# Keep the Java/Kotlin bridge intact so R8 cannot remove native methods from release APKs.
-keep class com.easytier.jni.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}
