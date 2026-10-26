// "Passwort vergessen?": ein neues Passwort festlegen, ohne das alte zu kennen. Nur mit einem Notfall-Code oder mit einem Passkey, nie mit dem
// Code der Authenticator-App allein. Das neue Passwort verlässt das Gerät nie (nur der abgeleitete authKey). Dein Verlauf bleibt nur erhalten, wenn du ein Gerät
// mit deinem Schlüssel oder deinen Wiederherstellungsschlüssel hast (die Seite sagt es so, nicht pauschal); auf einem Gerät mit deinem Schlüssel legt die App danach selbst eine neue Passwort-Sicherung an.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/auth/passwort_reset.dart';
import '../../data/auth/reset_hinweis.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/push/sicherheits_pruefer.dart';
import '../../ui/widgets.dart';
import 'auth_widgets.dart';

class PasswortVergessenScreen extends ConsumerStatefulWidget {
  /// E-Mail aus dem Anmeldefeld (spart das erneute Tippen).
  final String? email;
  const PasswortVergessenScreen({super.key, this.email});

  @override
  ConsumerState<PasswortVergessenScreen> createState() => _PasswortVergessenScreenState();
}

class _PasswortVergessenScreenState extends ConsumerState<PasswortVergessenScreen> with AktionsZustand<PasswortVergessenScreen> {
  late final _email = TextEditingController(text: widget.email ?? '');
  final _code = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _mitPasskey = false;
  bool? _passkeysDa;

  @override
  void initState() {
    super.initState();
    unawaited(
      ref.read(passkeyServiceProvider).verfuegbar().then((v) {
        if (mounted) setState(() => _passkeysDa = v);
      }),
    );
  }

  @override
  void dispose() {
    for (final c in [_email, _code, _pw, _pw2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _los() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final auth = ref.read(authProvider.notifier);
    final e2ee = ref.read(e2eeProvider.notifier);
    final hinweis = ref.read(resetHinweisProvider.notifier);
    final reset = ref.read(passwortResetProvider);
    final pruefer = ref.read(sicherheitsPrueferProvider);
    String? rest;
    final pw = _pw.text;
    final ok = await ausfuehren(() async {
      final mail = _email.text.trim();
      if (!mail.contains('@') || mail.length < 5) throw const EingabeFehler('Bitte gib die E-Mail-Adresse deines Kontos ein.');
      if (!_mitPasskey && _code.text.trim().isEmpty) throw const EingabeFehler('Bitte gib einen Notfall-Code ein.');
      if (pw.length < 12) throw const EingabeFehler('Das neue Passwort braucht mindestens 12 Zeichen.');
      if (pw != _pw2.text) throw const EingabeFehler('Die beiden Passwörter sind nicht gleich.');
      await pruefer.hinweisAbgemeldetLoeschen();
      await auth.mitResetAnmelden(() async {
        final r = _mitPasskey
            ? await reset.vergessenMitPasskey(email: mail, passwort: pw)
            : await reset.vergessenMitCode(email: mail, code: _code.text.trim(), passwort: pw);
        if (!_mitPasskey && r.recoveryCodesRemaining != null) rest = _restText(r.recoveryCodesRemaining!);
        return r;
      });
    });
    if (!ok) return;
    // angemeldet: auf einem Gerät mit Schlüssel eine neue Passwort-Sicherung anlegen (läuft im Hintergrund der Oberfläche)
    unawaited(sicherungNachReset(e2ee, hinweis, pw, pruefer: pruefer));
    navigator.popUntil((r) => r.isFirst);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(['Dein neues Passwort gilt.', ?rest].join(' ')), duration: const Duration(seconds: 8)));
  }

  static String _restText(int n) => n <= 3
      ? 'Du hast nur noch $n Notfall-Codes. Erzeuge unter Profil › Sicherheit bald neue.'
      : 'Du hast noch $n Notfall-Codes.';

  @override
  Widget build(BuildContext context) => BildschirmSchutz(
    child: AuthSeite(
    label: 'Passwort vergessen',
    titel: 'Neues Passwort festlegen',
    maxBreite: kMaxContentWidth,
    kinder: [
      AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Du kommst nicht mehr in dein Konto? Mit einem deiner Notfall-Codes oder mit deinem Passkey legst du ein neues Passwort fest. '
              'Der Code aus der Authenticator-App allein reicht dafür nicht. Dein Verlauf bleibt erhalten, wenn du ein Gerät mit deinem Schlüssel oder deinen Wiederherstellungsschlüssel hast.',
              style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
            ),
            const SizedBox(height: 8),
            const Text(
              'Hast du weder Code noch Passkey, schreibe einem Admin: Er kann dir einen Link zum Zurücksetzen schicken.',
              style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
            ),
            const SizedBox(height: 16),
            if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username, AutofillHints.email],
              decoration: const InputDecoration(labelText: 'E-Mail'),
            ),
            const SizedBox(height: 16),
            const MonoLabel('So bestätigst du dich'),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Code'), icon: Icon(Icons.key_outlined)),
                ButtonSegment(value: true, label: Text('Passkey'), icon: Icon(Icons.fingerprint)),
              ],
              selected: {_mitPasskey},
              onSelectionChanged: laeuft ? null : (s) => setState(() => _mitPasskey = s.first),
            ),
            const SizedBox(height: 12),
            if (_mitPasskey)
              Text(
                _passkeysDa == false
                    ? 'Anmelden ohne Passwort wird auf diesem Gerät oder in diesem Browser nicht unterstützt. Nimm einen Notfall-Code.'
                    : 'Du bestätigst gleich mit Fingerabdruck, Gesicht oder Bildschirmsperre.',
                style: const TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
              )
            else
              TextField(
                controller: _code,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(fontFamily: kFontMono, fontSize: 18, color: kAccent),
                decoration: const InputDecoration(labelText: 'Notfall-Code', hintText: 'XXXX-XXXX-XXXX-XXXX'),
              ),
            const SizedBox(height: 16),
            const MonoLabel('Neues Passwort'),
            const SizedBox(height: 8),
            TextField(
              controller: _pw,
              obscureText: true,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: 'Neues Passwort (mind. 12 Zeichen)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pw2,
              obscureText: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _los(),
              decoration: const InputDecoration(labelText: 'Passwort wiederholen'),
            ),
            const SizedBox(height: 16),
            HauptKnopf(text: 'Neues Passwort festlegen', laeuft: laeuft, onPressed: _los),
          ],
        ),
      ),
    ],
  ),
  );
}
