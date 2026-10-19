// QR-Scan für Einladungen (nur Android; im Web gibt es nur das Einfügen des Links, weil der Web-Scanner Skripte von
// einem CDN laden würde). Die Kamera wird nur in diesem Screen genutzt; das Bild verlässt das Gerät nicht.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../constants.dart';
import 'auth_widgets.dart';
import 'invite_link.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _fertig = false;
  String? _hinweis;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _erkannt(BarcodeCapture capture) {
    // Der Scanner meldet Treffer mehrfach und auch noch kurz nach dem Schließen: nur der erste gültige zählt, und nur solange
    // die Seite noch steht.
    if (_fertig || !mounted) return;
    for (final b in capture.barcodes) {
      final token = parseInviteToken(b.rawValue ?? '');
      if (token != null) {
        _fertig = true;
        unawaited(_controller.stop());
        Navigator.of(context).pop(token);
        return;
      }
    }
    if (capture.barcodes.isNotEmpty && _hinweis == null) {
      setState(() => _hinweis = 'Das ist kein Einladungs-QR-Code von dieser Familie.');
    }
  }

  @override
  Widget build(BuildContext context) => AuthSeite(
    label: '// einladung',
    titel: 'QR-Code scannen',
    kinder: [
      const Text('Halte die Kamera auf den QR-Code der Einladung.', style: TextStyle(fontSize: 14, color: kTextMuted)),
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
                child: MeldungsBox(
                  'Die Kamera ist nicht verfügbar oder nicht erlaubt. Erlaube den Kamerazugriff in den Einstellungen oder füge den Einladungslink ein.',
                ),
              ),
            ),
          ),
        ),
      ),
      if (_hinweis != null) ...[const SizedBox(height: 12), MeldungsBox(_hinweis!)],
      const SizedBox(height: 12),
      ZweitKnopf(text: 'Link einfügen statt scannen', icon: Icons.link, onPressed: () => Navigator.of(context).pop()),
    ],
  );
}
