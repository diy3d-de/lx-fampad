// Vorsorge und Impfungen: die Dialoge und das Auswahlblatt (Profil, "Erledigt eintragen", Eintrag bearbeiten, Vorlagen hinzufügen). Alle mit `useRootNavigator: false` (Desktop-Shell).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/medikamente/medikament_modelle.dart' show tagLesen;
import '../../data/vorsorge/vorsorge_logik.dart';
import '../../data/vorsorge/vorsorge_modelle.dart';
import '../../data/vorsorge/vorsorge_repository.dart';
import '../../data/vorsorge/vorsorge_state.dart';
import '../../data/vorsorge/vorsorge_vorlagen.dart';
import '../../ui/widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'vorsorge_anzeige.dart';

/// Ein Feld, das einen Datumswähler öffnet (Touch-Ziel mindestens 48 px).
class _DatumFeld extends StatelessWidget {
  final IconData icon;
  final String text;
  final String semantik;
  final VoidCallback onTap;
  const _DatumFeld({required this.icon, required this.text, required this.semantik, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semantik,
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: kTextMuted),
            const SizedBox(width: 8),
            Flexible(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    ),
  );
}

Future<DateTime?> _datumWaehlen(BuildContext context, {required DateTime start, required DateTime erster, required DateTime letzter}) => showDatePicker(
  useRootNavigator: false,
  context: context,
  initialDate: DateTime(start.year, start.month, start.day),
  firstDate: DateTime(erster.year, erster.month, erster.day),
  lastDate: DateTime(letzter.year, letzter.month, letzter.day),
  locale: const Locale('de', 'DE'),
);

// ------------------------------------------------------------------ Profil

/// Fragt Geburtsdatum und Geschlecht der Person ab und speichert das Profil. Liefert true, wenn gespeichert wurde.
Future<bool> vorsorgeProfilOeffnen(BuildContext context, {required String subjektId, required String personName, VorsorgeProfilInhalt? bisher}) async =>
    await showDialog<bool>(context: context, useRootNavigator: false, builder: (_) => _ProfilDialog(subjektId: subjektId, personName: personName, bisher: bisher)) == true;

class _ProfilDialog extends ConsumerStatefulWidget {
  final String subjektId;
  final String personName;
  final VorsorgeProfilInhalt? bisher;
  const _ProfilDialog({required this.subjektId, required this.personName, this.bisher});

  @override
  ConsumerState<_ProfilDialog> createState() => _ProfilDialogState();
}

class _ProfilDialogState extends ConsumerState<_ProfilDialog> {
  DateTime? _geburt;
  VorsorgeGeschlecht? _geschlecht;
  String? _fehler;
  var _speichert = false;

  @override
  void initState() {
    super.initState();
    _geburt = widget.bisher?.geburtTag;
    _geschlecht = widget.bisher?.geschlecht;
  }

  Future<void> _waehlen() async {
    final heute = vorsorgeHeute();
    final d = await _datumWaehlen(context, start: _geburt ?? DateTime.utc(heute.year - 30, heute.month, heute.day), erster: DateTime.utc(1900), letzter: heute);
    if (d != null && mounted) setState(() => _geburt = DateTime.utc(d.year, d.month, d.day));
  }

  Future<void> _speichern() async {
    if (_speichert) return;
    final g = _geburt;
    if (g == null) {
      setState(() => _fehler = 'Wähle das Geburtsdatum.');
      return;
    }
    final nav = Navigator.of(context);
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      await ref.read(vorsorgeRepositoryProvider).profilSetzen(widget.subjektId, VorsorgeProfilInhalt(geburt: vorsorgeTagText(g), geschlecht: _geschlecht));
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = vorsorgeFehlerText(e, person: widget.personName);
        });
      }
      return;
    }
    if (mounted) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Profil von ${widget.personName}'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Die App braucht das Geburtsdatum, um auszurechnen, wann etwas ansteht. Die Angaben liegen nur verschlüsselt bei dir und, bei Kindern, bei den Eltern. Der Server sieht sie nie.',
          style: TextStyle(color: kTextMuted, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 14),
        const MonoLabel('Geburtsdatum'),
        const SizedBox(height: 6),
        _DatumFeld(icon: Icons.cake_outlined, text: _geburt == null ? 'Datum wählen' : vorsorgeDatum(_geburt!), semantik: 'Geburtsdatum, ${_geburt == null ? 'nicht gewählt' : vorsorgeDatum(_geburt!)}. Ändern', onTap: _waehlen),
        const SizedBox(height: 14),
        const MonoLabel('Geschlecht (nur für die Früherkennung, freiwillig)'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AuswahlKnopf(text: 'Keine Angabe', gewaehlt: _geschlecht == null, onTap: () => setState(() => _geschlecht = null)),
            for (final g in VorsorgeGeschlecht.values) AuswahlKnopf(text: g.label, gewaehlt: _geschlecht == g, onTap: () => setState(() => _geschlecht = g)),
          ],
        ),
        if (_fehler != null) ...[const SizedBox(height: 12), Text(_fehler!, style: const TextStyle(color: kDanger, fontSize: 13))],
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
      FilledButton(onPressed: _speichert ? null : _speichern, child: const Text('Speichern')),
    ],
  );
}

// ------------------------------------------------------------------ Erledigt eintragen

/// Trägt ein erledigtes Datum ein (Datum vorbelegt mit heute, Notiz optional). Liefert true, wenn gespeichert wurde.
Future<bool> vorsorgeErledigtOeffnen(BuildContext context, {required String id, DateTime? ab}) async =>
    await showDialog<bool>(context: context, useRootNavigator: false, builder: (_) => _ErledigtDialog(id: id, ab: ab)) == true;

class _ErledigtDialog extends ConsumerStatefulWidget {
  final String id;
  final DateTime? ab;
  const _ErledigtDialog({required this.id, this.ab});

  @override
  ConsumerState<_ErledigtDialog> createState() => _ErledigtDialogState();
}

class _ErledigtDialogState extends ConsumerState<_ErledigtDialog> {
  late DateTime _tag = vorsorgeHeute();
  final _notiz = TextEditingController();
  String? _fehler;
  var _speichert = false;

  @override
  void dispose() {
    _notiz.dispose();
    super.dispose();
  }

  Future<void> _waehlen() async {
    final heute = vorsorgeHeute();
    final d = await _datumWaehlen(context, start: _tag, erster: DateTime.utc(1900), letzter: heute);
    if (d != null && mounted) setState(() => _tag = DateTime.utc(d.year, d.month, d.day));
  }

  Future<void> _speichern() async {
    if (_speichert) return;
    final nav = Navigator.of(context);
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      final n = _notiz.text.trim();
      await ref.read(vorsorgeRepositoryProvider).erledigtEintragen(widget.id, tag: _tag, notiz: n.isEmpty ? null : n);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = vorsorgeFehlerText(e);
        });
      }
      return;
    }
    if (mounted) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Erledigt eintragen'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MonoLabel('Wann war es?'),
        const SizedBox(height: 6),
        _DatumFeld(icon: Icons.event, text: vorsorgeDatum(_tag), semantik: 'Datum, ${vorsorgeDatum(_tag)}. Ändern', onTap: _waehlen),
        const SizedBox(height: 14),
        TextField(
          controller: _notiz,
          maxLength: kMaxVorsorgeNotizZeichen,
          maxLines: 2,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Notiz (freiwillig)', hintText: 'Zum Beispiel Praxis oder Chargennummer'),
        ),
        if (_fehler != null) ...[const SizedBox(height: 8), Text(_fehler!, style: const TextStyle(color: kDanger, fontSize: 13))],
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
      FilledButton(onPressed: _speichert ? null : _speichern, child: const Text('Eintragen')),
    ],
  );
}

// ------------------------------------------------------------------ Eintrag anlegen oder bearbeiten

const _kIntervalle = <int?>[null, 6, 12, 24, 36, 60, 120];
const _kVorlaeufe = <int>[0, 7, 14, 30, 60];

String _intervallText(int? m) => m == null ? 'Keine' : (m % 12 == 0 ? (m == 12 ? 'Jedes Jahr' : 'Alle ${m ~/ 12} Jahre') : 'Alle $m Monate');

/// Legt einen eigenen Eintrag an ([bestehend] null) oder ändert einen (Vorlauf, nächstes Datum, Notiz; bei eigenen Einträgen auch Name, Art und Wiederholung). Liefert true, wenn gespeichert wurde.
Future<bool> vorsorgeEditorOeffnen(BuildContext context, {required String subjektId, String? personName, VorsorgeAnsicht? bestehend}) async =>
    await showDialog<bool>(context: context, useRootNavigator: false, builder: (_) => _EditorDialog(subjektId: subjektId, personName: personName, bestehend: bestehend)) == true;

class _EditorDialog extends ConsumerStatefulWidget {
  final String subjektId;
  final String? personName;
  final VorsorgeAnsicht? bestehend;
  const _EditorDialog({required this.subjektId, this.personName, this.bestehend});

  @override
  ConsumerState<_EditorDialog> createState() => _EditorDialogState();
}

class _EditorDialogState extends ConsumerState<_EditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _notiz;
  late VorsorgeArt _art;
  DateTime? _naechstes;
  int? _intervall;
  late int _vorlauf;
  String? _fehler;
  var _speichert = false;

  VorsorgeEintragInhalt? get _alt => widget.bestehend?.inhalt;
  bool get _eigen => _alt == null || vorsorgeVorlage(_alt!.vorlage) == null;

  @override
  void initState() {
    super.initState();
    final a = _alt;
    _name = TextEditingController(text: a?.name ?? '');
    _notiz = TextEditingController(text: a?.notiz ?? '');
    _art = a?.art ?? VorsorgeArt.vorsorge;
    _naechstes = a?.naechstes == null ? null : tagLesen(a!.naechstes);
    _intervall = a?.intervallMonate;
    _vorlauf = a?.vorlauf ?? kStandardVorsorgeVorlauf;
  }

  @override
  void dispose() {
    _name.dispose();
    _notiz.dispose();
    super.dispose();
  }

  Future<void> _datum() async {
    final heute = vorsorgeHeute();
    final d = await _datumWaehlen(context, start: _naechstes ?? heute, erster: DateTime.utc(heute.year - 1), letzter: DateTime.utc(heute.year + 30, 12, 31));
    if (d != null && mounted) setState(() => _naechstes = DateTime.utc(d.year, d.month, d.day));
  }

  Future<void> _speichern() async {
    if (_speichert) return;
    final name = _name.text.trim();
    if (_eigen && name.isEmpty) {
      setState(() => _fehler = 'Gib dem Eintrag einen Namen.');
      return;
    }
    final alt = _alt;
    final neu = VorsorgeEintragInhalt(
      vorlage: alt?.vorlage,
      name: _eigen ? name : (alt?.name ?? ''),
      art: _eigen ? _art : (alt?.art ?? _art),
      erledigt: alt?.erledigt ?? const [],
      naechstes: _naechstes == null ? null : vorsorgeTagText(_naechstes!),
      intervallMonate: _eigen ? _intervall : alt?.intervallMonate,
      vorlauf: _vorlauf,
      notiz: _notiz.text.trim(),
    );
    final nav = Navigator.of(context);
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      final repo = ref.read(vorsorgeRepositoryProvider);
      if (widget.bestehend == null) {
        await repo.anlegen(widget.subjektId, neu);
      } else {
        await repo.aendern(widget.bestehend!.id, neu);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = vorsorgeFehlerText(e, person: widget.personName);
        });
      }
      return;
    }
    if (mounted) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.bestehend == null ? 'Eigener Eintrag' : 'Eintrag bearbeiten'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_eigen) ...[
          TextField(
            controller: _name,
            maxLength: kMaxVorsorgeNameZeichen,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Wie heißt der Eintrag?', hintText: 'Zum Beispiel Augenarzt'),
          ),
          const SizedBox(height: 8),
          const MonoLabel('Was ist es?'),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final a in VorsorgeArt.values) AuswahlKnopf(text: a.label, gewaehlt: _art == a, onTap: () => setState(() => _art = a))]),
          const SizedBox(height: 14),
          const MonoLabel('Wie oft?'),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final m in _kIntervalle) AuswahlKnopf(text: _intervallText(m), gewaehlt: _intervall == m, onTap: () => setState(() => _intervall = m))]),
          const SizedBox(height: 14),
        ],
        const MonoLabel('Nächstes Datum (freiwillig)'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _DatumFeld(icon: Icons.event, text: _naechstes == null ? 'Kein Datum' : vorsorgeDatum(_naechstes!), semantik: 'Nächstes Datum, ${_naechstes == null ? 'keines' : vorsorgeDatum(_naechstes!)}. Ändern', onTap: _datum),
            if (_naechstes != null) TextButton(onPressed: () => setState(() => _naechstes = null), child: const Text('Datum entfernen')),
          ],
        ),
        const SizedBox(height: 14),
        const MonoLabel('Erinnern'),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final t in _kVorlaeufe) AuswahlKnopf(text: t == 0 ? 'Am Tag selbst' : '$t Tage vorher', gewaehlt: _vorlauf == t, onTap: () => setState(() => _vorlauf = t))]),
        const SizedBox(height: 14),
        TextField(controller: _notiz, maxLength: kMaxVorsorgeNotizZeichen, maxLines: 3, minLines: 1, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Notiz (freiwillig)')),
        if (_fehler != null) ...[const SizedBox(height: 8), Text(_fehler!, style: const TextStyle(color: kDanger, fontSize: 13))],
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
      FilledButton(onPressed: _speichert ? null : _speichern, child: const Text('Speichern')),
    ],
  );
}

// ------------------------------------------------------------------ Vorlagen hinzufügen

/// Öffnet das Auswahlblatt: empfohlene Vorlagen für das Alter zuerst, der Rest eingeklappt, dazu "Eigener Eintrag". Fehlt das Profil, fragt es zuerst danach.
Future<void> vorsorgeHinzufuegenOeffnen(BuildContext context, WidgetRef ref, {required String subjektId, required String personName}) async {
  var daten = ref.read(vorsorgeAnsichtProvider);
  if (daten.profilVon(subjektId) == null) {
    if (daten.profilUnlesbar(subjektId)) return; // nie ein unlesbares Profil überschreiben
    final ok = await vorsorgeProfilOeffnen(context, subjektId: subjektId, personName: personName);
    if (!ok || !context.mounted) return;
    daten = ref.read(vorsorgeAnsichtProvider);
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    backgroundColor: kSurface,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9, maxWidth: kMaxContentWidth),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => _VorlagenBlatt(subjektId: subjektId, personName: personName),
  );
}

class _VorlagenBlatt extends ConsumerStatefulWidget {
  final String subjektId;
  final String personName;
  const _VorlagenBlatt({required this.subjektId, required this.personName});

  @override
  ConsumerState<_VorlagenBlatt> createState() => _VorlagenBlattState();
}

class _VorlagenBlattState extends ConsumerState<_VorlagenBlatt> {
  String? _fehler;
  var _beschaeftigt = false;

  Future<void> _waehlen(VorsorgeVorlage v) async {
    if (_beschaeftigt) return;
    final nav = Navigator.of(context);
    setState(() {
      _beschaeftigt = true;
      _fehler = null;
    });
    try {
      await ref.read(vorsorgeRepositoryProvider).anlegen(widget.subjektId, VorsorgeEintragInhalt(vorlage: v.kennung, art: v.art));
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _beschaeftigt = false;
          _fehler = vorsorgeFehlerText(e, person: widget.personName);
        });
      }
      return;
    }
    if (mounted) nav.pop();
  }

  Future<void> _eigener() async {
    final nav = Navigator.of(context);
    final ok = await vorsorgeEditorOeffnen(context, subjektId: widget.subjektId, personName: widget.personName);
    if (ok && mounted) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(vorsorgeAnsichtProvider);
    final profil = daten.profilVon(widget.subjektId);
    final heute = vorsorgeHeute();
    final vorhanden = {for (final e in daten.von(widget.subjektId)) if (e.inhalt?.vorlage != null) e.inhalt!.vorlage!};
    final frei = [for (final v in kVorsorgeVorlagen) if (!vorhanden.contains(v.kennung)) v];
    final geburt = profil?.geburtTag;
    final empfohlen = geburt == null ? <VorsorgeVorlage>[] : [for (final v in frei) if (vorsorgeEmpfohlen(v, geburt: geburt, geschlecht: profil?.geschlecht, heute: heute)) v];
    final rest = [for (final v in frei) if (!empfohlen.contains(v)) v];
    Widget zeile(VorsorgeVorlage v) => _VorlagenZeile(vorlage: v, onTap: _beschaeftigt ? null : () => _waehlen(v));
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        shrinkWrap: true,
        children: [
          Text('Für ${widget.personName} hinzufügen', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(kVorsorgeHinweis, style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 14),
          if (_fehler != null) ...[Text(_fehler!, style: const TextStyle(color: kDanger, fontSize: 13)), const SizedBox(height: 8)],
          if (empfohlen.isNotEmpty) ...[const MonoLabel('Empfohlen für das Alter', color: kTextMuted), const SizedBox(height: 6), for (final v in empfohlen) zeile(v)],
          if (empfohlen.isEmpty) const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Für das Alter gibt es gerade keine Vorschläge. Unter „Weitere Vorlagen“ findest du den Rest.', style: TextStyle(color: kTextMuted, fontSize: 13))),
          if (rest.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Weitere Vorlagen (${rest.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
                children: [for (final v in rest) zeile(v)],
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _beschaeftigt ? null : _eigener,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Eigener Eintrag'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
        ],
      ),
    );
  }
}

class _VorlagenZeile extends StatelessWidget {
  final VorsorgeVorlage vorlage;
  final VoidCallback? onTap;
  const _VorlagenZeile({required this.vorlage, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final v = vorlage;
    final zusatz = vorsorgeVerlaessigkeitText(v);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        button: true,
        label: '${v.name}. ${v.art.label}. ${zusatz ?? ''} Hinzufügen',
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: kSurface2, borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                Icon(vorsorgeArtSymbol(v.art), size: 20, color: kTextMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(v.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(zusatz == null ? v.art.label : '${v.art.label} · $zusatz', style: const TextStyle(fontSize: 12, color: kTextMuted)),
                    ],
                  ),
                ),
                const Icon(Icons.add, size: 20, color: kAccent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
