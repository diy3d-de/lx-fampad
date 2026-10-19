// Wiederherstellungsschlüssel einmalig anzeigen, per Abfrage zweier zufälliger Gruppen bestätigen lassen und erst dann die Sicherung
// beim Server ablegen. Bildschirmfoto-Schutz (FLAG_SECURE) und Zwischenablage nur auf Klick wie bei den Wiederherstellungscodes.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/crypto/code32.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/wiederherstellung.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';

class WiederherstellungsschluesselScreen extends ConsumerStatefulWidget {
  final Einrichtung einrichtung;

  /// true: neuer Schlüssel für einen schon eingerichteten Personenschlüssel (ersetzt die bisherige Sicherung).
  final bool ersatz;
  const WiederherstellungsschluesselScreen({super.key, required this.einrichtung, this.ersatz = false});

  @override
  ConsumerState<WiederherstellungsschluesselScreen> createState() => _WiederherstellungsschluesselScreenState();
}

class _WiederherstellungsschluesselScreenState extends ConsumerState<WiederherstellungsschluesselScreen> with AktionsZustand<WiederherstellungsschluesselScreen> {
  late final List<String> _gruppen = Wiederherstellung.gruppen(widget.einrichtung.wiederherstellungsschluessel);
  late final List<int> _fragen = Wiederherstellung.abfragePositionen(Random.secure());
  final _eingaben = [TextEditingController(), TextEditingController()];

  @override
  void initState() {
    super.initState();
    for (final c in _eingaben) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in _eingaben) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _richtig => [for (var i = 0; i < 2; i++) Wiederherstellung.gruppeStimmt(widget.einrichtung.wiederherstellungsschluessel, _fragen[i], _eingaben[i].text)].every((b) => b);

  Future<void> _fertig() async {
    final ok = await ausfuehren(() async {
      final ergebnis = await mitStepUp(context, ref, () async {
        await ref.read(e2eeProvider.notifier).sicherungAblegen(widget.einrichtung);
        return true;
      });
      if (ergebnis != true) throw const EingabeFehler('Die Sicherung wurde nicht abgelegt. Bestätige mit Passkey oder Code, um sie zu speichern.');
    });
    if (ok && mounted) {
      zeigeHinweis(context, 'Wiederherstellungsschlüssel gesichert.');
      Navigator.of(context).pop();
    }
  }

  Future<void> _spaeter() async {
    final ja = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Später sichern?'),
        content: const Text('Ohne Wiederherstellungsschlüssel verlierst du deinen Schlüssel, wenn du alle Geräte verlierst. Du kannst ihn jederzeit in den Einstellungen erzeugen.'),
        scrollable: true,
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Zurück')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Später')),
        ],
      ),
    );
    if (ja == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false, // erst nach der Bestätigung oder dem ausdrücklichen "Später"
    child: BildschirmSchutz(
      child: AuthSeite(
        zurueck: false,
        label: '// einmalig',
        titel: 'Wiederherstellungsschlüssel',
        kinder: [
          Text(
            widget.ersatz
                ? 'Dein bisheriger Wiederherstellungsschlüssel wird durch diesen ersetzt, sobald du ihn bestätigt hast.'
                : 'Mit diesem Schlüssel stellst du deinen Verschlüsselungsschlüssel wieder her, wenn du alle Geräte verlierst. '
                      'Er wird nur jetzt angezeigt. Wer ihn kennt, kann deine Inhalte lesen: bewahre ihn sicher auf, am besten ausgedruckt oder im Passwortmanager.',
            style: const TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          Semantics(
            label: 'Wiederherstellungsschlüssel in $kCodeGruppen Gruppen: ${_gruppen.map((g) => g.split('').join(' ')).join(', ')}',
            child: LxCard(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _gruppen.length; i++)
                    Container(
                      constraints: const BoxConstraints(minHeight: 44, minWidth: 84),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(10)),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${i + 1}', style: const TextStyle(fontFamily: kFontMono, fontSize: 10, color: kTextFaint)),
                          Text(_gruppen[i], style: const TextStyle(fontFamily: kFontMono, fontSize: 18, letterSpacing: 1.5, color: kAccent)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ZweitKnopf(
            text: 'Schlüssel kopieren',
            icon: Icons.copy,
            onPressed: () => inZwischenablage(
              context,
              Wiederherstellung.anzeigen(widget.einrichtung.wiederherstellungsschluessel),
              'Schlüssel kopiert. Lege ihn sicher ab und lösche ihn aus der Zwischenablage.',
              geheim: true,
            ),
          ),
          const SizedBox(height: 16),
          const MonoLabel('// kontrolle'),
          const SizedBox(height: 8),
          Text(
            'Zur Kontrolle, dass du ihn gesichert hast: Tippe die Gruppen ${_fragen[0] + 1} und ${_fragen[1] + 1} ab.',
            style: const TextStyle(fontSize: 14, height: 1.4, color: kText),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < 2; i++) ...[
            TextField(
              controller: _eingaben[i],
              enabled: !laeuft,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [LengthLimitingTextInputFormatter(5)],
              style: const TextStyle(fontFamily: kFontMono, fontSize: 18, letterSpacing: 2, color: kAccent),
              decoration: InputDecoration(labelText: 'Gruppe ${_fragen[i] + 1}', counterText: ''),
            ),
            const SizedBox(height: 8),
          ],
          if (fehler != null) ...[const SizedBox(height: 4), MeldungsBox(fehler!)],
          const SizedBox(height: 8),
          HauptKnopf(text: 'Gesichert, weiter', laeuft: laeuft, onPressed: _richtig ? _fertig : null),
          const SizedBox(height: 4),
          LinkKnopf('Später sichern', onPressed: laeuft ? null : _spaeter),
        ],
      ),
    ),
  );
}
