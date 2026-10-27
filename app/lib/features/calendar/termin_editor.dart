// Termin anlegen und bearbeiten (eine Seite, Eigenbau ohne UI-Pakete). Zeiten sind Wanduhrzeiten der Familienzone (Europe/Berlin).
// Bei Serien gilt der gewählte Umfang: nur dieses Vorkommen (Titel, Ort, Beginn, Ende), dieses und folgende oder alle (alle Felder).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/termin_erinnerung.dart';
import '../../data/calendar/termin_farben.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/calendar/wiederholung.dart';
import '../../data/calendar/zeitzonen.dart';
import '../../data/erinnerungen/erinnerung_dienst.dart' show erinnerungStatusProvider;
import '../../data/erinnerungen/erinnerung_einstellungen.dart';
import '../../data/lists/list_repository.dart' show ListenSicht;
import '../../data/sync/sync_store.dart' show neueUuid;
import '../../data/lists/members.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import '../profile/erinnerungen_screen.dart';
import '../../widgets/ungespeichert_schutz.dart';
import 'calendar_state.dart';
import 'kalender_widgets.dart';

/// Öffnet den Editor. [v] null = neuer Termin (am Tag [tag]); sonst bearbeiten mit [umfang].
/// [startMinute] (nur neu): Beginn in Minuten seit 0:00 am Tag [tag] (Tipp auf eine leere Stelle der Wochenansicht), Ende eine Stunde später.
Future<void> terminEditorOeffnen(BuildContext context, {Vorkommen? v, SerieUmfang umfang = SerieUmfang.alle, DateTime? tag, int? startMinute}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => TerminEditor(vorkommen: v, umfang: umfang, tag: tag, startMinute: startMinute)));

class TerminEditor extends ConsumerStatefulWidget {
  final Vorkommen? vorkommen;
  final SerieUmfang umfang;
  final DateTime? tag;
  final int? startMinute;
  const TerminEditor({super.key, this.vorkommen, this.umfang = SerieUmfang.alle, this.tag, this.startMinute});

  @override
  ConsumerState<TerminEditor> createState() => _TerminEditorState();
}

class _TerminEditorState extends ConsumerState<TerminEditor> {
  final _titel = TextEditingController();
  final _ort = TextEditingController();
  final _beschreibung = TextEditingController();
  var _ganztaegig = false;
  // Geburtstag: ganztägiger Jahrestag (siehe geburtstag.dart); [_geburtsdatum] trägt Monat und Tag (und das Jahr, wenn [_jahrBekannt])
  var _geburtstag = false;
  var _jahrBekannt = true;
  late DateTime _geburtsdatum;
  late DateTime _startTag;
  late DateTime _endTag; // bei ganztägigen Terminen einschließlich
  var _startZeit = const TimeOfDay(hour: 9, minute: 0);
  var _endZeit = const TimeOfDay(hour: 10, minute: 0);
  var _wdh = Wiederholung.keine;
  // Die Regel wird nur neu geschrieben, wenn sich Wiederholung, Beginn-Tag oder Art geändert haben; sonst bleibt der gespeicherte Text unverändert
  // (Rundlauf: COUNT/UNTIL und fremde Formen gehen nicht verloren).
  var _wdhGeaendert = false;
  late DateTime _startTagUrsprung;
  late bool _ganztaegigUrsprung;
  int? _erinnerung;
  int? _erinnerungBisher; // gespeicherter Rohwert eines bestehenden Termins (null = nie gesetzt, -1 = bewusst keine)
  bool _erinnerungGewaehlt = false; // die Person hat die Erinnerung selbst gewählt (dann ändert der Geburtstags-Schalter sie nicht mehr)
  int? _farbe; // Termin-Farbe (Index in kTerminFarben), null = keine
  var _teilnehmer = <String>{};
  var _sicht = TerminSicht.family;
  String? _fehler;

  /// Android: Benachrichtigungen sind nicht erlaubt (Android 13+ fragt erst auf Wunsch); sonst (Web, erlaubt, unbekannt) false.
  bool get _benachrichtigungenFehlen {
    final st = ref.watch(erinnerungStatusProvider).value;
    return st != null && st.verfuegbar && !st.erlaubt;
  }

  bool get _neu => widget.vorkommen == null;

  /// Stand der Eingaben (zum Erkennen ungespeicherter Änderungen); der Ausgangsstand wird beim ersten Bauen festgehalten.
  String? _ausgang;
  String _stand() => [
    _titel.text, _ort.text, _beschreibung.text, _ganztaegig, _geburtstag, _jahrBekannt, _geburtsdatum, _startTag, _endTag, _startZeit, _endZeit, _wdhGeaendert,
    _erinnerung, _farbe, ([..._teilnehmer]..sort()).join(','), _sicht,
  ].join('');
  bool get _nurDieses => !_neu && widget.umfang == SerieUmfang.dieses;

  @override
  void initState() {
    super.initState();
    final v = widget.vorkommen;
    if (v == null) {
      final heute = heuteTag();
      final tag = widget.tag ?? heute;
      final jetzt = wandUhr(DateTime.now().toUtc(), familienOrt);
      final stunde = tag == heute ? (jetzt.hour + 1).clamp(0, 22) : 9;
      _startTag = tag;
      _endTag = tag;
      _startZeit = TimeOfDay(hour: stunde, minute: 0);
      _endZeit = TimeOfDay(hour: stunde + 1, minute: 0);
      final m = widget.startMinute;
      if (m != null) {
        // Beginn aus dem Wochenraster; das Ende (eine Stunde später) bleibt am selben Tag
        final ende = (m + 60).clamp(0, 24 * 60 - 1);
        _startZeit = TimeOfDay(hour: m ~/ 60, minute: m % 60);
        _endZeit = TimeOfDay(hour: ende ~/ 60, minute: ende % 60);
      }
      _startTagUrsprung = _startTag;
      _ganztaegigUrsprung = false;
      // Vorbelegung: heute vor zehn Jahren; am Schalttag (29.2.) auf den letzten Tag des Monats im Zieljahr begrenzt
      final zielJahr = tag.year - 10;
      _geburtsdatum = DateTime.utc(zielJahr, tag.month, tag.day.clamp(1, DateTime.utc(zielJahr, tag.month + 1, 0).day));
      _erinnerung = ref.read(erinnerungEinstellungenProvider).standardVorlauf; // Standard-Erinnerung dieses Geräts (Profil > Kalender, Vorgabe 1 Stunde)
      return;
    }
    final t = v.termin;
    final daten = ref.read(kalenderDatenProvider);
    // "alle" bearbeitet den Termin selbst (Beginn der Serie), sonst das gewählte Vorkommen
    final (DateTime s, DateTime e) = widget.umfang == SerieUmfang.alle ? _wandVonTermin(t) : (v.startWand, v.endeWand);
    _ganztaegig = t.ganztaegig;
    _startTag = DateTime.utc(s.year, s.month, s.day);
    _startZeit = TimeOfDay(hour: s.hour, minute: s.minute);
    if (t.ganztaegig) {
      _endTag = e.subtract(const Duration(days: 1));
    } else {
      _endTag = DateTime.utc(e.year, e.month, e.day);
      _endZeit = TimeOfDay(hour: e.hour, minute: e.minute);
    }
    _titel.text = widget.umfang == SerieUmfang.alle ? t.titel : v.titel;
    _ort.text = widget.umfang == SerieUmfang.alle ? t.ort : v.ort;
    _beschreibung.text = t.beschreibung;
    _wdh = Wiederholung.ausRrule(t.rrule, ganztaegig: t.ganztaegig, ort: ortFuer(t.tzid), startTag: _startTag);
    _erinnerung = erinnerungMinuten(t.erinnerungMin);
    _erinnerungBisher = t.erinnerungMin;
    _farbe = terminFarbeNummer(t.farbe);
    _teilnehmer = daten.teilnehmerIds(t.id);
    _sicht = ListenSicht.von(t.audience);
    _startTagUrsprung = _startTag;
    _ganztaegigUrsprung = _ganztaegig;
    _geburtsdatum = DateTime.utc(_startTag.year, _startTag.month, _startTag.day);
    if (hatGeburtstagsMarke(t)) {
      final j = geburtsjahr(t);
      _geburtstag = true;
      _jahrBekannt = j != null;
      _geburtsdatum = DateTime.utc(j ?? 2000, _startTag.month, _startTag.day);
    }
  }

  /// Beginn und Ende des Termins selbst (bei Serien: des ersten Vorkommens) in der Wanduhr der Familienzone.
  (DateTime, DateTime) _wandVonTermin(Termin t) {
    if (t.ganztaegig) return (tagAusText(t.startDate) ?? _startTag, tagAusText(t.endDate) ?? _startTag.add(const Duration(days: 1)));
    return (wandUhr(t.startUtc!.toUtc(), familienOrt), wandUhr(t.endUtc!.toUtc(), familienOrt));
  }

  @override
  void dispose() {
    _titel.dispose();
    _ort.dispose();
    _beschreibung.dispose();
    super.dispose();
  }

  DateTime _wand(DateTime tag, TimeOfDay z) => DateTime.utc(tag.year, tag.month, tag.day, z.hour, z.minute);

  DateTime get _startWand => _ganztaegig ? _startTag : _wand(_startTag, _startZeit);
  DateTime get _endeWand => _ganztaegig ? _endTag.add(const Duration(days: 1)) : _wand(_endTag, _endZeit);

  Future<DateTime?> _tagWaehlen(DateTime aktuell) async {
    final d = await showDatePicker(useRootNavigator: false,
      context: context,
      initialDate: DateTime(aktuell.year, aktuell.month, aktuell.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2199, 12, 30), // ein ganztägiger Termin braucht ein exklusives Ende, das noch vor 2200 liegt
      locale: const Locale('de', 'DE'),
    );
    return d == null ? null : DateTime.utc(d.year, d.month, d.day);
  }

  Future<TimeOfDay?> _zeitWaehlen(TimeOfDay aktuell) => showTimePicker(useRootNavigator: false,
    context: context,
    initialTime: aktuell,
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
  );

  /// Verschiebt das Ende mit, wenn der Beginn verschoben wird (Dauer bleibt).
  void _startAendern(DateTime tag, TimeOfDay zeit) {
    final alt = _startWand;
    final dauer = _endeWand.difference(alt);
    // verschiebt sich der Beginn auf einen anderen Wochentag, wandert der Wochentag der wöchentlichen Auswahl mit
    final neueWdh = _wdh.wochentageNachStart(_startTag, tag);
    if (neueWdh.wochentage.toList().join() != _wdh.wochentage.toList().join()) _wdhGeaendert = true;
    setState(() {
      _wdh = neueWdh;
      _startTag = tag;
      _startZeit = zeit;
      if (_ganztaegig) {
        final tage = dauer.inDays - 1;
        _endTag = tag.add(Duration(days: tage < 0 ? 0 : tage));
      } else {
        final ende = _wand(tag, zeit).add(dauer);
        _endTag = DateTime.utc(ende.year, ende.month, ende.day);
        _endZeit = TimeOfDay(hour: ende.hour, minute: ende.minute);
      }
      _fehler = null;
    });
  }

  /// Speichert einen Geburtstag: ganztägig, jährlich, Beginn im Jahr der Geburt (frühestens 2000, der Server kennt davor keine Tage).
  Future<void> _speichernGeburtstag() async {
    final repo = ref.read(terminRepositoryProvider);
    final nav = Navigator.of(context);
    final name = _titel.text.trim();
    if (name.isEmpty) {
      setState(() => _fehler = 'Gib den Namen ein.');
      return;
    }
    final d = _geburtsdatum;
    final jahr = _jahrBekannt ? d.year : null;
    final beginnJahr = jahr != null && jahr >= 2000 ? jahr : 2000;
    final start = DateTime.utc(beginnJahr, d.month, d.day);
    final original = widget.vorkommen?.termin;
    final suffix = geburtstagUidSuffix(original?.icalUid) ?? neueUuid();
    final e = TerminEingabe(
      titel: name,
      beschreibung: _beschreibung.text,
      ganztaegig: true,
      startWand: start,
      endeWand: start.add(const Duration(days: 1)),
      rrule: geburtstagRegel(d.month, d.day),
      erinnerungMin: erinnerungSpeichern(_erinnerung, neu: _neu, bisher: _erinnerungBisher),
      sicht: _sicht,
      teilnehmer: _teilnehmer,
      icalUid: geburtstagUid(jahr, suffix),
    );
    final v = widget.vorkommen;
    try {
      if (v == null) {
        await repo.anlegen(e);
      } else {
        await repo.alleAendern(v.termin.id, e);
      }
    } on ZeitzonenFehlen {
      if (mounted) setState(() => _fehler = 'Die Zeitzonen-Daten fehlen, der Geburtstag wurde nicht gespeichert. Bitte versuche es noch einmal.');
      return;
    }
    if (mounted) nav.pop();
  }

  Future<void> _speichern() async {
    if (_geburtstag) return _speichernGeburtstag();
    final repo = ref.read(terminRepositoryProvider);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final titel = _titel.text.trim();
    if (titel.isEmpty) {
      setState(() => _fehler = 'Gib dem Termin einen Titel.');
      return;
    }
    final start = _startWand;
    final ende = _endeWand;
    if (_ganztaegig ? !ende.isAfter(start) : ende.isBefore(start)) {
      setState(() => _fehler = 'Das Ende liegt vor dem Beginn.');
      return;
    }
    // Zeitzonen-Daten fehlen: Anlegen und Ändern würde Uhrzeiten falsch speichern. Neuer Versuch, sonst Hinweis (Speichern wiederholt ihn).
    if (!zeitzonenBereit() && !await zeitzonenNeuLaden()) {
      if (mounted) setState(() => _fehler = 'Die Zeitzonen-Daten konnten nicht geladen werden, der Termin wurde nicht gespeichert. Bitte versuche es gleich noch einmal (Speichern wiederholt das Laden).');
      return;
    }
    final startTag = DateTime.utc(start.year, start.month, start.day);
    final original = widget.vorkommen?.termin;
    final String? rrule;
    if (_nurDieses) {
      rrule = null;
    } else if (original != null && !_wdhGeaendert && startTag == _startTagUrsprung && _ganztaegig == _ganztaegigUrsprung) {
      rrule = original.rrule; // unverändert: genau der gespeicherte Text
    } else {
      rrule = _wdh.zuRrule(startTag: startTag, ganztaegig: _ganztaegig, ort: familienOrt);
    }
    final e = TerminEingabe(
      titel: titel,
      ort: _ort.text,
      beschreibung: _beschreibung.text,
      ganztaegig: _ganztaegig,
      startWand: start,
      endeWand: ende,
      rrule: rrule,
      erinnerungMin: erinnerungSpeichern(_erinnerung, neu: _neu, bisher: _erinnerungBisher),
      sicht: _sicht,
      teilnehmer: _teilnehmer,
      farbe: _farbe,
    );
    final v = widget.vorkommen;
    try {
      if (v == null) {
        await repo.anlegen(e);
      } else {
        switch (widget.umfang) {
          case SerieUmfang.alle:
            final verworfen = await repo.alleAendern(v.termin.id, e);
            if (verworfen > 0) {
              messenger
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text(verworfen == 1 ? 'Eine Ausnahme der Serie wurde zurückgesetzt, weil sich Beginn oder Wiederholung geändert haben.' : '$verworfen Ausnahmen der Serie wurden zurückgesetzt, weil sich Beginn oder Wiederholung geändert haben.')));
            }
          case SerieUmfang.dieses:
            await repo.vorkommenAendern(v, e);
          case SerieUmfang.folgende:
            await repo.folgendeAendern(v, e);
        }
      }
    } on ZeitzonenFehlen {
      if (mounted) setState(() => _fehler = 'Die Zeitzonen-Daten fehlen, der Termin wurde nicht gespeichert. Bitte versuche es noch einmal.');
      return;
    }
    if (mounted) nav.pop();
  }

  Future<void> _wiederholungWaehlen() async {
    final w = await wiederholungBlatt(context, _wdh, startTag: _startTag, ganztaegig: _ganztaegig);
    if (w != null) {
      setState(() {
        _wdh = w;
        _wdhGeaendert = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _ausgang ??= _stand();
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = TerminRechte(user?.role ?? Role.child, user?.id);
    final mitglieder = ref.watch(mitgliederProvider).value ?? const <UserDto>[];
    final datum = DateFormat('E, d. MMM y', 'de_DE');
    final titel = _geburtstag ? (_neu ? 'Neuer Geburtstag' : 'Geburtstag bearbeiten') : _neu ? 'Neuer Termin' : (_nurDieses ? 'Dieses Vorkommen' : (widget.umfang == SerieUmfang.folgende ? 'Dieses und folgende' : 'Termin bearbeiten'));

    Widget wahl({required String label, required String text, required VoidCallback onTap, IconData icon = Icons.event}) => Semantics(
      button: true,
      label: '$label, $text',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
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

    Widget zeitzeile(String label, DateTime tag, TimeOfDay zeit, void Function(DateTime, TimeOfDay) setze) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel(label),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SizedBox(
              width: 190,
              child: wahl(
                label: '$label Datum',
                text: datum.format(tag),
                onTap: () async {
                  final d = await _tagWaehlen(tag);
                  if (d != null) setze(d, zeit);
                },
              ),
            ),
            if (!_ganztaegig)
              SizedBox(
                width: 112,
                child: wahl(
                  label: '$label Uhrzeit',
                  text: zeit.format(context),
                  icon: Icons.schedule,
                  onTap: () async {
                    final z = await _zeitWaehlen(zeit);
                    if (z != null) setze(tag, z);
                  },
                ),
              ),
          ],
        ),
      ],
    );

    return UngespeichertSchutz(
      geaendert: () => _stand() != _ausgang,
      aenderungen: Listenable.merge([_titel, _ort, _beschreibung]),
      child: AuthSeite(
      label: 'Termin',
      titel: titel,
      maxBreite: kMaxContentWidth,
      fussleiste: FilledButton(onPressed: _speichern, child: Text(_neu ? (_geburtstag ? 'Geburtstag anlegen' : 'Termin anlegen') : 'Speichern')),
      kinder: [
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
        TextField(
          controller: _titel,
          maxLength: 200,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: _geburtstag ? 'Name' : 'Titel', counterText: ''),
        ),
        const SizedBox(height: 12),
        if (_neu || _geburtstag)
          Semantics(
            toggled: _geburtstag,
            label: 'Geburtstag',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Geburtstag'),
              subtitle: const Text('Ganztägig, wiederholt sich jedes Jahr'),
              value: _geburtstag,
              onChanged: _neu
                  ? (v) => setState(() {
                      _geburtstag = v;
                      // Geburtstage behalten ihr bisheriges Verhalten (keine Erinnerung vorbelegt), solange die Person nichts gewählt hat
                      if (!_erinnerungGewaehlt) _erinnerung = v ? null : ref.read(erinnerungEinstellungenProvider).standardVorlauf;
                    })
                  : null,
            ),
          ),
        if (_geburtstag) ...[
          const MonoLabel('Geburtsdatum'),
          const SizedBox(height: 6),
          wahl(
            label: 'Geburtsdatum',
            text: _jahrBekannt ? DateFormat('d. MMMM y', 'de_DE').format(_geburtsdatum) : DateFormat('d. MMMM', 'de_DE').format(_geburtsdatum),
            onTap: () async {
              final d = await showDatePicker(useRootNavigator: false,
                context: context,
                initialDate: DateTime(_geburtsdatum.year, _geburtsdatum.month, _geburtsdatum.day),
                firstDate: DateTime(1900),
                lastDate: DateTime.now(),
                locale: const Locale('de', 'DE'),
              );
              if (d != null) setState(() => _geburtsdatum = DateTime.utc(d.year, d.month, d.day));
            },
          ),
          Semantics(
            toggled: _jahrBekannt,
            label: 'Geburtsjahr angeben',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Geburtsjahr angeben'),
              subtitle: const Text('Dann zeigt der Kalender das Alter ("wird 8")'),
              value: _jahrBekannt,
              onChanged: (v) => setState(() => _jahrBekannt = v),
            ),
          ),
          const SizedBox(height: 4),
        ] else ...[
        Semantics(
            toggled: _ganztaegig,
            label: 'Ganztägig',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ganztägig'),
              value: _ganztaegig,
              onChanged: _nurDieses
                  ? null
                  : (v) => setState(() {
                      _ganztaegig = v;
                      _wdhGeaendert = true; // UNTIL hat je nach Art ein anderes Format
                      if (_endTag.isBefore(_startTag)) _endTag = _startTag;
                    }),
            ),
          ),
        zeitzeile('Beginn', _startTag, _startZeit, _startAendern),
        const SizedBox(height: 12),
        zeitzeile(_ganztaegig ? 'Letzter Tag' : 'Ende', _endTag, _endZeit, (d, z) => setState(() {
          _endTag = d;
          _endZeit = z;
          _fehler = null;
        })),
        const SizedBox(height: 16),
        TextField(controller: _ort, maxLength: 200, decoration: const InputDecoration(labelText: 'Ort', counterText: '', prefixIcon: Icon(Icons.place_outlined))),
        const SizedBox(height: 12),
        ],
        if (!_nurDieses) ...[
          if (!_geburtstag) ...[
            const MonoLabel('Farbe'),
            const SizedBox(height: 6),
            FarbWahl(gewaehlt: _farbe, onWahl: (f) => setState(() => _farbe = f)),
            const SizedBox(height: 12),
            const MonoLabel('Wie oft?'),
            const SizedBox(height: 6),
            wahl(label: 'Wie oft?', text: _wdh.beschreibung(), icon: Icons.repeat, onTap: _wiederholungWaehlen),
            const SizedBox(height: 12),
          ],
          const MonoLabel('Erinnern'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in kErinnerungen)
                AuswahlKnopf(text: m == null ? 'Keine' : erinnerungText(m).replaceAll(' vorher', ''), gewaehlt: _erinnerung == m, onTap: () => setState(() {
                  _erinnerung = m;
                  _erinnerungGewaehlt = true;
                })),
            ],
          ),
          if (_erinnerung != null && _benachrichtigungenFehlen) ...[
            const SizedBox(height: 6),
            const Text(
              'Auf diesem Gerät sind Benachrichtigungen für $kAppName nicht erlaubt: Die Erinnerung wird nicht angezeigt.',
              style: TextStyle(fontSize: 12, color: kWarn),
            ),
            LinkKnopf('Benachrichtigungen erlauben', icon: Icons.notifications_active_outlined, onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const ErinnerungenScreen()))),
          ],
          const SizedBox(height: 12),
          if (mitglieder.isNotEmpty) ...[
            const MonoLabel('Teilnehmer'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final u in mitglieder)
                  PersonKapsel(
                    u: u,
                    gewaehlt: _teilnehmer.contains(u.id),
                    beschriftung: 'Teilnehmer ${u.displayName}',
                    onTap: () => setState(() => _teilnehmer.contains(u.id) ? _teilnehmer.remove(u.id) : _teilnehmer.add(u.id)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _beschreibung,
            maxLength: 4000,
            minLines: 2,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Beschreibung', counterText: '', alignLabelWithHint: true),
          ),
          const SizedBox(height: 12),
          if (rechte.darfFreigabeAendern) ...[
            const MonoLabel('Wer sieht das?'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final s in rechte.freigaben) AuswahlKnopf(text: s.label, gewaehlt: s == _sicht, onTap: () => setState(() => _sicht = s))],
            ),
          ],
        ],
      ],
      ),
    );
  }
}

/// Blatt "Wiederholung": Art, Intervall, Wochentage, Monatsmodus, Ende. Liefert die neue Auswahl (null: abgebrochen).
Future<Wiederholung?> wiederholungBlatt(BuildContext context, Wiederholung start, {required DateTime startTag, required bool ganztaegig}) =>
    showModalBottomSheet<Wiederholung>(useRootNavigator: false,
      context: context,
      isScrollControlled: true,
      builder: (_) => _WiederholungBlatt(start: start, startTag: startTag),
    );

class _WiederholungBlatt extends StatefulWidget {
  final Wiederholung start;
  final DateTime startTag;
  const _WiederholungBlatt({required this.start, required this.startTag});

  @override
  State<_WiederholungBlatt> createState() => _WiederholungBlattState();
}

class _WiederholungBlattState extends State<_WiederholungBlatt> {
  late Wiederholung _w = widget.start;

  Widget _stepper({required String label, required int wert, required int min, required int max, required void Function(int) onChanged}) => Row(
    children: [
      Expanded(child: Text(label)),
      IconButton(tooltip: 'Weniger', onPressed: wert > min ? () => onChanged(wert - 1) : null, icon: const Icon(Icons.remove_circle_outline)),
      SizedBox(width: 36, child: Text('$wert', textAlign: TextAlign.center, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern))),
      IconButton(tooltip: 'Mehr', onPressed: wert < max ? () => onChanged(wert + 1) : null, icon: const Icon(Icons.add_circle_outline)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final w = _w;
    final eigene = w.eigeneRegel != null;
    final einheit = switch (w.art) {
      WdhArt.taeglich => 'Alle … Tage',
      WdhArt.woechentlich => 'Alle … Wochen',
      WdhArt.monatlich => 'Alle … Monate',
      WdhArt.jaehrlich => 'Alle … Jahre',
      WdhArt.keine => '',
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const MonoLabel('Wie oft?'),
            const SizedBox(height: 10),
            if (eigene) ...[
              const Text('Dieser Termin hat eine eigene Wiederholungsregel. Sie bleibt unverändert erhalten.', style: TextStyle(color: kTextMuted)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => setState(() => _w = Wiederholung.keine), child: const Text('Regel entfernen (einmalig)')),
            ] else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final a in WdhArt.values) AuswahlKnopf(text: a.label, gewaehlt: w.art == a, onTap: () => setState(() => _w = w.kopie(art: a)))],
              ),
              if (w.art != WdhArt.keine) ...[
                const SizedBox(height: 12),
                _stepper(label: einheit, wert: w.intervall, min: 1, max: 99, onChanged: (n) => setState(() => _w = w.kopie(intervall: n))),
                if (w.art == WdhArt.woechentlich) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 1; i <= 7; i++)
                        AuswahlKnopf(
                          text: wochentagKurz[i - 1],
                          gewaehlt: w.wochentage.contains(i) || (w.wochentage.isEmpty && widget.startTag.weekday == i),
                          onTap: () {
                            final basis = w.wochentage.isEmpty ? {widget.startTag.weekday} : {...w.wochentage};
                            if (!basis.remove(i)) basis.add(i);
                            if (basis.isNotEmpty) setState(() => _w = w.kopie(wochentage: basis));
                          },
                        ),
                    ],
                  ),
                ],
                if (w.art == WdhArt.monatlich) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      AuswahlKnopf(text: 'Am ${widget.startTag.day}. des Monats', gewaehlt: w.modus == MonatsModus.tagImMonat, onTap: () => setState(() => _w = w.kopie(modus: MonatsModus.tagImMonat))),
                      AuswahlKnopf(
                        text: _wochentagText(widget.startTag),
                        gewaehlt: w.modus == MonatsModus.wochentag,
                        onTap: () => setState(() => _w = w.kopie(modus: MonatsModus.wochentag)),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                const MonoLabel('Ende'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AuswahlKnopf(text: 'Nie', gewaehlt: w.ende == WdhEnde.nie, onTap: () => setState(() => _w = w.kopie(ende: WdhEnde.nie))),
                    AuswahlKnopf(
                      text: w.ende == WdhEnde.bis && w.bis != null ? 'Bis ${DateFormat('d.M.y').format(w.bis!)}' : 'Bis Datum',
                      gewaehlt: w.ende == WdhEnde.bis,
                      onTap: () async {
                        final d = await showDatePicker(useRootNavigator: false,
                          context: context,
                          initialDate: DateTime(widget.startTag.year, widget.startTag.month, widget.startTag.day).add(const Duration(days: 30)),
                          firstDate: DateTime(widget.startTag.year, widget.startTag.month, widget.startTag.day),
                          lastDate: DateTime(2199, 12, 30),
                          locale: const Locale('de', 'DE'),
                        );
                        if (d != null) setState(() => _w = w.kopie(ende: WdhEnde.bis, bis: DateTime.utc(d.year, d.month, d.day)));
                      },
                    ),
                    AuswahlKnopf(text: 'Nach Anzahl', gewaehlt: w.ende == WdhEnde.anzahl, onTap: () => setState(() => _w = w.kopie(ende: WdhEnde.anzahl))),
                  ],
                ),
                if (w.ende == WdhEnde.anzahl) _stepper(label: 'Anzahl der Termine', wert: w.anzahl, min: 1, max: kMaxAnzahl, onChanged: (n) => setState(() => _w = w.kopie(anzahl: n))),
              ],
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.of(context).pop(_w), child: const Text('Fertig')),
          ],
        ),
      ),
    );
  }

  String _wochentagText(DateTime tag) {
    final nr = (tag.day - 1) ~/ 7 + 1;
    const namen = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];
    return nr >= 5 ? 'Jeden letzten ${namen[tag.weekday - 1]}' : 'Jeden $nr. ${namen[tag.weekday - 1]}';
  }
}

/// Farbwahl im Termin-Editor: "Keine" und die elf Farben als zweispaltiges Raster (Punkt + Name); "Keine" = Personenfarbe.
class FarbWahl extends StatelessWidget {
  final int? gewaehlt;
  final void Function(int? farbe) onWahl;
  const FarbWahl({super.key, required this.gewaehlt, required this.onWahl});

  @override
  Widget build(BuildContext context) {
    Widget chip({required String name, required Color? farbe, required bool an, required int? wert}) => Semantics(
      button: true,
      selected: an,
      label: wert == null ? 'Farbe: keine, Personenfarbe' : 'Farbe $name',
      excludeSemantics: true,
      onTap: () => onWahl(wert),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onWahl(wert),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: an ? kSurface2 : kSurface,
            border: Border.all(color: an ? (farbe ?? kTextMuted) : Colors.transparent, width: an ? 1.5 : 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(shape: BoxShape.circle, color: farbe, border: farbe == null ? Border.all(color: kTextMuted, width: 1.5) : null),
              ),
              const SizedBox(width: 9),
              Expanded(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
            ],
          ),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, c) {
        final breite = (c.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SizedBox(width: breite, child: chip(name: 'Keine', farbe: null, an: gewaehlt == null, wert: null)),
            for (var i = 0; i < kTerminFarben.length; i++)
              SizedBox(width: breite, child: chip(name: kTerminFarben[i].name, farbe: kTerminFarben[i].farbe, an: gewaehlt == i, wert: i)),
          ],
        );
      },
    );
  }
}
