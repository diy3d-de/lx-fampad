// "Mehr" in der unteren Leiste (nur mobil): Blatt mit den Bereichen und Seiten, die nicht in der Leiste stehen, in drei Gruppen (Familie, Zuhause, Ablage), dazu Hinweise (Zahlen) und die Zeile "Profil".
// Dieselben Einträge in derselben Reihenfolge zeigt die Seitenleiste im Desktop-Layout. Das Blatt ändert den aktiven Bereich nicht; ein Eintrag schließt es und öffnet sein Ziel.
// Neuer Eintrag (z. B. Medikamente) = ein Eintrag mit Gruppe in [bereichsEintraege].
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/muell/muell_state.dart';
import '../../data/shell/leiste_logik.dart';
import '../../data/shell/leiste_state.dart';
import '../../data/shell/zuletzt_logik.dart';
import '../../data/shell/zuletzt_state.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../../data/tasks/aufgabe_repository.dart' show aufgabenProvider;
import '../../data/tasks/fristen_logik.dart';
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../medikamente/medikament_anzeige.dart' show medikamenteFaelligProvider;
import '../medikamente/medikamente_karte.dart' show medikamenteOeffnen;
import '../vorsorge/vorsorge_anzeige.dart' show vorsorgeHinweisProvider;
import '../vorsorge/vorsorge_screen.dart' show vorsorgeOeffnen;
import '../zaehler/zaehler_anzeige.dart' show zaehlerFaelligProvider;
import '../zaehler/zaehler_karte.dart' show zaehlerOeffnen;
import '../tresor/tresor_screen.dart' show tresorOeffnen;
import '../../data/tresor/tresor_state.dart' show tresorDarfProvider;
import '../../data/dateien/datei_state.dart' show dateienVerfuegbarProvider;
import '../../data/zaehler/zaehler_state.dart' show zaehlerDarfProvider;
import '../files/dateien_screen.dart' show dateienOeffnen;
import '../muell/muell_karte.dart' show MuellKachelDaten, muellOeffnen;
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
  final vorsorge = ref.watch(vorsorgeHinweisProvider);
  final muellZ = ref.watch(muellProvider);
  final muellHinweis = muellZ.verfuegbar && MuellKachelDaten.aus(muellZ, jetzt).hervorgehoben ? 1 : 0;
  return MehrHinweise(
    aufgaben: aufgaben.length,
    aufgabenUeberfaellig: aufgaben.where((a) => istUeberfaellig(a, jetzt)).length,
    fristen: fristen.length,
    fristenUeberfaellig: fristen.where((a) => fristAmpel(a, jetzt) == FristAmpel.ueberfaellig).length,
    medikamente: ref.watch(medikamenteFaelligProvider),
    zaehler: ref.watch(zaehlerFaelligProvider),
    vorsorge: vorsorge.offen,
    vorsorgeUeberfaellig: vorsorge.ueberfaellig,
    muell: muellHinweis,
  );
});

/// Die drei Gruppen der Navigation (Blatt "Mehr" mobil, Seitenleiste im Desktop-Layout): gleiche Einträge in gleicher Reihenfolge.
enum MehrGruppe {
  familie('Familie'),
  zuhause('Zuhause'),
  ablage('Ablage');

  final String label;
  const MehrGruppe(this.label);
}

/// Ein Eintrag der Navigation. [hinweis] > 0 zeigt ein kleines Zeichen (rot bei [ueberfaellig], sonst gelb).
/// [tab] ist der Index im Seitenstapel, wenn der Eintrag ein Bereich der Desktop-Shell ist (sonst null, z. B. Suche); [vorWahl] läuft vor dem Wechsel
/// in den Bereich (Fristen stellen den Aufgaben-Filter ein).
class MehrEintrag {
  final String id;
  final String label;
  final IconData icon;
  final MehrGruppe gruppe;
  final int? tab;
  final int hinweis;
  final bool ueberfaellig;
  final void Function(WidgetRef ref)? vorWahl;
  final void Function(BuildContext context, WidgetRef ref) oeffnen;
  const MehrEintrag({required this.id, required this.label, required this.icon, required this.gruppe, required this.oeffnen, this.tab, this.hinweis = 0, this.ueberfaellig = false, this.vorWahl});
}

/// Alle Einträge der drei Gruppen in fester Reihenfolge (eine Quelle für Blatt und Seitenleiste; ein neuer Bereich = ein Eintrag hier):
/// Familie: Listen, Aufgaben, Fristen, Standort. Zuhause: Müll und Wetter (nur wenn verfügbar), Zähler (nur Eltern/Admins), Medikamente.
/// Ablage: Dateien (nur wenn die Dateiablage da ist), Tresor (nur Eltern/Admins), Suche. [offenerTab]: der gerade gewählte Bereich der Desktop-Shell
/// (Wetter und Müll bleiben dann auch sichtbar, wenn sie ausgeschaltet werden, damit der Bereich nicht unter dir verschwindet).
List<MehrEintrag> bereichsEintraege(WidgetRef ref, {int? offenerTab}) {
  final h = ref.watch(mehrHinweiseProvider);
  final muell = ref.watch(muellProvider.select((m) => m.verfuegbar)) || offenerTab == kMuellTab;
  final wetter = ref.watch(wetterProvider.select((w) => w.kachelSichtbar)) || offenerTab == kWetterTab;
  final zaehlerDarf = ref.watch(zaehlerDarfProvider);
  final tresorDarf = ref.watch(tresorDarfProvider);
  final dateienDa = ref.watch(dateienVerfuegbarProvider).value ?? false;
  MehrEintrag tabEintrag(int tab, MehrGruppe g) => MehrEintrag(
    id: leisteKennung(tab),
    label: kTabs[tab].label,
    icon: kTabs[tab].icon,
    gruppe: g,
    tab: tab,
    hinweis: tab == kAufgabenTab ? h.aufgaben : 0,
    ueberfaellig: tab == kAufgabenTab && h.aufgabenUeberfaellig > 0,
    oeffnen: (_, ref) => ref.read(shellTabProvider.notifier).waehlen(tab),
  );
  return [
    // Familie
    tabEintrag(kListenTab, MehrGruppe.familie),
    tabEintrag(kAufgabenTab, MehrGruppe.familie),
    MehrEintrag(
      id: 'fristen',
      label: 'Fristen',
      icon: Icons.event_available_outlined,
      gruppe: MehrGruppe.familie,
      tab: kAufgabenTab,
      hinweis: h.fristen,
      ueberfaellig: h.fristenUeberfaellig > 0,
      vorWahl: (ref) => ref.read(aufgabenAnsichtProvider.notifier).filter(AufgabeFilter.fristen),
      oeffnen: (_, ref) {
        ref.read(aufgabenAnsichtProvider.notifier).filter(AufgabeFilter.fristen);
        ref.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
      },
    ),
    MehrEintrag(id: 'standort', label: 'Standort', icon: Icons.location_on_outlined, gruppe: MehrGruppe.familie, tab: kStandortTab, oeffnen: (c, _) => standortOeffnen(c)),
    // Zuhause
    if (muell) MehrEintrag(id: 'muell', label: 'Müll', icon: Icons.delete_outline, gruppe: MehrGruppe.zuhause, tab: kMuellTab, hinweis: h.muell, oeffnen: (c, _) => muellOeffnen(c)),
    if (wetter) MehrEintrag(id: 'wetter', label: 'Wetter', icon: Icons.wb_sunny_outlined, gruppe: MehrGruppe.zuhause, tab: kWetterTab, oeffnen: (c, _) => wetterOeffnen(c)),
    // Zähler: NUR für Eltern und Admins, Kinder bekommen den Eintrag nie; die Zahl sind die Zähler, die jetzt abgelesen werden sollen
    if (zaehlerDarf) MehrEintrag(id: 'zaehler', label: 'Zähler', icon: Icons.speed_outlined, gruppe: MehrGruppe.zuhause, tab: kZaehlerTab, hinweis: h.zaehler, oeffnen: (c, _) => zaehlerOeffnen(c)),
    // Medikamente: nur Eigenes und das der Kinder; die Zahl sind fällige und verpasste Einnahmen heute
    MehrEintrag(id: 'medikamente', label: 'Medikamente', icon: Icons.medication_outlined, gruppe: MehrGruppe.zuhause, tab: kMedikamenteTab, hinweis: h.medikamente, oeffnen: (c, _) => medikamenteOeffnen(c)),
    // Vorsorge: für alle Rollen, aber nur Eigenes und das der Kinder; die Zahl sind fällige und überfällige Einträge (nur die Zahl, nie ein Name)
    MehrEintrag(id: 'vorsorge', label: 'Vorsorge', icon: Icons.vaccines_outlined, gruppe: MehrGruppe.zuhause, tab: kVorsorgeTab, hinweis: h.vorsorge, ueberfaellig: h.vorsorgeUeberfaellig > 0, oeffnen: (c, _) => vorsorgeOeffnen(c)),
    // Ablage
    // Dateien: nur wenn der Server die Dateiablage meldet; Kinder sehen den Bereich mit ihren Rechten, ohne Zahl und ohne Zeichen
    if (dateienDa) MehrEintrag(id: 'dateien', label: 'Dateien', icon: Icons.folder_outlined, gruppe: MehrGruppe.ablage, tab: kDateienTab, oeffnen: (c, _) => dateienOeffnen(c)),
    // Tresor: NUR für Eltern und Admins, Kinder bekommen den Eintrag nie; ohne Zahl und ohne Zeichen
    if (tresorDarf) MehrEintrag(id: 'tresor', label: 'Tresor', icon: Icons.lock_outline, gruppe: MehrGruppe.ablage, tab: kTresorTab, oeffnen: (c, _) => tresorOeffnen(c)),
    MehrEintrag(id: 'suche', label: 'Suche', icon: Icons.search, gruppe: MehrGruppe.ablage, oeffnen: (c, _) => unawaited(Navigator.of(c).push<void>(SuchScreen.route()))),
  ];
}

/// Die Einträge des Blatts: alle Einträge der drei Gruppen, ohne die Bereiche, die in der Leiste stehen (Listen und Aufgaben, falls gewählt).
List<MehrEintrag> mehrEintraege(WidgetRef ref, List<int> leiste) => [
  for (final e in bereichsEintraege(ref))
    if (e.id == 'fristen' || e.tab == null || !leiste.contains(e.tab)) e,
];

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
    child: Text(hinweisText(zahl), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 10, fontWeight: FontWeight.w700, color: kBg, height: 1.1)),
  );
}

class MehrBlatt extends ConsumerStatefulWidget {
  /// Kontext der Seite unter dem Blatt: Ziele öffnen darin, nachdem das Blatt geschlossen ist.
  final BuildContext seite;
  const MehrBlatt({super.key, required this.seite});

  @override
  ConsumerState<MehrBlatt> createState() => _MehrBlattState();
}

class _MehrBlattState extends ConsumerState<MehrBlatt> {
  final _suche = TextEditingController();

  @override
  void dispose() {
    _suche.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seite = widget.seite;
    final leiste = ref.watch(leisteProvider).tabs;
    final eintraege = mehrEintraege(ref, leiste);
    final merker = ref.watch(shellMerkerProvider);
    final eingabe = _suche.text.trim();
    // Suche nur in den Namen der Bereiche (nie in Inhalten); ohne Eingabe: "Zuletzt benutzt" und die Gruppen
    final treffer = [for (final e in eintraege) if (bereichPasst(e.label, eingabe)) e];
    final zuletzt = [
      for (final id in zuletztSichtbar(merker.zuletzt, {for (final e in eintraege) e.id}))
        eintraege.firstWhere((e) => e.id == id),
    ];
    // Beschriftungen wachsen höchstens auf 1,3-fach (vier Spalten); Screenreader bekommen den vollen Namen, die Fläche scrollt
    final skala = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final hoehe = 66 + skala.scale(11) * 2.3;

    void waehlen(MehrEintrag e) {
      unawaited(ref.read(shellMerkerProvider.notifier).merken(e.id));
      Navigator.of(context).pop();
      if (seite.mounted) e.oeffnen(seite, ref);
    }

    Widget raster(List<MehrEintrag> liste) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: skala),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: liste.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 8, crossAxisSpacing: 8, mainAxisExtent: hoehe),
        itemBuilder: (_, i) => _Kachel(eintrag: liste[i], onTap: () => waehlen(liste[i])),
      ),
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(14, 0, 14, 14 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _suche,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Bereich suchen',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: eingabe.isEmpty ? null : IconButton(tooltip: 'Suche leeren', icon: const Icon(Icons.close), onPressed: () => setState(_suche.clear)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            if (eingabe.isNotEmpty) ...[
              if (treffer.isEmpty)
                const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text('Keinen Bereich gefunden.', textAlign: TextAlign.center, style: TextStyle(color: kTextMuted)))
              else
                raster(treffer),
            ] else ...[
              if (zuletzt.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(2, 6, 2, 8),
                  child: MonoLabel('Zuletzt benutzt', color: kTextMuted),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final e in zuletzt) _ZuletztChip(eintrag: e, onTap: () => waehlen(e))],
                ),
              ],
              // drei Gruppen mit Überschrift; leere Gruppen entfallen samt Überschrift
              for (final g in MehrGruppe.values)
                if (eintraege.any((e) => e.gruppe == g)) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 6, 2, 8),
                    child: Semantics(header: true, child: MonoLabel(g.label, color: kTextMuted)),
                  ),
                  raster([for (final e in eintraege) if (e.gruppe == g) e]),
                ],
            ],
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

/// Eintrag der Zeile "Zuletzt benutzt": eine Fläche mit Symbol und Name (Touch-Ziel mindestens 44 px).
class _ZuletztChip extends StatelessWidget {
  final MehrEintrag eintrag;
  final VoidCallback onTap;
  const _ZuletztChip({required this.eintrag, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Zuletzt benutzt: ${eintrag.label}',
    excludeSemantics: true,
    child: Material(
      color: kBgElevated,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey('zuletzt:${eintrag.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(eintrag.icon, size: 18, color: kAccent),
                const SizedBox(width: 8),
                Flexible(child: Text(eintrag.label, style: const TextStyle(fontSize: 13.5))),
              ],
            ),
          ),
        ),
      ),
    ),
  );
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: InkWell(
          key: ValueKey('mehr:${e.id}'),
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
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
