package dev.lx_labs.fampad

import android.app.Activity
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Kanal für den Übertragungsdienst (lib/data/dateien/transfer_hintergrund_android.dart): starten, Anzeige aktualisieren, beenden.
 * Es gehen nur Zahlen über den Kanal (Anzahl, Prozent), nie Namen oder Inhalte.
 */
class TransferKanal(private val activity: Activity) {
    companion object {
        const val METHODEN = "dev.lx_labs.fampad/transfer"
    }

    fun einrichten(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODEN).setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val intent = Intent(activity, TransferService::class.java)
                        .setAction(if (call.method == "start") TransferService.ACTION_START else TransferService.ACTION_UPDATE)
                        .putExtra(TransferService.EXTRA_ANZAHL, call.argument<Number>("anzahl")?.toInt() ?: 1)
                        .putExtra(TransferService.EXTRA_PROZENT, call.argument<Number>("prozent")?.toInt() ?: 0)
                    try {
                        // ein Update ohne laufenden Dienst startet ihn nicht neu (sonst bliebe er nach dem Beenden hängen)
                        if (call.method == "start" || TransferService.laeuft) ContextCompat.startForegroundService(activity, intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "stop" -> {
                    activity.stopService(Intent(activity, TransferService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Beim endgültigen Abbau der Oberfläche (nicht bei Neuaufbau durch eine Konfigurationsänderung) gibt es nichts mehr zu übertragen. */
    fun abbauen(neuAufbau: Boolean) {
        if (!neuAufbau) activity.stopService(Intent(activity, TransferService::class.java))
    }
}
