import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/auth/passwort_anmeldung.dart';
import '../../ui/widgets.dart';
import 'auth_widgets.dart';
import 'invite_screen.dart';

enum _Schritt { start, code, wiederherstellung }

/// Anmeldung wie im Login-Mockup: Passkey-Knopf, Passwort mit zweitem Schritt (Bestätigungscode), Wiederherstellungscode-Weg.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> with AktionsZustand<LoginScreen> {
  final _email = TextEditingController();
  final _passwort = TextEditingController();
  final _code = TextEditingController();
  final _wiederherstellung = TextEditingController();
  _Schritt _schritt = _Schritt.start;

  /// Schritt 2: statt des TOTP-Codes einen Wiederherstellungscode eingeben.
  bool _mitWiederherstellungscode = false;
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
    _email.dispose();
    _passwort.dispose();
    _code.dispose();
    _wiederherstellung.dispose();
    super.dispose();
  }

  AuthController get _auth => ref.read(authProvider.notifier);

  void _zu(_Schritt s) => setState(() {
    _schritt = s;
    fehler = null;
    _code.clear();
    _wiederherstellung.clear();
    _mitWiederherstellungscode = false;
  });

  void _weiter() {
    if (_email.text.trim().isEmpty || _passwort.text.isEmpty) {
      setState(() => fehler = 'Bitte gib E-Mail und Passwort ein.');
      return;
    }
    _zu(_Schritt.code);
  }

  Future<void> _anmeldenMitCode() async {
    final code = _code.text.trim();
    final wc = _wiederherstellung.text.trim();
    if (_mitWiederherstellungscode ? wc.isEmpty : code.length != 6) {
      setState(() => fehler = _mitWiederherstellungscode ? 'Bitte gib einen Wiederherstellungscode ein.' : 'Bitte gib den 6-stelligen Code ein.');
      return;
    }
    final email = _email.text.trim();
    await ausfuehren(
      () => ref.read(passwortAnmeldungProvider).anmelden(
        email: email,
        passwort: _passwort.text,
        senden: ({passwort, authKey, upgradeAuthKey}) => _auth.mitPasswortAnmelden(
          email: email,
          passwort: passwort,
          authKey: authKey,
          upgradeAuthKey: upgradeAuthKey,
          totp: _mitWiederherstellungscode ? null : code,
          wiederherstellungscode: _mitWiederherstellungscode ? wc : null,
        ),
      ),
    );
  }

  Future<void> _nurWiederherstellung() async {
    if (_email.text.trim().isEmpty || _wiederherstellung.text.trim().isEmpty) {
      setState(() => fehler = 'Bitte gib E-Mail und Wiederherstellungscode ein.');
      return;
    }
    await ausfuehren(() => _auth.mitWiederherstellungscodeAnmelden(email: _email.text.trim(), code: _wiederherstellung.text.trim()));
  }

  void _einladung() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const InviteScreen()));

  @override
  Widget build(BuildContext context) {
    final hinweis = ref.watch(authProvider.select((s) => s.hinweis));
    return AuthSeite(
      zurueck: false,
      maxBreite: 420,
      kinder: [
        const SizedBox(height: 24),
        const MarkenKopf(),
        const SizedBox(height: 28),
        if (hinweis != null && fehler == null) ...[MeldungsBox(hinweis, fehler: false), const SizedBox(height: 16)],
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 16)],
        // AutofillGroup (im Web ein <form>): Passwortmanager erkennen Anmeldename und Passwort, und Chrome meldet kein
        // "Password field is not contained in a form" mehr. Beim Verlassen der Seite (erfolgreiche Anmeldung) wird der Kontext gespeichert.
        AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: switch (_schritt) {
              _Schritt.start => _start(),
              _Schritt.code => _codeSchritt(),
              _Schritt.wiederherstellung => _nurWiederherstellungSchritt(),
            },
          ),
        ),
      ],
      fussleiste: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinkKnopf(
            kIsWeb ? 'Einladung annehmen' : 'Einladung per QR-Code annehmen',
            icon: kIsWeb ? Icons.link : Icons.qr_code_scanner,
            onPressed: laeuft ? null : _einladung,
          ),
          StatusPill(serverKennzeile()),
        ],
      ),
    );
  }

  List<Widget> _start() => [
    const _Ueberschrift('Willkommen zurück'),
    const SizedBox(height: 16),
    HauptKnopf(
      text: 'Mit Passkey anmelden',
      icon: Icons.fingerprint,
      laeuft: laeuft,
      onPressed: () => ausfuehren(_auth.mitPasskeyAnmelden),
    ),
    if (_passkeysDa == false) ...[
      const SizedBox(height: 8),
      const Text(
        'Passkeys werden auf diesem Gerät oder in diesem Browser nicht unterstützt. Melde dich mit Passwort und Code an.',
        style: TextStyle(fontSize: 12, color: kTextMuted),
      ),
    ],
    const SizedBox(height: 20),
    const MonoTrenner('oder mit passwort'),
    const SizedBox(height: 20),
    TextField(
      controller: _email,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.username, AutofillHints.email],
      decoration: const InputDecoration(labelText: 'E-Mail'),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _passwort,
      obscureText: true,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.password],
      onSubmitted: (_) => _weiter(),
      decoration: const InputDecoration(labelText: 'Passwort'),
    ),
    const SizedBox(height: 16),
    ZweitKnopf(text: 'Weiter', onPressed: laeuft ? null : _weiter),
    const SizedBox(height: 4),
    Center(
      child: LinkKnopf('Passwort verloren? Mit Wiederherstellungscode anmelden', onPressed: laeuft ? null : () => _zu(_Schritt.wiederherstellung)),
    ),
  ];

  List<Widget> _codeSchritt() => [
    const Align(alignment: Alignment.centerLeft, child: RollenPille('schritt 2 von 2', farbe: kNeural)),
    const SizedBox(height: 12),
    _Ueberschrift(_mitWiederherstellungscode ? 'Wiederherstellungscode' : 'Bestätigungscode'),
    const SizedBox(height: 8),
    Text(
      _mitWiederherstellungscode
          ? 'Gib einen deiner Wiederherstellungscodes ein. Jeder Code gilt nur einmal.'
          : 'Gib den 6-stelligen Code aus deiner Authenticator-App ein.',
      style: const TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
    ),
    const SizedBox(height: 16),
    if (_mitWiederherstellungscode)
      TextField(
        controller: _wiederherstellung,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(fontFamily: kFontMono, fontSize: 18, color: kAccent),
        onSubmitted: (_) => _anmeldenMitCode(),
        decoration: const InputDecoration(labelText: 'Wiederherstellungscode', hintText: 'XXXX-XXXX-XXXX-XXXX'),
      )
    else
      CodeFeld(controller: _code, label: 'Code aus der Authenticator-App', autofocus: true, onSubmitted: (_) => _anmeldenMitCode()),
    const SizedBox(height: 16),
    HauptKnopf(text: 'Anmelden', laeuft: laeuft, onPressed: _anmeldenMitCode),
    const SizedBox(height: 8),
    Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        LinkKnopf('zurück', icon: Icons.arrow_back, onPressed: laeuft ? null : () => _zu(_Schritt.start)),
        LinkKnopf(
          _mitWiederherstellungscode ? 'Code aus der App nutzen' : 'Wiederherstellungscode nutzen',
          onPressed: laeuft
              ? null
              : () => setState(() {
                  _mitWiederherstellungscode = !_mitWiederherstellungscode;
                  fehler = null;
                }),
        ),
      ],
    ),
  ];

  List<Widget> _nurWiederherstellungSchritt() => [
    const _Ueberschrift('Mit Wiederherstellungscode anmelden'),
    const SizedBox(height: 8),
    const Text(
      'Kein Passkey und kein Authenticator zur Hand? Mit E-Mail und einem Wiederherstellungscode kommst du wieder hinein. '
      'Richte danach unter Profil und Sicherheit einen neuen Zugang ein.',
      style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
    ),
    const SizedBox(height: 16),
    TextField(
      controller: _email,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.username, AutofillHints.email],
      decoration: const InputDecoration(labelText: 'E-Mail'),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _wiederherstellung,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.characters,
      style: const TextStyle(fontFamily: kFontMono, fontSize: 18, color: kAccent),
      onSubmitted: (_) => _nurWiederherstellung(),
      decoration: const InputDecoration(labelText: 'Wiederherstellungscode', hintText: 'XXXX-XXXX-XXXX-XXXX'),
    ),
    const SizedBox(height: 16),
    HauptKnopf(text: 'Anmelden', laeuft: laeuft, onPressed: _nurWiederherstellung),
    const SizedBox(height: 8),
    Align(alignment: Alignment.centerLeft, child: LinkKnopf('zurück', icon: Icons.arrow_back, onPressed: laeuft ? null : () => _zu(_Schritt.start))),
  ];
}

class _Ueberschrift extends StatelessWidget {
  final String text;
  const _Ueberschrift(this.text);

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.65, color: kTextStrong)),
  );
}
