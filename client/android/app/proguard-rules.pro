# Jar spiders are loaded at runtime and link against host classes by name; keep them intact.
-keep class com.github.catvod.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class com.google.gson.** { *; }
-keep class org.jsoup.** { *; }
-keep class org.json.** { *; }
-keep class androidx.collection.** { *; }

# The embedded engine (reflection in Ktor, kotlinx.serialization, QuickJS bindings).
-keep class tvbox.engine.** { *; }
-keep class io.ktor.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlinx.serialization.** { *; }
-keep class com.dokar.quickjs.** { *; }
-keep class tvbox.next.tvbox_client.engine.** { *; }

-dontwarn **
