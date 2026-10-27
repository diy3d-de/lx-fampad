// "Neue Verbindung koppeln" (nur Admins, Zähler Abschnitt 6l), Schritt 1 und 2 von 3: Name wählen, bestätigen (Step-up), Verbindung (Einwurf-Token) anlegen, Postfach-Schlüssel und MAC-Geheimnis
// erzeugen und NUR im Schlüsselspeicher dieses Geräts ablegen, danach den Kopplungscode EINMAL anzeigen (in `BildschirmSchutz`). Hauptweg ist "Code kopieren" und in Home Assistant einfügen
// (die Integration hat nur ein Textfeld); der QR-Code ist ein Zusatz für den Fall, dass Home Assistant auf einem anderen Gerät läuft. Die Zwischenablage wird nach 60 Sekunden geleert
// (nur wenn noch derselbe Text darin steht). Vor dem Weitergehen fragt die Seite, ob der Code eingegeben wurde; danach ist er weg und Schritt 3 ("Zähler zuordnen", ha_zuordnen_screen.dart)
// beginnt. Der private Schlüssel verlässt das Gerät nie; dieses Gerät wird zum Abholgerät und merkt sich die Kennung der neuen Verbindung (es holt nur deren Päckchen ab). Hat dieses Gerät
// schon ein Postfach (frühere Verbindung), wird es weiterverwendet: alle Verbindungen derselben Person auf diesem Gerät teilen es. Schließt die Person die Seite, ist der Code weg; dann
// Verbindung trennen und neu koppeln.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show Role;
import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart' show cryptoProviderProvider, schluesselSpeicherProvider;
import '../../data/crypto/schluessel_speicher.dart' show SchluesselSpeicherFehler;
import '../../data/ingest/ingest_kopplung.dart';
import '../../data/ingest/ingest_state.dart';
import '../../data/ingest/ingest_zwischenablage.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/ungespeichert_schutz.dart';
import '../auth/auth_widgets.dart';
import '../auth/qr_anzeige.dart';
import '../auth/step_up.dart';
import 'ha_verbindung_screen.dart' show haFehlerText;
import 'ha_zuordnen_screen.dart';

/// Platzhalter in der Form eines Einwurf-Tokens: damit prüft die Seite Adresse, Schlüssel und Name VOR dem Anlegen der Verbindung, ob sich ein Kopplungscode bauen lässt.
const String _pruefToken = 'fhi_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Future<void> haKoppelnOeffnen(BuildContext context) {
  final c = ProviderScope.containerOf(context);
  if (c.read(authProvider).user?.role != Role.admin || !c.read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const HaKoppelnScreen()));
}

class HaKoppelnScreen extends ConsumerStatefulWidget {
  const HaKoppelnScreen({super.key});

  @override
  ConsumerState<HaKoppelnScreen> createState() => _HaKoppelnScreenState();
}

class _HaKoppelnScreenState extends ConsumerState<HaKoppelnScreen> {
  final _name = TextEditingController(text: 'Home Assistant');
  String? _code;
  String? _fehler;
  var _laeuft = false;
  var _kopiert = false;
  var _codeZeigen = false;

  @override
  void dispose() {
    _name.dispose();
    _code = null; // der Code gehört nur dieser Anzeige
    super.dispose();
  }

  Future<void> _koppeln() async {
    if (_laeuft) return;
    final name = _name.text.trim();
    if (name.isEmpty || name.length > kMaxVerbindungsname) {
      setState(() => _fehler = 'Gib der Verbindung einen Namen (höchstens $kMaxVerbindungsname Zeichen), zum Beispiel „Haus Keller“.');
      return;
    }
    final adresse = ref.read(ingestServerAdresseProvider);
    final uid = ref.read(authProvider).user?.id;
    if (adresse == null || uid == null) {
      setState(() => _fehler = 'Die Serveradresse ist nicht sicher (https). Home Assistant lässt sich so nicht koppeln.');
      return;
    }
    setState(() {
      _laeuft = true;
      _fehler = null;
    });
    final speicher = PostfachSpeicher(ref.read(schluesselSpeicherProvider));
    var neuErzeugt = false;
    String? tokenId; // gesetzt, sobald die Verbindung beim Server angelegt ist
    try {
      final crypto = await ref.read(cryptoProviderProvider.future);
      var s = await speicher.lesen(uid);
      // ein Gerät aus der Zeit vor der Merkliste (Postfach da, keine Verbindungen gemerkt) holte bisher alle Päckchen ab
      final alteGeraet = s != null && await speicher.verbindungen(uid) == null;
      if (s == null) {
        // zuerst lokal sichern, dann beim Server anlegen: ginge danach etwas schief, gäbe es höchstens einen ungenutzten Schlüssel, nie eine Verbindung ohne Schlüssel
        s = PostfachSchluessel.erzeugen(crypto);
        await speicher.schreiben(uid, s);
        neuErzeugt = true;
      }
      // Adresse, Schlüssel und Name prüfen, BEVOR eine Verbindung angelegt wird: scheitert hier etwas, gibt es noch kein Token, das verwaisen könnte
      kopplungscodeBauen(IngestKopplung(url: adresse, token: _pruefToken, postfach: s.oeffentlich, geheimnis: s.geheimnis, name: name));
      if (!mounted) {
        if (neuErzeugt) await speicher.entfernen(uid);
        return;
      }
      final neu = await mitStepUp(context, ref, () => ref.read(apiProvider).ingestTokenAnlegen(name));
      if (neu == null) {
        // abgebrochen: ein eben erst erzeugtes Postfach wird wieder entfernt (es gibt keine Verbindung dazu)
        if (neuErzeugt) await speicher.entfernen(uid);
        if (mounted) setState(() => _laeuft = false);
        return;
      }
      tokenId = neu.eintrag.id;
      // die Kennung der neuen Verbindung merken (dieses Gerät holt nur die Päckchen seiner eigenen Verbindungen ab); ein Gerät aus der Zeit davor bekommt dazu alle Verbindungen der Familie in
      // EINEM Schreibvorgang, kann das nicht gelesen werden, bleibt es ohne Merkliste (holt wie bisher alles ab, nichts geht verloren)
      if (alteGeraet) {
        try {
          final alle = [for (final t in await ref.read(apiProvider).ingestTokens()) t.id, neu.eintrag.id];
          await speicher.verbindungenMerken(uid, alle);
        } on Object {
          // ohne Merkliste weiter
        }
      } else {
        await speicher.verbindungMerken(uid, neu.eintrag.id);
      }
      final code = kopplungscodeBauen(IngestKopplung(url: adresse, token: neu.token, postfach: s.oeffentlich, geheimnis: s.geheimnis, name: name));
      ref.invalidate(ingestVerbindungenProvider);
      await ref.read(ingestProvider.notifier).neuLesen();
      await ref.read(ingestProvider.notifier).schalterSetzen(true); // dieses Gerät holt ab
      if (mounted) {
        setState(() {
          _code = code;
          _laeuft = false;
        });
      }
    } on Object catch (e) {
      var verbindungBleibt = false;
      if (tokenId != null) {
        // Der Fehler kam NACH dem Anlegen der Verbindung: das Token wird widerrufen (best effort), damit keine Verbindung ohne Code und Schlüssel verwaist.
        try {
          await ref.read(apiProvider).ingestTokenWiderrufen(tokenId);
        } on Object {
          verbindungBleibt = true; // nicht widerrufen: die Verbindung lebt, also behält das Gerät auch den Schlüssel dazu (sie lässt sich in der Liste trennen)
          try {
            await speicher.verbindungMerken(uid, tokenId);
          } on Object {
            // ohne Merkliste weiter
          }
        }
      }
      // Ein eben erst erzeugtes Postfach wird nur entfernt, wenn es sonst keine Verbindung dazu gibt (nie ein Schlüssel, den eine lebende Verbindung braucht).
      if (neuErzeugt && !verbindungBleibt) {
        try {
          final gemerkt = (await speicher.verbindungen(uid)) ?? const <String>[];
          if (!gemerkt.any((id) => id != tokenId)) await speicher.entfernen(uid);
        } on Object {
          // bleibt höchstens ein ungenutzter Schlüssel liegen
        }
      }
      if (mounted) {
        setState(() {
          _laeuft = false;
          _fehler = tokenId != null
              ? (verbindungBleibt
                    ? 'Der Kopplungscode ließ sich nicht erzeugen, und die neue Verbindung konnte nicht gleich wieder entfernt werden. Trenne sie in der Liste „Verbindung“ und koppele neu.'
                    : 'Der Kopplungscode ließ sich nicht erzeugen. Die neue Verbindung wurde wieder entfernt, versuche es noch einmal.')
              : (e is SchluesselSpeicherFehler ? 'Der Schlüsselspeicher dieses Geräts ließ sich gerade nicht lesen. Versuche es noch einmal.' : (e is ArgumentError ? 'Der Kopplungscode ließ sich nicht erzeugen.' : haFehlerText(e)));
        });
      }
    }
  }

  Future<void> _kopieren() async {
    final c = _code;
    if (c == null) return;
    await ref.read(ingestZwischenablageProvider).kopieren(c, geheim: true);
    if (mounted) setState(() => _kopiert = true);
  }

  /// "Weiter": erst nachfragen, ob der Code eingegeben wurde (danach ist er weg), dann Schritt 3.
  Future<void> _weiter() async {
    final ja = await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hast du den Code in Home Assistant eingegeben?'),
        content: const Text('Danach ist der Code weg und lässt sich nicht noch einmal anzeigen.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Noch nicht')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Ja, eingegeben')),
        ],
      ),
    );
    if (ja != true || !mounted) return;
    await _codeVerwerfen();
    if (!mounted) return;
    unawaited(Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(builder: (_) => const HaZuordnenScreen(nachKopplung: true))));
  }

  Future<void> _codeVerwerfen() async {
    _code = null;
    await ref.read(ingestZwischenablageProvider).sofortLeeren();
  }

  /// "Es klappt nicht?": mögliche Gründe und der Weg, die Verbindung neu zu koppeln.
  Future<void> _hilfe() async {
    final schliessen = await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Es klappt nicht?'),
        content: const SingleChildScrollView(
          child: Text(
            'Wenn Home Assistant den Code nicht annimmt:\n\n'
            '• Prüfe, ob die Integration „Familyhub“ in Home Assistant installiert ist und Home Assistant danach neu gestartet wurde.\n'
            '• Kopiere den ganzen Code. Er beginnt mit FH1- und hat keine Leerzeichen.\n'
            '• Ist der Code weg oder kaputt, schließe diese Seite, trenne die Verbindung unter Zähler › Home Assistant und koppele neu.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Seite schließen')),
          FilledButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Zurück zum Code')),
        ],
      ),
    );
    if (schliessen != true || !mounted) return;
    await _codeVerwerfen();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    if (code != null) {
      return PopScope(
        canPop: false,
        child: BildschirmSchutz(
          child: AuthSeite(
            label: 'Schritt 2 von 3',
            titel: 'Code in Home Assistant einfügen',
            zurueck: false,
            maxBreite: kMaxContentWidth,
            fussleiste: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(_weiter()), child: const Text('Weiter: Zähler zuordnen')),
            kinder: [
              const Text('Der Code wird nur jetzt angezeigt. Er enthält den Zugang und den Schlüssel zum Prüfen der Werte: Zeig ihn niemandem.', style: TextStyle(color: kTextMuted)),
              const SizedBox(height: 14),
              const LxCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Schritt(nr: 1, text: 'Tippe auf „Code kopieren“.'),
                    _Schritt(nr: 2, text: 'Öffne Home Assistant (App oder Browser): Einstellungen › Geräte & Dienste › Integration hinzufügen › Familyhub.'),
                    _Schritt(nr: 3, text: 'Füge den Code ins Feld „Kopplungscode“ ein und wähle die Sensoren.'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => unawaited(_kopieren()),
                icon: Icon(_kopiert ? Icons.check : Icons.copy, size: 18),
                label: Text(_kopiert ? 'Kopiert' : 'Code kopieren'),
              ),
              const SizedBox(height: 8),
              const Text('Die Zwischenablage wird nach 60 Sekunden geleert.', style: TextStyle(fontSize: 12, color: kTextMuted)),
              const SizedBox(height: 14),
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft),
                onPressed: () => setState(() => _codeZeigen = !_codeZeigen),
                icon: Icon(_codeZeigen ? Icons.expand_less : Icons.qr_code_2, size: 18),
                label: Text(_codeZeigen ? 'QR-Code und Text ausblenden' : 'Home Assistant auf einem anderen Gerät? QR-Code zeigen'),
              ),
              if (_codeZeigen) ...[
                const Text('Scanne den QR-Code dort mit der Kamera und kopiere den Text in Home Assistant.', style: TextStyle(fontSize: 12, color: kTextMuted)),
                const SizedBox(height: 10),
                QrAnzeige(daten: code, beschreibung: 'Kopplungscode für Home Assistant als QR-Code', groesse: 280),
                const SizedBox(height: 14),
                LxCard(
                  child: Semantics(
                    label: 'Kopplungscode als Text. Länge ${code.length} Zeichen.',
                    child: ExcludeSemantics(child: SelectableText(code, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, height: 1.4))),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft), onPressed: () => unawaited(_hilfe()), child: const Text('Es klappt nicht?')),
            ],
          ),
        ),
      );
    }
    final fremde = ref.watch(ingestFremdeVerbindungenProvider).value ?? const [];
    return UngespeichertSchutz(
      geaendert: () => _name.text.trim() != 'Home Assistant',
      aenderungen: _name,
      child: AuthSeite(
        label: 'Schritt 1 von 3',
        titel: 'Neue Verbindung',
        maxBreite: kMaxContentWidth,
        fussleiste: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: _laeuft ? null : () => unawaited(_koppeln()), child: Text(_laeuft ? 'Einen Moment …' : 'Weiter')),
        kinder: [
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
          if (fremde.isNotEmpty) ...[
            Semantics(
              container: true,
              label: 'Hinweis: Es gibt schon eine Verbindung auf einem anderen Gerät.',
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: kWarn.withValues(alpha: 0.08), border: Border.all(color: kWarn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(18)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Es gibt schon eine Verbindung auf einem anderen Gerät', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      '${fremde.length == 1 ? '„${fremde.first.name}“ wurde' : '${fremde.map((v) => '„${v.name}“').join(', ')} wurden'} auf einem anderen Gerät gekoppelt. Nur dieses Gerät kann die zugehörigen Werte öffnen. '
                      'Koppelst du hier, holt dieses Gerät nur die Werte der neuen Verbindung ab. Am besten koppelst du neue Verbindungen auf dem Gerät, das schon abholt, dann landen alle Werte an einer Stelle.',
                      style: const TextStyle(fontSize: 13, color: kTextMuted),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],
          const Text('Du bestätigst gleich mit Passkey oder Code. Danach erzeugt dieses Gerät den Schlüssel für die Werte aus Home Assistant und zeigt dir den Kopplungscode einmal an. Der private Schlüssel bleibt auf diesem Gerät; abholen kann nur dieses Gerät, bis du weitere eigene Geräte unter Zähler › Home Assistant dafür freigibst.', style: TextStyle(color: kTextMuted)),
          const SizedBox(height: 14),
          TextField(controller: _name, maxLength: kMaxVerbindungsname, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Name der Verbindung (zum Beispiel Haus Keller)', counterText: '')),
        ],
      ),
    );
  }
}

class _Schritt extends StatelessWidget {
  final int nr;
  final String text;
  const _Schritt({required this.nr, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 24, child: Text('$nr.', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, color: kTextMuted))),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
