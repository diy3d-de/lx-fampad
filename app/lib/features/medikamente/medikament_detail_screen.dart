// Detail eines Medikaments (Abschnitt 6k): Vorrat als Balken ("reicht noch N Tage"), Rhythmus, Rezept, wer erinnert wird und wer es sieht (fest), die letzten 7 Tage, "Packung aufgefüllt",
// "Einnahme nachtragen", Bearbeiten, Pausieren/Fortsetzen, Beenden und Löschen. Steht nur auf dem Gerät der Person, die den Plan sehen darf.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show Role;
import '../../data/medikamente/medikament_heute.dart';
import '../../data/medikamente/medikament_logik.dart';
import '../../data/medikamente/medikament_modelle.dart';
import '../../data/medikamente/medikament_repository.dart';
import '../../data/medikamente/medikament_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show bestaetigen;
import 'medikament_anzeige.dart';
import 'medikament_editor.dart';
import 'medikament_nachtragen.dart';

Future<void> medikamentDetailOeffnen(BuildContext context, String id) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => MedikamentDetailScreen(id: id)));

class MedikamentDetailScreen extends ConsumerStatefulWidget {
  final String id;
  const MedikamentDetailScreen({super.key, required this.id});

  @override
  ConsumerState<MedikamentDetailScreen> createState() => _MedikamentDetailScreenState();
}

class _MedikamentDetailScreenState extends ConsumerState<MedikamentDetailScreen> {
  String? _fehler;

  Future<void> _tun(Future<void> Function() f) async {
    setState(() => _fehler = null);
    try {
      await f();
    } on Object catch (e) {
      if (mounted) setState(() => _fehler = medFehlerText(e));
    }
  }

  Future<void> _auffuellen(MedikamentInhalt m) async {
    final ergebnis = await showDialog<({int packungen, double stueck})>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _AuffuellenDialog(packung: m.packung),
    );
    if (ergebnis == null || !mounted) return;
    await _tun(() => ref.read(medikamentRepositoryProvider).vorratAuffuellen(widget.id, packungen: ergebnis.packungen, stueck: ergebnis.stueck));
  }

  Future<void> _pausieren() async {
    final ja = await bestaetigen(context, titel: 'Pausieren?', text: 'Ab heute gibt es keine Einnahmen und keine Erinnerungen mehr, bis du den Plan fortsetzt.', knopf: 'Pausieren');
    if (ja && mounted) await _tun(() => ref.read(medikamentRepositoryProvider).pausieren(widget.id));
  }

  Future<void> _beenden() async {
    final ja = await bestaetigen(context, titel: 'Beenden?', text: 'Ab heute gibt es keine Einnahmen und keine Erinnerungen mehr. Plan und Verlauf bleiben erhalten, du kannst ihn später fortsetzen.', knopf: 'Beenden');
    if (ja && mounted) await _tun(() => ref.read(medikamentRepositoryProvider).beenden(widget.id));
  }

  Future<void> _loeschen() async {
    final nav = Navigator.of(context);
    final ja = await bestaetigen(context, titel: 'Endgültig löschen?', text: 'Der Plan und alle seine Einträge werden auf allen Geräten gelöscht. Das lässt sich nicht rückgängig machen.', knopf: 'Löschen');
    if (!ja || !mounted) return;
    try {
      await ref.read(medikamentRepositoryProvider).loeschen(widget.id);
      if (mounted) nav.pop();
    } on Object catch (e) {
      if (mounted) setState(() => _fehler = medFehlerText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(medAnsichtProvider);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final e = daten.eintrag(widget.id);
    if (e == null) {
      return AuthSeite(
        label: '// medikament',
        titel: 'Medikament',
        maxBreite: kMaxContentWidth,
        kinder: [if (!daten.geladen) const Center(child: CircularProgressIndicator()) else const MeldungsBox('Dieses Medikament gibt es nicht mehr.', fehler: false)],
      );
    }
    final m = e.inhalt;
    if (m == null) {
      return AuthSeite(label: '// medikament', titel: 'Medikament', maxBreite: kMaxContentWidth, kinder: [MeldungsBox('Dieses Medikament lässt sich gerade nicht lesen${e.med.hinweis == null ? '' : ' (${e.med.hinweis})'}.', fehler: false)]);
    }
    final person = daten.person(e.subjektId);
    final ich = e.subjektId.toLowerCase() == daten.ich?.toLowerCase();
    final subjektKind = person?.role == Role.child;
    final name = person?.displayName.split(RegExp(r'\s+')).first ?? 'Person';
    final prognose = m.bestand == null ? null : vorratPrognose(m, e.einnahmen, jetzt);
    final warn = vorratWarnTage(e, jetzt);
    final rezept = m.rezeptDatum == null ? null : tagLesen(m.rezeptDatum!);
    final v = verlauf(e, jetzt);
    final letzte = ([...e.einnahmen.where((x) => x.inhalt != null)]..sort((a, b) => b.inhalt!.um.compareTo(a.inhalt!.um))).take(5).toList();
    final zustandPille = switch (m.zustand) {
      MedikamentZustand.aktiv => warn != null ? 'BALD LEER' : null,
      MedikamentZustand.pausiert => 'PAUSIERT',
      MedikamentZustand.beendet => 'BEENDET',
    };
    return AuthSeite(
      label: '// medikament',
      titel: m.name,
      maxBreite: kMaxContentWidth,
      kinder: [
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Pille(ich ? 'Ich' : name),
            _Pille(rhythmusText(m)),
            if (m.dosis.trim().isNotEmpty) _Pille(m.dosis),
            if (m.rhythmus.festeZeiten && m.menge != 1) _Pille('${zahlText(m.menge)} pro Einnahme'),
            if (zustandPille != null) _Pille(zustandPille, farbe: warn != null && m.zustand == MedikamentZustand.aktiv ? kWarn : kTextMuted),
          ],
        ),
        const SizedBox(height: 16),
        if (m.bestand != null) ...[
          _Abschnitt(
            label: 'vorrat',
            kind: _VorratBalken(m: m, prognose: prognose!, warn: warn),
          ),
          const SizedBox(height: 12),
        ],
        LxCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              if (rezept != null) _Zeile('Rezept', 'bis ${datumLang(rezept)} · ${rezeptText(_tageBis(rezept, jetzt))}', farbe: rezeptWarnTage(e, jetzt) != null ? kWarn : null),
              _Zeile('Erinnerung an', subjektKind ? '$name, alle Eltern und Admins' : 'nur dich'),
              _Zeile('Sichtbar für', subjektKind ? '$name, alle Eltern und Admins (fest)' : 'nur dich (fest)'),
              if (m.notiz.trim().isNotEmpty) _Zeile('Notiz', m.notiz),
              if (m.zustand != MedikamentZustand.aktiv && m.zustandAb != null) _Zeile(m.zustand == MedikamentZustand.beendet ? 'Beendet ab' : 'Pausiert ab', datumLang(tagLesen(m.zustandAb!)!)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (m.rhythmus.festeZeiten) ...[
          const MonoLabel('// letzte 7 tage', color: kTextMuted),
          const SizedBox(height: 8),
          _VerlaufReihe(tage: v),
          if (verlaufText(v) != null) ...[const SizedBox(height: 6), Text(verlaufText(v)!, style: const TextStyle(fontSize: 13, color: kTextMuted))],
          const SizedBox(height: 16),
        ],
        if (letzte.isNotEmpty) ...[
          const MonoLabel('// letzte einträge', color: kTextMuted),
          const SizedBox(height: 4),
          for (final x in letzte) _EintragZeile(einnahme: x, onZurueck: () => _tun(() => ref.read(medikamentRepositoryProvider).einnahmeZuruecknehmen(x.id))),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (m.bestand != null || m.packung != null) OutlinedButton.icon(onPressed: () => unawaited(_auffuellen(m)), icon: const Icon(Icons.inventory_2_outlined), label: const Text('Packung aufgefüllt'), style: _knopf),
            OutlinedButton.icon(onPressed: () => unawaited(einnahmeNachtragenOeffnen(context, ref, e)), icon: const Icon(Icons.history), label: const Text('Einnahme nachtragen'), style: _knopf),
            OutlinedButton.icon(onPressed: () => unawaited(medikamentEditorOeffnen(context, id: e.id)), icon: const Icon(Icons.edit_outlined), label: const Text('Bearbeiten'), style: _knopf),
            if (m.zustand == MedikamentZustand.aktiv) ...[
              OutlinedButton.icon(onPressed: () => unawaited(_pausieren()), icon: const Icon(Icons.pause_circle_outline), label: const Text('Pausieren'), style: _knopf),
              OutlinedButton.icon(onPressed: () => unawaited(_beenden()), icon: const Icon(Icons.stop_circle_outlined), label: const Text('Beenden'), style: _knopf),
            ] else
              OutlinedButton.icon(onPressed: () => unawaited(_tun(() => ref.read(medikamentRepositoryProvider).fortsetzen(widget.id))), icon: const Icon(Icons.play_circle_outline), label: const Text('Fortsetzen'), style: _knopf),
          ],
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: kDanger, minimumSize: const Size(44, 48)),
            onPressed: () => unawaited(_loeschen()),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Endgültig löschen'),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Die App ist kein Medizinprodukt: Sie gibt keine Hinweise zu Wechselwirkungen oder Dosierung, sie erinnert nur und führt Protokoll.', style: TextStyle(fontSize: 12, color: kTextMuted, height: 1.35)),
      ],
    );
  }
}

final _knopf = OutlinedButton.styleFrom(minimumSize: const Size(48, 48));

int _tageBis(DateTime tag, DateTime jetzt) => tag.difference(familienTag(jetzt)).inDays;

class _Pille extends StatelessWidget {
  final String text;
  final Color farbe;
  const _Pille(this.text, {this.farbe = kTextMuted});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(border: Border.all(color: farbe == kTextMuted ? kBorder : farbe.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(99)),
    child: Text(text, style: TextStyle(fontSize: 12, color: farbe == kTextMuted ? kText : farbe)),
  );
}

class _Abschnitt extends StatelessWidget {
  final String label;
  final Widget kind;
  const _Abschnitt({required this.label, required this.kind});

  @override
  Widget build(BuildContext context) => LxCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [MonoLabel('// $label', color: kTextMuted), const SizedBox(height: 8), kind]),
  );
}

class _Zeile extends StatelessWidget {
  final String label;
  final String wert;
  final Color? farbe;
  const _Zeile(this.label, this.wert, {this.farbe});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label: $wert',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 112, child: Text(label, style: const TextStyle(fontSize: 13, color: kTextMuted))),
          Expanded(child: Text(wert, style: TextStyle(fontSize: 13, color: farbe))),
        ],
      ),
    ),
  );
}

class _VorratBalken extends StatelessWidget {
  final MedikamentInhalt m;
  final VorratPrognose prognose;
  final int? warn;
  const _VorratBalken({required this.m, required this.prognose, required this.warn});

  @override
  Widget build(BuildContext context) {
    final tage = prognose.tage;
    final text = prognose.keinVerbrauch ? 'Kein Verbrauch geplant' : (prognose.reichtLange ? 'reicht lange' : vorratText(tage ?? 0));
    final anteil = prognose.reichtLange ? 1.0 : (tage == null ? 0.0 : (tage / 30).clamp(0.0, 1.0));
    final farbe = warn != null ? kWarn : kTerminal;
    final bestand = prognose.bestand ?? 0;
    return Semantics(
      container: true,
      label: 'Vorrat: $text. Bestand ${zahlText(bestand)}${m.packung == null ? '' : ', Packung ${zahlText(m.packung!)}'}. Warnung ab $kVorratWarnTage Tagen',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text[0].toUpperCase() + text.substring(1), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: farbe)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: anteil, minHeight: 10, color: farbe, backgroundColor: kBorder),
          ),
          const SizedBox(height: 8),
          Text('Warnung ab $kVorratWarnTage Tagen · Bestand: ${zahlText(bestand)}${m.packung == null ? '' : ' · Packung: ${zahlText(m.packung!)}'}', style: const TextStyle(fontSize: 12, color: kTextMuted)),
        ],
      ),
    );
  }
}

class _VerlaufReihe extends StatelessWidget {
  final List<VerlaufTag> tage;
  const _VerlaufReihe({required this.tage});

  @override
  Widget build(BuildContext context) {
    final beschr = [
      for (final t in tage)
        '${wochentagLang(t.tag.weekday)}: ${switch (t.stand) {
          VerlaufStand.genommen => 'genommen',
          VerlaufStand.verpasst => 'verpasst',
          VerlaufStand.offen => 'noch offen',
          VerlaufStand.keinPlan => 'nichts geplant',
        }}',
    ];
    return Semantics(
      container: true,
      label: 'Letzte ${tage.length} Tage. ${beschr.join(', ')}',
      excludeSemantics: true,
      child: Row(
        children: [
          for (final t in tage)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Column(
                  children: [
                    Container(
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: switch (t.stand) {
                          VerlaufStand.genommen => kTerminal.withValues(alpha: 0.2),
                          VerlaufStand.verpasst => kDanger.withValues(alpha: 0.2),
                          _ => kSurface,
                        },
                        border: Border.all(color: switch (t.stand) {
                          VerlaufStand.genommen => kTerminal.withValues(alpha: 0.6),
                          VerlaufStand.verpasst => kDanger.withValues(alpha: 0.6),
                          _ => kBorder,
                        }),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        switch (t.stand) {
                          VerlaufStand.genommen => Icons.check,
                          VerlaufStand.verpasst => Icons.close,
                          VerlaufStand.offen => Icons.more_horiz,
                          VerlaufStand.keinPlan => Icons.remove,
                        },
                        size: 16,
                        color: switch (t.stand) {
                          VerlaufStand.genommen => kTerminal,
                          VerlaufStand.verpasst => kDanger,
                          _ => kTextMuted,
                        },
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(wochentagKurz(t.tag.weekday), style: const TextStyle(fontFamily: kFontMono, fontSize: 10, color: kTextMuted)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EintragZeile extends StatelessWidget {
  final EinnahmeAnsicht einnahme;
  final VoidCallback onZurueck;
  const _EintragZeile({required this.einnahme, required this.onZurueck});

  @override
  Widget build(BuildContext context) {
    final i = einnahme.inhalt!;
    final w = i.um.toLocal();
    final tag = DateTime.utc(w.year, w.month, w.day);
    final status = i.status == EinnahmeStatus.genommen ? 'genommen' : 'übersprungen';
    final text = '${datumKurz(tag)}, ${uhrzeitVon(i.um)} Uhr · $status${i.geplant == null ? ' · außer der Reihe' : ''}';
    return Row(
      children: [
        Expanded(child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(text, style: const TextStyle(fontSize: 13)))),
        IconButton(tooltip: 'Eintrag vom ${datumKurz(tag)} zurücknehmen', icon: const Icon(Icons.undo, size: 20), onPressed: onZurueck, constraints: const BoxConstraints(minWidth: 48, minHeight: 48)),
      ],
    );
  }
}

class _AuffuellenDialog extends StatefulWidget {
  final double? packung;
  const _AuffuellenDialog({required this.packung});

  @override
  State<_AuffuellenDialog> createState() => _AuffuellenDialogState();
}

class _AuffuellenDialogState extends State<_AuffuellenDialog> {
  late final _anzahl = TextEditingController(text: '1');
  String? _fehler;

  @override
  void dispose() {
    _anzahl.dispose();
    super.dispose();
  }

  void _ok() {
    final z = double.tryParse(_anzahl.text.trim().replaceAll(',', '.'));
    if (z == null || z <= 0 || z > kMaxBestand) {
      setState(() => _fehler = 'Gib eine Zahl größer als 0 ein.');
      return;
    }
    final mitPackung = widget.packung != null;
    if (mitPackung && z != z.roundToDouble()) {
      setState(() => _fehler = 'Gib ganze Packungen ein.');
      return;
    }
    Navigator.of(context).pop(mitPackung ? (packungen: z.round(), stueck: 0.0) : (packungen: 0, stueck: z));
  }

  @override
  Widget build(BuildContext context) {
    final mitPackung = widget.packung != null;
    return AlertDialog(
      title: const Text('Packung aufgefüllt'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(mitPackung ? 'Wie viele Packungen (je ${zahlText(widget.packung!)} Stück) hast du aufgefüllt?' : 'Wie viele Stück hast du aufgefüllt?', style: const TextStyle(color: kTextMuted)),
          const SizedBox(height: 12),
          TextField(
            controller: _anzahl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: mitPackung ? 'Packungen' : 'Stück', errorText: _fehler),
            onSubmitted: (_) => _ok(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
        FilledButton(onPressed: _ok, child: const Text('Auffüllen')),
      ],
    );
  }
}
