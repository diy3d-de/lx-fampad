# Terminerinnerungen (flutter_local_notifications): speichert geplante Benachrichtigungen mit Gson und liest sie nach einem Neustart
# per Reflection/TypeToken zurück. Ohne diese Regeln entfernt oder benennt R8 die Klassen im Release-Build um, und die Alarme gehen
# nach dem Neustart verloren (Quelle: README des Plugins, "ProGuard rules").
-keep class com.dexterous.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken

# Karte (maplibre_android, JNI-Brücke): Die Dart-Seite (jni.g.dart, JNI) ruft die Klassen des Plugins und des MapLibre-SDK über ihre Namen auf. R8 benennt
# sie im Release-Build um oder entfernt sie; dann scheitert das Anlegen der Karten-Ansicht mit einer NullPointerException und die Fläche bleibt leer
# (Debug-Builds laufen ohne R8 und zeigen den Fehler nicht). Das Paket bringt nur Regeln für org.maplibre und gson mit, nicht für seine eigenen Klassen.
-keep class com.github.josxha.maplibre.** { *; }
-keep class org.maplibre.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
# Die Dart-Seite implementiert Schnittstellen von Flutter per JNI und ruft sie über ihre Methodennamen auf (jni.g.dart: PlatformView.implement). R8 entfernt die
# "unbenutzten" abstrakten Methoden dieser Schnittstellen (getView, dispose ...): der Proxy hat dann keine Methode, getView() liefert null, und das Anlegen der Karte
# scheitert im Release-Build mit einer NullPointerException im PlatformViewsController (Debug läuft ohne R8 und zeigt es nicht). Ursache der leeren Karte in v0.5.0.
-keep interface io.flutter.plugin.platform.PlatformView { *; }
-keep class io.flutter.plugin.platform.PlatformViewFactory { *; }
-keep interface io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding { *; }
-keep interface io.flutter.plugin.common.PluginRegistry** { *; }
