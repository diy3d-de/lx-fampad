// Bewusst schwere Bestätigung für Aktionen, die Schlüssel unwiderruflich entfernen oder ersetzen ("Gerät abgeben", alten Schlüssel verwerfen,
// "Neuen Schlüssel erzeugen"): erst alle Haken der Checkliste, dann ein Wort eintippen. Ein einfaches "Ja" reicht dafür nie.
import 'package:flutter/material.dart';

import '../../constants.dart';

/// Fragt nach: [haken] müssen alle gesetzt sein (Checkliste, kann leer sein), dann muss [wort] eingetippt werden (Groß-/Kleinschreibung und Leerzeichen
/// am Rand egal). true nur bei bestätigtem [knopf].
Future<bool> wortBestaetigen(
  BuildContext context, {
  required String titel,
  required String text,
  required String wort,
  required String knopf,
  List<String> haken = const [],
}) async =>
    await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (ctx) => _WortDialog(titel: titel, text: text, wort: wort, knopf: knopf, haken: haken),
    ) ??
    false;

class _WortDialog extends StatefulWidget {
  final String titel;
  final String text;
  final String wort;
  final String knopf;
  final List<String> haken;
  const _WortDialog({required this.titel, required this.text, required this.wort, required this.knopf, required this.haken});

  @override
  State<_WortDialog> createState() => _WortDialogState();
}

class _WortDialogState extends State<_WortDialog> {
  final _eingabe = TextEditingController();
  late final List<bool> _gesetzt = List.filled(widget.haken.length, false);

  @override
  void initState() {
    super.initState();
    _eingabe.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _eingabe.dispose();
    super.dispose();
  }

  bool get _bereit => _gesetzt.every((b) => b) && _eingabe.text.trim().toLowerCase() == widget.wort.toLowerCase();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.titel),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.text, style: const TextStyle(height: 1.4, color: kTextMuted)),
        if (widget.haken.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (var i = 0; i < widget.haken.length; i++)
            CheckboxListTile(
              value: _gesetzt[i],
              onChanged: (v) => setState(() => _gesetzt[i] = v ?? false),
              title: Text(widget.haken[i], style: const TextStyle(fontSize: 14, height: 1.3)),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              visualDensity: VisualDensity.standard,
            ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _eingabe,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: 'Zum Bestätigen "${widget.wort}" eintippen'),
        ),
      ],
    ),
    actionsOverflowButtonSpacing: 12,
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        child: const Text('Abbrechen'),
      ),
      TextButton(
        onPressed: _bereit ? () => Navigator.of(context).pop(true) : null,
        style: TextButton.styleFrom(foregroundColor: kDanger, minimumSize: const Size(48, 48)),
        child: Text(widget.knopf),
      ),
    ],
  );
}
