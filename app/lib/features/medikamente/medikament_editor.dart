// Medikament anlegen und bearbeiten (Abschnitt 6k): Name, Dosis, Person (Ich und die eigenen Kinder), Rhythmus, Uhrzeiten, Vorrat (Bestand, Packung, Menge je Einnahme), Rezept (optional) und Notiz.
// Wer es sehen darf, ist fest (nur die Person, bei Kindern zusätzlich alle Eltern und Admins) und nicht einstellbar; die Hinweiskarte sagt das. Ein Rezept-Datum kann für ein KIND zusätzlich eine
// neutrale Frist "Rezept erneuern" im Fristen-Tracker anlegen (nur für Eltern sichtbar, ohne Namen von Medikament oder Person; Fristen liegen unverschlüsselt auf dem Server). Für Erwachsene gibt es
// diese Verknüpfung bewusst nicht: ihre Frist wäre für andere Erwachsene sichtbar.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show Role, UserDto;
import '../../data/medikamente/medikament_heute.dart' show kVorratWarnTage;
import '../../data/medikamente/medikament_logik.dart';
import '../../data/medikamente/medikament_modelle.dart';
import '../../data/medikamente/medikament_repository.dart';
import '../../data/medikamente/medikament_state.dart';
import '../../data/tasks/aufgabe_logik.dart' show AufgabeSicht;
import '../../data/tasks/aufgabe_repository.dart';
import '../../data/tasks/fristen_logik.dart' show fristVorwarnMin;
import '../../ui/widgets.dart';
import '../../widgets/ungespeichert_schutz.dart';
import '../auth/auth_widgets.dart';
import '../calendar/kalender_widgets.dart' show PersonKapsel;
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'medikament_anzeige.dart';

/// Öffnet den Editor: [id] = bearbeiten, sonst neu (für [subjektId] oder, ohne Angabe, für die Person selbst).
Future<void> medikamentEditorOeffnen(BuildContext context, {String? id, String? subjektId}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => MedikamentEditor(id: id, subjektId: subjektId)));

/// Titel der Frist, die für ein Kind angelegt werden kann (neutral: nie ein Name von Medikament oder Person).
const String kRezeptFristTitel = 'Rezept erneuern';

/// Vorwarnzeit dieser Frist in Tagen.
const int kRezeptFristVorwarnTage = 14;

class MedikamentEditor extends ConsumerStatefulWidget {
  final String? id;
  final String? subjektId;
  const MedikamentEditor({super.key, this.id, this.subjektId});

  @override
  ConsumerState<MedikamentEditor> createState() => _MedikamentEditorState();
}

class _MedikamentEditorState extends ConsumerState<MedikamentEditor> {
  final _name = TextEditingController();
  final _dosis = TextEditingController();
  final _menge = TextEditingController(text: '1');
  final _bestand = TextEditingController();
  final _packung = TextEditingController();
  final _notiz = TextEditingController();
  String? _subjekt;
  var _art = RhythmusArt.taeglich;
  var _tage = <int>{};
  var _alleN = 2;
  var _zeiten = <String>['08:00'];
  DateTime? _rezept;
  var _alsFrist = false;
  String? _fehler;
  var _speichert = false;
  var _geladen = false;
  MedikamentInhalt? _alt;
  String? _bestandAusgang;
  String? _ausgang;

  bool get _neu => widget.id == null;

  String _stand() => [_name.text, _dosis.text, _menge.text, _bestand.text, _packung.text, _notiz.text, _subjekt, _art, ([..._tage]..sort()), _alleN, _zeiten, _rezept, _alsFrist].join('|');

  @override
  void dispose() {
    for (final c in [_name, _dosis, _menge, _bestand, _packung, _notiz]) {
      c.dispose();
    }
    super.dispose();
  }

  // Beim Bearbeiten wird einmal aus dem Plan gefüllt, sobald er gelesen ist
  void _laden(MedDaten d) {
    if (_geladen) return;
    final id = widget.id;
    if (id == null) {
      _subjekt = widget.subjektId ?? d.ich;
      _geladen = true;
      return;
    }
    final e = d.eintrag(id);
    final m = e?.inhalt;
    if (e == null || m == null) return;
    _alt = m;
    _subjekt = e.subjektId;
    _name.text = m.name;
    _dosis.text = m.dosis;
    _menge.text = zahlText(m.menge);
    final jetzt = bestandJetzt(m, e.einnahmen);
    _bestand.text = jetzt == null ? '' : zahlText(jetzt);
    _bestandAusgang = _bestand.text;
    _packung.text = m.packung == null ? '' : zahlText(m.packung!);
    _notiz.text = m.notiz;
    _art = m.rhythmus.art;
    _tage = {...m.rhythmus.wochentage};
    if (m.rhythmus.art == RhythmusArt.intervall) _alleN = m.rhythmus.alleNTage;
    _zeiten = [...m.zeiten];
    _rezept = m.rezeptDatum == null ? null : tagLesen(m.rezeptDatum!);
    _geladen = true;
  }

  double? _zahl(String t) => double.tryParse(t.trim().replaceAll(',', '.'));

  void _fehlerSetzen(String text) {
    if (mounted) {
      setState(() {
        _speichert = false;
        _fehler = text;
      });
    }
  }

  Future<void> _speichern(MedDaten d) async {
    if (_speichert) return;
    final name = _name.text.trim();
    if (name.isEmpty) return _fehlerSetzen('Gib dem Medikament einen Namen.');
    final subjekt = _subjekt;
    if (subjekt == null || d.person(subjekt) == null) return _fehlerSetzen('Wähle, für wen der Plan gilt.');
    final menge = _zahl(_menge.text);
    if (menge == null || menge <= 0 || menge > kMaxMenge) return _fehlerSetzen('Gib die Menge je Einnahme als Zahl größer als 0 ein.');
    final festeZeiten = _art != RhythmusArt.bedarf;
    if (festeZeiten && _zeiten.isEmpty) return _fehlerSetzen('Füge mindestens eine Uhrzeit hinzu.');
    if (_art == RhythmusArt.wochentage && _tage.isEmpty) return _fehlerSetzen('Wähle mindestens einen Wochentag.');
    final bestandText = _bestand.text.trim();
    final bestand = bestandText.isEmpty ? null : _zahl(bestandText);
    if (bestandText.isNotEmpty && (bestand == null || bestand < 0 || bestand > kMaxBestand)) return _fehlerSetzen('Der Bestand muss eine Zahl von 0 aufwärts sein.');
    final packungText = _packung.text.trim();
    final packung = packungText.isEmpty ? null : _zahl(packungText);
    if (packungText.isNotEmpty && (packung == null || packung <= 0 || packung > kMaxBestand)) return _fehlerSetzen('Die Packungsgröße muss eine Zahl größer als 0 sein.');
    final heute = tagText(familienTag(DateTime.now()));
    final rhythmus = switch (_art) {
      RhythmusArt.taeglich => const Rhythmus.taeglich(),
      RhythmusArt.bedarf => const Rhythmus.bedarf(),
      RhythmusArt.wochentage => Rhythmus.wochentage(_tage),
      RhythmusArt.intervall => Rhythmus.intervall(_alleN, ab: _alt?.rhythmus.art == RhythmusArt.intervall && _alt!.rhythmus.alleNTage == _alleN ? _alt!.rhythmus.ab! : heute),
    };
    final zeiten = festeZeiten ? ([..._zeiten]..sort()) : <String>[];
    final jetztUtc = DateTime.now().toUtc();
    final bestandGeaendert = bestandText != (_bestandAusgang ?? '');
    final base = _alt;
    final MedikamentInhalt inhalt;
    if (base == null) {
      inhalt = MedikamentInhalt(
        name: name,
        dosis: _dosis.text.trim(),
        rhythmus: rhythmus,
        zeiten: zeiten,
        menge: menge,
        beginn: heute,
        bestand: bestand,
        bestandStand: bestand == null ? null : jetztUtc,
        packung: packung,
        rezeptDatum: _rezept == null ? null : tagText(_rezept!),
        notiz: _notiz.text.trim(),
      );
    } else {
      inhalt = base.kopie(
        name: name,
        dosis: _dosis.text.trim(),
        rhythmus: rhythmus,
        zeiten: zeiten,
        menge: menge,
        bestand: bestandGeaendert ? () => bestand : null,
        bestandStand: bestandGeaendert ? () => bestand == null ? null : jetztUtc : null,
        packung: () => packung,
        rezeptDatum: () => _rezept == null ? null : tagText(_rezept!),
        notiz: _notiz.text.trim(),
      );
    }
    if (!inhalt.gueltig) return _fehlerSetzen('Die Eingaben sind nicht stimmig. Prüfe Uhrzeiten, Menge und Vorrat.');
    final repo = ref.read(medikamentRepositoryProvider);
    final aufgaben = ref.read(aufgabeRepositoryProvider);
    final nav = Navigator.of(context);
    final person = d.person(subjekt)?.displayName.split(RegExp(r'\s+')).first;
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      if (base == null) {
        await repo.anlegen(subjekt, inhalt);
      } else {
        await repo.aendern(widget.id!, inhalt);
      }
    } on Object catch (e) {
      return _fehlerSetzen(medFehlerText(e, person: person));
    }
    // Frist nur für ein Kind, nur durch ein Elternteil/einen Admin, nur auf Wunsch (neutral, nur für Eltern sichtbar, ohne Namen)
    if (_alsFrist && _rezept != null && _fristMoeglich(d, subjekt)) {
      try {
        await aufgaben.anlegen(
          AufgabeEingabe(
            titel: kRezeptFristTitel,
            faellig: _rezept,
            sicht: AufgabeSicht.parents,
            erinnerungMin: fristVorwarnMin(kRezeptFristVorwarnTage),
            frist: true,
          ),
        );
      } on Object {
        // Der Plan ist gespeichert; nur die Frist ließ sich nicht anlegen
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Der Plan ist gespeichert, die Frist konnte nicht angelegt werden.')));
        }
      }
    }
    if (mounted) nav.pop();
  }

  bool _fristMoeglich(MedDaten d, String subjekt) {
    final ichErwachsen = d.ichRolle == Role.admin || d.ichRolle == Role.parent;
    final kind = d.person(subjekt)?.role == Role.child;
    return ichErwachsen && kind && subjekt.toLowerCase() != d.ich?.toLowerCase();
  }

  Future<void> _zeitWaehlen({int? index}) async {
    final start = index == null ? TimeOfDay.now() : TimeOfDay(hour: int.parse(_zeiten[index].substring(0, 2)), minute: int.parse(_zeiten[index].substring(3)));
    final t = await showTimePicker(useRootNavigator: false, context: context, initialTime: start);
    if (t == null || !mounted) return;
    final text = zeitText(t.hour * 60 + t.minute);
    setState(() {
      final neu = [..._zeiten];
      if (index != null) neu.removeAt(index);
      if (!neu.contains(text)) neu.add(text);
      neu.sort();
      _zeiten = neu;
    });
  }

  Future<void> _rezeptWaehlen() async {
    final start = _rezept ?? familienTag(DateTime.now());
    final d = await showDatePicker(
      useRootNavigator: false,
      context: context,
      initialDate: DateTime(start.year, start.month, start.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2199, 12, 30),
      locale: const Locale('de', 'DE'),
    );
    if (d != null && mounted) setState(() => _rezept = DateTime.utc(d.year, d.month, d.day));
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(medAnsichtProvider);
    _laden(daten);
    _ausgang ??= _geladen ? _stand() : null;
    if (!_geladen) {
      return AuthSeite(
        label: 'Medikament',
        titel: 'Medikament',
        maxBreite: kMaxContentWidth,
        kinder: [if (!daten.geladen) const Center(child: CircularProgressIndicator()) else const MeldungsBox('Dieses Medikament lässt sich gerade nicht bearbeiten.', fehler: false)],
      );
    }
    final subjekt = _subjekt;
    final kindPlan = subjekt != null && daten.person(subjekt)?.role == Role.child && subjekt.toLowerCase() != daten.ich?.toLowerCase();
    final fristMoeglich = subjekt != null && _fristMoeglich(daten, subjekt);
    final festeZeiten = _art != RhythmusArt.bedarf;
    return UngespeichertSchutz(
      geaendert: () => _ausgang != null && _stand() != _ausgang,
      aenderungen: Listenable.merge([_name, _dosis, _menge, _bestand, _packung, _notiz]),
      child: AuthSeite(
        label: _neu ? 'Neu' : 'Bearbeiten',
        titel: _neu ? 'Medikament anlegen' : 'Medikament bearbeiten',
        maxBreite: kMaxContentWidth,
        fussleiste: FilledButton(onPressed: _speichert ? null : () => unawaited(_speichern(daten)), child: Text(_neu ? 'Speichern' : 'Änderungen speichern')),
        kinder: [
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
          TextField(controller: _name, maxLength: kMaxNameZeichen, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Name', counterText: '')),
          const SizedBox(height: 12),
          TextField(controller: _dosis, maxLength: kMaxDosisZeichen, decoration: const InputDecoration(labelText: 'Dosis (z. B. 5 mg · 1 Tablette)', counterText: '')),
          const SizedBox(height: 16),
          if (_neu && daten.personen.length > 1) ...[
            const MonoLabel('Für wen (nur du und deine Kinder)'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final u in daten.personen)
                  PersonKapsel(
                    u: u,
                    gewaehlt: subjekt != null && subjekt.toLowerCase() == u.id.toLowerCase(),
                    beschriftung: u.id.toLowerCase() == daten.ich?.toLowerCase() ? 'Für mich' : 'Für ${u.displayName}',
                    onTap: () => setState(() {
                      _subjekt = u.id;
                      if (!_fristMoeglich(daten, u.id)) _alsFrist = false;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ] else if (!_neu && subjekt != null) ...[
            Text('Für ${_personText(daten.person(subjekt), daten)}', style: const TextStyle(color: kTextMuted)),
            const SizedBox(height: 16),
          ],
          const MonoLabel('Rhythmus'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (a, t) in const [(RhythmusArt.taeglich, 'Täglich'), (RhythmusArt.wochentage, 'Wochentage'), (RhythmusArt.intervall, 'Alle N Tage'), (RhythmusArt.bedarf, 'Bei Bedarf')])
                AuswahlKnopf(text: t, gewaehlt: _art == a, onTap: () => setState(() => _art = a)),
            ],
          ),
          if (_art == RhythmusArt.wochentage) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var d = 1; d <= 7; d++)
                  AuswahlKnopf(text: wochentagKurz(d), gewaehlt: _tage.contains(d), onTap: () => setState(() => _tage = _tage.contains(d) ? ({..._tage}..remove(d)) : {..._tage, d})),
              ],
            ),
          ],
          if (_art == RhythmusArt.intervall) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                IconButton(tooltip: 'Einen Tag weniger', icon: const Icon(Icons.remove_circle_outline), constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: _alleN > 2 ? () => setState(() => _alleN--) : null),
                Semantics(liveRegion: true, label: 'Alle $_alleN Tage', child: ExcludeSemantics(child: Text('Alle $_alleN Tage', style: const TextStyle(fontSize: 16)))),
                IconButton(tooltip: 'Einen Tag mehr', icon: const Icon(Icons.add_circle_outline), constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: _alleN < 365 ? () => setState(() => _alleN++) : null),
              ],
            ),
            if (_alt?.rhythmus.art != RhythmusArt.intervall) const Text('Gezählt ab heute.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
          const SizedBox(height: 16),
          if (festeZeiten) ...[
            const MonoLabel('Uhrzeiten'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _zeiten.length; i++)
                  Container(
                    decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          button: true,
                          label: 'Uhrzeit ${_zeiten[i]} ändern',
                          excludeSemantics: true,
                          child: InkWell(
                            key: ValueKey('med-zeit:$i'),
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => unawaited(_zeitWaehlen(index: i)),
                            child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 6, 12), child: Text(_zeiten[i], style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 15))),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Uhrzeit ${_zeiten[i]} entfernen',
                          icon: const Icon(Icons.close, size: 18),
                          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                          onPressed: () => setState(() => _zeiten = [..._zeiten]..removeAt(i)),
                        ),
                      ],
                    ),
                  ),
                if (_zeiten.length < kMaxZeiten) OutlinedButton.icon(onPressed: () => unawaited(_zeitWaehlen()), icon: const Icon(Icons.add), label: const Text('Zeit'), style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48))),
              ],
            ),
            const SizedBox(height: 16),
          ] else ...[
            const Text('Ohne feste Uhrzeiten: Du trägst die Einnahme selbst ein, es gibt keine Erinnerung.', style: TextStyle(fontSize: 12, color: kTextMuted)),
            const SizedBox(height: 16),
          ],
          const MonoLabel('Vorrat (optional)'),
          const SizedBox(height: 6),
          TextField(controller: _menge, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Menge je Einnahme (Stück)')),
          const SizedBox(height: 12),
          TextField(controller: _bestand, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Bestand jetzt (Stück)')),
          const SizedBox(height: 12),
          TextField(controller: _packung, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Stück je Packung')),
          const SizedBox(height: 6),
          const Text('Die App warnt, wenn der Vorrat noch höchstens $kVorratWarnTage Tage reicht.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          const SizedBox(height: 16),
          const MonoLabel('Rezept läuft ab (optional)'),
          const SizedBox(height: 6),
          Row(
            children: [
              Flexible(
                child: Semantics(
                  button: true,
                  label: 'Rezept läuft ab, ${_rezept == null ? 'nicht gewählt' : datumLang(_rezept!)}. Ändern',
                  excludeSemantics: true,
                  onTap: () => unawaited(_rezeptWaehlen()),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => unawaited(_rezeptWaehlen()),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48, maxWidth: 280),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.event, size: 18, color: kTextMuted), const SizedBox(width: 8), Flexible(child: Text(_rezept == null ? 'Datum wählen' : datumLang(_rezept!), maxLines: 1, overflow: TextOverflow.ellipsis))]),
                    ),
                  ),
                ),
              ),
              if (_rezept != null) IconButton(tooltip: 'Rezept-Datum entfernen', icon: const Icon(Icons.close), constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: () => setState(() {
                _rezept = null;
                _alsFrist = false;
              })),
            ],
          ),
          if (_rezept != null && fristMoeglich) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Zusätzlich als Frist anlegen'),
              subtitle: const Text('Im Fristen-Tracker erscheint „$kRezeptFristTitel“, nur für Eltern sichtbar, ohne Namen von Medikament oder Kind. Fristen sind nicht verschlüsselt.', style: TextStyle(fontSize: 12, color: kTextMuted)),
              value: _alsFrist,
              onChanged: (v) => setState(() => _alsFrist = v),
            ),
          ] else if (_rezept != null) ...[
            const SizedBox(height: 6),
            const Text('Die App weist dich in der Übersicht auf das Ablaufen hin. Eine Frist im Fristen-Tracker gibt es nur für Kinder, denn Fristen sind nicht verschlüsselt.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
          const SizedBox(height: 16),
          TextField(controller: _notiz, maxLength: kMaxNotizZeichen, minLines: 2, maxLines: 5, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Notiz (optional)', counterText: '', alignLabelWithHint: true)),
          const SizedBox(height: 16),
          _SichtKarte(kind: kindPlan),
        ],
      ),
    );
  }

  String _personText(UserDto? u, MedDaten d) => u == null ? 'eine Person' : (u.id.toLowerCase() == d.ich?.toLowerCase() ? 'dich' : u.displayName);
}

/// Feste Hinweiskarte: wer den Plan sieht (nicht einstellbar).
class _SichtKarte extends StatelessWidget {
  final bool kind;
  const _SichtKarte({required this.kind});

  @override
  Widget build(BuildContext context) {
    final titel = kind ? 'Sichtbar für das Kind und alle Eltern' : 'Sichtbar nur für dich';
    const text = 'Bei Medikamenten eines Kindes sehen alle Eltern und Admins sie, sonst niemand. Das ist fest und nicht einstellbar. Name und Dosis sind Ende-zu-Ende verschlüsselt, die Erinnerung nennt nie das Medikament.';
    return Semantics(
      container: true,
      label: '$titel. $text',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(18)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.lock_outline, size: 20, color: kAccent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text(text, style: TextStyle(fontSize: 12, color: kTextMuted, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
