// Profil > Verschlüsselung > Passwort-Sicherung (vereinfachte Schlüsselverwaltung, nur wenn der Server sie anbietet): Passwort wählen (Mindeststärke,
// Vorschlag aus Zufallswörtern, Bestätigung) und den Personenschlüssel damit sichern; auf einem Gerät ohne Schlüssel damit wieder verbinden.
// Passwort und Vorschlag nur in BildschirmSchutz (FLAG_SECURE), Zwischenablage nur auf Klick. Der alte Weg (Wiederherstellungsschlüssel, QR) bleibt
// unverändert daneben gültig.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/crypto_fehler.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/pw_regeln.dart';
import '../../data/crypto/wortliste.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import 'geraet_verbinden_screens.dart';

/// Ein Passwortfeld mit Auge (Standard verdeckt).
class _PwFeld extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool verdeckt;
  final bool aktiv;
  final TextInputAction aktion;
  final VoidCallback? onSubmitted;
  const _PwFeld({
    required this.controller,
    required this.label,
    required this.verdeckt,
    required this.aktiv,
    this.aktion = TextInputAction.next,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: aktiv,
    obscureText: verdeckt,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: aktion,
    autofillHints: const [AutofillHints.newPassword],
    onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
    decoration: InputDecoration(labelText: label),
  );
}

class PwSicherungScreen extends ConsumerStatefulWidget {
  const PwSicherungScreen({super.key});

  @override
  ConsumerState<PwSicherungScreen> createState() => _PwSicherungScreenState();
}

class _PwSicherungScreenState extends ConsumerState<PwSicherungScreen> with AktionsZustand<PwSicherungScreen> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _verdeckt = true;

  @override
  void initState() {
    super.initState();
    _pw.addListener(() => setState(() {}));
    _pw2.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  List<PasswortProblem> get _probleme {
    final user = ref.read(authProvider).user;
    return passwortPruefen(_pw.text, email: user?.email, anzeigename: user?.displayName);
  }

  bool get _bereit => _pw.text.isNotEmpty && _probleme.isEmpty && _pw.text == _pw2.text;

  Future<void> _vorschlag() async {
    await ausfuehren(() async {
      final crypto = await ref.read(cryptoProviderProvider.future);
      final woerter = await ref.read(wortlisteProvider.future);
      final user = ref.read(authProvider).user;
      var v = passwortVorschlag(crypto, woerter);
      // ein Vorschlag, der die eigenen Regeln verletzt (z. B. Kontodaten), wird nie angeboten
      for (var i = 0; i < 20 && passwortPruefen(v, email: user?.email, anzeigename: user?.displayName).isNotEmpty; i++) {
        v = passwortVorschlag(crypto, woerter);
      }
      _pw.text = v;
      _pw2.text = v;
      if (mounted) setState(() => _verdeckt = false);
    });
  }

  Future<void> _sichern() async {
    final pw = _pw.text;
    final ok = await ausfuehren(() async {
      // erst einen Frame zeichnen lassen: die Ableitung (Argon2id) blockiert im Web den Hauptthread
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final c = ref.read(e2eeProvider.notifier);
      final entwurf = await c.pwSicherungVorbereiten(pw);
      if (!mounted) return;
      final fertig = await mitStepUp(context, ref, () => c.pwSicherungAblegen(entwurf, pw));
      if (fertig != true) throw const EingabeFehler('Die Passwort-Sicherung wurde nicht abgelegt. Bestätige mit Passkey oder Code, um sie zu speichern.');
    });
    if (ok && mounted) {
      zeigeHinweis(context, 'Passwort-Sicherung angelegt und geprüft.');
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final probleme = _probleme;
    final zeigeProbleme = _pw.text.isNotEmpty && probleme.isNotEmpty;
    final stimmtNicht = _pw2.text.isNotEmpty && _pw.text != _pw2.text;
    return BildschirmSchutz(
      child: AuthSeite(
        label: '// passwort-sicherung',
        titel: 'Passwort-Sicherung',
        kinder: [
          if (ref.watch(e2eeProvider.select((s) => s.pwSicherungVeraltet))) ...[
            const MeldungsBox(
              'Dein Passwort wurde zurückgesetzt, deshalb ist die bisherige Passwort-Sicherung veraltet. Lege sie hier mit einem Passwort neu an '
              '(zum Beispiel deinem neuen Anmelde-Passwort). Bis dahin gilt dein Wiederherstellungsschlüssel unverändert.',
              fehler: false,
            ),
            const SizedBox(height: 12),
          ],
          const Text(
            'Dein Verschlüsselungsschlüssel wird mit einem Passwort geschützt auf dem Server abgelegt. Mit diesem Passwort verbindest du später ein neues Gerät, '
            'ohne Wiederherstellungsschlüssel oder QR-Code. Der Server sieht das Passwort nie. Vergisst du es, kann es niemand wiederherstellen: '
            'dein Wiederherstellungsschlüssel und verbundene Geräte funktionieren weiter wie bisher.',
            style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
          AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PwFeld(controller: _pw, label: 'Passwort (mind. $kPasswortMindestlaenge Zeichen)', verdeckt: _verdeckt, aktiv: !laeuft),
                const SizedBox(height: 12),
                _PwFeld(
                  controller: _pw2,
                  label: 'Passwort wiederholen',
                  verdeckt: _verdeckt,
                  aktiv: !laeuft,
                  aktion: TextInputAction.done,
                  onSubmitted: _bereit && !laeuft ? _sichern : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: LinkKnopf(
              _verdeckt ? 'Passwort anzeigen' : 'Passwort verbergen',
              icon: _verdeckt ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              onPressed: laeuft ? null : () => setState(() => _verdeckt = !_verdeckt),
            ),
          ),
          if (zeigeProbleme)
            for (final p in probleme)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(p.meldung, style: const TextStyle(fontSize: 13, height: 1.4, color: kWarn)),
              ),
          if (stimmtNicht) const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('Die beiden Passwörter sind nicht gleich.', style: TextStyle(fontSize: 13, color: kWarn))),
          const SizedBox(height: 8),
          ZweitKnopf(text: 'Passwort vorschlagen', icon: Icons.casino_outlined, onPressed: laeuft ? null : _vorschlag),
          const SizedBox(height: 4),
          const Text(
            'Der Vorschlag besteht aus fünf zufälligen Wörtern, leicht zu merken und schwer zu erraten. Schreibe ihn auf oder speichere ihn im Passwortmanager.',
            style: TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
          ),
          if (_pw.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            ZweitKnopf(
              text: 'Passwort kopieren',
              icon: Icons.copy,
              onPressed: laeuft ? null : () => inZwischenablage(context, _pw.text, 'Passwort kopiert. Lege es sicher ab und lösche es aus der Zwischenablage.', geheim: true),
            ),
          ],
          const SizedBox(height: 16),
          HauptKnopf(text: 'Sicherung anlegen und prüfen', icon: Icons.lock_outline, laeuft: laeuft, onPressed: _bereit ? _sichern : null),
          if (laeuft) ...[
            const SizedBox(height: 8),
            const Text('Das Ableiten des Schlüssels und die zweifache Prüfung dauern einen Moment.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
        ],
      ),
    );
  }
}

/// Gerät ohne Schlüssel mit dem Passwort der Passwort-Sicherung verbinden.
class PwVerbindenScreen extends ConsumerStatefulWidget {
  const PwVerbindenScreen({super.key});

  @override
  ConsumerState<PwVerbindenScreen> createState() => _PwVerbindenScreenState();
}

class _PwVerbindenScreenState extends ConsumerState<PwVerbindenScreen> with AktionsZustand<PwVerbindenScreen> {
  final _pw = TextEditingController();
  bool _verdeckt = true;

  @override
  void initState() {
    super.initState();
    _pw.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  bool _veraltet = false;

  Future<void> _verbinden() async {
    final pw = _pw.text;
    final ok = await ausfuehren(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final c = ref.read(e2eeProvider.notifier);
      if (!mounted) return;
      final fertig = await mitStepUp(context, ref, () async {
        _veraltet = await c.mitPasswortVerbinden(pw);
        return true;
      });
      if (fertig != true) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Das Gerät wurde nicht verbunden. Bestätige mit Passkey oder Code.');
    });
    if (ok && mounted) {
      if (_veraltet) {
        // Passwort-Reset: Die alte Sicherung hat geöffnet. Jetzt gleich die Erneuerung anbieten (mit einem neuen Passwort).
        zeigeHinweis(context, 'Gerät verbunden. Erneuere jetzt deine Passwort-Sicherung.');
        unawaited(Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(builder: (_) => const PwSicherungScreen())));
      } else {
        zeigeHinweis(context, 'Gerät verbunden.');
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final veraltet = ref.watch(e2eeProvider.select((s) => s.pwSicherungVeraltet));
    final hatSicherung = ref.watch(e2eeProvider.select((s) => s.hatSicherung));
    return _seite(veraltet, hatSicherung);
  }

  Widget _seite(bool veraltet, bool hatSicherung) => BildschirmSchutz(
    child: AuthSeite(
      label: '// passwort',
      titel: 'Mit Passwort verbinden',
      kinder: [
        if (veraltet) ...[
          const MeldungsBox(
            'Dein Anmelde-Passwort wurde zurückgesetzt. Deine alte Passwort-Sicherung funktioniert noch mit dem Passwort, mit dem du sie angelegt hast. '
            'Hast du es vergessen, nimm den Wiederherstellungsschlüssel oder ein anderes Gerät.',
            fehler: false,
          ),
          const SizedBox(height: 12),
        ],
        const Text(
          'Gib das Passwort ein, mit dem du deine Passwort-Sicherung angelegt hast. Es ist nicht automatisch dein Anmelde-Passwort.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        TextField(
          controller: _pw,
          enabled: !laeuft,
          obscureText: _verdeckt,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _pw.text.isEmpty || laeuft ? null : _verbinden(),
          decoration: InputDecoration(
            labelText: 'Passwort der Sicherung',
            suffixIcon: IconButton(
              tooltip: _verdeckt ? 'Passwort anzeigen' : 'Passwort verbergen',
              icon: Icon(_verdeckt ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _verdeckt = !_verdeckt),
            ),
          ),
        ),
        const SizedBox(height: 16),
        HauptKnopf(text: 'Verbinden', icon: Icons.link, laeuft: laeuft, onPressed: _pw.text.isEmpty ? null : _verbinden),
        if (hatSicherung) ...[
          const SizedBox(height: 8),
          ZweitKnopf(
            text: 'Mit Wiederherstellungsschlüssel verbinden',
            icon: Icons.key_outlined,
            onPressed: laeuft ? null : () => Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(builder: (_) => const WiederherstellungVerbindenScreen())),
          ),
        ],
        const SizedBox(height: 8),
        ZweitKnopf(
          text: 'Mit anderem Gerät verbinden',
          icon: Icons.qr_code_scanner,
          onPressed: laeuft ? null : () => Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(builder: (_) => const GeraetVerbindenScreen())),
        ),
      ],
    ),
  );
}
