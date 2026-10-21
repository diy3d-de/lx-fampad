// Passwort und Zwei-Faktor (TOTP) nachträglich einrichten, ändern oder entfernen (alles mit Step-up).
// Einrichten in zwei Stufen wie bei der Einladung: Passwort eingeben -> QR/Schlüssel anzeigen und mit dem 6-stelligen Code bestätigen.
// Entfernen geht nur, solange noch ein Passkey als Zugang bleibt (Server: 409 last_credential).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/qr_anzeige.dart';
import '../auth/step_up.dart';

enum _Modus { uebersicht, passwortFeld, totp }

class PasswordScreen extends ConsumerStatefulWidget {
  const PasswordScreen({super.key});

  @override
  ConsumerState<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends ConsumerState<PasswordScreen> with AktionsZustand<PasswordScreen> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _code = TextEditingController();
  _Modus _modus = _Modus.uebersicht;

  /// Schritt 1 erledigt: Schlüssel zum Bestätigen (nur im Speicher, nie auf der Platte).
  PasswordStart? _start;

  /// Nach Erfolg gilt der neue Stand sofort, auch wenn das Neuladen von /me scheitert oder noch läuft (null = Stand aus /me).
  bool? _passwortLokal;

  @override
  void dispose() {
    for (final c in [_pw, _pw2, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  void _pruefePasswort() {
    if (_pw.text.length < 12) throw const EingabeFehler('Das Passwort braucht mindestens 12 Zeichen.');
    if (_pw.text != _pw2.text) throw const EingabeFehler('Die beiden Passwörter sind nicht gleich.');
  }

  void _zurueck() => setState(() {
    _modus = _Modus.uebersicht;
    _start = null;
    _pw.clear();
    _pw2.clear();
    _code.clear();
    fehler = null;
  });

  /// Lädt /me neu und prüft, ob der erwartete Stand angekommen ist. Scheitert das Neuladen, gilt lokal der erwartete Stand
  /// (Knöpfe passen dazu) und die Person bekommt einen Hinweis. Gibt zurück, ob die Anzeige aktuell ist.
  Future<bool> _nachErfolg({required bool hatPasswort}) async {
    _passwortLokal = hatPasswort;
    try {
      await ref.read(authProvider.notifier).neuLaden();
    } catch (_) {
      // wie ein Fehlschlag behandeln: unten wird der Stand geprüft
    }
    final me = ref.read(authProvider).me;
    final aktuell = me != null && me.hasPassword == hatPasswort;
    if (aktuell) _passwortLokal = null;
    return aktuell;
  }

  String _hinweis(String text, bool aktuell) => aktuell ? text : '$text Die Anzeige wird beim nächsten Laden aktualisiert.';

  Future<void> _einrichtenStart() async {
    PasswordStart? start;
    final ok = await ausfuehren(() async {
      _pruefePasswort();
      start = await mitStepUp(context, ref, () => ref.read(apiProvider).passwortEinrichtenStart(_pw.text));
    });
    if (ok && start != null && mounted) {
      // das Passwort wird nicht mehr gebraucht (der Server hält nur den Hash)
      _pw.clear();
      _pw2.clear();
      setState(() {
        _start = start;
        _modus = _Modus.totp;
      });
    }
  }

  Future<void> _einrichtenFertig() async {
    var erledigt = false;
    var aktuell = true;
    final ok = await ausfuehren(() async {
      if (!RegExp(r'^\d{6}$').hasMatch(_code.text)) throw const EingabeFehler('Bitte gib den 6-stelligen Code aus der Authenticator-App ein.');
      final id = _start!.challengeId;
      final fertig = await mitStepUp<bool>(context, ref, () async {
        await ref.read(apiProvider).passwortEinrichtenFertig(challengeId: id, code: _code.text);
        return true;
      });
      erledigt = fertig == true;
      if (erledigt) aktuell = await _nachErfolg(hatPasswort: true);
    });
    if (ok && erledigt && mounted) {
      _zurueck();
      zeigeHinweis(context, _hinweis('Passwort und Zwei-Faktor sind eingerichtet.', aktuell));
    }
  }

  Future<void> _aendern() async {
    var erledigt = false;
    var aktuell = true;
    final ok = await ausfuehren(() async {
      _pruefePasswort();
      final fertig = await mitStepUp<bool>(context, ref, () async {
        await ref.read(apiProvider).passwortAendern(_pw.text);
        return true;
      });
      erledigt = fertig == true;
      if (erledigt) aktuell = await _nachErfolg(hatPasswort: true);
    });
    if (ok && erledigt && mounted) {
      _zurueck();
      zeigeHinweis(context, _hinweis('Passwort geändert.', aktuell));
    }
  }

  Future<void> _entfernen() async {
    var aktuell = true;
    final ja = await showDialog<bool>(useRootNavigator: false,
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Passwort entfernen?'),
        content: const Text('Passwort und Zwei-Faktor (TOTP) werden gelöscht. Du meldest dich danach nur noch mit Passkey an.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Abbrechen')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: kDanger),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (ja != true || !mounted) return;
    var erledigt = false;
    final ok = await ausfuehren(() async {
      final fertig = await mitStepUp<bool>(context, ref, () async {
        await ref.read(apiProvider).passwortEntfernen();
        return true;
      });
      erledigt = fertig == true;
      if (erledigt) aktuell = await _nachErfolg(hatPasswort: false);
    });
    if (ok && erledigt && mounted) {
      zeigeHinweis(context, _hinweis('Passwort und Zwei-Faktor wurden entfernt.', aktuell));
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider.select((s) => s.me));
    final hatPasswort = _passwortLokal ?? (me != null && me.hasPassword);
    final Widget inhalt = switch (_modus) {
      _Modus.totp => _totpStufe(_start!),
      _Modus.passwortFeld => _passwortFeld(hatPasswort),
      _Modus.uebersicht => _uebersicht(me, hatPasswort),
    };
    // Zurück in der Übersicht verlässt den Screen; in den Stufen geht es erst zur Übersicht (und leert Passwort und Code)
    return PopScope(
      canPop: !laeuft && _modus == _Modus.uebersicht,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !laeuft) _zurueck();
      },
      child: BildschirmSchutz(
        child: AuthSeite(label: '// zugänge', titel: 'Passwort & Zwei-Faktor', maxBreite: kMaxContentWidth, kinder: [inhalt]),
      ),
    );
  }

  Widget _uebersicht(MeDto? me, bool aktiv) {
    final passkeys = me?.passkeys ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Mit Passwort und einem Code aus einer Authenticator-App (TOTP) kannst du dich auch ohne Passkey anmelden, '
          'zum Beispiel an einem fremden Gerät.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        LxCard(
          child: Row(
            children: [
              const Icon(Icons.verified_user_outlined, color: kAccent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  me == null ? 'wird geladen …' : (aktiv ? 'Passwort und Authenticator sind eingerichtet' : 'Noch nicht eingerichtet'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (aktiv) const RollenPille('an', farbe: kTerminal),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (me != null && !aktiv)
          HauptKnopf(text: 'Passwort einrichten', icon: Icons.add, onPressed: laeuft ? null : () => setState(() => _modus = _Modus.passwortFeld)),
        if (aktiv) ...[
          HauptKnopf(text: 'Passwort ändern', icon: Icons.edit_outlined, onPressed: laeuft ? null : () => setState(() => _modus = _Modus.passwortFeld)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: laeuft || passkeys == 0 ? null : _entfernen,
            style: OutlinedButton.styleFrom(
              foregroundColor: kDanger,
              side: BorderSide(color: passkeys == 0 ? kBorder : kDanger),
              minimumSize: const Size.fromHeight(48),
            ),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Passwort und Zwei-Faktor entfernen', textAlign: TextAlign.center),
          ),
          if (passkeys == 0) ...[
            const SizedBox(height: 8),
            const Text(
              'Entfernen geht erst, wenn du einen Passkey eingerichtet hast: Sonst bliebe kein Zugang übrig.',
              style: TextStyle(fontSize: 12, color: kTextMuted),
            ),
          ],
        ],
        const SizedBox(height: 8),
        const Text(
          'Zum Einrichten, Ändern und Entfernen bestätigst du noch einmal mit einem bestehenden Zugang.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }

  Widget _passwortFeld(bool aendern) => AutofillGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          aendern
              ? 'Neues Passwort mit mindestens 12 Zeichen. Der Authenticator bleibt unverändert.'
              : 'Passwort mit mindestens 12 Zeichen. Im nächsten Schritt richtest du den Authenticator (TOTP) ein.',
          style: const TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        TextField(
          controller: _pw,
          obscureText: true,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(labelText: aendern ? 'Neues Passwort (mind. 12 Zeichen)' : 'Passwort (mind. 12 Zeichen)'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pw2,
          obscureText: true,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.newPassword],
          onSubmitted: (_) => aendern ? _aendern() : _einrichtenStart(),
          decoration: const InputDecoration(labelText: 'Passwort wiederholen'),
        ),
        const SizedBox(height: 16),
        HauptKnopf(text: aendern ? 'Passwort ändern' : 'Weiter zum Authenticator', laeuft: laeuft, onPressed: aendern ? _aendern : _einrichtenStart),
        const SizedBox(height: 8),
        Center(child: LinkKnopf('Abbrechen', onPressed: laeuft ? null : _zurueck)),
      ],
    ),
  );

  Widget _totpStufe(PasswordStart start) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Align(
        alignment: Alignment.centerLeft,
        child: RollenPille('authenticator einrichten', farbe: kNeural),
      ),
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
      CodeFeld(controller: _code, label: 'Code aus der Authenticator-App', onSubmitted: (_) => _einrichtenFertig()),
      const SizedBox(height: 12),
      HauptKnopf(text: 'Bestätigen und einrichten', laeuft: laeuft, onPressed: _einrichtenFertig),
      const SizedBox(height: 8),
      Center(
        child: LinkKnopf('zurück', icon: Icons.arrow_back, onPressed: laeuft ? null : _zurueck),
      ),
    ],
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
