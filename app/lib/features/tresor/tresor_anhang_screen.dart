// Tresor (Abschnitt 6m/6n): ein Dokument ansehen. Die Datei wird beim Öffnen geladen und im ARBEITSSPEICHER entschlüsselt (nie als Datei, nie im Cache oder Vorschau-Zwischenspeicher der
// Dateien-Ablage). Bilder zeigt die App selbst (`Image.memory`), alles andere lässt sich nur speichern: über den Systemdialog, nach einer Rückfrage, denn danach liegt die Datei UNVERSCHLÜSSELT
// dort, wo die Person sie ablegt. Mit der Sperre schließt sich die Seite (`TresorSeite`): beim Schließen wird der Klartext überschrieben, das Bild aus dem Bildspeicher entfernt und eine noch
// laufende Entschlüsselung wirkt danach nicht mehr (ihr Ergebnis wird sofort überschrieben). Fehler (beschädigt, verändert, Schlüssel fehlt, Netz) stehen ruhig und verständlich auf der Seite.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_speichern.dart';
import '../../data/dateien/tresor_anhang_repository.dart';
import '../../data/dateien/tresor_anhang_state.dart';
import '../../data/tresor/tresor_sperre.dart';
import '../../data/tresor/tresor_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show bestaetigen;
import 'tresor_bausteine.dart';

/// Öffnet die Ansicht eines Dokuments (Unterseite des Tresors: schließt sich mit der Sperre).
Future<void> tresorAnhangOeffnen(BuildContext context, AnhangAnsicht a) => Navigator.of(context).push<void>(tresorUnterseiteRoute((_) => TresorAnhangScreen(anhang: a)));

/// Datum der Ablage als "12.09.2026".
String tresorAnhangDatum(DateTime t) {
  final l = t.toLocal();
  return '${l.day.toString().padLeft(2, '0')}.${l.month.toString().padLeft(2, '0')}.${l.year}';
}

/// Symbol je Art der Datei.
IconData tresorAnhangIcon(String? mime, String name) => switch (vorschauArt(mime, name)) {
  VorschauArt.bild => Icons.image_outlined,
  VorschauArt.pdf => Icons.picture_as_pdf_outlined,
  VorschauArt.text => Icons.description_outlined,
  _ => Icons.insert_drive_file_outlined,
};

class TresorAnhangScreen extends ConsumerStatefulWidget {
  final AnhangAnsicht anhang;
  const TresorAnhangScreen({super.key, required this.anhang});

  @override
  ConsumerState<TresorAnhangScreen> createState() => _TresorAnhangScreenState();
}

class _TresorAnhangScreenState extends ConsumerState<TresorAnhangScreen> {
  Uint8List? _bytes;
  MemoryImage? _bild;
  String? _fehler;
  var _beschaeftigt = false;
  var _geladen = 0;
  var _beendet = false;

  AnhangAnsicht get _a => widget.anhang;

  @override
  void initState() {
    super.initState();
    unawaited(_laden());
  }

  @override
  void dispose() {
    _beendet = true;
    _verwerfen();
    super.dispose();
  }

  /// Überschreibt den Klartext und entfernt das Bild aus dem Bildspeicher.
  void _verwerfen() {
    _bild?.evict();
    _bild = null;
    anhangUeberschreiben(_bytes);
    _bytes = null;
  }

  Future<void> _laden() async {
    setState(() {
      _fehler = null;
      _geladen = 0;
    });
    Uint8List? klar;
    try {
      klar = await ref.read(tresorAnhangRepositoryProvider).herunterladen(
        _a.id,
        fortschritt: (n) {
          if (mounted && !_beendet) setState(() => _geladen = n);
        },
      );
    } on Object catch (e) {
      if (mounted && !_beendet) setState(() => _fehler = anhangFehlerText(e));
      return;
    }
    // gesperrt oder geschlossen, während entschlüsselt wurde: das Ergebnis sofort verwerfen
    if (!mounted || _beendet || !ref.read(tresorSperreProvider).entsperrt) {
      anhangUeberschreiben(klar);
      return;
    }
    setState(() {
      _bytes = klar;
      _bild = zeigtVollbild(_a.mime, _a.name ?? '') ? MemoryImage(klar!) : null;
    });
  }

  Future<void> _speichern() async {
    final bytes = _bytes;
    if (bytes == null || _beschaeftigt) return;
    final ok = await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Dokument speichern?'),
        content: const Text('Die Datei wird dabei entschlüsselt und liegt danach unverschlüsselt dort, wo du sie ablegst. Dort schützt sie der Tresor nicht mehr. Speichere sie nur an einem Ort, dem du vertraust.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Speichern')),
        ],
      ),
    );
    if (ok != true || !mounted || _bytes == null) return;
    setState(() => _beschaeftigt = true);
    try {
      final gespeichert = await ref.read(tresorSperreProvider.notifier).mitSystemDialog(() => ref.read(dateiSpeichernProvider).bytes(_a.name ?? 'Dokument', bytes, mime: _a.mime));
      if (mounted && gespeichert) zeigeHinweis(context, 'Gespeichert. Die Datei liegt jetzt unverschlüsselt an dem Ort, den du gewählt hast.');
    } on Object {
      if (mounted) zeigeHinweis(context, 'Das Speichern hat nicht geklappt. Versuche es noch einmal.');
    } finally {
      if (mounted) setState(() => _beschaeftigt = false);
    }
  }

  Future<void> _loeschen() async {
    final ok = await bestaetigen(context, titel: 'Dokument löschen?', text: '„${_a.name}“ verschwindet für alle Eltern und lässt sich nicht wiederherstellen.', knopf: 'Löschen');
    if (!ok || !mounted) return;
    setState(() => _beschaeftigt = true);
    final nav = Navigator.of(context);
    try {
      await ref.read(tresorAnhangRepositoryProvider).loeschen(_a.id);
      if (mounted) nav.pop();
    } on Object catch (e) {
      if (mounted) {
        zeigeHinweis(context, anhangFehlerText(e));
        setState(() => _beschaeftigt = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(tresorDarfProvider)) return const TresorNichtVerfuegbar(eingebettet: false);
    final name = _a.name ?? 'Dokument';
    final bytes = _bytes;
    final meta = [if (_a.groesse != null) groesseText(_a.groesse!), tresorAnhangDatum(_a.erstelltAt)].join(' · ');
    return TresorSeite(
      unterseite: true,
      child: AuthSeite(
        label: 'Dokument',
        titel: name,
        maxBreite: kMaxContentWidth,
        kinder: [
          if (_fehler != null) ...[
            MeldungsBox(_fehler!),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _beschaeftigt ? null : () => unawaited(_laden()), icon: const Icon(Icons.refresh), label: const Text('Noch einmal versuchen'), style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48))),
            const SizedBox(height: 12),
          ] else if (bytes == null) ...[
            LxCard(
              child: Semantics(
                container: true,
                label: 'Das Dokument wird geladen und entschlüsselt',
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Wird geladen und entschlüsselt …', style: TextStyle(color: kTextMuted)),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: _a.groesse != null && _a.groesse! > 0 && _geladen > 0 ? (_geladen / (_a.groesse! + 64)).clamp(0.0, 1.0) : null),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ] else if (_bild != null) ...[
            Semantics(
              image: true,
              label: 'Bild: $name',
              excludeSemantics: true,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 120, maxHeight: 420),
                  alignment: Alignment.center,
                  color: kSurface,
                  child: Image(
                    image: _bild!,
                    fit: BoxFit.contain,
                    gaplessPlayback: false,
                    errorBuilder: (_, _, _) => const Padding(padding: EdgeInsets.all(16), child: Text('Dieses Bild lässt sich nicht anzeigen. Du kannst es speichern.', style: TextStyle(color: kTextMuted))),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ] else ...[
            LxCard(
              child: Row(
                children: [
                  Icon(tresorAnhangIcon(_a.mime, name), color: kAccent),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('Dieses Dokument zeigt die App nicht an. Du kannst es speichern und mit einer anderen App öffnen.', style: TextStyle(color: kTextMuted, height: 1.4))),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          LxCard(
            child: Row(
              children: [
                const Expanded(child: Text('Datei', style: TextStyle(color: kTextMuted))),
                Flexible(child: Text(meta, textAlign: TextAlign.end, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12))),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const TresorHinweis(titel: 'Beim Speichern entschlüsselt', text: 'Gespeichert liegt die Datei unverschlüsselt dort, wo du sie ablegst. Der Tresor schützt sie dann nicht mehr.', icon: Icons.warning_amber_outlined, farbe: kWarn),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _beschaeftigt || bytes == null ? null : () => unawaited(_speichern()),
            icon: const Icon(Icons.save_alt),
            label: const Text('Speichern'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _beschaeftigt ? null : () => unawaited(_loeschen()),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Löschen'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: kDanger, side: const BorderSide(color: kDanger)),
          ),
        ],
      ),
    );
  }
}
