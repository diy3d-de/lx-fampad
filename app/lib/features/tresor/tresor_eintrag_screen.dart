// Tresor (Abschnitt 6m): einen Eintrag ansehen. Felder mit Bezeichnung und Wert; GEHEIME Werte stehen verdeckt (nie als Text im Widgetbaum, nie in der Bedienhilfe: dort "verdeckt"), werden nur
// auf Tipp angezeigt und blenden sich nach 15 Sekunden wieder aus. Kopieren nur auf Klick, die Zwischenablage wird nach 30 Sekunden geleert (tresor_zwischenablage.dart). Der Eintrag gehört
// allen Eltern: jede Person mit Zugriff darf ihn bearbeiten und löschen (Löschen mit Bestätigung).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/dateien/tresor_anhang_repository.dart';
import '../../data/dateien/tresor_anhang_state.dart';
import '../../data/dateien/transfer_dienst.dart' show transferDienstProvider;
import '../../data/tresor/tresor_daten.dart';
import '../../data/tresor/tresor_modelle.dart';
import '../../data/tresor/tresor_repository.dart';
import '../../data/tresor/tresor_state.dart';
import '../../data/tresor/tresor_zwischenablage.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show bestaetigen;
import 'tresor_bausteine.dart';
import 'tresor_dokumente.dart';
import 'tresor_editor.dart';

/// So lange bleibt ein geheimer Wert nach dem Tipp auf "Anzeigen" sichtbar.
const Duration kTresorAnzeigeDauer = Duration(seconds: 15);

class TresorEintragScreen extends ConsumerWidget {
  final String id;
  const TresorEintragScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(tresorDarfProvider)) return const TresorNichtVerfuegbar(eingebettet: false);
    final daten = ref.watch(tresorDatenProvider);
    final eintrag = daten.eintrag(id);
    final Widget inhalt;
    if (!daten.offen) {
      inhalt = const SizedBox.shrink(); // gesperrt: die Seite schließt sich gerade
    } else if (eintrag?.inhalt == null) {
      inhalt = AuthSeite(
        titel: 'Eintrag',
        maxBreite: kMaxContentWidth,
        kinder: [
          if (!daten.geladen)
            const Center(child: CircularProgressIndicator())
          else
            EmptyState(icon: Icons.lock_outline, title: eintrag == null ? 'Eintrag nicht gefunden' : 'Nicht lesbar', hint: eintrag == null ? 'Den Eintrag gibt es nicht mehr.' : 'Dieser Eintrag lässt sich gerade nicht lesen.'),
        ],
      );
    } else {
      inhalt = _Ansicht(eintrag: eintrag!);
    }
    return TresorSeite(unterseite: true, child: inhalt);
  }
}

class _Ansicht extends ConsumerStatefulWidget {
  final TresorAnsicht eintrag;
  const _Ansicht({required this.eintrag});

  @override
  ConsumerState<_Ansicht> createState() => _AnsichtState();
}

class _AnsichtState extends ConsumerState<_Ansicht> {
  var _laeuft = false;

  Future<void> _loeschen() async {
    final i = widget.eintrag.inhalt!;
    final id = widget.eintrag.id;
    // Dokumente dieses Eintrags (nur wenn es sie gibt: Dateiablage verfügbar und entsperrt)
    var n = 0;
    if (ref.read(tresorDokumenteAktivProvider)) {
      try {
        n = anhaengeFuerEintrag(await ref.read(tresorAnhaengeProvider.future), id)?.length ?? 0;
      } on Object {
        n = 0;
      }
      if (!mounted) return;
    }
    final ok = await bestaetigen(
      context,
      titel: n > 0 ? 'Eintrag und $n ${n == 1 ? 'Dokument' : 'Dokumente'} löschen?' : 'Eintrag löschen?',
      text: n > 0
          ? '„${i.titel}“ und ${n == 1 ? 'das angehängte Dokument verschwinden' : 'die $n angehängten Dokumente verschwinden'} für alle Eltern und lassen sich nicht wiederherstellen.'
          : '„${i.titel}“ verschwindet für alle Eltern und lässt sich nicht wiederherstellen.',
      knopf: 'Löschen',
    );
    if (!ok || !mounted) return;
    setState(() => _laeuft = true);
    final nav = Navigator.of(context);
    try {
      if (n > 0) {
        // laufende Uploads zu diesem Eintrag zuerst abbrechen, dann die Dokumente, zuletzt der Eintrag (scheitert ein Schritt, bleibt der Eintrag stehen)
        final dienst = ref.read(transferDienstProvider);
        for (final u in ref.read(tresorAnhangUploadsProvider).values.where((u) => u.eintragId == id).toList()) {
          await dienst.abbrechen(u.transferId);
        }
        await ref.read(tresorAnhangRepositoryProvider).fuerEintragLoeschen(id);
      }
      await ref.read(tresorRepositoryProvider).loeschen(widget.eintrag.id);
      if (mounted) nav.pop();
    } on TresorFehler catch (e) {
      if (mounted) zeigeHinweis(context, e.meldung);
    } on Object {
      if (mounted) zeigeHinweis(context, 'Das Löschen hat nicht geklappt. Versuche es noch einmal.');
    } finally {
      if (mounted) setState(() => _laeuft = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.eintrag.inhalt!;
    final geaendert = tresorGeaendertText(i.geaendert);
    return AuthSeite(
      label: '// ${i.kategorieAnzeige}',
      titel: i.titel,
      maxBreite: kMaxContentWidth,
      kinder: [
        const TresorHinweis(titel: 'Für alle Eltern sichtbar', text: 'Alle Eltern und Admins sehen und bearbeiten diesen Eintrag.', icon: Icons.groups_outlined),
        const SizedBox(height: 12),
        LxCard(
          child: i.felder.isEmpty
              ? const Text('Dieser Eintrag hat keine Felder.', style: TextStyle(color: kTextMuted))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var n = 0; n < i.felder.length; n++) ...[if (n > 0) const Divider(height: 16, color: kBorderSoft), _FeldZeile(key: ValueKey('feld-$n'), feld: i.felder[n])]]),
        ),
        const SizedBox(height: 12),
        if (i.notiz.isNotEmpty) ...[
          LxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MonoLabel('// notiz', color: kTextMuted),
                const SizedBox(height: 6),
                Semantics(label: 'Notiz: ${i.notiz}', excludeSemantics: true, child: Text(i.notiz, style: const TextStyle(height: 1.4))),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        TresorDokumente(eintragId: widget.eintrag.id),
        const SizedBox(height: 12),
        LxCard(
          child: Row(
            children: [
              const Expanded(child: Text('Zuletzt geändert', style: TextStyle(color: kTextMuted))),
              Text(geaendert ?? 'unbekannt', style: const TextStyle(fontFamily: kFontMono, fontSize: 12)),
            ],
          ),
        ),
        if (widget.eintrag.lokalNeu) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Noch nicht mit den anderen Geräten abgeglichen.', style: TextStyle(fontSize: 12, color: kTextMuted))),
        const SizedBox(height: 12),
        const TresorHinweis(titel: 'Zwischenablage', text: 'Kopierte Werte löscht die App nach 30 Sekunden aus der Zwischenablage. Auf Android sind Bildschirmfotos in diesem Bereich gesperrt.', icon: Icons.content_paste_off_outlined, farbe: kWarn),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _laeuft ? null : () => tresorEditorOeffnen(context, id: widget.eintrag.id),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Bearbeiten'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _laeuft ? null : _loeschen,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Löschen'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: kDanger, side: const BorderSide(color: kDanger)),
        ),
      ],
    );
  }
}

class _FeldZeile extends ConsumerStatefulWidget {
  final TresorFeld feld;
  const _FeldZeile({super.key, required this.feld});

  @override
  ConsumerState<_FeldZeile> createState() => _FeldZeileState();
}

class _FeldZeileState extends ConsumerState<_FeldZeile> {
  Timer? _timer;
  var _gezeigt = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _umschalten() {
    _timer?.cancel();
    setState(() => _gezeigt = !_gezeigt);
    if (_gezeigt) {
      _timer = Timer(kTresorAnzeigeDauer, () {
        if (mounted) setState(() => _gezeigt = false);
      });
    }
  }

  Future<void> _kopieren() async {
    final f = widget.feld;
    await ref.read(tresorZwischenablageProvider).kopieren(f.wert, geheim: f.geheim);
    if (mounted) zeigeHinweis(context, '${f.bezeichnung} kopiert. Wird in ${kTresorZwischenablageFrist.inSeconds} Sekunden aus der Zwischenablage entfernt.');
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.feld;
    final verdeckt = f.geheim && !_gezeigt;
    final leer = f.wert.isEmpty;
    // Bedienhilfe: ein verdeckter Wert steht NIE darin
    final label = verdeckt ? '${f.bezeichnung}: ${leer ? 'leer' : 'verdeckt'}' : '${f.bezeichnung}: ${leer ? 'leer' : f.wert}';
    final Widget wert = verdeckt
        ? Text(leer ? '–' : '••••••••', style: const TextStyle(fontFamily: kFontMono, fontSize: 15, letterSpacing: 1, color: kTextStrong))
        : Text(leer ? '–' : f.wert, style: TextStyle(fontFamily: f.geheim ? kFontMono : null, color: kTextStrong, height: 1.35));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Semantics(
            container: true,
            label: label,
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f.bezeichnung, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, letterSpacing: 0.6, color: kTextMuted)),
                  const SizedBox(height: 2),
                  wert,
                ],
              ),
            ),
          ),
        ),
        if (f.geheim && !leer)
          IconButton(
            tooltip: _gezeigt ? '${f.bezeichnung} verbergen' : '${f.bezeichnung} anzeigen',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: _umschalten,
            icon: Icon(_gezeigt ? Icons.visibility_off_outlined : Icons.visibility_outlined),
          ),
        IconButton(
          tooltip: '${f.bezeichnung} kopieren',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: leer ? null : () => unawaited(_kopieren()),
          icon: const Icon(Icons.copy_outlined),
        ),
      ],
    );
  }
}
