// Profil › Sicherheit › Nachrichten-Schutz › Passkey-Sicherung (nur wenn der Server sie anbietet und die Person einen Passkey hat): den Schlüssel mit der PRF-Erweiterung des Passkeys
// sichern, und auf einem Gerät ohne Schlüssel damit wieder verbinden. Kein Passwort, kein Zettel: die Geste des Passkeys (Fingerabdruck, Gesicht, PIN) öffnet die Sicherung.
// Ob der Passkey-Speicher PRF kann, entscheidet sich erst auf dem Gerät: ohne Unterstützung sagt die Seite es und verändert nichts; Wiederherstellungsschlüssel, QR-Code und
// Passwort-Sicherung gelten unverändert weiter.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/prf_state.dart';
import '../auth/auth_widgets.dart';
import 'geraet_verbinden_screens.dart';

const _nichtUnterstuetzt =
    'Dein Passkey-Speicher unterstützt diese Funktion auf diesem Gerät nicht (die PRF-Erweiterung fehlt). Es wurde nichts verändert. '
    'Sichere deinen Schlüssel stattdessen mit einem Passwort oder mit dem Wiederherstellungsschlüssel.';

/// Passkey-Sicherung anlegen oder erneuern.
class PrfSicherungScreen extends ConsumerStatefulWidget {
  const PrfSicherungScreen({super.key});

  @override
  ConsumerState<PrfSicherungScreen> createState() => _PrfSicherungScreenState();
}

class _PrfSicherungScreenState extends ConsumerState<PrfSicherungScreen> with AktionsZustand<PrfSicherungScreen> {
  bool _nichtMoeglich = false;

  Future<void> _anlegen() async {
    PrfAnlegen? r;
    final ok = await ausfuehren(() async {
      r = await ref.read(prfSteuerungProvider).sicherungAnlegen();
    });
    if (!ok || !mounted) return;
    if (r == PrfAnlegen.nichtUnterstuetzt) {
      setState(() => _nichtMoeglich = true);
      return;
    }
    zeigeHinweis(context, 'Passkey-Sicherung angelegt und geprüft.');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final veraltet = ref.watch(e2eeProvider.select((s) => s.prfSicherungVeraltet));
    final gesichert = ref.watch(e2eeProvider.select((s) => s.prfCredentialIds.isNotEmpty));
    return AuthSeite(
      label: 'Passkey-sicherung',
      titel: 'Passkey-Sicherung',
      kinder: [
        if (veraltet) ...[
          const MeldungsBox(
            'Dein Schlüssel wurde gewechselt, deshalb ist die bisherige Passkey-Sicherung veraltet. Lege sie hier neu an. Bis dahin gelten deine anderen Wege unverändert.',
            fehler: false,
          ),
          const SizedBox(height: 12),
        ],
        const Text(
          'Dein Schlüssel wird mit einem Geheimnis geschützt, das dein Passkey nie verlässt, und so auf dem Server abgelegt. Auf einem neuen Gerät öffnet dein '
          'Passkey (Fingerabdruck, Gesicht oder PIN) die Sicherung: kein Zettel, kein Passwort. Der Server sieht weder das Geheimnis noch deinen Schlüssel. '
          'Als Absicherung zählt sie nur, wenn dein Passkey-Anbieter ihn als synchronisiert und gesichert meldet und auf deinen anderen Geräten bereithält (zum Beispiel der Google-Passwortmanager; ob das klappt, hängt vom Anbieter ab); ein Passkey, der nur auf diesem Gerät liegt, geht mit dem Gerät verloren. '
          'Geht der Passkey verloren oder wird er neu angelegt, lässt sich die Sicherung nicht mehr öffnen; Wiederherstellungsschlüssel und verbundene Geräte funktionieren weiter wie bisher.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 12),
        const Text(
          'Du bestätigst zweimal mit deinem Passkey: einmal zum Anlegen und einmal, damit die App prüfen kann, dass sich die Sicherung wirklich wieder öffnen lässt.',
          style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        if (_nichtMoeglich) ...[const MeldungsBox(_nichtUnterstuetzt), const SizedBox(height: 12)],
        HauptKnopf(text: gesichert || veraltet ? 'Sicherung erneuern' : 'Mit Passkey sichern', icon: Icons.fingerprint, laeuft: laeuft, onPressed: _anlegen),
        if (laeuft) ...[
          const SizedBox(height: 8),
          const Text('Bestätige mit deinem Passkey, wenn das Gerät danach fragt.', style: TextStyle(fontSize: 12, color: kTextMuted)),
        ],
      ],
    );
  }
}

/// Gerät ohne Schlüssel mit dem Passkey verbinden.
class PrfVerbindenScreen extends ConsumerStatefulWidget {
  const PrfVerbindenScreen({super.key});

  @override
  ConsumerState<PrfVerbindenScreen> createState() => _PrfVerbindenScreenState();
}

class _PrfVerbindenScreenState extends ConsumerState<PrfVerbindenScreen> with AktionsZustand<PrfVerbindenScreen> {
  String? _hinweis;

  Future<void> _verbinden() async {
    PrfVerbinden? r;
    final ok = await ausfuehren(() async {
      r = await ref.read(prfSteuerungProvider).mitPasskeyVerbinden();
    });
    if (!ok || !mounted) return;
    switch (r) {
      case PrfVerbinden.verbunden:
        zeigeHinweis(context, 'Gerät verbunden.');
        Navigator.of(context).pop();
      case PrfVerbinden.nichtUnterstuetzt:
        setState(() => _hinweis = _nichtUnterstuetzt);
      case PrfVerbinden.keineSicherung:
        setState(() => _hinweis = 'Zu diesem Passkey gibt es keine Passkey-Sicherung. Wähle einen anderen Passkey oder nimm eine andere Möglichkeit.');
      case PrfVerbinden.passtNicht:
        setState(() => _hinweis = 'Dieser Passkey öffnet die Sicherung nicht (er wurde vermutlich neu angelegt). Nimm den Wiederherstellungsschlüssel oder ein anderes Gerät.');
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hatSicherung = ref.watch(e2eeProvider.select((s) => s.hatSicherung));
    return AuthSeite(
      label: 'Passkey',
      titel: 'Mit Passkey verbinden',
      kinder: [
        const Text(
          'Bestätige mit dem Passkey, mit dem du deine Passkey-Sicherung angelegt hast. Er öffnet deinen Schlüssel auf diesem Gerät.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        if (_hinweis != null) ...[MeldungsBox(_hinweis!), const SizedBox(height: 12)],
        HauptKnopf(text: 'Mit Passkey verbinden', icon: Icons.fingerprint, laeuft: laeuft, onPressed: _verbinden),
        if (hatSicherung) ...[
          const SizedBox(height: 8),
          ZweitKnopf(
            text: 'Mit Wiederherstellungsschlüssel verbinden',
            icon: Icons.key_outlined,
            onPressed: laeuft ? null : () => unawaited(Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(builder: (_) => const WiederherstellungVerbindenScreen()))),
          ),
        ],
        const SizedBox(height: 8),
        ZweitKnopf(
          text: 'Mit anderem Gerät verbinden',
          icon: Icons.qr_code_scanner,
          onPressed: laeuft ? null : () => unawaited(Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(builder: (_) => const GeraetVerbindenScreen()))),
        ),
      ],
    );
  }
}
