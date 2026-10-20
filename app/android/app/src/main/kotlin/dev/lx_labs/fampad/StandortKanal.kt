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
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Kanäle fürs Standort teilen (lib/data/standort/standort_port_android.dart): Berechtigungen abfragen, den Vordergrunddienst starten und
 * beenden, Lebenszeichen der Dart-Seite entgegennehmen und Ereignisse (Position, "Beenden" in der Benachrichtigung) liefern.
 * Berechtigungen nur FINE/COARSE im Vordergrund und (ab Android 13) Benachrichtigungen; ACCESS_BACKGROUND_LOCATION gibt es bewusst nicht.
 *
 * **An die Engine gebunden, nicht an die Activity:** Solange geteilt wird, bleibt die Flutter-Engine (und damit die Dart-Seite mit den Schlüsseln im
 * Arbeitsspeicher) auch ohne Oberfläche am Leben (MainActivity: Engine im Cache, [StandortBruecke.laeuft]). Die Kanäle werden deshalb **einmal je
 * Engine** angelegt (nie bei jedem Neuaufbau der Activity, sonst ginge der Ereignisstrom verloren); nur Dinge, die eine Oberfläche brauchen
 * (Berechtigungsdialog, Einstellungen öffnen), benutzen die [activity], die MainActivity beim Anheften setzt und beim Lösen entfernt.
 */
class StandortKanal private constructor(private val ctx: Context) {
    companion object {
        const val METHODEN = "dev.lx_labs.fampad/standort"
        const val EREIGNISSE = "dev.lx_labs.fampad/standort_ereignisse"
        private const val ANFRAGE_CODE = 4712
        private val kanaele = HashMap<FlutterEngine, StandortKanal>()

        /** Der Kanal dieser Engine; wird beim ersten Aufruf angelegt (Kanäle, Ereignisstrom) und fällt mit der Engine wieder weg. */
        fun fuer(engine: FlutterEngine, ctx: Context): StandortKanal =
            kanaele.getOrPut(engine) {
                val k = StandortKanal(ctx.applicationContext)
                k.einrichten(engine)
                engine.addEngineLifecycleListener(
                    object : FlutterEngine.EngineLifecycleListener {
                        override fun onPreEngineRestart() {}

                        override fun onEngineWillDestroy() {
                            kanaele.remove(engine)
                            // eine zerstörte Engine darf nie aus dem Cache kommen (MainActivity.provideFlutterEngine)
                            if (FlutterEngineCache.getInstance().get(StandortBruecke.ENGINE_ID) === engine) FlutterEngineCache.getInstance().remove(StandortBruecke.ENGINE_ID)
                            StandortBruecke.senke = null
                        }
                    },
                )
                k
            }
    }

    /** Die sichtbare Activity (null, solange keine Oberfläche da ist). */
    var activity: Activity? = null

    private var offeneAnfrage: MethodChannel.Result? = null

    private fun einrichten(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODEN).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "berechtigungAnfragen" -> berechtigungAnfragen(result)
                "start" -> result.success(starten(call.argument<Number>("ende")?.toLong() ?: 0L, call.argument<Number>("intervall")?.toLong() ?: 5000L))
                "verlaengern" -> {
                    val ende = call.argument<Number>("ende")?.toLong() ?: 0L
                    if (StandortBruecke.laeuft && ende > System.currentTimeMillis()) {
                        ctx.startService(
                            Intent(ctx, StandortService::class.java).setAction(StandortService.ACTION_UPDATE).putExtra(StandortService.EXTRA_ENDE, ende),
                        )
                    }
                    result.success(null)
                }
                "stop" -> {
                    ctx.stopService(Intent(ctx, StandortService::class.java))
                    result.success(null)
                }
                "herzschlag" -> {
                    StandortBruecke.letzterHerzschlag = System.currentTimeMillis()
                    result.success(mapOf("laeuft" to StandortBruecke.laeuft, "stopAngefordert" to StandortBruecke.stopAngefordert))
                }
                "einstellungenOeffnen" -> result.success(oeffnen(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))))
                "akkuEinstellungenOeffnen" -> result.success(
                    oeffnen(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
                        oeffnen(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))),
                )
                // true = die App ist von der Akkuoptimierung ausgenommen ("Nicht eingeschränkt"); false = Android (One UI: "Optimiert") darf sie im Hintergrund bremsen
                "akkuUneingeschraenkt" -> result.success(akkuUneingeschraenkt())
                // Systemdialog "Im Hintergrund ohne Einschränkung ausführen?" (nur diese App, die Person bestätigt selbst); sonst die Liste der Einstellungen
                "akkuAnfragen" -> result.success(
                    oeffnen(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}"))) ||
                        oeffnen(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
                        oeffnen(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))),
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

    /** Die Activity wird zerstört: Dialoge ohne Antwort verwerfen. Der Ereignisstrom und der Dienst bleiben (siehe Klassenkommentar). */
    fun loesen() {
        activity = null
        offeneAnfrage = null
    }

    private fun hat(permission: String) = ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED

    private fun dienstAn(): Boolean {
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return try {
            lm.isLocationEnabled
        } catch (_: Exception) {
            false
        }
    }

    private fun akkuUneingeschraenkt(): Boolean =
        try {
            (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(ctx.packageName)
        } catch (_: Exception) {
            false
        }

    private fun status(): Map<String, Any> =
        mapOf(
            "fein" to hat(Manifest.permission.ACCESS_FINE_LOCATION),
            "grob" to hat(Manifest.permission.ACCESS_COARSE_LOCATION),
            "benachrichtigungen" to NotificationManagerCompat.from(ctx).areNotificationsEnabled(),
            "dienstAn" to dienstAn(),
            "laeuft" to StandortBruecke.laeuft,
        )

    private fun berechtigungAnfragen(result: MethodChannel.Result) {
        val a = activity
        if (a == null) {
            result.success(status())
            return
        }
        if (offeneAnfrage != null) {
            result.error("BESCHAEFTIGT", "Es läuft schon eine Anfrage.", null)
            return
        }
        val liste = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) liste.add(Manifest.permission.POST_NOTIFICATIONS)
        offeneAnfrage = result
        a.requestPermissions(liste.toTypedArray(), ANFRAGE_CODE)
    }

    fun beiBerechtigung(requestCode: Int) {
        if (requestCode != ANFRAGE_CODE) return
        offeneAnfrage?.success(status())
        offeneAnfrage = null
    }

    /** Startet den Vordergrunddienst nur mit Erlaubnis und sichtbarer Benachrichtigung (sonst ließe sich das Teilen nicht beenden). */
    private fun starten(ende: Long, intervall: Long): Map<String, Any?> {
        // Start nur aus der sichtbaren App (Android 12+ erlaubt es sonst nicht, und die Person soll es selbst auslösen)
        if (activity == null) return mapOf("ok" to false, "grund" to "dienst_start")
        if (ende <= System.currentTimeMillis()) return mapOf("ok" to false, "grund" to "ende")
        if (!hat(Manifest.permission.ACCESS_FINE_LOCATION) && !hat(Manifest.permission.ACCESS_COARSE_LOCATION)) return mapOf("ok" to false, "grund" to "keine_berechtigung")
        if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return mapOf("ok" to false, "grund" to "benachrichtigungen_aus")
        StandortBruecke.letzterHerzschlag = System.currentTimeMillis()
        StandortBruecke.stopAngefordert = false
        return try {
            ContextCompat.startForegroundService(
                ctx,
                Intent(ctx, StandortService::class.java).setAction(StandortService.ACTION_START).putExtra(StandortService.EXTRA_ENDE, ende)
                    .putExtra(StandortService.EXTRA_INTERVALL, intervall),
            )
            mapOf("ok" to true)
        } catch (_: Exception) {
            mapOf("ok" to false, "grund" to "dienst_start")
        }
    }

    private fun oeffnen(intent: Intent): Boolean {
        val a = activity ?: return false
        return try {
            a.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
