// "Jetzt nach neuer Datei suchen" (Eltern/Admins): fordert beim Server eine Prüfung an. Der API-Dienst ruft nie bei Dritten ab; der Abruf-
// Dienst des Servers holt die Anforderung im nächsten Takt (ca. 1 Minute). Die Oberfläche zeigt den Ablauf ehrlich: "Prüfung angefordert",
// dann nach der Rückmeldung "2027: gefunden, 118 Termine", "2027: noch nicht verfügbar (geprüft um 07:05)" oder "2027: Quelle nicht erreichbar".
// Die Rückmeldung kommt per kurzem Polling von `GET /waste` und nur, solange diese Seite offen ist. Nur feste Texte, nie ein Servertext.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/muell/muell_logik.dart';
import '../../data/muell/muell_state.dart';

/// Freundlicher Hinweis bei zu häufigem Drücken (der Server erlaubt eine Anforderung je 10 Minuten).
const kMuellZuOftText = 'Bitte etwas später erneut versuchen.';

/// So viele Abfragen wartet die Seite auf die Rückmeldung (bei 5 s ca. 3 Minuten), danach steht ein Hinweis.
const kMuellPruefMaxAbfragen = 36;

class MuellPruefenBlock extends ConsumerStatefulWidget {
  const MuellPruefenBlock({super.key});

  @override
  ConsumerState<MuellPruefenBlock> createState() => _MuellPruefenBlockState();
}

enum _Phase { ruhig, wartet, fertig, zuOft, fehler, zuLange }

class _MuellPruefenBlockState extends ConsumerState<MuellPruefenBlock> {
  _Phase _phase = _Phase.ruhig;
  DateTime? _vorherLetzte;
  Timer? _timer;
  var _abfragen = 0;

  @override
  void initState() {
    super.initState();
    // Eine schon angeforderte Prüfung (auch von einem anderen Gerät): auf das Ergebnis warten
    final st = ref.read(muellProvider);
    if (st.dto?.pruefung.angefordert ?? false) {
      _vorherLetzte = st.dto!.pruefung.letzte;
      _phase = _Phase.wartet;
      _warten();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _warten() {
    _timer?.cancel();
    _abfragen = 0;
    _timer = Timer.periodic(ref.read(muellPruefAbfrageProvider), (_) => unawaited(_nachfragen()));
  }

  Future<void> _nachfragen() async {
    if (!mounted) return;
    _abfragen++;
    await ref.read(muellProvider.notifier).aktualisieren();
    if (!mounted) return;
    final p = ref.read(muellProvider).dto?.pruefung;
    final fertig = p != null && !p.angefordert && p.letzte != null && p.letzte != _vorherLetzte;
    if (fertig) {
      _timer?.cancel();
      setState(() => _phase = _Phase.fertig);
    } else if (_abfragen >= kMuellPruefMaxAbfragen) {
      _timer?.cancel();
      setState(() => _phase = _Phase.zuLange);
    }
  }

  Future<void> _anfordern() async {
    _vorherLetzte = ref.read(muellProvider).dto?.pruefung.letzte;
    setState(() => _phase = _Phase.wartet);
    final r = await ref.read(muellProvider.notifier).pruefenAnfordern();
    if (!mounted) return;
    switch (r) {
      case MuellAnfrage.angefordert:
        _warten();
      case MuellAnfrage.zuOft:
        setState(() => _phase = _Phase.zuOft);
      case MuellAnfrage.fehlgeschlagen:
        setState(() => _phase = _Phase.fehler);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dto = ref.watch(muellProvider.select((z) => z.dto));
    final wartet = _phase == _Phase.wartet;
    final jahr = muellHeute(ref.watch(muellUhrProvider)()).year; // Jahr der Familienzone, nicht des Geräts
    final status = switch (_phase) {
      _Phase.wartet => 'Prüfung angefordert. Der Server prüft gleich, das dauert höchstens eine Minute.',
      _Phase.zuOft => kMuellZuOftText,
      _Phase.fehler => 'Die Prüfung konnte nicht angefordert werden. Bitte versuche es später noch einmal.',
      _Phase.zuLange => 'Der Server hat die Prüfung noch nicht abgeholt. Sieh später noch einmal nach.',
      _ => null,
    };
    final ergebnis = _phase == _Phase.fertig && dto != null
        ? <String>[
            // die Prüfung gilt dem laufenden und dem nächsten Jahr
            muellJahrErgebnis(dto, jahr),
            muellJahrErgebnis(dto, jahr + 1),
          ]
        : const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: OutlinedButton.icon(
            onPressed: wartet ? null : () => unawaited(_anfordern()),
            icon: wartet ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.search, size: 18),
            label: const Text('Jetzt nach neuer Datei suchen'),
          ),
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(liveRegion: true, child: Text(status, style: TextStyle(fontSize: 13, color: _phase == _Phase.wartet ? kTextMuted : kWarn))),
          ),
        for (final z in ergebnis)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(liveRegion: true, child: Text(z, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kText))),
          ),
      ],
    );
  }
}
