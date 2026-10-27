// Bereich "Vorsorge" (Abschnitt 6p): Vorsorge und Impfungen für dich und deine Kinder. Je Person drei Karten (Fällig oder überfällig, Bald, Später oder erledigt), "Erledigt eintragen" mit einem Tipp,
// Vorlagen hinzufügen und eigene Einträge. Mobil eine Seite (Blatt "Mehr"), Desktop ein Bereich der Shell. Es steht nur, was diese Person ohnehin sehen darf (ihre eigenen Daten und die ihrer
// Kinder, nie die eines anderen Erwachsenen); nichts davon verlässt die App unverschlüsselt (kein Push-Inhalt, kein Wandtablet, keine Suche, kein Tagesbriefing).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show UserDto;
import '../../data/vorsorge/vorsorge_logik.dart';
import '../../data/vorsorge/vorsorge_modelle.dart';
import '../../data/vorsorge/vorsorge_state.dart';
import '../../data/vorsorge/vorsorge_vorlagen.dart' show kVorsorgeHinweis;
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';
import '../calendar/kalender_widgets.dart' show PersonKapsel;
import '../shell/desktop_shell.dart' show DesktopShellMarke;
import '../shell/shell_tab.dart';
import 'vorsorge_anzeige.dart';
import 'vorsorge_detail_screen.dart';
import 'vorsorge_dialoge.dart';

/// Gewählte Person ("ich" = null).
class VorsorgePerson extends Notifier<String?> {
  @override
  String? build() => null;

  void waehlen(String? id) => state = id;
}

final vorsorgePersonProvider = NotifierProvider<VorsorgePerson, String?>(VorsorgePerson.new);

/// Öffnet den Bereich als eigene Seite (mobil); im Desktop-Layout ist er ein Bereich der Shell (siehe [vorsorgeOeffnen]).
Route<void> vorsorgeRoute() => MaterialPageRoute<void>(builder: (_) => const VorsorgeScreen());

/// Öffnet den Bereich: im Desktop-Layout als Bereich der Shell (Seitenleiste und Fußzeile bleiben), sonst als eigene Seite.
void vorsorgeOeffnen(BuildContext context) {
  if (DesktopShellMarke.vorhanden(context)) {
    ProviderScope.containerOf(context).read(shellTabProvider.notifier).waehlen(kVorsorgeTab);
    return;
  }
  unawaited(Navigator.of(context).push<void>(vorsorgeRoute()));
}

String _vorname(UserDto u) {
  final n = u.displayName.split(RegExp(r'\s+')).first;
  return n.isEmpty ? 'Kind' : n;
}

class VorsorgeScreen extends ConsumerWidget {
  /// Im Desktop-Layout ein Bereich der Shell (Seitenleiste und Fußzeile bleiben): ohne eigenes Gerüst, ohne Zurück-Pfeil, mit der gemeinsamen Kopfzeile.
  final bool eingebettet;
  const VorsorgeScreen({super.key, this.eingebettet = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daten = ref.watch(vorsorgeAnsichtProvider);
    final gewaehlt = ref.watch(vorsorgePersonProvider);
    // eine Person, die es (nicht mehr) gibt oder die man nicht sehen darf, gilt nicht: dann die eigene
    final person = (gewaehlt != null ? daten.person(gewaehlt) : null) ?? (daten.personen.isEmpty ? null : daten.personen.first);
    final kinder = <Widget>[
      if (daten.hatKinder) ...[_Auswahl(daten: daten, aktiv: person?.id), const SizedBox(height: 14)],
      ..._inhalt(context, ref, daten, person),
      const SizedBox(height: 18),
      const Text(kVorsorgeHinweis, style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.4)),
    ];
    final neu = FilledButton.icon(
      onPressed: person == null ? null : () => unawaited(vorsorgeHinzufuegenOeffnen(context, ref, subjektId: person.id, personName: _anrede(daten, person))),
      icon: const Icon(Icons.add),
      label: const Text('Hinzufügen'),
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    );
    if (!eingebettet) {
      return AuthSeite(label: kopfzeilenDatum(), titel: 'Vorsorge', maxBreite: kMaxContentWidth, fussleiste: neu, kinder: kinder);
    }
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TabKopfzeile(title: 'Vorsorge'),
                  const SizedBox(height: 16),
                  ...kinder,
                  const SizedBox(height: 16),
                  Align(alignment: Alignment.centerLeft, child: neu),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _anrede(VorsorgeDaten d, UserDto p) => p.id.toLowerCase() == d.ich?.toLowerCase() ? 'dich' : _vorname(p);

  List<Widget> _inhalt(BuildContext context, WidgetRef ref, VorsorgeDaten daten, UserDto? person) {
    if (!daten.geladen || person == null) return const [Padding(padding: EdgeInsets.only(top: 32), child: Center(child: CircularProgressIndicator()))];
    final eigene = person.id.toLowerCase() == daten.ich?.toLowerCase();
    final profil = daten.profilVon(person.id);
    final unlesbar = daten.profilUnlesbar(person.id);
    final eintraege = daten.von(person.id);
    final heute = vorsorgeHeute();
    final karten = vorsorgeKarten(eintraege, geburt: profil?.geburtTag, geschlecht: profil?.geschlecht, heute: heute);
    final nicht = [for (final e in eintraege) if (e.inhalt == null) e];
    final name = eigene ? 'dich' : _vorname(person);
    return [
      _ProfilZeile(person: person, eigene: eigene, profil: profil, unlesbar: unlesbar, name: name),
      const SizedBox(height: 14),
      if (eintraege.isEmpty)
        EmptyState(
          icon: Icons.vaccines_outlined,
          title: 'Noch nichts eingetragen',
          hint: eigene
              ? 'Wähle Vorlagen für Impfungen und Vorsorge oder lege eigene Einträge an, dann erinnert dich die App rechtzeitig. Alles ist Ende-zu-Ende verschlüsselt.'
              : 'Wähle Vorlagen für Impfungen und Vorsorge von ${_vorname(person)} oder lege eigene Einträge an, dann erinnert dich die App rechtzeitig. Alles ist Ende-zu-Ende verschlüsselt.',
          knopf: 'Hinzufügen',
          onKnopf: () => unawaited(vorsorgeHinzufuegenOeffnen(context, ref, subjektId: person.id, personName: name)),
        ),
      if (karten.faellig.isNotEmpty) _Karte(titel: 'Fällig oder überfällig', posten: karten.faellig, heute: heute, hervor: true),
      if (karten.bald.isNotEmpty) _Karte(titel: 'Bald', posten: karten.bald, heute: heute),
      if (karten.spaeterOderErledigt.isNotEmpty) _Karte(titel: 'Später oder erledigt', posten: karten.spaeterOderErledigt, heute: heute),
      if (karten.hinweise.isNotEmpty) _Karte(titel: 'Nur ein Hinweis', posten: karten.hinweise, heute: heute),
      for (final e in nicht)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: LxCard(
            child: Row(
              children: [
                const Icon(Icons.lock_outline, size: 18, color: kTextMuted),
                const SizedBox(width: 10),
                Expanded(child: Text('Ein Eintrag lässt sich gerade nicht lesen (${e.hinweis ?? 'wird entschlüsselt'}).', style: const TextStyle(color: kTextMuted, fontSize: 13))),
              ],
            ),
          ),
        ),
    ];
  }
}

class _Auswahl extends ConsumerWidget {
  final VorsorgeDaten daten;
  final String? aktiv;
  const _Auswahl({required this.daten, required this.aktiv});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final u in daten.personen)
        PersonKapsel(
          u: u,
          gewaehlt: aktiv != null && aktiv!.toLowerCase() == u.id.toLowerCase(),
          beschriftung: u.id.toLowerCase() == daten.ich?.toLowerCase() ? 'Meine Vorsorge' : 'Vorsorge von ${u.displayName}',
          onTap: () => ref.read(vorsorgePersonProvider.notifier).waehlen(u.id),
        ),
    ],
  );
}

class _ProfilZeile extends ConsumerWidget {
  final UserDto person;
  final bool eigene;
  final VorsorgeProfilInhalt? profil;
  final bool unlesbar;
  final String name;
  const _ProfilZeile({required this.person, required this.eigene, required this.profil, required this.unlesbar, required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final geburt = profil?.geburtTag;
    final text = unlesbar
        ? 'Das Profil lässt sich gerade nicht lesen.'
        : geburt == null
        ? 'Noch kein Geburtsdatum. Ohne kann die App nichts ausrechnen.'
        : 'Geboren am ${vorsorgeDatum(geburt)}';
    final knopf = geburt == null ? 'Eintragen' : 'Ändern';
    return LxCard(
      child: Row(
        children: [
          const Icon(Icons.cake_outlined, size: 20, color: kTextMuted),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: kTextMuted))),
          if (!unlesbar)
            TextButton(
              onPressed: () => unawaited(vorsorgeProfilOeffnen(context, subjektId: person.id, personName: name, bisher: profil)),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(knopf),
            ),
        ],
      ),
    );
  }
}

class _Karte extends ConsumerWidget {
  final String titel;
  final List<VorsorgePosten> posten;
  final DateTime heute;
  final bool hervor;
  const _Karte({required this.titel, required this.posten, required this.heute, this.hervor = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoLabel('$titel · ${posten.length}', color: hervor ? kWarn : kTextMuted),
        const SizedBox(height: 6),
        for (final p in posten) _Zeile(posten: p, heute: heute),
      ],
    ),
  );
}

class _Zeile extends ConsumerWidget {
  final VorsorgePosten posten;
  final DateTime heute;
  const _Zeile({required this.posten, required this.heute});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = posten.eintrag;
    final i = a.inhalt!;
    final f = posten.faelligkeit;
    final name = vorsorgeName(posten.vorlage, i);
    final stand = vorsorgeStandText(f, heute);
    final zusatz = vorsorgeVerlaessigkeitText(posten.vorlage);
    final erledigtMoeglich = f.status != VorsorgeStatus.erledigt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        container: true,
        button: true,
        label: '$name. $stand.${zusatz == null ? '' : ' $zusatz'} Details öffnen',
        excludeSemantics: true,
        onTap: () => unawaited(vorsorgeDetailOeffnen(context, a.id)),
        child: Material(
          color: kSurface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => unawaited(vorsorgeDetailOeffnen(context, a.id)),
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Icon(vorsorgeStatusSymbol(f.status), size: 22, color: f.offen ? kWarn : kTextMuted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(stand, style: const TextStyle(fontSize: 12, color: kTextMuted)),
                        if (zusatz != null) Text(zusatz, style: const TextStyle(fontSize: 11, color: kTextMuted)),
                      ],
                    ),
                  ),
                  if (erledigtMoeglich)
                    IconButton(
                      tooltip: 'Erledigt eintragen: $name',
                      icon: const Icon(Icons.check_circle_outline),
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: () => unawaited(vorsorgeErledigtOeffnen(context, id: a.id)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
