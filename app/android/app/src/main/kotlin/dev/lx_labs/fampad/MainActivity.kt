package dev.lx_labs.fampad

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Kanal für App-Updates (lib/features/update/update_service.dart): Version abfragen und die heruntergeladene,
 * bereits geprüfte APK per PackageInstaller-Session installieren (statt ACTION_VIEW mit FileProvider).
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.lx_labs.fampad/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "appVersion" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                    "appVersionCode" -> result.success(packageManager.getPackageInfo(packageName, 0).longVersionCode)
                    "installApk" -> installApk(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        val updates = File(cacheDir, "updates").canonicalFile
        val file = path?.let { File(it).canonicalFile }
        // Nur die eigene, geprüfte Download-Datei installieren
        if (file == null || file.parentFile != updates || !file.isFile) {
            result.error("INVALID", "Ungültige Update-Datei", null)
            return
        }
        if (!packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            result.success("permission")
            return
        }

        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        // Die Session darf nur ein Update dieser App installieren; Android prüft zusätzlich den Signaturschlüssel.
        params.setAppPackageName(packageName)
        var sessionId = -1
        try {
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("update.apk", 0, file.length()).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
                // Ergebnis geht an UpdateReceiver (nicht exportiert); der Intent ist ausdrücklich an diese Klasse gerichtet.
                val intent = Intent(this, UpdateReceiver::class.java).setAction(UpdateReceiver.ACTION)
                var flags = PendingIntent.FLAG_UPDATE_CURRENT
                // Der Installer ergänzt Extras (Status, Bestätigungs-Intent): ab Android 12 muss das PendingIntent veränderbar sein
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
                val pending = PendingIntent.getBroadcast(this, sessionId, intent, flags)
                session.commit(pending.intentSender)
            }
            result.success("ok")
        } catch (e: Exception) {
            if (sessionId != -1) {
                try {
                    installer.abandonSession(sessionId)
                } catch (_: Exception) {
                    // Session schon beendet
                }
            }
            result.error("INSTALL_FAILED", e.message, null)
        }
    }
}
