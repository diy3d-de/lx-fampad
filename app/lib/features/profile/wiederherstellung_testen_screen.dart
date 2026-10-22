// Profil > Verschlüsselung > Wiederherstellung testen: Prüft, dass sich die Sicherung wirklich öffnen lässt, ohne etwas zu verändern (data/crypto/wiederherstellungstest.dart).
// Wege: Wiederherstellungsschlüssel, Passwort der Passwort-Sicherung, Passkey. Dazu der Schalter der Erinnerung alle 90 Tage (rein lokal). Eingaben nur in BildschirmSchutz.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/wiederherstellungstest.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';

String _datum(DateTime t) => DateFormat('d. MMM yyyy', 'de_DE').format(t.toLocal());

String _wegText(PruefWeg w) => switch (w) {
  PruefWeg.wiederherstellungsschluessel => 'mit dem Wiederherstellungsschlüssel',
  PruefWeg.passwort => 'mit dem Passwort der Passwort-Sicherung',
  PruefWeg.passkey => 'mit dem Passkey',
};

/// "zuletzt getestet am …" oder "noch nie getestet" (für Zeilen und Karten).
String testZeitText(TestStand t) {
  final z = t.zuletzt;
  return z == null ? 'noch nie getestet' : 'zuletzt getestet am ${_datum(z)}${t.weg == null ? '' : ' ${_wegText(t.weg!)}'}';
}

class WiederherstellungTestenScreen extends ConsumerStatefulWidget {
  const WiederherstellungTestenScreen({super.key});

  @override
  ConsumerState<WiederherstellungTestenScreen> createState() => _WiederherstellungTestenScreenState();
}

class _WiederherstellungTestenScreenState extends ConsumerState<WiederherstellungTestenScreen> with AktionsZustand<WiederherstellungTestenScreen> {
  final _schluessel = TextEditingController();
  final _passwort = TextEditingController();
  String? _bestanden;
  String? _hinweis;

  @override
  void dispose() {
    _schluessel.clear();
    _passwort.clear();
    _schluessel.dispose();
    _passwort.dispose();
    super.dispose();
  }

  WiederherstellungsPruefung get _p => ref.read(wiederherstellungsPruefungProvider);

  Future<void> _lauf(String bestanden, Future<void> Function() test) async {
    setState(() {
      _bestanden = null;
      _hinweis = null;
    });
    final ok = await ausfuehren(test);
    if (ok && mounted) {
      setState(() => _bestanden = bestanden);
      _schluessel.clear();
      _passwort.clear();
    }
  }

  Future<void> _mitSchluessel() => _lauf('Test bestanden: Dein Wiederherstellungsschlüssel öffnet die Sicherung, und sie gehört zu deinem aktuellen Schlüssel.', () async {
    if (_schluessel.text.trim().isEmpty) throw const EingabeFehler('Bitte gib deinen Wiederherstellungsschlüssel ein.');
    final r = await mitStepUp(context, ref, () async {
      await _p.mitWiederherstellungsschluessel(_schluessel.text);
      return true;
    });
    if (r != true) throw const EingabeFehler('Der Test wurde nicht abgeschlossen. Bestätige mit Passkey oder Code, um fortzufahren.');
  });

  Future<void> _mitPasswort() => _lauf('Test bestanden: Dein Passwort öffnet die Passwort-Sicherung, und sie gehört zu deinem aktuellen Schlüssel.', () async {
    if (_passwort.text.isEmpty) throw const EingabeFehler('Bitte gib das Passwort deiner Passwort-Sicherung ein.');
    final r = await mitStepUp(context, ref, () async {
      await _p.mitPasswort(_passwort.text);
      return true;
    });
    if (r != true) throw const EingabeFehler('Der Test wurde nicht abgeschlossen. Bestätige mit Passkey oder Code, um fortzufahren.');
  });

  Future<void> _mitPasskey() async {
    var unterstuetzt = true;
    await _lauf('Test bestanden: Dein Passkey öffnet die Passkey-Sicherung, und sie gehört zu deinem aktuellen Schlüssel.', () async {
      unterstuetzt = await _p.mitPasskey();
    });
    if (!unterstuetzt && mounted) {
      setState(() => _hinweis = 'Dein Passkey-Speicher unterstützt diese Funktion auf diesem Gerät nicht. Es wurde nichts verändert.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(e2eeProvider);
    final stand = ref.watch(testStandProvider).value ?? const TestStand();
    final hatSchluessel = s.hatSicherung && s.wiederherstellungAm != null;
    final hatPw = s.pwBestaetigtAm != null && !s.pwSicherungVeraltet;
    final hatPasskey = s.prfCredentialIds.isNotEmpty && (ref.watch(authProvider.select((a) => (a.me?.passkeys ?? 0) > 0)));
    return BildschirmSchutz(
      child: AuthSeite(
        label: '// wiederherstellung testen',
        titel: 'Wiederherstellung testen',
        maxBreite: kMaxContentWidth,
        kinder: [
          const Text(
            'Eine Sicherung hilft nur, wenn sie sich wirklich öffnen lässt. Der Test holt sie vom Server, öffnet sie mit dem, was du eingibst, und vergleicht sie mit deinem aktuellen Schlüssel. '
            'Er verändert nichts: dein Schlüssel und deine Sicherungen bleiben, wie sie sind. Die App erinnert dich alle 90 Tage daran; das bleibt auf diesem Gerät.',
            style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          Text(testZeitText(stand), style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
          const SizedBox(height: 16),
          if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
          if (_hinweis != null) ...[MeldungsBox(_hinweis!), const SizedBox(height: 12)],
          if (_bestanden != null) ...[MeldungsBox(_bestanden!, fehler: false), const SizedBox(height: 12)],
          if (!hatSchluessel && !hatPw && !hatPasskey)
            const MeldungsBox(
              'Es gibt noch keine bestätigte Sicherung, die sich testen ließe. Lege zuerst eine an (Profil > Bin ich abgesichert?).',
              fehler: false,
            ),
          if (hatSchluessel) ...[
            const MonoLabel('// wiederherstellungsschlüssel'),
            const SizedBox(height: 8),
            TextField(
              controller: _schluessel,
              enabled: !laeuft,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontFamily: kFontMono, fontSize: 15, letterSpacing: 1.2, color: kAccent),
              decoration: const InputDecoration(labelText: 'Wiederherstellungsschlüssel', hintText: 'XXXX-XXXX-XXXX-…'),
            ),
            const SizedBox(height: 4),
            const Text(
              'Der Server meldet den Abruf deinen anderen Geräten als Sicherheitshinweis: das ist bei einem Test normal.',
              style: TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
            ),
            const SizedBox(height: 8),
            HauptKnopf(text: 'Mit Wiederherstellungsschlüssel testen', icon: Icons.key_outlined, laeuft: laeuft, onPressed: _mitSchluessel),
            const SizedBox(height: 20),
          ],
          if (hatPw) ...[
            const MonoLabel('// passwort-sicherung'),
            const SizedBox(height: 8),
            TextField(
              controller: _passwort,
              enabled: !laeuft,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Passwort der Passwort-Sicherung'),
            ),
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Mit Passwort testen', icon: Icons.password, onPressed: laeuft ? null : _mitPasswort),
            const SizedBox(height: 20),
          ],
          if (hatPasskey) ...[
            const MonoLabel('// passkey-sicherung'),
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Mit Passkey testen', icon: Icons.fingerprint, onPressed: laeuft ? null : _mitPasskey),
            const SizedBox(height: 20),
          ],
          const MonoLabel('// erinnerung'),
          const SizedBox(height: 4),
          SwitchListTile(
            value: stand.erinnerungAn,
            onChanged: laeuft ? null : (v) => ausfuehren(() => _p.erinnerungSetzen(v)),
            contentPadding: EdgeInsets.zero,
            title: const Text('Alle 90 Tage an den Test erinnern', style: TextStyle(fontSize: 14)),
            subtitle: const Text('Nur ein Hinweis in dieser App, ohne Server und ohne Benachrichtigung.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ),
        ],
      ),
    );
  }
}
