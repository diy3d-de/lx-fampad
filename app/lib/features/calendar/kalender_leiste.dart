// Leiste des Kalenders: Monat/Woche mit Pfeilen und Wahl, "Heute", Filter und Anzeige (mobil als Bottom-Sheet, Desktop als Chips und Menü),
// "Mehr" mit "Kalender-Einstellungen …" (Import und Export liegen dort), der Umschalter Agenda | Monat | Woche. Alles, was früher als Knöpfe über dem Kalender lag.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/calendar/feiertage.dart';
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/monat_layout.dart';
import '../../data/calendar/termin_farben.dart';
import '../../data/calendar/termin_repository.dart' show kalenderDatenProvider;
import '../../data/lists/members.dart';
import '../../data/muell/muell_state.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart' show ProfilButton;
import '../../widgets/sync_anzeige.dart';
import 'calendar_state.dart';
import '../profile/kalender_einstellungen_screen.dart';
import 'kalender_widgets.dart';
import 'termin_editor.dart';

/// Anzahl aktiver Filter: gewählte Personen, ausgeschaltete Anzeigen (Feiertage, Schulferien, Geburtstage) und ein aktiver Farbfilter (zählt als einer).
int aktiveFilter(KalenderAuswahl a, {required bool feiertage, required bool ferien, required bool geburtstage, int farbenAus = 0}) =>
    a.personen.length + (feiertage ? 0 : 1) + (ferien ? 0 : 1) + (geburtstage ? 0 : 1) + (farbenAus > 0 ? 1 : 0);

/// Titel der Leiste: Monat und Jahr, Kalenderwoche (mobil "KW 43 · Okt 2026", Desktop "KW 43 · 19.–25. Oktober 2026"), "Agenda".
({String haupt, String? unter}) kalenderTitel(KalenderAuswahl a, {required bool breit}) {
  switch (a.ansicht) {
    case KalenderAnsicht.agenda:
      return (haupt: 'Agenda', unter: null);
    case KalenderAnsicht.monat:
      return (haupt: DateFormat('MMMM y', 'de_DE').format(a.monat), unter: null);
    case KalenderAnsicht.woche:
      final montag = a.tag.subtract(Duration(days: a.tag.weekday - 1));
      final sonntag = montag.add(const Duration(days: 6));
      final kw = 'KW ${kalenderwoche(montag)}';
      if (!breit) {
        // Monat und Jahr der ISO-Woche (Donnerstag)
        final donnerstag = montag.add(const Duration(days: 3));
        return (haupt: '$kw · ${DateFormat('MMM y', 'de_DE').format(donnerstag).replaceAll('.', '')}', unter: null);
      }
      final voll = DateFormat('d. MMMM y', 'de_DE');
      final text = montag.year != sonntag.year
          ? '${voll.format(montag)} – ${voll.format(sonntag)}'
          : montag.month != sonntag.month
          ? '${DateFormat('d. MMMM', 'de_DE').format(montag)} – ${voll.format(sonntag)}'
          : '${montag.day}.–${voll.format(sonntag)}';
      return (haupt: '$kw · $text', unter: null);
  }
}

/// Schmale Symbolknöpfe der mobilen Leiste (44 px statt 48), damit der Titel Platz behält.
final _kompakt = IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap, minimumSize: const Size(44, 44), padding: EdgeInsets.zero);

class KalenderLeiste extends ConsumerWidget {
  final bool breit;
  final List<UserDto> personen;
  final bool darfAnlegen;
  final VoidCallback onNeu;
  const KalenderLeiste({super.key, required this.breit, required this.personen, required this.darfAnlegen, required this.onNeu});

  void _verschiebe(WidgetRef ref, KalenderAuswahl a, int richtung) {
    final n = ref.read(kalenderAuswahlProvider.notifier);
    if (a.ansicht == KalenderAnsicht.monat) {
      n.tag(DateTime.utc(a.monat.year, a.monat.month + richtung));
    } else {
      n.tag(a.tag.add(Duration(days: 7 * richtung)));
    }
  }

  Future<void> _datumWaehlen(BuildContext context, WidgetRef ref, KalenderAuswahl a) async {
    final d = await showDatePicker(
      context: context,
      useRootNavigator: false,
      initialDate: a.ansicht == KalenderAnsicht.monat ? a.monat : a.tag,
      firstDate: DateTime.utc(2000),
      lastDate: DateTime.utc(2100, 12, 31),
      helpText: a.ansicht == KalenderAnsicht.monat ? 'Monat wählen' : 'Woche wählen',
    );
    if (d != null) ref.read(kalenderAuswahlProvider.notifier).tag(d);
  }

  /// Manueller Abgleich (wie der Sync-Indikator der Kopfzeile) mit kurzer Rückmeldung.
  Future<void> _abgleichen(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(syncProvider.notifier).synchronisieren(manuell: true);
    if (!context.mounted) return;
    final s = ref.read(syncProvider);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(s.status == SyncStatus.synchron ? 'Abgeglichen' : (s.meldung ?? 'Der Abgleich ist nicht möglich: ${syncAnzeige(s).$1}.'))));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(kalenderAuswahlProvider);
    final feiertage = ref.watch(feiertageAnzeigenProvider);
    final ferien = ref.watch(ferienAnzeigenProvider);
    final geburtstage = ref.watch(geburtstageAnzeigenProvider);
    final aktiv = aktiveFilter(a, feiertage: feiertage, ferien: ferien, geburtstage: geburtstage, farbenAus: ref.watch(farbenAusProvider).length);
    final nav = a.ansicht != KalenderAnsicht.agenda;
    // Mobil: ist die Kopfzeile eingeklappt, bleiben Profil und Sync-Zustand hier erreichbar
    final profil = !breit && ref.watch(kalenderKopfEingeklapptProvider);
    final einheit = a.ansicht == KalenderAnsicht.monat ? 'Monat' : 'Woche';
    final titel = kalenderTitel(a, breit: breit);
    final zurueck = a.ansicht == KalenderAnsicht.monat ? 'Vorheriger Monat' : 'Vorherige Woche';
    final weiter = a.ansicht == KalenderAnsicht.monat ? 'Nächster Monat' : 'Nächste Woche';
    final menue = PopupMenuButton<String>(
      style: _kompakt,
      padding: EdgeInsets.zero,
      tooltip: 'Mehr',
      icon: const Icon(Icons.more_vert),
      onSelected: (w) {
        if (w == 'einstellungen') kalenderEinstellungenOeffnen(context);
        if (w == 'heute') ref.read(kalenderAuswahlProvider.notifier).tag(heuteTag());
        if (w == 'sync') _abgleichen(context, ref);
      },
      itemBuilder: (_) => [
        // eingeklappte Kopfzeile: Heute und der Abgleich (sonst in Leiste bzw. Kopfzeile) liegen hier, damit der Titel Platz behält
        if (profil && nav) const PopupMenuItem(value: 'heute', child: Text('Heute')),
        if (profil) PopupMenuItem(value: 'sync', child: Text('Jetzt abgleichen (${syncAnzeige(ref.read(syncProvider)).$1})')),
        const PopupMenuItem(value: 'einstellungen', child: Text('Kalender-Einstellungen …')),
      ],
    );
    final titelWidget = _TitelKnopf(titel: titel, breit: breit, onTap: nav ? () => _datumWaehlen(context, ref, a) : null, semantik: nav ? '$einheit wählen: ${titel.haupt}' : 'Agenda');

    if (!breit) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 6, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (nav) IconButton(style: _kompakt, tooltip: zurueck, onPressed: () => _verschiebe(ref, a, -1), icon: const Icon(Icons.chevron_left)),
                Expanded(child: Padding(padding: EdgeInsets.only(left: nav ? 0 : 12), child: titelWidget)),
                if (nav) IconButton(style: _kompakt, tooltip: weiter, onPressed: () => _verschiebe(ref, a, 1), icon: const Icon(Icons.chevron_right)),
                if (nav && !profil)
                  Tooltip(
                    message: 'Heute',
                    child: Semantics(
                      button: true,
                      label: 'Heute',
                      excludeSemantics: true,
                      onTap: () => ref.read(kalenderAuswahlProvider.notifier).tag(heuteTag()),
                      child: InkResponse(
                        radius: 24,
                        onTap: () => ref.read(kalenderAuswahlProvider.notifier).tag(heuteTag()),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Center(child: Text('${heuteTag().day}', style: const TextStyle(fontFamily: kFontMono, fontSize: 13, fontWeight: FontWeight.w600, color: kAccent))),
                        ),
                      ),
                    ),
                  ),
                IconButton(
                  style: _kompakt,
                  tooltip: aktiv == 0 ? 'Filter und Anzeige' : 'Filter und Anzeige, $aktiv aktiv',
                  onPressed: () => kalenderFilterBlattOeffnen(context),
                  icon: Badge(
                    isLabelVisible: aktiv > 0,
                    label: Text('$aktiv'),
                    backgroundColor: kAccent,
                    textColor: kOnAccent,
                    child: const Icon(Icons.filter_list),
                  ),
                ),
                menue,
                if (profil) const _ProfilMitSync(),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 2, 4),
              child: AnsichtUmschalter(aktiv: a.ansicht, onWahl: (x) => _ansicht(ref, x)),
            ),
          ],
        ),
      );
    }

    // Desktop: alles in einer Zeile (bei wenig Platz umbrechend)
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (nav) _RahmenKnopf(tooltip: zurueck, icon: Icons.chevron_left, onTap: () => _verschiebe(ref, a, -1)),
            Flexible(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: titelWidget)),
            if (nav) _RahmenKnopf(tooltip: weiter, icon: Icons.chevron_right, onTap: () => _verschiebe(ref, a, 1)),
            if (nav)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: OutlinedButton(onPressed: () => ref.read(kalenderAuswahlProvider.notifier).tag(heuteTag()), child: const Text('Heute')),
              ),
          ],
        ),
        AnsichtUmschalter(aktiv: a.ansicht, breit: true, onWahl: (x) => _ansicht(ref, x)),
        PersonenFilter(personen: personen, gewaehlt: a.personen, onPerson: ref.read(kalenderAuswahlProvider.notifier).person, onAlle: ref.read(kalenderAuswahlProvider.notifier).alle),
        _AnzeigeMenue(aktiv: aktiv),
        OutlinedButton.icon(
          onPressed: () => kalenderEinstellungenOeffnen(context),
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Kalender-Einstellungen …'),
        ),
        if (darfAnlegen) FilledButton.icon(onPressed: onNeu, icon: const Icon(Icons.add, size: 18), label: const Text('Neuer Termin')),
      ],
    );
  }

  void _ansicht(WidgetRef ref, KalenderAnsicht x) {
    unawaited(ref.read(kalenderAuswahlProvider.notifier).ansichtMerken(x));
    ref.read(kalenderKopfEingeklapptProvider.notifier).setzen(false);
  }
}

/// Profil-Knopf mit kleinem Punkt für den Sync-Zustand (nur bei eingeklappter Kopfzeile, mobil).
class _ProfilMitSync extends ConsumerWidget {
  const _ProfilMitSync();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (text, farbe) = syncAnzeige(ref.watch(syncProvider));
    return Stack(
      alignment: Alignment.center,
      children: [
        const ProfilButton(),
        Positioned(
          right: 6,
          bottom: 6,
          child: IgnorePointer(
            child: Semantics(
              label: 'Sync: $text',
              child: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: farbe, border: Border.all(color: kBg, width: 1.5))),
            ),
          ),
        ),
      ],
    );
  }
}

class _TitelKnopf extends StatelessWidget {
  final ({String haupt, String? unter}) titel;
  final bool breit;
  final VoidCallback? onTap;
  final String semantik;
  const _TitelKnopf({required this.titel, required this.breit, required this.onTap, required this.semantik});

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          titel.haupt,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: breit ? 30 : 18, fontWeight: FontWeight.w800, letterSpacing: breit ? -0.9 : -0.4, color: kTextStrong, height: 1.15),
        ),
        if (titel.unter != null) Text(titel.unter!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
      ],
    );
    final skaliert = breit ? text : FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: text);
    return Semantics(
      header: true,
      button: onTap != null,
      label: semantik,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Align(alignment: Alignment.centerLeft, child: skaliert)),
        ),
      ),
    );
  }
}

class _RahmenKnopf extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  const _RahmenKnopf({required this.tooltip, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(10), border: Border.all(color: kBorder)),
          child: Icon(icon, size: 20),
        ),
      ),
    ),
  );
}

class _MenueKnopf extends StatelessWidget {
  final String text;
  const _MenueKnopf({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 44),
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(10), border: Border.all(color: kBorder)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(width: 4),
        const Icon(Icons.arrow_drop_down, size: 20),
      ],
    ),
  );
}

/// Desktop: Menü "Anzeige" mit den drei Schaltern (Feiertage, Schulferien, Geburtstage).
class _AnzeigeMenue extends ConsumerWidget {
  final int aktiv;
  const _AnzeigeMenue({required this.aktiv});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eintraege = [
      (wert: 'feiertage', text: 'Feiertage', an: ref.watch(feiertageAnzeigenProvider)),
      (wert: 'ferien', text: 'Schulferien', an: ref.watch(ferienAnzeigenProvider)),
      (wert: 'geburtstage', text: 'Geburtstage', an: ref.watch(geburtstageAnzeigenProvider)),
      if (ref.watch(muellProvider.select((z) => z.hatTermine))) (wert: 'muell', text: 'Müll', an: ref.watch(muellProvider.select((z) => z.einst.imKalender))),
    ];
    return PopupMenuButton<String>(
      tooltip: 'Anzeige: Feiertage, Schulferien, Geburtstage, Müll',
      onSelected: (w) {
        switch (w) {
          case 'feiertage':
            ref.read(feiertageAnzeigenProvider.notifier).setzen(!eintraege[0].an);
          case 'ferien':
            ref.read(ferienAnzeigenProvider.notifier).setzen(!eintraege[1].an);
          case 'geburtstage':
            ref.read(geburtstageAnzeigenProvider.notifier).setzen(!eintraege[2].an);
          case 'muell':
            ref.read(muellProvider.notifier).kalenderSetzen(!eintraege[3].an);
          case 'farben':
            kalenderFilterBlattOeffnen(context);
        }
      },
      itemBuilder: (_) => [
        for (final e in eintraege) CheckedPopupMenuItem(value: e.wert, checked: e.an, child: Text(e.text)),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'farben', child: Text('Farben filtern …')),
      ],
      child: const _MenueKnopf(text: 'Anzeige'),
    );
  }
}

/// Umschalter Agenda | Monat | Woche (zusammenhängende Leiste; mobil über die volle Breite, Desktop mit festen Segmenten).
class AnsichtUmschalter extends StatelessWidget {
  final KalenderAnsicht aktiv;
  final void Function(KalenderAnsicht) onWahl;
  final bool breit;
  const AnsichtUmschalter({super.key, required this.aktiv, required this.onWahl, this.breit = false});

  @override
  Widget build(BuildContext context) {
    Widget segment(KalenderAnsicht a) {
      final an = a == aktiv;
      final inhalt = InkWell(
        onTap: () => onWahl(a),
        child: Container(
          constraints: BoxConstraints(minHeight: 44, minWidth: breit ? 88 : 0),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: an ? kAccentSoft : null,
          child: Text(a.label, maxLines: 1, style: TextStyle(fontSize: breit ? 14 : 13, fontWeight: FontWeight.w600, color: an ? kAccent : kText)),
        ),
      );
      return Semantics(button: true, selected: an, label: a.label, excludeSemantics: true, onTap: () => onWahl(a), child: inhalt);
    }

    final segmente = [for (final a in KalenderAnsicht.values) breit ? segment(a) : Expanded(child: segment(a))];
    return Container(
      decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(child: Row(mainAxisSize: breit ? MainAxisSize.min : MainAxisSize.max, children: segmente)),
    );
  }
}

/// Filter und Anzeige als Bottom-Sheet: Personen, Schalter für Feiertage, Schulferien und Geburtstage.
Future<void> kalenderFilterBlattOeffnen(BuildContext context) => showModalBottomSheet<void>(
  useRootNavigator: false,
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (_) => const _FilterBlatt(),
);

class _FilterBlatt extends ConsumerWidget {
  const _FilterBlatt();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(kalenderAuswahlProvider);
    final n = ref.read(kalenderAuswahlProvider.notifier);
    final personen = ref.watch(mitgliederProvider).value ?? const <UserDto>[];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Filter und Anzeige', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: kTextStrong)),
                ),
                TextButton(
                  onPressed: () {
                    n.alle();
                    ref.read(feiertageAnzeigenProvider.notifier).setzen(true);
                    ref.read(ferienAnzeigenProvider.notifier).setzen(true);
                    ref.read(geburtstageAnzeigenProvider.notifier).setzen(true);
                    ref.read(farbenAusProvider.notifier).alleAn();
                  },
                  child: const Text('Zurücksetzen'),
                ),
              ],
            ),
            if (personen.length >= 2) ...[
              const SizedBox(height: 12),
              const MonoLabel('// personen'),
              const SizedBox(height: 8),
              PersonenFilter(personen: personen, gewaehlt: a.personen, onPerson: n.person, onAlle: n.alle),
            ],
            const SizedBox(height: 16),
            const _FarbenFilter(),
            const SizedBox(height: 16),
            const MonoLabel('// im kalender anzeigen'),
            const SizedBox(height: 4),
            _SchalterZeile(text: 'Feiertage', farbe: kFeiertag, provider: feiertageAnzeigenProvider),
            _SchalterZeile(text: 'Schulferien', farbe: kFerien, provider: ferienAnzeigenProvider),
            _SchalterZeile(text: 'Geburtstage', farbe: kGeburtstag, provider: geburtstageAnzeigenProvider),
            const _MuellSchalterZeile(),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Bei wenig Platz im Raster: getönte Zelle = Schulferien, Streifen oben = Feiertag.', style: TextStyle(fontSize: 12, color: kTextMuted)),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Fertig')),
          ],
        ),
      ),
    );
  }
}

/// Abschnitt "Farben" im Filter-Blatt: je Termin-Farbe ein Schalter mit der Zahl der Termine, dazu "Alle an" und "Alle aus". Reine Anzeige:
/// Termine ohne Farbe, Geburtstage, Feiertage und Ferien bleiben immer sichtbar, es wird nie ein Termin verändert.
class _FarbenFilter extends ConsumerWidget {
  const _FarbenFilter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final aus = ref.watch(farbenAusProvider);
    final n = ref.read(farbenAusProvider.notifier);
    final zahlen = zaehleFarben([for (final t in ref.watch(kalenderDatenProvider).termine) if (!istGeburtstag(t)) t.farbe]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('// farben'),
        const SizedBox(height: 4),
        for (var i = 0; i < kTerminFarben.length; i++)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: !aus.contains(i),
            onChanged: (_) => n.umschalten(i),
            secondary: null,
            title: Row(
              children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: kTerminFarben[i].farbe)),
                const SizedBox(width: 12),
                Expanded(child: Text(kTerminFarben[i].name)),
                Text('${zahlen[i] ?? 0}', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(child: OutlinedButton(onPressed: n.alleAn, child: const Text('Alle an'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: n.alleAus, child: const Text('Alle aus'))),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Termine ohne Farbe bleiben immer sichtbar.', style: TextStyle(fontSize: 12, color: kTextMuted)),
        ),
      ],
    );
  }
}

/// Schalter "Müll" (Abfuhrtermine): nur Anzeige, nur auf diesem Gerät, Standard aus; für alle Mitglieder (auch Kinder). Nur sichtbar, wenn der Server
/// Abfuhrtermine liefert. Das "Zurücksetzen" des Blatts lässt ihn unberührt (er ist von sich aus aus).
class _MuellSchalterZeile extends ConsumerWidget {
  const _MuellSchalterZeile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(muellProvider);
    if (!z.hatTermine) return const SizedBox.shrink();
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: z.einst.imKalender,
      onChanged: (v) => ref.read(muellProvider.notifier).kalenderSetzen(v),
      title: Row(
        children: [
          Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: kMuellRest)),
          const SizedBox(width: 12),
          const Expanded(child: Text('Müll')),
        ],
      ),
    );
  }
}

class _SchalterZeile extends ConsumerWidget {
  final String text;
  final Color farbe;
  final NotifierProvider<AnzeigeSchalter, bool> provider;
  const _SchalterZeile({required this.text, required this.farbe, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final an = ref.watch(provider);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: an,
      onChanged: (v) => ref.read(provider.notifier).setzen(v),
      title: Row(
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: farbe)),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// "Neuer Termin" für den gewählten Tag (außer in der Agenda: dort ohne Tag).
Future<void> neuerTerminOeffnen(BuildContext context, KalenderAuswahl a, [DateTime? tag]) =>
    terminEditorOeffnen(context, tag: tag ?? (a.ansicht == KalenderAnsicht.agenda ? null : a.tag));
