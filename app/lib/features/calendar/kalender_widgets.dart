// Bausteine des Kalenders: Karte eines Vorkommens, Personenfilter, Ansichtswechsel, Wahl "nur dieses / dieses und folgende / alle" und das
// Detailblatt eines Termins.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/feiertage.dart';
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/wiederholung.dart';
import '../../data/calendar/zeitzonen.dart';
import '../../data/lists/members.dart';
import '../../ui/widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'countdown_karte.dart' show CountdownSchalter;
import 'calendar_state.dart';
import '../../widgets/benutzer_avatar.dart';

/// Karte eines Vorkommens: farbiger Balken (Personenfarbe des Erstellers), Titel, Zeit, Ort, Teilnehmer. Mindestens 56 px hoch.
class VorkommenKarte extends StatelessWidget {
  final Vorkommen v;
  final DateTime tag;
  final Mitglieder mitglieder;
  final Set<String> teilnehmer;
  final VoidCallback onTap;
  const VorkommenKarte({super.key, required this.v, required this.tag, required this.mitglieder, required this.teilnehmer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final farbe = terminFarbe(v, mitglieder);
    final zeit = zeitText(v, tag);
    final personen = [for (final id in teilnehmer) ?mitglieder[id]];
    return Semantics(
      button: true,
      label: '${vorkommenTitel(v)}, ${datumZeitText(v)}${v.ort.isEmpty ? '' : ', ${v.ort}'}',
      excludeSemantics: true,
      child: LxCard(
        padding: EdgeInsets.zero,
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: farbe),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 36),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(vorkommenTitel(v), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                            ),
                            if (istGeburtstag(v.termin)) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.cake_outlined, size: 16, color: kGeburtstag)) else if (v.serie) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.repeat, size: 14, color: kTextMuted)),
                            if (v.geaendert) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.edit_outlined, size: 14, color: kTextMuted)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(zeit, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
                        if (v.ort.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
                              children: [
                                const Icon(Icons.place_outlined, size: 13, color: kTextFaint),
                                const SizedBox(width: 4),
                                Expanded(child: Text(v.ort, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: kTextMuted))),
                              ],
                            ),
                          ),
                        if (personen.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                for (final u in personen.take(4)) BenutzerAvatar(user: u, size: 22),
                                if (personen.length > 4) Text('+${personen.length - 4}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Filter je Person: "Alle" und eine Auswahl-Kapsel je Mitglied in seiner Farbe.
class PersonenFilter extends StatelessWidget {
  final List<UserDto> personen;
  final Set<String> gewaehlt;
  final void Function(String id) onPerson;
  final VoidCallback onAlle;
  const PersonenFilter({super.key, required this.personen, required this.gewaehlt, required this.onPerson, required this.onAlle});

  @override
  Widget build(BuildContext context) {
    if (personen.length < 2) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        AuswahlKnopf(text: 'Alle', gewaehlt: gewaehlt.isEmpty, onTap: onAlle),
        for (final u in personen) PersonKapsel(u: u, gewaehlt: gewaehlt.contains(u.id), onTap: () => onPerson(u.id)),
      ],
    );
  }
}

class PersonKapsel extends StatelessWidget {
  final UserDto u;
  final bool gewaehlt;
  final VoidCallback onTap;
  final String? beschriftung;
  const PersonKapsel({super.key, required this.u, required this.gewaehlt, required this.onTap, this.beschriftung});

  @override
  Widget build(BuildContext context) {
    final farbe = personColor(u.colorIndex);
    return Semantics(
      button: true,
      selected: gewaehlt,
      label: beschriftung ?? 'Termine von ${u.displayName}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: gewaehlt ? farbe.withValues(alpha: 0.16) : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: gewaehlt ? farbe : kBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: farbe)),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(u.displayName.split(RegExp(r'\s+')).first, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: gewaehlt ? kText : kTextMuted)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wie weit eine Änderung an einer Serie gilt.
enum SerieUmfang {
  dieses('Nur dieses Vorkommen'),
  folgende('Dieses und alle folgenden'),
  alle('Alle Vorkommen');

  final String label;
  const SerieUmfang(this.label);
}

/// Fragt bei einem Serientermin, wie weit die Aktion gilt. Null = abgebrochen. Beim ersten Vorkommen entfällt "dieses und folgende".
Future<SerieUmfang?> serieUmfangFragen(BuildContext context, {required String titel, required bool erstes}) => showModalBottomSheet<SerieUmfang>(useRootNavigator: false,
  context: context,
  isScrollControlled: true,
  builder: (ctx) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const MonoLabel('// serie'),
          const SizedBox(height: 4),
          Text(titel, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: kTextStrong)),
          const SizedBox(height: 12),
          for (final u in SerieUmfang.values)
            if (!(erstes && u == SerieUmfang.folgende))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(onPressed: () => Navigator.of(ctx).pop(u), child: Align(alignment: Alignment.centerLeft, child: Text(u.label))),
              ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Abbrechen')),
        ],
      ),
    ),
  ),
);

/// Aktion im Detailblatt.
enum TerminAktion { bearbeiten, loeschen }

/// Detailblatt eines Vorkommens: alle Angaben, Bearbeiten und Löschen (nur wer darf).
Future<TerminAktion?> terminDetailBlatt(
  BuildContext context, {
  required Vorkommen v,
  required Mitglieder mitglieder,
  required Set<String> teilnehmer,
  required bool darfAendern,
}) => showModalBottomSheet<TerminAktion>(useRootNavigator: false,
  context: context,
  isScrollControlled: true,
  builder: (ctx) {
    final t = v.termin;
    final farbe = terminFarbe(v, mitglieder);
    final ersteller = mitglieder[t.ownerId];
    final wdh = t.rrule == null ? null : Wiederholung.ausRrule(t.rrule, ganztaegig: t.ganztaegig, ort: ortFuer(t.tzid));
    final personen = [for (final id in teilnehmer) ?mitglieder[id]];
    Widget zeile(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Icon(icon, size: 18, color: kTextMuted), const SizedBox(width: 12), Expanded(child: Text(text))],
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(width: 4, height: 18, color: farbe),
                const SizedBox(width: 8),
                MonoLabel(istGeburtstag(t) ? '// geburtstag' : (v.geaendert ? '// termin · geändert' : '// termin'), color: farbe),
              ],
            ),
            const SizedBox(height: 6),
            Text(vorkommenTitel(v), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: kTextStrong)),
            const SizedBox(height: 14),
            zeile(Icons.schedule, datumZeitText(v)),
            if (v.ort.isNotEmpty) zeile(Icons.place_outlined, v.ort),
            if (wdh != null && wdh.wiederholt) zeile(Icons.repeat, wdh.beschreibung()),
            if (t.erinnerungMin != null) zeile(Icons.notifications_none, erinnerungText(t.erinnerungMin)),
            if (t.beschreibung.isNotEmpty) zeile(Icons.notes, t.beschreibung),
            if (personen.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Icon(Icons.group_outlined, size: 18, color: kTextMuted),
                    for (final u in personen)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [BenutzerAvatar(user: u, size: 24), const SizedBox(width: 6), Text(u.displayName)],
                      ),
                  ],
                ),
              ),
            if (ersteller != null) zeile(Icons.person_outline, 'Angelegt von ${ersteller.displayName}'),
            CountdownSchalter(terminId: t.id),
            const SizedBox(height: 8),
            if (darfAendern) ...[
              FilledButton.icon(onPressed: () => Navigator.of(ctx).pop(TerminAktion.bearbeiten), icon: const Icon(Icons.edit_outlined), label: const Text('Bearbeiten')),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(ctx).pop(TerminAktion.loeschen),
                icon: const Icon(Icons.delete_outline, color: kDanger),
                label: const Text('Löschen', style: TextStyle(color: kDanger)),
              ),
            ] else
              const Text('Du darfst diesen Termin nicht ändern.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
        ),
      ),
    );
  },
);

/// Dezente Hinweise eines Tages (Feiertag, Schulferien): kleine Kapseln in Mono-Schrift, nicht antippbar, nicht editierbar.
/// In der Agenda nennen Ferien das Ende ([mitEnde]), in Monat und Woche stehen sie an jedem Tag.
class TagesHinweisZeile extends StatelessWidget {
  final List<TagesHinweis> hinweise;
  final bool mitEnde;
  const TagesHinweisZeile({super.key, required this.hinweise, this.mitEnde = false});

  @override
  Widget build(BuildContext context) {
    if (hinweise.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final h in hinweise)
            () {
              final farbe = h.art == TagesHinweisArt.feiertag ? kFeiertag : kFerien;
              final ende = mitEnde && h.art == TagesHinweisArt.ferien ? ' · bis ${DateFormat('d. MMM', 'de_DE').format(h.bis)}' : '';
              final text = '${h.name}$ende';
              return Semantics(
                label: '${h.art == TagesHinweisArt.feiertag ? 'Feiertag' : 'Schulferien'}: $text',
                excludeSemantics: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: farbe.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8), border: Border.all(color: farbe.withValues(alpha: 0.35))),
                  child: Text(text, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: farbe)),
                ),
              );
            }(),
        ],
      ),
    );
  }
}
