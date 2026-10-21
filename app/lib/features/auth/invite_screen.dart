// Einladung annehmen: Link einfügen oder QR scannen (Android) -> Einladung prüfen -> PIN, Name, E-Mail ->
// Passkey anlegen ODER Passwort + TOTP (Secret/QR, Bestätigungscode) -> Wiederherstellungscodes (einmalig) -> App.
// Das Token bleibt im Arbeitsspeicher und geht nur im POST-Body zum Server.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/auth/passwort_anmeldung.dart';
import '../../data/auth/passwort_reset.dart';
import '../../data/auth/reset_hinweis.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/push/sicherheits_pruefer.dart';
import '../../data/crypto/pw_regeln.dart';
import '../../ui/widgets.dart';
import 'app_download.dart';
import 'auth_widgets.dart';
import 'invite_link.dart';
import 'qr_anzeige.dart';
import 'qr_scan_screen.dart';
import 'recovery_codes_screen.dart';

class InviteScreen extends ConsumerStatefulWidget {
  /// Schon bekanntes Token (aus Adresszeile, Intent oder Scan); sonst wird der Link eingegeben.
  final String? token;

  /// Nur für Tests: Browser/Android erzwingen (Standard: echte Plattform).
  final bool? webAndroid;
  final bool? webBrowser;
  const InviteScreen({super.key, this.token, this.webAndroid, this.webBrowser});

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> with AktionsZustand<InviteScreen> {
  final _link = TextEditingController();
  final _pin = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _totpCode = TextEditingController();
  final _resetCode = TextEditingController();

  String? _token;
  InviteLookup? _info;
  bool _mitPasswort = false;
  PasswordStart? _start;

  @override
  void initState() {
    super.initState();
    final t = widget.token;
    if (t != null) WidgetsBinding.instance.addPostFrameCallback((_) => _pruefen(t));
  }

  @override
  void dispose() {
    for (final c in [_link, _pin, _name, _email, _pw, _pw2, _totpCode, _resetCode]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _linkPruefen() async {
    final token = parseInviteToken(_link.text);
    if (token == null) {
      setState(() => fehler = 'Das ist kein gültiger Einladungslink. Er sieht so aus: https://$kInviteHost/#/einladung/…');
      return;
    }
    await _pruefen(token);
  }

  Future<void> _pruefen(String token) async {
    await ausfuehren(() async {
      final info = await ref.read(apiProvider).einladungPruefen(token);
      if (!mounted) return;
      setState(() {
        _token = token;
        _info = info;
        if (info.displayName != null) _name.text = info.displayName!;
        _link.clear(); // der Link soll nicht länger im Feld stehen
      });
    });
  }

  Future<void> _scannen() async {
    final token = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (token != null && mounted) await _pruefen(token);
  }

  /// Prüft die Eingaben des Formulars; wirft [EingabeFehler].
  void _formularPruefen() {
    final info = _info!;
    if (info.pinRequired && !RegExp(r'^\d{6}$').hasMatch(_pin.text)) {
      throw const EingabeFehler('Bitte gib die 6-stellige PIN ein, die du getrennt zur Einladung bekommen hast.');
    }
    if (!info.reset) {
      if (_name.text.trim().isEmpty) throw const EingabeFehler('Bitte gib deinen Anzeigenamen ein.');
      final mail = _email.text.trim();
      if (!mail.contains('@') || mail.length < 5) throw const EingabeFehler('Bitte gib eine gültige E-Mail-Adresse ein.');
    }
  }

  Future<String?> _geraeteLabel() async {
    if (kIsWeb) return 'Browser';
    final n = (await ref.read(systemChannelProvider).geraetename())?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }

  Future<void> _passkeyAnlegen() => ausfuehren(() async {
    _formularPruefen();
    final api = ref.read(apiProvider);
    final info = _info!;
    final ch = await api.passkeyRegistrierungStart(
      token: _token!,
      pin: info.pinRequired ? _pin.text : null,
      email: info.reset ? null : _email.text.trim(),
      anzeigename: info.reset ? null : _name.text.trim(),
    );
    final antwort = await ref.read(passkeyServiceProvider).erstellen(ch.options);
    final r = await api.passkeyRegistrierungFertig(challengeId: ch.challengeId, antwort: antwort, bezeichnung: await _geraeteLabel());
    await _registriert(r);
  });

  Future<void> _passwortStart() => ausfuehren(() async {
    _formularPruefen();
    if (_pw.text.length < 12) throw const EingabeFehler('Das Passwort braucht mindestens 12 Zeichen.');
    if (_pw.text != _pw2.text) throw const EingabeFehler('Die beiden Passwörter sind nicht gleich.');
    final info = _info!;
    // E-Mail des künftigen Kontos (Salt der Ableitung): neu aus dem Formular, bei Reset-Einladung vom Server
    final mail = info.reset ? info.email : _email.text.trim();
    final pa = ref.read(passwortAnmeldungProvider);
    final neu = mail == null || mail.isEmpty ? NeuesPasswort(klartext: _pw.text) : await pa.neuesPasswort(
            mail,
            _pw.text,
            pruefenMitAuthKey: () {
              final probleme = passwortPruefen(_pw.text, email: mail, anzeigename: info.reset ? info.displayName : _name.text.trim());
              if (probleme.isNotEmpty) throw EingabeFehler(probleme.first.meldung);
            },
          );
    final s = await ref
        .read(apiProvider)
        .passwortRegistrierungStart(
          token: _token!,
          passwort: neu.klartext,
          authKey: neu.authKey,
          pin: info.pinRequired ? _pin.text : null,
          email: info.reset ? null : _email.text.trim(),
          anzeigename: info.reset ? null : _name.text.trim(),
        );
    if (mounted) setState(() => _start = s);
  });

  Future<void> _totpBestaetigen() => ausfuehren(() async {
    if (!RegExp(r'^\d{6}$').hasMatch(_totpCode.text)) throw const EingabeFehler('Bitte gib den 6-stelligen Code aus der Authenticator-App ein.');
    final r = await ref.read(apiProvider).passwortRegistrierungFertig(challengeId: _start!.challengeId, code: _totpCode.text);
    await _registriert(r);
  });

  /// Link des Admins "neues Passwort": PIN, neues Passwort und ein Code des vorhandenen Authenticators (der zweite Faktor bleibt Pflicht).
  Future<void> _passwortResetEinloesen() async {
    final auth = ref.read(authProvider.notifier);
    final e2ee = ref.read(e2eeProvider.notifier);
    final hinweis = ref.read(resetHinweisProvider.notifier);
    final pruefer = ref.read(sicherheitsPrueferProvider);
    final navigator = Navigator.of(context);
    final pw = _pw.text;
    final ok = await ausfuehren(() async {
      final info = _info!;
      if (info.pinRequired && !RegExp(r'^\d{6}$').hasMatch(_pin.text)) {
        throw const EingabeFehler('Bitte gib die 6-stellige PIN ein, die du getrennt zum Link bekommen hast.');
      }
      if (pw.length < 12) throw const EingabeFehler('Das Passwort braucht mindestens 12 Zeichen.');
      if (pw != _pw2.text) throw const EingabeFehler('Die beiden Passwörter sind nicht gleich.');
      if (!RegExp(r'^\d{6}$').hasMatch(_resetCode.text)) throw const EingabeFehler('Bitte gib den 6-stelligen Code aus deiner Authenticator-App ein.');
      final mail = info.email;
      if (mail == null || mail.isEmpty) throw const EingabeFehler('Dieser Link kann auf diesem Server gerade nicht eingelöst werden. Bitte frage einen Admin.');
      final r = await ref
          .read(passwortResetProvider)
          .einladungEinloesen(token: _token!, pin: info.pinRequired ? _pin.text : null, email: mail, anzeigename: info.displayName, passwort: pw, code: _resetCode.text);
      await auth.registrierungAbschliessen(r);
    });
    if (!ok) return;
    unawaited(sicherungNachReset(e2ee, hinweis, pw, pruefer: pruefer));
    navigator.popUntil((r) => r.isFirst);
  }

  /// Konto ist angelegt: Wiederherstellungscodes zeigen, erst danach die Sitzung übernehmen.
  Future<void> _registriert(RegistrationResult r) async {
    if (!mounted) return;
    final auth = ref.read(authProvider.notifier);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RecoveryCodesScreen(
          codes: r.recoveryCodes,
          zurWurzel: true,
          weiterText: r.status == MemberStatus.pending ? 'Weiter' : 'Weiter zur App',
          onFertig: () => auth.registrierungAbschliessen(r),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget inhalt;
    if (_start != null) {
      inhalt = _totpStufe(_start!);
    } else if (_info != null && _info!.art == EinladungsArt.passwordReset) {
      inhalt = _resetFormular(_info!);
    } else if (_info != null) {
      inhalt = _formular(_info!);
    } else {
      inhalt = _eingabe();
    }
    // Hinweis auf die App nur im Browser und nur vor dem Registrieren (nicht bei Passwort-/TOTP-Stufe)
    final hinweis = _start == null ? WillkommenAppHinweis(android: widget.webAndroid, istWeb: widget.webBrowser) : null;
    return AuthSeite(label: '// einladung', titel: 'Einladung annehmen', kinder: [?hinweis, inhalt]);
  }

  // ------------------------------------------------------------ Stufe 1: Link

  Widget _eingabe() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Füge den Einladungslink ein, den du bekommen hast'
        '${kIsWeb ? '' : ', oder scanne den QR-Code'}.',
        style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
      ),
      const SizedBox(height: 16),
      if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
      TextField(
        controller: _link,
        minLines: 1,
        maxLines: 3,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _linkPruefen(),
        style: const TextStyle(fontFamily: kFontMono, fontSize: 13),
        decoration: InputDecoration(labelText: 'Einladungslink', hintText: 'https://$kInviteHost/#/einladung/…'),
      ),
      const SizedBox(height: 12),
      HauptKnopf(text: 'Einladung prüfen', laeuft: laeuft, onPressed: _linkPruefen),
      if (!kIsWeb) ...[
        const SizedBox(height: 12),
        ZweitKnopf(text: 'QR-Code scannen', icon: Icons.qr_code_scanner, onPressed: laeuft ? null : _scannen),
      ],
    ],
  );

  // ------------------------------------------------------------ Stufe 2: Formular

  Widget _formular(InviteLookup info) {
    final bis = DateFormat('d. MMM, HH:mm', 'de_DE').format(info.expiresAt.toLocal());
    // AutofillGroup (im Web ein <form>): Passwortmanager bieten ein neues Passwort an und speichern es mit der E-Mail
    return AutofillGroup(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MonoLabel(info.reset ? '// zugang neu einrichten' : '// du bist eingeladen'),
              const SizedBox(height: 8),
              Text(
                info.familyName.isEmpty ? 'Familie' : info.familyName,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: kTextStrong),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  RollenPille(info.role.label),
                  if (info.requireApproval) const RollenPille('freigabe nötig', farbe: kWarn),
                  RollenPille('gültig bis $bis', farbe: kTextMuted),
                ],
              ),
              if (info.reset && info.displayName != null) ...[
                const SizedBox(height: 8),
                Text('Neuer Zugang für ${info.displayName}.', style: const TextStyle(color: kTextMuted)),
              ],
              if (info.requireApproval) ...[
                const SizedBox(height: 8),
                const Text(
                  'Nach der Registrierung gibt ein Admin dein Konto frei. Bis dahin kannst du dich nicht anmelden.',
                  style: TextStyle(fontSize: 13, color: kTextMuted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        if (info.pinRequired) ...[
          CodeFeld(controller: _pin, label: 'PIN der Einladung', verdeckt: true),
          const SizedBox(height: 12),
        ],
        if (!info.reset) ...[
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.words,
            autofillHints: const [AutofillHints.name],
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Anzeigename', counterText: ''),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            decoration: const InputDecoration(labelText: 'E-Mail'),
          ),
          const SizedBox(height: 16),
        ],
        const MonoLabel('// anmeldung einrichten'),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Passkey'), icon: Icon(Icons.fingerprint)),
            ButtonSegment(value: true, label: Text('Passwort'), icon: Icon(Icons.password)),
          ],
          selected: {_mitPasswort},
          onSelectionChanged: laeuft ? null : (s) => setState(() => _mitPasswort = s.first),
        ),
        const SizedBox(height: 12),
        if (!_mitPasswort) ...[
          const Text(
            'Ein Passkey ersetzt das Passwort: Du bestätigst mit Fingerabdruck, Gesicht oder Bildschirmsperre. Empfohlen.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          HauptKnopf(text: 'Passkey anlegen', icon: Icons.fingerprint, laeuft: laeuft, onPressed: _passkeyAnlegen),
        ] else ...[
          const Text(
            'Passwort mit mindestens 12 Zeichen. Zusätzlich richtest du im nächsten Schritt einen Authenticator (TOTP) ein.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pw,
            obscureText: true,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newPassword],
            decoration: const InputDecoration(labelText: 'Passwort (mind. 12 Zeichen)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pw2,
            obscureText: true,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
            onSubmitted: (_) => _passwortStart(),
            decoration: const InputDecoration(labelText: 'Passwort wiederholen'),
          ),
          const SizedBox(height: 12),
          HauptKnopf(text: 'Weiter zum Authenticator', laeuft: laeuft, onPressed: _passwortStart),
        ],
        const SizedBox(height: 8),
        Center(
          child: LinkKnopf(
            'andere Einladung verwenden',
            onPressed: laeuft
                ? null
                : () => setState(() {
                    _info = null;
                    _token = null;
                    fehler = null;
                  }),
          ),
        ),
      ],
    ),
    );
  }

  // ------------------------------------------------------------ Link "neues Passwort"

  Widget _resetFormular(InviteLookup info) {
    final bis = DateFormat('d. MMM, HH:mm', 'de_DE').format(info.expiresAt.toLocal());
    return BildschirmSchutz(
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LxCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MonoLabel('// neues passwort'),
                  const SizedBox(height: 8),
                  Text(
                    info.displayName == null ? 'Neues Passwort festlegen' : 'Neues Passwort für ${info.displayName}',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: kTextStrong),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 6, children: [RollenPille(info.role.label), RollenPille('gültig bis $bis', farbe: kTextMuted)]),
                  const SizedBox(height: 8),
                  const Text(
                    'Du legst ein neues Passwort fest. Zur Sicherheit bestätigst du mit dem aktuellen Code aus deiner Authenticator-App, dass du es bist. '
                    'Dein Chat-Verlauf bleibt erhalten.',
                    style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
            if (info.pinRequired) ...[
              CodeFeld(controller: _pin, label: 'PIN der Einladung', verdeckt: true),
              const SizedBox(height: 12),
            ],
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
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: 'Passwort wiederholen'),
            ),
            const SizedBox(height: 12),
            CodeFeld(controller: _resetCode, label: 'Code aus der Authenticator-App', onSubmitted: (_) => _passwortResetEinloesen()),
            const SizedBox(height: 16),
            HauptKnopf(text: 'Neues Passwort festlegen', laeuft: laeuft, onPressed: _passwortResetEinloesen),
            const SizedBox(height: 8),
            Center(
              child: LinkKnopf(
                'andere Einladung verwenden',
                onPressed: laeuft
                    ? null
                    : () => setState(() {
                        _info = null;
                        _token = null;
                        fehler = null;
                        _resetCode.clear();
                      }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ Stufe 3: TOTP

  Widget _totpStufe(PasswordStart start) => BildschirmSchutz(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(alignment: Alignment.centerLeft, child: RollenPille('authenticator einrichten', farbe: kNeural)),
        const SizedBox(height: 12),
        const Text(
          'Scanne den QR-Code mit einer Authenticator-App (z. B. Aegis, 2FAS oder Google Authenticator) '
          'oder gib den Schlüssel von Hand ein. Danach bestätigst du mit dem 6-stelligen Code.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        QrAnzeige(daten: start.totpUri, beschreibung: 'QR-Code zum Einrichten des Authenticators'),
        const SizedBox(height: 12),
        const MonoLabel('// schlüssel', color: kTextMuted),
        const SizedBox(height: 4),
        Semantics(
          label: 'Schlüssel für die Authenticator-App',
          child: SelectableText(
            _gruppiert(start.totpSecret),
            style: const TextStyle(fontFamily: kFontMono, fontSize: 15, letterSpacing: 1.2, color: kAccent),
          ),
        ),
        const SizedBox(height: 8),
        ZweitKnopf(
          text: 'Schlüssel kopieren',
          icon: Icons.copy,
          onPressed: () => inZwischenablage(context, start.totpSecret, 'Schlüssel kopiert.', geheim: true),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        CodeFeld(controller: _totpCode, label: 'Code aus der Authenticator-App', onSubmitted: (_) => _totpBestaetigen()),
        const SizedBox(height: 12),
        HauptKnopf(text: 'Bestätigen und Konto anlegen', laeuft: laeuft, onPressed: _totpBestaetigen),
        const SizedBox(height: 8),
        Center(
          child: LinkKnopf(
            'zurück',
            icon: Icons.arrow_back,
            onPressed: laeuft
                ? null
                : () => setState(() {
                    _start = null;
                    _totpCode.clear();
                    fehler = null;
                  }),
          ),
        ),
      ],
    ),
  );

  static String _gruppiert(String s) {
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && i % 4 == 0) b.write(' ');
      b.write(s[i]);
    }
    return b.toString();
  }
}
