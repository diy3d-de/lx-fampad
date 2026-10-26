// Admin-Bereich: Mitglieder (Liste, Rolle ändern, entfernen, zurücksetzen, freigeben/ablehnen) und Einladungen
// (erstellen, offene auflisten, verlängern, widerrufen). Eltern sehen nur die Einladungen für Kinder.
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
import '../profile/wort_bestaetigung.dart';
import 'einladung_neu.dart';
import '../../widgets/benutzer_avatar.dart';

class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final istAdmin = ref.watch(authProvider.select((s) => s.istAdmin));
    final rolle = ref.watch(authProvider.select((s) => s.rolle)) ?? Role.child;
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

enum _Aktion { rolle, familienrolle, passwortZuruecksetzen, zuruecksetzen, bildZuruecksetzen, entfernen, freigeben, ablehnen }

class _MitgliederTabState extends ConsumerState<_MitgliederTab> with AktionsZustand<_MitgliederTab> {
  List<UserDto>? _mitglieder;

  /// Zustand der Passwort-Anmeldung je Mitglied (nur lesend; null: der Server bietet es nicht an). Nur für die kleine Markierung "altes Passwort-Verfahren".
  PasswortModi? _passwortModi;

  /// Bietet der Server das leichte "Passwort zurücksetzen" (Link, zweiter Faktor bleibt) an?
  bool _passwortResetDa = false;

  /// Kürzlich entfernte Mitglieder (Soft-Delete); null: der Server kennt es nicht (älterer Stand: Entfernen ist dort endgültig und sofort) oder die Abfrage ist gescheitert.
  EntfernteMitglieder? _entfernte;

  @override
  void initState() {
    super.initState();
    unawaited(_laden());
  }

  Future<void> _ladeListe() async {
    final api = ref.read(apiProvider);
    final m = await api.mitglieder();
    // die Liste der Entfernten ist nebensächlich: ein älterer Server (404) oder ein Fehler lässt nur den Bereich weg und den alten, ehrlichen Text im Dialog stehen
    EntfernteMitglieder? entfernte;
    try {
      entfernte = await api.entfernteMitglieder();
    } catch (_) {
      entfernte = null;
    }
    // die Markierung ist nebensächlich: Fehler dabei dürfen die Liste nicht verhindern
    PasswortModi? modi;
    try {
      modi = await api.passwortModi();
    } catch (_) {
      modi = null;
    }
    final resetDa = await api.pwSicherungVerfuegbar();
    if (mounted) {
      setState(() {
        _mitglieder = m;
        _passwortModi = modi;
        _passwortResetDa = resetDa;
        _entfernte = entfernte;
      });
    }
  }

  /// Text zum Entfernen: mit Soft-Delete (Server hält Schlüssel und Sicherungen noch [EntfernteMitglieder.aufbewahrungTage] Tage) ehrlich anders als beim sofortigen Löschen.
  String _entfernenText(UserDto m) {
    final e = _entfernte;
    if (e == null) {
      return '${m.displayName} wird entfernt und überall abgemeldet. Das Konto bleibt nur bestehen, wenn die Person noch zu einer anderen Familie gehört.\n\n'
          'Endgültig: Ihr Schlüssel, ihre Sicherungen und ihr Schlüsselarchiv werden auf dem Server gelöscht. Ihre früheren Nachrichten bleiben als Chiffretext. '
          'Auf Geräten, die ihren Schlüssel schon gemerkt haben, bleiben sie lesbar; auf neu verbundenen Geräten lassen sie sich nicht mehr prüfen.';
    }
    return '${m.displayName} wird aus der Familie genommen und überall abgemeldet. '
        'Konto, Schlüssel und Sicherungen bleiben noch ${e.aufbewahrungTage} Tage gespeichert: In dieser Zeit holst du die Person unter „Kürzlich entfernt“ zurück. '
        'Danach wird alles endgültig gelöscht, auch ihr Schlüssel und ihre Sicherungen. '
        'Zuständigkeiten, Termin-Teilnahmen und Chat-Teilnahmen kommen auch bei einer Rückkehr nicht von selbst zurück. '
        'Ihre früheren Nachrichten bleiben als Chiffretext; nach dem endgültigen Löschen lassen sie sich auf neu verbundenen Geräten nicht mehr prüfen. '
        'Die E-Mail-Adresse bleibt in dieser Zeit belegt: Eine Einladung mit derselben Adresse lässt sich erst annehmen, wenn du die Person zurückgeholt hast oder das endgültige Löschen erfolgt ist.';
  }

  /// "Jetzt endgültig löschen" (Art. 17 DSGVO und Ähnliches): unwiderruflich, mit Step-up und getipptem Wort.
  Future<void> _endgueltigLoeschen(EntferntesMitglied m) async {
    final ja = await wortBestaetigen(
      context,
      titel: '${m.name} jetzt endgültig löschen?',
      text: 'Konto, Anmeldedaten${m.hatSchluessel ? ', Schlüssel, alle Sicherungen und das Archiv' : ''} von ${m.name} werden sofort und unwiderruflich gelöscht. Danach lässt sich die Person nicht mehr zurückholen'
          '${m.hatSchluessel ? ', und ihr Chat-Verlauf ist für sie nie wieder lesbar' : ''}. Aus den Datensicherungen verschwinden die Daten erst nach deren Aufbewahrungsfrist.',
      wort: 'löschen',
      knopf: 'Endgültig löschen',
    );
    if (!ja || !mounted) return;
    await _ausfuehrenUndLaden(() => _schritt(() => ref.read(apiProvider).mitgliedEndgueltigLoeschen(m.id)), erfolg: '${m.name} ist endgültig gelöscht.');
  }

  Future<void> _wiederherstellen(EntferntesMitglied m) async {
    final ja = await _frage(
      '${m.name} zurückholen?',
      '${m.name} bekommt den Zugang zurück und meldet sich neu an. Schlüssel und Sicherungen sind unverändert da. '
          'Zuständigkeiten und Chat-Teilnahmen kommen nicht zurück: Du nimmst ${m.name} wieder in Gruppen auf, und die Familie bestätigt die Person im Chat wie jede neue Person. '
          'Empfehlung: Führe danach „Zugang zurücksetzen“ für ${m.name} aus. Das erneuert alle Anmeldedaten und Notfall-Codes, falls das Konto zwischendurch in falsche Hände geraten ist.',
      'Zurückholen',
      gefaehrlich: false,
    );
    if (!ja || !mounted) return;
    await _ausfuehrenUndLaden(() => _schritt(() => ref.read(apiProvider).mitgliedWiederherstellen(m.id)), erfolg: '${m.name} ist wieder in der Familie.');
  }

  Future<void> _laden() => ausfuehren(_ladeListe);

  Future<void> _aktion(UserDto m, _Aktion a) async {
    switch (a) {
      case _Aktion.rolle:
        final neu = await showDialog<Role>(useRootNavigator: false,
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
      case _Aktion.familienrolle:
        final wahl = await familienrolleWaehlen(context, titel: 'Familienrolle für ${m.displayName}', aktuell: m.familyRole);
        if (wahl == null || wahl.rolle == m.familyRole || !mounted) return;
        await _ausfuehrenUndLaden(
          () => _schritt(() => ref.read(apiProvider).familienrolleMitglied(m.id, wahl.rolle), stepUp: false),
          erfolg: 'Familienrolle geändert.',
        );
      case _Aktion.bildZuruecksetzen:
        final bild = await _frage(
          'Profilbild zurücksetzen?',
          'Das Profilbild von ${m.displayName} wird entfernt, es erscheinen wieder die Initialen. ${m.displayName} kann selbst ein neues Bild wählen.',
          'Zurücksetzen',
        );
        if (!bild || !mounted) return;
        await _ausfuehrenUndLaden(
          () => _schritt(() => ref.read(apiProvider).avatarMitgliedZuruecksetzen(m.id), stepUp: false),
          erfolg: 'Profilbild zurückgesetzt.',
        );
      case _Aktion.entfernen:
        final ja = await _frage('Mitglied entfernen?', _entfernenText(m), 'Entfernen');
        if (!ja || !mounted) return;
        await _ausfuehrenUndLaden(
          () => _schritt(() => ref.read(apiProvider).mitgliedEntfernen(m.id)),
          erfolg: _entfernte == null ? 'Mitglied entfernt.' : 'Mitglied entfernt. Du kannst es bis zum endgültigen Löschen zurückholen.',
        );
      case _Aktion.passwortZuruecksetzen:
        final opt = await _passwortResetWaehlen(m);
        if (opt == null || !mounted) return;
        var fertig = false;
        final geklappt = await ausfuehren(() async {
          final inv = await mitStepUp(context, ref, () => ref.read(apiProvider).passwortZuruecksetzenLink(m.id, stunden: opt.$1, pin: opt.$2));
          if (inv == null || !mounted) return;
          fertig = true;
          await Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => EinladungErstelltSeite(einladung: inv, rolle: m.role, fuer: m.displayName, passwortReset: true)),
          );
        });
        if (geklappt && fertig && mounted) await neuLadenMitHinweis(_ladeListe);
      case _Aktion.zuruecksetzen:
        final opt = await _zuruecksetzenWaehlen(m);
        if (opt == null || !mounted) return;
        var erledigt = false;
        final ok = await ausfuehren(() async {
          final inv = await mitStepUp(context, ref, () => ref.read(apiProvider).mitgliedZuruecksetzen(m.id, stunden: opt.$1, pin: opt.$2));
          if (inv == null || !mounted) return;
          erledigt = true;
          await Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => EinladungErstelltSeite(einladung: inv, rolle: m.role, fuer: m.displayName)),
          );
        });
        // Zugang ist zurückgesetzt: ein Fehler beim Neuladen der Liste ändert daran nichts
        if (ok && erledigt && mounted) await neuLadenMitHinweis(_ladeListe);
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
      if (r == true) erledigt = true;
    });
    // Erfolg und Neuladen der Liste getrennt: scheitert nur das Neuladen, war die Aktion trotzdem erfolgreich
    if (ok && erledigt && mounted) await neuLadenMitHinweis(_ladeListe, erfolg: erfolg);
  }

  Future<bool> _frage(String titel, String text, String knopf, {bool gefaehrlich = true}) async =>
      await showDialog<bool>(useRootNavigator: false,
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(titel),
          scrollable: true,
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Abbrechen')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: gefaehrlich ? TextButton.styleFrom(foregroundColor: kDanger) : null,
              child: Text(knopf),
            ),
          ],
        ),
      ) ??
      false;

  /// Gültigkeit und PIN für den Link "Passwort zurücksetzen" (leicht: Konto, Zugänge und Verlauf bleiben).
  Future<(int, bool)?> _passwortResetWaehlen(UserDto m) => showDialog<(int, bool)>(useRootNavigator: false,
    context: context,
    builder: (ctx) {
      var stunden = 24;
      var pin = false;
      return StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Passwort zurücksetzen?'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${m.displayName} bekommt einen Link und legt damit ein neues Passwort fest. '
                'Zur Sicherheit braucht die Person dafür auch den Code aus ihrer Authenticator-App: Du selbst kannst das Konto damit nicht übernehmen. '
                'Die App von ${m.displayName} muss aktuell sein (mit einer alten App klappt der Link nicht und zeigt „ungültig“ oder verlangt „Zugang zurücksetzen“). '
                'Authenticator, Passkeys und Notfall-Codes bleiben. Der Chat-Verlauf bleibt nur erhalten, wenn ${m.displayName} ein Gerät mit dem eigenen Schlüssel oder den Wiederherstellungsschlüssel hat. Alle Geräte von ${m.displayName} werden erst abgemeldet, wenn das neue Passwort gesetzt ist. '
                '${m.displayName} sieht den Vorgang in den Sicherheitsereignissen und bekommt eine Benachrichtigung.',
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
            TextButton(onPressed: () => Navigator.of(ctx).pop((stunden, pin)), child: const Text('Link erstellen')),
          ],
        ),
      );
    },
  );

  /// Gültigkeit und PIN für die Einladung zum Zurücksetzen.
  Future<(int, bool)?> _zuruecksetzenWaehlen(UserDto m) => showDialog<(int, bool)>(useRootNavigator: false,
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
                'Die Person richtet ihren Zugang mit einer neuen Einladung neu ein. Das Konto bleibt erhalten. '
                'Alle anderen in der Familie bekommen einen Hinweis darauf und sollen einen neuen Schlüssel von ${m.displayName} nur nach Rücksprache annehmen.'
                '${_passwortResetDa ? ' Verschlüsselte Chats kann sie danach nur lesen, wenn sie noch ein Gerät mit ihrem Schlüssel oder ihren Wiederherstellungsschlüssel hat. Willst du nur das Passwort neu setzen, nimm „Passwort zurücksetzen“.' : ''}',
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
            const MonoLabel('Wartet auf Freigabe', color: kWarn),
            const SizedBox(height: 8),
            for (final m in wartend) _MitgliedKarte(m: m, ich: ich, onAktion: laeuft ? null : _aktion, passwortModus: _passwortModi?.modi[m.id], passwortResetDa: _passwortResetDa),
            const SizedBox(height: 12),
          ],
          if (liste != null) ...[
            MonoLabel('Mitglieder (${aktiv.length})'),
            const SizedBox(height: 8),
            for (final m in aktiv) _MitgliedKarte(m: m, ich: ich, onAktion: laeuft ? null : _aktion, passwortModus: _passwortModi?.modi[m.id], passwortResetDa: _passwortResetDa),
            if (aktiv.isEmpty) const EmptyState(icon: Icons.group_outlined, title: 'Keine Mitglieder', hint: 'Lade jemanden ein.'),
          ],
          // Soft-Delete: entfernte Mitglieder, die noch zurückgeholt werden können (nur wenn es welche gibt)
          if (_entfernte != null && _entfernte!.mitglieder.isNotEmpty) ...[
            const SizedBox(height: 12),
            MonoLabel('Kürzlich entfernt (${_entfernte!.mitglieder.length})', color: kTextMuted),
            const SizedBox(height: 4),
            Text(
              'Schlüssel und Sicherungen liegen noch ${_entfernte!.aufbewahrungTage} Tage nach dem Entfernen beim Server. Danach wird alles endgültig gelöscht. Die E-Mail-Adresse bleibt bis dahin belegt: Eine Registrierung mit ihr geht erst nach dem Zurückholen oder dem endgültigen Löschen.',
              style: const TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
            ),
            const SizedBox(height: 8),
            for (final m in _entfernte!.mitglieder) _EntferntKarte(m: m, onZurueck: laeuft ? null : () => _wiederherstellen(m), onLoeschen: laeuft ? null : () => _endgueltigLoeschen(m)),
          ],
        ],
      ),
    );
  }
}

/// Ein kürzlich entferntes Mitglied: Name, Rolle, wann es endgültig gelöscht wird und der Knopf "Zurückholen".
class _EntferntKarte extends StatelessWidget {
  final EntferntesMitglied m;
  final VoidCallback? onZurueck;
  final VoidCallback? onLoeschen;
  const _EntferntKarte({required this.m, required this.onZurueck, required this.onLoeschen});

  static String _tag(DateTime d) => DateFormat('dd.MM.yyyy').format(d.toLocal());

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      container: true,
      label: '${m.name}, entfernt am ${_tag(m.entferntAm)}, wird am ${_tag(m.loeschtAm)} endgültig gelöscht',
      child: LxCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 4, children: [RollenPille(m.rolle.label, farbe: kTextMuted), if (m.hatSchluessel) const RollenPille('schlüssel gespeichert', farbe: kWarn)]),
            const SizedBox(height: 6),
            Text(
              'entfernt am ${_tag(m.entferntAm)} · endgültig gelöscht am ${_tag(m.loeschtAm)}',
              style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
            ),
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Zurückholen', icon: Icons.undo, onPressed: onZurueck),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onLoeschen,
                style: TextButton.styleFrom(foregroundColor: kDanger, minimumSize: const Size(44, 44)),
                icon: const Icon(Icons.delete_forever_outlined, size: 18),
                label: const Text('Jetzt endgültig löschen'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MitgliedKarte extends StatelessWidget {
  final UserDto m;
  final String? ich;
  final Future<void> Function(UserDto, _Aktion)? onAktion;

  /// Zustand der Passwort-Anmeldung (nur Admins, nur wenn der Server es liefert); "legacy" bekommt eine kleine Markierung.
  final PasswortModus? passwortModus;

  /// Der Server bietet "Passwort zurücksetzen" an (nur sinnvoll für Mitglieder mit Passwort).
  final bool passwortResetDa;
  const _MitgliedKarte({required this.m, required this.ich, required this.onAktion, this.passwortModus, this.passwortResetDa = false});

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
            BenutzerAvatar(user: m),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(bin ? '${m.displayName} (du)' : m.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (m.email != null)
                    Text(m.email!, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4, children: [...rollenPillen(m.role, m.familyRole), if (wartet) const RollenPille('wartet', farbe: kWarn), if (passwortModus == PasswortModus.legacy) const RollenPille('altes passwort-verfahren', farbe: kWarn)]),
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
                    : [
                        const PopupMenuItem(value: _Aktion.rolle, child: Text('Rolle ändern')),
                        const PopupMenuItem(value: _Aktion.familienrolle, child: Text('Familienrolle ändern')),
                        if (m.avatar != null) const PopupMenuItem(value: _Aktion.bildZuruecksetzen, child: Text('Profilbild zurücksetzen')),
                        if (passwortResetDa && passwortModus != PasswortModus.keins) const PopupMenuItem(value: _Aktion.passwortZuruecksetzen, child: Text('Passwort zurücksetzen')),
                        const PopupMenuItem(value: _Aktion.zuruecksetzen, child: Text('Zugang zurücksetzen')),
                        const PopupMenuItem(value: _Aktion.entfernen, child: Text('Entfernen')),
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

  Future<void> _ladeListe() async {
    final l = await ref.read(apiProvider).einladungen();
    if (mounted) setState(() => _liste = l);
  }

  Future<void> _laden() => ausfuehren(_ladeListe);

  Future<void> _neu() async {
    final wahl = await neueEinladungWaehlen(context, widget.rolle);
    if (wahl == null || !mounted) return;
    var erledigt = false;
    final ok = await ausfuehren(() async {
      final api = ref.read(apiProvider);
      Future<CreatedInvite> erzeugen() => api.einladungErstellen(rolle: wahl.rolle, stunden: wahl.stunden, pin: wahl.pin, freigabe: wahl.freigabe);
      // Admin-Einladungen verlangen eine frische Bestätigung (Step-up)
      final inv = await mitStepUp(context, ref, erzeugen);
      if (inv == null || !mounted) return;
      erledigt = true;
      await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => EinladungErstelltSeite(einladung: inv, rolle: wahl.rolle)));
    });
    // Die Einladung existiert: ein Fehler beim Neuladen der Liste ist kein Fehler beim Erstellen
    if (ok && erledigt && mounted) await neuLadenMitHinweis(_ladeListe);
  }

  Future<void> _widerrufen(InviteDto i) async {
    final ja = await showDialog<bool>(useRootNavigator: false,
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
    final ok = await ausfuehren(() => ref.read(apiProvider).einladungWiderrufen(i.id));
    if (ok && mounted) await neuLadenMitHinweis(_ladeListe);
  }

  Future<void> _verlaengern(InviteDto i) async {
    final stunden = await showDialog<int>(useRootNavigator: false,
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
    final ok = await ausfuehren(() => ref.read(apiProvider).einladungVerlaengern(i.id, stunden));
    if (ok && mounted) await neuLadenMitHinweis(_ladeListe);
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
            MonoLabel('Einladungen (${liste.length})'),
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
                                if (i.art == EinladungsArt.passwordReset) const RollenPille('neues passwort', farbe: kWarn) else if (i.reset) const RollenPille('zurücksetzen', farbe: kWarn),
                                if (i.hasPin) const RollenPille('pin', farbe: kTextMuted),
                                if (i.requireApproval) const RollenPille('freigabe', farbe: kTextMuted),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'gültig bis ${df.format(i.expiresAt.toLocal())}',
                              style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
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
