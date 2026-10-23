// Wandtablet-Modus: Vollbild-Anzeige für ein fest installiertes Tablet (Querformat, auch Web im Vollbild). NUR Anzeige, keine Eingabe:
// Uhr, Termine heute und morgen, fällige Aufgaben, Müll, Wetter, Countdowns, Fristen und optional EINE Liste. Alles aus der lokalen Datenbank
// (offline-first, aktualisiert sich über den Sync live). Nie Chat, Standort, Schlüssel, Betrieb oder Profil.
//  - Ausstieg: Uhr gedrückt halten (auch als Semantics-Aktion); die Zurück-Taste beendet nichts.
//  - Bildschirm bleibt an (Wake Lock, beim Verlassen freigegeben); Einbrenn-Schutz: Inhalt rückt alle 5 Minuten um wenige Pixel, nachts gedimmt.
//  - Abmeldung, Sitzungsverlust und Personenwechsel beenden den Modus (die App zeigt dann die normale Anmeldung).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/feiertage.dart';
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/lists/list_repository.dart';
import '../../data/lists/members.dart';
import '../../data/muell/muell_logik.dart';
import '../../data/muell/muell_state.dart';
import '../../data/sync_state.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../../data/tasks/aufgabe_repository.dart' show aufgabenProvider;
import '../../data/tasks/fristen_logik.dart';
import '../../data/wandtablet/bildschirm_wach.dart';
import '../../data/wandtablet/wandtablet_einstellungen.dart';
import '../../data/wandtablet/wandtablet_logik.dart';
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_anzeige.dart';
import '../calendar/calendar_state.dart';
import '../calendar/countdown_karte.dart' show countdownEintraegeProvider;
import '../muell/muell_karte.dart' show MuellKachelDaten;
import '../muell/muell_widgets.dart';
import '../tasks/fristen_anzeige.dart' show dringendeFristenProvider, fristFarbe, fristKurzText;

class WandtabletScreen extends ConsumerStatefulWidget {
  const WandtabletScreen({super.key});

  /// Unbenannte Route (nie benannte Routen, siehe CLAUDE.md).
  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const WandtabletScreen());

  @override
  ConsumerState<WandtabletScreen> createState() => _WandtabletScreenState();
}

class _WandtabletScreenState extends ConsumerState<WandtabletScreen> {
  late final BildschirmWach _wach = ref.read(bildschirmWachProvider);
  late final String? _person = ref.read(authProvider).user?.id;
  Timer? _hinweisTimer;
  bool _hinweis = true;
  bool _beendet = false;

  bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    unawaited(_wach.halten());
    if (_android) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _hinweisTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _hinweis = false);
    });
  }

  @override
  void dispose() {
    _hinweisTimer?.cancel();
    unawaited(_wach.freigeben());
    if (_android) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _beenden() {
    if (_beendet || !mounted) return;
    _beendet = true;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  void _hinweisZeigen() {
    _hinweisTimer?.cancel();
    if (mounted) setState(() => _hinweis = true);
    _hinweisTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _hinweis = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Sitzung weg oder andere Person: der Modus endet sauber
    ref.listen(authProvider.select((a) => (a.status, a.user?.id)), (_, n) {
      if (n.$1 != AuthStatus.angemeldet || n.$2 != _person) WidgetsBinding.instance.addPostFrameCallback((_) => _beenden());
    });
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final einst = ref.watch(wandtabletEinstellungenProvider);
    final sync = ref.watch(syncProvider.select((s) => (s.status, s.letzterAbgleich)));
    final offline = sync.$1 == SyncStatus.offline || sync.$1 == SyncStatus.fehler;
    final v = verschiebung(jetzt);
    final dimm = dimmDeckkraft(jetzt, dimmen: einst.dimmen);
    return PopScope(
      canPop: false,
      // die Zurück-Taste beendet nicht; sie erinnert nur an den bewussten Ausstieg
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hinweisZeigen();
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            TweenAnimationBuilder<Offset>(
              tween: Tween(end: Offset(v.dx.toDouble(), v.dy.toDouble())),
              duration: const Duration(seconds: 4),
              builder: (context, o, child) => Transform.translate(offset: o, child: child),
              child: SafeArea(
                minimum: const EdgeInsets.all(kWandVerschiebeMax + 10),
                child: _Inhalt(jetzt: jetzt, onBeenden: _beenden),
              ),
            ),
            if (dimm > 0) Positioned.fill(child: IgnorePointer(child: ColoredBox(color: kBg.withValues(alpha: dimm)))),
            if (offline)
              Positioned(
                left: 16,
                bottom: 10,
                child: Semantics(
                  liveRegion: true,
                  child: Text(offlineText(sync.$2, jetzt), style: const TextStyle(fontFamily: kFontMono, fontSize: 14, color: kTextMuted)),
                ),
              ),
            if (_hinweis)
              Positioned(
                left: 0,
                right: 0,
                bottom: 40,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
                      child: const Text(kWandHinweisBeenden, style: TextStyle(fontFamily: kFontMono, fontSize: 16, color: kTextStrong)),
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

/// Der Inhalt: Kopf (Uhr, Datum, Hinweise) und die Blöcke in 1 bis 3 Spalten.
class _Inhalt extends ConsumerWidget {
  final DateTime jetzt;
  final VoidCallback onBeenden;
  const _Inhalt({required this.jetzt, required this.onBeenden});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final einst = ref.watch(wandtabletEinstellungenProvider);
    final muell = ref.watch(muellProvider);
    final wetter = ref.watch(wetterProvider);
    final listen = ref.watch(listenProvider).value ?? const <Liste>[];
    final liste = listen.where((l) => l.id == einst.liste).firstOrNull;
    final bloecke = sichtbareBloecke(
      fristen: ref.watch(dringendeFristenProvider).isNotEmpty,
      countdown: ref.watch(countdownEintraegeProvider).isNotEmpty,
      muell: MuellKachelDaten.aus(muell, jetzt).abholung != null,
      wetter: wetter.kachelSichtbar,
      einkauf: liste != null,
    );
    return LayoutBuilder(
      builder: (context, c) {
        final gross = c.maxWidth >= kDesktopBreakpoint;
        final spalten = wandSpalten(c.maxWidth);
        final kopf = _Kopf(jetzt: jetzt, gross: gross, onBeenden: onBeenden);
        Widget block(WandBlock b) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: switch (b) {
            WandBlock.termine => _TermineBlock(jetzt: jetzt, gross: gross),
            WandBlock.aufgaben => _AufgabenBlock(jetzt: jetzt, gross: gross),
            WandBlock.fristen => _FristenBlock(jetzt: jetzt, gross: gross),
            WandBlock.countdown => _CountdownBlock(gross: gross),
            WandBlock.muell => _MuellBlock(jetzt: jetzt, gross: gross),
            WandBlock.wetter => _WetterBlock(gross: gross),
            WandBlock.einkauf => _EinkaufBlock(liste: liste!, gross: gross),
          },
        );
        if (spalten == 1) {
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [kopf, const SizedBox(height: 16), for (final b in bloecke) block(b)]);
        }
        final teile = verteileSpalten(bloecke, spalten);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            kopf,
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < teile.length; i++) ...[
                    if (i > 0) const SizedBox(width: 20),
                    Expanded(
                      child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: Column(children: [for (final b in teile[i]) block(b)])),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

TextStyle _mono(double groesse, {Color farbe = kTextMuted, FontWeight gewicht = FontWeight.w400}) =>
    TextStyle(fontFamily: kFontMono, fontSize: groesse, color: farbe, fontWeight: gewicht);

class _Kopf extends ConsumerWidget {
  final DateTime jetzt;
  final bool gross;
  final VoidCallback onBeenden;
  const _Kopf({required this.jetzt, required this.gross, required this.onBeenden});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = wandJetzt(jetzt);
    final datum = DateFormat('EEEE, d. MMMM yyyy', 'de_DE').format(w);
    final heute = DateTime.utc(w.year, w.month, w.day);
    final hinweise = ref.watch(tagesHinweiseProvider).fuerTag(heute);
    final uhr = wandUhrText(jetzt);
    // Ausstieg: Uhr gedrückt halten (auch als Aktion für Screenreader). Die Uhr wächst nicht mit der Textskala (sie ist schon groß genug).
    final uhrGruppe = Semantics(
      label: 'Uhr, $uhr Uhr, $datum',
      hint: kWandHinweisBeenden,
      onLongPress: onBeenden,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onBeenden,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(uhr, textScaler: TextScaler.noScaling, style: _mono(gross ? 120 : 72, farbe: kTextStrong, gewicht: FontWeight.w700).copyWith(height: 1.0, letterSpacing: -2)),
              Text(datum, style: TextStyle(fontSize: gross ? 32 : 20, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: kTextStrong)),
            ],
          ),
        ),
      ),
    );
    final chips = Wrap(
      alignment: gross ? WrapAlignment.end : WrapAlignment.start,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final h in hinweise)
          () {
            final farbe = h.art == TagesHinweisArt.feiertag ? kFeiertag : kFerien;
            return Semantics(
              label: '${h.art == TagesHinweisArt.feiertag ? 'Feiertag' : 'Schulferien'}: ${h.name}',
              excludeSemantics: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: farbe.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10), border: Border.all(color: farbe.withValues(alpha: 0.4))),
                child: Text(h.name, style: _mono(gross ? 20 : 16, farbe: farbe)),
              ),
            );
          }(),
      ],
    );
    if (!gross) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [uhrGruppe, if (hinweise.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: chips)]);
    }
    return Row(
      children: [
        Flexible(flex: 3, child: uhrGruppe),
        if (hinweise.isNotEmpty) ...[const SizedBox(width: 24), Flexible(flex: 2, child: Align(alignment: Alignment.centerRight, child: chips))],
      ],
    );
  }
}

/// Rahmen eines Blocks: Mono-Label und Inhalt, gut lesbar aus der Entfernung.
class _Block extends StatelessWidget {
  final String label;
  final bool gross;
  final bool hervorgehoben;
  final Widget child;
  const _Block({required this.label, required this.gross, required this.child, this.hervorgehoben = false});

  @override
  Widget build(BuildContext context) => LxCard(
    gewaehlt: hervorgehoben,
    padding: EdgeInsets.all(gross ? 22 : 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(label.toUpperCase(), style: _mono(gross ? 16 : 13, farbe: kAccent).copyWith(letterSpacing: 1.2)),
        ),
        SizedBox(height: gross ? 14 : 10),
        child,
      ],
    ),
  );
}

Widget _leer(String text, bool gross) => Text(text, style: TextStyle(fontSize: gross ? 22 : 17, color: kTextMuted));

Widget _mehr(int n, bool gross) => Text('+ $n weitere', style: _mono(gross ? 18 : 14));

class _TermineBlock extends ConsumerWidget {
  final DateTime jetzt;
  final bool gross;
  const _TermineBlock({required this.jetzt, required this.gross});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daten = ref.watch(kalenderDatenProvider);
    final mitglieder = mitgliederFuer(ref, daten);
    final geburtstage = ref.watch(geburtstageAnzeigenProvider);
    final heute = heuteTag(jetzt);
    final morgenEnde = heute.add(const Duration(days: 2));
    final liste = [
      for (final v in anstehende(daten, jetzt, tage: 2))
        if (v.startWand.isBefore(morgenEnde) && (geburtstage || !istGeburtstag(v.termin))) v,
    ];
    final t = teileHeuteMorgen(liste, heute);
    final hinweise = ref.watch(tagesHinweiseProvider);
    Widget gruppe(String titel, List<Vorkommen> l, int max, String leer, DateTime tag) {
      final h = tag == heute ? const <TagesHinweis>[] : hinweise.fuerTag(tag); // die von heute stehen schon im Kopf
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titel, style: _mono(gross ? 20 : 15)),
          const SizedBox(height: 8),
          if (h.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(h.map((x) => x.name).join(' · '), style: _mono(gross ? 18 : 14, farbe: kFerien))),
          if (l.isEmpty)
            _leer(leer, gross)
          else ...[
            for (final v in l.take(max)) _TerminZeile(v: v, tag: tag, mitglieder: mitglieder, gross: gross),
            if (l.length > max) _mehr(l.length - max, gross),
          ],
        ],
      );
    }

    return _Block(
      label: '// termine',
      gross: gross,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          gruppe('HEUTE', t.heute, 8, 'Heute steht nichts an.', heute),
          SizedBox(height: gross ? 22 : 16),
          gruppe('MORGEN', t.morgen, 6, 'Morgen steht nichts an.', heute.add(const Duration(days: 1))),
        ],
      ),
    );
  }
}

class _TerminZeile extends StatelessWidget {
  final Vorkommen v;
  final DateTime tag;
  final Mitglieder mitglieder;
  final bool gross;
  const _TerminZeile({required this.v, required this.tag, required this.mitglieder, required this.gross});

  @override
  Widget build(BuildContext context) {
    final zeit = startZeitText(v, tag);
    final titel = vorkommenTitel(v);
    return Semantics(
      label: '$zeit, $titel',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(width: 6, height: gross ? 52 : 40, margin: const EdgeInsets.only(right: 14), decoration: BoxDecoration(color: terminFarbe(v, mitglieder), borderRadius: BorderRadius.circular(3))),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: gross ? 28 : 20, fontWeight: FontWeight.w700, color: kTextStrong, height: 1.15)),
                  Text(zeit, style: _mono(gross ? 20 : 15)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AufgabenBlock extends ConsumerWidget {
  final DateTime jetzt;
  final bool gross;
  const _AufgabenBlock({required this.jetzt, required this.gross});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alle = ref.watch(aufgabenProvider).value ?? const <Aufgabe>[];
    final l = wandAufgaben(alle, jetzt);
    return _Block(
      label: '// aufgaben',
      gross: gross,
      child: l.isEmpty
          ? _leer('Heute ist nichts fällig.', gross)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in l.take(8))
                  Semantics(
                    label: istUeberfaellig(a, jetzt) ? 'Überfällig: ${a.titel}' : a.titel,
                    excludeSemantics: true,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(istUeberfaellig(a, jetzt) ? Icons.error_outline : Icons.radio_button_unchecked, size: gross ? 28 : 22, color: istUeberfaellig(a, jetzt) ? kDanger : kTextMuted),
                          const SizedBox(width: 12),
                          Expanded(child: Text(a.titel, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: gross ? 26 : 19, color: kTextStrong, height: 1.15))),
                        ],
                      ),
                    ),
                  ),
                if (l.length > 8) _mehr(l.length - 8, gross),
              ],
            ),
    );
  }
}

class _FristenBlock extends ConsumerWidget {
  final DateTime jetzt;
  final bool gross;
  const _FristenBlock({required this.jetzt, required this.gross});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(dringendeFristenProvider);
    if (l.isEmpty) return const SizedBox.shrink();
    return _Block(
      label: '// fristen',
      gross: gross,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final a in l.take(4))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(width: 6, height: gross ? 52 : 40, margin: const EdgeInsets.only(right: 14), decoration: BoxDecoration(color: fristFarbe(fristAmpel(a, jetzt)), borderRadius: BorderRadius.circular(3))),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.titel, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: gross ? 26 : 19, fontWeight: FontWeight.w700, color: kTextStrong)),
                        Text(fristKurzText(a, jetzt), maxLines: 2, overflow: TextOverflow.ellipsis, style: _mono(gross ? 18 : 14, farbe: fristFarbe(fristAmpel(a, jetzt)))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (l.length > 4) _mehr(l.length - 4, gross),
        ],
      ),
    );
  }
}

class _CountdownBlock extends ConsumerWidget {
  final bool gross;
  const _CountdownBlock({required this.gross});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(countdownEintraegeProvider);
    if (l.isEmpty) return const SizedBox.shrink();
    return _Block(
      label: '// countdown',
      gross: gross,
      child: Column(
        children: [
          for (final e in l)
            Semantics(
              label: '${e.titel}: ${e.text}',
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Icon(Icons.hourglass_bottom, size: gross ? 28 : 22, color: kAccent),
                    const SizedBox(width: 12),
                    Expanded(child: Text(e.titel, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: gross ? 26 : 19, fontWeight: FontWeight.w600, color: kTextStrong))),
                    const SizedBox(width: 8),
                    Text(e.text, style: _mono(gross ? 22 : 16, farbe: kAccent, gewicht: FontWeight.w700)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MuellBlock extends ConsumerWidget {
  final DateTime jetzt;
  final bool gross;
  const _MuellBlock({required this.jetzt, required this.gross});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = MuellKachelDaten.aus(ref.watch(muellProvider), jetzt);
    final t = d.abholung;
    if (t == null) return const SizedBox.shrink();
    return Semantics(
      label: 'Müll: nächste Abholung ${muellLangDatum(t.tag)}, ${artenText(t.arten)}, ${tageBisText(d.tage)}',
      excludeSemantics: true,
      child: _Block(
        label: d.hervorgehoben ? '// müll · ${d.tage == 0 ? 'heute' : 'morgen'}' : '// müll',
        gross: gross,
        hervorgehoben: d.hervorgehoben,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(muellKurzDatum(t.tag), style: TextStyle(fontSize: gross ? 34 : 24, fontWeight: FontWeight.w800, color: kTextStrong, letterSpacing: -0.3)),
            const SizedBox(height: 4),
            Text(tageBisText(d.tage), style: _mono(gross ? 20 : 15)),
            const SizedBox(height: 10),
            MuellSymbolReihe(t.arten, groesse: gross ? 44 : 32),
          ],
        ),
      ),
    );
  }
}

class _WetterBlock extends ConsumerWidget {
  final bool gross;
  const _WetterBlock({required this.gross});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(wetterProvider);
    if (!st.kachelSichtbar) return const SizedBox.shrink();
    final dto = st.dto!;
    final stand = wetterStand(st, DateTime.now());
    return Semantics(
      label: 'Wetter in ${dto.ort}: ${temperaturText(dto.aktuell!.temperatur)}',
      excludeSemantics: true,
      child: _Block(
        label: '// wetter',
        gross: gross,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dto.ort, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: gross ? 24 : 18, fontWeight: FontWeight.w600, color: kTextStrong)),
                  Text(stand.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: _mono(gross ? 16 : 13, farbe: stand.warnung ? kWarn : kTextMuted)),
                  if (dto.min24h != null && dto.max24h != null)
                    Text('min ${temperaturText(dto.min24h)} · max ${temperaturText(dto.max24h)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: _mono(gross ? 16 : 13)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(temperaturText(dto.aktuell!.temperatur), style: _mono(gross ? 44 : 30, farbe: kAccent, gewicht: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _EinkaufBlock extends ConsumerWidget {
  final Liste liste;
  final bool gross;
  const _EinkaufBlock({required this.liste, required this.gross});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alle = ref.watch(alleEintraegeProvider).value ?? const <Listeneintrag>[];
    final offen = sortiereEintraege(alle.where((e) => e.listId == liste.id && e.doneAt == null).toList());
    return _Block(
      label: '// ${liste.name}',
      gross: gross,
      child: offen.isEmpty
          ? _leer('Nichts auf der Liste.', gross)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in offen.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(Icons.check_box_outline_blank, size: gross ? 26 : 20, color: kTextMuted),
                        const SizedBox(width: 12),
                        Expanded(child: Text(e.inhalt, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: gross ? 24 : 18, color: kTextStrong))),
                      ],
                    ),
                  ),
                if (offen.length > 8) _mehr(offen.length - 8, gross),
              ],
            ),
    );
  }
}
