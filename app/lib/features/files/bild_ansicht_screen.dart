// Bildansicht der Dateiablage (Abschnitt 6n): lädt ein Bild (PNG, JPEG, WebP) mit der Anmeldung der Sitzung in den ARBEITSSPEICHER (höchstens 25 MB, nie auf die Platte) und zeigt es zum Zoomen.
// Größere oder nicht darstellbare Bilder bleiben beim Speichern. Nie Namen oder Inhalte loggen.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/dateien/blob_lader.dart';
import '../../ui/widgets.dart';

/// Größte Bilddatei, die die App im Arbeitsspeicher zeigt.
const int kBildAnsichtMaxBytes = 25 * 1024 * 1024;

/// Lädt Blobs in den Arbeitsspeicher (für Tests überschreibbar).
final blobLaderProvider = Provider<BlobLader>((ref) => BlobLader(ref.watch(apiClientProvider)));

class BildAnsichtScreen extends ConsumerStatefulWidget {
  final String name;
  final String blobId;
  final int groesse;
  const BildAnsichtScreen({super.key, required this.name, required this.blobId, required this.groesse});

  static Route<void> route({required String name, required String blobId, required int groesse}) =>
      MaterialPageRoute<void>(builder: (_) => BildAnsichtScreen(name: name, blobId: blobId, groesse: groesse));

  @override
  ConsumerState<BildAnsichtScreen> createState() => _BildAnsichtScreenState();
}

class _BildAnsichtScreenState extends ConsumerState<BildAnsichtScreen> {
  Uint8List? _bytes;
  String? _fehler;

  @override
  void initState() {
    super.initState();
    if (widget.groesse > kBildAnsichtMaxBytes) {
      _fehler = 'Das Bild ist zu groß für die Ansicht in der App. Speichere es stattdessen.';
    } else {
      _laden();
    }
  }

  Future<void> _laden() async {
    try {
      final b = await ref.read(blobLaderProvider).laden(widget.blobId, widget.groesse, maxBytes: kBildAnsichtMaxBytes);
      if (mounted) setState(() => _bytes = b);
    } on Object {
      if (mounted) setState(() => _fehler = 'Das Bild lässt sich gerade nicht laden. Prüfe die Verbindung oder speichere es.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget inhalt;
    if (_fehler != null) {
      inhalt = Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_fehler!, textAlign: TextAlign.center, style: const TextStyle(color: kTextMuted, height: 1.4))));
    } else if (_bytes == null) {
      inhalt = Center(child: Semantics(label: 'Bild wird geladen', child: const CircularProgressIndicator(strokeWidth: 2)));
    } else {
      inhalt = InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Image.memory(
            _bytes!,
            fit: BoxFit.contain,
            semanticLabel: 'Bild ${widget.name}',
            errorBuilder: (_, _, _) => const Padding(padding: EdgeInsets.all(24), child: Text('Dieses Bild lässt sich hier nicht darstellen. Speichere es stattdessen.', textAlign: TextAlign.center, style: TextStyle(color: kTextMuted))),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(tooltip: 'Zurück', icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
                    Expanded(child: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                    const SizedBox(width: 12),
                  ],
                ),
                Expanded(child: inhalt),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
