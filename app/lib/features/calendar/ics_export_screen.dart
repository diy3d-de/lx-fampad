// ICS-Export: Zeitraum wählen, Anzahl der Termine sehen, Datei speichern. Der Export entsteht lokal aus der Datenbank des Geräts und geht nie an
// den Server; es werden nur Termine geschrieben (keine Teilnehmer, kein Chat, kein Standort).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart' show Termin;
import '../../data/calendar/ics_export.dart';
import '../../data/calendar/ics_speichern.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/calendar/zeitzonen.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;

Future<void> icsExportOeffnen(BuildContext context) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const IcsExportScreen()));

class IcsExportScreen extends ConsumerStatefulWidget {
  /// Nur für Tests: feste Uhr.
  final DateTime Function()? jetzt;
  const IcsExportScreen({super.key, this.jetzt});

  @override
  ConsumerState<IcsExportScreen> createState() => _IcsExportScreenState();
}

class _IcsExportScreenState extends ConsumerState<IcsExportScreen> {
  var _zeitraum = IcsZeitraum.alles;
  late int _jahr;
  var _laeuft = false;
  String? _meldung;
  var _fehler = false;

  DateTime _jetzt() => (widget.jetzt ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _jahr = wandUhr(_jetzt().toUtc(), familienOrt).year;
  }

  List<Termin> _auswahl(KalenderDaten daten) =>
      termineFuerExport(termine: daten.termine, ausnahmen: daten.ausnahmen, zeitraum: _zeitraum, jahr: _jahr, jetzt: _jetzt());

  Future<void> _exportieren(KalenderDaten daten) async {
    setState(() {
      _laeuft = true;
      _meldung = null;
    });
    try {
      if (!zeitzonenBereit() && !await zeitzonenNeuLaden()) throw const ZeitzonenFehlen();
      final jetzt = _jetzt();
      final termine = _auswahl(daten);
      final text = icsErstellen(termine: termine, ausnahmen: daten.ausnahmen, jetzt: jetzt);
      final gespeichert = await ref.read(icsSpeichernProvider)(icsExportDateiname(jetzt), icsBytes(text));
      if (!mounted) return;
      setState(() {
        _fehler = false;
        _meldung = gespeichert ? (termine.length == 1 ? '1 Termin gespeichert.' : '${termine.length} Termine gespeichert.') : null;
      });
    } on ZeitzonenFehlen {
      if (mounted) {
        setState(() {
          _fehler = true;
          _meldung = 'Die Zeitzonen-Daten konnten nicht geladen werden. Bitte versuche es gleich noch einmal.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _fehler = true;
          _meldung = 'Die Datei konnte nicht gespeichert werden.';
        });
      }
    } finally {
      if (mounted) setState(() => _laeuft = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(kalenderDatenProvider);
    final n = _auswahl(daten).length;
    final hoch = ButtonStyle(minimumSize: const WidgetStatePropertyAll(Size(64, 48)), tapTargetSize: MaterialTapTargetSize.padded);
    return AuthSeite(
      label: '// export',
      titel: 'Kalender exportieren',
      maxBreite: kMaxContentWidth,
      fussleiste: FilledButton.icon(
        style: hoch,
        onPressed: _laeuft || n == 0 ? null : () => _exportieren(daten),
        icon: const Icon(Icons.download),
        label: Text(n == 1 ? '1 Termin exportieren' : '$n Termine exportieren'),
      ),
      kinder: [
        if (_meldung != null) ...[MeldungsBox(_meldung!, fehler: _fehler), const SizedBox(height: 12)],
        const Text(
          'Speichere die Termine, die du siehst, als ICS-Datei (für Google, Apple, Outlook und andere). '
          'Enthalten sind Titel, Ort, Beschreibung, Zeiten, Wiederholungen, Ausnahmen und Erinnerung. Chat, Standort und Teilnehmer bleiben außen vor. '
          'Die Datei entsteht auf diesem Gerät und wird nirgends hochgeladen.',
          style: TextStyle(color: kTextMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        const MonoLabel('// zeitraum'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AuswahlKnopf(text: 'Alles', gewaehlt: _zeitraum == IcsZeitraum.alles, onTap: () => setState(() => _zeitraum = IcsZeitraum.alles)),
            AuswahlKnopf(text: 'Ab heute', gewaehlt: _zeitraum == IcsZeitraum.abHeute, onTap: () => setState(() => _zeitraum = IcsZeitraum.abHeute)),
            AuswahlKnopf(text: 'Ein Jahr', gewaehlt: _zeitraum == IcsZeitraum.jahr, onTap: () => setState(() => _zeitraum = IcsZeitraum.jahr)),
          ],
        ),
        if (_zeitraum == IcsZeitraum.jahr) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Vorheriges Jahr',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => setState(() => _jahr--),
                icon: const Icon(Icons.chevron_left),
              ),
              Semantics(
                liveRegion: true,
                child: Text(
                  '$_jahr',
                  style: const TextStyle(fontFamily: kFontMono, fontSize: 18, color: kTextStrong),
                ),
              ),
              IconButton(
                tooltip: 'Nächstes Jahr',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => setState(() => _jahr++),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(
            n == 0 ? 'Keine Termine im Zeitraum.' : (n == 1 ? '1 Termin wird exportiert.' : '$n Termine werden exportiert.'),
            style: const TextStyle(color: kTextStrong, fontFamily: kFontMono),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Eine Serie kommt immer ganz in die Datei, auch wenn nur ein Teil davon im Zeitraum liegt.',
          style: TextStyle(color: kTextFaint, fontSize: 12),
        ),
      ],
    );
  }
}
