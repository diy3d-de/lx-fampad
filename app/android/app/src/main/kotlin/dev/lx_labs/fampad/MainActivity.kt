package dev.lx_labs.fampad

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
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
    private var standort: StandortKanal? = null

    companion object {
        /** Zuletzt von Dart gewünschter Zustand von FLAG_SECURE; als Klassenvariable, damit eine neu erstellte Activity ihn kennt. */
        private var secureWunsch = false

        /** Kanal der Terminerinnerungen (lib/data/erinnerungen/erinnerung_port_android.dart); muss dort identisch sein. */
        private const val ERINNERUNG_KANAL = "terminerinnerungen"
        private const val CHAT_KANAL = "chat_nachrichten"
        private const val PREFS = "lx_fampad_system"
        private const val PREF_ANGEFRAGT = "benachrichtigung_angefragt"
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        standort?.abbauen()
        standort = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        standort?.beiBerechtigung(requestCode)
    }

    /** Setzt FLAG_SECURE entsprechend dem zuletzt von Dart gewünschten Zustand. */
    private fun secureAnwenden() {
        if (secureWunsch) window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    /** Kopiert Text als vertraulich (EXTRA_IS_SENSITIVE, Android 13+: keine Vorschau; ältere Versionen ignorieren den Hinweis). */
    private fun geheimKopieren(text: String): Boolean {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return false
        val clip = ClipData.newPlainText("lx-familyhub", text)
        // Konstante als Text, damit der Code auch mit älteren compileSdk übersetzt (ClipDescription.EXTRA_IS_SENSITIVE ab API 33)
        clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
        clipboard.setPrimaryClip(clip)
        return true
    }

    /** Darf die App Benachrichtigungen zeigen? Berechtigung (Android 13+), Systemschalter der App und der Kanal der Erinnerungen. */
    private fun benachrichtigungenAn(): Boolean {
        if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) return false
        val kanal = (getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.getNotificationChannel(ERINNERUNG_KANAL)
        return kanal == null || kanal.importance != NotificationManager.IMPORTANCE_NONE
    }

    /**
     * Zeigt Android den Berechtigungsdialog noch? Nur ab Android 13, solange nicht dauerhaft verweigert: nie gefragt, oder die Person hat
     * einmal abgelehnt (dann liefert shouldShowRequestPermissionRationale true). Nach "Nicht mehr fragen" bzw. zweiter Ablehnung kommt
     * kein Dialog mehr, dann führt nur der Weg in die Einstellungen weiter.
     */
    private fun benachrichtigungFragbar(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val erteilt = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (erteilt) return false
        val angefragt = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(PREF_ANGEFRAGT, false)
        return !angefragt || shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
    }

    /** Wichtigkeit des Kanals der Erinnerungen (0 = aus, 4 = hoch); -1 = Kanal (noch) nicht angelegt. */
    private fun kanalWichtigkeit(): Int =
        (getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.getNotificationChannel(ERINNERUNG_KANAL)?.importance ?: -1

    /** Wichtigkeit des Kanals der Chat-Benachrichtigungen (0 = aus); -1 = Kanal (noch) nicht angelegt. Eigener Kanal: die Person kann ihn getrennt von den Erinnerungen abschalten. */
    private fun chatKanalWichtigkeit(): Int =
        (getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.getNotificationChannel(CHAT_KANAL)?.importance ?: -1

    /** Öffnet "Alarme & Erinnerungen" der App (Android 12+), Rückfall die App-Info. */
    private fun alarmEinstellungenOeffnen(): Boolean {
        val versuche = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            versuche.add(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
        }
        versuche.add(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        for (intent in versuche) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // nächster Versuch
            }
        }
        return false
    }

    /** Öffnet die Benachrichtigungseinstellungen der App, Rückfall die App-Info. Kein resolveActivity (Paketsichtbarkeit ab Android 11). */
    private fun benachrichtigungsEinstellungenOeffnen(): Boolean {
        val versuche = listOf(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")),
        )
        for (intent in versuche) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // nächster Versuch
            }
        }
        return false
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
        // Standort teilen (Vordergrunddienst, Berechtigungen, Ereignisse): StandortKanal.kt
        standort = StandortKanal(this).also { it.einrichten(flutterEngine) }
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
                    "notificationStatus" ->
                        result.success(
                            mapOf(
                                "enabled" to benachrichtigungenAn(),
                                "canAsk" to benachrichtigungFragbar(),
                                "channelImportance" to kanalWichtigkeit(),
                            ),
                        )
                    "chatChannelImportance" -> result.success(chatKanalWichtigkeit())
                    "openExactAlarmSettings" -> result.success(alarmEinstellungenOeffnen())
                    "notificationAsked" -> {
                        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(PREF_ANGEFRAGT, true).apply()
                        result.success(null)
                    }
                    "openNotificationSettings" -> result.success(benachrichtigungsEinstellungenOeffnen())
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
