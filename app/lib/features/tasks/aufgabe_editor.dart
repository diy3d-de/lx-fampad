// Aufgabe anlegen, ansehen und bearbeiten (eine Seite, wie der Termin-Editor). Zeiten sind Wanduhrzeiten der Familienzone (Europe/Berlin).
// Wer die Aufgabe nicht ändern darf (ein Kind bei fremden Aufgaben), sieht sie schreibgeschützt.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart' show ZeitzonenFehlen;
import '../../data/calendar/zeitzonen.dart';
import '../../data/lists/members.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../../ui/widgets.dart';
import '../../widgets/ungespeichert_schutz.dart';
import '../auth/auth_widgets.dart';
import '../calendar/kalender_widgets.dart' show PersonKapsel;
import '../lists/list_dialogs.dart' show AuswahlKnopf, bestaetigen;

/// Öffnet den Editor. [aufgabe] null = neue Aufgabe.
Future<void> aufgabeEditorOeffnen(BuildContext context, {Aufgabe? aufgabe}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => AufgabeEditor(aufgabe: aufgabe)));

/// Obergrenze der Unteraufgaben je Aufgabe (wie am Server).
const kMaxPunkte = 100;

class _PunktZeile {
  final String id;
  final TextEditingController text;
  bool erledigt;
  _PunktZeile(this.id, String start, this.erledigt) : text = TextEditingController(text: start);
}

class AufgabeEditor extends ConsumerStatefulWidget {
  final Aufgabe? aufgabe;
  const AufgabeEditor({super.key, this.aufgabe});

  @override
  ConsumerState<AufgabeEditor> createState() => _AufgabeEditorState();
}

class _AufgabeEditorState extends ConsumerState<AufgabeEditor> {
  final _titel = TextEditingController();
  final _beschreibung = TextEditingController();
  final _neuerPunkt = TextEditingController();
  DateTime? _tag; // Fälligkeit (Tag, UTC-Markierung), null = ohne
  var _mitUhrzeit = false;
  var _zeit = const TimeOfDay(hour: 9, minute: 0);
  var _prio = AufgabePrio.keine;
  String? _zustaendig;
  var _wdh = AufgabeWdh.keine;
  var _sicht = AufgabeSicht.family;
  int? _erinnerung; // Minuten vor der Fälligkeit, null = keine
  final _punkte = <_PunktZeile>[];
  final _entsorgen = <_PunktZeile>[];
  List<AufgabePunkt> _bisherigePunkte = const [];
  String? _fehler;
  var _speichert = false;

  bool get _neu => widget.aufgabe == null;

  /// Stand der Eingaben (zum Erkennen ungespeicherter Änderungen); der Ausgangsstand wird beim ersten Bauen festgehalten.
  String? _ausgang;
  String _stand() => [
    _titel.text, _beschreibung.text, _neuerPunkt.text, _tag, _mitUhrzeit, _zeit, _prio, _zustaendig, _wdh, _sicht, _erinnerung,
    for (final p in _punkte) '${p.id}|${p.text.text}|${p.erledigt}',
    _entsorgen.length,
  ].join('');

  @override
  void initState() {
    super.initState();
    final a = widget.aufgabe;
    if (a == null) return;
    _titel.text = a.titel;
    _beschreibung.text = a.beschreibung;
    final w = faelligWand(a);
    if (w != null) {
      _tag = DateTime.utc(w.year, w.month, w.day);
      _mitUhrzeit = hatUhrzeit(a);
      if (_mitUhrzeit) _zeit = TimeOfDay(hour: w.hour, minute: w.minute);
    }
    _prio = AufgabePrio.von(a.prioritaet);
    _zustaendig = a.assigneeId;
    _wdh = AufgabeWdh.von(a.wiederholung);
    _sicht = AufgabeSicht.von(a.audience);
    _erinnerung = a.erinnerungMin;
    _bisherigePunkte = sortierePunkte(ref.read(aufgabenDatenProvider).punkteVon(a.id));
    for (final p in _bisherigePunkte) {
      _punkte.add(_PunktZeile(p.id, p.inhalt, p.doneAt != null));
    }
  }

  @override
  void dispose() {
    _titel.dispose();
    _beschreibung.dispose();
    _neuerPunkt.dispose();
    for (final p in [..._punkte, ..._entsorgen]) {
      p.text.dispose();
    }
    super.dispose();
  }

  Future<DateTime?> _tagWaehlen(DateTime aktuell) async {
    final d = await showDatePicker(useRootNavigator: false,
      context: context,
      initialDate: DateTime(aktuell.year, aktuell.month, aktuell.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2199, 12, 30),
      locale: const Locale('de', 'DE'),
    );
    return d == null ? null : DateTime.utc(d.year, d.month, d.day);
  }

  Future<TimeOfDay?> _zeitWaehlen(TimeOfDay aktuell) => showTimePicker(useRootNavigator: false,
    context: context,
    initialTime: aktuell,
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
  );

  void _punktHinzu() {
    final t = _neuerPunkt.text.trim();
    if (t.isEmpty || _punkte.length >= kMaxPunkte) return;
    _neuerPunkt.clear();
    setState(() => _punkte.add(_PunktZeile(ref.read(aufgabeRepositoryProvider).neuePunktId(), t, false)));
  }

  void _punktUmschalten(int i, {required bool sofort}) {
    final p = _punkte[i];
    setState(() => p.erledigt = !p.erledigt);
    if (sofort) unawaited(ref.read(aufgabeRepositoryProvider).punktErledigt(p.id, p.erledigt));
  }

  AufgabeEingabe _eingabe() {
    final tag = _tag;
    return AufgabeEingabe(
      titel: _titel.text.trim(),
      beschreibung: _beschreibung.text,
      faellig: tag == null ? null : (_mitUhrzeit ? DateTime.utc(tag.year, tag.month, tag.day, _zeit.hour, _zeit.minute) : tag),
      mitUhrzeit: tag != null && _mitUhrzeit,
      prioritaet: _prio,
      zustaendig: _zustaendig,
      wiederholung: tag == null ? AufgabeWdh.keine : _wdh,
      sicht: _sicht,
      erinnerungMin: tag == null ? null : _erinnerung,
      punkte: [
        for (final p in _punkte)
          if (p.text.text.trim().isNotEmpty) PunktEingabe(id: p.id, text: p.text.text, erledigt: p.erledigt),
      ],
    );
  }

  Future<void> _speichern() async {
    if (_speichert) return;
    final repo = ref.read(aufgabeRepositoryProvider);
    final nav = Navigator.of(context);
    if (_titel.text.trim().isEmpty) {
      setState(() => _fehler = 'Gib der Aufgabe einen Titel.');
      return;
    }
    // ein noch nicht übernommener Text im Feld "Unteraufgabe" geht nicht verloren
    if (_neuerPunkt.text.trim().isNotEmpty) _punktHinzu();
    if (_mitUhrzeit && _tag != null && !zeitzonenBereit() && !await zeitzonenNeuLaden()) {
      if (mounted) setState(() => _fehler = 'Die Zeitzonen-Daten konnten nicht geladen werden, die Aufgabe wurde nicht gespeichert. Bitte versuche es gleich noch einmal.');
      return;
    }
    setState(() => _speichert = true);
    try {
      final e = _eingabe();
      final alt = widget.aufgabe;
      if (alt == null) {
        await repo.anlegen(e);
      } else {
        await repo.speichern(alt, e, bisherigePunkte: _bisherigePunkte);
      }
    } on ZeitzonenFehlen {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = 'Die Zeitzonen-Daten fehlen, die Aufgabe wurde nicht gespeichert.';
        });
      }
      return;
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = e.message;
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = 'Die Aufgabe konnte nicht gespeichert werden.';
        });
      }
      return;
    }
    if (mounted) nav.pop();
  }

  Future<void> _loeschen() async {
    final a = widget.aufgabe;
    if (a == null) return;
    final repo = ref.read(aufgabeRepositoryProvider);
    final nav = Navigator.of(context);
    final ja = await bestaetigen(context, titel: 'Aufgabe „${a.titel}“ löschen?', text: 'Die Aufgabe und ihre Unteraufgaben werden für alle gelöscht.', knopf: 'Löschen');
    if (!ja) return;
    await repo.loeschen(a.id);
    if (mounted) nav.pop();
  }

  /// Wer die Erinnerung bekommt: die zuständige Person, ohne Zuständige die Person, die die Aufgabe anlegt (bei einer Wiederholung die, die sie erledigt).
  String _erinnerungHinweis(String? ich, List<UserDto> mitglieder) {
    final z = _zustaendig;
    if (z == null) return 'Ohne Zuständige erinnert nur die Person, die die Aufgabe angelegt hat (bei einer Wiederholung die, die sie erledigt).';
    if (z == ich) return 'Die Erinnerung kommt auf deinem Gerät.';
    final name = mitglieder.where((u) => u.id == z).map((u) => u.displayName).firstOrNull ?? 'die zuständige Person';
    return 'Erinnert nur $name, nicht dich.';
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = AufgabeRechte(user?.role ?? Role.child, user?.id);
    _ausgang ??= _stand();
    final darf = _neu ? rechte.darfAnlegen : rechte.darfAendern(widget.aufgabe!);
    // zuständige Person ohne Änderungsrecht: Unteraufgaben abhaken ist erlaubt (wirkt sofort), alles andere nicht
    final statusDarf = !darf && !_neu && rechte.darfStatus(widget.aufgabe!);
    final mitglieder = ref.watch(mitgliederProvider).value ?? const <UserDto>[];
    final datum = DateFormat('E, d. MMM y', 'de_DE');
    final heute = tagVon(DateTime.now());
    final morgen = heute.add(const Duration(days: 1));
    final tag = _tag;

    Widget wahl({required String label, required String text, required VoidCallback? onTap, IconData icon = Icons.event}) => Semantics(
      button: true,
      enabled: onTap != null,
      label: '$label, $text',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              Icon(icon, size: 18, color: kTextMuted),
              const SizedBox(width: 8),
              Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    );

    void nichts() {}
    VoidCallback? nurWenn(VoidCallback f) => darf ? f : null;

    return UngespeichertSchutz(
      geaendert: () => _stand() != _ausgang,
      aenderungen: Listenable.merge([_titel, _beschreibung, _neuerPunkt, for (final p in _punkte) p.text]),
      child: AuthSeite(
      label: '// aufgabe',
      titel: _neu ? 'Neue Aufgabe' : (darf ? 'Aufgabe bearbeiten' : 'Aufgabe'),
      maxBreite: kMaxContentWidth,
      fussleiste: darf ? FilledButton(onPressed: _speichert ? null : _speichern, child: Text(_neu ? 'Aufgabe anlegen' : 'Speichern')) : null,
      kinder: [
        if (!darf) ...[
          MeldungsBox(statusDarf ? 'Diese Aufgabe ist dir zugewiesen: du kannst sie abhaken und ihre Unteraufgaben erledigen, aber nicht ändern.' : 'Du darfst diese Aufgabe ansehen, aber nicht ändern.', fehler: false),
          const SizedBox(height: 12),
        ],
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
        TextField(
          controller: _titel,
          enabled: darf,
          maxLength: 200,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Titel', counterText: ''),
        ),
        const SizedBox(height: 16),
        const MonoLabel('// fällig'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AuswahlKnopf(text: 'Kein Datum', gewaehlt: tag == null, onTap: darf ? () => setState(() => _tag = null) : nichts),
            AuswahlKnopf(text: 'Heute', gewaehlt: tag == heute, onTap: darf ? () => setState(() => _tag = heute) : nichts),
            AuswahlKnopf(text: 'Morgen', gewaehlt: tag == morgen, onTap: darf ? () => setState(() => _tag = morgen) : nichts),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SizedBox(
              width: 210,
              child: wahl(
                label: 'Fälligkeitsdatum',
                text: tag == null ? 'Datum wählen' : datum.format(tag),
                onTap: nurWenn(() async {
                  final d = await _tagWaehlen(tag ?? heute);
                  if (d != null) setState(() => _tag = d);
                }),
              ),
            ),
            if (tag != null && _mitUhrzeit)
              SizedBox(
                width: 112,
                child: wahl(
                  label: 'Fälligkeit Uhrzeit',
                  text: _zeit.format(context),
                  icon: Icons.schedule,
                  onTap: nurWenn(() async {
                    final z = await _zeitWaehlen(_zeit);
                    if (z != null) setState(() => _zeit = z);
                  }),
                ),
              ),
          ],
        ),
        if (tag != null)
          Semantics(
            toggled: _mitUhrzeit,
            label: 'Mit Uhrzeit',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mit Uhrzeit'),
              value: _mitUhrzeit,
              onChanged: darf ? (v) => setState(() => _mitUhrzeit = v) : null,
            ),
          ),
        const SizedBox(height: 12),
        if (mitglieder.isNotEmpty) ...[
          const MonoLabel('// zuständig'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AuswahlKnopf(text: 'Niemand', gewaehlt: _zustaendig == null, onTap: darf ? () => setState(() => _zustaendig = null) : nichts),
              for (final u in mitglieder)
                PersonKapsel(
                  u: u,
                  gewaehlt: _zustaendig == u.id,
                  beschriftung: 'Zuständig ${u.displayName}',
                  onTap: darf ? () => setState(() => _zustaendig = u.id) : nichts,
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (_zustaendig != null && _sicht == AufgabeSicht.parents && mitglieder.any((u) => u.id == _zustaendig && u.role == Role.child)) ...[
          const Text('Achtung: Die Aufgabe ist nur für Eltern sichtbar, die zuständige Person ist ein Kind und sieht sie deshalb nicht.', style: TextStyle(fontSize: 12, color: kWarn)),
          const SizedBox(height: 12),
        ],
        const MonoLabel('// priorität'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final p in AufgabePrio.values) AuswahlKnopf(text: p.label, gewaehlt: _prio == p, onTap: darf ? () => setState(() => _prio = p) : nichts)],
        ),
        const SizedBox(height: 16),
        const MonoLabel('// wiederholung'),
        const SizedBox(height: 6),
        if (tag == null)
          const Text('Für eine Wiederholung braucht die Aufgabe ein Fälligkeitsdatum.', style: TextStyle(fontSize: 12, color: kTextMuted))
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final w in AufgabeWdh.values) AuswahlKnopf(text: w.label, gewaehlt: _wdh == w, onTap: darf ? () => setState(() => _wdh = w) : nichts)],
          ),
          if (_wdh != AufgabeWdh.keine) ...[
            const SizedBox(height: 6),
            const Text('Sobald du die Aufgabe erledigst, entsteht die nächste.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
        ],
        if (tag != null) ...[
          const SizedBox(height: 16),
          const MonoLabel('// erinnerung'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in {...kAufgabeErinnerungen, if (_erinnerung != null) _erinnerung})
                AuswahlKnopf(text: aufgabeErinnerungText(m), gewaehlt: _erinnerung == m, onTap: darf ? () => setState(() => _erinnerung = m) : nichts),
            ],
          ),
          if (_erinnerung != null) ...[
            const SizedBox(height: 6),
            Text(
              '${_mitUhrzeit ? '' : 'Ohne Uhrzeit gilt 09:00 Uhr am Fälligkeitstag. '}${_erinnerungHinweis(user?.id, mitglieder)}',
              style: const TextStyle(fontSize: 12, color: kTextMuted),
            ),
          ],
        ],
        const SizedBox(height: 16),
        const MonoLabel('// unteraufgaben'),
        const SizedBox(height: 6),
        for (var i = 0; i < _punkte.length; i++)
          Padding(
            key: ValueKey('punkt-${_punkte[i].id}'),
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Semantics(
                  checked: _punkte[i].erledigt,
                  enabled: darf || statusDarf,
                  label: 'Unteraufgabe ${_punkte[i].text.text}, ${_punkte[i].erledigt ? 'erledigt' : 'offen'}',
                  excludeSemantics: true,
                  onTap: darf || statusDarf ? () => _punktUmschalten(i, sofort: statusDarf) : null,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: darf || statusDarf ? () => _punktUmschalten(i, sofort: statusDarf) : null,
                    child: SizedBox(width: 48, height: 48, child: Icon(_punkte[i].erledigt ? Icons.check_box : Icons.check_box_outline_blank, color: _punkte[i].erledigt ? kTerminal : kTextMuted)),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _punkte[i].text,
                    enabled: darf,
                    maxLength: 500,
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                    ),
                    style: TextStyle(color: _punkte[i].erledigt ? kTextMuted : kText, decoration: _punkte[i].erledigt ? TextDecoration.lineThrough : null, decorationColor: kTextMuted),
                  ),
                ),
                if (darf)
                  IconButton(
                    tooltip: 'Unteraufgabe entfernen',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.close, size: 20, color: kTextMuted),
                    onPressed: () => setState(() {
                      _entsorgen.add(_punkte.removeAt(i)); // erst beim Schließen freigeben: der Baum benutzt den Controller noch
                    }),
                  ),
              ],
            ),
          ),
        if (darf && _punkte.length < kMaxPunkte)
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _neuerPunkt,
                  maxLength: 500,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _punktHinzu(),
                  decoration: const InputDecoration(hintText: 'Unteraufgabe hinzufügen', counterText: ''),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(tooltip: 'Unteraufgabe hinzufügen', onPressed: _punktHinzu, icon: const Icon(Icons.add)),
            ],
          ),
        const SizedBox(height: 16),
        TextField(
          controller: _beschreibung,
          enabled: darf,
          maxLength: 4000,
          minLines: 2,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Beschreibung', counterText: '', alignLabelWithHint: true),
        ),
        const SizedBox(height: 12),
        if (darf && rechte.darfFreigabeAendern) ...[
          const MonoLabel('// sichtbar für'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final s in rechte.freigaben) AuswahlKnopf(text: s.label, gewaehlt: s == _sicht, onTap: () => setState(() => _sicht = s))],
          ),
          const SizedBox(height: 12),
        ],
        if (!_neu && darf)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: kDanger, minimumSize: const Size(44, 48)),
              onPressed: _loeschen,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Aufgabe löschen'),
            ),
          ),
      ],
      ),
    );
  }
}
