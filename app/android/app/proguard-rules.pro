# Terminerinnerungen (flutter_local_notifications): speichert geplante Benachrichtigungen mit Gson und liest sie nach einem Neustart
# per Reflection/TypeToken zurück. Ohne diese Regeln entfernt oder benennt R8 die Klassen im Release-Build um, und die Alarme gehen
# nach dem Neustart verloren (Quelle: README des Plugins, "ProGuard rules").
-keep class com.dexterous.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
