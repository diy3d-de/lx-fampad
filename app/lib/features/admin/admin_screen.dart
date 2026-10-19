// Admin-Bereich: Mitglieder (Liste, Rolle ändern, entfernen, zurücksetzen, freigeben/ablehnen) und Einladungen
// (erstellen, offene auflisten, verlängern, widerrufen). Eltern sehen nur die Einladungen für Kinder und Gäste.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import 'einladung_neu.dart';

class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final istAdmin = ref.watch(authProvider.select((s) => s.istAdmin));
    final rolle = ref.watch(authProvider.select((s) => s.rolle)) ?? Role.guest;
    final inhalt = istAdmin
        ? TabBarView(children: [const _MitgliederTab(), _EinladungenTab(rolle: rolle)])
        : _EinladungenTab(rolle: rolle);
    final body = LxBackground(
      child: SafeArea(
        child: LxContentWidth(child: inhalt),
      ),
    );
    final bar = AppBar(
      title: Text(istAdmin ? 'Familie verwalten' : 'Einladungen'),
      bottom: istAdmin
          ? const TabBar(
              indicatorColor: kAccent,
              labelColor: kAccent,
              unselectedLabelColor: kTextMuted,
              tabs: [Tab(text: 'Mitglieder'), Tab(text: 'Einladungen')],
            )
          : null,
    );
    final scaffold = Scaffold(backgroundColor: kBg, appBar: bar, body: body);
    return istAdmin ? DefaultTabController(length: 2, child: scaffold) : scaffold;
  }
}

// ---------------------------------------------------------------------------------------------------------------- Mitglieder

class _MitgliederTab extends ConsumerStatefulWidget {
  const _MitgliederTab();

  @override
  ConsumerState<_MitgliederTab> createState() => _MitgliederTabState();
}

enum _Aktion { rolle, zuruecksetzen, entfernen, freigeben, ablehnen }

class _MitgliederTabState extends ConsumerState<_MitgliederTab> with AktionsZustand<_MitgliederTab> {
  List<UserDto>? _mitglieder;

  @override
  void initState() {
    super.initState();
    unawaited(_laden());
  }

  Future<void> _laden() => ausfuehren(() async {
    final m = await ref.read(apiProvider).mitglieder();
    if (mounted) setState(() => _mitglieder = m);
  });

  Future<void> _aktion(UserDto m, _Aktion a) async {
    switch (a) {
      case _Aktion.rolle:
        final neu = await showDialog<Role>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text('Rolle für ${m.displayName}'),
            children: [
              for (final r in Role.values)
                SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(r),
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Icon(r == m.role ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 20, color: kAccent),
                        const SizedBox(width: 12),
                        Text(r.label),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
        if (neu == null || neu == m.role || !mounted) return;
        await _ausfuehrenUndLaden(() => _schritt(() => ref.read(apiProvider).rolleAendern(m.id, neu)), erfolg: 'Rolle geändert.');
      case _Aktion.entfernen:
        final ja = await _frage(
          'Mitglied entfernen?',
          '${m.displayName} wird entfernt und überall abgemeldet. Das Konto bleibt nur bestehen, wenn die Person noch zu einer anderen Familie gehört.',
          'Entfernen',
        );
        if (!ja || !mounted) return;
        await _ausfuehrenUndLaden(() => _schritt(() => ref.read(apiProvider).mitgliedEntfernen(m.id)), erfolg: 'Mitglied entfernt.');
      case _Aktion.zuruecksetzen:
        final opt = await _zuruecksetzenWaehlen(m);
        if (opt == null || !mounted) return;
        await ausfuehren(() async {
          final inv = await mitStepUp(context, ref, () => ref.read(apiProvider).mitgliedZuruecksetzen(m.id, stunden: opt.$1, pin: opt.$2));
          if (inv == null || !mounted) return;
          await Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => EinladungErstelltSeite(einladung: inv, rolle: m.role, fuer: m.displayName)),
          );
          final liste = await ref.read(apiProvider).mitglieder();
          if (mounted) setState(() => _mitglieder = liste);
        });
      case _Aktion.freigeben:
        await _ausfuehrenUndLaden(() => _schritt(() => ref.read(apiProvider).freigeben(m.id), stepUp: false), erfolg: '${m.displayName} ist freigegeben.');
      case _Aktion.ablehnen:
        final ja = await _frage('Anfrage ablehnen?', '${m.displayName} wird abgelehnt und das Konto gelöscht.', 'Ablehnen');
        if (!ja || !mounted) return;
        await _ausfuehrenUndLaden(() => _schritt(() => ref.read(apiProvider).ablehnen(m.id), stepUp: false), erfolg: 'Anfrage abgelehnt.');
    }
  }

  /// Führt einen Schritt aus (bei Bedarf mit Step-up); true = erledigt, null = Bestätigung abgebrochen.
  Future<bool?> _schritt(Future<void> Function() f, {bool stepUp = true}) async {
    Future<bool> lauf() async {
      await f();
      return true;
    }

    return stepUp ? mitStepUp<bool>(context, ref, lauf) : lauf();
  }

  Future<void> _ausfuehrenUndLaden(Future<bool?> Function() aktion, {required String erfolg}) async {
    var erledigt = false;
    final ok = await ausfuehren(() async {
      final r = await aktion();
      if (r != true || !mounted) return;
      erledigt = true;
      final m = await ref.read(apiProvider).mitglieder();
      if (mounted) setState(() => _mitglieder = m);
    });
    if (ok && erledigt && mounted) zeigeHinweis(context, erfolg);
  }

  Future<bool> _frage(String titel, String text, String knopf) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(titel),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Abbrechen')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), style: TextButton.styleFrom(foregroundColor: kDanger), child: Text(knopf)),
          ],
        ),
      ) ??
      false;

  /// Gültigkeit und PIN für die Einladung zum Zurücksetzen.
  Future<(int, bool)?> _zuruecksetzenWaehlen(UserDto m) => showDialog<(int, bool)>(
    context: context,
    builder: (ctx) {
      var stunden = 24;
      var pin = false;
      return StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Zugang zurücksetzen?'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Alle Anmeldedaten, Codes und Sitzungen von ${m.displayName} werden widerrufen. '
                'Die Person richtet ihren Zugang mit einer neuen Einladung neu ein. Das Konto bleibt erhalten.',
                style: const TextStyle(color: kTextMuted, height: 1.4),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final (t, h) in kGueltigkeiten) ChoiceChip(label: Text(t), selected: stunden == h, onSelected: (_) => setD(() => stunden = h)),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: pin,
                onChanged: (v) => setD(() => pin = v),
                title: const Text('PIN verlangen'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Abbrechen')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop((stunden, pin)),
              style: TextButton.styleFrom(foregroundColor: kDanger),
              child: const Text('Zurücksetzen'),
            ),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final ich = ref.watch(authProvider.select((s) => s.user?.id));
    final liste = _mitglieder;
    final wartend = liste?.where((m) => m.status == MemberStatus.pending).toList() ?? const <UserDto>[];
    final aktiv = liste?.where((m) => m.status == MemberStatus.active).toList() ?? const <UserDto>[];
    return RefreshIndicator(
      onRefresh: _laden,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
          if (liste == null && laeuft) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (wartend.isNotEmpty) ...[
            const MonoLabel('// wartet auf freigabe', color: kWarn),
            const SizedBox(height: 8),
            for (final m in wartend) _MitgliedKarte(m: m, ich: ich, onAktion: laeuft ? null : _aktion),
            const SizedBox(height: 12),
          ],
          if (liste != null) ...[
            MonoLabel('// mitglieder (${aktiv.length})'),
            const SizedBox(height: 8),
            for (final m in aktiv) _MitgliedKarte(m: m, ich: ich, onAktion: laeuft ? null : _aktion),
            if (aktiv.isEmpty) const EmptyState(icon: Icons.group_outlined, title: 'Keine Mitglieder', hint: 'Lade jemanden ein.'),
          ],
        ],
      ),
    );
  }
}

class _MitgliedKarte extends StatelessWidget {
  final UserDto m;
  final String? ich;
  final Future<void> Function(UserDto, _Aktion)? onAktion;
  const _MitgliedKarte({required this.m, required this.ich, required this.onAktion});

  @override
  Widget build(BuildContext context) {
    final bin = m.id == ich;
    final wartet = m.status == MemberStatus.pending;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        child: Row(
          children: [
            PersonAvatar(name: m.displayName, colorIndex: m.colorIndex),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(bin ? '${m.displayName} (du)' : m.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (m.email != null)
                    Text(m.email!, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4, children: [RollenPille(m.role.label), if (wartet) const RollenPille('wartet', farbe: kWarn)]),
                ],
              ),
            ),
            if (!bin && onAktion != null)
              PopupMenuButton<_Aktion>(
                tooltip: 'Aktionen für ${m.displayName}',
                onSelected: (a) => onAktion!(m, a),
                itemBuilder: (_) => wartet
                    ? const [
                        PopupMenuItem(value: _Aktion.freigeben, child: Text('Freigeben')),
                        PopupMenuItem(value: _Aktion.ablehnen, child: Text('Ablehnen')),
                      ]
                    : const [
                        PopupMenuItem(value: _Aktion.rolle, child: Text('Rolle ändern')),
                        PopupMenuItem(value: _Aktion.zuruecksetzen, child: Text('Zugang zurücksetzen')),
                        PopupMenuItem(value: _Aktion.entfernen, child: Text('Entfernen')),
                      ],
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------- Einladungen

class _EinladungenTab extends ConsumerStatefulWidget {
  final Role rolle;
  const _EinladungenTab({required this.rolle});

  @override
  ConsumerState<_EinladungenTab> createState() => _EinladungenTabState();
}

class _EinladungenTabState extends ConsumerState<_EinladungenTab> with AktionsZustand<_EinladungenTab> {
  List<InviteDto>? _liste;

  @override
  void initState() {
    super.initState();
    unawaited(_laden());
  }

  Future<void> _laden() => ausfuehren(() async {
    final l = await ref.read(apiProvider).einladungen();
    if (mounted) setState(() => _liste = l);
  });

  Future<void> _neu() async {
    final wahl = await neueEinladungWaehlen(context, widget.rolle);
    if (wahl == null || !mounted) return;
    await ausfuehren(() async {
      final api = ref.read(apiProvider);
      Future<CreatedInvite> erzeugen() => api.einladungErstellen(rolle: wahl.rolle, stunden: wahl.stunden, pin: wahl.pin, freigabe: wahl.freigabe);
      // Admin-Einladungen verlangen eine frische Bestätigung (Step-up)
      final inv = await mitStepUp(context, ref, erzeugen);
      if (inv == null || !mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => EinladungErstelltSeite(einladung: inv, rolle: wahl.rolle)));
      final l = await api.einladungen();
      if (mounted) setState(() => _liste = l);
    });
  }

  Future<void> _widerrufen(InviteDto i) async {
    final ja = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Einladung widerrufen?'),
        content: const Text('Der Link und der QR-Code dieser Einladung funktionieren danach nicht mehr.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), style: TextButton.styleFrom(foregroundColor: kDanger), child: const Text('Widerrufen')),
        ],
      ),
    );
    if (ja != true || !mounted) return;
    await ausfuehren(() async {
      await ref.read(apiProvider).einladungWiderrufen(i.id);
      final l = await ref.read(apiProvider).einladungen();
      if (mounted) setState(() => _liste = l);
    });
  }

  Future<void> _verlaengern(InviteDto i) async {
    final stunden = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Einladung verlängern'),
        children: [
          for (final (t, h) in kGueltigkeiten)
            SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop(h), child: SizedBox(height: 44, child: Align(alignment: Alignment.centerLeft, child: Text('Noch $t gültig')))),
        ],
      ),
    );
    if (stunden == null || !mounted) return;
    await ausfuehren(() async {
      await ref.read(apiProvider).einladungVerlaengern(i.id, stunden);
      final l = await ref.read(apiProvider).einladungen();
      if (mounted) setState(() => _liste = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final liste = _liste;
    final df = DateFormat('d. MMM, HH:mm', 'de_DE');
    return RefreshIndicator(
      onRefresh: _laden,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          HauptKnopf(text: 'Neue Einladung', icon: Icons.add, onPressed: laeuft ? null : _neu),
          const SizedBox(height: 16),
          if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
          if (liste == null && laeuft) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (liste != null) ...[
            MonoLabel('// einladungen (${liste.length})'),
            const SizedBox(height: 8),
            if (liste.isEmpty) const EmptyState(icon: Icons.mail_outline, title: 'Keine Einladungen', hint: 'Erstelle eine, um jemanden einzuladen.'),
            for (final i in liste)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: LxCard(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                RollenPille(i.role.label),
                                RollenPille(i.status.label, farbe: i.status == InviteStatus.open ? kTerminal : kTextMuted),
                                if (i.reset) const RollenPille('zurücksetzen', farbe: kWarn),
                                if (i.hasPin) const RollenPille('pin', farbe: kTextMuted),
                                if (i.requireApproval) const RollenPille('freigabe', farbe: kTextMuted),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'gültig bis ${df.format(i.expiresAt.toLocal())}',
                              style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
                            ),
                          ],
                        ),
                      ),
                      if (i.status == InviteStatus.open || i.status == InviteStatus.expired)
                        PopupMenuButton<String>(
                          tooltip: 'Aktionen für die ${i.role.label}-Einladung',
                          enabled: !laeuft,
                          onSelected: (a) => a == 'verlaengern' ? _verlaengern(i) : _widerrufen(i),
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'verlaengern', child: Text('Verlängern')),
                            if (i.status == InviteStatus.open) const PopupMenuItem(value: 'widerrufen', child: Text('Widerrufen')),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
