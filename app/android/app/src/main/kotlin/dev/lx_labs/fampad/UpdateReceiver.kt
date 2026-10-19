package dev.lx_labs.fampad

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/**
 * Empfängt das Ergebnis der PackageInstaller-Session (MainActivity.installApk). Android verlangt für die
 * Installation eine Bestätigung durch die Person (STATUS_PENDING_USER_ACTION): Der Bestätigungsdialog wird hier gestartet.
 * Erfolg (die App wird ersetzt und neu gestartet) und Fehler zeigt das System selbst an.
 */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        if (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE) !=
            PackageInstaller.STATUS_PENDING_USER_ACTION
        ) {
            return
        }
        val confirm: Intent? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
        confirm?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(it)
        }
    }

    companion object {
        const val ACTION = "dev.lx_labs.fampad.INSTALL_RESULT"
    }
}
