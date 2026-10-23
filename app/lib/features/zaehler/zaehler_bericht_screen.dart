// PDF-Bericht der Zähler (Abschnitt 6l): Zähler und Zeitraum wählen (Kalenderjahr, Abrechnungsperiode je Zähler oder eigener Zeitraum), Inhalt wählen (Stände, Verbrauch je Monat, Vorjahr,
// Kosten) und das PDF lokal erzeugen. Das Speichern (und von dort Drucken oder Teilen) übernimmt der Dialog des Systems; Web: Download. Nichts wird gesendet, nichts geloggt.
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/crypto/notfallblatt_download_stub.dart' if (dart.library.js_interop) '../../data/crypto/notfallblatt_download_web.dart';
import '../../data/zaehler/zaehler_bericht.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../data/zaehler/zaehler_pdf.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'zaehler_anzeige.dart';

/// Speichert [bytes] unter [name] über den Speichern-Dialog des Systems; false = abgebrochen. Für Tests überschreibbar.
typedef ZaehlerBerichtSpeichern = Future<bool> Function(String name, Uint8List bytes);

Future<bool> _systemSpeichern(String name, Uint8List bytes) async {
  if (kIsWeb) return notfallblattHerunterladen(name, bytes);
  final ziel = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: 'application/pdf', dialogTitle: 'Zählerbericht speichern', type: FileType.custom, allowedExtensions: const ['pdf']);
  return ziel != null;
}

final zaehlerBerichtSpeichernProvider = Provider<ZaehlerBerichtSpeichern>((ref) => _systemSpeichern);

/// Öffnet die Berichts-Auswahl, auf Wunsch mit einem vorgewählten Zähler (Schlüssel der Kachel).
Future<void> berichtOeffnen(BuildContext context, {String? schluessel}) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ZaehlerBerichtScreen(schluessel: schluessel)));
}

DateTime _lokal(DateTime t) => DateTime(t.year, t.month, t.day);

class ZaehlerBerichtScreen extends ConsumerStatefulWidget {
  final String? schluessel;
  const ZaehlerBerichtScreen({super.key, this.schluessel});

  @override
  ConsumerState<ZaehlerBerichtScreen> createState() => _ZaehlerBerichtScreenState();
}

class _ZaehlerBerichtScreenState extends ConsumerState<ZaehlerBerichtScreen> {
  Set<String>? _gewaehlt;
  var _zeitraum = BerichtZeitraum.kalenderjahr;
  int? _jahr;
  DateTime? _von;
  DateTime? _bis;
  var _staende = true;
  var _monate = true;
  var _vorjahr = true;
  var _kosten = false;
  var _arbeitet = false;
  String? _fehler;

  Future<void> _datum({required bool von, required DateTime heute}) async {
    final start = (von ? _von : _bis) ?? heute;
    final d = await showDatePicker(useRootNavigator: false, context: context, initialDate: _lokal(start), firstDate: DateTime(2000), lastDate: DateTime(2100), locale: const Locale('de', 'DE'));
    if (d == null || !mounted) return;
    setState(() {
      final t = DateTime.utc(d.year, d.month, d.day);
      if (von) {
        _von = t;
      } else {
        _bis = t;
      }
    });
  }

  Future<void> _erstellen(List<ZaehlerKachel> kacheln, BerichtWahl wahl, DateTime heute) async {
    if (_arbeitet) return;
    final speichern = ref.read(zaehlerBerichtSpeichernProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _arbeitet = true;
      _fehler = null;
    });
    Uint8List? pdf;
    try {
      pdf = zaehlerBerichtPdf(baueBericht(kacheln: kacheln, wahl: wahl, heute: heute));
      final ok = await speichern(kZaehlerBerichtDateiname, pdf);
      if (mounted) {
        setState(() => _arbeitet = false);
        if (ok) messenger.showSnackBar(const SnackBar(content: Text('Der Bericht ist erstellt. Du kannst ihn jetzt mit jedem PDF-Programm drucken.')));
      }
    } on Object {
      if (mounted) {
        setState(() {
          _arbeitet = false;
          _fehler = 'Der Bericht ließ sich nicht erstellen. Prüfe die Auswahl und versuche es noch einmal.';
        });
      }
    } finally {
      pdf?.fillRange(0, pdf.length, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(zaehlerDarfProvider)) return const AuthSeite(titel: 'Nicht verfügbar', maxBreite: kMaxContentWidth, kinder: [EmptyState(icon: Icons.lock_outline, title: 'Nicht verfügbar', hint: 'Diesen Bereich gibt es für dich nicht.')]);
    final daten = ref.watch(zaehlerDatenProvider);
    final heute = zaehlerHeute(ref.watch(minutenTaktProvider).value ?? DateTime.now());
    final alle = [...daten.kacheln, ...daten.archiviert.map((r) => daten.kachel('z:${r.id}')).whereType<ZaehlerKachel>()];
    _gewaehlt ??= widget.schluessel != null ? {widget.schluessel!} : {for (final k in daten.kacheln) k.schluessel};
    final gewaehlt = [for (final k in alle) if (_gewaehlt!.contains(k.schluessel)) k];
    final jahr = _jahr ?? heute.year;
    final wahl = BerichtWahl(zeitraum: _zeitraum, jahr: jahr, von: _von, bis: _bis, staende: _staende, monate: _monate, vorjahr: _vorjahr, kosten: _kosten);
    final kannErstellen = !_arbeitet && gewaehlt.isNotEmpty && wahl.gueltig && (_staende || _monate);
    if (!daten.geladen || alle.isEmpty) {
      return AuthSeite(label: '// zähler', titel: 'Bericht', maxBreite: kMaxContentWidth, kinder: [if (!daten.geladen) const Center(child: CircularProgressIndicator()) else const MeldungsBox('Es gibt noch keinen Zähler, für den ein Bericht entstehen kann.', fehler: false)]);
    }
    return AuthSeite(
      label: '// zähler',
      titel: 'Bericht',
      maxBreite: kMaxContentWidth,
      fussleiste: FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: kannErstellen ? () => unawaited(_erstellen(gewaehlt, wahl, heute)) : null,
        icon: const Icon(Icons.picture_as_pdf_outlined),
        label: Text(_arbeitet ? 'Wird erstellt …' : 'PDF erstellen und speichern'),
      ),
      kinder: [
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
        const MonoLabel('// zähler'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final k in alle)
              AuswahlKnopf(
                text: k.istGruppe ? '${k.titel} (${k.reihen.length})' : k.titel,
                gewaehlt: _gewaehlt!.contains(k.schluessel),
                onTap: () => setState(() => _gewaehlt = _gewaehlt!.contains(k.schluessel) ? ({..._gewaehlt!}..remove(k.schluessel)) : {..._gewaehlt!, k.schluessel}),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const MonoLabel('// zeitraum'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AuswahlKnopf(text: 'Kalenderjahr', gewaehlt: _zeitraum == BerichtZeitraum.kalenderjahr, onTap: () => setState(() => _zeitraum = BerichtZeitraum.kalenderjahr)),
            AuswahlKnopf(text: 'Abrechnungsperiode (letzte)', gewaehlt: _zeitraum == BerichtZeitraum.letztePeriode, onTap: () => setState(() => _zeitraum = BerichtZeitraum.letztePeriode)),
            AuswahlKnopf(text: 'Abrechnungsperiode (laufende)', gewaehlt: _zeitraum == BerichtZeitraum.laufendePeriode, onTap: () => setState(() => _zeitraum = BerichtZeitraum.laufendePeriode)),
            AuswahlKnopf(text: 'Eigener Zeitraum', gewaehlt: _zeitraum == BerichtZeitraum.eigen, onTap: () => setState(() => _zeitraum = BerichtZeitraum.eigen)),
          ],
        ),
        if (_zeitraum == BerichtZeitraum.kalenderjahr)
          Row(
            children: [
              IconButton(tooltip: 'Ein Jahr zurück', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => _jahr = jahr - 1)),
              Expanded(child: Center(child: Text('$jahr', style: const TextStyle(fontFamily: kFontMono, fontWeight: FontWeight.w700, fontSize: 16)))),
              IconButton(tooltip: 'Ein Jahr weiter', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.chevron_right), onPressed: jahr < heute.year ? () => setState(() => _jahr = jahr + 1) : null),
            ],
          ),
        if (_zeitraum == BerichtZeitraum.eigen) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(_datum(von: true, heute: heute)), icon: const Icon(Icons.calendar_today, size: 18), label: Text(_von == null ? 'Von wählen' : 'Von ${tagDeutsch(_von!)}')),
              OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(_datum(von: false, heute: heute)), icon: const Icon(Icons.calendar_today, size: 18), label: Text(_bis == null ? 'Bis wählen' : 'Bis ${tagDeutsch(_bis!)}')),
            ],
          ),
          if (_von != null && _bis != null && !wahl.gueltig) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Das Ende liegt vor dem Beginn.', style: TextStyle(color: kDanger, fontSize: 13))),
        ],
        const SizedBox(height: 16),
        const MonoLabel('// inhalt'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AuswahlKnopf(text: 'Stände', gewaehlt: _staende, onTap: () => setState(() => _staende = !_staende)),
            AuswahlKnopf(text: 'Verbrauch je Monat', gewaehlt: _monate, onTap: () => setState(() => _monate = !_monate)),
            AuswahlKnopf(text: 'Vorjahr', gewaehlt: _vorjahr, onTap: () => setState(() => _vorjahr = !_vorjahr)),
            AuswahlKnopf(text: 'Kosten', gewaehlt: _kosten, onTap: () => setState(() => _kosten = !_kosten)),
          ],
        ),
        if (!_staende && !_monate) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Wähle mindestens „Stände“ oder „Verbrauch je Monat“.', style: TextStyle(color: kWarn, fontSize: 13))),
        const SizedBox(height: 16),
        const MonoLabel('// vorschau', color: kTextMuted),
        const SizedBox(height: 6),
        LxCard(
          child: gewaehlt.isEmpty || !wahl.gueltig
              ? const Text('Wähle mindestens einen Zähler und einen gültigen Zeitraum.', style: TextStyle(color: kTextMuted))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final k in gewaehlt) _VorschauZeile(kachel: k, wahl: wahl, heute: heute),
                    const SizedBox(height: 6),
                    const Text('A4, heller Druckstil, deutsche Formate. Das PDF entsteht auf diesem Gerät und wird nirgends hin gesendet. Zum Drucken öffnest du die gespeicherte Datei in einem PDF-Programm.', style: TextStyle(fontSize: 12, color: kTextMuted)),
                  ],
                ),
        ),
      ],
    );
  }
}

class _VorschauZeile extends StatelessWidget {
  final ZaehlerKachel kachel;
  final BerichtWahl wahl;
  final DateTime heute;
  const _VorschauZeile({required this.kachel, required this.wahl, required this.heute});

  @override
  Widget build(BuildContext context) {
    final z = berichtZeitraumFuer(wahl, kachel.erste.inhalt, heute);
    final v = kachelVerbrauch(kachel, z.start, z.ende);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        container: true,
        label: '${kachel.titel}: ${zeitraumText(z)}, ${v.abgedeckteTage == 0 ? 'keine Stände' : verbrauchAnzeige(v.milli, kachel.einheit)}',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(zaehlerSymbol(kachel.art), size: 16, color: zaehlerFarbe(kachel.art)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kachel.titel, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(zeitraumText(z), style: const TextStyle(fontSize: 12, color: kTextMuted)),
                ],
              ),
            ),
            Text(v.abgedeckteTage == 0 ? 'keine Stände' : verbrauchAnzeige(v.milli, kachel.einheit), style: const TextStyle(fontFamily: kFontMono, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
