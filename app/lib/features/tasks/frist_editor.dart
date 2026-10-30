// Frist anlegen, ansehen und bearbeiten: Titel, Ablaufdatum, Wiederholung (in Monaten), Vorwarnzeit (Tage), Zuständige. Eine Frist ist eine
// Aufgabe mit `frist = true` (siehe data/tasks/fristen_logik.dart); Vorlagen belegen den Editor nur vor, alles bleibt änderbar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/lists/members.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../../data/tasks/fristen_logik.dart';
import '../../ui/widgets.dart';
import '../../widgets/ungespeichert_schutz.dart';
import '../../widgets/liste_detail.dart' show detailOeffnen;
import '../auth/auth_widgets.dart';
import '../calendar/kalender_widgets.dart' show PersonKapsel;
import '../lists/list_dialogs.dart' show AuswahlKnopf, bestaetigen;
import 'fristen_anzeige.dart';

/// Öffnet den Frist-Editor. [frist] null = neue Frist.
Future<void> fristEditorOeffnen(BuildContext context, {Aufgabe? frist}) => detailOeffnen(context, (_) => FristEditor(frist: frist), id: frist?.id);

class FristEditor extends ConsumerStatefulWidget {
  final Aufgabe? frist;
  const FristEditor({super.key, this.frist});

  @override
  ConsumerState<FristEditor> createState() => _FristEditorState();
}

class _FristEditorState extends ConsumerState<FristEditor> {
  final _titel = TextEditingController();
  final _notiz = TextEditingController();
  DateTime? _tag; // Ablaufdatum (Tag, UTC-Markierung)
  int? _monate = 12; // Wiederholung in Monaten, null = einmalig
  var _vorwarn = kFristVorwarnStandard; // Tage
  String? _zustaendig;
  var _sicht = AufgabeSicht.family;
  List<AufgabePunkt> _punkte = const [];
  String? _fehler;
  var _speichert = false;

  bool get _neu => widget.frist == null;

  String? _ausgang;
  String _stand() => [_titel.text, _notiz.text, _tag, _monate, _vorwarn, _zustaendig, _sicht].join('|');

  @override
  void initState() {
    super.initState();
    final a = widget.frist;
    if (a == null) return;
    _titel.text = a.titel;
    _notiz.text = a.beschreibung;
    _tag = fristTag(a);
    _monate = a.fristMonate;
    _vorwarn = fristVorwarnTageOderStandard(a);
    _zustaendig = a.assigneeId;
    _sicht = AufgabeSicht.von(a.audience);
    _punkte = sortierePunkte(ref.read(aufgabenDatenProvider).punkteVon(a.id));
  }

  @override
  void dispose() {
    _titel.dispose();
    _notiz.dispose();
    super.dispose();
  }

  void _vorlage(FristVorlage v) => setState(() {
    _titel.text = v.titel;
    _monate = v.monate;
    _vorwarn = v.vorwarnTage;
  });

  void _fehlerSetzen(String text) {
    if (mounted) {
      setState(() {
        _speichert = false;
        _fehler = text;
      });
    }
  }

  Future<void> _speichern() async {
    if (_speichert) return;
    if (_titel.text.trim().isEmpty) {
      setState(() => _fehler = 'Gib der Frist einen Titel.');
      return;
    }
    final tag = _tag;
    if (tag == null) {
      setState(() => _fehler = 'Wähle das Ablaufdatum.');
      return;
    }
    final repo = ref.read(aufgabeRepositoryProvider);
    final nav = Navigator.of(context);
    setState(() => _speichert = true);
    try {
      final alt = widget.frist;
      final e = AufgabeEingabe(
        titel: _titel.text.trim(),
        beschreibung: _notiz.text,
        faellig: tag,
        zustaendig: _zustaendig,
        sicht: _sicht,
        erinnerungMin: fristVorwarnMin(_vorwarn),
        frist: true,
        fristMonate: _monate,
        prioritaet: alt == null ? AufgabePrio.keine : AufgabePrio.von(alt.prioritaet),
        punkte: [for (final p in _punkte) PunktEingabe(id: p.id, text: p.inhalt, erledigt: p.doneAt != null)],
      );
      if (alt == null) {
        await repo.anlegen(e);
      } else {
        await repo.speichern(alt, e, bisherigePunkte: _punkte);
      }
    } on ApiException catch (e) {
      _fehlerSetzen(e.message);
      return;
    } catch (_) {
      _fehlerSetzen('Die Frist konnte nicht gespeichert werden.');
      return;
    }
    if (mounted) nav.pop();
  }

  Future<void> _loeschen() async {
    final a = widget.frist;
    if (a == null) return;
    final repo = ref.read(aufgabeRepositoryProvider);
    final nav = Navigator.of(context);
    final ja = await bestaetigen(context, titel: 'Frist „${a.titel}“ löschen?', text: 'Die Frist wird für alle gelöscht.', knopf: 'Löschen');
    if (!ja) return;
    await repo.loeschen(a.id);
    if (mounted) nav.pop();
  }

  Future<void> _datumWaehlen() async {
    final start = _tag ?? tagVon(DateTime.now());
    final d = await showDatePicker(
      useRootNavigator: false,
      context: context,
      initialDate: DateTime(start.year, start.month, start.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2199, 12, 30),
      locale: const Locale('de', 'DE'),
    );
    if (d != null) setState(() => _tag = DateTime.utc(d.year, d.month, d.day));
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = AufgabeRechte(user?.role ?? Role.child, user?.id);
    _ausgang ??= _stand();
    final darf = _neu ? rechte.darfAnlegen : rechte.darfAendern(widget.frist!);
    final mitglieder = ref.watch(mitgliederProvider).value ?? const <UserDto>[];
    final tag = _tag;
    void nichts() {}
    final vorwarnWerte = {...kFristVorwarnTage, _vorwarn}.toList()..sort();
    final wdhWerte = {...kFristWiederholungen, _monate}.toList()..sort((a, b) => (a ?? 0).compareTo(b ?? 0));
    final wer = _zustaendig == null
        ? 'ohne Zuständige nur die Person, die die Frist angelegt hat (bei einer Wiederholung die, die sie erledigt).'
        : (_zustaendig == user?.id ? 'auf deinem Gerät.' : 'nur die zuständige Person, nicht dich.');

    return UngespeichertSchutz(
      geaendert: () => _stand() != _ausgang,
      aenderungen: Listenable.merge([_titel, _notiz]),
      child: AuthSeite(
        label: 'Frist',
        titel: _neu ? 'Neue Frist' : (darf ? 'Frist bearbeiten' : 'Frist'),
        maxBreite: kMaxContentWidth,
        fussleiste: darf ? FilledButton(onPressed: _speichert ? null : _speichern, child: Text(_neu ? 'Frist anlegen' : 'Speichern')) : null,
        kinder: [
          if (!darf) ...[const MeldungsBox('Du darfst diese Frist ansehen, aber nicht ändern.', fehler: false), const SizedBox(height: 12)],
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
          if (_neu) ...[
            const MonoLabel('Vorlage'),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final v in kFristVorlagen) AuswahlKnopf(text: v.titel, gewaehlt: false, onTap: () => _vorlage(v))]),
            const SizedBox(height: 4),
            const Text('Eine Vorlage füllt nur Titel, Wiederholung und Vorwarnzeit vor. Du kannst alles ändern.', style: TextStyle(fontSize: 12, color: kTextMuted)),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _titel,
            enabled: darf,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Titel', counterText: ''),
          ),
          const SizedBox(height: 16),
          const MonoLabel('Läuft ab am'),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              enabled: darf,
              label: 'Ablaufdatum, ${tag == null ? 'nicht gewählt' : fristDatumTextFuer(tag)}',
              excludeSemantics: true,
              onTap: darf ? _datumWaehlen : null,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: darf ? _datumWaehlen : null,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48, maxWidth: 280),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.event, size: 18, color: kTextMuted),
                      const SizedBox(width: 8),
                      Flexible(child: Text(tag == null ? 'Datum wählen' : fristDatumTextFuer(tag), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const MonoLabel('Wie oft?'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final m in wdhWerte) AuswahlKnopf(text: fristWiederholungText(m), gewaehlt: _monate == m, onTap: darf ? () => setState(() => _monate = m) : nichts)],
          ),
          if (_monate != null) ...[
            const SizedBox(height: 6),
            const Text('Sobald du die Frist erledigst, entsteht die nächste.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
          const SizedBox(height: 16),
          const MonoLabel('Wann erinnern?'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final t in vorwarnWerte) AuswahlKnopf(text: fristVorwarnText(t), gewaehlt: _vorwarn == t, onTap: darf ? () => setState(() => _vorwarn = t) : nichts)],
          ),
          const SizedBox(height: 6),
          Text('Erinnert um 09:00 Uhr, $wer', style: const TextStyle(fontSize: 12, color: kTextMuted)),
          const SizedBox(height: 16),
          if (mitglieder.isNotEmpty) ...[
            const MonoLabel('Wer macht das?'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AuswahlKnopf(text: 'Niemand', gewaehlt: _zustaendig == null, onTap: darf ? () => setState(() => _zustaendig = null) : nichts),
                for (final u in mitglieder)
                  PersonKapsel(u: u, gewaehlt: _zustaendig == u.id, beschriftung: 'Zuständig ${u.displayName}', onTap: darf ? () => setState(() => _zustaendig = u.id) : nichts),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (_zustaendig != null && _sicht == AufgabeSicht.parents && mitglieder.any((u) => u.id == _zustaendig && u.role == Role.child)) ...[
            const Text('Achtung: Die Frist ist nur für Eltern sichtbar, die zuständige Person ist ein Kind und sieht sie deshalb nicht.', style: TextStyle(fontSize: 12, color: kWarn)),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _notiz,
            enabled: darf,
            maxLength: 4000,
            minLines: 2,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Notiz (z. B. Vertragsnummer)', counterText: '', alignLabelWithHint: true),
          ),
          const SizedBox(height: 12),
          if (darf && rechte.darfFreigabeAendern) ...[
            const MonoLabel('Wer sieht das?'),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final s in rechte.freigaben) AuswahlKnopf(text: s.label, gewaehlt: s == _sicht, onTap: () => setState(() => _sicht = s))]),
            const SizedBox(height: 12),
          ],
          if (!_neu && darf)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: kDanger, minimumSize: const Size(44, 48)),
                onPressed: _loeschen,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Frist löschen'),
              ),
            ),
        ],
      ),
    );
  }
}
