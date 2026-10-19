// Neues Gerät verbinden: (1) auf dem vorhandenen Gerät QR-Code und Code zeigen, (2) auf dem neuen Gerät scannen (nur Android) oder abtippen,
// (3) mit dem Wiederherstellungsschlüssel. Alle Screens mit Geheimnissen laufen unter BildschirmSchutz (FLAG_SECURE).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../constants.dart';
import '../../data/crypto/crypto_fehler.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/uebertragung.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/qr_anzeige.dart';
import '../auth/step_up.dart';

/// Vorhandenes Gerät: zeigt QR-Code und Code (2 Minuten gültig, einmal einlösbar).
class UebertragungAnbietenScreen extends ConsumerStatefulWidget {
  const UebertragungAnbietenScreen({super.key});

  @override
  ConsumerState<UebertragungAnbietenScreen> createState() => _UebertragungAnbietenScreenState();
}

class _UebertragungAnbietenScreenState extends ConsumerState<UebertragungAnbietenScreen> with AktionsZustand<UebertragungAnbietenScreen> {
  UebertragungsAnzeige? _anzeige;
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
    super.dispose();
  }

  Future<void> _erzeugen() async {
    _takt?.cancel();
    setState(() => _anzeige = null);
    await ausfuehren(() async {
      final a = await ref.read(e2eeProvider.notifier).uebertragungAnbieten();
      if (!mounted) return;
      setState(() {
        _anzeige = a;
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
    });
  }

  Duration _restVon(UebertragungsAnzeige a) => a.gueltigBis.difference(DateTime.now());

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
        label: '// neues gerät',
        titel: 'Neues Gerät verbinden',
        kinder: [
          const Text(
            'Öffne auf dem neuen Gerät die Verschlüsselung (Profil) und scanne diesen QR-Code oder tippe den Code ab. '
            'Der Code gilt zwei Minuten und nur einmal. Zeige ihn niemandem, der nicht dein neues Gerät ist.',
            style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
          if (laeuft && a == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (a != null && !abgelaufen) ...[
            QrAnzeige(daten: a.qrText, beschreibung: 'QR-Code zum Verbinden eines neuen Geräts', groesse: 240),
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
              onPressed: () => inZwischenablage(context, a.codeText, 'Code kopiert. Er gilt nur zwei Minuten.', geheim: true),
            ),
          ],
          if (abgelaufen) ...[
            const MeldungsBox('Der Code ist abgelaufen.', fehler: false),
            const SizedBox(height: 12),
            HauptKnopf(text: 'Neuen Code anzeigen', icon: Icons.refresh, laeuft: laeuft, onPressed: _erzeugen),
          ],
          if (a == null && !laeuft) ...[
            HauptKnopf(text: 'Erneut versuchen', icon: Icons.refresh, onPressed: _erzeugen),
          ],
        ],
      ),
    );
  }
}

/// Neues Gerät: QR scannen (Android) oder Code abtippen.
class GeraetVerbindenScreen extends ConsumerStatefulWidget {
  const GeraetVerbindenScreen({super.key});

  @override
  ConsumerState<GeraetVerbindenScreen> createState() => _GeraetVerbindenScreenState();
}

class _GeraetVerbindenScreenState extends ConsumerState<GeraetVerbindenScreen> with AktionsZustand<GeraetVerbindenScreen> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verbinden(String eingabe) async {
    final ok = await ausfuehren(() async {
      if (eingabe.trim().isEmpty) throw const EingabeFehler('Bitte scanne den QR-Code oder gib den Code ein.');
      await ref.read(e2eeProvider.notifier).uebertragungAnnehmen(eingabe);
    });
    if (ok && mounted) {
      zeigeHinweis(context, 'Dieses Gerät ist jetzt verbunden.');
      Navigator.of(context).pop();
    }
  }

  Future<void> _scannen() async {
    final text = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _UebertragungScanScreen()));
    if (text != null && mounted) await _verbinden(text);
  }

  @override
  Widget build(BuildContext context) => BildschirmSchutz(
    child: AuthSeite(
      label: '// gerät verbinden',
      titel: 'Mit anderem Gerät verbinden',
      kinder: [
        const Text(
          'Öffne auf einem Gerät, das schon verbunden ist, Profil > Verschlüsselung > Neues Gerät verbinden. Scanne dann den QR-Code oder tippe den Code hier ab.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (!kIsWeb) ...[
          HauptKnopf(text: 'QR-Code scannen', icon: Icons.qr_code_scanner, laeuft: laeuft, onPressed: _scannen),
          const SizedBox(height: 12),
          const MonoTrenner('── oder code abtippen ──'),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _code,
          enabled: !laeuft,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontFamily: kFontMono, fontSize: 15, letterSpacing: 1.2, color: kAccent),
          decoration: const InputDecoration(labelText: 'Code (14 Gruppen)', hintText: 'XXXX-XXXX-XXXX-…'),
        ),
        if (fehler != null) ...[const SizedBox(height: 12), MeldungsBox(fehler!)],
        const SizedBox(height: 12),
        if (kIsWeb)
          HauptKnopf(text: 'Verbinden', icon: Icons.link, laeuft: laeuft, onPressed: () => _verbinden(_code.text))
        else
          ZweitKnopf(text: 'Mit Code verbinden', icon: Icons.link, onPressed: laeuft ? null : () => _verbinden(_code.text)),
      ],
    ),
  );
}

/// Scanner für den QR-Code der Übertragung (nur Android; im Web gibt es nur das Abtippen, weil der Web-Scanner ein CDN bräuchte).
class _UebertragungScanScreen extends StatefulWidget {
  const _UebertragungScanScreen();

  @override
  State<_UebertragungScanScreen> createState() => _UebertragungScanScreenState();
}

class _UebertragungScanScreenState extends State<_UebertragungScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _fertig = false;
  String? _hinweis;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _erkannt(BarcodeCapture capture) {
    if (_fertig || !mounted) return;
    String? hinweis;
    for (final b in capture.barcodes) {
      final text = b.rawValue ?? '';
      if (!text.toUpperCase().startsWith('LXK1:')) continue;
      // Prüfsumme sofort prüfen: ein beschädigter oder fremder Code löst nichts am Server aus
      try {
        Uebertragung.geheimnisLesen(text);
      } on CryptoFehler catch (e) {
        hinweis = e.art == CryptoFehlerArt.pruefsumme ? 'Der QR-Code ist beschädigt oder unvollständig. Bitte scanne ihn noch einmal.' : 'Das ist kein gültiger QR-Code zum Verbinden eines Geräts.';
        continue;
      }
      _fertig = true;
      unawaited(_controller.stop());
      Navigator.of(context).pop(text);
      return;
    }
    if (capture.barcodes.isNotEmpty) {
      final neu = hinweis ?? 'Das ist kein QR-Code zum Verbinden eines Geräts.';
      if (_hinweis != neu) setState(() => _hinweis = neu);
    }
  }

  @override
  Widget build(BuildContext context) => AuthSeite(
    label: '// gerät verbinden',
    titel: 'QR-Code scannen',
    kinder: [
      const Text('Halte die Kamera auf den QR-Code des anderen Geräts.', style: TextStyle(fontSize: 14, color: kTextMuted)),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 320,
          child: MobileScanner(
            controller: _controller,
            onDetect: _erkannt,
            errorBuilder: (context, error) => const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: MeldungsBox('Die Kamera ist nicht verfügbar oder nicht erlaubt. Erlaube den Kamerazugriff in den Einstellungen oder tippe den Code ab.'),
              ),
            ),
          ),
        ),
      ),
      if (_hinweis != null) ...[const SizedBox(height: 12), MeldungsBox(_hinweis!)],
      const SizedBox(height: 12),
      ZweitKnopf(text: 'Code abtippen statt scannen', icon: Icons.keyboard, onPressed: () => Navigator.of(context).pop()),
    ],
  );
}

/// Mit dem Wiederherstellungsschlüssel verbinden (der Abruf der Sicherung verlangt Step-up).
class WiederherstellungVerbindenScreen extends ConsumerStatefulWidget {
  const WiederherstellungVerbindenScreen({super.key});

  @override
  ConsumerState<WiederherstellungVerbindenScreen> createState() => _WiederherstellungVerbindenScreenState();
}

class _WiederherstellungVerbindenScreenState extends ConsumerState<WiederherstellungVerbindenScreen> with AktionsZustand<WiederherstellungVerbindenScreen> {
  final _schluessel = TextEditingController();

  @override
  void dispose() {
    _schluessel.dispose();
    super.dispose();
  }

  Future<void> _verbinden() async {
    final ok = await ausfuehren(() async {
      if (_schluessel.text.trim().isEmpty) throw const EingabeFehler('Bitte gib deinen Wiederherstellungsschlüssel ein.');
      final ergebnis = await mitStepUp(context, ref, () async {
        await ref.read(e2eeProvider.notifier).mitWiederherstellungVerbinden(_schluessel.text);
        return true;
      });
      if (ergebnis != true) throw const EingabeFehler('Das Verbinden wurde nicht abgeschlossen. Bestätige mit Passkey oder Code, um fortzufahren.');
    });
    if (ok && mounted) {
      zeigeHinweis(context, 'Dieses Gerät ist jetzt verbunden.');
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => BildschirmSchutz(
    child: AuthSeite(
      label: '// wiederherstellung',
      titel: 'Mit Wiederherstellungsschlüssel verbinden',
      kinder: [
        const Text(
          'Gib den Wiederherstellungsschlüssel ein, den du bei der Einrichtung bekommen hast (14 Gruppen aus je 4 Zeichen). Groß- und Kleinschreibung und Bindestriche sind egal.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
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
        if (fehler != null) ...[const SizedBox(height: 12), MeldungsBox(fehler!)],
        const SizedBox(height: 12),
        HauptKnopf(text: 'Verbinden', icon: Icons.key_outlined, laeuft: laeuft, onPressed: _verbinden),
      ],
    ),
  );
}
