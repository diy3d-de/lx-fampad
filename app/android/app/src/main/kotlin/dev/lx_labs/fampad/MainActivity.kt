package dev.lx_labs.fampad

import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Kanal für App-Updates (lib/features/update/update_service.dart): Version abfragen und die heruntergeladene,
 * bereits geprüfte APK per PackageInstaller-Session installieren (statt ACTION_VIEW mit FileProvider).
 *
 * Zweiter Kanal (lib/data/system_channel.dart): Gerätename, Bildschirmfoto-Schutz (FLAG_SECURE) für Screens mit
 * Geheimnissen und Einladungs-Links (https://familie.lx-labs.dev/#/einladung/<token>), mit denen die App geöffnet wird.
 * Das Token im Link wird nie protokolliert.
 *
 * FLAG_SECURE: Der Wunsch aus Dart wird gemerkt und in onCreate/onResume neu gesetzt (die Activity kann neu erstellt werden,
 * z. B. nach Prozess-Tod oder Konfigurationswechsel; das Fenster-Flag geht dabei verloren).
 */
class MainActivity : FlutterActivity() {
    private var systemChannel: MethodChannel? = null
    private var startLink: String? = null

    companion object {
        /** Zuletzt von Dart gewünschter Zustand von FLAG_SECURE; als Klassenvariable, damit eine neu erstellte Activity ihn kennt. */
        private var secureWunsch = false
    }

    /**
     * Start-Argumente der Dart-Seite nie aus einem Intent übernehmen: Das Argument "--unifiedpush-bg" (Hintergrund-Start ohne Oberfläche,
     * lib/data/push/push_hintergrund.dart) setzt allein das UnifiedPush-Plugin in seiner eigenen Engine. Sonst könnte eine fremde App die
     * sichtbare Oberfläche mit dem Argument starten (dann liefe nur der Abgleich, die App bliebe leer).
     */
    override fun getDartEntrypointArgs(): List<String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startLink = linkAus(intent)
        secureAnwenden()
    }

    override fun onResume() {
        super.onResume()
        secureAnwenden()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // der neue Intent ersetzt den alten (sonst liefert getIntent() später den Start-Intent)
        setIntent(intent)
        val link = linkAus(intent)
        if (link != null) systemChannel?.invokeMethod("link", link)
    }

    /** Setzt FLAG_SECURE entsprechend dem zuletzt von Dart gewünschten Zustand. */
    private fun secureAnwenden() {
        if (secureWunsch) window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    /** Kopiert Text als vertraulich (EXTRA_IS_SENSITIVE, Android 13+: keine Vorschau; ältere Versionen ignorieren den Hinweis). */
    private fun geheimKopieren(text: String): Boolean {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return false
        val clip = ClipData.newPlainText("lx-fampad", text)
        // Konstante als Text, damit der Code auch mit älteren compileSdk übersetzt (ClipDescription.EXTRA_IS_SENSITIVE ab API 33)
        clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
        clipboard.setPrimaryClip(clip)
        return true
    }

    /** Nur Links der eigenen Domain (https). Die Daten werden aus dem Intent entfernt, damit sie nicht erneut gelesen werden. */
    private fun linkAus(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        if (data.scheme != "https" || data.host != "familie.lx-labs.dev") return null
        val link = data.toString()
        intent.data = null
        return link
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        systemChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.lx_labs.fampad/system").also { kanal ->
            kanal.setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceName" -> {
                        val hersteller = Build.MANUFACTURER ?: ""
                        val modell = Build.MODEL ?: ""
                        val name = if (modell.startsWith(hersteller, ignoreCase = true)) modell else "$hersteller $modell"
                        result.success(name.trim().take(60))
                    }
                    "appVersion" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                    "initialLink" -> {
                        result.success(startLink)
                        startLink = null
                    }
                    "setSecure" -> {
                        secureWunsch = call.argument<Boolean>("secure") == true
                        secureAnwenden()
                        result.success(null)
                    }
                    "copySensitive" -> {
                        val text = call.argument<String>("text")
                        result.success(if (text == null) false else geheimKopieren(text))
                    }
                    else -> result.notImplemented()
                }
            }
        }
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
