import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/feiertage.dart';
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/monat_layout.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/calendar/woche_layout.dart';
import '../../data/lists/members.dart';
import '../../data/muell/muell_state.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../../widgets/sync_hinweise.dart';
import '../lists/list_dialogs.dart' show bestaetigen;
import '../shell/shell_tab.dart';
import 'calendar_state.dart';
import 'kalender_leiste.dart';
import 'kalender_monat.dart';
import 'kalender_tag.dart';
import 'kalender_woche.dart';
import 'kalender_widgets.dart';
import 'muell_kalender.dart';
import 'termin_editor.dart';

/// Erst wenn die Liste um mehr als die Kopfzeile plus Reserve scrollbar ist, klappt die Kopfzeile ein (sonst würde sie bei knapp überlangem
/// Inhalt hin- und herspringen: Einklappen verlängert den sichtbaren Bereich und der Inhalt passt plötzlich ganz hinein).
const _kEinklappenAb = 200.0;

/// Die gemeinsame Kopfzeile, einklappbar; baut als einziges Teil bei einem Wechsel neu.
class _KopfBereich extends ConsumerWidget {
  final bool breit;
  const _KopfBereich({required this.breit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eingeklappt = !breit && ref.watch(kalenderKopfEingeklapptProvider);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: eingeklappt
          ? const SizedBox(width: double.infinity)
          : const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: TabKopfzeile(title: 'Kalender'),
            ),
    );
  }
}

/// Kalender: Monat (Standard; die zuletzt gewählte Ansicht merkt sich das Gerät), Agenda und Woche, Filter je Person, Termine anlegen, ändern und löschen (auch Serien). Alles wirkt sofort
/// auf die lokale Datenbank; der Abgleich mit dem Server läuft im Hintergrund (data/sync/).
/// Aufbau: (einklappende) Kopfzeile, Hinweise des Abgleichs (nur bei Bedarf), schlanke Leiste mit Umschalter, darunter die Ansicht; mobil dazu
/// der runde Knopf "Neuer Termin", im Desktop-Layout steht er in der Leiste. Das Monatsraster füllt den Rest des Bildschirms.
class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auswahl = ref.watch(kalenderAuswahlProvider);
    // Erst die gemerkte Ansicht lesen (wenige Millisekunden), dann zeichnen: kein Sprung von der Standardansicht auf die gemerkte
    if (!auswahl.geladen) return const SizedBox.shrink();
    final daten = ref.watch(kalenderDatenProvider);
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = TerminRechte(user?.role ?? Role.child, user?.id);
    // Mitglieder (Farben, Filter) erst laden, wenn es Termine gibt
    final personen = daten.termine.isEmpty ? const <UserDto>[] : (ref.watch(mitgliederProvider).value ?? const <UserDto>[]);
    final mitglieder = Mitglieder(personen);
    final breit = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;
    final kopf = ref.read(kalenderKopfEingeklapptProvider.notifier);
    // Der eingeklappte Zustand gilt nur im Kalender-Tab: beim Verlassen kommt die Kopfzeile zurück
    ref.listen(shellTabProvider, (_, tab) {
      if (tab != kKalenderTab) kopf.setzen(false);
    });
    final fab = !breit && rechte.darfAnlegen;
    final aktuelleAuswahl = auswahl;

    // Nur das Hauptscrollable (Liste bzw. Raster, Tiefe 0) steuert die Kopfzeile; im Desktop-Layout bleibt sie immer sichtbar (Profil und Sync stehen in der Seitenleiste)
    bool beiScroll(ScrollNotification n) {
      if (breit || n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
      if (n is ScrollUpdateNotification) {
        final d = n.scrollDelta ?? 0;
        if (n.metrics.pixels <= 0) {
          kopf.setzen(false); // am Anfang immer wieder einblenden
        } else if (kopf.beruhigt) {
          // Richtungswechsel nur außerhalb der Einklapp-Animation, sonst springt die Kopfzeile
          if (d > 0 && n.metrics.pixels > 24 && n.metrics.maxScrollExtent > _kEinklappenAb) {
            kopf.setzen(true);
          } else if (d < 0) {
            kopf.setzen(false);
          }
        }
      } else if (n is OverscrollNotification && n.overscroll < 0) {
        kopf.setzen(false); // Herunterziehen am Anfang immer
      }
      return false;
    }

    // Die Agenda bleibt auch im breiten Desktop-Bereich schmal und mittig; Monats- und Wochenraster nutzen die ganze Breite
    Widget schmal(Widget liste) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
        child: liste,
      ),
    );
    final ansicht = switch (auswahl.ansicht) {
      KalenderAnsicht.agenda => schmal(_Agenda(auswahl: auswahl, daten: daten, mitglieder: mitglieder, rechte: rechte, platzFuerKnopf: fab)),
      KalenderAnsicht.monat => _Monat(auswahl: auswahl, daten: daten, mitglieder: mitglieder, rechte: rechte, breit: breit, platzFuerKnopf: fab),
      KalenderAnsicht.woche => _Woche(auswahl: auswahl, daten: daten, mitglieder: mitglieder, rechte: rechte, breit: breit, platzFuerKnopf: fab),
    };

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: fab
          ? FloatingActionButton(
              heroTag: null,
              tooltip: 'Neuer Termin',
              backgroundColor: kAccent,
              foregroundColor: kOnAccent,
              onPressed: () => neuerTerminOeffnen(context, aktuelleAuswahl),
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KopfBereich(breit: breit),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: SyncHinweise()),
          Padding(
            padding: breit ? const EdgeInsets.fromLTRB(20, 4, 20, 12) : EdgeInsets.zero,
            child: KalenderLeiste(breit: breit, personen: personen, darfAnlegen: rechte.darfAnlegen, onNeu: () => neuerTerminOeffnen(context, aktuelleAuswahl)),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: beiScroll,
              child: RefreshIndicator(
                color: kAccent,
                backgroundColor: kSurface,
                onRefresh: () => ref.read(syncProvider.notifier).synchronisieren(manuell: true),
                child: ansicht,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Öffnet das Detailblatt eines Vorkommens und führt Bearbeiten/Löschen aus (bei Serien mit Wahl des Umfangs).
Future<void> vorkommenOeffnen(BuildContext context, WidgetRef ref, Vorkommen v, KalenderDaten daten, Mitglieder mitglieder, TerminRechte rechte) async {
  final darf = rechte.darfAendern(v.termin);
  final aktion = await terminDetailBlatt(context, v: v, mitglieder: mitglieder, teilnehmer: daten.teilnehmerIds(v.termin.id), darfAendern: darf);
  if (aktion == null || !context.mounted) return;
  final repo = ref.read(terminRepositoryProvider);
  // Geburtstage mit Marke sind Jahresserien ohne Ausnahmen (importierte Geburtstage können welche haben und behalten die Wahl): Bearbeiten und Löschen gelten immer für den ganzen Termin
  final serie = v.serie && !hatGeburtstagsMarke(v.termin);
  final erstes = serie && repo.istErstes(v);
  switch (aktion) {
    case TerminAktion.bearbeiten:
      var umfang = SerieUmfang.alle;
      if (serie) {
        final u = await serieUmfangFragen(context, titel: 'Was möchtest du ändern?', erstes: erstes);
        if (u == null || !context.mounted) return;
        umfang = u;
      }
      await terminEditorOeffnen(context, v: v, umfang: umfang);
    case TerminAktion.loeschen:
      if (serie) {
        final u = await serieUmfangFragen(context, titel: 'Was möchtest du löschen?', erstes: erstes);
        if (u == null) return;
        switch (u) {
          case SerieUmfang.dieses:
            await repo.vorkommenAbsagen(v);
          case SerieUmfang.folgende:
            await repo.folgendeLoeschen(v);
          case SerieUmfang.alle:
            await repo.alleLoeschen(v.termin.id);
        }
      } else {
        final ja = await bestaetigen(
          context,
          titel: istGeburtstag(v.termin) ? 'Geburtstag „${v.titel}“ löschen?' : 'Termin „${v.titel}“ löschen?',
          text: 'Der Termin wird für alle gelöscht.',
          knopf: 'Löschen',
        );
        if (ja) await repo.alleLoeschen(v.termin.id);
      }
  }
}

Widget _tagesListe(BuildContext context, WidgetRef ref, DateTime tag, List<Vorkommen> liste, KalenderDaten daten, Mitglieder mitglieder, TerminRechte rechte) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final v in liste)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: VorkommenKarte(
              key: ValueKey('${v.termin.id}|${v.schluessel}|${tag.toIso8601String()}'),
              v: v,
              tag: tag,
              mitglieder: mitglieder,
              teilnehmer: daten.teilnehmerIds(v.termin.id),
              onTap: () => vorkommenOeffnen(context, ref, v, daten, mitglieder, rechte),
            ),
          ),
      ],
    );

/// Abstand unter den Listen: Platz für den runden Knopf "Neuer Termin" (mobil).
EdgeInsets _listenRand(bool platzFuerKnopf) => EdgeInsets.fromLTRB(20, 8, 20, platzFuerKnopf ? 96 : 24);

// ------------------------------------------------------------------------------------------------ Agenda

class _Agenda extends ConsumerWidget {
  final KalenderAuswahl auswahl;
  final KalenderDaten daten;
  final Mitglieder mitglieder;
  final TerminRechte rechte;
  final bool platzFuerKnopf;
  const _Agenda({required this.auswahl, required this.daten, required this.mitglieder, required this.rechte, required this.platzFuerKnopf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final heute = heuteTag();
    final bis = heute.add(Duration(days: auswahl.agendaTage));
    final tage = nachTagen(
      gefilterteVorkommen(auswahl, daten, heute, bis, geburtstage: ref.watch(geburtstageAnzeigenProvider), farbenAus: ref.watch(farbenAusProvider)),
      heute,
      bis.subtract(const Duration(days: 1)),
    );
    final hinweise = ref.watch(tagesHinweiseProvider).fuerAgenda(heute, bis.subtract(const Duration(days: 1)));
    // Abfuhrtermine (nur mit eingeschaltetem Schalter): Anzeige wie Feiertage, nie als Termin
    final muell = ref.watch(muellKalenderTageProvider);
    final muellTage = [for (final t in muell.keys) if (!t.isBefore(heute) && t.isBefore(bis)) t];
    final schluessel = {...tage.keys, ...hinweise.keys, ...muellTage}.toList()..sort();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: _listenRand(platzFuerKnopf),
      children: [
        if (schluessel.isEmpty)
          const EmptyState(icon: Icons.event_available_outlined, title: 'Keine Termine', hint: 'In den nächsten Wochen steht nichts an.')
        else
          for (final tag in schluessel) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: MonoLabel(tag == heute ? '${tagesLabel(tag)} · heute' : tagesLabel(tag), color: tag == heute ? kAccent : kTextMuted),
            ),
            TagesHinweisZeile(hinweise: hinweise[tag] ?? const [], mitEnde: true),
            MuellTagesZeile(arten: muell[tag] ?? const []),
            _tagesListe(context, ref, tag, tage[tag] ?? const <Vorkommen>[], daten, mitglieder, rechte),
          ],
        _MehrKnopf(auswahl: auswahl),
      ],
    );
  }
}

class _MehrKnopf extends ConsumerWidget {
  final KalenderAuswahl auswahl;
  const _MehrKnopf({required this.auswahl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (auswahl.agendaTage >= kHorizontJahre * 365) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton(onPressed: ref.read(kalenderAuswahlProvider.notifier).mehrTage, child: const Text('Weitere Tage anzeigen')),
    );
  }
}

// ------------------------------------------------------------------------------------------------ Monat

/// Einträge des Rasters: Termine (Personenfarbe, Geburtstage in Geburtstagsfarbe), dazu Feiertage und Ferien als Balken.
List<BalkenQuelle> _quellen(
  List<Vorkommen> liste,
  TagesHinweise hinweise,
  DateTime von,
  DateTime bisInklusive,
  Mitglieder mitglieder, {
  required bool mitZeit,
}) {
  final out = <BalkenQuelle>[];
  for (final v in liste) {
    final titel = vorkommenTitel(v);
    final einTag = v.ersterTag == v.letzterTag;
    out.add(
      BalkenQuelle(
        id: '${v.termin.id}|${v.schluessel}',
        text: mitZeit && einTag && !v.ganztaegig ? '$titel ${uhrzeitText(v.startWand)}' : titel,
        farbe: terminFarbe(v, mitglieder),
        art: BalkenArt.termin,
        von: v.ersterTag,
        bis: v.letzterTag,
        vorkommen: v,
        sortierung: v.ganztaegig ? '0$titel' : '1${uhrzeitText(v.startWand)}$titel',
      ),
    );
  }
  final gesehen = <TagesHinweis>{};
  for (var t = von; !t.isAfter(bisInklusive); t = DateTime.utc(t.year, t.month, t.day + 1)) {
    for (final h in hinweise.fuerTag(t)) {
      if (!gesehen.add(h)) continue;
      out.add(
        BalkenQuelle(
          id: '${h.art.name}|${h.name}|${h.von.toIso8601String()}',
          text: h.name,
          farbe: h.art == TagesHinweisArt.feiertag ? kFeiertag : kFerien,
          art: h.art == TagesHinweisArt.feiertag ? BalkenArt.feiertag : BalkenArt.ferien,
          von: h.von,
          bis: h.bis,
        ),
      );
    }
  }
  return out;
}

class _Monat extends ConsumerWidget {
  final KalenderAuswahl auswahl;
  final KalenderDaten daten;
  final Mitglieder mitglieder;
  final TerminRechte rechte;
  final bool breit;
  final bool platzFuerKnopf;
  const _Monat({required this.auswahl, required this.daten, required this.mitglieder, required this.rechte, required this.breit, required this.platzFuerKnopf});

  /// Ab dieser Breite steht rechts das Tagespanel, sonst öffnet ein Tipp auf einen Tag das Tagesblatt.
  static const _panelAb = 820.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(kalenderAuswahlProvider.notifier);
    final heute = heuteTag();
    final monat = auswahl.monat;
    final wochen = wochenDesMonats(monat);
    final von = wochen.first;
    final bisInklusive = DateTime.utc(wochen.last.year, wochen.last.month, wochen.last.day + 6);
    final liste = gefilterteVorkommen(auswahl, daten, von, bisInklusive.add(const Duration(days: 1)), geburtstage: ref.watch(geburtstageAnzeigenProvider), farbenAus: ref.watch(farbenAusProvider));
    final quellen = _quellen(liste, ref.watch(tagesHinweiseProvider), von, bisInklusive, mitglieder, mitZeit: breit);

    // Aktionen lesen die Daten beim Aufruf frisch (das Tagesblatt kann länger offen sein als dieser Aufbau)
    void terminOeffnen(Vorkommen v) {
      final d = ref.read(kalenderDatenProvider);
      final m = Mitglieder(ref.read(mitgliederProvider).value ?? const <UserDto>[]);
      vorkommenOeffnen(context, ref, v, d, m, rechte);
    }

    return LayoutBuilder(
      builder: (context, c) {
        final panel = breit && c.maxWidth >= _panelAb;
        final raster = MonatsRaster(
          monat: monat,
          heute: heute,
          gewaehlt: auswahl.tag,
          gewaehltMarkieren: panel,
          breit: breit,
          quellen: quellen,
          muell: ref.watch(muellKalenderTageProvider),
          onTag: (tag) {
            notifier.waehleTag(tag);
            if (!breit) ref.read(kalenderKopfEingeklapptProvider.notifier).setzen(true);
            if (!panel) {
              tagesBlattOeffnen(context, tag, onTermin: terminOeffnen, onNeu: () => terminEditorOeffnen(context, tag: tag));
            }
          },
        );
        // mobil bleibt unten Platz für den runden Knopf, damit er die letzte Rasterzeile nicht überdeckt
        if (!panel) return Padding(padding: EdgeInsets.fromLTRB(breit ? 20 : 8, 0, breit ? 20 : 8, platzFuerKnopf ? 72 : 0), child: raster);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: kBgElevated,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: raster,
                ),
              ),
              const SizedBox(width: 20),
              _TagesPanel(tag: auswahl.tag, onTermin: terminOeffnen, onNeu: () => terminEditorOeffnen(context, tag: auswahl.tag)),
            ],
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------------------------------------ Tagespanel

/// Tagespanel (Desktop, rechts neben dem Raster): die Termine des gewählten Tages.
class _TagesPanel extends StatelessWidget {
  final DateTime tag;
  final void Function(Vorkommen v) onTermin;
  final VoidCallback onNeu;
  const _TagesPanel({required this.tag, required this.onTermin, required this.onNeu});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 320,
    child: Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kAccent.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.all(20),
      // der Scroll des Panels darf weder die Kopfzeile noch den Abgleich (Herunterziehen) auslösen
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) => true,
        child: SingleChildScrollView(
          child: TagesInhalt(tag: tag, knopfUnten: true, onTermin: onTermin, onNeu: onNeu),
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------------------------------------ Woche

class _Woche extends ConsumerWidget {
  final KalenderAuswahl auswahl;
  final KalenderDaten daten;
  final Mitglieder mitglieder;
  final TerminRechte rechte;
  final bool breit;
  final bool platzFuerKnopf;
  const _Woche({required this.auswahl, required this.daten, required this.mitglieder, required this.rechte, required this.breit, required this.platzFuerKnopf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(kalenderAuswahlProvider.notifier);
    final jetzt = ref.watch(kalenderJetztProvider);
    final montag = auswahl.tag.subtract(Duration(days: auswahl.tag.weekday - 1));
    final naechster = DateTime.utc(montag.year, montag.month, montag.day + 7);
    final sonntag = DateTime.utc(montag.year, montag.month, montag.day + 6);
    final liste = gefilterteVorkommen(auswahl, daten, montag, naechster, geburtstage: ref.watch(geburtstageAnzeigenProvider), farbenAus: ref.watch(farbenAusProvider));
    final quellen = _quellen(
      [
        for (final v in liste)
          if (gehoertInsBand(v)) v,
      ],
      ref.watch(tagesHinweiseProvider),
      montag,
      sonntag,
      mitglieder,
      mitZeit: false,
    );
    final bloecke = zeitBloecke(montag, liste);

    // Aktionen lesen die Daten beim Aufruf frisch (Blätter können länger offen sein als dieser Aufbau)
    void terminOeffnen(Vorkommen v) {
      final d = ref.read(kalenderDatenProvider);
      final m = Mitglieder(ref.read(mitgliederProvider).value ?? const <UserDto>[]);
      vorkommenOeffnen(context, ref, v, d, m, rechte);
    }

    return LayoutBuilder(
      builder: (context, c) {
        final panel = breit && c.maxWidth >= _Monat._panelAb;
        final raster = WochenRaster(
          montag: montag,
          gewaehlt: auswahl.tag,
          gewaehltMarkieren: panel,
          breit: breit,
          bloecke: bloecke,
          band: quellen,
          muell: ref.watch(muellKalenderTageProvider),
          farbe: (b) => terminFarbe(b.v, mitglieder),
          person: (b) => mitglieder[b.v.termin.ownerId]?.displayName,
          jetzt: jetzt,
          unten: !panel && platzFuerKnopf ? 72 : 0,
          onWoche: (r) => notifier.tag(DateTime.utc(auswahl.tag.year, auswahl.tag.month, auswahl.tag.day + 7 * r)),
          onBlock: (b) => terminOeffnen(b.v),
          onLeer: rechte.darfAnlegen ? (tag, minute) => terminEditorOeffnen(context, tag: tag, startMinute: minute) : null,
          onTag: (tag) {
            notifier.waehleTag(tag);
            if (!panel) {
              tagesBlattOeffnen(context, tag, onTermin: terminOeffnen, onNeu: () => terminEditorOeffnen(context, tag: tag));
            }
          },
        );
        if (!panel) return Padding(padding: EdgeInsets.symmetric(horizontal: breit ? 20 : 8), child: raster);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: kBgElevated,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: raster,
                ),
              ),
              const SizedBox(width: 20),
              _TagesPanel(
                tag: auswahl.tag,
                onTermin: terminOeffnen,
                onNeu: () => terminEditorOeffnen(context, tag: auswahl.tag),
              ),
            ],
          ),
        );
      },
    );
  }
}
