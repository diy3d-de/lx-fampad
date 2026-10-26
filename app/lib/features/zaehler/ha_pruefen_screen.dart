// Prüfliste "Zu prüfen" (Zähler, Abschnitt 6l): Werte aus Home Assistant, die die App nicht ungefragt einträgt (Stand kleiner als der letzte, Sprung). Die Person entscheidet je Wert mit einer
// Antwort: "Der Zähler wurde getauscht" (der vorhandene Dialog "Zähler wechseln"), "Wert stimmt, trotzdem eintragen" oder "Wert verwerfen". Über den Antworten steht der Zusammenhang (der
// Stand davor und der neue Wert). Ein Wert bleibt beim Server (höchstens 30 Tage), bis er entschieden ist; nichts davon landet ungeprüft in den Kurven. Der Ladekreis dreht sich nur am
// gedrückten Knopf. Nur Eltern und Admins; nie auf der Startseite oder in Push.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/ingest/ingest_dienst.dart' show IngestPruefEintrag;
import '../../data/ingest/ingest_logik.dart' show PruefGrund, paketLoeschInTagen, paketLoeschText;
import '../../data/ingest/ingest_state.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart' show tagKurz;
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'ha_verbindung_screen.dart' show haFehlerText;
import 'zaehler_anzeige.dart';
import 'zaehler_editor.dart' show zaehlerWechselOeffnen;

Future<void> haPruefenOeffnen(BuildContext context) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const HaPruefenScreen()));
}

/// Der erklärende Satz zu einem vorgelegten Wert (nur Zahlen und Namen der eigenen Zähler).
String haPruefText(IngestPruefEintrag e) {
  final einheit = e.einheit;
  String zahl(int m) => '${standAnzeige(m)} $einheit'.trim();
  return switch (e.grund) {
    PruefGrund.kleiner => 'Neuer Stand ${zahl(e.milli)} liegt unter dem letzten (${zahl(e.davorMilli ?? 0)}).',
    PruefGrund.hoeherAlsSpaeter => 'Der Stand ${zahl(e.milli)} ist höher als ein späterer, schon eingetragener Stand.',
    PruefGrund.sprung => 'Sprung um +${zahl(e.tagesVerbrauchMilli ?? 0)} an einem Tag (üblich: ${zahl(e.ueblichMilli ?? 0)}).',
    PruefGrund.ungueltig => 'Home Assistant hat einen Stand geschickt, der keine gültige Zahl ist ("${e.standText ?? ''}"). Er wurde nicht eingetragen.',
  };
}

/// Die Frage über den Antworten.
String haPruefFrage(PruefGrund g) => switch (g) {
  PruefGrund.kleiner => 'Der neue Wert ist kleiner. Was ist passiert?',
  PruefGrund.hoeherAlsSpaeter => 'Der Wert passt nicht zur Reihenfolge der Stände. Was ist passiert?',
  PruefGrund.sprung => 'Der Verbrauch ist an diesem Tag ungewöhnlich hoch. Stimmt der Wert?',
  PruefGrund.ungueltig => 'Das lässt sich nicht eintragen. Der Wert bleibt beim Server, bis du ihn verwirfst (höchstens 30 Tage).',
};

enum _Aktion { eintragen, neuerZaehler, verwerfen }

class HaPruefenScreen extends ConsumerStatefulWidget {
  const HaPruefenScreen({super.key});

  @override
  ConsumerState<HaPruefenScreen> createState() => _HaPruefenScreenState();
}

class _HaPruefenScreenState extends ConsumerState<HaPruefenScreen> {
  String? _fehler;

  /// Welcher Wert und welche Antwort gerade laufen (nur dieser Knopf zeigt den Ladekreis, alle anderen sind solange gesperrt).
  ({String paketId, _Aktion aktion})? _laeuft;

  Future<void> _ausfuehren(IngestPruefEintrag e, _Aktion aktion, Future<void> Function() tun) async {
    if (_laeuft != null) return;
    setState(() {
      _laeuft = (paketId: e.paketId, aktion: aktion);
      _fehler = null;
    });
    try {
      await tun();
      if (mounted) setState(() => _laeuft = null);
    } on Object catch (x) {
      if (mounted) {
        setState(() {
          _laeuft = null;
          _fehler = haFehlerText(x);
        });
      }
    }
  }

  Future<void> _neuerZaehler(IngestPruefEintrag e) async {
    final reihe = ref.read(zaehlerDatenProvider).reihe(e.zaehlerId);
    if (reihe == null) {
      setState(() => _fehler = 'Diesen Zähler gibt es nicht mehr.');
      return;
    }
    final ok = await zaehlerWechselOeffnen(context, ref, reihe.id, datum: e.tag, startMilli: e.milli);
    if (!ok || !mounted) return;
    // der Wechsel hat den Wert als Startstand geschrieben: das Päckchen ist erledigt
    await _ausfuehren(e, _Aktion.neuerZaehler, () => ref.read(ingestProvider.notifier).erledigt(e));
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(zaehlerDarfProvider)) {
      return const AuthSeite(titel: 'Nicht verfügbar', maxBreite: kMaxContentWidth, kinder: [EmptyState(icon: Icons.lock_outline, title: 'Nicht verfügbar', hint: 'Diesen Bereich gibt es für dich nicht.')]);
    }
    final liste = ref.watch(ingestProvider.select((z) => z.zuPruefen));
    final daten = ref.watch(zaehlerDatenProvider);
    return AuthSeite(
      label: 'Home Assistant',
      titel: 'Zu prüfen',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
        if (liste.isEmpty) const EmptyState(icon: Icons.check_circle_outline, title: 'Nichts zu prüfen', hint: 'Alle Werte aus Home Assistant sind eingetragen oder verworfen.'),
        for (final e in liste) ...[
          _PruefKarte(
            eintrag: e,
            name: daten.eintrag(e.zaehlerId)?.inhalt?.name ?? 'Zähler',
            laeuft: _laeuft != null && _laeuft!.paketId == e.paketId ? _laeuft!.aktion : null,
            sperre: _laeuft != null,
            onEintragen: () => unawaited(_ausfuehren(e, _Aktion.eintragen, () => ref.read(ingestProvider.notifier).pruefEintragen(e))),
            onNeuerZaehler: () => unawaited(_neuerZaehler(e)),
            onVerwerfen: () => unawaited(_ausfuehren(e, _Aktion.verwerfen, () => ref.read(ingestProvider.notifier).verwerfen(e))),
          ),
          const SizedBox(height: 12),
        ],
        if (liste.isNotEmpty) const Text('Nichts davon landet ungeprüft in deinen Kurven. Ein Wert bleibt hier, bis du entscheidest (beim Server höchstens 30 Tage).', style: TextStyle(fontSize: 12, color: kTextMuted)),
      ],
    );
  }
}

class _PruefKarte extends StatelessWidget {
  final IngestPruefEintrag eintrag;
  final String name;
  final _Aktion? laeuft;
  final bool sperre;
  final VoidCallback onEintragen;
  final VoidCallback onNeuerZaehler;
  final VoidCallback onVerwerfen;
  const _PruefKarte({required this.eintrag, required this.name, required this.laeuft, required this.sperre, required this.onEintragen, required this.onNeuerZaehler, required this.onVerwerfen});

  @override
  Widget build(BuildContext context) {
    final e = eintrag;
    final titel = '$name · ${tagKurz(e.tag)}';
    final kleiner = e.grund == PruefGrund.kleiner;
    final ungueltig = e.grund == PruefGrund.ungueltig;
    final loesch = paketLoeschInTagen(e.empfangen, DateTime.now());
    String zahl(int m) => '${standAnzeige(m)} ${e.einheit}'.trim();
    Widget antwort(String text, _Aktion a, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: sperre ? null : onTap,
        child: laeuft == a ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(text, textAlign: TextAlign.center),
      ),
    );
    final getauscht = antwort('Der Zähler wurde getauscht', _Aktion.neuerZaehler, onNeuerZaehler);
    final stimmt = antwort('Wert stimmt, trotzdem eintragen', _Aktion.eintragen, onEintragen);
    final verwerfen = antwort(kleiner ? 'Home Assistant wurde zurückgesetzt – Wert verwerfen' : 'Wert verwerfen', _Aktion.verwerfen, onVerwerfen);
    return Semantics(
      container: true,
      label: '$titel. ${haPruefText(e)}${loesch == null ? '' : ' ${paketLoeschText(loesch)}.'}',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kSurface, border: Border.all(color: kWarn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(titel, style: const TextStyle(fontWeight: FontWeight.w700, color: kWarn)),
            const SizedBox(height: 6),
            Text(haPruefText(e), style: const TextStyle(fontSize: 13)),
            if (e.davorMilli != null && !ungueltig) ...[
              const SizedBox(height: 8),
              ExcludeSemantics(
                child: Wrap(
                  spacing: 16,
                  runSpacing: 2,
                  children: [
                    Text('Davor: ${zahl(e.davorMilli!)}', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted)),
                    Text('Neu: ${zahl(e.milli)}', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kWarn)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(haPruefFrage(e.grund), style: const TextStyle(fontSize: 12, color: kTextMuted)),
            if (loesch != null) ...[
              const SizedBox(height: 6),
              Text(paketLoeschText(loesch), style: const TextStyle(fontSize: 12, color: kWarn, fontWeight: FontWeight.w600)),
            ],
            if (ungueltig) verwerfen else if (kleiner) ...[getauscht, verwerfen, stimmt] else ...[stimmt, verwerfen, getauscht],
          ],
        ),
      ),
    );
  }
}
