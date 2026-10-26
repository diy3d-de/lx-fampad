// "Zähler zuordnen" (Zähler, Abschnitt 6l), Schritt 3 von 3 der Kopplung und eigenständig aus dem Zustand heraus ("Zuordnen"): Home Assistant liefert drei feste Kanäle (Strom Bezug, Strom
// Einspeisung, Solar Erzeugung); hier wählt die Person je Kanal den Zähler, der die Werte bekommt. Gespeichert wird dieselbe Quelle wie im Zähler-Editor (`ZaehlerQuelle` im verschlüsselten
// Zähler), nichts geht zum Server. Nur Eltern und Admins; angeboten werden nur Zähler, die zur Art passen (Strom, Solar), nicht archiviert und nicht in der Eingabeart Monatswerte.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/ingest/ingest_anzeige.dart';
import '../../data/zaehler/zaehler_modelle.dart';
import '../../data/zaehler/zaehler_repository.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'ha_verbindung_screen.dart' show haFehlerText;
import 'zaehler_editor.dart' show zaehlerEditorOeffnen;

/// Öffnet die Seite (nur Eltern und Admins; für alle anderen passiert nichts).
Future<void> haZuordnenOeffnen(BuildContext context) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const HaZuordnenScreen()));
}

/// Der Zähler (Reihe), der den Kanal gerade bekommt: bei mehreren gewinnt der mit der kleinsten ID (wie [kanalZuordnung]).
ZaehlerReihe? haZielFuer(ZaehlerDaten daten, String kanal) {
  final treffer = [for (final r in daten.reihen) if (!r.archiviert && !r.monatlich && r.inhalt.quelle?.kanal == kanal) r]..sort((a, b) => a.id.compareTo(b.id));
  return treffer.firstOrNull;
}

/// Die Zähler, die einen Kanal bekommen dürfen: passende Art, nicht archiviert, keine Monatswerte, noch ohne Quelle oder schon mit diesem Kanal.
List<ZaehlerReihe> haKandidaten(ZaehlerDaten daten, String kanal, ZaehlerArt art) =>
    [for (final r in daten.reihen) if (!r.archiviert && !r.monatlich && r.art == art && (r.inhalt.quelle == null || r.inhalt.quelle!.kanal == kanal)) r];

class HaZuordnenScreen extends ConsumerStatefulWidget {
  /// Schritt 3 der Kopplung (mit Titel "Fast geschafft"); sonst die eigenständige Seite.
  final bool nachKopplung;
  const HaZuordnenScreen({super.key, this.nachKopplung = false});

  @override
  ConsumerState<HaZuordnenScreen> createState() => _HaZuordnenScreenState();
}

class _HaZuordnenScreenState extends ConsumerState<HaZuordnenScreen> {
  String? _fehler;
  String? _beschaeftigt;

  Future<void> _waehlen(String kanal, ZaehlerReihe? alt, ZaehlerReihe? neu) async {
    if (_beschaeftigt != null || alt?.id == neu?.id) return;
    setState(() {
      _beschaeftigt = kanal;
      _fehler = null;
    });
    try {
      final repo = ref.read(zaehlerRepositoryProvider);
      // erst den bisherigen Zähler lösen, dann den neuen verbinden: nie zwei Zähler mit demselben Kanal
      if (alt != null) await repo.aendern(alt.id, alt.inhalt.kopie(quelle: () => null));
      if (neu != null) {
        await repo.aendern(neu.id, neu.inhalt.kopie(quelle: () => ZaehlerQuelle(kanal: kanal, pruefen: neu.inhalt.quelle?.pruefen ?? true), modus: ZaehlerModus.stand, ablesung: () => null));
      }
    } on Object catch (e) {
      if (mounted) setState(() => _fehler = haFehlerText(e));
    }
    if (mounted) setState(() => _beschaeftigt = null);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(zaehlerDarfProvider)) {
      return const AuthSeite(titel: 'Nicht verfügbar', maxBreite: kMaxContentWidth, kinder: [EmptyState(icon: Icons.lock_outline, title: 'Nicht verfügbar', hint: 'Diesen Bereich gibt es für dich nicht.')]);
    }
    final daten = ref.watch(zaehlerDatenProvider);
    final nachKopplung = widget.nachKopplung;
    return AuthSeite(
      label: nachKopplung ? 'Schritt 3 von 3' : 'Home Assistant',
      titel: nachKopplung ? 'Fast geschafft' : 'Zähler zuordnen',
      maxBreite: kMaxContentWidth,
      fussleiste: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.of(context).pop(), child: const Text('Fertig')),
      kinder: [
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
        Text(
          nachKopplung ? 'Die Verbindung steht. Jetzt legst du fest, welcher Zähler welche Werte aus Home Assistant bekommt.' : 'Lege fest, welcher Zähler welche Werte aus Home Assistant bekommt.',
          style: const TextStyle(color: kTextMuted),
        ),
        const SizedBox(height: 14),
        if (!daten.geladen) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
        if (daten.geladen)
          LxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final k in kHaKanaele) ...[
                  _KanalAuswahl(
                    label: k.label,
                    kanal: k.kanal,
                    kandidaten: haKandidaten(daten, k.kanal, k.art),
                    aktuell: haZielFuer(daten, k.kanal),
                    beschaeftigt: _beschaeftigt != null,
                    onWaehlen: (alt, neu) => unawaited(_waehlen(k.kanal, alt, neu)),
                  ),
                  if (k != kHaKanaele.last) const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.hourglass_empty, size: 18, color: kTextMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                nachKopplung
                    ? 'Warte auf den ersten Wert: Home Assistant sendet einmal am Tag kurz nach Mitternacht. Der erste Wert kommt deshalb erst nach der nächsten Mitternacht; bis dahin steht bei der Verbindung „Noch nie gehört“.'
                    : 'Home Assistant sendet einmal am Tag kurz nach Mitternacht. Ein neu zugeordneter Zähler bekommt seinen ersten Wert deshalb erst nach der nächsten Mitternacht.',
                style: const TextStyle(fontSize: 13, color: kTextMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft),
          onPressed: () => unawaited(zaehlerEditorOeffnen(context)),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Zähler einrichten'),
        ),
      ],
    );
  }
}

class _KanalAuswahl extends StatelessWidget {
  final String label;
  final String kanal;
  final List<ZaehlerReihe> kandidaten;
  final ZaehlerReihe? aktuell;
  final bool beschaeftigt;
  final void Function(ZaehlerReihe? alt, ZaehlerReihe? neu) onWaehlen;
  const _KanalAuswahl({required this.label, required this.kanal, required this.kandidaten, required this.aktuell, required this.beschaeftigt, required this.onWaehlen});

  @override
  Widget build(BuildContext context) {
    if (kandidaten.isEmpty) {
      return Semantics(
        container: true,
        label: '$label: noch kein passender Zähler',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const Text('Noch kein passender Zähler. Richte einen ein und wähle dort Home Assistant als Quelle.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
        ),
      );
    }
    final wert = aktuell == null ? null : kandidaten.where((r) => r.id == aktuell!.id).firstOrNull;
    return DropdownButtonFormField<String?>(
      key: ValueKey('$kanal:${wert?.id}'),
      isExpanded: true,
      initialValue: wert?.id,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Nicht nutzen')),
        for (final r in kandidaten) DropdownMenuItem<String?>(value: r.id, child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: beschaeftigt ? null : (id) => onWaehlen(aktuell, id == null ? null : kandidaten.firstWhere((r) => r.id == id)),
    );
  }
}
