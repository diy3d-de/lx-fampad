import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/lists/members.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../../widgets/sync_hinweise.dart';
import '../lists/list_dialogs.dart' show bestaetigen;
import 'calendar_state.dart';
import 'ics_import_screen.dart';
import 'kalender_widgets.dart';
import 'termin_editor.dart';

/// Kalender: Agenda (Standard), Monat und Woche, Filter je Person, Termine anlegen, ändern und löschen (auch Serien). Alles wirkt sofort
/// auf die lokale Datenbank; der Abgleich mit dem Server läuft im Hintergrund (data/sync/).
class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auswahl = ref.watch(kalenderAuswahlProvider);
    final daten = ref.watch(kalenderDatenProvider);
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = TerminRechte(user?.role ?? Role.child, user?.id);
    // Mitglieder (Farben, Filter) erst laden, wenn es Termine gibt
    final personen = daten.termine.isEmpty ? const <UserDto>[] : (ref.watch(mitgliederProvider).value ?? const <UserDto>[]);
    final mitglieder = Mitglieder(personen);
    final notifier = ref.read(kalenderAuswahlProvider.notifier);

    return RefreshIndicator(
      color: kAccent,
      backgroundColor: kSurface,
      onRefresh: () => ref.read(syncProvider.notifier).synchronisieren(manuell: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          const TabKopfzeile(title: 'Kalender'),
          const SizedBox(height: 12),
          const SyncHinweise(),
          AnsichtUmschalter(aktiv: auswahl.ansicht, onWahl: notifier.ansicht),
          const SizedBox(height: 12),
          PersonenFilter(personen: personen, gewaehlt: auswahl.personen, onPerson: notifier.person, onAlle: notifier.alle),
          if (personen.length >= 2) const SizedBox(height: 12),
          if (rechte.darfAnlegen)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => terminEditorOeffnen(context, tag: auswahl.ansicht == KalenderAnsicht.agenda ? null : auswahl.tag),
                  icon: const Icon(Icons.add),
                  label: const Text('Neuer Termin'),
                ),
                OutlinedButton.icon(onPressed: () => icsImportOeffnen(context), icon: const Icon(Icons.upload_file), label: const Text('Importieren')),
              ],
            ),
          const SizedBox(height: 16),
          switch (auswahl.ansicht) {
            KalenderAnsicht.agenda => _Agenda(auswahl: auswahl, daten: daten, mitglieder: mitglieder, rechte: rechte),
            KalenderAnsicht.monat => _Monat(auswahl: auswahl, daten: daten, mitglieder: mitglieder, rechte: rechte),
            KalenderAnsicht.woche => _Woche(auswahl: auswahl, daten: daten, mitglieder: mitglieder, rechte: rechte),
          },
        ],
      ),
    );
  }
}

/// Öffnet das Detailblatt eines Vorkommens und führt Bearbeiten/Löschen aus (bei Serien mit Wahl des Umfangs).
Future<void> vorkommenOeffnen(BuildContext context, WidgetRef ref, Vorkommen v, KalenderDaten daten, Mitglieder mitglieder, TerminRechte rechte) async {
  final darf = rechte.darfAendern(v.termin);
  final aktion = await terminDetailBlatt(context, v: v, mitglieder: mitglieder, teilnehmer: daten.teilnehmerIds(v.termin.id), darfAendern: darf);
  if (aktion == null || !context.mounted) return;
  final repo = ref.read(terminRepositoryProvider);
  final erstes = v.serie && repo.istErstes(v);
  switch (aktion) {
    case TerminAktion.bearbeiten:
      var umfang = SerieUmfang.alle;
      if (v.serie) {
        final u = await serieUmfangFragen(context, titel: 'Was möchtest du ändern?', erstes: erstes);
        if (u == null || !context.mounted) return;
        umfang = u;
      }
      await terminEditorOeffnen(context, v: v, umfang: umfang);
    case TerminAktion.loeschen:
      if (v.serie) {
        final u = await serieUmfangFragen(context, titel: 'Was möchtest du löschen?', erstes: erstes);
        if (u == null) return;
        switch (u) {
          case SerieUmfang.dieses:
            await repo.vorkommenAbsagen(v);
          case SerieUmfang.folgende:
            await repo.folgendeLoeschen(v);
          case SerieUmfang.alle:
            await repo.alleLoeschen(v.termin.id);
        }
      } else {
        final ja = await bestaetigen(context, titel: 'Termin „${v.titel}“ löschen?', text: 'Der Termin wird für alle gelöscht.', knopf: 'Löschen');
        if (ja) await repo.alleLoeschen(v.termin.id);
      }
  }
}

List<Vorkommen> _gefiltert(KalenderAuswahl a, KalenderDaten daten, DateTime von, DateTime bis) => [
  for (final v in vorkommenImFenster(termine: daten.termine, ausnahmen: daten.ausnahmen, vonWand: von, bisWand: bis))
    if (passtZumFilter(v, a.personen, daten)) v,
];

Widget _tagesListe(
  BuildContext context,
  WidgetRef ref,
  DateTime tag,
  List<Vorkommen> liste,
  KalenderDaten daten,
  Mitglieder mitglieder,
  TerminRechte rechte,
) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    for (final v in liste)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: VorkommenKarte(
          key: ValueKey('${v.termin.id}|${v.schluessel}|${tag.toIso8601String()}'),
          v: v,
          tag: tag,
          mitglieder: mitglieder,
          teilnehmer: daten.teilnehmerIds(v.termin.id),
          onTap: () => vorkommenOeffnen(context, ref, v, daten, mitglieder, rechte),
        ),
      ),
  ],
);

// ------------------------------------------------------------------------------------------------ Agenda

class _Agenda extends ConsumerWidget {
  final KalenderAuswahl auswahl;
  final KalenderDaten daten;
  final Mitglieder mitglieder;
  final TerminRechte rechte;
  const _Agenda({required this.auswahl, required this.daten, required this.mitglieder, required this.rechte});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final heute = heuteTag();
    final bis = heute.add(Duration(days: auswahl.agendaTage));
    final tage = nachTagen(_gefiltert(auswahl, daten, heute, bis), heute, bis.subtract(const Duration(days: 1)));
    final schluessel = tage.keys.toList()..sort();
    if (schluessel.isEmpty) {
      return Column(
        children: [
          const EmptyState(icon: Icons.event_available_outlined, title: 'Keine Termine', hint: 'In den nächsten Wochen steht nichts an.'),
          _MehrKnopf(auswahl: auswahl),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final tag in schluessel) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: MonoLabel(tag == heute ? '${tagesLabel(tag)} · heute' : tagesLabel(tag), color: tag == heute ? kAccent : kTextMuted),
          ),
          _tagesListe(context, ref, tag, tage[tag]!, daten, mitglieder, rechte),
        ],
        _MehrKnopf(auswahl: auswahl),
      ],
    );
  }
}

class _MehrKnopf extends ConsumerWidget {
  final KalenderAuswahl auswahl;
  const _MehrKnopf({required this.auswahl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (auswahl.agendaTage >= kHorizontJahre * 365) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton(onPressed: ref.read(kalenderAuswahlProvider.notifier).mehrTage, child: const Text('Weitere Tage anzeigen')),
    );
  }
}

// ------------------------------------------------------------------------------------------------ Monat

class _Monat extends ConsumerWidget {
  final KalenderAuswahl auswahl;
  final KalenderDaten daten;
  final Mitglieder mitglieder;
  final TerminRechte rechte;
  const _Monat({required this.auswahl, required this.daten, required this.mitglieder, required this.rechte});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(kalenderAuswahlProvider.notifier);
    final heute = heuteTag();
    final monat = DateTime.utc(auswahl.tag.year, auswahl.tag.month);
    final naechster = DateTime.utc(monat.year, monat.month + 1);
    final tageImMonat = naechster.difference(monat).inDays;
    final versatz = (monat.weekday - 1) % 7; // Montag = 0
    final zellen = ((versatz + tageImMonat) / 7).ceil() * 7;
    final tage = nachTagen(_gefiltert(auswahl, daten, monat, naechster), monat, naechster.subtract(const Duration(days: 1)));
    final monatsname = DateFormat('MMMM yyyy', 'de_DE').format(monat);
    void verschiebe(int m) {
      final ziel = DateTime.utc(monat.year, monat.month + m);
      notifier.tag(ziel);
    }

    final gewaehlt = tage[auswahl.tag] ?? const <Vorkommen>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(tooltip: 'Vorheriger Monat', onPressed: () => verschiebe(-1), icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(monatsname, textAlign: TextAlign.center, style: const TextStyle(fontFamily: kFontMono, fontSize: 13, color: kTextMuted)),
              ),
            ),
            IconButton(tooltip: 'Nächster Monat', onPressed: () => verschiebe(1), icon: const Icon(Icons.chevron_right)),
          ],
        ),
        Row(
          children: [
            for (final t in const ['mo', 'di', 'mi', 'do', 'fr', 'sa', 'so'])
              Expanded(child: Center(child: Text(t, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextFaint)))),
          ],
        ),
        const SizedBox(height: 6),
        GridView(
          // feste Höhe: Zellen 48 px hoch (Touch-Ziel), bei 360 px Breite 46 px breit
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, mainAxisSpacing: 4, crossAxisSpacing: 0, mainAxisExtent: 48),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < zellen; i++)
              _zelle(i - versatz + 1, tageImMonat, monat, heute, auswahl.tag, tage, mitglieder, notifier.tag),
          ],
        ),
        const SizedBox(height: 16),
        MonoLabel(tagesLabel(auswahl.tag)),
        const SizedBox(height: 12),
        if (gewaehlt.isEmpty)
          const LxCard(child: Text('Keine Termine – frei!', style: TextStyle(color: kTextMuted)))
        else
          _tagesListe(context, ref, auswahl.tag, gewaehlt, daten, mitglieder, rechte),
      ],
    );
  }

  Widget _zelle(int n, int tageImMonat, DateTime monat, DateTime heute, DateTime gewaehlt, Map<DateTime, List<Vorkommen>> tage, Mitglieder mitglieder, void Function(DateTime) onTag) {
    if (n < 1 || n > tageImMonat) return const SizedBox.shrink();
    final tag = DateTime.utc(monat.year, monat.month, n);
    final liste = tage[tag] ?? const <Vorkommen>[];
    final farben = <Color>{for (final v in liste) terminFarbe(v, mitglieder)}.take(3).toList();
    return _Tag(nummer: n, heute: tag == heute, gewaehlt: tag == gewaehlt, anzahl: liste.length, farben: farben, onTap: () => onTag(tag));
  }
}

class _Tag extends StatelessWidget {
  final int nummer;
  final bool heute;
  final bool gewaehlt;
  final int anzahl;
  final List<Color> farben;
  final VoidCallback onTap;
  const _Tag({required this.nummer, required this.heute, required this.gewaehlt, required this.anzahl, required this.farben, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: gewaehlt,
    label: anzahl == 0 ? '$nummer' : '$nummer, ${anzahl == 1 ? '1 Termin' : '$anzahl Termine'}',
    excludeSemantics: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: gewaehlt ? kAccentSoft : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: heute ? kAccent : (gewaehlt ? kAccent.withValues(alpha: 0.4) : Colors.transparent)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$nummer', style: TextStyle(fontWeight: gewaehlt ? FontWeight.w700 : FontWeight.w500, color: gewaehlt ? kAccent : kText)),
            SizedBox(
              height: 6,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [for (final f in farben) Container(width: 5, height: 5, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: BoxDecoration(shape: BoxShape.circle, color: f))],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------------------------------------ Woche

class _Woche extends ConsumerWidget {
  final KalenderAuswahl auswahl;
  final KalenderDaten daten;
  final Mitglieder mitglieder;
  final TerminRechte rechte;
  const _Woche({required this.auswahl, required this.daten, required this.mitglieder, required this.rechte});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(kalenderAuswahlProvider.notifier);
    final heute = heuteTag();
    final montag = auswahl.tag.subtract(Duration(days: auswahl.tag.weekday - 1));
    final naechster = montag.add(const Duration(days: 7));
    final tage = nachTagen(_gefiltert(auswahl, daten, montag, naechster), montag, naechster.subtract(const Duration(days: 1)));
    final kopf = '${DateFormat('d. MMM', 'de_DE').format(montag)} – ${DateFormat('d. MMM y', 'de_DE').format(naechster.subtract(const Duration(days: 1)))}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(tooltip: 'Vorherige Woche', onPressed: () => notifier.tag(montag.subtract(const Duration(days: 7))), icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(kopf, textAlign: TextAlign.center, style: const TextStyle(fontFamily: kFontMono, fontSize: 13, color: kTextMuted)),
              ),
            ),
            IconButton(tooltip: 'Nächste Woche', onPressed: () => notifier.tag(naechster), icon: const Icon(Icons.chevron_right)),
          ],
        ),
        TextButton(onPressed: () => notifier.tag(heute), child: const Text('Heute')),
        for (var i = 0; i < 7; i++) ...[
          Builder(
            builder: (context) {
              final tag = montag.add(Duration(days: i));
              final liste = tage[tag] ?? const <Vorkommen>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    child: MonoLabel(tag == heute ? '${tagesLabel(tag)} · heute' : tagesLabel(tag), color: tag == heute ? kAccent : kTextMuted),
                  ),
                  if (liste.isEmpty) const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('frei', style: TextStyle(color: kTextFaint))) else _tagesListe(context, ref, tag, liste, daten, mitglieder, rechte),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}
