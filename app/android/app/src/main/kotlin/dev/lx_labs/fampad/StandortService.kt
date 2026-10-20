package dev.lx_labs.fampad

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.text.DateFormat
import java.util.Date

/**
 * Vordergrunddienst fürs Standort teilen. Er läuft nur, solange die Person geteilt hat (Start per Tipp in der App), zeigt dazu eine ständige
 * Benachrichtigung mit Restzeit und "Beenden" und holt Positionen mit dem Android-LocationManager (kein Google-Dienst, keine Fremdbibliothek).
 * Es gibt KEINE Berechtigung für den Hintergrund (ACCESS_BACKGROUND_LOCATION): der Dienst wird aus der sichtbaren App gestartet.
 *
 * Verschlüsselt, signiert und gesendet wird in Dart (die Positionen gehen als Ereignis über [StandortBruecke]); der Dienst hält nur den Prozess am
 * Leben und liefert Positionen. Er beendet sich selbst, wenn
 *  - die Ablaufzeit erreicht ist,
 *  - die Dart-Seite länger als [HERZSCHLAG_FRIST_MS] kein Lebenszeichen gegeben hat (App beendet, Absturz),
 *  - die Person in der Benachrichtigung auf "Beenden" tippt oder die App ihn beendet,
 *  - die App aus der Liste der letzten Apps gewischt wird.
 */
class StandortService : Service() {
    companion object {
        const val ACTION_START = "dev.lx_labs.fampad.standort.START"
        const val ACTION_STOP = "dev.lx_labs.fampad.standort.STOP"
        const val ACTION_UPDATE = "dev.lx_labs.fampad.standort.UPDATE"
        const val EXTRA_ENDE = "ende"
        const val EXTRA_INTERVALL = "intervall"
        const val KANAL_ID = "standort_teilen"
        private const val NOTIFICATION_ID = 4711
        private const val HERZSCHLAG_FRIST_MS = 3 * 60 * 1000L
        private const val WACHE_MS = 15_000L
        private const val STANDARD_ZEIT_MS = 5_000L
    }

    private var ende = 0L

    /** Abstand der Positionen in ms (Auswahl "Aktualisierung" in der App, 3 bis 15 s). */
    private var zeitMs = STANDARD_ZEIT_MS
    private var manager: LocationManager? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var letzte: Location? = null
    private val haupt = Handler(Looper.getMainLooper())

    private val wache = object : Runnable {
        override fun run() {
            val jetzt = System.currentTimeMillis()
            if (jetzt >= ende || jetzt - StandortBruecke.letzterHerzschlag > HERZSCHLAG_FRIST_MS) {
                beenden()
            } else {
                haupt.postDelayed(this, WACHE_MS)
            }
        }
    }

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            if (!besser(location, letzte)) return
            letzte = location
            StandortBruecke.ereignis(
                mapOf(
                    "art" to "position",
                    "breite" to location.latitude,
                    "laenge" to location.longitude,
                    "genauigkeit" to if (location.hasAccuracy()) location.accuracy.toDouble() else null,
                    "zeit" to location.time,
                ),
            )
        }

        // Android 9 und 10 (API 28/29) kennen für diese drei keine Standardmethoden: ohne eigene Umsetzung gäbe es einen AbstractMethodError
        @Deprecated("Seit API 29 nicht mehr aufgerufen")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

        override fun onProviderEnabled(provider: String) {
            StandortBruecke.ereignis(mapOf("art" to "dienst", "an" to dienstAn()))
        }

        override fun onProviderDisabled(provider: String) {
            StandortBruecke.ereignis(mapOf("art" to "dienst", "an" to dienstAn()))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> starten(intent.getLongExtra(EXTRA_ENDE, 0L), intent.getLongExtra(EXTRA_INTERVALL, STANDARD_ZEIT_MS))
            ACTION_UPDATE -> {
                val neu = intent.getLongExtra(EXTRA_ENDE, 0L)
                if (StandortBruecke.laeuft && neu > System.currentTimeMillis()) {
                    ende = neu
                    // die Wecksperre gilt nur bis zur alten Endzeit: neu setzen
                    try {
                        wakeLock?.takeIf { it.isHeld }?.release()
                    } catch (_: Exception) {
                        // schon freigegeben
                    }
                    wachbleiben()
                    meldungZeigen()
                }
            }
            ACTION_STOP -> {
                // "Beenden" in der Benachrichtigung: Dart erfährt es per Ereignis (läuft die Oberfläche nicht, beim nächsten Herzschlag oder gar nicht)
                StandortBruecke.stopAngefordert = true
                StandortBruecke.ereignis(mapOf("art" to "stop"))
                beenden()
            }
            // kein Neustart durch das System nach einem Prozess-Tod (null-Intent): ohne die Oberfläche gibt es nichts zu teilen
            else -> beenden()
        }
        return START_NOT_STICKY
    }

    private fun starten(endeMs: Long, intervallMs: Long) {
        zeitMs = intervallMs.coerceIn(1_000L, 60_000L)
        if (StandortBruecke.laeuft) {
          // schon laufender Dienst (z. B. neue Oberfläche nach Zurück-Taste): Endzeit übernehmen statt sie zu ignorieren
          if (endeMs > System.currentTimeMillis()) {
              ende = endeMs
              StandortBruecke.stopAngefordert = false
              try {
                  wakeLock?.takeIf { it.isHeld }?.release()
              } catch (_: Exception) {
              }
              wachbleiben()
              meldungZeigen()
          }
          return
        }
        // Wer den Dienst mit startForegroundService startet, muss startForeground rechtzeitig aufrufen (sonst stürzt die App ab): zuerst die
        // Benachrichtigung, dann erst prüfen (eine bereits vergangene Endzeit beendet den Dienst gleich wieder)
        ende = maxOf(endeMs, System.currentTimeMillis() + 1_000L)
        StandortBruecke.stopAngefordert = false
        try {
            val n = benachrichtigung()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
        } catch (_: Exception) {
            // z. B. Android 14 ohne Standort-Erlaubnis oder Start aus dem Hintergrund: nichts teilen
            StandortBruecke.ereignis(mapOf("art" to "fehler", "grund" to "dienst_start"))
            beenden()
            return
        }
        StandortBruecke.laeuft = true
        if (endeMs <= System.currentTimeMillis()) {
            beenden()
            return
        }
        if (!positionenAnfordern()) {
            StandortBruecke.ereignis(mapOf("art" to "fehler", "grund" to "keine_berechtigung"))
            beenden()
            return
        }
        wachbleiben()
        haupt.postDelayed(wache, WACHE_MS)
    }

    private fun hat(permission: String) = ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun dienstAn(): Boolean {
        val lm = manager ?: return false
        return try {
            lm.isLocationEnabled
        } catch (_: Exception) {
            false
        }
    }

    /** GPS und Netzwerk-Ortung, je nach Erlaubnis (nur "ungefähr" erlaubt: nur Netzwerk). Liefert false, wenn gar nichts angefordert werden konnte. */
    private fun positionenAnfordern(): Boolean {
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        manager = lm
        val fein = hat(Manifest.permission.ACCESS_FINE_LOCATION)
        val grob = hat(Manifest.permission.ACCESS_COARSE_LOCATION)
        if (!fein && !grob) return false
        var ok = false
        try {
            val anbieter = lm.allProviders
            if (fein && anbieter.contains(LocationManager.GPS_PROVIDER)) {
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, zeitMs, 0f, listener, Looper.getMainLooper())
                ok = true
            }
            if (anbieter.contains(LocationManager.NETWORK_PROVIDER)) {
                lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, zeitMs, 0f, listener, Looper.getMainLooper())
                ok = true
            }
        } catch (_: SecurityException) {
            return false
        } catch (_: Exception) {
            // Anbieter fehlt oder ist abgeschaltet: die Ereignisse "dienst" melden es der Oberfläche
        }
        if (!dienstAn()) StandortBruecke.ereignis(mapOf("art" to "dienst", "an" to false))
        return ok
    }

    /** Verliert nicht die beste Messung, wenn GPS und Netzwerk-Ortung abwechselnd melden (übliches Vorgehen laut Android-Dokumentation). */
    private fun besser(neu: Location, alt: Location?): Boolean {
        if (alt == null) return true
        val zeitDifferenz = neu.time - alt.time
        if (zeitDifferenz > 2 * 60 * 1000L) return true
        if (zeitDifferenz < -2 * 60 * 1000L) return false
        val genauigkeitDifferenz = (neu.accuracy - alt.accuracy).toInt()
        val genauer = genauigkeitDifferenz < 0
        val ungenauer = genauigkeitDifferenz > 0
        val deutlichUngenauer = genauigkeitDifferenz > 200
        val gleicherAnbieter = neu.provider == alt.provider
        return when {
            genauer -> true
            zeitDifferenz > 0 && !ungenauer -> true
            zeitDifferenz > 0 && !deutlichUngenauer && gleicherAnbieter -> true
            else -> false
        }
    }

    /** Hält die CPU wach, solange geteilt wird (nie länger als bis zur Ablaufzeit): sonst könnte Android den Versand bei gesperrtem Bildschirm verzögern. */
    private fun wachbleiben() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lx-fampad:standort")
            lock.setReferenceCounted(false)
            lock.acquire(maxOf(1_000L, ende - System.currentTimeMillis()))
            wakeLock = lock
        } catch (_: Exception) {
            // ohne Wecksperre läuft es weiter, nur eventuell verzögert
        }
    }

    private fun benachrichtigung(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(KANAL_ID) == null) {
            val kanal = NotificationChannel(KANAL_ID, "Standort teilen", NotificationManager.IMPORTANCE_LOW)
            kanal.description = "Zeigt, solange du deinen Standort mit der Familie teilst. Hier kannst du das Teilen jederzeit beenden."
            kanal.setShowBadge(false)
            nm.createNotificationChannel(kanal)
        }
        val offnen = packageManager.getLaunchIntentForPackage(packageName)
        val offnenPi = offnen?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
        val stopPi = PendingIntent.getService(
            this,
            1,
            Intent(this, StandortService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val uhr = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ende))
        return NotificationCompat.Builder(this, KANAL_ID)
            .setSmallIcon(R.drawable.ic_stat_standort)
            .setContentTitle("Du teilst deinen Standort")
            .setContentText("Die Familie sieht ihn bis $uhr Uhr. Er ist Ende-zu-Ende verschlüsselt.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setWhen(ende)
            .setUsesChronometer(true)
            .setChronometerCountDown(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .apply { if (offnenPi != null) setContentIntent(offnenPi) }
            .addAction(0, "Beenden", stopPi)
            .build()
    }

    private fun meldungZeigen() {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, benachrichtigung())
    }

    private fun beenden() {
        aufraeumen()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun aufraeumen() {
        haupt.removeCallbacks(wache)
        try {
            manager?.removeUpdates(listener)
        } catch (_: Exception) {
            // schon entfernt
        }
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
            // schon freigegeben
        }
        wakeLock = null
        letzte = null
        StandortBruecke.laeuft = false
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // App aus der Liste der letzten Apps gewischt: Die Engine mit der Dart-Seite bleibt am Leben (MainActivity), das Teilen läuft mit der sichtbaren
        // Benachrichtigung weiter und lässt sich dort beenden. Ohne die Dart-Seite (Prozess beendet) endet der Dienst über das fehlende Lebenszeichen.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        aufraeumen()
        StandortBruecke.dienstBeendet()
        super.onDestroy()
    }
}
