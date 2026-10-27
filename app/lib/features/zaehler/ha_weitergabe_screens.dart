// Home Assistant, Mehrgeräte-Weitergabe (Zähler, Abschnitt 6l): der Schlüssel für die Werte aus Home Assistant liegt nur auf dem Gerät, das die Verbindung gekoppelt hat (Abholgerät).
// (1) Auf dem Abholgerät: QR-Code und Code für ein weiteres EIGENES Gerät zeigen (2 Minuten gültig, einmal einlösbar). (2) Auf dem weiteren Gerät: QR scannen (nur Android) oder Code
// abtippen; danach holt auch dieses Gerät ab. Nur für Eltern und Admins. Beide Seiten zeigen Geheimnisse und laufen unter `BildschirmSchutz` (FLAG_SECURE); die Zwischenablage nur auf
// Klick (nach 60 Sekunden geleert, wenn noch derselbe Text darin steht). Der Server reicht nur einen verschlüsselten Blob weiter und sieht nie ein Geheimnis. Nie Code, Schlüssel oder
// Werte in Meldungen; nur feste Texte aus [WeitergabeFehler].
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/ingest/ingest_state.dart';
import '../../data/ingest/ingest_weitergabe.dart';
import '../../data/ingest/ingest_zwischenablage.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/qr_anzeige.dart';
import '../profile/geraet_verbinden_screens.dart' show UebertragungScanScreen;

/// Meldung zu einem Fehler der Weitergabe (nie ein Servertext).
String haWeitergabeFehlerText(Object e) => e is WeitergabeFehler ? e.text : 'Das hat nicht geklappt. Bitte versuche es noch einmal.';

/// Öffnet die Seite für das Abholgerät (nur Eltern und Admins; für alle anderen passiert nichts).
Future<void> haWeitergabeAnbietenOeffnen(BuildContext context) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const HaWeitergabeAnbietenScreen()));
}

/// Öffnet die Seite für das weitere Gerät. Liefert true, wenn dieses Gerät danach abholt.
Future<bool?> haWeitergabeUebernehmenOeffnen(BuildContext context) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const HaWeitergabeUebernehmenScreen()));
}

/// Abholgerät: zeigt QR-Code und Code für ein weiteres Gerät.
class HaWeitergabeAnbietenScreen extends ConsumerStatefulWidget {
  const HaWeitergabeAnbietenScreen({super.key});

  @override
  ConsumerState<HaWeitergabeAnbietenScreen> createState() => _HaWeitergabeAnbietenScreenState();
}

class _HaWeitergabeAnbietenScreenState extends ConsumerState<HaWeitergabeAnbietenScreen> {
  WeitergabeAnzeige? _anzeige;
  String? _fehler;
  var _laeuft = false;
  Timer? _takt;
  Duration _rest = Duration.zero;

  /// Restzeit nach Ticks des Timers (läuft auch ohne Wanduhr); gezeigt wird das Kleinere von Ticks und Frist des Servers.
  Duration _ticks = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_erzeugen()));
  }

  @override
  void dispose() {
    _takt?.cancel();
    _anzeige = null; // der Code gehört nur dieser Anzeige
    super.dispose();
  }

  Future<void> _erzeugen() async {
    if (_laeuft) return;
    _takt?.cancel();
    setState(() {
      _anzeige = null;
      _laeuft = true;
      _fehler = null;
    });
    try {
      final a = await ref.read(ingestProvider.notifier).weitergabeAnbieten();
      if (!mounted) return;
      setState(() {
        _anzeige = a;
        _laeuft = false;
        _ticks = _restVon(a);
        _rest = _ticks;
      });
      _takt = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _anzeige == null) return;
        _ticks -= const Duration(seconds: 1);
        final wand = _restVon(_anzeige!);
        final rest = wand < _ticks ? wand : _ticks;
        setState(() => _rest = rest);
        if (rest <= Duration.zero) _takt?.cancel();
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _laeuft = false;
          _fehler = haWeitergabeFehlerText(e);
        });
      }
    }
  }

  Duration _restVon(WeitergabeAnzeige a) => a.gueltigBis.difference(DateTime.now());

  String get _restText {
    final s = _rest.inSeconds < 0 ? 0 : _rest.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final a = _anzeige;
    final abgelaufen = a != null && _rest <= Duration.zero;
    return BildschirmSchutz(
      child: AuthSeite(
        label: 'Home Assistant',
        titel: 'Auf weiterem Gerät abholen',
        kinder: [
          const Text(
            'Öffne auf deinem anderen Gerät Zähler › Home Assistant und wähle „Auf diesem Gerät auch abholen“. Scanne dann den QR-Code oder tippe den Code ab. '
            'Danach holt auch dieses Gerät die Werte ab. Der Code gilt zwei Minuten und nur einmal. Zeige ihn niemandem, der nicht dein eigenes Gerät ist.',
            style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
          if (_laeuft && a == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (a != null && !abgelaufen) ...[
            QrAnzeige(daten: a.qrText, beschreibung: 'QR-Code zum Abholen der Werte auf einem weiteren Gerät', groesse: 240),
            const SizedBox(height: 12),
            Center(child: StatusPill('noch $_restText', color: _rest.inSeconds < 30 ? kWarn : kTerminal)),
            const SizedBox(height: 12),
            LxCard(
              child: Semantics(
                label: 'Code zum Abtippen: ${a.codeText.replaceAll('-', ', ')}',
                child: SelectableText(
                  a.codeText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: kFontMono, fontSize: 15, height: 1.6, letterSpacing: 1.2, color: kAccent),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ZweitKnopf(
              text: 'Code kopieren',
              icon: Icons.copy,
              onPressed: () async {
                await ref.read(ingestZwischenablageProvider).kopieren(a.codeText, geheim: true);
                if (context.mounted) zeigeHinweis(context, 'Code kopiert. Er gilt nur zwei Minuten.');
              },
            ),
          ],
          if (abgelaufen) ...[
            const MeldungsBox('Der Code ist abgelaufen.', fehler: false),
            const SizedBox(height: 12),
            HauptKnopf(text: 'Neuen Code anzeigen', icon: Icons.refresh, laeuft: _laeuft, onPressed: _erzeugen),
          ],
          if (a == null && !_laeuft) HauptKnopf(text: 'Erneut versuchen', icon: Icons.refresh, onPressed: _erzeugen),
        ],
      ),
    );
  }
}

/// Weiteres Gerät: QR scannen (Android) oder Code abtippen.
class HaWeitergabeUebernehmenScreen extends ConsumerStatefulWidget {
  const HaWeitergabeUebernehmenScreen({super.key});

  @override
  ConsumerState<HaWeitergabeUebernehmenScreen> createState() => _HaWeitergabeUebernehmenScreenState();
}

class _HaWeitergabeUebernehmenScreenState extends ConsumerState<HaWeitergabeUebernehmenScreen> {
  final _code = TextEditingController();
  String? _fehler;
  var _laeuft = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _uebernehmen(String eingabe) async {
    if (_laeuft) return;
    if (eingabe.trim().isEmpty) {
      setState(() => _fehler = 'Bitte scanne den QR-Code oder gib den Code ein.');
      return;
    }
    setState(() {
      _laeuft = true;
      _fehler = null;
    });
    try {
      await ref.read(ingestProvider.notifier).weitergabeAnnehmen(eingabe);
      if (!mounted) return;
      _code.clear();
      zeigeHinweis(context, 'Dieses Gerät holt jetzt auch die Werte aus Home Assistant ab.');
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _laeuft = false;
          _fehler = haWeitergabeFehlerText(e);
        });
      }
    }
  }

  Future<void> _scannen() async {
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => UebertragungScanScreen(
          praefix: kPostfachQrPraefix,
          pruefer: (t) => PostfachWeitergabe.geheimnisLesen(t),
          label: 'Home Assistant',
          fremdText: 'Das ist kein QR-Code zum Abholen der Werte auf einem weiteren Gerät.',
        ),
      ),
    );
    if (text != null && mounted) await _uebernehmen(text);
  }

  @override
  Widget build(BuildContext context) {
    // Hat dieses Gerät schon ein Postfach, ist die Übernahme gesperrt (der Code würde sonst eingelöst und verworfen)
    final gesperrt = ref.watch(ingestProvider.select((z) => z.postfachDa));
    return BildschirmSchutz(
      child: AuthSeite(
        label: 'Home Assistant',
        titel: 'Auf diesem Gerät auch abholen',
        kinder: gesperrt ? [MeldungsBox(const WeitergabeFehler(WeitergabeFehlerArt.schonAnderes).text, fehler: false)] : [
        const Text(
          'Öffne auf dem Gerät, das die Werte aus Home Assistant schon abholt, Zähler › Home Assistant › „Auf weiterem Gerät abholen“. Scanne dann den QR-Code oder tippe den Code hier ab. '
          'Der Schlüssel wandert verschlüsselt auf dieses Gerät; der Server sieht ihn nie. Danach holen beide Geräte ab, doppelte Werte trägt die App nicht ein.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (!kIsWeb) ...[
          HauptKnopf(text: 'QR-Code scannen', icon: Icons.qr_code_scanner, laeuft: _laeuft, onPressed: _scannen),
          const SizedBox(height: 12),
          const MonoTrenner('── oder code abtippen ──'),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _code,
          enabled: !_laeuft,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontFamily: kFontMono, fontSize: 15, letterSpacing: 1.2, color: kAccent),
          decoration: const InputDecoration(labelText: 'Code (14 Gruppen)', hintText: 'XXXX-XXXX-XXXX-…'),
        ),
        if (_fehler != null) ...[const SizedBox(height: 12), MeldungsBox(_fehler!)],
        const SizedBox(height: 12),
        if (kIsWeb)
          HauptKnopf(text: 'Auf diesem Gerät abholen', icon: Icons.link, laeuft: _laeuft, onPressed: () => _uebernehmen(_code.text))
        else
          ZweitKnopf(text: 'Mit Code abholen', icon: Icons.link, onPressed: _laeuft ? null : () => _uebernehmen(_code.text)),
        ],
      ),
    );
  }
}
