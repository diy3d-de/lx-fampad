// Bereich "Zähler" (Abschnitt 6l): die Übersicht mit einer Kachel je Zähler oder Gruppe (letzter Stand, Verbrauch des letzten vollen Monats mit Vorjahresvergleich, Fälligkeit), der Karte
// "Ablesen fällig" und dem Knopf "Stand eintragen". Mobil eine Seite (Blatt "Mehr"), Desktop ein Bereich der Shell.
// NUR für Eltern und Admins: wer keine Rolle dafür hat, sieht hier eine neutrale Seite ohne Inhalt (auch über Erinnerung, Kachel oder Seitenleiste ist nichts erreichbar). Alles ist lokal aus
// den Ende-zu-Ende verschlüsselten Zählern berechnet; nichts davon verlässt die App (kein Push, kein Wandtablet, keine Suche).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show Role;
import '../../data/auth/auth_state.dart' show authProvider;
import '../../data/ingest/ingest_anzeige.dart';
import '../../data/ingest/ingest_state.dart';
import '../../data/zaehler/zaehler_logik.dart' show abrechnungsperiode;
import '../../data/zaehler/zaehler_repository.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show bestaetigen;
import 'ha_koppeln_screen.dart' show haKoppelnOeffnen;
import 'ha_pruefen_screen.dart';
import 'ha_verbindung_screen.dart';
import 'zaehler_anzeige.dart';
import 'zaehler_bericht_screen.dart';
import 'zaehler_editor.dart';
import 'zaehler_monat_screen.dart' show wertWort;
import 'zaehler_stand_screen.dart';
import 'zaehler_verlauf_screen.dart';

/// Öffnet den Bereich als eigene Seite (mobil); im Desktop-Layout ist er ein Bereich der Shell (siehe `zaehlerOeffnen` in zaehler_karte.dart).
Route<void> zaehlerRoute() => MaterialPageRoute<void>(builder: (_) => const ZaehlerScreen());

class ZaehlerScreen extends ConsumerWidget {
  /// Im Desktop-Layout ein Bereich der Shell: ohne eigenes Gerüst, ohne Zurück-Pfeil, mit der gemeinsamen Kopfzeile.
  final bool eingebettet;
  const ZaehlerScreen({super.key, this.eingebettet = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(zaehlerDarfProvider)) return _NichtVerfuegbar(eingebettet: eingebettet);
    final daten = ref.watch(zaehlerDatenProvider);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final heute = zaehlerHeute(jetzt);
    final faellig = faelligeReihen(daten.reihen, heute);
    final kinder = _inhalt(context, ref, daten, heute, faellig);
    final aktionen = Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: daten.reihen.where((r) => !r.archiviert).isEmpty ? () => zaehlerEditorOeffnen(context) : () => standEintragenOeffnen(context),
            icon: Icon(daten.reihen.where((r) => !r.archiviert).isEmpty ? Icons.add : Icons.edit_note),
            label: Text(daten.reihen.where((r) => !r.archiviert).isEmpty ? 'Zähler einrichten' : (daten.reihen.where((r) => !r.archiviert).every((r) => r.monatlich) ? 'Monatswert eintragen' : 'Stand eintragen')),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
        ),
        if (daten.reihen.isNotEmpty) ...[
          const SizedBox(width: 8),
          IconButton.outlined(tooltip: 'Zähler hinzufügen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: () => zaehlerEditorOeffnen(context), icon: const Icon(Icons.add)),
          const SizedBox(width: 4),
          IconButton.outlined(tooltip: 'Bericht als PDF', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: () => berichtOeffnen(context), icon: const Icon(Icons.picture_as_pdf_outlined)),
        ],
      ],
    );
    if (!eingebettet) {
      return AuthSeite(label: 'Haushalt', titel: 'Zähler', maxBreite: kMaxContentWidth, fussleiste: aktionen, kinder: kinder);
    }
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [const TabKopfzeile(title: 'Zähler'), const SizedBox(height: 16), ...kinder, const SizedBox(height: 16), aktionen],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _inhalt(BuildContext context, WidgetRef ref, ZaehlerDaten daten, DateTime heute, List<ZaehlerReihe> faellig) {
    if (!daten.geladen) return const [Padding(padding: EdgeInsets.only(top: 32), child: Center(child: CircularProgressIndicator()))];
    final haBekannt = ref.watch(ingestVerfuegbarProvider).value ?? false;
    if (daten.eintraege.isEmpty) {
      // Wer Home Assistant hat, will oft genau damit anfangen: der Einstieg steht auch ohne Zähler da (nur wenn der Server die Anbindung anbietet)
      final admin = ref.watch(authProvider.select((a) => a.user?.role)) == Role.admin;
      return [
        const SizedBox(height: 24),
        EmptyState(
          icon: Icons.speed_outlined,
          title: 'Noch keine Zähler',
          hint: haBekannt
              ? 'Trag Stände selbst ein oder lass sie von Home Assistant liefern. Strom, Wasser, Gas und Solar werden berechnet. Alle Angaben sind Ende-zu-Ende verschlüsselt und nur für Eltern und Admins sichtbar.'
              : 'Richte Strom, Wasser, Gas oder Solar ein, trage die Stände ein und lass den Verbrauch berechnen. Alle Angaben sind Ende-zu-Ende verschlüsselt und nur für Eltern und Admins sichtbar.',
        ),
        if (haBekannt)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => unawaited(admin ? haKoppelnOeffnen(context) : haVerbindungOeffnen(context)),
              icon: const Icon(Icons.sync_alt, size: 18),
              label: const Text('Mit Home Assistant verbinden'),
            ),
          ),
      ];
    }
    final zuPruefen = ref.watch(ingestProvider.select((z) => z.zuPruefen.length));
    final mischung = daten.reihen.any((r) => !r.archiviert && r.inhalt.automatisch);
    final automatischFaellig = [for (final r in faellig) if (r.inhalt.automatisch) r];
    final handFaellig = [for (final r in faellig) if (!r.inhalt.automatisch) r];
    return [
      const _IngestAnstoss(),
      if (zuPruefen > 0) ...[_PruefenKarte(anzahl: zuPruefen), const SizedBox(height: 14)],
      // die Zeile "Home Assistant" steht oben (hier meldet sie "läuft" oder "Problem"), nicht unter allen Kacheln
      if (haBekannt || mischung) ...[const _HaZeile(), const SizedBox(height: 12)],
      if (handFaellig.isNotEmpty) ...[_FaelligKarte(faellig: handFaellig, heute: heute), const SizedBox(height: 14)],
      if (automatischFaellig.isNotEmpty) ...[_KeinWertKarte(faellig: automatischFaellig, heute: heute), const SizedBox(height: 14)],
      for (final k in daten.kacheln) ...[_KachelKarte(kachel: k, heute: heute, herkunft: mischung), const SizedBox(height: 12)],
      for (final e in daten.nichtLesbar) _NichtLesbarZeile(eintrag: e),
      if (daten.archiviert.isNotEmpty) ...[
        const SizedBox(height: 8),
        const MonoLabel('Archiviert', color: kTextMuted),
        const SizedBox(height: 6),
        for (final r in daten.archiviert) _ArchivZeile(reihe: r),
      ],
    ];
  }
}

class _NichtVerfuegbar extends StatelessWidget {
  final bool eingebettet;
  const _NichtVerfuegbar({required this.eingebettet});

  @override
  Widget build(BuildContext context) {
    const inhalt = Padding(padding: EdgeInsets.all(24), child: EmptyState(icon: Icons.lock_outline, title: 'Nicht verfügbar', hint: 'Diesen Bereich gibt es für dich nicht.'));
    if (eingebettet) return const Material(type: MaterialType.transparency, child: Center(child: inhalt));
    return const AuthSeite(titel: 'Nicht verfügbar', maxBreite: kMaxContentWidth, kinder: [inhalt]);
  }
}

/// Hinweiskarte: welche Zähler gerade abgelesen werden sollen.
class _FaelligKarte extends StatelessWidget {
  final List<ZaehlerReihe> faellig;
  final DateTime heute;
  const _FaelligKarte({required this.faellig, required this.heute});

  @override
  Widget build(BuildContext context) {
    final erste = faellig.first;
    final t = reiheFaelligkeit(erste, heute).letzterTermin;
    final alleMonatlich = faellig.every((r) => r.monatlich);
    final vm = DateTime.utc(heute.year, heute.month - 1, 1);
    final titel = faellig.length == 1
        ? (erste.monatlich ? '${erste.name}: ${wertWort(erste.art)} ${monatName(vm.month)} fehlt' : '${erste.name}: Ablesen am ${t == null ? 'heute' : tagKurz(t)}')
        : '${faellig.length} Zähler warten auf ${alleMonatlich ? 'einen Monatswert' : 'eine Ablesung'}';
    return Semantics(
      container: true,
      label: 'Ablesen fällig. $titel',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kWarn.withValues(alpha: 0.08), border: Border.all(color: kWarn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            const Icon(Icons.schedule, color: kWarn),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(alleMonatlich ? 'Der Wert des Vormonats ist noch nicht eingetragen.' : 'Dein Rhythmus ist abgelaufen. Trage den aktuellen Stand ein.', style: const TextStyle(fontSize: 12, color: kTextMuted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => standEintragenOeffnen(context, reiheIds: [for (final r in faellig) r.id]), child: Text(alleMonatlich ? 'Eintragen' : 'Ablesen')),
          ],
        ),
      ),
    );
  }
}

/// Hinweiskarte für automatische Zähler (Home Assistant): seit Tagen kam kein Wert. Verlangt nie das Ablesen, denn das Problem liegt bei der Verbindung, nicht im Keller.
class _KeinWertKarte extends StatelessWidget {
  final List<ZaehlerReihe> faellig;
  final DateTime heute;
  const _KeinWertKarte({required this.faellig, required this.heute});

  @override
  Widget build(BuildContext context) {
    final erste = faellig.first;
    final tage = tageOhneWert(erste, heute);
    final titel = faellig.length == 1
        ? (tage == null ? '${erste.name}: noch kein Wert' : '${erste.name}: ${seitTagenText(tage)} kein Wert')
        : '${faellig.length} Zähler: kein Wert von Home Assistant';
    return Semantics(
      container: true,
      label: 'Kein Wert von Home Assistant. $titel',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kWarn.withValues(alpha: 0.08), border: Border.all(color: kWarn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            const Icon(Icons.sync_problem, color: kWarn),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Text('Home Assistant hat nichts geschickt, oder das Abholgerät war nicht online. Von Hand eintragen geht weiter über „Stand eintragen“.', style: TextStyle(fontSize: 12, color: kTextMuted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(haVerbindungOeffnen(context)), child: const Text('Prüfen')),
          ],
        ),
      ),
    );
  }
}

/// Eine Kachel der Übersicht.
class _KachelKarte extends StatelessWidget {
  final ZaehlerKachel kachel;
  final DateTime heute;

  /// Zeigt die Herkunft ("Home Assistant" oder "von Hand"), sobald mindestens ein Zähler automatisch geführt wird.
  final bool herkunft;
  const _KachelKarte({required this.kachel, required this.heute, this.herkunft = false});

  @override
  Widget build(BuildContext context) {
    final k = kachel;
    final farbe = zaehlerFarbe(k.art);
    final f = kachelFaelligkeit(k, heute);
    final monat = letzterVollerMonat(k, heute);
    final erzeugung = istErzeugung(k.art);
    final einheit = k.einheit;
    final r = k.erste;
    final warn = ungewoehnlichHoch(k, heute);
    final solar = erzeugung && !k.istGruppe ? solarAuswertung(r, heute) : null;
    final monatlich = !k.istGruppe && r.monatlich;
    final periode = abrechnungsperiode(heute, periodeMonat: r.inhalt.periodeMonat, periodeTag: r.inhalt.periodeTag);
    // Hauptwert: Stand (einzeln) bzw. Verbrauch des letzten vollen Monats (Gruppe), Solar die Erzeugung der laufenden Periode
    final String haupt;
    final String? unter;
    if (solar != null) {
      haupt = r.monatlich && r.monatswerte.isEmpty ? 'Noch kein Monatswert' : verbrauchAnzeige(solar.ergebnis.erzeugtMilli, einheit);
      unter = 'seit ${tagDeutsch(solar.periode.start)}';
    } else if (monatlich) {
      final bis = heute.isBefore(periode.ende) ? heute : periode.ende;
      haupt = r.monatswerte.isEmpty ? 'Noch kein Monatswert' : verbrauchAnzeige(r.kurve.verbrauch(periode.start, bis).milli, einheit);
      unter = 'seit ${tagDeutsch(periode.start)}';
    } else if (k.istGruppe) {
      haupt = monat == null ? 'Noch zu wenige Stände' : '${monatName(monat.monat)} ${verbrauchAnzeige(monat.milli, einheit)}';
      unter = '${k.reihen.length} Zähler zusammen';
    } else {
      haupt = r.letzter == null ? 'Noch kein Stand' : '${standAnzeige(r.letzter!.milli)} $einheit';
      unter = r.inhalt.nummer.isEmpty ? null : 'Zähler ${r.inhalt.nummer}';
    }
    // fällig ist bei automatischen Zählern nur "kein Wert gekommen", nie "ablesen"
    final nurAutomatischFaellig = k.reihen.where((x) => reiheFaelligkeit(x, heute).faellig).every((x) => x.inhalt.automatisch);
    final pille = switch (f.art) {
      FaelligkeitsArt.faellig => StatusPill(k.reihen.every((x) => x.monatlich) ? 'Wert fällig' : (nurAutomatischFaellig ? 'Kein Wert' : 'Ablesen fällig'), color: kWarn),
      FaelligkeitsArt.aktuell => StatusPill(k.istGruppe ? '${k.reihen.length} Zähler · aktuell' : (f.termin == null ? 'Aktuell' : 'Nächste ${tagKurz(f.termin!)}'), color: kTerminal),
      FaelligkeitsArt.keinRhythmus => StatusPill(erzeugung && !k.istGruppe ? 'Erzeugung' : 'Kein Rhythmus', color: kTextMuted),
    };
    final automatisch = k.reihen.where((r) => r.inhalt.automatisch).length;
    // die Herkunft ist nur bei automatischen Zählern eine Information; bei allen anderen wäre "von Hand" eine Pille ohne Nutzen
    final herkunftText = !herkunft || automatisch == 0 ? null : (automatisch == k.reihen.length ? 'Aus Home Assistant' : 'Gemischt');
    final monatsZeile = monat == null ? null : '${monatName(monat.monat)}: ${verbrauchAnzeige(monat.milli, einheit)}';
    final prozent = monat?.prozent;
    final semantik = StringBuffer('${k.titel}. $haupt');
    if (unter != null) semantik.write('. $unter');
    if (monat != null) semantik.write('. ${monatlich ? 'Monatswert ' : ''}${monatName(monat.monat)} ${verbrauchAnzeige(monat.milli, einheit)}${prozent == null ? '' : ', ${prozent > 0 ? 'plus' : 'minus'} ${prozent.abs().round()} Prozent zum Vorjahr'}');
    if (herkunftText != null) semantik.write(automatisch == k.reihen.length ? '. Werte aus Home Assistant' : '. Teils aus Home Assistant');
    if (f.art == FaelligkeitsArt.faellig) semantik.write(monatlich ? '. Monatswert fällig' : (nurAutomatischFaellig ? '. Kein Wert von Home Assistant' : '. Ablesen fällig'));
    if (warn) semantik.write('. Verbrauch ungewöhnlich hoch');
    semantik.write('. Öffnen für den Verlauf');
    return Semantics(
      button: true,
      label: semantik.toString(),
      excludeSemantics: true,
      child: LxCard(
        onTap: () => verlaufOeffnen(context, k.schluessel),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(zaehlerSymbol(k.art), size: 18, color: farbe),
                const SizedBox(width: 8),
                Expanded(child: Text(k.titel, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                const SizedBox(width: 8),
                Flexible(child: pille),
              ],
            ),
            if (herkunftText != null) ...[const SizedBox(height: 6), Align(alignment: Alignment.centerLeft, child: StatusPill(herkunftText, color: kAccent))],
            const SizedBox(height: 8),
            Text(haupt, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 20, fontWeight: FontWeight.w700, color: farbe)),
            if (unter != null) Text(unter, style: const TextStyle(fontSize: 12, color: kTextMuted)),
            if (solar == null && ((monatsZeile != null && !k.istGruppe) || prozent != null)) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  if (!k.istGruppe && monatsZeile != null) Text(monatsZeile, style: const TextStyle(fontSize: 13)),
                  if (prozent != null) Text('${prozentAnzeige(prozent)} zum Vorjahr', style: TextStyle(fontSize: 13, color: prozentFarbe(prozent, erzeugung: erzeugung))),
                ],
              ),
            ],
            if (solar != null) ...[
              const SizedBox(height: 4),
              if (monatsZeile != null) Text('$monatsZeile ${prozentAnzeige(prozent)}', style: TextStyle(fontSize: 13, color: prozentFarbe(prozent, erzeugung: true))),
              if (r.inhalt.kosten && (solar.ergebnis.vorteilCent > 0)) Text('Ersparnis ca. ${euroKurz(solar.ergebnis.vorteilCent)} in dieser Periode', style: const TextStyle(fontSize: 13)),
              if (solar.amortisation != null) Text('${solar.amortisation!.prozent.round()} % der Anschaffung drin', style: const TextStyle(fontSize: 13, color: kTextMuted)),
            ],
            if (k.istGruppe) ...[
              const SizedBox(height: 6),
              for (final m in k.reihen)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(shape: BoxShape.circle, color: zaehlerFarbe(m.art))),
                      Expanded(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(m.monatlich ? (m.letzterMonat == null ? '–' : '${monatKurz(m.letzterMonat!.monat)} ${verbrauchAnzeige(m.letzterMonat!.milli, m.inhalt.einheit)}') : (m.letzter == null ? '–' : '${standAnzeige(m.letzter!.milli)} ${m.inhalt.einheit}'), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted)),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => standEintragenOeffnen(context, reiheIds: [for (final m in k.zumAblesen) m.id]),
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: Text(k.art.istWasser ? 'Alle Wasserzähler ablesen' : 'Alle ablesen'),
                ),
              ),
            ],
            if (warn) ...[
              const SizedBox(height: 6),
              const Row(children: [Icon(Icons.warning_amber_rounded, size: 16, color: kWarn), SizedBox(width: 6), Expanded(child: Text('Verbrauch ungewöhnlich hoch', style: TextStyle(fontSize: 13, color: kWarn)))]),
            ],
            if (!k.istGruppe && (monatlich ? r.monatswerte.isEmpty : r.letzter == null)) Padding(padding: const EdgeInsets.only(top: 4), child: Text(monatlich ? 'Trage den ersten Monatswert ein, dann beginnt die Auswertung.' : 'Trage den ersten Stand ein, dann beginnt die Auswertung.', style: const TextStyle(fontSize: 12, color: kTextMuted))),
          ],
        ),
      ),
    );
  }
}

/// Hinweiskarte "1 Wert prüfen" (nur hier auf der Zähler-Seite, nie auf der Startseite oder in Push).
class _PruefenKarte extends StatelessWidget {
  final int anzahl;
  const _PruefenKarte({required this.anzahl});

  @override
  Widget build(BuildContext context) {
    final titel = anzahl == 1 ? '1 Wert prüfen' : '$anzahl Werte prüfen';
    return Semantics(
      container: true,
      label: '$titel. Werte aus Home Assistant warten auf deine Entscheidung.',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kWarn.withValues(alpha: 0.08), border: Border.all(color: kWarn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            const Icon(Icons.rule, color: kWarn),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Text('Aus Home Assistant, noch nicht eingetragen.', style: TextStyle(fontSize: 12, color: kTextMuted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(haPruefenOeffnen(context)), child: const Text('Prüfen')),
          ],
        ),
      ),
    );
  }
}

/// Zeile "Home Assistant" der Zähler-Seite: Einstieg in die Seite mit Schalter, Zustand und Verbindungen.
class _HaZeile extends ConsumerWidget {
  const _HaZeile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(ingestProvider);
    final daten = ref.watch(zaehlerDatenProvider);
    final letzter = letzterAutomatischerStand(daten.reihen);
    // Gerät ohne Postfach-Schlüssel (zweites Elternteil): nie "aus", die Werte kommen über ein anderes Gerät. Sonst der Zustand dieses Geräts.
    final String status;
    if (!z.geladen) {
      status = '';
    } else if (!z.postfachDa) {
      status = letzter == null ? 'läuft über ein anderes Gerät' : 'läuft über ein anderes Gerät · letzter Wert ${tagKurz(letzter.tag)}';
    } else if (!z.schalter) {
      status = 'Abholen ist aus';
    } else if (z.laeuft) {
      status = 'holt ab …';
    } else if (z.letzter?.abbruch != null) {
      status = 'Problem beim Abholen';
    } else {
      status = letzter == null ? 'läuft' : 'läuft · letzter Wert ${tagKurz(letzter.tag)}';
    }
    return LxCard(
      onTap: () => unawaited(haVerbindungOeffnen(context)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Semantics(
        button: true,
        label: 'Home Assistant. ${status.isEmpty ? '' : '$status. '}Öffnen',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              const Icon(Icons.sync_alt, color: kAccent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Home Assistant', style: TextStyle(fontWeight: FontWeight.w600)),
                    if (status.isNotEmpty) Text(status, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: kTextMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Löst beim Öffnen der Zähler-Seite einen Lauf aus (höchstens einmal je Minute; nur mit Schalter und Schlüssel, sonst tut es nichts).
class _IngestAnstoss extends ConsumerStatefulWidget {
  const _IngestAnstoss();

  @override
  ConsumerState<_IngestAnstoss> createState() => _IngestAnstossState();
}

class _IngestAnstossState extends ConsumerState<_IngestAnstoss> {
  @override
  void initState() {
    super.initState();
    unawaited(Future.microtask(() async {
      try {
        await ref.read(ingestProvider.notifier).beimOeffnen();
      } on Object {
        // ein Fehler beim Abholen stört die Seite nie
      }
    }));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _NichtLesbarZeile extends StatelessWidget {
  final ZaehlerEintrag eintrag;
  const _NichtLesbarZeile({required this.eintrag});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      container: true,
      label: 'Ein Zähler lässt sich gerade nicht lesen: ${eintrag.ansicht.hinweis ?? 'unbekannt'}',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 18, color: kTextMuted),
            const SizedBox(width: 10),
            Expanded(child: Text('Ein Zähler lässt sich gerade nicht lesen (${eintrag.ansicht.hinweis ?? 'unbekannt'}).', style: const TextStyle(color: kTextMuted, fontSize: 13))),
          ],
        ),
      ),
    ),
  );
}

class _ArchivZeile extends ConsumerWidget {
  final ZaehlerReihe reihe;
  const _ArchivZeile({required this.reihe});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: LxCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      onTap: () => verlaufOeffnen(context, 'z:${reihe.id}'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(zaehlerSymbol(reihe.art), size: 18, color: kTextMuted),
            const SizedBox(width: 10),
            Expanded(child: Text('${reihe.name} · seit ${datumTextDeutsch(reihe.inhalt.archiviertAb ?? '')} archiviert', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kTextMuted))),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                final repo = ref.read(zaehlerRepositoryProvider);
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await repo.reaktivieren(reihe.id);
                } on Object catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text(zaehlerFehlerText(e))));
                }
              },
              child: const Text('Aktivieren'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Wiederverwendbar: einen Zähler (samt Ständen) nach Bestätigung endgültig löschen. true = gelöscht. Bevorzugt wird "Archivieren" angeboten (der Aufrufer zeigt es zuerst).
Future<bool> zaehlerLoeschenMitBestaetigung(BuildContext context, WidgetRef ref, String id, String name) async {
  final ok = await bestaetigen(
    context,
    titel: 'Zähler endgültig löschen?',
    text: '„$name“ wird mit allen Ständen auf allen Geräten gelöscht. Das lässt sich nicht rückgängig machen. Besser: archivieren, dann bleiben die Stände erhalten.',
    knopf: 'Endgültig löschen',
  );
  if (!ok || !context.mounted) return false;
  try {
    await ref.read(zaehlerRepositoryProvider).loeschen(id);
    return true;
  } on Object catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(zaehlerFehlerText(e))));
    return false;
  }
}
