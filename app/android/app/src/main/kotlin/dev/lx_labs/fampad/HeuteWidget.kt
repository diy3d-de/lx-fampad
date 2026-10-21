package dev.lx_labs.fampad

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.TypefaceSpan
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

/**
 * Startbildschirm-Widget "Heute": zeigt die heutigen Termine, fällige Aufgaben und auf Wunsch die offenen Einträge einer Liste.
 *
 * Datenquelle ist allein die Anzeige-Zusammenfassung, die die Dart-Seite in den app-privaten Speicher schreibt ([HeuteSpeicher], SharedPreferences
 * im privaten Verzeichnis der App, für andere Apps nicht lesbar). Das Widget fragt nie das Netz und greift nie auf die Datenbank der App zu.
 * Aktualisierung: bei Änderungen der Zusammenfassung (HeuteKanal), beim Tageswechsel, bei Zeit-/Zeitzonenänderung und alle 30 Minuten (das Minimum
 * des Systems, kein Wecker).
 *
 * Sicherheit: Der Empfänger ist exportiert, weil Android ihn für Widgets so verlangt; er reagiert nur auf Systemmeldungen (APPWIDGET_UPDATE und
 * geschützte Zeit-Meldungen, die nur das System senden kann) und liest keine Daten aus Intents. Tippen öffnet die App über ein PendingIntent mit
 * FLAG_IMMUTABLE und ausdrücklichem Ziel ([MainActivity]); das Ziel ("kalender", "aufgaben", "listen") ist eine feste Liste.
 */
class HeuteWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        HeuteAnzeige.zeichnen(context, appWidgetManager, appWidgetIds)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            Intent.ACTION_DATE_CHANGED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_LOCALE_CHANGED -> HeuteAnzeige.alleAktualisieren(context)
        }
    }
}

/** App-privater Speicher der Zusammenfassung. */
object HeuteSpeicher {
    private const val PREFS = "lx_fampad_heute"
    private const val KEY = "zusammenfassung"
    private const val MAX_ZEICHEN = 64 * 1024

    /** Schreibt die Zusammenfassung, wenn sie die erwartete Form hat (Version 1, gültiges JSON, höchstens 64 KB). */
    fun schreiben(context: Context, json: String): Boolean {
        if (json.length > MAX_ZEICHEN) return false
        try {
            val o = JSONObject(json)
            if (o.optInt("v", 0) != 1) return false
        } catch (_: Exception) {
            return false
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json).apply()
        return true
    }

    fun lesen(context: Context): JSONObject? {
        val s = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return null
        return try {
            JSONObject(s)
        } catch (_: Exception) {
            null
        }
    }

    fun loeschen(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).apply()
    }
}

/** Zeichnet das Widget aus der Zusammenfassung (RemoteViews, Farben aus den Ressourcen, die den Design-Tokens der App entsprechen). */
object HeuteAnzeige {
    /** Familienzeitzone (wie die App: Europe/Berlin). */
    private val ZONE = ZoneId.of("Europe/Berlin")
    private const val MAX_TERMINE = 5
    private const val MAX_AUFGABEN = 5
    private const val MAX_EINKAUF = 3

    private val TERMIN_ZEILEN = intArrayOf(R.id.heute_t1, R.id.heute_t2, R.id.heute_t3, R.id.heute_t4, R.id.heute_t5)
    private val AUFGABEN_ZEILEN = intArrayOf(R.id.heute_a1, R.id.heute_a2, R.id.heute_a3, R.id.heute_a4, R.id.heute_a5)
    private val EINKAUF_ZEILEN = intArrayOf(R.id.heute_e1, R.id.heute_e2, R.id.heute_e3)

    fun alleAktualisieren(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, HeuteWidget::class.java))
        if (ids.isNotEmpty()) zeichnen(context, manager, ids)
    }

    fun zeichnen(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val heute = LocalDate.now(ZONE)
        val daten = HeuteSpeicher.lesen(context)
        for (id in ids) manager.updateAppWidget(id, ansicht(context, heute, daten))
    }

    private fun farbe(context: Context, res: Int) = ContextCompat.getColor(context, res)

    private fun zeile(context: Context, zeit: String, text: String, textFarbe: Int): CharSequence {
        val b = SpannableStringBuilder()
        if (zeit.isNotEmpty()) {
            b.append(zeit).append("  ")
            b.setSpan(ForegroundColorSpan(farbe(context, R.color.lx_text_muted)), 0, zeit.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            b.setSpan(TypefaceSpan("monospace"), 0, zeit.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val start = b.length
        b.append(text)
        b.setSpan(ForegroundColorSpan(textFarbe), start, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return b
    }

    private fun ziel(context: Context, ziel: String, code: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(MainActivity.ACTION_WIDGET)
            .putExtra(MainActivity.EXTRA_ZIEL, ziel)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun ansicht(context: Context, heute: LocalDate, daten: JSONObject?): RemoteViews {
        val v = RemoteViews(context.packageName, R.layout.widget_heute)
        val wochentag = heute.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.GERMANY).trimEnd('.')
        val monat = heute.month.getDisplayName(TextStyle.SHORT, Locale.GERMANY).trimEnd('.')
        v.setTextViewText(R.id.heute_datum, "$wochentag, ${heute.dayOfMonth}. $monat")
        v.setOnClickPendingIntent(R.id.heute_wurzel, ziel(context, "kalender", 0))
        v.setOnClickPendingIntent(R.id.heute_block_termine, ziel(context, "kalender", 1))
        v.setOnClickPendingIntent(R.id.heute_block_aufgaben, ziel(context, "aufgaben", 2))
        v.setOnClickPendingIntent(R.id.heute_block_einkauf, ziel(context, "listen", 3))
        val text = farbe(context, R.color.lx_text)
        if (daten == null) {
            // noch keine Zusammenfassung (frisch hinzugefügt, abgemeldet): nur ein Hinweis
            v.setViewVisibility(R.id.heute_block_aufgaben, View.GONE)
            v.setViewVisibility(R.id.heute_block_einkauf, View.GONE)
            for (r in TERMIN_ZEILEN) v.setViewVisibility(r, View.GONE)
            v.setViewVisibility(R.id.heute_t_mehr, View.GONE)
            v.setViewVisibility(R.id.heute_t_leer, View.VISIBLE)
            v.setTextViewText(R.id.heute_t_leer, context.getString(R.string.widget_heute_oeffnen))
            return v
        }
        v.setViewVisibility(R.id.heute_block_aufgaben, View.VISIBLE)

        // Termine des heutigen Tages (die Zusammenfassung enthält heute und die Folgetage; welcher Tag heute ist, entscheidet das Widget)
        val tag = heute.toString()
        var termine: JSONArray? = null
        var tagGefunden = false
        val tage = daten.optJSONArray("tage")
        if (tage != null) {
            for (i in 0 until tage.length()) {
                val t = tage.optJSONObject(i) ?: continue
                if (t.optString("d") == tag) {
                    termine = t.optJSONArray("t")
                    tagGefunden = true
                }
            }
        }
        if (!tagGefunden) {
            // die Zusammenfassung ist älter als drei Tage: lieber ehrlich "veraltet" als "keine Termine"
            v.setViewVisibility(R.id.heute_block_aufgaben, View.GONE)
            v.setViewVisibility(R.id.heute_block_einkauf, View.GONE)
            for (r in TERMIN_ZEILEN) v.setViewVisibility(r, View.GONE)
            v.setViewVisibility(R.id.heute_t_mehr, View.GONE)
            v.setViewVisibility(R.id.heute_t_leer, View.VISIBLE)
            v.setTextViewText(R.id.heute_t_leer, context.getString(R.string.widget_heute_veraltet))
            return v
        }
        val anzahl = termine?.length() ?: 0
        for (i in TERMIN_ZEILEN.indices) {
            val o = if (i < anzahl && i < MAX_TERMINE) termine?.optJSONObject(i) else null
            if (o == null) {
                v.setViewVisibility(TERMIN_ZEILEN[i], View.GONE)
            } else {
                v.setViewVisibility(TERMIN_ZEILEN[i], View.VISIBLE)
                v.setTextViewText(TERMIN_ZEILEN[i], zeile(context, o.optString("z"), o.optString("x"), text))
            }
        }
        v.setViewVisibility(R.id.heute_t_leer, if (anzahl == 0) View.VISIBLE else View.GONE)
        if (anzahl == 0) v.setTextViewText(R.id.heute_t_leer, context.getString(R.string.widget_heute_keine_termine))
        v.setViewVisibility(R.id.heute_t_mehr, if (anzahl > MAX_TERMINE) View.VISIBLE else View.GONE)
        if (anzahl > MAX_TERMINE) v.setTextViewText(R.id.heute_t_mehr, "+ ${anzahl - MAX_TERMINE} weitere")

        // fällige Aufgaben: Fälligkeitstag bis heute (überfällige rot)
        val faellig = ArrayList<Pair<String, String>>()
        val aufgaben = daten.optJSONArray("aufgaben")
        if (aufgaben != null) {
            for (i in 0 until aufgaben.length()) {
                val a = aufgaben.optJSONObject(i) ?: continue
                val f = a.optString("f")
                if (f.isNotEmpty() && f <= tag) faellig.add(Pair(f, a.optString("x")))
            }
        }
        for (i in AUFGABEN_ZEILEN.indices) {
            if (i < faellig.size && i < MAX_AUFGABEN) {
                val (f, x) = faellig[i]
                v.setViewVisibility(AUFGABEN_ZEILEN[i], View.VISIBLE)
                val ueberfaellig = f < tag
                v.setTextViewText(AUFGABEN_ZEILEN[i], zeile(context, if (ueberfaellig) "!" else "", x, if (ueberfaellig) farbe(context, R.color.lx_danger) else text))
            } else {
                v.setViewVisibility(AUFGABEN_ZEILEN[i], View.GONE)
            }
        }
        v.setViewVisibility(R.id.heute_a_leer, if (faellig.isEmpty()) View.VISIBLE else View.GONE)
        v.setViewVisibility(R.id.heute_a_mehr, if (faellig.size > MAX_AUFGABEN) View.VISIBLE else View.GONE)
        if (faellig.size > MAX_AUFGABEN) v.setTextViewText(R.id.heute_a_mehr, "+ ${faellig.size - MAX_AUFGABEN} weitere")

        // Liste (nur wenn in der App gewählt)
        val einkauf = daten.optJSONObject("einkauf")
        if (einkauf == null) {
            v.setViewVisibility(R.id.heute_block_einkauf, View.GONE)
        } else {
            v.setViewVisibility(R.id.heute_block_einkauf, View.VISIBLE)
            val offen = einkauf.optInt("a", 0)
            v.setTextViewText(R.id.heute_einkauf_kopf, "${einkauf.optString("n")} · $offen offen".uppercase(Locale.GERMANY))
            val eintraege = einkauf.optJSONArray("e")
            for (i in EINKAUF_ZEILEN.indices) {
                val e = if (eintraege != null && i < eintraege.length() && i < MAX_EINKAUF) eintraege.optString(i) else null
                if (e == null) {
                    v.setViewVisibility(EINKAUF_ZEILEN[i], View.GONE)
                } else {
                    v.setViewVisibility(EINKAUF_ZEILEN[i], View.VISIBLE)
                    v.setTextViewText(EINKAUF_ZEILEN[i], zeile(context, "", e, text))
                }
            }
            v.setViewVisibility(R.id.heute_e_mehr, if (offen > MAX_EINKAUF) View.VISIBLE else View.GONE)
            if (offen > MAX_EINKAUF) v.setTextViewText(R.id.heute_e_mehr, "+ ${offen - MAX_EINKAUF} weitere")
        }
        return v
    }
}

/**
 * Kanal zur Dart-Seite (lib/data/heute_widget/heute_widget_port.dart): Zusammenfassung schreiben und löschen, Ziel eines Tipps auf das Widget melden.
 */
class HeuteKanal(private val context: Context) {
    companion object {
        const val NAME = "dev.lx_labs.fampad/heute"
    }

    private var kanal: MethodChannel? = null

    /** Ziel, mit dem die App gestartet wurde (einmalig abgeholt). */
    var startZiel: String? = null

    fun einrichten(engine: FlutterEngine) {
        kanal = MethodChannel(engine.dartExecutor.binaryMessenger, NAME).also { k ->
            k.setMethodCallHandler { call, result ->
                when (call.method) {
                    "aktualisieren" -> {
                        val json = call.argument<String>("json")
                        val ok = json != null && HeuteSpeicher.schreiben(context, json)
                        if (ok) HeuteAnzeige.alleAktualisieren(context)
                        result.success(ok)
                    }
                    "loeschen" -> {
                        HeuteSpeicher.loeschen(context)
                        HeuteAnzeige.alleAktualisieren(context)
                        result.success(null)
                    }
                    "startZiel" -> {
                        result.success(startZiel)
                        startZiel = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** Ein Tipp auf das Widget, während die App läuft. */
    fun zielMelden(ziel: String) {
        kanal?.invokeMethod("ziel", ziel)
    }
}
