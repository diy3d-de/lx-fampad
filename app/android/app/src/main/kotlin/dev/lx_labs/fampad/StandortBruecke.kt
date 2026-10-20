package dev.lx_labs.fampad

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Verbindung zwischen dem Standort-Vordergrunddienst ([StandortService]) und der Dart-Seite (lib/data/standort/standort_port_android.dart).
 * Beides läuft im selben Prozess; die Zustände stehen deshalb in einem Singleton. Es wird nichts gespeichert: Positionen gehen nur als Ereignis
 * an Dart, solange dort jemand zuhört, sonst werden sie verworfen. Nichts davon wird protokolliert.
 */
object StandortBruecke {
    private val haupt = Handler(Looper.getMainLooper())

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

    fun ereignis(daten: Map<String, Any?>) {
        haupt.post { senke?.success(daten) }
    }
}
