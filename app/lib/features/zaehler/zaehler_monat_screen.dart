// Monatswert eintragen (Abschnitt 6l, Eingabeart "Monatswerte"): Zähler (nur solche mit Monatswerten), Monat (Standard: der Vormonat; wählbar sind der laufende Monat und die 24 davor),
// Wert als Dezimalzahl mit Komma. Zeigt sofort den Vorjahresmonat und die Summe des Jahres, fragt nach, wenn der Monat schon einen Wert hat ("ersetzen?") oder der Wert mehr als doppelt so
// hoch ist wie im Vorjahresmonat ("Stimmt der Wert?"). Der laufende Monat ist ein Zwischenstand. Auch zum Bearbeiten eines vorhandenen Monatswerts ([monatswertEintragenOeffnen] mit [monat]).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/zaehler/zaehler_logik.dart' show MonatsWert;
import '../../data/zaehler/zaehler_modelle.dart';
import '../../data/zaehler/zaehler_monate.dart';
import '../../data/zaehler/zaehler_repository.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../ui/widgets.dart';
import '../../widgets/ungespeichert_schutz.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'zaehler_anzeige.dart';

/// Öffnet "Monatswert eintragen" für den Zähler [reiheId] (ohne Angabe: der erste Zähler mit Monatswerten); [monat] wählt den Monat vor, [bearbeiten] öffnet einen vorhandenen Wert zum Ändern.
Future<void> monatswertEintragenOeffnen(BuildContext context, {String? reiheId, ({int jahr, int monat})? monat, bool bearbeiten = false}) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ZaehlerMonatScreen(reiheId: reiheId, monat: monat, bearbeiten: bearbeiten)));
}

/// Text zu einem Monat: "September 2026".
String monatTitel(int jahr, int monat) => '${monatName(monat)} $jahr';

/// Name des Wertes in Texten: Erzeugung bei einer Anlage, sonst Verbrauch.
String wertWort(ZaehlerArt art) => istErzeugung(art) ? 'Erzeugung' : 'Verbrauch';

class ZaehlerMonatScreen extends ConsumerStatefulWidget {
  final String? reiheId;
  final ({int jahr, int monat})? monat;
  final bool bearbeiten;
  const ZaehlerMonatScreen({super.key, this.reiheId, this.monat, this.bearbeiten = false});

  @override
  ConsumerState<ZaehlerMonatScreen> createState() => _ZaehlerMonatScreenState();
}

class _ZaehlerMonatScreenState extends ConsumerState<ZaehlerMonatScreen> {
  final _wert = TextEditingController();
  final _notiz = TextEditingController();
  String? _gewaehlt;
  ({int jahr, int monat})? _monat;
  var _bestaetigt = false;
  var _speichert = false;
  var _vorbelegt = false;
  String? _fehler;

  @override
  void dispose() {
    _wert.dispose();
    _notiz.dispose();
    super.dispose();
  }

  Future<void> _speichern(ZaehlerReihe r, ({int jahr, int monat}) m, int milli) async {
    if (_speichert) return;
    final repo = ref.read(zaehlerRepositoryProvider);
    final nav = Navigator.of(context);
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      await repo.monatswertErfassen(r.id, jahr: m.jahr, monat: m.monat, milli: milli, notiz: _notiz.text.trim());
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = zaehlerFehlerText(e);
        });
      }
      return;
    }
    if (mounted) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(zaehlerDarfProvider) ? ref.watch(zaehlerDatenProvider) : const ZaehlerDaten(geladen: true);
    final heute = zaehlerHeute(ref.watch(minutenTaktProvider).value ?? DateTime.now());
    final aktiv = [for (final r in daten.reihen) if (!r.archiviert && r.monatlich) r];
    final id = _gewaehlt ?? widget.reiheId ?? aktiv.firstOrNull?.id;
    final r = id == null ? null : daten.reihe(id);
    if (!daten.darf || !daten.geladen || r == null || !r.monatlich) {
      return AuthSeite(
        label: '// neu',
        titel: 'Monatswert',
        maxBreite: kMaxContentWidth,
        kinder: [if (!daten.geladen) const Center(child: CircularProgressIndicator()) else const MeldungsBox('Hier gibt es gerade keinen Zähler mit Monatswerten.', fehler: false)],
      );
    }
    final m = _monat ??= widget.monat ?? vormonat(heute);
    final vorhanden = monatswertFuer(r.monatswerte, m.jahr, m.monat);
    if (!_vorbelegt) {
      _vorbelegt = true;
      if (widget.bearbeiten && vorhanden != null) {
        _wert.text = mengeText(vorhanden.milli, kuerzen: true);
        _notiz.text = vorhanden.notiz;
      }
    }
    final einheit = r.inhalt.einheit;
    final wort = wertWort(r.art);
    final milli = mengeParsen(_wert.text);
    final wertFehler = _wert.text.trim().isNotEmpty && (milli == null || milli > kMaxMonatswertMilli);
    final gueltig = milli != null && milli <= kMaxMonatswertMilli;
    final plaus = gueltig ? pruefeMonatswert(jahr: m.jahr, monat: m.monat, milli: milli, werte: r.monatswerte, heute: heute, ausser: widget.bearbeiten ? vorhanden?.id : null) : null;
    final hinweise = plaus?.hinweise ?? const <MonatswertHinweis>[];
    final braucheBestaetigung = plaus?.bestaetigung ?? false;
    final kannSpeichern = !_speichert && gueltig && !(plaus?.blockiert ?? false) && (!braucheBestaetigung || _bestaetigt);
    final vj = monatswertFuer(r.monatswerte, m.jahr - 1, m.monat);
    final prozent = gueltig && vj != null && vj.milli > 0 ? (milli - vj.milli) * 100 / vj.milli : null;
    // Summe des Jahres mit dem neuen Wert (der vorhandene Wert des Monats wird ersetzt)
    final ohneMonat = summeMonate(r.monatswerte, m.jahr, 1, m.jahr + 1, 1) - (vorhanden?.milli ?? 0);
    final jahrSumme = ohneMonat + (gueltig ? milli : (vorhanden?.milli ?? 0));
    final monate = auswahlMonate(heute);
    final laufend = (jahr: heute.year, monat: heute.month);
    final auswahlIndex = monate.indexWhere((x) => x.jahr == m.jahr && x.monat == m.monat);
    return UngespeichertSchutz(
      geaendert: () => _wert.text.trim().isNotEmpty && (!widget.bearbeiten || _wert.text.trim() != (vorhanden == null ? '' : mengeText(vorhanden.milli, kuerzen: true))),
      aenderungen: Listenable.merge([_wert, _notiz]),
      child: AuthSeite(
        label: widget.bearbeiten ? '// ändern' : '// neu',
        titel: 'Monatswert',
        maxBreite: kMaxContentWidth,
        fussleiste: FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: kannSpeichern ? () => unawaited(_speichern(r, m, milli)) : null,
          child: const Text('Speichern'),
        ),
        kinder: [
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
          if (aktiv.length > 1 && !widget.bearbeiten) ...[
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
            const SizedBox(height: 14),
          ],
          const MonoLabel('// monat'),
          const SizedBox(height: 6),
          Semantics(
            label: 'Monat des Werts: ${monatTitel(m.jahr, m.monat)}${m == laufend ? ', laufender Monat' : ''}. Ändern',
            container: true,
            child: DropdownButtonFormField<int>(
              key: ValueKey('monat-$auswahlIndex-${widget.bearbeiten}'),
              initialValue: auswahlIndex < 0 ? null : auswahlIndex,
              isExpanded: true,
              onChanged: widget.bearbeiten
                  ? null
                  : (i) {
                      if (i == null) return;
                      setState(() {
                        _monat = monate[i];
                        _bestaetigt = false;
                      });
                    },
              items: [
                for (var i = 0; i < monate.length; i++)
                  DropdownMenuItem(value: i, child: Text('${monatTitel(monate[i].jahr, monate[i].monat)}${monate[i] == laufend ? ' (laufend)' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14)),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _wert,
            autofocus: widget.bearbeiten,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            style: const TextStyle(fontFamily: kFontMono, fontSize: 24, fontWeight: FontWeight.w700),
            onChanged: (_) => setState(() => _bestaetigt = false),
            decoration: InputDecoration(
              labelText: '$wort im Monat in $einheit',
              helperText: 'Mit Nachkommastellen (Komma), zum Beispiel 48,3',
              errorText: wertFehler ? 'Gib den Wert als Zahl ein, zum Beispiel 48,3 (höchstens 100 000).' : null,
            ),
          ),
          const SizedBox(height: 14),
          LxCard(
            child: Column(
              children: [
                _Zeile('Vorjahresmonat', vj == null ? 'noch keiner' : '${monatKurz(m.monat)} ${m.jahr - 1}: ${verbrauchAnzeige(vj.milli, einheit)}${prozent == null ? '' : ' (${prozentAnzeige(prozent)})'}'),
                _Zeile('Summe ${m.jahr}', verbrauchAnzeige(jahrSumme, einheit)),
                if (vorhanden != null && !widget.bearbeiten) _Zeile('Bisher für ${monatKurz(m.monat)}', verbrauchAnzeige(vorhanden.milli, einheit)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (gueltig && hinweise.isEmpty)
            const MeldungsBox('Plausibel. Der Wert liegt im üblichen Bereich.', fehler: false)
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
                    child: Text(_hinweisText(h, vorhanden: vorhanden, vj: vj, einheit: einheit, wort: wort), style: const TextStyle(height: 1.35)),
                  ),
                ),
              ),
            if (braucheBestaetigung)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _bestaetigt,
                onChanged: (v) => setState(() => _bestaetigt = v ?? false),
                title: Text(hinweise.contains(MonatswertHinweis.hoeherAlsVorjahr) ? 'Ich habe geprüft, der Wert stimmt' : 'Ja, den vorhandenen Wert ersetzen'),
              ),
          ],
          const SizedBox(height: 12),
          TextField(controller: _notiz, maxLength: kMaxStandNotizZeichen, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Notiz (optional)', counterText: '')),
        ],
      ),
    );
  }
}

String _hinweisText(MonatswertHinweis h, {required MonatsWert? vorhanden, required MonatsWert? vj, required String einheit, required String wort}) => switch (h) {
  MonatswertHinweis.zukunft => 'Dieser Monat liegt in der Zukunft. Ein Monatswert kann nur für den laufenden oder einen früheren Monat eingetragen werden.',
  MonatswertHinweis.ersetzt => 'Für diesen Monat gibt es schon einen Wert${vorhanden == null ? '' : ' (${verbrauchAnzeige(vorhanden.milli, einheit)})'}. Der neue ersetzt ihn.',
  MonatswertHinweis.hoeherAlsVorjahr => 'Der Wert ist mehr als doppelt so hoch wie im Vorjahresmonat${vj == null ? '' : ' (${verbrauchAnzeige(vj.milli, einheit)})'}. Stimmt der Wert? Haben sich Ziffern verdreht?',
  MonatswertHinweis.zwischenstand => 'Der laufende Monat ist ein Zwischenstand. Trage den Endwert nach dem Monatsende noch einmal ein, er ersetzt diesen.',
};

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
