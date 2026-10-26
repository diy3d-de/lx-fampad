package dev.lx_labs.fampad

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * Vordergrunddienst (Typ dataSync) für Datei-Übertragungen (lib/data/dateien/transfer_hintergrund_android.dart): hält den Prozess am Leben, solange
 * Uploads oder Downloads laufen, damit sie beim Wechsel in den Hintergrund nicht abbrechen. Die Benachrichtigung zeigt nur einen festen Text und
 * Zahlen ("Übertragung läuft" / "n Übertragungen", Prozent), nie einen Dateinamen oder Inhalt. Hochgeladen wird in Dart; der Dienst tut sonst nichts.
 *
 * Er beendet sich selbst, wenn
 *  - Dart ihn beendet (Warteschlange leer, Abmelden),
 *  - die Dart-Seite länger als [LEBENSZEICHEN_FRIST_MS] nichts gemeldet hat (App beendet, Absturz: nie hängen bleiben),
 *  - die App aus der Liste der letzten Apps gewischt wird,
 *  - Android das Zeitlimit für dataSync meldet (ab Android 15).
 */
class TransferService : Service() {
    companion object {
        const val ACTION_START = "dev.lx_labs.fampad.transfer.START"
        const val ACTION_UPDATE = "dev.lx_labs.fampad.transfer.UPDATE"
        const val EXTRA_ANZAHL = "anzahl"
        const val EXTRA_PROZENT = "prozent"
        const val KANAL_ID = "datei_uebertragung"
        private const val NOTIFICATION_ID = 4713
        private const val LEBENSZEICHEN_FRIST_MS = 2 * 60 * 1000L
        private const val WACHE_MS = 15_000L

        /** Läuft der Dienst gerade (Prozess-weit; nur zur Auskunft an den Kanal). */
        @Volatile
        var laeuft = false
    }

    private val haupt = Handler(Looper.getMainLooper())
    private var anzahl = 1
    private var prozent = 0
    private var letztesLebenszeichen = 0L

    private val wache = object : Runnable {
        override fun run() {
            if (System.currentTimeMillis() - letztesLebenszeichen > LEBENSZEICHEN_FRIST_MS) {
                beenden()
            } else {
                haupt.postDelayed(this, WACHE_MS)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_UPDATE -> {
                anzahl = intent.getIntExtra(EXTRA_ANZAHL, 1).coerceIn(1, 9999)
                prozent = intent.getIntExtra(EXTRA_PROZENT, 0).coerceIn(0, 100)
                letztesLebenszeichen = System.currentTimeMillis()
                if (!laeuft) {
                    // Wer startForegroundService ruft, muss startForeground rechtzeitig aufrufen (sonst stürzt die App ab)
                    try {
                        val n = benachrichtigung()
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                        } else {
                            startForeground(NOTIFICATION_ID, n)
                        }
                    } catch (_: Exception) {
                        // z. B. Start aus dem Hintergrund nicht erlaubt: die Übertragung läuft in der App weiter, nur ohne Dienst
                        beenden()
                        return START_NOT_STICKY
                    }
                    laeuft = true
                    haupt.postDelayed(wache, WACHE_MS)
                } else {
                    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, benachrichtigung())
                }
            }
            // kein Neustart durch das System nach einem Prozess-Tod (null-Intent): ohne die App gibt es nichts zu übertragen
            else -> beenden()
        }
        return START_NOT_STICKY
    }

    private fun benachrichtigung(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(KANAL_ID) == null) {
            val kanal = NotificationChannel(KANAL_ID, "Datei-Übertragungen", NotificationManager.IMPORTANCE_LOW)
            kanal.description = "Zeigt, solange Dateien hoch- oder heruntergeladen werden. Ohne Dateinamen."
            kanal.setShowBadge(false)
            nm.createNotificationChannel(kanal)
        }
        val offnen = packageManager.getLaunchIntentForPackage(packageName)
        val offnenPi = offnen?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
        val titel = if (anzahl <= 1) "Übertragung läuft" else "$anzahl Übertragungen"
        return NotificationCompat.Builder(this, KANAL_ID)
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle(titel)
            .setContentText("$prozent %")
            .setProgress(100, prozent, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .apply { if (offnenPi != null) setContentIntent(offnenPi) }
            .build()
    }

    private fun beenden() {
        haupt.removeCallbacks(wache)
        laeuft = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** Android 15: das Zeitlimit für dataSync ist erreicht; der Dienst muss sich beenden (die App versucht es beim nächsten Abgleich erneut). */
    override fun onTimeout(startId: Int, fgsType: Int) {
        beenden()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        beenden()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        haupt.removeCallbacks(wache)
        laeuft = false
        super.onDestroy()
    }
}
