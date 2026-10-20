package dev.lx_labs.fampad

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel

/**
 * Verbindung zwischen dem Standort-Vordergrunddienst ([StandortService]) und der Dart-Seite (lib/data/standort/standort_port_android.dart).
 * Beides läuft im selben Prozess; die Zustände stehen deshalb in einem Singleton. Es wird nichts gespeichert: Positionen gehen nur als Ereignis
 * an Dart, solange dort jemand zuhört, sonst werden sie verworfen. Nichts davon wird protokolliert.
 */
object StandortBruecke {
    private val haupt = Handler(Looper.getMainLooper())

    /** Schlüssel der Engine im FlutterEngineCache (MainActivity). */
    const val ENGINE_ID = "lx_fampad_haupt"

    /** Gibt es gerade eine Activity (sichtbare Oberfläche)? */
    @Volatile
    var activityDa: Boolean = false

    /** Zuhörer auf der Dart-Seite (nur im Hauptthread lesen und schreiben). */
    var senke: EventChannel.EventSink? = null

    /** Zeitpunkt (Uhrzeit in ms) des letzten Lebenszeichens der Dart-Seite; bleibt es aus, beendet sich der Dienst selbst. */
    @Volatile
    var letzterHerzschlag: Long = 0

    /** Die Person hat in der Benachrichtigung auf "Beenden" getippt (Dart erfährt es per Ereignis oder spätestens beim nächsten Herzschlag). */
    @Volatile
    var stopAngefordert: Boolean = false

    @Volatile
    var laeuft: Boolean = false

    /**
     * Der Dienst ist beendet. War dabei keine Oberfläche mehr da (das Teilen lief nur noch im Hintergrund), wird die Engine samt Dart-Seite und
     * Schlüsseln im Arbeitsspeicher beendet. Kurz verzögert, damit die Dart-Seite noch ein "loc_stop" senden kann.
     */
    fun dienstBeendet() {
        haupt.postDelayed({
            if (!laeuft && !activityDa) {
                val cache = FlutterEngineCache.getInstance()
                val engine = cache.get(ENGINE_ID)
                cache.remove(ENGINE_ID)
                engine?.destroy()
            }
        }, 5_000L)
    }

    fun ereignis(daten: Map<String, Any?>) {
        haupt.post { senke?.success(daten) }
    }
}
