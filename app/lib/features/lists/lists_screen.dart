import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/lists/einkauf_logik.dart';
import '../../data/lists/list_repository.dart';
import '../../data/lists/list_rights.dart';
import '../../data/lists/members.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/sync_hinweise.dart';
import '../../widgets/kopfzeile.dart';
import '../../widgets/liste_detail.dart' show kListeDetailBreite, kListeSpaltenBreite;
import '../../widgets/rueckgaengig.dart';
import 'list_dialogs.dart';
import '../../widgets/benutzer_avatar.dart';

/// Listen (Einkauf, Packliste, eigene Listen): Liste wählen, Einträge anlegen, abhaken, bearbeiten, zuweisen, löschen.
/// Alles wirkt sofort auf die lokale Datenbank; der Abgleich mit dem Server läuft im Hintergrund (data/sync/).
class ListsScreen extends ConsumerStatefulWidget {
  const ListsScreen({super.key});

  @override
  ConsumerState<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends ConsumerState<ListsScreen> {
  final _neu = TextEditingController();
  final _fokus = FocusNode();

  @override
  void dispose() {
    _neu.dispose();
    _fokus.dispose();
    super.dispose();
  }

  ListenRepository get _repo => ref.read(listenRepositoryProvider);

  ListenRechte _rechte() {
    final u = ref.read(authProvider).user;
    return ListenRechte(u?.role ?? Role.child, u?.id);
  }

  Future<void> _listeAnlegen() async {
    final a = await neueListeDialog(context, _rechte());
    if (a == null || !mounted) return;
    final id = await _repo.listeAnlegen(name: a.name, art: a.art, sicht: a.sicht);
    ref.read(gewaehlteListeProvider.notifier).waehlen(id);
  }

  Future<void> _eintragHinzufuegen(Liste liste) async {
    final text = _neu.text.trim();
    if (text.isEmpty) return;
    _neu.clear();
    String? kategorie;
    if (ListenArt.von(liste.kind).mitKategorien) {
      final alle = await ref.read(alleEintraegeProvider.future);
      final k = schlageKategorieVor(text, vorhandene: alle);
      kategorie = k == EinkaufKategorie.sonstiges ? null : k.wire;
    }
    await _repo.eintragAnlegen(liste.id, text, kategorie: kategorie);
    if (mounted) _fokus.requestFocus();
  }

  Future<void> _menue(Liste liste, String aktion) async {
    switch (aktion) {
      case 'umbenennen':
        final n = await textDialog(context, titel: 'Liste umbenennen', label: 'Name der Liste', start: liste.name);
        if (n != null) await _repo.listeUmbenennen(liste.id, n);
      case 'sicht':
        final s = await sichtDialog(context, ListenSicht.von(liste.audience));
        if (s != null) await _repo.listeSicht(liste.id, s);
      case 'vorlage_speichern':
        final n = await textDialog(context, titel: 'Als Vorlage speichern', label: 'Name der Vorlage', start: '${liste.name} (Vorlage)');
        if (n == null || !mounted) return;
        final id = await _repo.alsVorlageSpeichern(liste, name: n);
        if (!mounted) return;
        _hinweis(id == null ? 'Die Liste ist leer, daraus wird keine Vorlage.' : 'Vorlage „$n“ gespeichert.');
      case 'vorlage_nehmen':
        final vorlagen = (ref.read(listenProvider).value ?? const <Liste>[]).where((l) => ListenArt.von(l.kind) == ListenArt.template && l.id != liste.id).toList();
        final wahl = await vorlageBlatt(context, vorlagen: vorlagen);
        if (wahl == null || !mounted) return;
        final neu = await _repo.ausVorlageUebernehmen(liste.id, wahl);
        if (!mounted) return;
        _hinweis(neu == 0 ? 'Alles aus der Vorlage steht schon auf der Liste.' : (neu == 1 ? '1 Eintrag aus der Vorlage übernommen.' : '$neu Einträge aus der Vorlage übernommen.'));
      case 'loeschen':
        final anzahl = (await ref.read(eintraegeProvider(liste.id).future)).length;
        if (!mounted) return;
        final ja = await bestaetigen(
          context,
          titel: 'Liste „${liste.name}“ löschen?',
          text: anzahl == 0
              ? 'Die Liste wird für alle gelöscht.'
              : (anzahl == 1 ? 'Die Liste und ihr Eintrag werden für alle gelöscht.' : 'Die Liste und ihre $anzahl Einträge werden für alle gelöscht.'),
          knopf: 'Löschen',
        );
        if (ja) {
          await _repo.listeLoeschen(liste.id);
          ref.read(gewaehlteListeProvider.notifier).waehlen(null);
        }
    }
  }

  void _hinweis(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _eintragBearbeiten(Listeneintrag e, Liste liste) async {
    final mitKategorie = ListenArt.von(liste.kind).mitKategorien;
    final a = await eintragBlatt(context, text: e.inhalt, mitKategorie: mitKategorie, kategorie: e.category);
    if (a == null) return;
    switch (a) {
      case EintragSpeichern(:final text, :final kategorie):
        if (text != e.inhalt) await _repo.eintragText(e.id, text);
        // "Sonstiges" und kein Wert sind dasselbe: dann nichts schreiben
        if (mitKategorie && EinkaufKategorie.von(kategorie) != EinkaufKategorie.von(e.category)) await _repo.eintragKategorie(e.id, kategorie);
      case EintragLoeschen():
        final repo = _repo; // vor dem Hinweis holen (nach dem Abmelden gibt es den Bildschirm nicht mehr)
        final ich = ref.read(authProvider).user?.id;
        await repo.eintragLoeschen(e.id);
        if (!mounted) return;
        // Rückgängig legt den Eintrag mit neuer ID wieder an (der Server behält den gelöschten als Tombstone)
        rueckgaengigZeigen(context, text: 'Eintrag gelöscht', rueckgaengig: () async => repo.eintragWiederherstellen(e, besitzer: ich));
    }
  }

  Future<void> _zuweisen(Listeneintrag e, List<UserDto> personen) async {
    final wahl = await zuweisenBlatt(context, personen: personen, aktuell: e.assigneeId);
    if (wahl == null) return;
    await _repo.eintragZuweisen(e.id, wahl == keinePerson ? null : wahl);
  }

  @override
  Widget build(BuildContext context) {
    final listenWert = ref.watch(listenProvider);
    final rechte = _rechte();
    ref.watch(authProvider.select((a) => a.user?.id)); // bei Personenwechsel neu bauen
    final gewaehlt = ref.watch(gewaehlteListeProvider);

    final vorhandene = listenWert.value;
    final einspaltig = RefreshIndicator(
      color: kAccent,
      backgroundColor: kSurface,
      onRefresh: () => ref.read(syncProvider.notifier).synchronisieren(manuell: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          const TabKopfzeile(title: 'Listen'),
          const SizedBox(height: 12),
          const SyncHinweise(),
          ...switch (listenWert) {
            AsyncError() when !listenWert.hasValue => const [
              EmptyState(icon: Icons.error_outline, title: 'Listen nicht lesbar', hint: 'Die lokale Datenbank konnte nicht gelesen werden.'),
            ],
            AsyncData(:final value) || AsyncLoading(value: final value?) || AsyncError(value: final value?) => _inhalt(value, gewaehlt, rechte),
            _ => const [LadePlatzhalter(karten: 2)],
          },
        ],
      ),
    );
    if (vorhandene == null || vorhandene.isEmpty) return einspaltig;
    // Zweispalter wie bei den Aufgaben: links die Listen, rechts die gewählte Liste (schmaler: Reiter über der Liste, wie bisher)
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < kListeDetailBreite) return einspaltig;
        final liste = vorhandene.firstWhere((l) => l.id == gewaehlt, orElse: () => vorhandene.first);
        final mitglieder = Mitglieder(ref.watch(mitgliederProvider).value ?? const []);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: kListeSpaltenBreite,
              child: RefreshIndicator(
                color: kAccent,
                backgroundColor: kSurface,
                onRefresh: () => ref.read(syncProvider.notifier).synchronisieren(manuell: true),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  children: [
                    const TabKopfzeile(title: 'Listen'),
                    const SizedBox(height: 12),
                    const SyncHinweise(),
                    _ListenSpalte(listen: vorhandene, aktiv: liste.id, onWahl: (id) => ref.read(gewaehlteListeProvider.notifier).waehlen(id), onNeu: rechte.darfListeAnlegen ? _listeAnlegen : null),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1, color: kBorderSoft),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 20, 24),
                children: [_ansicht(liste, rechte, mitglieder)],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _ansicht(Liste liste, ListenRechte rechte, Mitglieder mitglieder) => _ListeAnsicht(
    key: ValueKey(liste.id),
    liste: liste,
    rechte: rechte,
    mitglieder: mitglieder,
    eingabe: _neu,
    fokus: _fokus,
    onHinzu: () => _eintragHinzufuegen(liste),
    onMenue: (a) => _menue(liste, a),
    onBearbeiten: (e) => _eintragBearbeiten(e, liste),
    onZuweisen: (e) => _zuweisen(e, mitglieder.alle),
  );

  List<Widget> _inhalt(List<Liste> listen, String? gewaehlt, ListenRechte rechte) {
    if (listen.isEmpty) {
      return [
        const SizedBox(height: 24),
        EmptyState(
          icon: Icons.checklist_outlined,
          title: 'Noch keine Liste',
          hint: 'Lege eine Liste an, z. B. für den Einkauf oder die Packliste.',
          knopf: rechte.darfListeAnlegen ? 'Liste anlegen' : null,
          onKnopf: rechte.darfListeAnlegen ? _listeAnlegen : null,
        ),
      ];
    }
    final liste = listen.firstWhere((l) => l.id == gewaehlt, orElse: () => listen.first);
    // Mitglieder (Name, Farbe der Zuständigen) erst laden, wenn es eine Liste gibt
    final mitglieder = Mitglieder(ref.watch(mitgliederProvider).value ?? const []);
    return [
      _Reiter(listen: listen, aktiv: liste.id, onWahl: (id) => ref.read(gewaehlteListeProvider.notifier).waehlen(id), onNeu: rechte.darfListeAnlegen ? _listeAnlegen : null),
      const SizedBox(height: 16),
      _ansicht(liste, rechte, mitglieder),
    ];
  }
}

// ------------------------------------------------------------------------------------------------ Teile

/// Die Listen als Spalte (Zweispalter im Desktop-Layout): Name und Zahl offener Einträge, die gewählte als hellere Fläche (Fläche und Text, nicht nur Farbe).
class _ListenSpalte extends ConsumerWidget {
  final List<Liste> listen;
  final String aktiv;
  final void Function(String id) onWahl;
  final VoidCallback? onNeu;
  const _ListenSpalte({required this.listen, required this.aktiv, required this.onWahl, required this.onNeu});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alle = ref.watch(alleEintraegeProvider).value ?? const <Listeneintrag>[];
    int offen(String id) => alle.where((e) => e.listId == id && e.doneAt == null).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in listen)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Semantics(
              button: true,
              selected: l.id == aktiv,
              label: '${l.name}, ${offen(l.id)} offen',
              excludeSemantics: true,
              child: Material(
                color: l.id == aktiv ? kSurface2 : kSurface,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  key: ValueKey('liste:${l.id}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onWahl(l.id),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: l.id == aktiv ? FontWeight.w700 : FontWeight.w500, color: l.id == aktiv ? kTextStrong : kText)),
                                Text('${ListenArt.von(l.kind).label} · ${offen(l.id)} offen', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                              ],
                            ),
                          ),
                          if (l.id == aktiv) const Icon(Icons.chevron_right, color: kAccent),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (onNeu != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(style: TextButton.styleFrom(minimumSize: const Size(44, 44)), onPressed: onNeu, icon: const Icon(Icons.add), label: const Text('Neue Liste')),
          ),
      ],
    );
  }
}

/// Reiter der Listen (waagerecht scrollbar) und der Knopf "Neue Liste".
class _Reiter extends StatelessWidget {
  final List<Liste> listen;
  final String aktiv;
  final void Function(String id) onWahl;
  final VoidCallback? onNeu;
  const _Reiter({required this.listen, required this.aktiv, required this.onWahl, required this.onNeu});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final l in listen)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _Reiter1(text: l.name, aktiv: l.id == aktiv, onTap: () => onWahl(l.id)),
                  ),
              ],
            ),
          ),
        ),
        if (onNeu != null)
          IconButton(tooltip: 'Neue Liste', icon: const Icon(Icons.add, color: kAccent), onPressed: onNeu),
      ],
    ),
  );
}

class _Reiter1 extends StatelessWidget {
  final String text;
  final bool aktiv;
  final VoidCallback onTap;
  const _Reiter1({required this.text, required this.aktiv, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: aktiv,
    label: text,
    excludeSemantics: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 64, maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: aktiv ? kAccentSoft : null,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: aktiv ? kAccent.withValues(alpha: 0.4) : Colors.transparent),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, fontWeight: aktiv ? FontWeight.w600 : FontWeight.w400, color: aktiv ? kAccent : kTextMuted),
        ),
      ),
    ),
  );
}

class _ListeAnsicht extends ConsumerWidget {
  final Liste liste;
  final ListenRechte rechte;
  final Mitglieder mitglieder;
  final TextEditingController eingabe;
  final FocusNode fokus;
  final VoidCallback onHinzu;
  final void Function(String aktion) onMenue;
  final void Function(Listeneintrag) onBearbeiten;
  final void Function(Listeneintrag) onZuweisen;
  const _ListeAnsicht({
    super.key,
    required this.liste,
    required this.rechte,
    required this.mitglieder,
    required this.eingabe,
    required this.fokus,
    required this.onHinzu,
    required this.onMenue,
    required this.onBearbeiten,
    required this.onZuweisen,
  });

  String get _hinweisText => switch (ListenArt.von(liste.kind)) {
    ListenArt.shopping => 'Was fehlt?',
    ListenArt.packing => 'Was muss mit?',
    ListenArt.custom => 'Neuer Eintrag',
    ListenArt.template => 'Was gehört dazu?',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eintraegeWert = ref.watch(eintraegeProvider(liste.id));
    final eintraege = eintraegeWert.value ?? const <Listeneintrag>[];
    final lesefehler = eintraegeWert.hasError && !eintraegeWert.hasValue; // sonst sähe ein Lesefehler wie eine leere Liste aus
    final sortiert = sortiereEintraege(eintraege);
    final erledigt = eintraege.where((e) => e.doneAt != null).length;
    final gesamt = eintraege.length;
    final art = ListenArt.von(liste.kind);
    final menue = rechte.darfListeAendern(liste);
    final gruppiert = art.mitKategorien;
    Widget zeile(Listeneintrag e) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _Zeile(
        key: ValueKey('eintrag-${e.id}'),
        eintrag: e,
        rechte: rechte,
        person: mitglieder[e.assigneeId],
        onHaken: () => ref.read(listenRepositoryProvider).eintragErledigt(e.id, e.doneAt == null),
        onBearbeiten: () => onBearbeiten(e),
        onZuweisen: () => onZuweisen(e),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(liste.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: kTextStrong)),
                  const SizedBox(height: 2),
                  Text(
                    '${ListenArt.von(liste.kind).label} · ${ListenSicht.von(liste.audience).label}',
                    style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
                  ),
                ],
              ),
            ),
            if (menue)
              PopupMenuButton<String>(
                tooltip: 'Liste verwalten',
                color: kSurface,
                icon: const Icon(Icons.more_vert),
                onSelected: onMenue,
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'umbenennen', height: 48, child: Text('Umbenennen')),
                  if (art == ListenArt.shopping) const PopupMenuItem(value: 'vorlage_nehmen', height: 48, child: Text('Aus Vorlage übernehmen')),
                  if (art == ListenArt.shopping) const PopupMenuItem(value: 'vorlage_speichern', height: 48, child: Text('Als Vorlage speichern')),
                  if (rechte.darfFreigabeAendern) const PopupMenuItem(value: 'sicht', height: 48, child: Text('Wer sieht das? …')),
                  const PopupMenuItem(value: 'loeschen', height: 48, child: Text('Liste löschen', style: TextStyle(color: kDanger))),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        Semantics(
          label: 'Fortschritt: $erledigt von $gesamt erledigt',
          excludeSemantics: true,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: gesamt == 0 ? 0 : erledigt / gesamt, minHeight: 6, color: kTerminal, backgroundColor: kBorder),
          ),
        ),
        const SizedBox(height: 6),
        Text(gesamt == 0 ? '' : '$erledigt von $gesamt erledigt', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
        if (rechte.darfEintraegeAendern) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: eingabe,
                  focusNode: fokus,
                  maxLength: 500,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onHinzu(),
                  decoration: InputDecoration(hintText: _hinweisText, counterText: ''),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(tooltip: 'Hinzufügen', onPressed: onHinzu, icon: const Icon(Icons.add)),
            ],
          ),
        ],
        if (gruppiert && rechte.darfEintraegeAendern)
          _Vorschlaege(liste: liste, eingabe: eingabe, fokus: fokus, offeneNamen: {for (final e in eintraege) if (e.doneAt == null) e.inhalt}),
        const SizedBox(height: 16),
        if (lesefehler)
          const EmptyState(icon: Icons.error_outline, title: 'Einträge nicht lesbar', hint: 'Die lokale Datenbank konnte nicht gelesen werden.')
        else if (!eintraegeWert.hasValue)
          const LadePlatzhalter()
        else if (sortiert.isEmpty)
          EmptyState(
            icon: Icons.checklist_outlined,
            title: 'Noch nichts drauf',
            hint: 'Schreib oben auf, was auf die Liste soll.',
            knopf: rechte.darfEintraegeAendern ? 'Eintrag hinzufügen' : null,
            onKnopf: rechte.darfEintraegeAendern ? fokus.requestFocus : null,
          )
        else if (gruppiert) ...[
          for (final g in gruppiereOffene(eintraege)) ...[
            Padding(
              key: ValueKey('kategorie-${g.kategorie.wire}'),
              padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
              child: MonoLabel(g.kategorie.label, color: kTextMuted),
            ),
            for (final e in g.eintraege) zeile(e),
          ],
          if (erledigteEintraege(eintraege).isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(2, 12, 2, 6), child: MonoLabel('Erledigt', color: kTextMuted)),
          for (final e in erledigteEintraege(eintraege)) zeile(e),
        ] else
          for (final e in sortiert) zeile(e),
        if (gesamt > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '${gesamt - erledigt} offen · $erledigt erledigt',
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
            ),
          ),
      ],
    );
  }
}

class _Zeile extends StatelessWidget {
  final Listeneintrag eintrag;
  final ListenRechte rechte;
  final UserDto? person;
  final VoidCallback onHaken;
  final VoidCallback onBearbeiten;
  final VoidCallback onZuweisen;
  const _Zeile({super.key, required this.eintrag, required this.rechte, required this.person, required this.onHaken, required this.onBearbeiten, required this.onZuweisen});

  @override
  Widget build(BuildContext context) {
    final erledigt = eintrag.doneAt != null;
    final zugewiesen = eintrag.assigneeId != null;
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        color: erledigt ? null : kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Semantics(
            checked: erledigt,
            label: erledigt ? '${eintrag.inhalt}, erledigt. Zum Zurücksetzen tippen' : '${eintrag.inhalt}, offen. Zum Abhaken tippen',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onHaken,
              child: SizedBox(
                width: 48,
                height: 52,
                child: Icon(erledigt ? Icons.check_box : Icons.check_box_outline_blank, color: erledigt ? kTerminal : kTextMuted),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: rechte.darfEintraegeAendern ? onBearbeiten : null,
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  eintrag.inhalt,
                  style: TextStyle(
                    fontSize: 15,
                    color: erledigt ? kTextMuted : kText,
                    decoration: erledigt ? TextDecoration.lineThrough : null,
                    decorationColor: kTextMuted,
                  ),
                ),
              ),
            ),
          ),
          if (rechte.darfEintraegeAendern)
            Tooltip(
              message: zugewiesen ? 'Zuständig: ${person?.displayName ?? 'unbekannt'}. Ändern' : 'Zuweisen',
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onZuweisen,
                child: SizedBox(
                  width: 48,
                  height: 52,
                  child: Center(
                    child: zugewiesen
                        ? BenutzerAvatar(user: person, size: 30)
                        : const Icon(Icons.person_add_alt, size: 20, color: kTextFaint),
                  ),
                ),
              ),
            )
          else if (zugewiesen)
            Padding(padding: const EdgeInsets.only(right: 12), child: BenutzerAvatar(user: person, size: 30)),
        ],
      ),
    );
  }
}

/// Vorschläge "Zuletzt gekauft" unter dem Eingabefeld: aus bereits abgehakten Einträgen der Familie, gefiltert nach dem Getippten.
/// Ein Tipp legt den Eintrag mit Name und Kategorie an.
class _Vorschlaege extends ConsumerWidget {
  final Liste liste;
  final TextEditingController eingabe;
  final FocusNode fokus;
  final Set<String> offeneNamen;
  const _Vorschlaege({required this.liste, required this.eingabe, required this.fokus, required this.offeneNamen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alle = ref.watch(alleEintraegeProvider).value ?? const <Listeneintrag>[];
    return ListenableBuilder(
      listenable: eingabe,
      builder: (context, _) {
        final treffer = zuletztGekauft(alle, eingabe.text, offeneNamen: offeneNamen);
        if (treffer.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MonoLabel('Zuletzt gekauft', color: kTextMuted),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final v in treffer)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44, maxWidth: 260),
                      child: ActionChip(
                        key: ValueKey('vorschlag-${v.name}'),
                        tooltip: '${v.name} hinzufügen (${v.kategorie.label})',
                        label: Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onPressed: () async {
                          eingabe.clear();
                          await ref.read(listenRepositoryProvider).eintragAnlegen(
                            liste.id,
                            v.name,
                            kategorie: v.kategorie == EinkaufKategorie.sonstiges ? null : v.kategorie.wire,
                          );
                          fokus.requestFocus();
                        },
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
