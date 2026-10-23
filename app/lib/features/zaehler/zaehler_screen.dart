// Bereich "Zähler" (Abschnitt 6l): die Übersicht mit einer Kachel je Zähler oder Gruppe (letzter Stand, Verbrauch des letzten vollen Monats mit Vorjahresvergleich, Fälligkeit), der Karte
// "Ablesen fällig" und dem Knopf "Stand eintragen". Mobil eine Seite (Blatt "Mehr"), Desktop ein Bereich der Shell.
// NUR für Eltern und Admins: wer keine Rolle dafür hat, sieht hier eine neutrale Seite ohne Inhalt (auch über Erinnerung, Kachel oder Seitenleiste ist nichts erreichbar). Alles ist lokal aus
// den Ende-zu-Ende verschlüsselten Zählern berechnet; nichts davon verlässt die App (kein Push, kein Wandtablet, keine Suche).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/zaehler/zaehler_repository.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show bestaetigen;
import 'zaehler_anzeige.dart';
import 'zaehler_bericht_screen.dart';
import 'zaehler_editor.dart';
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
            label: Text(daten.reihen.where((r) => !r.archiviert).isEmpty ? 'Zähler einrichten' : 'Stand eintragen'),
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
      return AuthSeite(label: '// haushalt', titel: 'Zähler', maxBreite: kMaxContentWidth, fussleiste: aktionen, kinder: kinder);
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
    if (daten.eintraege.isEmpty) {
      return const [
        SizedBox(height: 24),
        EmptyState(
          icon: Icons.speed_outlined,
          title: 'Noch keine Zähler',
          hint: 'Richte Strom, Wasser, Gas oder Solar ein, trage die Stände ein und lass den Verbrauch berechnen. Alle Angaben sind Ende-zu-Ende verschlüsselt und nur für Eltern und Admins sichtbar.',
        ),
      ];
    }
    return [
      if (faellig.isNotEmpty) ...[_FaelligKarte(faellig: faellig, heute: heute), const SizedBox(height: 14)],
      for (final k in daten.kacheln) ...[_KachelKarte(kachel: k, heute: heute), const SizedBox(height: 12)],
      for (final e in daten.nichtLesbar) _NichtLesbarZeile(eintrag: e),
      if (daten.archiviert.isNotEmpty) ...[
        const SizedBox(height: 8),
        const MonoLabel('// archiviert', color: kTextMuted),
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
    final titel = faellig.length == 1 ? '${erste.name}: Ablesen am ${t == null ? 'heute' : tagKurz(t)}' : '${faellig.length} Zähler warten auf eine Ablesung';
    return Semantics(
      container: true,
      label: 'Ablesen fällig. $titel',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kWarn.withValues(alpha: 0.08), border: Border.all(color: kWarn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            const Icon(Icons.schedule, color: kWarn),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Text('Dein Rhythmus ist abgelaufen. Trage den aktuellen Stand ein.', style: TextStyle(fontSize: 12, color: kTextMuted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => standEintragenOeffnen(context, reiheIds: [for (final r in faellig) r.id]), child: const Text('Ablesen')),
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
  const _KachelKarte({required this.kachel, required this.heute});

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
    // Hauptwert: Stand (einzeln) bzw. Verbrauch des letzten vollen Monats (Gruppe), Solar die Erzeugung der laufenden Periode
    final String haupt;
    final String? unter;
    if (solar != null) {
      haupt = verbrauchAnzeige(solar.ergebnis.erzeugtMilli, einheit);
      unter = 'seit ${tagDeutsch(solar.periode.start)}';
    } else if (k.istGruppe) {
      haupt = monat == null ? 'Noch zu wenige Stände' : '${monatName(monat.monat)} ${verbrauchAnzeige(monat.milli, einheit)}';
      unter = '${k.reihen.length} Zähler zusammen';
    } else {
      haupt = r.letzter == null ? 'Noch kein Stand' : '${standAnzeige(r.letzter!.milli)} $einheit';
      unter = r.inhalt.nummer.isEmpty ? null : 'Zähler ${r.inhalt.nummer}';
    }
    final pille = switch (f.art) {
      FaelligkeitsArt.faellig => const StatusPill('ABLESEN FÄLLIG', color: kWarn),
      FaelligkeitsArt.aktuell => StatusPill(k.istGruppe ? '${k.reihen.length} ZÄHLER · AKTUELL' : (f.termin == null ? 'AKTUELL' : 'NÄCHSTE ${tagKurz(f.termin!)}'), color: kTerminal),
      FaelligkeitsArt.keinRhythmus => StatusPill(erzeugung && !k.istGruppe ? 'ERZEUGUNG' : 'KEIN RHYTHMUS', color: kTextMuted),
    };
    final monatsZeile = monat == null ? null : '${monatName(monat.monat)}: ${verbrauchAnzeige(monat.milli, einheit)}';
    final prozent = monat?.prozent;
    final semantik = StringBuffer('${k.titel}. $haupt');
    if (unter != null) semantik.write('. $unter');
    if (monat != null) semantik.write('. ${monatName(monat.monat)} ${verbrauchAnzeige(monat.milli, einheit)}${prozent == null ? '' : ', ${prozent > 0 ? 'plus' : 'minus'} ${prozent.abs().round()} Prozent zum Vorjahr'}');
    if (f.art == FaelligkeitsArt.faellig) semantik.write('. Ablesen fällig');
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
            const SizedBox(height: 8),
            Text(haupt, style: TextStyle(fontFamily: kFontMono, fontSize: 20, fontWeight: FontWeight.w700, color: farbe)),
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
                      Text(m.letzter == null ? '–' : '${standAnzeige(m.letzter!.milli)} ${m.inhalt.einheit}', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
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
            if (r.letzter == null && !k.istGruppe) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Trage den ersten Stand ein, dann beginnt die Auswertung.', style: TextStyle(fontSize: 12, color: kTextMuted))),
          ],
        ),
      ),
    );
  }
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
        decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(14)),
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
