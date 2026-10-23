// Zähler einrichten und bearbeiten (Abschnitt 6l): Name, Art und Einheit, Zählernummer, Ort, Gruppe (gemeinsame Summe, z. B. mehrere Wasserzähler), Ablese-Rhythmus (monatlich am Tag X oder
// einmal im Jahr), Abrechnungsperiode, Kosten mit Tarif-Verlauf ("gilt ab"; Arbeitspreis, Grund- und Zählergebühr je Jahr, Abschlag je Monat), Solar-Angaben (Strompreis der Ersparnis,
// Eigenverbrauch, Anschaffung, Einspeisevergütung), Warnschwelle, Zählerwechsel, Archivieren und Löschen. Wer den Zähler sehen darf, ist fest (nur Eltern und Admins).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/zaehler/zaehler_logik.dart';
import '../../data/zaehler/zaehler_modelle.dart';
import '../../data/zaehler/zaehler_repository.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../ui/widgets.dart';
import '../../widgets/ungespeichert_schutz.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show AuswahlKnopf, bestaetigen;
import 'zaehler_anzeige.dart';
import 'zaehler_screen.dart' show zaehlerLoeschenMitBestaetigung;

/// Öffnet den Editor: [id] = bearbeiten, sonst einen neuen Zähler einrichten.
Future<void> zaehlerEditorOeffnen(BuildContext context, {String? id}) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ZaehlerEditor(id: id)));
}

/// Vorschläge für den Ort.
const List<String> kOrtVorschlaege = ['Wohnung', 'Keller', 'Waschkeller', 'Balkon', 'Garage'];

enum _Rhythmus { keiner, monatlich, jaehrlich }

DateTime _lokal(DateTime t) => DateTime(t.year, t.month, t.day);

class ZaehlerEditor extends ConsumerStatefulWidget {
  final String? id;
  const ZaehlerEditor({super.key, this.id});

  @override
  ConsumerState<ZaehlerEditor> createState() => _ZaehlerEditorState();
}

class _ZaehlerEditorState extends ConsumerState<ZaehlerEditor> {
  final _name = TextEditingController();
  final _nummer = TextEditingController();
  final _ort = TextEditingController();
  final _gruppe = TextEditingController();
  final _einheit = TextEditingController();
  final _notiz = TextEditingController();
  final _abschlag = TextEditingController();
  final _anlage = TextEditingController();
  final _eigen = TextEditingController(text: '100');
  final _verguetung = TextEditingController();
  final _start = TextEditingController();
  var _art = ZaehlerArt.strom;
  var _rhythmus = _Rhythmus.keiner;
  var _rTag = 1;
  var _rMonat = 12;
  var _kalenderjahr = true;
  var _pTag = 1;
  var _pMonat = 3;
  var _kosten = true;
  var _preise = <Preis>[];
  var _warn = false;
  var _warnProzent = 30;
  String? _fehler;
  var _speichert = false;
  var _geladen = false;
  ZaehlerInhalt? _alt;
  String? _ausgang;

  bool get _neu => widget.id == null;

  List<TextEditingController> get _felder => [_name, _nummer, _ort, _gruppe, _einheit, _notiz, _abschlag, _anlage, _eigen, _verguetung, _start];

  String _stand() => [for (final c in _felder) c.text, _art, _rhythmus, _rTag, _rMonat, _kalenderjahr, _pTag, _pMonat, _kosten, [for (final p in _preise) '${p.ab}/${p.arbeitspreis}/${p.grundgebuehrJahr}/${p.zaehlergebuehrJahr}'], _warn, _warnProzent].join('|');

  @override
  void dispose() {
    for (final c in _felder) {
      c.dispose();
    }
    super.dispose();
  }

  void _laden(ZaehlerDaten d) {
    if (_geladen) return;
    final id = widget.id;
    if (id == null) {
      _kosten = _art.kostenStandard;
      _geladen = true;
      return;
    }
    final z = d.eintrag(id)?.inhalt;
    if (z == null) return;
    _alt = z;
    _art = z.art;
    _name.text = z.name;
    _nummer.text = z.nummer;
    _ort.text = z.ort;
    _gruppe.text = z.gruppe;
    _einheit.text = z.einheit;
    _notiz.text = z.notiz;
    _kosten = z.kosten;
    _preise = [...z.preise];
    _kalenderjahr = z.periodeMonat == 1 && z.periodeTag == 1;
    _pMonat = z.periodeMonat == 1 && z.periodeTag == 1 ? 3 : z.periodeMonat;
    _pTag = z.periodeTag;
    final a = z.ablesung;
    if (a != null) {
      _rhythmus = a.art == AblesungArt.monatlich ? _Rhythmus.monatlich : _Rhythmus.jaehrlich;
      _rTag = a.tag;
      _rMonat = a.monat;
    }
    _abschlag.text = z.abschlag == null ? '' : geldText(z.abschlag!);
    _anlage.text = z.anlagenkosten == null ? '' : geldText(z.anlagenkosten!);
    _eigen.text = z.eigenverbrauchBp == null ? '100' : '${z.eigenverbrauchBp! ~/ 100}';
    _verguetung.text = z.einspeiseVerguetung == null ? '' : preisText(z.einspeiseVerguetung!);
    _warn = z.warnProzent != null;
    _warnProzent = z.warnProzent ?? 30;
    _geladen = true;
  }

  void _fehlerSetzen(String text) {
    if (mounted) {
      setState(() {
        _speichert = false;
        _fehler = text;
      });
    }
  }

  void _artWaehlen(ZaehlerArt a, ZaehlerDaten d) {
    setState(() {
      _art = a;
      _kosten = a.kostenStandard;
      if (a != ZaehlerArt.eigen) _einheit.text = a.einheit;
      if (a == ZaehlerArt.eigen) _einheit.clear();
      // Solar: Strompreis der Ersparnis aus dem ersten Stromzähler vorbelegen (änderbar)
      if (a == ZaehlerArt.erzeugung && _preise.isEmpty) {
        final strom = d.reihen.where((r) => r.art == ZaehlerArt.strom && r.inhalt.preise.isNotEmpty).firstOrNull;
        if (strom != null) {
          final p = strom.inhalt.preise.last;
          _preise = [Preis(ab: p.ab, arbeitspreis: p.arbeitspreis)];
        }
      }
    });
  }

  int? _geld(String t) => t.trim().isEmpty ? null : geldParsen(t);

  Future<void> _speichern(ZaehlerDaten d) async {
    if (_speichert) return;
    final name = _name.text.trim();
    if (name.isEmpty) return _fehlerSetzen('Gib dem Zähler einen Namen.');
    final einheit = _art == ZaehlerArt.eigen ? _einheit.text.trim() : _art.einheit;
    if (einheit.isEmpty) return _fehlerSetzen('Gib die Einheit des Zählers an (zum Beispiel kWh oder m³).');
    final abschlagText = _abschlag.text.trim();
    final abschlag = _geld(abschlagText);
    if (abschlagText.isNotEmpty && (abschlag == null || abschlag > kMaxGeldCent)) return _fehlerSetzen('Der Abschlag muss ein Betrag in Euro sein, zum Beispiel 95.');
    int? anlage;
    int? eigenBp;
    int? vergutung;
    if (_art == ZaehlerArt.erzeugung) {
      final at = _anlage.text.trim();
      anlage = _geld(at);
      if (at.isNotEmpty && (anlage == null || anlage > 100 * kMaxGeldCent)) return _fehlerSetzen('Der Anschaffungspreis muss ein Betrag in Euro sein.');
      final e = int.tryParse(_eigen.text.trim());
      if (e == null || e < 0 || e > 100) return _fehlerSetzen('Der Eigenverbrauch ist ein Anteil von 0 bis 100 Prozent.');
      eigenBp = e * 100;
      final vt = _verguetung.text.trim();
      vergutung = vt.isEmpty ? null : preisParsen(vt);
      if (vt.isNotEmpty && (vergutung == null || vergutung > kMaxPreisAp)) return _fehlerSetzen('Die Einspeisevergütung muss ein Preis je kWh in Euro sein, zum Beispiel 0,081.');
    }
    final preise = [..._preise]..sort((a, b) => a.ab.compareTo(b.ab));
    final inhalt = ZaehlerInhalt(
      art: _art,
      name: name,
      einheit: einheit,
      nummer: _nummer.text.trim(),
      notiz: _notiz.text.trim(),
      ort: _ort.text.trim(),
      gruppe: _art == ZaehlerArt.erzeugung ? '' : _gruppe.text.trim(),
      periodeMonat: _kalenderjahr ? 1 : _pMonat,
      periodeTag: _kalenderjahr ? 1 : _pTag,
      kosten: _kosten,
      preise: preise,
      abschlag: _kosten && _art != ZaehlerArt.erzeugung ? abschlag : null,
      vorgaenger: _alt?.vorgaenger,
      archiviertAb: _alt?.archiviertAb,
      ablesung: switch (_rhythmus) {
        _Rhythmus.keiner => null,
        _Rhythmus.monatlich => Ablesung.monatlich(_rTag),
        _Rhythmus.jaehrlich => Ablesung.jaehrlich(monat: _rMonat, tag: _rTag),
      },
      eigenverbrauchBp: eigenBp,
      anlagenkosten: anlage,
      einspeiseVerguetung: vergutung,
      warnProzent: _warn && _art != ZaehlerArt.erzeugung ? _warnProzent : null,
    );
    if (!inhalt.gueltig) return _fehlerSetzen('Die Eingaben sind nicht stimmig. Prüfe Name, Preise und Zeiten.');
    final startText = _start.text.trim();
    final startMilli = startText.isEmpty ? null : mengeParsen(startText);
    if (_neu && startText.isNotEmpty && (startMilli == null || startMilli > kMaxStandMilli)) return _fehlerSetzen('Der aktuelle Stand muss eine Zahl sein, zum Beispiel 48213,5.');
    final repo = ref.read(zaehlerRepositoryProvider);
    final nav = Navigator.of(context);
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      if (_neu) {
        final id = await repo.anlegen(inhalt);
        if (startMilli != null) {
          try {
            await repo.standErfassen(id, datum: zaehlerHeute(ref.read(minutenTaktProvider).value ?? DateTime.now()), milli: startMilli);
          } on Object {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Der Zähler ist angelegt, der erste Stand ließ sich nicht speichern. Trage ihn noch einmal ein.')));
          }
        }
      } else {
        await repo.aendern(widget.id!, inhalt);
      }
    } on Object catch (e) {
      return _fehlerSetzen(zaehlerFehlerText(e));
    }
    if (mounted) nav.pop();
  }

  Future<void> _preisBearbeiten({int? index}) async {
    final p = await showDialog<Preis>(
      useRootNavigator: false,
      context: context,
      builder: (_) => _PreisDialog(start: index == null ? null : _preise[index], nurArbeit: _art == ZaehlerArt.erzeugung, einheit: _art == ZaehlerArt.eigen ? _einheit.text.trim() : _art.einheit),
    );
    if (p == null || !mounted) return;
    setState(() {
      final neu = [..._preise];
      if (index != null) neu.removeAt(index);
      neu.removeWhere((x) => x.ab == p.ab);
      neu.add(p);
      neu.sort((a, b) => a.ab.compareTo(b.ab));
      _preise = neu;
    });
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(zaehlerDarfProvider) ? ref.watch(zaehlerDatenProvider) : const ZaehlerDaten(geladen: true);
    if (!daten.darf) return const AuthSeite(titel: 'Nicht verfügbar', maxBreite: kMaxContentWidth, kinder: [EmptyState(icon: Icons.lock_outline, title: 'Nicht verfügbar', hint: 'Diesen Bereich gibt es für dich nicht.')]);
    _laden(daten);
    _ausgang ??= _geladen ? _stand() : null;
    if (!_geladen) {
      return AuthSeite(label: '// zähler', titel: 'Zähler', maxBreite: kMaxContentWidth, kinder: [if (!daten.geladen) const Center(child: CircularProgressIndicator()) else const MeldungsBox('Dieser Zähler lässt sich gerade nicht bearbeiten.', fehler: false)]);
    }
    final erzeugung = _art == ZaehlerArt.erzeugung;
    final gruppen = {for (final r in daten.reihen) if (r.art == _art && r.inhalt.gruppe.trim().isNotEmpty) r.inhalt.gruppe.trim()};
    final einheit = _art == ZaehlerArt.eigen ? _einheit.text.trim() : _art.einheit;
    final reihe = _neu ? null : daten.reihe(widget.id!);
    final istJuengster = reihe == null || reihe.id == widget.id;
    return UngespeichertSchutz(
      geaendert: () => _ausgang != null && _stand() != _ausgang,
      aenderungen: Listenable.merge(_felder),
      child: AuthSeite(
        label: _neu ? '// neu' : '// zähler',
        titel: _neu ? 'Zähler einrichten' : (_alt?.name ?? 'Zähler'),
        maxBreite: kMaxContentWidth,
        fussleiste: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: _speichert ? null : () => unawaited(_speichern(daten)), child: Text(_neu ? 'Speichern' : 'Änderungen speichern')),
        kinder: [
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
          TextField(controller: _name, maxLength: kMaxNameZeichen, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Name (zum Beispiel Strom Haus)', counterText: '')),
          const SizedBox(height: 14),
          const MonoLabel('// art und einheit'),
          const SizedBox(height: 6),
          if (_neu)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final a in ZaehlerArt.values) AuswahlKnopf(text: artAuswahlText(a), gewaehlt: _art == a, onTap: () => _artWaehlen(a, daten))],
            )
          else
            Text('${_art.anzeige}${einheit.isEmpty ? '' : ' · $einheit'}', style: const TextStyle(color: kTextMuted)),
          if (_art == ZaehlerArt.eigen) ...[
            const SizedBox(height: 10),
            TextField(controller: _einheit, maxLength: kMaxEinheitZeichen, decoration: const InputDecoration(labelText: 'Einheit (zum Beispiel Stück oder l)', counterText: '')),
          ],
          const SizedBox(height: 14),
          TextField(controller: _nummer, maxLength: kMaxNummerZeichen, decoration: const InputDecoration(labelText: 'Zählernummer (optional)', counterText: '')),
          const SizedBox(height: 14),
          const MonoLabel('// ort'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final o in kOrtVorschlaege) AuswahlKnopf(text: o, gewaehlt: _ort.text.trim() == o, onTap: () => setState(() => _ort.text = _ort.text.trim() == o ? '' : o))],
          ),
          const SizedBox(height: 8),
          TextField(controller: _ort, maxLength: kMaxOrtZeichen, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Eigener Ort (optional)', counterText: '')),
          if (!erzeugung) ...[
            const SizedBox(height: 14),
            const MonoLabel('// gruppe (gemeinsame summe)'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AuswahlKnopf(text: 'Keine', gewaehlt: _gruppe.text.trim().isEmpty, onTap: () => setState(_gruppe.clear)),
                for (final g in gruppen) AuswahlKnopf(text: g, gewaehlt: _gruppe.text.trim().toLowerCase() == g.toLowerCase(), onTap: () => setState(() => _gruppe.text = g)),
              ],
            ),
            const SizedBox(height: 8),
            TextField(controller: _gruppe, maxLength: kMaxGruppeZeichen, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Gruppe (zum Beispiel Wasser Wohnung)', helperText: 'Zähler gleicher Art mit gleichem Namen zeigt die App mit einer Summe', counterText: '')),
          ],
          const SizedBox(height: 16),
          const MonoLabel('// ablese-rhythmus'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AuswahlKnopf(text: 'Kein Rhythmus', gewaehlt: _rhythmus == _Rhythmus.keiner, onTap: () => setState(() => _rhythmus = _Rhythmus.keiner)),
              AuswahlKnopf(text: 'Monatlich', gewaehlt: _rhythmus == _Rhythmus.monatlich, onTap: () => setState(() => _rhythmus = _Rhythmus.monatlich)),
              AuswahlKnopf(text: 'Jahresablesung', gewaehlt: _rhythmus == _Rhythmus.jaehrlich, onTap: () => setState(() => _rhythmus = _Rhythmus.jaehrlich)),
            ],
          ),
          if (_rhythmus != _Rhythmus.keiner) ...[
            const SizedBox(height: 8),
            _Stepper(label: _rhythmus == _Rhythmus.monatlich ? 'Am Tag des Monats' : 'Tag', wert: _rTag, min: 1, max: 31, text: (v) => '$v.', onChanged: (v) => setState(() => _rTag = v)),
            if (_rhythmus == _Rhythmus.jaehrlich) _Stepper(label: 'Monat', wert: _rMonat, min: 1, max: 12, text: monatName, onChanged: (v) => setState(() => _rMonat = v)),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _rhythmus == _Rhythmus.monatlich ? 'Die App erinnert jeden Monat am $_rTag. um 9 Uhr, wenn du die Zähler-Erinnerungen eingeschaltet hast (Profil, Erinnerungen).' : 'Die App erinnert einmal im Jahr am $_rTag. ${monatName(_rMonat)} um 9 Uhr, wenn du die Zähler-Erinnerungen eingeschaltet hast.',
                style: const TextStyle(fontSize: 12, color: kTextMuted),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const MonoLabel('// abrechnungsperiode'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AuswahlKnopf(text: 'Kalenderjahr', gewaehlt: _kalenderjahr, onTap: () => setState(() => _kalenderjahr = true)),
              AuswahlKnopf(text: 'Eigene (ab Tag und Monat)', gewaehlt: !_kalenderjahr, onTap: () => setState(() => _kalenderjahr = false)),
            ],
          ),
          if (!_kalenderjahr) ...[
            const SizedBox(height: 8),
            _Stepper(label: 'Beginnt am Tag', wert: _pTag, min: 1, max: 31, text: (v) => '$v.', onChanged: (v) => setState(() => _pTag = v)),
            _Stepper(label: 'im Monat', wert: _pMonat, min: 1, max: 12, text: monatName, onChanged: (v) => setState(() => _pMonat = v)),
          ],
          const SizedBox(height: 16),
          LxCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(erzeugung ? 'Ersparnis rechnen' : 'Kosten rechnen', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                erzeugung ? 'Rechnet aus Erzeugung, Eigenverbrauch und Strompreis, was die Anlage spart.' : (_art.istWasser ? 'Wasser läuft meist über Miete und Nebenkosten, darum ist es zunächst aus.' : 'Rechnet Verbrauchskosten, Grund- und Zählergebühr und die Abschläge.'),
                style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
              ),
              value: _kosten,
              onChanged: (v) => setState(() => _kosten = v),
            ),
          ),
          if (_kosten) ...[
            const SizedBox(height: 12),
            MonoLabel(erzeugung ? '// strompreis für die ersparnis' : '// tarif'),
            const SizedBox(height: 6),
            if (_preise.isEmpty) Text(erzeugung ? 'Noch kein Strompreis. Ohne ihn rechnet die App keine Ersparnis.' : 'Noch kein Tarif. Ohne ihn rechnet die App keine Kosten.', style: const TextStyle(color: kTextMuted, fontSize: 13)),
            for (var i = 0; i < _preise.length; i++)
              LxCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                onTap: () => unawaited(_preisBearbeiten(index: i)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Ab ${datumTextDeutsch(_preise[i].ab)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(
                              '${preisAnzeige(_preise[i].arbeitspreis)} je $einheit${erzeugung ? '' : ' · Grund ${euroKurz(_preise[i].grundgebuehrJahr)} im Jahr${_preise[i].zaehlergebuehrJahr > 0 ? ' · Zähler ${euroKurz(_preise[i].zaehlergebuehrJahr)} im Jahr' : ''}'}',
                              style: const TextStyle(fontSize: 12, color: kTextMuted),
                            ),
                          ],
                        ),
                      ),
                      IconButton(tooltip: 'Preisstand ab ${datumTextDeutsch(_preise[i].ab)} entfernen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => _preise = [..._preise]..removeAt(i))),
                    ],
                  ),
                ),
              ),
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(_preisBearbeiten()), icon: const Icon(Icons.add), label: Text(erzeugung ? 'Strompreis hinzufügen' : 'Preisstand hinzufügen'))),
            Text(erzeugung ? 'Bei einer Preisänderung trägst du den neuen Strompreis mit Datum ein. Alte Zeiträume rechnen mit dem alten Preis.' : 'Bei einer Preisänderung trägst du den neuen Preis mit Datum ein. Alte Zeiträume rechnen mit dem alten Preis. Grund- und Zählergebühr werden anteilig auf Tage umgelegt.', style: const TextStyle(fontSize: 12, color: kTextMuted)),
            if (!erzeugung) ...[
              const SizedBox(height: 12),
              TextField(controller: _abschlag, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))], decoration: const InputDecoration(labelText: 'Abschlag im Monat in Euro (optional)')),
            ],
          ],
          if (erzeugung) ...[
            const SizedBox(height: 14),
            const MonoLabel('// solar'),
            const SizedBox(height: 6),
            TextField(controller: _anlage, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))], decoration: const InputDecoration(labelText: 'Anschaffungspreis der Anlage in Euro', helperText: 'Damit rechnet die App aus, wann sich die Anlage bezahlt gemacht hat')),
            const SizedBox(height: 12),
            TextField(controller: _eigen, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Eigenverbrauch in Prozent', helperText: 'Anteil des Solarstroms, den ihr selbst nutzt (geschätzt)')),
            const SizedBox(height: 12),
            TextField(controller: _verguetung, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))], decoration: const InputDecoration(labelText: 'Einspeisevergütung je kWh in Euro (optional)')),
          ],
          if (!erzeugung) ...[
            const SizedBox(height: 14),
            LxCard(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: const Text('Ungewöhnlich hohen Verbrauch melden', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(_warn ? 'ab $_warnProzent % über dem Vorjahresmonat' : 'aus', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                value: _warn,
                onChanged: (v) => setState(() => _warn = v),
              ),
            ),
            if (_warn) _Stepper(label: 'Schwelle in Prozent', wert: _warnProzent, min: 5, max: 500, schritt: 5, text: (v) => '$v %', onChanged: (v) => setState(() => _warnProzent = v)),
          ],
          const SizedBox(height: 14),
          TextField(controller: _notiz, maxLength: kMaxNotizZeichen, minLines: 1, maxLines: 3, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Notiz (optional)', counterText: '')),
          if (_neu) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _start,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: InputDecoration(labelText: 'Aktueller Zählerstand${einheit.isEmpty ? '' : ' in $einheit'} (optional)', helperText: 'Wird als erster Stand für heute eingetragen'),
            ),
          ] else if (reihe != null && istJuengster) ...[
            const SizedBox(height: 20),
            const MonoLabel('// weitere aktionen', color: kTextMuted),
            const SizedBox(height: 6),
            if (!(_alt?.archiviert ?? false)) OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(zaehlerWechselOeffnen(context, ref, reihe.id)), icon: const Icon(Icons.swap_horiz), label: const Text('Zähler wechseln (neue Nummer, neuer Startstand)')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => unawaited(_archivieren(reihe)),
              icon: Icon((_alt?.archiviert ?? false) ? Icons.unarchive_outlined : Icons.archive_outlined),
              label: Text((_alt?.archiviert ?? false) ? 'Wieder aktivieren' : 'Archivieren (die Stände bleiben)'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: kDanger),
              onPressed: () => unawaited(_loeschen(reihe)),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Zähler endgültig löschen'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _archivieren(ZaehlerReihe r) async {
    final repo = ref.read(zaehlerRepositoryProvider);
    final nav = Navigator.of(context);
    try {
      if (r.archiviert) {
        await repo.reaktivieren(r.id);
      } else {
        final ok = await bestaetigen(context, titel: 'Zähler archivieren?', text: '„${r.name}“ zählt dann nicht mehr mit und erinnert nicht mehr. Alle Stände bleiben erhalten, du kannst ihn jederzeit wieder aktivieren.', knopf: 'Archivieren');
        if (!ok) return;
        await repo.archivieren(r.id);
      }
      if (mounted) nav.pop();
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(zaehlerFehlerText(e))));
    }
  }

  Future<void> _loeschen(ZaehlerReihe r) async {
    final nav = Navigator.of(context);
    final weg = await zaehlerLoeschenMitBestaetigung(context, ref, r.id, r.name);
    // der Editor und der Verlauf dieses Zählers schließen sich (der Zähler ist weg)
    if (weg && mounted) {
      nav.pop();
      if (nav.canPop()) nav.pop();
    }
  }
}

/// Zahl wählen mit Plus und Minus (jeweils mindestens 48 px).
class _Stepper extends StatelessWidget {
  final String label;
  final int wert;
  final int min;
  final int max;
  final int schritt;
  final String Function(int) text;
  final ValueChanged<int> onChanged;
  const _Stepper({required this.label, required this.wert, required this.min, required this.max, required this.text, required this.onChanged, this.schritt = 1});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label: ${text(wert)}',
    child: Row(
      children: [
        Expanded(child: ExcludeSemantics(child: Text(label, style: const TextStyle(color: kTextMuted)))),
        IconButton(tooltip: '$label verringern', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.remove_circle_outline), onPressed: wert > min ? () => onChanged((wert - schritt).clamp(min, max)) : null),
        SizedBox(width: 96, child: Center(child: ExcludeSemantics(child: Text(text(wert), style: const TextStyle(fontFamily: kFontMono, fontWeight: FontWeight.w700))))),
        IconButton(tooltip: '$label erhöhen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.add_circle_outline), onPressed: wert < max ? () => onChanged((wert + schritt).clamp(min, max)) : null),
      ],
    ),
  );
}

// ---------------------------------------------------------------- Preisstand

class _PreisDialog extends StatefulWidget {
  final Preis? start;
  final bool nurArbeit;
  final String einheit;
  const _PreisDialog({required this.start, required this.nurArbeit, required this.einheit});

  @override
  State<_PreisDialog> createState() => _PreisDialogState();
}

class _PreisDialogState extends State<_PreisDialog> {
  late final _arbeit = TextEditingController(text: widget.start == null ? '' : preisText(widget.start!.arbeitspreis));
  late final _grund = TextEditingController(text: widget.start == null || widget.start!.grundgebuehrJahr == 0 ? '' : geldText(widget.start!.grundgebuehrJahr));
  late final _zaehler = TextEditingController(text: widget.start == null || widget.start!.zaehlergebuehrJahr == 0 ? '' : geldText(widget.start!.zaehlergebuehrJahr));
  late DateTime _ab = widget.start?.abTag ?? zaehlerHeute(DateTime.now());
  String? _fehler;

  @override
  void dispose() {
    _arbeit.dispose();
    _grund.dispose();
    _zaehler.dispose();
    super.dispose();
  }

  Future<void> _datum() async {
    final d = await showDatePicker(useRootNavigator: false, context: context, initialDate: _lokal(_ab), firstDate: DateTime(2000), lastDate: DateTime(2100), locale: const Locale('de', 'DE'));
    if (d != null && mounted) setState(() => _ab = DateTime.utc(d.year, d.month, d.day));
  }

  void _ok() {
    final ap = preisParsen(_arbeit.text);
    if (ap == null || ap > kMaxPreisAp) return setState(() => _fehler = 'Gib den Preis je ${widget.einheit.isEmpty ? 'Einheit' : widget.einheit} in Euro ein, zum Beispiel 0,3456.');
    int gg = 0;
    int zg = 0;
    if (!widget.nurArbeit) {
      if (_grund.text.trim().isNotEmpty) {
        final g = geldParsen(_grund.text);
        if (g == null || g > kMaxGeldCent) return setState(() => _fehler = 'Die Grundgebühr ist ein Betrag in Euro pro Jahr.');
        gg = g;
      }
      if (_zaehler.text.trim().isNotEmpty) {
        final z = geldParsen(_zaehler.text);
        if (z == null || z > kMaxGeldCent) return setState(() => _fehler = 'Die Zählergebühr ist ein Betrag in Euro pro Jahr.');
        zg = z;
      }
    }
    Navigator.of(context).pop(Preis(ab: tagIso(_ab), arbeitspreis: ap, grundgebuehrJahr: gg, zaehlergebuehrJahr: zg));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.nurArbeit ? 'Strompreis' : 'Preisstand'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 10)],
        OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(_datum()), icon: const Icon(Icons.calendar_today, size: 18), label: Text('Gilt ab ${tagDeutsch(_ab)}')),
        const SizedBox(height: 12),
        TextField(controller: _arbeit, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))], decoration: InputDecoration(labelText: 'Arbeitspreis in Euro je ${widget.einheit.isEmpty ? 'Einheit' : widget.einheit}')),
        if (!widget.nurArbeit) ...[
          const SizedBox(height: 12),
          TextField(controller: _grund, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))], decoration: const InputDecoration(labelText: 'Grundgebühr in Euro im Jahr')),
          const SizedBox(height: 12),
          TextField(controller: _zaehler, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))], decoration: const InputDecoration(labelText: 'Zählergebühr in Euro im Jahr')),
        ],
      ],
    ),
    actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')), FilledButton(onPressed: _ok, child: const Text('Übernehmen'))],
  );
}

// ---------------------------------------------------------------- Zählerwechsel

/// Zählerwechsel: der alte Zähler bekommt am Tag seinen Endstand und wird archiviert, der neue beginnt mit dem Startstand; der Verbrauch läuft nahtlos weiter. true = gewechselt.
Future<bool> zaehlerWechselOeffnen(BuildContext context, WidgetRef ref, String reiheId, {DateTime? datum}) async {
  final ok = await showDialog<bool>(useRootNavigator: false, context: context, builder: (_) => _WechselDialog(reiheId: reiheId, datum: datum));
  return ok ?? false;
}

class _WechselDialog extends ConsumerStatefulWidget {
  final String reiheId;
  final DateTime? datum;
  const _WechselDialog({required this.reiheId, this.datum});

  @override
  ConsumerState<_WechselDialog> createState() => _WechselDialogState();
}

class _WechselDialogState extends ConsumerState<_WechselDialog> {
  final _ende = TextEditingController();
  final _start = TextEditingController(text: '0');
  final _nummer = TextEditingController();
  late DateTime _datum = widget.datum ?? zaehlerHeute(DateTime.now());
  var _speichert = false;
  String? _fehler;

  @override
  void dispose() {
    _ende.dispose();
    _start.dispose();
    _nummer.dispose();
    super.dispose();
  }

  Future<void> _datumWaehlen(DateTime heute) async {
    final d = await showDatePicker(useRootNavigator: false, context: context, initialDate: _lokal(_datum), firstDate: DateTime(2000), lastDate: _lokal(heute), locale: const Locale('de', 'DE'));
    if (d != null && mounted) setState(() => _datum = DateTime.utc(d.year, d.month, d.day));
  }

  Future<void> _wechseln(ZaehlerReihe r) async {
    final ende = mengeParsen(_ende.text);
    final start = mengeParsen(_start.text);
    if (ende == null || ende > kMaxStandMilli) return setState(() => _fehler = 'Gib den Endstand des alten Zählers als Zahl ein.');
    if (start == null || start > kMaxStandMilli) return setState(() => _fehler = 'Gib den Startstand des neuen Zählers als Zahl ein (meist 0).');
    final letzter = r.letzter;
    if (letzter != null && (ende < letzter.milli || tagNummer(_datum) < tagNummer(letzter.tag))) {
      return setState(() => _fehler = 'Der Endstand darf nicht kleiner sein als der letzte Stand (${standAnzeige(letzter.milli)}), und das Datum nicht davor liegen.');
    }
    final nr = _nummer.text.trim();
    final nav = Navigator.of(context);
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      await ref.read(zaehlerRepositoryProvider).zaehlerWechseln(r.id, datum: _datum, endstandMilli: ende, startstandMilli: start, neu: (alt) => alt.kopie(nummer: nr));
      if (mounted) nav.pop(true);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = zaehlerFehlerText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = ref.watch(zaehlerDatenProvider).reihe(widget.reiheId);
    final heute = zaehlerHeute(ref.watch(minutenTaktProvider).value ?? DateTime.now());
    if (r == null) return AlertDialog(title: const Text('Zähler wechseln'), content: const Text('Diesen Zähler gibt es nicht mehr.'), actions: [TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Schließen'))]);
    final einheit = r.inhalt.einheit;
    return AlertDialog(
      title: const Text('Zähler wechseln'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Der alte Zähler wird archiviert, der neue beginnt mit seinem Startstand. Der Verbrauch läuft nahtlos weiter.', style: TextStyle(fontSize: 13, color: kTextMuted)),
          const SizedBox(height: 10),
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 10)],
          OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(_datumWaehlen(heute)), icon: const Icon(Icons.calendar_today, size: 18), label: Text('Wechsel am ${tagDeutsch(_datum)}')),
          const SizedBox(height: 12),
          TextField(controller: _ende, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))], decoration: InputDecoration(labelText: 'Endstand des alten Zählers in $einheit', helperText: r.letzter == null ? null : 'Letzter Stand: ${standAnzeige(r.letzter!.milli)}')),
          const SizedBox(height: 12),
          TextField(controller: _start, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))], decoration: InputDecoration(labelText: 'Startstand des neuen Zählers in $einheit')),
          const SizedBox(height: 12),
          TextField(controller: _nummer, maxLength: kMaxNummerZeichen, decoration: const InputDecoration(labelText: 'Neue Zählernummer (optional)', counterText: '')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
        FilledButton(onPressed: _speichert ? null : () => unawaited(_wechseln(r)), child: const Text('Wechseln')),
      ],
    );
  }
}
