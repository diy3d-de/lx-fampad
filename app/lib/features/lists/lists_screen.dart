import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/lists/list_repository.dart';
import '../../data/lists/list_rights.dart';
import '../../data/lists/members.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/sync_hinweise.dart';
import '../../widgets/kopfzeile.dart';
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
    await _repo.eintragAnlegen(liste.id, text);
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

  Future<void> _eintragBearbeiten(Listeneintrag e) async {
    final a = await eintragBlatt(context, text: e.inhalt);
    if (a == null) return;
    switch (a) {
      case EintragSpeichern(:final text):
        if (text != e.inhalt) await _repo.eintragText(e.id, text);
      case EintragLoeschen():
        await _repo.eintragLoeschen(e.id);
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

    return RefreshIndicator(
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
            _ => const [Padding(padding: EdgeInsets.only(top: 48), child: Center(child: CircularProgressIndicator()))],
          },
        ],
      ),
    );
  }

  List<Widget> _inhalt(List<Liste> listen, String? gewaehlt, ListenRechte rechte) {
    if (listen.isEmpty) {
      return [
        const SizedBox(height: 24),
        const EmptyState(icon: Icons.checklist_outlined, title: 'Noch keine Liste', hint: 'Lege eine Liste an, z. B. für den Einkauf oder die Packliste.'),
        if (rechte.darfListeAnlegen)
          Center(
            child: FilledButton.icon(onPressed: _listeAnlegen, icon: const Icon(Icons.add), label: const Text('Liste anlegen')),
          ),
      ];
    }
    final liste = listen.firstWhere((l) => l.id == gewaehlt, orElse: () => listen.first);
    // Mitglieder (Name, Farbe der Zuständigen) erst laden, wenn es eine Liste gibt
    final mitglieder = Mitglieder(ref.watch(mitgliederProvider).value ?? const []);
    return [
      _Reiter(listen: listen, aktiv: liste.id, onWahl: (id) => ref.read(gewaehlteListeProvider.notifier).waehlen(id), onNeu: rechte.darfListeAnlegen ? _listeAnlegen : null),
      const SizedBox(height: 16),
      _ListeAnsicht(
        key: ValueKey(liste.id),
        liste: liste,
        rechte: rechte,
        mitglieder: mitglieder,
        eingabe: _neu,
        fokus: _fokus,
        onHinzu: () => _eintragHinzufuegen(liste),
        onMenue: (a) => _menue(liste, a),
        onBearbeiten: _eintragBearbeiten,
        onZuweisen: (e) => _zuweisen(e, mitglieder.alle),
      ),
    ];
  }
}

// ------------------------------------------------------------------------------------------------ Teile

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
    decoration: BoxDecoration(color: kSurface, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
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
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eintraegeWert = ref.watch(eintraegeProvider(liste.id));
    final eintraege = eintraegeWert.value ?? const <Listeneintrag>[];
    final lesefehler = eintraegeWert.hasError && !eintraegeWert.hasValue; // sonst sähe ein Lesefehler wie eine leere Liste aus
    final sortiert = sortiereEintraege(eintraege);
    final erledigt = eintraege.where((e) => e.doneAt != null).length;
    final gesamt = eintraege.length;
    final menue = rechte.darfListeAendern(liste);
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
                    style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
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
                  if (rechte.darfFreigabeAendern) const PopupMenuItem(value: 'sicht', height: 48, child: Text('Sichtbar für …')),
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
        Text(gesamt == 0 ? '' : '$erledigt von $gesamt erledigt', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
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
        const SizedBox(height: 16),
        if (lesefehler)
          const EmptyState(icon: Icons.error_outline, title: 'Einträge nicht lesbar', hint: 'Die lokale Datenbank konnte nicht gelesen werden.')
        else if (sortiert.isEmpty)
          const EmptyState(icon: Icons.checklist_outlined, title: 'Noch nichts drauf', hint: 'Schreib oben auf, was auf die Liste soll.')
        else
          for (final e in sortiert)
            Padding(
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
            ),
        if (gesamt > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '${gesamt - erledigt} offen · $erledigt erledigt',
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
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
        color: erledigt ? null : kSurface.withValues(alpha: 0.7),
        border: Border.all(color: kBorder),
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
