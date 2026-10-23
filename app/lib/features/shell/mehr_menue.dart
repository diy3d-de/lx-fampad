// "Mehr" in der unteren Leiste (nur mobil): Blatt mit den Bereichen und Seiten, die nicht in der Leiste stehen, dazu Hinweise (Zahlen) und die Zeile "Profil".
// Das Blatt ändert den aktiven Bereich nicht; ein Eintrag schließt es und öffnet sein Ziel. Neuer Eintrag (z. B. Medikamente) = ein Eintrag in [mehrEintraege].
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/muell/muell_state.dart';
import '../../data/shell/leiste_logik.dart';
import '../../data/shell/leiste_state.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../../data/tasks/aufgabe_repository.dart' show aufgabenProvider;
import '../../data/tasks/fristen_logik.dart';
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../muell/muell_karte.dart' show muellOeffnen;
import '../profile/profile_screen.dart';
import '../standort/standort_start_karte.dart' show standortOeffnen;
import '../suche/such_screen.dart';
import '../tasks/aufgaben_anzeige.dart' show startseitenAufgaben;
import '../tasks/fristen_anzeige.dart' show dringendeFristenProvider;
import '../tasks/tasks_state.dart' show aufgabenAnsichtProvider;
import '../wetter/wetter_karte.dart' show wetterOeffnen;
import 'shell_tab.dart';

/// Hinweise hinter "Mehr", lokal aus den vorhandenen Providern (keine Server-Aufrufe).
final mehrHinweiseProvider = Provider.autoDispose<MehrHinweise>((ref) {
  final alle = ref.watch(aufgabenProvider).value ?? const [];
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  final fristen = ref.watch(dringendeFristenProvider);
  final aufgaben = startseitenAufgaben([for (final a in alle) if (!istFrist(a)) a], jetzt, nurFaellig: true);
  return MehrHinweise(
    aufgaben: aufgaben.length,
    aufgabenUeberfaellig: aufgaben.where((a) => istUeberfaellig(a, jetzt)).length,
    fristen: fristen.length,
    fristenUeberfaellig: fristen.where((a) => fristAmpel(a, jetzt) == FristAmpel.ueberfaellig).length,
  );
});

/// Ein Eintrag im Blatt. [hinweis] > 0 zeigt ein kleines Zeichen (rot bei [ueberfaellig], sonst gelb).
class MehrEintrag {
  final String id;
  final String label;
  final IconData icon;
  final int hinweis;
  final bool ueberfaellig;
  final void Function(BuildContext context, WidgetRef ref) oeffnen;
  const MehrEintrag({required this.id, required this.label, required this.icon, required this.oeffnen, this.hinweis = 0, this.ueberfaellig = false});
}

/// Die Einträge des Blatts in fester Reihenfolge: Bereiche hinter "Mehr", Fristen, Müll, Wetter (nur wenn verfügbar), Standort, Suche.
List<MehrEintrag> mehrEintraege(WidgetRef ref, List<int> leiste) {
  final h = ref.watch(mehrHinweiseProvider);
  final muell = ref.watch(muellProvider.select((m) => m.verfuegbar));
  final wetter = ref.watch(wetterProvider.select((w) => w.kachelSichtbar));
  return [
    for (final tab in hinterMehr(leiste))
      MehrEintrag(
        id: leisteKennung(tab),
        label: kTabs[tab].label,
        icon: kTabs[tab].icon,
        hinweis: tab == kAufgabenTab ? h.aufgaben : 0,
        ueberfaellig: tab == kAufgabenTab && h.aufgabenUeberfaellig > 0,
        oeffnen: (_, ref) => ref.read(shellTabProvider.notifier).waehlen(tab),
      ),
    MehrEintrag(
      id: 'fristen',
      label: 'Fristen',
      icon: Icons.event_available_outlined,
      hinweis: h.fristen,
      ueberfaellig: h.fristenUeberfaellig > 0,
      oeffnen: (_, ref) {
        ref.read(aufgabenAnsichtProvider.notifier).filter(AufgabeFilter.fristen);
        ref.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
      },
    ),
    if (muell) MehrEintrag(id: 'muell', label: 'Müll', icon: Icons.delete_outline, oeffnen: (c, _) => muellOeffnen(c)),
    if (wetter) MehrEintrag(id: 'wetter', label: 'Wetter', icon: Icons.wb_sunny_outlined, oeffnen: (c, _) => wetterOeffnen(c)),
    MehrEintrag(id: 'standort', label: 'Standort', icon: Icons.location_on_outlined, oeffnen: (c, _) => standortOeffnen(c)),
    MehrEintrag(id: 'suche', label: 'Suche', icon: Icons.search, oeffnen: (c, _) => unawaited(Navigator.of(c).push<void>(SuchScreen.route()))),
  ];
}

/// Öffnet das Blatt (im Navigator der Seite, nicht im Wurzel-Navigator).
Future<void> mehrBlattOeffnen(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: false,
  isScrollControlled: true,
  backgroundColor: kSurface,
  showDragHandle: true,
  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85, maxWidth: kMaxContentWidth),
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
  builder: (sheet) => MehrBlatt(seite: context),
);

/// Zeichen mit Zahl (Kachel und Leiste); rot bei Überfälligem, sonst gelb.
class HinweisZeichen extends StatelessWidget {
  final int zahl;
  final bool ueberfaellig;
  const HinweisZeichen({super.key, required this.zahl, required this.ueberfaellig});

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
    padding: const EdgeInsets.symmetric(horizontal: 5),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: ueberfaellig ? kDanger : kWarn, borderRadius: BorderRadius.circular(9)),
    child: Text(hinweisText(zahl), style: const TextStyle(fontFamily: kFontMono, fontSize: 10, fontWeight: FontWeight.w700, color: kBg, height: 1.1)),
  );
}

class MehrBlatt extends ConsumerWidget {
  /// Kontext der Seite unter dem Blatt: Ziele öffnen darin, nachdem das Blatt geschlossen ist.
  final BuildContext seite;
  const MehrBlatt({super.key, required this.seite});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leiste = ref.watch(leisteProvider).tabs;
    final eintraege = mehrEintraege(ref, leiste);
    // Beschriftungen wachsen höchstens auf 1,3-fach (vier Spalten); Screenreader bekommen den vollen Namen, die Fläche scrollt
    final skala = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final hoehe = 66 + skala.scale(11) * 2.3;

    void waehlen(MehrEintrag e) {
      Navigator.of(context).pop();
      if (seite.mounted) e.oeffnen(seite, ref);
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: skala),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: eintraege.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 8, crossAxisSpacing: 8, mainAxisExtent: hoehe),
                itemBuilder: (_, i) => _Kachel(eintrag: eintraege[i], onTap: () => waehlen(eintraege[i])),
              ),
            ),
            const SizedBox(height: 10),
            Semantics(
              button: true,
              label: 'Profil: Konto, Sicherheit, Einstellungen',
              excludeSemantics: true,
              child: LxCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                onTap: () {
                  Navigator.of(context).pop();
                  if (seite.mounted) unawaited(Navigator.of(seite).push<void>(ProfileScreen.route()));
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      Icon(Icons.person_outline, color: kAccent),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Profil', style: TextStyle(fontWeight: FontWeight.w600)),
                            Text('Konto, Sicherheit, Einstellungen', style: TextStyle(fontSize: 12, color: kTextMuted)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: kTextMuted),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Kachel extends StatelessWidget {
  final MehrEintrag eintrag;
  final VoidCallback onTap;
  const _Kachel({required this.eintrag, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final e = eintrag;
    return Semantics(
      button: true,
      label: e.hinweis > 0 ? '${e.label}, ${e.hinweis} ${e.hinweis == 1 ? 'Hinweis' : 'Hinweise'}${e.ueberfaellig ? ', Überfälliges dabei' : ''}' : e.label,
      excludeSemantics: true,
      child: Material(
        color: kBgElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kBorder)),
        child: InkWell(
          key: ValueKey('mehr:${e.id}'),
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          onTap: onTap,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(e.icon, color: kAccent),
                    const SizedBox(height: 6),
                    Text(e.label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, height: 1.15)),
                  ],
                ),
              ),
              if (e.hinweis > 0) Positioned(top: 4, right: 4, child: HinweisZeichen(zahl: e.hinweis, ueberfaellig: e.ueberfaellig)),
            ],
          ),
        ),
      ),
    );
  }
}
