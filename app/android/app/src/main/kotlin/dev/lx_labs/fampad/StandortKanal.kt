package dev.lx_labs.fampad

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Kanäle fürs Standort teilen (lib/data/standort/standort_port_android.dart): Berechtigungen abfragen, den Vordergrunddienst starten und
 * beenden, Lebenszeichen der Dart-Seite entgegennehmen und Ereignisse (Position, "Beenden" in der Benachrichtigung) liefern.
 * Berechtigungen nur FINE/COARSE im Vordergrund und (ab Android 13) Benachrichtigungen; ACCESS_BACKGROUND_LOCATION gibt es bewusst nicht.
 */
class StandortKanal(private val activity: Activity) {
    companion object {
        const val METHODEN = "dev.lx_labs.fampad/standort"
        const val EREIGNISSE = "dev.lx_labs.fampad/standort_ereignisse"
        private const val ANFRAGE_CODE = 4712
    }

    private var offeneAnfrage: MethodChannel.Result? = null

    fun einrichten(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODEN).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "berechtigungAnfragen" -> berechtigungAnfragen(result)
                "start" -> result.success(starten(call.argument<Number>("ende")?.toLong() ?: 0L, call.argument<Number>("intervall")?.toLong() ?: 5000L))
                "verlaengern" -> {
                    val ende = call.argument<Number>("ende")?.toLong() ?: 0L
                    if (StandortBruecke.laeuft && ende > System.currentTimeMillis()) {
                        activity.startService(
                            Intent(activity, StandortService::class.java).setAction(StandortService.ACTION_UPDATE).putExtra(StandortService.EXTRA_ENDE, ende),
                        )
                    }
                    result.success(null)
                }
                "stop" -> {
                    activity.stopService(Intent(activity, StandortService::class.java))
                    result.success(null)
                }
                "herzschlag" -> {
                    StandortBruecke.letzterHerzschlag = System.currentTimeMillis()
                    result.success(mapOf("laeuft" to StandortBruecke.laeuft, "stopAngefordert" to StandortBruecke.stopAngefordert))
                }
                "einstellungenOeffnen" -> result.success(oeffnen(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))))
                "akkuEinstellungenOeffnen" -> result.success(
                    oeffnen(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
                        oeffnen(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))),
                )
                // true = die App ist von der Akkuoptimierung ausgenommen ("Nicht eingeschränkt"); false = Android (One UI: "Optimiert") darf sie im Hintergrund bremsen
                "akkuUneingeschraenkt" -> result.success(akkuUneingeschraenkt())
                // Systemdialog "Im Hintergrund ohne Einschränkung ausführen?" (nur diese App, die Person bestätigt selbst); sonst die Liste der Einstellungen
                "akkuAnfragen" -> result.success(
                    oeffnen(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${activity.packageName}"))) ||
                        oeffnen(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
                        oeffnen(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))),
                )
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, EREIGNISSE).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    StandortBruecke.senke = events
                }

                override fun onCancel(arguments: Any?) {
                    StandortBruecke.senke = null
                }
            },
        )
    }

    /**
     * Beim Abbau der Engine: niemand hört mehr zu. Ist die Oberfläche wirklich weg (nicht nur neu aufgebaut, z. B. nach einer Konfigurationsänderung),
     * gibt es nichts mehr zu teilen: den Dienst gleich beenden statt auf die Frist des Lebenszeichens zu warten.
     */
    fun abbauen(neuAufbau: Boolean) {
        StandortBruecke.senke = null
        offeneAnfrage = null
        if (!neuAufbau) activity.stopService(Intent(activity, StandortService::class.java))
    }

    private fun hat(permission: String) = ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED

    private fun dienstAn(): Boolean {
        val lm = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return try {
            lm.isLocationEnabled
        } catch (_: Exception) {
            false
        }
    }

    private fun akkuUneingeschraenkt(): Boolean =
        try {
            (activity.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(activity.packageName)
        } catch (_: Exception) {
            false
        }

    private fun status(): Map<String, Any> =
        mapOf(
            "fein" to hat(Manifest.permission.ACCESS_FINE_LOCATION),
            "grob" to hat(Manifest.permission.ACCESS_COARSE_LOCATION),
            "benachrichtigungen" to NotificationManagerCompat.from(activity).areNotificationsEnabled(),
            "dienstAn" to dienstAn(),
            "laeuft" to StandortBruecke.laeuft,
        )

    private fun berechtigungAnfragen(result: MethodChannel.Result) {
        if (offeneAnfrage != null) {
            result.error("BESCHAEFTIGT", "Es läuft schon eine Anfrage.", null)
            return
        }
        val liste = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) liste.add(Manifest.permission.POST_NOTIFICATIONS)
        offeneAnfrage = result
        activity.requestPermissions(liste.toTypedArray(), ANFRAGE_CODE)
    }

    fun beiBerechtigung(requestCode: Int) {
        if (requestCode != ANFRAGE_CODE) return
        offeneAnfrage?.success(status())
        offeneAnfrage = null
    }

    /** Startet den Vordergrunddienst nur mit Erlaubnis und sichtbarer Benachrichtigung (sonst ließe sich das Teilen nicht beenden). */
    private fun starten(ende: Long, intervall: Long): Map<String, Any?> {
        if (ende <= System.currentTimeMillis()) return mapOf("ok" to false, "grund" to "ende")
        if (!hat(Manifest.permission.ACCESS_FINE_LOCATION) && !hat(Manifest.permission.ACCESS_COARSE_LOCATION)) return mapOf("ok" to false, "grund" to "keine_berechtigung")
        if (!NotificationManagerCompat.from(activity).areNotificationsEnabled()) return mapOf("ok" to false, "grund" to "benachrichtigungen_aus")
        StandortBruecke.letzterHerzschlag = System.currentTimeMillis()
        StandortBruecke.stopAngefordert = false
        return try {
            ContextCompat.startForegroundService(
                activity,
                Intent(activity, StandortService::class.java).setAction(StandortService.ACTION_START).putExtra(StandortService.EXTRA_ENDE, ende)
                    .putExtra(StandortService.EXTRA_INTERVALL, intervall),
            )
            mapOf("ok" to true)
        } catch (_: Exception) {
            mapOf("ok" to false, "grund" to "dienst_start")
        }
    }

    private fun oeffnen(intent: Intent): Boolean =
        try {
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
}
