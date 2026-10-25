// Termine eines Tages im Monatsraster: Tagesblatt (Bottom-Sheet, mobil) und Tagespanel (Desktop, neben dem Raster). Beide zeigen dieselbe
// Liste (Zeit, Personenfarbe, Titel, Ort und Teilnehmer) und "Termin anlegen"; ein Tipp auf einen Termin öffnet das Detailblatt.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/feiertage.dart';
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/monat_layout.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/lists/members.dart';
import '../../data/muell/muell_state.dart';
import '../../ui/widgets.dart';
import 'calendar_anzeige.dart';
import 'calendar_state.dart';
import '../../data/calendar/termin_farben.dart';
import '../../widgets/benutzer_avatar.dart';
import 'kalender_widgets.dart';
import 'muell_kalender.dart';

/// Inhalt eines Tages: Kopf (Datum, Kalenderwoche), Hinweise (Feiertag, Ferien), Termine, "Termin anlegen".
class TagesInhalt extends ConsumerWidget {
  final DateTime tag;

  /// Tipp auf einen Termin; Tipp auf "Termin anlegen" (für diesen Tag).
  final void Function(Vorkommen v) onTermin;
  final VoidCallback onNeu;

  /// Desktop-Panel: der Knopf steht unter der Liste und heißt "Termin an diesem Tag".
  final bool knopfUnten;
  const TagesInhalt({super.key, required this.tag, required this.onTermin, required this.onNeu, this.knopfUnten = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auswahl = ref.watch(kalenderAuswahlProvider);
    final daten = ref.watch(kalenderDatenProvider);
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = TerminRechte(user?.role ?? Role.child, user?.id);
    final mitglieder = mitgliederFuer(ref, daten);
    final geburtstage = ref.watch(geburtstageAnzeigenProvider);
    final hinweise = ref.watch(tagesHinweiseProvider).fuerTag(tag);
    final liste = nachTagen(gefilterteVorkommen(auswahl, daten, tag, tag.add(const Duration(days: 1)), geburtstage: geburtstage, farbenAus: ref.watch(farbenAusProvider)), tag, tag)[tag] ?? const <Vorkommen>[];
    final heute = heuteTag();
    final kopfLabel = '// ${tag == heute ? 'heute' : DateFormat('E', 'de_DE').format(tag).toLowerCase()} · kw ${kalenderwoche(tag)}';
    final knopf = rechte.darfAnlegen
        ? FilledButton.icon(
            onPressed: onNeu,
            icon: const Icon(Icons.add, size: 18),
            label: Text(knopfUnten ? 'Termin an diesem Tag' : 'Termin'),
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MonoLabel(kopfLabel, color: tag == heute ? kAccent : kTextMuted),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('EEEE, d. MMMM', 'de_DE').format(tag),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: kTextStrong),
                    ),
                  ],
                ),
              ),
            ),
            if (knopf != null && !knopfUnten) ...[const SizedBox(width: 12), knopf],
          ],
        ),
        const SizedBox(height: 14),
        TagesHinweisZeile(hinweise: hinweise),
        MuellTagesZeile(arten: ref.watch(muellKalenderTageProvider)[tag] ?? const []),
        if (liste.isEmpty)
          const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('Keine Termine – frei!', style: TextStyle(color: kTextMuted)))
        else
          for (final v in liste) TagesTerminZeile(key: ValueKey('${v.termin.id}|${v.schluessel}'), v: v, tag: tag, mitglieder: mitglieder, teilnehmer: daten.teilnehmerIds(v.termin.id), onTap: () => onTermin(v)),
        if (knopf != null && knopfUnten) ...[const SizedBox(height: 4), knopf],
      ],
    );
  }
}

/// Eine Zeile der Tagesliste: Zeit, Farbstreifen der Person, Titel und Einzelheiten. Mindestens 56 px hoch.
class TagesTerminZeile extends StatelessWidget {
  final Vorkommen v;
  final DateTime tag;
  final Mitglieder mitglieder;
  final Set<String> teilnehmer;
  final VoidCallback onTap;
  const TagesTerminZeile({super.key, required this.v, required this.tag, required this.mitglieder, required this.teilnehmer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final namen = [for (final id in teilnehmer) ?mitglieder[id]?.displayName.split(RegExp(r'\s+')).first];
    final info = [
      if (v.ort.isNotEmpty) v.ort,
      if (namen.isNotEmpty) namen.take(4).join(', ') + (namen.length > 4 ? ' +${namen.length - 4}' : ''),
      if (v.serie) 'wiederkehrend',
    ].join(' · ');
    final zeitBreite = MediaQuery.textScalerOf(context).scale(64);
    final farbName = istGeburtstag(v.termin) ? null : terminFarbeName(v.termin.farbe);
    final ersteller = farbName == null ? null : mitglieder[v.termin.ownerId];
    return Semantics(
      button: true,
      label: '${vorkommenTitel(v)}, ${datumZeitText(v)}${v.ort.isEmpty ? '' : ', ${v.ort}'}${farbName == null ? '' : ', $farbName'}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: zeitBreite,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(startZeitText(v, tag), maxLines: 2, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kText, height: 1.4)),
                    ),
                  ),
                  Container(width: 6, margin: const EdgeInsets.only(right: 12), decoration: BoxDecoration(color: terminFarbe(v, mitglieder), borderRadius: BorderRadius.circular(3))),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(vorkommenTitel(v), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        if (info.isNotEmpty) Text(info, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: kTextMuted)),
                      ],
                    ),
                  ),
                  // mit Termin-Farbe bleibt die Person als kleiner Avatar sichtbar
                  if (ersteller != null) Padding(padding: const EdgeInsets.only(left: 8), child: Align(alignment: Alignment.center, child: BenutzerAvatar(user: ersteller, size: 24))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tagesblatt (mobil): Bottom-Sheet mit den Terminen eines Tages. Ein Tipp auf einen Termin oder "Termin" schließt das Blatt und führt die
/// Aktion im aufrufenden Kontext aus (Detailblatt bzw. Editor).
Future<void> tagesBlattOeffnen(BuildContext context, DateTime tag, {required void Function(Vorkommen v) onTermin, required VoidCallback onNeu}) => showModalBottomSheet<void>(
  useRootNavigator: false,
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (ctx) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: TagesInhalt(
        tag: tag,
        onTermin: (v) {
          Navigator.of(ctx).pop();
          onTermin(v);
        },
        onNeu: () {
          Navigator.of(ctx).pop();
          onNeu();
        },
      ),
    ),
  ),
);
