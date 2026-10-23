// Zählerstand eintragen (Abschnitt 6l): Zählerwahl, Datum (nie in der Zukunft), Ziffernfeld mit Nachkommastellen, sofort berechneter Verbrauch und Verbrauch je Tag, Plausibilitätsprüfung
// (Zählerwechsel-Verdacht, verdrehte Ziffern, doppelter Tag) und Notiz. Mehrere Zähler hintereinander ("Alle Wasserzähler ablesen"): ein Datum für alle, die Zähler werden nacheinander
// abgefragt, jeder Stand wird sofort gespeichert. Auch das Bearbeiten eines vorhandenen Standes ([standBearbeitenOeffnen]).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/medikamente/medikament_modelle.dart' show tagText;
import '../../data/zaehler/zaehler_logik.dart';
import '../../data/zaehler/zaehler_modelle.dart';
import '../../data/zaehler/zaehler_repository.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../ui/widgets.dart';
import '../../widgets/ungespeichert_schutz.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'zaehler_anzeige.dart';
import 'zaehler_editor.dart' show zaehlerWechselOeffnen;

/// Öffnet "Stand eintragen": [reiheIds] = die Zähler, die nacheinander abgefragt werden (ohne Angabe: freie Wahl unter den aktiven Zählern).
Future<void> standEintragenOeffnen(BuildContext context, {List<String>? reiheIds}) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ZaehlerStandScreen(reiheIds: reiheIds)));
}

/// Tage heute, begrenzt auf einen gültigen Tag für den Datumsdialog.
DateTime _lokal(DateTime tag) => DateTime(tag.year, tag.month, tag.day);

String _hinweisText(StandHinweis h, {required String letzter, required String einheit}) => switch (h) {
  StandHinweis.zukunft => 'Das Datum liegt in der Zukunft. Ein Stand kann nur für heute oder früher eingetragen werden.',
  StandHinweis.datumDoppelt => 'Für diesen Tag gibt es schon einen Stand. Der neue ersetzt ihn in der Auswertung.',
  StandHinweis.niedriger => 'Der Stand ist niedriger als der letzte ($letzter $einheit). Wurde der Zähler gewechselt, oder hast du dich vertippt?',
  StandHinweis.hoeherAlsSpaeterer => 'Der Stand ist höher als ein späterer Stand. Stimmt das Datum?',
  StandHinweis.sprung => 'Der Verbrauch ist viel höher als üblich. Haben sich Ziffern verdreht?',
};

class ZaehlerStandScreen extends ConsumerStatefulWidget {
  final List<String>? reiheIds;
  const ZaehlerStandScreen({super.key, this.reiheIds});

  @override
  ConsumerState<ZaehlerStandScreen> createState() => _ZaehlerStandScreenState();
}

class _ZaehlerStandScreenState extends ConsumerState<ZaehlerStandScreen> {
  final _wert = TextEditingController();
  final _notiz = TextEditingController();
  DateTime? _datum;
  String? _gewaehlt;
  var _schritt = 0;
  var _bestaetigt = false;
  var _speichert = false;
  String? _fehler;

  bool get _folge => (widget.reiheIds?.length ?? 0) > 1;

  @override
  void dispose() {
    _wert.dispose();
    _notiz.dispose();
    super.dispose();
  }

  String? _aktuelleId(ZaehlerDaten d) {
    if (_folge) {
      final ids = widget.reiheIds!;
      return _schritt < ids.length ? ids[_schritt] : null;
    }
    return _gewaehlt ?? widget.reiheIds?.firstOrNull ?? d.reihen.where((r) => !r.archiviert).firstOrNull?.id;
  }

  Future<void> _datumWaehlen(DateTime heute) async {
    final start = _datum ?? heute;
    final d = await showDatePicker(
      useRootNavigator: false,
      context: context,
      initialDate: _lokal(start),
      firstDate: DateTime(2000),
      lastDate: _lokal(heute),
      locale: const Locale('de', 'DE'),
    );
    if (d != null && mounted) {
      setState(() {
        _datum = DateTime.utc(d.year, d.month, d.day);
        _bestaetigt = false;
      });
    }
  }

  Future<void> _speichern(ZaehlerReihe r, DateTime datum, int milli, {required bool letzterSchritt}) async {
    if (_speichert) return;
    final repo = ref.read(zaehlerRepositoryProvider);
    final nav = Navigator.of(context);
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      await repo.standErfassen(r.id, datum: datum, milli: milli, notiz: _notiz.text.trim());
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = zaehlerFehlerText(e);
        });
      }
      return;
    }
    if (!mounted) return;
    if (_folge && !letzterSchritt) {
      setState(() {
        _speichert = false;
        _schritt++;
        _wert.clear();
        _notiz.clear();
        _bestaetigt = false;
      });
    } else {
      nav.pop();
    }
  }

  void _ueberspringen(int anzahl) {
    if (_schritt + 1 >= anzahl) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _schritt++;
      _wert.clear();
      _notiz.clear();
      _bestaetigt = false;
      _fehler = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(zaehlerDarfProvider) ? ref.watch(zaehlerDatenProvider) : const ZaehlerDaten(geladen: true);
    final heute = zaehlerHeute(DateTime.now());
    final aktiv = [for (final r in daten.reihen) if (!r.archiviert) r];
    final id = _aktuelleId(daten);
    final r = id == null ? null : daten.reihe(id);
    if (!daten.darf || !daten.geladen || r == null) {
      return AuthSeite(
        label: '// neu',
        titel: 'Zählerstand',
        maxBreite: kMaxContentWidth,
        kinder: [if (!daten.geladen) const Center(child: CircularProgressIndicator()) else const MeldungsBox('Hier gibt es gerade keinen Zähler zum Ablesen.', fehler: false)],
      );
    }
    final datum = _datum ?? heute;
    final einheit = r.inhalt.einheit;
    final milli = mengeParsen(_wert.text);
    final wertFehler = _wert.text.trim().isNotEmpty && (milli == null || milli > kMaxStandMilli);
    final plaus = milli == null || milli > kMaxStandMilli ? null : pruefeStand(datum: datum, milli: milli, bestehende: r.staende, heute: heute);
    final vorschau = milli == null || milli > kMaxStandMilli ? null : standVorschau(r, datum, milli);
    final hinweise = plaus?.hinweise ?? const <StandHinweis>[];
    final davorText = vorschau?.davor == null ? (r.letzter == null ? '–' : standAnzeige(r.letzter!.milli)) : standAnzeige(vorschau!.davor!.milli);
    final braucheBestaetigung = hinweise.any((h) => h != StandHinweis.zukunft);
    final kannSpeichern = !_speichert && milli != null && milli <= kMaxStandMilli && !(plaus?.blockiert ?? false) && (!braucheBestaetigung || _bestaetigt);
    final anzahl = widget.reiheIds?.length ?? 1;
    final letzterSchritt = !_folge || _schritt + 1 >= anzahl;
    return UngespeichertSchutz(
      geaendert: () => _wert.text.trim().isNotEmpty || _notiz.text.trim().isNotEmpty,
      aenderungen: Listenable.merge([_wert, _notiz]),
      child: AuthSeite(
        label: _folge ? '// zähler ${_schritt + 1} von $anzahl' : '// neu',
        titel: 'Zählerstand',
        maxBreite: kMaxContentWidth,
        fussleiste: Row(
          children: [
            if (_folge) ...[
              OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: _speichert ? null : () => _ueberspringen(anzahl), child: const Text('Überspringen')),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: kannSpeichern ? () => unawaited(_speichern(r, datum, milli, letzterSchritt: letzterSchritt)) : null,
                child: Text(letzterSchritt ? 'Speichern' : 'Speichern und weiter'),
              ),
            ),
          ],
        ),
        kinder: [
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
          if (!_folge) ...[
            const MonoLabel('// zähler'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in aktiv)
                  AuswahlKnopf(
                    text: a.name,
                    gewaehlt: a.id == r.id,
                    onTap: () => setState(() {
                      _gewaehlt = a.id;
                      _bestaetigt = false;
                      _wert.clear();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ] else ...[
            Row(children: [Icon(zaehlerSymbol(r.art), color: zaehlerFarbe(r.art)), const SizedBox(width: 8), Expanded(child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)))]),
            const SizedBox(height: 4),
            const Text('Ein Datum gilt für alle Zähler dieser Runde. Jeder Stand wird sofort gespeichert.', style: TextStyle(fontSize: 12, color: kTextMuted)),
            const SizedBox(height: 14),
          ],
          const MonoLabel('// datum'),
          const SizedBox(height: 6),
          Semantics(
            button: true,
            label: 'Datum der Ablesung: ${tagDeutsch(datum)}${datum == heute ? ', heute' : ''}. Ändern',
            excludeSemantics: true,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft),
              onPressed: _folge && _schritt > 0 ? null : () => unawaited(_datumWaehlen(heute)),
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text('${tagDeutsch(datum)}${datum == heute ? ' · heute' : ''}'),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _wert,
            autofocus: _folge && _schritt > 0,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            style: const TextStyle(fontFamily: kFontMono, fontSize: 24, fontWeight: FontWeight.w700),
            onChanged: (_) => setState(() => _bestaetigt = false),
            decoration: InputDecoration(labelText: 'Zählerstand in $einheit', helperText: 'Mit Nachkommastellen, wie am Zähler (Komma)', errorText: wertFehler ? 'Gib den Stand als Zahl ein, zum Beispiel 48213,5.' : null),
          ),
          const SizedBox(height: 14),
          LxCard(
            child: Column(
              children: [
                _Zeile('Letzter Stand', r.letzter == null && vorschau?.davor == null ? 'noch keiner' : '$davorText $einheit${vorschau?.davor == null ? '' : ' am ${tagKurz(vorschau!.davor!.tag)}'}'),
                if (vorschau?.verbrauchMilli != null) _Zeile('Verbrauch seitdem', '${verbrauchAnzeige(vorschau!.verbrauchMilli!, einheit)} in ${vorschau.tage} ${vorschau.tage == 1 ? 'Tag' : 'Tagen'}'),
                if (vorschau?.proTagMilli != null) _Zeile('Pro Tag', '${verbrauchAnzeige(vorschau!.proTagMilli!, einheit)}${vorschau.vorjahrProTagMilli == null ? '' : ' (Vorjahr ${verbrauchAnzeige(vorschau.vorjahrProTagMilli!, '', mitEinheit: false)})'}'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (milli != null && milli <= kMaxStandMilli && hinweise.isEmpty)
            const MeldungsBox('Plausibel. Der Verbrauch liegt im üblichen Bereich.', fehler: false)
          else if (hinweise.isNotEmpty) ...[
            for (final h in hinweise)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Semantics(
                  liveRegion: true,
                  container: true,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: kWarn.withValues(alpha: 0.08), border: Border.all(color: kWarn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_hinweisText(h, letzter: davorText, einheit: einheit), style: const TextStyle(height: 1.35)),
                        if (h == StandHinweis.niedriger && r.letzter != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                              onPressed: () => unawaited(zaehlerWechselOeffnen(context, ref, r.id, datum: datum)),
                              child: const Text('Zähler wurde gewechselt'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (braucheBestaetigung)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _bestaetigt,
                onChanged: (v) => setState(() => _bestaetigt = v ?? false),
                title: const Text('Ich habe geprüft, der Stand stimmt'),
              ),
          ],
          const SizedBox(height: 12),
          TextField(controller: _notiz, maxLength: kMaxStandNotizZeichen, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Notiz (optional)', counterText: '')),
        ],
      ),
    );
  }
}

class _Zeile extends StatelessWidget {
  final String label;
  final String wert;
  const _Zeile(this.label, this.wert);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: const TextStyle(color: kTextMuted))),
        const SizedBox(width: 12),
        Flexible(child: Text(wert, textAlign: TextAlign.right, style: const TextStyle(fontFamily: kFontMono, fontWeight: FontWeight.w600))),
      ],
    ),
  );
}

// ---------------------------------------------------------------- Bearbeiten

/// Dialog zum Ändern eines vorhandenen Standes (Datum, Wert, Notiz) mit derselben Plausibilitätsprüfung. true = gespeichert.
Future<bool> standBearbeitenOeffnen(BuildContext context, WidgetRef ref, ZaehlerReihe reihe, StandAnsicht stand) async {
  final inhalt = stand.inhalt;
  if (inhalt == null || inhalt.tag == null) return false;
  final ok = await showDialog<bool>(useRootNavigator: false, context: context, builder: (_) => _StandDialog(reihe: reihe, stand: stand, inhalt: inhalt));
  return ok ?? false;
}

class _StandDialog extends ConsumerStatefulWidget {
  final ZaehlerReihe reihe;
  final StandAnsicht stand;
  final StandInhalt inhalt;
  const _StandDialog({required this.reihe, required this.stand, required this.inhalt});

  @override
  ConsumerState<_StandDialog> createState() => _StandDialogState();
}

class _StandDialogState extends ConsumerState<_StandDialog> {
  late final _wert = TextEditingController(text: mengeText(widget.inhalt.milli, kuerzen: true));
  late final _notiz = TextEditingController(text: widget.inhalt.notiz);
  late DateTime _datum = widget.inhalt.tag!;
  var _bestaetigt = false;
  var _speichert = false;
  String? _fehler;

  @override
  void dispose() {
    _wert.dispose();
    _notiz.dispose();
    super.dispose();
  }

  Future<void> _datumWaehlen(DateTime heute) async {
    final d = await showDatePicker(useRootNavigator: false, context: context, initialDate: _lokal(_datum), firstDate: DateTime(2000), lastDate: _lokal(heute), locale: const Locale('de', 'DE'));
    if (d != null && mounted) setState(() => _datum = DateTime.utc(d.year, d.month, d.day));
  }

  @override
  Widget build(BuildContext context) {
    final heute = zaehlerHeute(DateTime.now());
    final einheit = widget.reihe.inhalt.einheit;
    final milli = mengeParsen(_wert.text);
    // die anderen Stände der Reihe (ohne den bearbeiteten selbst)
    final eigener = widget.inhalt;
    final andere = [for (final s in widget.reihe.staende) if (!(s.tag == eigener.tag && s.milli == eigener.milli)) s];
    final plaus = milli == null || milli > kMaxStandMilli ? null : pruefeStand(datum: _datum, milli: milli, bestehende: andere, heute: heute);
    final hinweise = (plaus?.hinweise ?? const <StandHinweis>[]).where((h) => h != StandHinweis.datumDoppelt || andere.any((s) => s.tag == _datum)).toList();
    final brauche = hinweise.any((h) => h != StandHinweis.zukunft);
    final davor = andere.where((s) => s.tag.isBefore(_datum)).lastOrNull;
    final kann = !_speichert && milli != null && milli <= kMaxStandMilli && !(plaus?.blockiert ?? false) && (!brauche || _bestaetigt);
    return AlertDialog(
      title: const Text('Stand ändern'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 10)],
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => unawaited(_datumWaehlen(heute)),
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(tagDeutsch(_datum)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _wert,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            onChanged: (_) => setState(() => _bestaetigt = false),
            decoration: InputDecoration(labelText: 'Zählerstand in $einheit'),
          ),
          const SizedBox(height: 8),
          TextField(controller: _notiz, maxLength: kMaxStandNotizZeichen, decoration: const InputDecoration(labelText: 'Notiz', counterText: '')),
          for (final h in hinweise) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_hinweisText(h, letzter: davor == null ? '–' : standAnzeige(davor.milli), einheit: einheit), style: const TextStyle(color: kWarn, fontSize: 13))),
          if (brauche) CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _bestaetigt, onChanged: (v) => setState(() => _bestaetigt = v ?? false), title: const Text('Ich habe geprüft, der Stand stimmt')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
        FilledButton(
          onPressed: kann
              ? () async {
                  final nav = Navigator.of(context);
                  setState(() {
                    _speichert = true;
                    _fehler = null;
                  });
                  try {
                    await ref.read(zaehlerRepositoryProvider).standAendern(widget.stand.id, datum: _datum, milli: milli, notiz: _notiz.text.trim());
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
              : null,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

/// Text zum Datum eines Standes in Listen: "23.10.2026".
String standDatumText(StandInhalt s) => datumTextDeutsch(s.datum);

String standTagIso(DateTime t) => tagText(t);
