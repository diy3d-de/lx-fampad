// Nachrichtenansicht eines Chats: Kopf, Verlauf (Blasen, Datumstrenner), Antworten, Bearbeiten, Eingabe. Senden wirkt sofort auf die lokale
// Datenbank ("wird gesendet" bis der Server bestätigt). Links werden nicht angeklickt oder vorgeladen; Inhalte laufen über NachrichtenInhalt.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/chat/nachrichten_inhalt.dart';
import '../../data/lists/members.dart';
import '../../ui/widgets.dart';
import '../lists/list_dialogs.dart';
import 'chat_anzeige.dart';
import 'personen_wahl.dart';

class ChatVerlauf extends ConsumerStatefulWidget {
  final String konversationId;

  /// Schließt den Verlauf (Zurück-Pfeil; nach Verlassen oder Löschen einer Gruppe). Fehlt er, gibt es keinen Pfeil.
  final VoidCallback? beiSchliessen;

  /// Zurück-Pfeil im Kopf (schmal: ja; im Zweispalter steht die Liste daneben).
  final bool zurueckPfeil;
  const ChatVerlauf({super.key, required this.konversationId, this.beiSchliessen, this.zurueckPfeil = true});

  @override
  ConsumerState<ChatVerlauf> createState() => _ChatVerlaufState();
}

class _ChatVerlaufState extends ConsumerState<ChatVerlauf> {
  final _text = TextEditingController();
  final _fokus = FocusNode();
  final _scroll = ScrollController();
  Nachricht? _antwort;
  Nachricht? _bearbeitet;
  bool _amEnde = true;

  String get _id => widget.konversationId;
  ChatRepository get _repo => ref.read(chatRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_beiScrollen);
    WidgetsBinding.instance.addPostFrameCallback((_) => _markieren());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _text.dispose();
    _fokus.dispose();
    super.dispose();
  }

  /// Der Verlauf ist umgekehrt (neueste unten = Offset 0): "am Ende" heißt nahe 0.
  void _beiScrollen() {
    final am = !_scroll.hasClients || _scroll.position.pixels <= 80;
    if (am && !_amEnde) _markieren();
    _amEnde = am;
  }

  /// Lesestand setzen, solange der Chat offen, im Vordergrund und am Ende gelesen ist.
  void _markieren() {
    if (!mounted || !_amEnde) return;
    final s = WidgetsBinding.instance.lifecycleState;
    if (s != null && s != AppLifecycleState.resumed) return;
    unawaited(_repo.gelesenSetzen(_id));
  }

  Future<void> _senden() async {
    final t = _text.text;
    if (t.trim().isEmpty) return;
    final bearbeitet = _bearbeitet;
    final antwort = _antwort;
    _text.clear();
    setState(() {
      _antwort = null;
      _bearbeitet = null;
    });
    if (bearbeitet != null) {
      await _repo.bearbeiten(bearbeitet.id, t);
    } else {
      await _repo.senden(_id, t, antwortAuf: antwort?.id);
    }
    if (mounted && _scroll.hasClients) unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 150), curve: Curves.easeOut));
  }

  Future<void> _aktionen(Nachricht n, ChatArt art, ChatRechte rechte, bool lesbar, String text) async {
    final aktion = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kSurface,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AktionsZeile(icon: Icons.reply, text: 'Antworten', wert: 'antworten', c: c),
            if (lesbar) _AktionsZeile(icon: Icons.copy_outlined, text: 'Text kopieren', wert: 'kopieren', c: c),
            if (lesbar && rechte.darfBearbeiten(n)) _AktionsZeile(icon: Icons.edit_outlined, text: 'Bearbeiten', wert: 'bearbeiten', c: c),
            if (rechte.darfLoeschen(n, art)) _AktionsZeile(icon: Icons.delete_outline, text: 'Löschen', wert: 'loeschen', c: c, gefahr: true),
          ],
        ),
      ),
    );
    if (!mounted || aktion == null) return;
    switch (aktion) {
      case 'antworten':
        setState(() {
          _antwort = n;
          _bearbeitet = null;
        });
        _fokus.requestFocus();
      case 'kopieren':
        await Clipboard.setData(ClipboardData(text: text));
      case 'bearbeiten':
        _text.text = text;
        _text.selection = TextSelection.collapsed(offset: text.length);
        setState(() {
          _bearbeitet = n;
          _antwort = null;
        });
        _fokus.requestFocus();
      case 'loeschen':
        final ja = await bestaetigen(context, titel: 'Nachricht löschen?', text: 'Die Nachricht wird für alle im Chat gelöscht.', knopf: 'Löschen');
        if (ja && mounted) {
          if (_bearbeitet?.id == n.id) setState(() => _bearbeitet = null);
          await _repo.loeschen(n.id);
        }
    }
  }

  void _schliessen() => widget.beiSchliessen?.call();

  Future<void> _gruppenMenue(String aktion, Konversation k, List<String> teilnehmer, String? ich) async {
    final messenger = ScaffoldMessenger.of(context);
    switch (aktion) {
      case 'name':
        final inhalt = ref.read(nachrichtenInhaltProvider);
        final alt = inhalt.dekodieren(k.titel);
        final n = await textDialog(context, titel: 'Gruppenname', label: 'Name der Gruppe', start: alt.lesbar ? alt.text : '', maxLaenge: kMaxChatNameZeichen);
        if (n != null) await _repo.gruppeUmbenennen(k.id, n);
      case 'teilnehmer':
        final wahl = await Navigator.of(context).push<PersonenAuswahl>(
          MaterialPageRoute(builder: (_) => PersonenWahlSeite(modus: PersonenWahlModus.teilnehmer, vorgewaehlt: {...teilnehmer}..remove(ich))),
        );
        if (wahl == null) return;
        if (ich != null) await _repo.teilnehmerSetzen(k.id, [ich, ...wahl.personen]);
      case 'verlassen':
        if (teilnehmer.length <= 2) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('Dann bliebe nur eine Person übrig. Lösche die Gruppe stattdessen.')));
          return;
        }
        final ja = await bestaetigen(context, titel: 'Gruppe verlassen?', text: 'Du siehst die Gruppe danach nicht mehr, bis dich jemand wieder aufnimmt.', knopf: 'Verlassen');
        if (!ja || ich == null) return;
        await _repo.teilnehmerSetzen(k.id, [...teilnehmer.where((t) => t != ich)]);
        _schliessen();
      case 'loeschen':
        final ja = await bestaetigen(context, titel: 'Gruppe löschen?', text: 'Die Gruppe und alle Nachrichten werden für alle gelöscht.', knopf: 'Löschen');
        if (!ja) return;
        await _repo.gruppeLoeschen(k.id);
        _schliessen();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(nachrichtenProvider(_id), (_, _) => WidgetsBinding.instance.addPostFrameCallback((_) => _markieren()));
    final user = ref.watch(authProvider.select((s) => s.user));
    final ich = user?.id;
    final rechte = ChatRechte(user?.role ?? Role.child, ich);
    final inhalt = ref.watch(nachrichtenInhaltProvider);
    final mitglieder = Mitglieder(ref.watch(mitgliederProvider).value ?? const []);
    final konvAsync = ref.watch(konversationProvider(_id));
    final konv = konvAsync.value;
    if (konv == null) {
      return Column(
        children: [
          _Kopf(beiSchliessen: widget.zurueckPfeil ? widget.beiSchliessen : null, titel: 'Chat', untertitel: '', avatar: null, menue: null),
          Expanded(
            child: konvAsync.isLoading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : const EmptyState(icon: Icons.chat_bubble_outline, title: 'Chat nicht verfügbar', hint: 'Er wurde gelöscht oder du bist nicht mehr dabei.'),
          ),
        ],
      );
    }
    final art = konv.chatArt;
    final teilnehmer = teilnehmerIds(konv);
    final name = chatName(konv, teilnehmer, mitglieder, ich, inhalt);
    final anderer = art == ChatArt.direct ? mitglieder[teilnehmer.where((t) => t != ich).firstOrNull] : null;
    final untertitel = switch (art) {
      ChatArt.family => 'alle in der familie',
      ChatArt.direct => 'direktchat',
      ChatArt.group => '${teilnehmer.length} teilnehmer',
    };
    final liste = ref.watch(nachrichtenProvider(_id)).value ?? const <Nachricht>[];
    final nachId = {for (final n in liste) n.id: n};

    // Verlauf mit Datumstrennern (chronologisch), umgekehrt angezeigt: neueste unten
    final eintraege = <Object>[];
    DateTime? vorher;
    for (final n in liste) {
      if (vorher == null || !gleicherTag(vorher, n.createdAt)) eintraege.add(n.createdAt);
      eintraege.add(n);
      vorher = n.createdAt;
    }
    final umgekehrt = eintraege.reversed.toList();
    final breit = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;

    final eingabe = _Eingabe(
      controller: _text,
      fokus: _fokus,
      enterSendet: breit,
      onSenden: _senden,
      banner: _bearbeitet != null
          ? _Banner(label: 'nachricht bearbeiten', text: nachrichtKurztext(_bearbeitet!, inhalt), onAbbrechen: () => setState(() {
              _bearbeitet = null;
              _text.clear();
            }))
          : _antwort != null
          ? _Banner(
              label: 'antwort an ${_antwort!.autorId == ich ? 'dich' : (mitglieder[_antwort!.autorId]?.displayName ?? 'unbekannt')}',
              text: nachrichtKurztext(_antwort!, inhalt),
              onAbbrechen: () => setState(() => _antwort = null),
            )
          : null,
    );

    return Column(
      children: [
        _Kopf(
          beiSchliessen: widget.zurueckPfeil ? widget.beiSchliessen : null,
          titel: name,
          untertitel: untertitel,
          avatar: ChatAvatar(art: art, person: anderer, name: name, size: 36),
          menue: art == ChatArt.group
              ? PopupMenuButton<String>(
                  tooltip: 'Gruppe verwalten',
                  color: kSurface,
                  onSelected: (a) => _gruppenMenue(a, konv, teilnehmer, ich),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'name', height: 48, child: Text('Namen ändern')),
                    const PopupMenuItem(value: 'teilnehmer', height: 48, child: Text('Teilnehmer ändern')),
                    const PopupMenuItem(value: 'verlassen', height: 48, child: Text('Gruppe verlassen')),
                    if (rechte.darfGruppeLoeschen(konv)) const PopupMenuItem(value: 'loeschen', height: 48, child: Text('Gruppe löschen', style: TextStyle(color: kDanger))),
                  ],
                )
              : null,
        ),
        Expanded(
          child: liste.isEmpty
              ? EmptyState(icon: Icons.chat_bubble_outline, title: 'Noch keine Nachrichten', hint: art == ChatArt.family ? 'Schreib die erste Nachricht an die Familie.' : 'Schreib die erste Nachricht.')
              : ListView.builder(
                  reverse: true,
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  itemCount: umgekehrt.length,
                  itemBuilder: (context, i) {
                    final e = umgekehrt[i];
                    if (e is DateTime) return _Trenner(datumTrenner(e));
                    final n = e as Nachricht;
                    final eigen = rechte.eigene(n);
                    // Name nur über der ersten Nachricht einer Folge derselben Person (in Direktchats nie)
                    final davor = i + 1 < umgekehrt.length ? umgekehrt[i + 1] : null;
                    final zeigeName = !eigen && art != ChatArt.direct && !(davor is Nachricht && davor.autorId == n.autorId);
                    final d = inhalt.dekodieren(n.inhalt);
                    final autor = mitglieder[n.autorId];
                    final zitat = n.antwortAuf == null ? null : nachId[n.antwortAuf];
                    return _Blase(
                      nachricht: n,
                      eigen: eigen,
                      autorName: eigen ? 'Du' : (autor?.displayName ?? 'Ehemaliges Mitglied'),
                      autorFarbe: autor == null ? kTextMuted : personColor(autor.colorIndex),
                      zeigeName: zeigeName,
                      inhalt: d,
                      zitat: n.antwortAuf == null
                          ? null
                          : _Zitat(
                              autor: zitat == null ? '' : (zitat.autorId == ich ? 'Du' : (mitglieder[zitat.autorId]?.displayName ?? 'Unbekannt')),
                              text: zitat == null ? 'Nachricht nicht verfügbar' : nachrichtKurztext(zitat, inhalt),
                            ),
                      onTap: () => _aktionen(n, art, rechte, d.lesbar, d.text),
                    );
                  },
                ),
        ),
        eingabe,
      ],
    );
  }
}

class _Kopf extends StatelessWidget {
  final VoidCallback? beiSchliessen;
  final String titel;
  final String untertitel;
  final Widget? avatar;
  final Widget? menue;
  const _Kopf({required this.beiSchliessen, required this.titel, required this.untertitel, required this.avatar, required this.menue});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kBorderSoft))),
    constraints: const BoxConstraints(minHeight: 56),
    child: Row(
      children: [
        if (beiSchliessen != null) IconButton(tooltip: 'Zurück zur Chatliste', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.arrow_back), onPressed: beiSchliessen)
        else const SizedBox(width: 12),
        if (avatar != null) ...[avatar!, const SizedBox(width: 10)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(header: true, child: Text(titel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: kTextStrong))),
              if (untertitel.isNotEmpty) Text(untertitel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
            ],
          ),
        ),
        ?menue,
      ],
    ),
  );
}

class _AktionsZeile extends StatelessWidget {
  final IconData icon;
  final String text;
  final String wert;
  final BuildContext c;
  final bool gefahr;
  const _AktionsZeile({required this.icon, required this.text, required this.wert, required this.c, this.gefahr = false});

  @override
  Widget build(BuildContext context) => ListTile(
    minTileHeight: 52,
    leading: Icon(icon, color: gefahr ? kDanger : kText),
    title: Text(text, style: TextStyle(color: gefahr ? kDanger : kText)),
    onTap: () => Navigator.of(c).pop(wert),
  );
}

class _Trenner extends StatelessWidget {
  final String text;
  const _Trenner(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Center(
      child: Semantics(header: true, child: MonoLabel(text.toLowerCase())),
    ),
  );
}

class _Zitat {
  final String autor;
  final String text;
  const _Zitat({required this.autor, required this.text});
}

class _Blase extends StatelessWidget {
  final Nachricht nachricht;
  final bool eigen;
  final String autorName;
  final Color autorFarbe;
  final bool zeigeName;
  final DekodierterInhalt inhalt;
  final _Zitat? zitat;
  final VoidCallback onTap;
  const _Blase({
    required this.nachricht,
    required this.eigen,
    required this.autorName,
    required this.autorFarbe,
    required this.zeigeName,
    required this.inhalt,
    required this.zitat,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final gesendet = nachricht.rev > 0;
    final text = switch (inhalt.status) {
      InhaltStatus.bereit => inhalt.text,
      InhaltStatus.wirdEntschluesselt => 'wird entschlüsselt …',
      InhaltStatus.nichtEntschluesselbar => 'Nachricht nicht lesbar – warte auf Schlüssel',
    };
    final lesbar = inhalt.lesbar;
    final zeit = uhrzeit(nachricht.createdAt);
    final bearbeitet = nachricht.bearbeitetAt != null;
    final beschreibung = '${eigen ? 'Du' : autorName}, $zeit${gesendet ? '' : ', wird gesendet'}${bearbeitet ? ', bearbeitet' : ''}: $text';
    return Padding(
      padding: EdgeInsets.only(top: zeigeName ? 8 : 2, bottom: 2),
      child: Align(
        alignment: eigen ? Alignment.centerRight : Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, c) => ConstrainedBox(
            constraints: BoxConstraints(maxWidth: c.maxWidth * 0.84),
            child: Semantics(
              container: true,
              button: true,
              label: beschreibung,
              hint: 'Aktionen öffnen',
              excludeSemantics: true,
              onTap: onTap,
              child: Material(
                color: eigen ? kAccentSoft : kSurface.withValues(alpha: 0.92),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(14),
                    topRight: const Radius.circular(14),
                    bottomLeft: Radius.circular(eigen ? 14 : 4),
                    bottomRight: Radius.circular(eigen ? 4 : 14),
                  ),
                  side: BorderSide(color: eigen ? kAccent.withValues(alpha: 0.4) : kBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (zeigeName) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(autorName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: autorFarbe))),
                        if (zitat != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                            decoration: const BoxDecoration(border: Border(left: BorderSide(color: kAccent, width: 2))),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (zitat!.autor.isNotEmpty) Text(zitat!.autor, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: kAccent)),
                                Text(zitat!.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: kTextMuted)),
                              ],
                            ),
                          ),
                        Text(text, style: TextStyle(fontStyle: lesbar ? FontStyle.normal : FontStyle.italic, color: lesbar ? kText : kTextMuted)),
                        const SizedBox(height: 2),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            alignment: WrapAlignment.end,
                            children: [
                              if (bearbeitet) const Text('bearbeitet', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextFaint)),
                              if (!gesendet && eigen) const Text('wird gesendet', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                              Text(zeit, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextFaint)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String label;
  final String text;
  final VoidCallback onAbbrechen;
  const _Banner({required this.label, required this.text, required this.onAbbrechen});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
    padding: const EdgeInsets.only(left: 10),
    decoration: BoxDecoration(color: kSurface, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
    child: Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MonoLabel(label, color: kAccent),
                Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kTextMuted)),
              ],
            ),
          ),
        ),
        IconButton(tooltip: 'Abbrechen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.close, size: 20), onPressed: onAbbrechen),
      ],
    ),
  );
}

class _Eingabe extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode fokus;
  final bool enterSendet;
  final VoidCallback onSenden;
  final Widget? banner;
  const _Eingabe({required this.controller, required this.fokus, required this.enterSendet, required this.onSenden, required this.banner});

  @override
  Widget build(BuildContext context) {
    Widget feld = TextField(
      controller: controller,
      focusNode: fokus,
      minLines: 1,
      maxLines: 5,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      inputFormatters: [LengthLimitingTextInputFormatter(kMaxNachrichtenZeichen)],
      decoration: const InputDecoration(hintText: 'Nachricht', contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
    );
    // Desktop und Web: Enter sendet, Umschalt+Enter macht eine neue Zeile
    if (enterSendet) {
      feld = CallbackShortcuts(bindings: {const SingleActivator(LogicalKeyboardKey.enter): onSenden}, child: feld);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?banner,
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: feld),
              const SizedBox(width: 8),
              IconButton.filled(tooltip: 'Senden', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: onSenden, icon: const Icon(Icons.send)),
            ],
          ),
        ),
      ],
    );
  }
}
