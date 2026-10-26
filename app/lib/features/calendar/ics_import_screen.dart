// ICS-Import: Datei wählen, Vorschau (neu / schon vorhanden / geändert / übersprungen, Hinweise), Freigabe und Zuordnung wählen, importieren,
// Bericht. Alles läuft lokal (offline-first); der Abgleich mit dem Server folgt im Hintergrund. Es werden keine Teilnehmer, Anhänge oder
// Links aus der Datei übernommen und nichts aus dem Netz geladen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/ics_datei.dart';
import '../../data/app_database.dart' show Termin;
import '../../data/calendar/ics_import.dart';
import '../../data/calendar/ics_parser.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/calendar/zeitzonen.dart';
import '../../data/lists/members.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'kalender_widgets.dart' show PersonKapsel;

Future<void> icsImportOeffnen(BuildContext context) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const IcsImportScreen()));

/// Mindesthöhe 48 px für Knöpfe (Touch-Ziele mindestens 44 px, auch bei Textskala 1.5).
final _hoch = ButtonStyle(minimumSize: const WidgetStatePropertyAll(Size(64, 48)), tapTargetSize: MaterialTapTargetSize.padded);

enum _Phase { wahl, liest, vorschau, laeuft, fertig }

class IcsImportScreen extends ConsumerStatefulWidget {
  const IcsImportScreen({super.key});

  @override
  ConsumerState<IcsImportScreen> createState() => _IcsImportScreenState();
}

class _IcsImportScreenState extends ConsumerState<IcsImportScreen> {
  var _phase = _Phase.wahl;
  String? _fehler;
  String _dateiname = '';
  IcsPlan? _plan;
  var _sicht = TerminSicht.family;
  String? _person;
  var _aktualisieren = false;
  var _erledigt = 0;
  double? _lesefortschritt;
  var _gesamt = 0;
  IcsBericht? _bericht;
  final _abbruch = IcsAbbruch();

  @override
  void dispose() {
    _abbruch.angefordert = true;
    super.dispose();
  }

  Future<void> _waehlen() async {
    setState(() => _fehler = null);
    final IcsDatei? datei;
    try {
      datei = await ref.read(icsDateiWaehlerProvider)();
    } catch (_) {
      if (mounted) setState(() => _fehler = 'Die Dateiauswahl konnte nicht geöffnet werden.');
      return;
    }
    if (datei == null || !mounted) return;
    if ((datei.laenge ?? 0) > kIcsMaxBytes) {
      setState(() {
        _fehler = 'Die Datei ist größer als 5 MB.';
        _plan = null; // eine frühere Vorschau gehört nicht zu dieser Datei
        _phase = _Phase.wahl;
      });
      return;
    }
    setState(() {
      _phase = _Phase.liest;
      _dateiname = datei!.name;
    });
    try {
      final bytes = await leseBegrenzt(datei.bytes);
      if (!zeitzonenBereit() && !await zeitzonenNeuLaden()) throw const IcsFehler('Die Zeitzonen-Daten konnten nicht geladen werden. Bitte versuche es gleich noch einmal.');
      final ergebnis = await ref.read(icsLeserProvider)(bytes, (p) {
        if (mounted) setState(() => _lesefortschritt = p);
      });
      if (!mounted) return;
      final daten = ref.read(kalenderDatenProvider);
      final user = ref.read(authProvider).user;
      final plan = icsPlanen(ergebnis, bestehende: daten.termine, ausnahmen: daten.ausnahmen, rechte: TerminRechte(user?.role ?? Role.child, user?.id));
      setState(() {
        _plan = plan;
        _phase = _Phase.vorschau;
      });
    } on IcsFehler catch (e) {
      if (mounted) {
        setState(() {
          _fehler = e.meldung;
          _plan = null;
          _phase = _Phase.wahl;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _fehler = 'Die Datei konnte nicht gelesen werden.';
          _plan = null;
          _phase = _Phase.wahl;
        });
      }
    }
  }

  Future<void> _importieren() async {
    final plan = _plan;
    if (plan == null) return;
    setState(() {
      _phase = _Phase.laeuft;
      _erledigt = 0;
      _gesamt = plan.neu + (_aktualisieren ? plan.geaendert : 0);
    });
    final bericht = await ref.read(icsImporterProvider).importieren(
      plan,
      sicht: _sicht,
      rechte: TerminRechte(ref.read(authProvider).user?.role ?? Role.child, ref.read(authProvider).user?.id),
      teilnehmer: {?_person},
      aktualisieren: _aktualisieren,
      abbruch: _abbruch,
      fortschritt: (e, g) {
        if (mounted) setState(() => _erledigt = e);
      },
    );
    if (!mounted) return;
    setState(() {
      _bericht = bericht;
      _phase = _Phase.fertig;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(kalenderDatenProvider); // hält die lokalen Termine für den Abgleich der UIDs bereit
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = TerminRechte(user?.role ?? Role.child, user?.id);
    final plan = _plan;
    return PopScope(
      canPop: _phase != _Phase.laeuft,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _phase != _Phase.laeuft) return;
        final nav = Navigator.of(context);
        final abbrechen = await showDialog<bool>(useRootNavigator: false,
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import abbrechen?'),
            content: const Text('Bereits importierte Termine bleiben erhalten, der Rest wird nicht mehr importiert.'),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Weiter importieren')),
              TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Abbrechen')),
            ],
          ),
        );
        if (abbrechen ?? false) {
          // der Import hält an und zeigt den Teilbericht
          setState(() => _abbruch.angefordert = true);
        } else if (!mounted) {
          nav.maybePop();
        }
      },
      child: _seite(rechte, plan),
    );
  }

  Widget _seite(TerminRechte rechte, IcsPlan? plan) {
    Widget? fuss;
    switch (_phase) {
      case _Phase.vorschau:
        final n = plan == null ? 0 : plan.neu + (_aktualisieren ? plan.geaendert : 0);
        fuss = FilledButton(style: _hoch, onPressed: n > 0 ? _importieren : null, child: Text(n == 1 ? '1 Termin importieren' : '$n Termine importieren'));
      case _Phase.laeuft:
        fuss = OutlinedButton(style: _hoch, onPressed: () => setState(() => _abbruch.angefordert = true), child: const Text('Abbrechen'));
      case _Phase.fertig:
        fuss = FilledButton(style: _hoch, onPressed: () => Navigator.of(context).maybePop(), child: const Text('Fertig'));
      case _Phase.wahl || _Phase.liest:
        fuss = null;
    }
    return AuthSeite(
      label: 'Import',
      titel: 'Kalender importieren',
      maxBreite: kMaxContentWidth,
      fussleiste: fuss,
      kinder: [
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
        switch (_phase) {
          _Phase.wahl => _wahl(rechte),
          _Phase.liest => _lade('Datei „$_dateiname“ wird gelesen …'),
          _Phase.vorschau => _vorschau(plan!, rechte),
          _Phase.laeuft => _lauf(),
          _Phase.fertig => _fertig(_bericht!),
        },
      ],
    );
  }

  Widget _wahl(TerminRechte rechte) {
    if (!rechte.darfAnlegen) {
      return const MeldungsBox('Mit deiner Rolle kannst du keine Termine anlegen und deshalb auch nichts importieren.', fehler: false);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Übernimm deinen bisherigen Kalender aus einer ICS-Datei (Export aus Google, Apple, Outlook und anderen). '
          'Übernommen werden Termine mit Ort, Beschreibung, Wiederholungen und Erinnerung. Teilnehmer, Anhänge und Links bleiben außen vor. '
          'Ein erneuter Import legt keine Termine doppelt an. Importiere dieselbe Datei aber nicht gleichzeitig auf zwei Geräten: bis alles übertragen ist, würden Termine doppelt entstehen.',
          style: TextStyle(color: kTextMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _waehlen, icon: const Icon(Icons.upload_file), label: const Text('ICS-Datei auswählen')),
        const SizedBox(height: 8),
        const Text('Höchstens 5 MB und 5000 Termine.', style: TextStyle(color: kTextMuted, fontSize: 12)),
      ],
    );
  }

  Widget _lade(String text) => Semantics(
    liveRegion: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: _lesefortschritt, color: kAccent, semanticsLabel: 'Datei wird gelesen'),
        const SizedBox(height: 12),
        Text(text, style: const TextStyle(color: kTextMuted)),
      ],
    ),
  );

  Widget _lauf() => Semantics(
    liveRegion: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: _gesamt == 0 ? null : _erledigt / _gesamt, color: kAccent, semanticsLabel: 'Import läuft'),
        const SizedBox(height: 12),
        Text('$_erledigt von $_gesamt Terminen', style: const TextStyle(color: kTextMuted, fontFamily: kFontSans, fontFeatures: kZiffern)),
      ],
    ),
  );

  static String _wann(IcsTermin t) {
    if (t.ganztaegig) {
      final d = DateTime.tryParse('${t.startDate}T00:00:00Z');
      return d == null ? '' : DateFormat('E, d. MMM y', 'de_DE').format(d);
    }
    final w = wandUhr(t.startUtc!, familienOrt);
    return '${DateFormat('E, d. MMM y', 'de_DE').format(w)}, ${DateFormat('HH:mm').format(w)} Uhr';
  }

  /// Zusatz "(angelegt von X)", wenn der vorhandene Termin jemand anderem gehört.
  String _fremd(Termin? t, List<UserDto> mitglieder) {
    final besitzer = t?.ownerId;
    if (besitzer == null || besitzer == ref.read(authProvider).user?.id) return '';
    final name = mitglieder.where((u) => u.id == besitzer).map((u) => u.displayName).firstOrNull ?? 'jemand anderem';
    return ' (angelegt von $name)';
  }

  static String _wannVorhanden(Termin? t) {
    if (t == null) return '';
    if (t.ganztaegig) {
      final d = DateTime.tryParse('${t.startDate}T00:00:00Z');
      return d == null ? '' : DateFormat('d. MMM y', 'de_DE').format(d);
    }
    if (t.startUtc == null) return '';
    return DateFormat('d. MMM y, HH:mm', 'de_DE').format(wandUhr(t.startUtc!, familienOrt));
  }

  Widget _zahl(String zahl, String text, Color farbe) => Container(
    constraints: const BoxConstraints(minHeight: 44),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: farbe.withValues(alpha: 0.5))),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(zahl, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontWeight: FontWeight.w700, color: farbe)),
        const SizedBox(width: 8),
        Flexible(child: Text(text, style: const TextStyle(color: kText))),
      ],
    ),
  );

  Widget _vorschau(IcsPlan plan, TerminRechte rechte) {
    final mitglieder = ref.watch(mitgliederProvider).value ?? const <UserDto>[];
    final vorschau = plan.eintraege.take(25).toList();
    final warnungen = plan.hinweise;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoLabel(_dateiname, color: kTextMuted),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _zahl('${plan.neu}', 'neu', kTerminal),
            _zahl('${plan.vorhanden}', 'schon vorhanden', kTextMuted),
            if (plan.geaendert > 0) _zahl('${plan.geaendert}', 'geändert', kAccent),
            if (plan.uebersprungen > 0) _zahl('${plan.uebersprungen}', 'übersprungen', kWarn),
          ],
        ),
        if (plan.eintraege.isEmpty && warnungen.isEmpty) ...[
          const SizedBox(height: 12),
          const MeldungsBox('In der Datei wurden keine Termine gefunden.', fehler: false),
        ],
        if (vorschau.isNotEmpty) ...[
          const SizedBox(height: 16),
          const MonoLabel('Termine'),
          const SizedBox(height: 6),
          for (final e in vorschau) _Zeile(eintrag: e, wann: _wann(e.termin)),
          if (plan.eintraege.length > vorschau.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('… und ${plan.eintraege.length - vorschau.length} weitere', style: const TextStyle(color: kTextMuted, fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12)),
            ),
        ],
        if (warnungen.isNotEmpty) ...[
          const SizedBox(height: 16),
          const MonoLabel('Hinweise', color: kWarn),
          const SizedBox(height: 6),
          LxCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final h in warnungen.take(12))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(h.uebersprungen ? Icons.block : Icons.info_outline, size: 16, color: kWarn),
                        const SizedBox(width: 8),
                        Expanded(child: Text(h.titel == null ? h.text : '${h.titel}: ${h.text}', style: const TextStyle(fontSize: 13, color: kText))),
                      ],
                    ),
                  ),
                if (warnungen.length > 12) Text('… und ${warnungen.length - 12} weitere Hinweise', style: const TextStyle(color: kTextMuted, fontSize: 12)),
              ],
            ),
          ),
        ],
        if (plan.neu + plan.geaendert > 0) ...[
          const SizedBox(height: 16),
          if (plan.neu > 0 && rechte.darfFreigabeAendern) ...[
            const MonoLabel('Wer sieht das?'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final s in rechte.freigaben) AuswahlKnopf(text: s.label, gewaehlt: s == _sicht, onTap: () => setState(() => _sicht = s))],
            ),
            const SizedBox(height: 12),
          ],
          if (plan.neu > 0 && mitglieder.isNotEmpty) ...[
            const MonoLabel('Zugeordnet zu'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AuswahlKnopf(text: 'Niemand', gewaehlt: _person == null, onTap: () => setState(() => _person = null)),
                for (final u in mitglieder)
                  PersonKapsel(u: u, gewaehlt: _person == u.id, beschriftung: 'Zuordnen zu ${u.displayName}', onTap: () => setState(() => _person = _person == u.id ? null : u.id)),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (plan.geaendert > 0)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Vorhandene Termine aktualisieren'),
              subtitle: const Text('Überschreibt Änderungen, die du in der App an diesen Terminen gemacht hast.', style: TextStyle(color: kTextMuted, fontSize: 12)),
              value: _aktualisieren,
              onChanged: (v) => setState(() => _aktualisieren = v),
            ),
          if (plan.geaendert > 0 && _aktualisieren) ...[
            const SizedBox(height: 4),
            const MonoLabel('Wird überschrieben', color: kWarn),
            const SizedBox(height: 6),
            LxCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in plan.eintraege.where((e) => e.status == IcsStatus.geaendert).take(15))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        '${e.vorhanden?.titel ?? e.termin.titel}, ${_wannVorhanden(e.vorhanden)}${_fremd(e.vorhanden, mitglieder)}',
                        style: const TextStyle(fontSize: 13, color: kText),
                      ),
                    ),
                  if (plan.geaendert > 15) Text('… und ${plan.geaendert - 15} weitere', style: const TextStyle(color: kTextMuted, fontSize: 12)),
                ],
              ),
            ),
          ],
        ],
        const SizedBox(height: 8),
        TextButton.icon(style: _hoch, onPressed: _waehlen, icon: const Icon(Icons.swap_horiz), label: const Text('Andere Datei wählen')),
      ],
    );
  }

  Widget _fertig(IcsBericht b) {
    Widget zeile(String zahl, String text, Color farbe) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 56, child: Text(zahl, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontWeight: FontWeight.w700, fontSize: 18, color: farbe))),
          Expanded(child: Text(text, style: const TextStyle(color: kText))),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeldungsBox(b.abgebrochen ? 'Der Import wurde abgebrochen.' : 'Der Import ist fertig. Die Termine werden im Hintergrund mit dem Server abgeglichen.', fehler: false),
        const SizedBox(height: 12),
        zeile('${b.neu}', 'importiert', kTerminal),
        if (b.aktualisiert > 0) zeile('${b.aktualisiert}', 'aktualisiert', kAccent),
        zeile('${b.vorhanden}', 'schon vorhanden', kTextMuted),
        zeile('${b.uebersprungen.length}', 'übersprungen', kWarn),
        if (b.uebersprungen.isNotEmpty) ...[
          const SizedBox(height: 8),
          const MonoLabel('Übersprungen', color: kWarn),
          const SizedBox(height: 6),
          LxCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final h in b.uebersprungen.take(50))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(h.titel == null ? h.text : '${h.titel}: ${h.text}', style: const TextStyle(fontSize: 13, color: kText)),
                  ),
                if (b.uebersprungen.length > 50) Text('… und ${b.uebersprungen.length - 50} weitere', style: const TextStyle(color: kTextMuted, fontSize: 12)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Zeile extends StatelessWidget {
  final IcsPlanEintrag eintrag;
  final String wann;
  const _Zeile({required this.eintrag, required this.wann});

  @override
  Widget build(BuildContext context) {
    final t = eintrag.termin;
    final (text, farbe) = switch (eintrag.status) {
      IcsStatus.neu => ('neu', kTerminal),
      IcsStatus.vorhanden => ('vorhanden', kTextMuted),
      IcsStatus.geaendert => ('geändert', kAccent),
      IcsStatus.uebersprungen => ('übersprungen', kWarn),
    };
    return Semantics(
      label: '${t.titel}, $wann, $text${t.serie ? ', Serie' : ''}',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kBorderSoft))),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.titel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kTextStrong, fontWeight: FontWeight.w600)),
                  Text(wann, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kTextMuted, fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12)),
                ],
              ),
            ),
            if (t.serie) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.repeat, size: 16, color: kTextMuted)),
            const SizedBox(width: 8),
            StatusPill(text, color: farbe),
          ],
        ),
      ),
    );
  }
}
