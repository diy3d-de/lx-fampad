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
import '../../data/crypto/e2ee_state.dart';
import '../../data/chat/chat_krypto.dart' show ChatKrypto;
import '../../data/chat/chat_zusatz_inhalt.dart';
import '../../data/chat/chat_zusatz_repository.dart';
import '../../data/chat/lese_status.dart';
import '../../data/chat/nachrichten_inhalt.dart';
import '../../data/suche/chat_sprung.dart';
import '../../data/suche/such_logik.dart';
import '../../data/lists/members.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart' show BildschirmSchutz;
import '../lists/list_dialogs.dart';
import '../shell/shell_tab.dart';
import '../suche/treffer_text.dart';
import 'chat_anzeige.dart';
import 'chat_suche_ui.dart';
import 'chat_krypto_ui.dart';
import 'verlauf_freigabe_ui.dart';
import 'chat_zusatz_ui.dart';
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

  /// Suche im Chat: Leiste offen, Suchwörter (Hervorhebung in den sichtbaren Nachrichten) und der angesteuerte Treffer.
  bool _sucheOffen = false;
  List<String> _suchWoerter = const [];
  String? _treffer;
  Timer? _trefferEnde;

  /// Neuzeichnen, sobald eine ungesendete Nachricht als "hängt" gilt (die Uhr allein löst keine Änderung der Datenbank aus).
  Timer? _tick;
  DateTime? _tickZiel;

  String get _id => widget.konversationId;
  ChatRepository get _repo => ref.read(chatRepositoryProvider);
  ChatZusatzRepository get _zusatz => ref.read(chatZusatzRepositoryProvider);

  void _hinweis(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  final Map<String, GlobalKey> _schluessel = {};
  List<String> _reihenfolge = const [];

  /// Springt zu einer Nachricht (Pin-Liste): ist sie schon gebaut, wird sie sichtbar gemacht; sonst wird grob dorthin gescrollt und erneut versucht.
  Future<void> _zuNachricht(String id) async {
    for (var versuch = 0; versuch < 30 && mounted; versuch++) {
      final ctx = _schluessel[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        return;
      }
      final i = _reihenfolge.indexOf(id);
      // die Liste ist noch nicht da (Chat gerade geöffnet): ein paar Bilder warten
      if (i < 0 || !_scroll.hasClients) {
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      _scroll.jumpTo((i * 90.0).clamp(0.0, _scroll.position.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// Setzt die eigene Reaktion oder nimmt sie zurück (gleiches Emoji noch einmal). Nur auf bestätigte Nachrichten.
  Future<void> _reagieren(Nachricht n, String emoji, String? meine) async {
    if (n.rev == 0) {
      _hinweis('Du kannst reagieren, sobald die Nachricht gesendet ist.');
      return;
    }
    try {
      await _zusatz.reaktionUmschalten(n.konversationId, n.id, emoji, aktuell: meine);
    } on ChatNichtVerschluesselt {
      _hinweis('Dieser Chat ist nicht verschlüsselt. Reaktionen sind hier nicht möglich.');
    }
  }

  /// Stimme abgeben, ändern oder zurücknehmen. Bei Einzelwahl ersetzt die neue Antwort die alte, bei Mehrfachwahl wird die Antwort umgeschaltet.
  Future<void> _abstimmen(Nachricht n, Umfrage u, UmfrageErgebnis e, int option) async {
    if (n.rev == 0) {
      _hinweis('Du kannst abstimmen, sobald die Umfrage gesendet ist.');
      return;
    }
    if (u.beendet(DateTime.now())) {
      _hinweis('Die Umfrage ist beendet.');
      return;
    }
    try {
      await _zusatz.stimmeUmschalten(n.konversationId, n.id, option, mehrfach: u.mehrfach, anzahl: u.optionen.length, aktuell: e.meine);
    } on ChatNichtVerschluesselt {
      _hinweis('Dieser Chat ist nicht verschlüsselt. Abstimmen ist hier nicht möglich.');
    }
  }

  Future<void> _umfrageNeu() async {
    final entwurf = await umfrageErstellen(context);
    if (entwurf == null || !mounted) return;
    try {
      await _repo.senden(_id, umfrageKodieren(frage: entwurf.frage, optionen: entwurf.optionen, mehrfach: entwurf.mehrfach, ende: entwurf.ende));
    } on ChatNichtVerschluesselt {
      _hinweis('Dieser Chat ist nicht verschlüsselt. Neue Nachrichten sind hier nicht möglich.');
      return;
    } on NachrichtZuLang {
      _hinweis('Die Umfrage ist zu lang. Bitte kürze sie.');
      return;
    }
    if (mounted && _scroll.hasClients) unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 150), curve: Curves.easeOut));
  }

  Future<void> _pinListeOeffnen(List<PinEintrag> pins) async {
    final wahl = await pinListe(context, pins);
    if (wahl == null || !mounted) return;
    if (wahl.loesen) {
      await _zusatz.pinLoesen(wahl.nachrichtId);
    } else {
      await _zuNachricht(wahl.nachrichtId);
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_beiScrollen);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markieren();
      _sprungPruefen();
    });
  }

  /// Sprung aus der Suche über alle Chats: zur Nachricht scrollen und sie kurz hervorheben.
  void _sprungPruefen() {
    final z = ref.read(chatSprungProvider);
    if (!mounted || z == null || z.chatId != _id) return;
    ref.read(chatSprungProvider.notifier).verbraucht();
    _trefferAnsteuern(z.nachrichtId, dauerhaft: false);
  }

  void _trefferAnsteuern(String id, {required bool dauerhaft}) {
    _trefferEnde?.cancel();
    setState(() => _treffer = id);
    if (!dauerhaft) {
      _trefferEnde = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _treffer = null);
      });
    }
    unawaited(_zuNachricht(id));
  }

  void _sucheSchliessen() {
    _trefferEnde?.cancel();
    setState(() {
      _sucheOffen = false;
      _suchWoerter = const [];
      _treffer = null;
    });
  }

  @override
  void dispose() {
    _trefferEnde?.cancel();
    _scroll.dispose();
    _text.dispose();
    _fokus.dispose();
    _tick?.cancel();
    super.dispose();
  }

  void _planeTick(DateTime? ziel, DateTime jetzt) {
    if (ziel == null) return;
    if (_tickZiel != null && !_tickZiel!.isAfter(ziel) && _tickZiel!.isAfter(jetzt)) return; // ein früherer Zeitpunkt ist schon geplant
    _tick?.cancel();
    _tickZiel = ziel;
    _tick = Timer(ziel.difference(jetzt) + const Duration(seconds: 1), () {
      _tickZiel = null;
      if (mounted) setState(() {});
    });
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
    // nur wenn der Chat wirklich zu sehen ist: Chat-Bereich gewählt und diese Seite oben (nicht hinter Profil o. Ä.)
    if (ref.read(shellTabProvider) != kChatTab) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
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
    try {
      if (bearbeitet != null) {
        await _repo.bearbeiten(bearbeitet.id, t);
      } else {
        await _repo.senden(_id, t, antwortAuf: antwort?.id);
      }
    } on ChatNichtVerschluesselt {
      if (mounted) {
        _text.text = t;
        setState(() {
          _antwort = antwort;
          _bearbeitet = bearbeitet;
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Dieser Chat ist nicht verschlüsselt. Neue Nachrichten sind hier nicht möglich.')));
      }
      return;
    } on NachrichtZuLang {
      // nichts gesendet: der Text bleibt im Feld
      if (mounted) {
        _text.text = t;
        setState(() {
          _antwort = antwort;
          _bearbeitet = bearbeitet;
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Die Nachricht ist zu lang. Bitte kürze sie.')));
      }
      return;
    }
    if (mounted && _scroll.hasClients) unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 150), curve: Curves.easeOut));
  }

  Future<void> _aktionen(
    Nachricht n,
    ChatArt art,
    ChatRechte rechte,
    bool lesbar,
    String text, {
    LeseInfo? lese,
    bool istUmfrage = false,
    String? meineReaktion,
    ChatPin? pin,
    bool verschluesselt = true,
  }) async {
    final abgelehnt = lese?.zustand == LeseZustand.abgelehnt;
    // Reaktionen, Umfragen und Anheften gibt es nur in verschlüsselten Chats (Altbestand: nur lesen)
    final bestaetigt = n.rev > 0 && !abgelehnt && lesbar && verschluesselt;
    final aktion = await showModalBottomSheet<String>(useRootNavigator: false,
      context: context,
      backgroundColor: kSurface,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (abgelehnt) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline, color: kDanger, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text('Senden fehlgeschlagen. ${ablehnungsGrund(lese?.fehlerCode)}', style: const TextStyle(fontSize: 14, height: 1.4, color: kText)),
                      ),
                    ),
                  ],
                ),
              ),
              _AktionsZeile(icon: Icons.refresh, text: 'Erneut senden', wert: 'erneut', c: c),
              if (lesbar) _AktionsZeile(icon: Icons.copy_outlined, text: 'Text kopieren', wert: 'kopieren', c: c),
              _AktionsZeile(icon: Icons.delete_outline, text: 'Verwerfen', wert: 'verwerfen', c: c, gefahr: true),
            ] else ...[
              if (bestaetigt) ReaktionsAuswahl(meine: meineReaktion, onWaehlen: (e) => Navigator.of(c).pop('emoji:$e')),
              _AktionsZeile(icon: Icons.reply, text: 'Antworten', wert: 'antworten', c: c),
              if (lesbar && !istUmfrage) _AktionsZeile(icon: Icons.copy_outlined, text: 'Text kopieren', wert: 'kopieren', c: c),
              if (bestaetigt && pin == null && rechte.darfPinnen(art)) _AktionsZeile(icon: Icons.push_pin_outlined, text: 'Anheften', wert: 'anheften', c: c),
              if (pin != null && rechte.darfPinLoesen(pin)) _AktionsZeile(icon: Icons.push_pin, text: 'Anheftung lösen', wert: 'pinLoesen', c: c),
              if (lesbar && !istUmfrage && rechte.darfBearbeiten(n)) _AktionsZeile(icon: Icons.edit_outlined, text: 'Bearbeiten', wert: 'bearbeiten', c: c),
              if (rechte.darfLoeschen(n, art)) _AktionsZeile(icon: Icons.delete_outline, text: 'Löschen', wert: 'loeschen', c: c, gefahr: true),
            ],
          ],
        ),
      ),
    );
    if (!mounted || aktion == null) return;
    if (aktion.startsWith('emoji:')) {
      await _reagieren(n, aktion.substring(6), meineReaktion);
      return;
    }
    switch (aktion) {
      case 'anheften':
        try {
          await _zusatz.pinnen(n.konversationId, n.id);
        } on PinGrenze {
          _hinweis('Es sind schon $kMaxPins Nachrichten angeheftet. Löse zuerst eine Anheftung.');
        } on ChatNichtVerschluesselt {
          _hinweis('Dieser Chat ist nicht verschlüsselt. Anheften ist hier nicht möglich.');
        }
      case 'pinLoesen':
        await _zusatz.pinLoesen(n.id);
      case 'erneut':
        await _repo.erneutSenden(n.id);
      case 'verwerfen':
        if (_bearbeitet?.id == n.id) setState(() => _bearbeitet = null);
        if (_antwort?.id == n.id) setState(() => _antwort = null);
        await _repo.verwerfen(n.id);
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
        if (wahl == null || !mounted) return;
        final bisher = {...teilnehmer}..remove(ich);
        final hinzu = wahl.personen.difference(bisher);
        final weg = bisher.difference(wahl.personen);
        if (hinzu.isEmpty && weg.isEmpty) return;
        final alle = {...bisher, ...hinzu}..removeAll(weg);
        final bestaetigung = await mitgliederBestaetigen(
          context,
          titel: hinzu.isEmpty ? 'Teilnehmer ändern?' : 'Mitglieder prüfen und hinzufügen',
          personen: alle.toList(),
          neu: hinzu,
          entfernt: weg,
          verlaufFrage: true,
          knopf: hinzu.isEmpty ? 'Ändern' : 'Hinzufügen',
        );
        if (bestaetigung == null || !mounted) return;
        try {
          await _repo.teilnehmerAendern(k.id, hinzu: hinzu, weg: weg, verlaufTeilen: bestaetigung.verlaufTeilen);
        } on Object catch (e) {
          final text = kryptoFehlerText(e, ref.read(e2eeProvider).mitglieder);
          if (text == null) rethrow;
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(text)));
        }
      case 'verlassen':
        if (teilnehmer.length <= 2) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('Dann bliebe nur eine Person übrig. Lösche die Gruppe stattdessen.')));
          return;
        }
        final ja = await bestaetigen(context, titel: 'Gruppe verlassen?', text: 'Du siehst die Gruppe danach nicht mehr, bis dich jemand wieder aufnimmt.', knopf: 'Verlassen');
        if (!ja || ich == null) return;
        await _repo.teilnehmerAendern(k.id, weg: {ich});
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
    // Neuzeichnen planen, sobald eine ungesendete Nachricht als "hängt" gilt
    ref.listen(nachrichtenAusgangProvider, (_, neu) {
      final jetzt = DateTime.now();
      for (final o in neu.value?.values ?? const <OutboxData>[]) {
        _planeTick(haengtAb(o, jetzt), jetzt);
      }
    });
    ref.listen(nachrichtenProvider(_id), (_, _) => WidgetsBinding.instance.addPostFrameCallback((_) => _markieren()));
    ref.listen(chatSprungProvider, (_, _) => WidgetsBinding.instance.addPostFrameCallback((_) => _sprungPruefen()));
    // beim Zurückwechseln in den Chat-Bereich gilt der Verlauf erst jetzt als gelesen
    ref.listen(shellTabProvider, (_, t) {
      if (t == kChatTab) WidgetsBinding.instance.addPostFrameCallback((_) => _markieren());
    });
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
      ChatArt.meds => 'medikamente',
      ChatArt.zaehler => 'zähler',
      ChatArt.tresor => 'tresor',
    };
    final verschluesselt = konv.encVersion == 'e1';
    final kryptoZustand = chatKryptoZustand(ref.watch(e2eeProvider));
    final darfSchreiben = verschluesselt && kryptoZustand.darfSchreiben;
    final liste = ref.watch(nachrichtenProvider(_id)).value ?? const <Nachricht>[];
    final nachId = {for (final n in liste) n.id: n};
    // Lesebestätigung: Lesestände der anderen Teilnehmer (Familienchat: alle aktiven Mitglieder)
    final gelesenBis = {for (final l in ref.watch(lesestaendeProvider(_id)).value ?? const <Lesestand>[]) l.userId: l.gelesenBis};
    final empfaenger = {if (art == ChatArt.family) ...mitglieder.alle.map((u) => u.id) else ...teilnehmer}..remove(ich);
    final ausgang = ref.watch(nachrichtenAusgangProvider).value ?? const <String, OutboxData>{};
    // Reaktionen, Stimmen und Anheftungen (Inhalte werden im Hintergrund entschlüsselt; nicht lesbare zählen nicht mit)
    final reaktionenJe = gruppiereReaktionen(ref.watch(reaktionenProvider(_id)).value ?? const <Reaktion>[], (r) {
      final z = inhalt.zusatz(ZusatzRef(id: r.id, konversationId: r.konversationId, nachrichtId: r.nachrichtId, userId: r.userId, wire: r.inhalt, rev: r.rev, art: 'r'));
      return z.lesbar ? z.text : null;
    }, ich);
    final stimmenJe = <String, List<Stimme>>{};
    for (final st in ref.watch(stimmenProvider(_id)).value ?? const <Stimme>[]) {
      (stimmenJe[st.nachrichtId] ??= []).add(st);
    }
    String? stimmeText(Stimme st) {
      final z = inhalt.zusatz(ZusatzRef(id: st.id, konversationId: st.konversationId, nachrichtId: st.nachrichtId, userId: st.userId, wire: st.inhalt, rev: st.rev, art: 's'));
      return z.lesbar ? z.text : null;
    }
    final pinZeilen = ref.watch(pinsProvider(_id)).value ?? const <ChatPin>[];
    final pinJe = {for (final p in pinZeilen) p.nachrichtId: p};
    final pinEintraege = [
      for (final p in pinZeilen)
        if (nachId[p.nachrichtId] case final m?)
          PinEintrag(
            nachrichtId: m.id,
            text: nachrichtKurztext(m, inhalt),
            autor: m.autorId == ich ? 'Du' : (mitglieder[m.autorId]?.displayName ?? 'Unbekannt'),
            darfLoesen: rechte.darfPinLoesen(p),
          ),
    ];
    final jetzt = DateTime.now();
    final epochenMitglieder = epochenEmpfaenger(ref.watch(epochenListenProvider(_id)).value ?? const <Epoche>[]);
    String leseName(String id) => mitglieder[id]?.displayName ?? 'Unbekannt';

    // Verlauf mit Datumstrennern (chronologisch), umgekehrt angezeigt: neueste unten
    final eintraege = <Object>[];
    DateTime? vorher;
    for (final n in liste) {
      if (vorher == null || !gleicherTag(vorher, n.createdAt)) eintraege.add(n.createdAt);
      eintraege.add(n);
      vorher = n.createdAt;
    }
    final umgekehrt = eintraege.reversed.toList();
    _reihenfolge = [for (final e in umgekehrt) if (e is Nachricht) e.id];
    final breit = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;

    final eingabe = _Eingabe(
      controller: _text,
      fokus: _fokus,
      enterSendet: breit,
      onSenden: _senden,
      onUmfrage: _bearbeitet == null ? _umfrageNeu : null,
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

    final seite = Column(
      children: [
        _Kopf(
          beiSchliessen: widget.zurueckPfeil ? widget.beiSchliessen : null,
          titel: name,
          untertitel: untertitel,
          verschluesselt: verschluesselt,
          avatar: ChatAvatar(art: art, person: anderer, name: name, size: 36),
          beiSuche: _sucheOffen ? null : () => setState(() => _sucheOffen = true),
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
        if (_sucheOffen)
          ChatSuchLeiste(
            konversationId: _id,
            beiTreffer: (id) => _trefferAnsteuern(id, dauerhaft: true),
            beiWoerter: (w) => setState(() => _suchWoerter = w),
            beiSchliessen: _sucheSchliessen,
          ),
        if (verschluesselt) SchluesselWechselHinweis(personen: art == ChatArt.family ? const {} : {...teilnehmer}),
        if (verschluesselt) AufnahmeHinweis(konversationId: konv.id, chatName: name),
        if (verschluesselt) VerlaufFreigabeHinweis(konversationId: konv.id),
        if (!verschluesselt)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kSurface, border: Border.all(color: kWarn.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(12)),
            child: const Text(
              'Dieser Chat ist nicht verschlüsselt (er stammt aus einer früheren Version). Du kannst ihn lesen, aber nichts mehr schreiben. Starte einen neuen, verschlüsselten Chat.',
              style: TextStyle(fontSize: 13, height: 1.4, color: kText),
            ),
          ),
        if (pinEintraege.isNotEmpty) PinLeiste(pins: pinEintraege, onTap: () => _pinListeOeffnen(pinEintraege)),
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
                    final d = inhalt.nachricht(n);
                    final umfrage = d.lesbar ? umfrageLesen(d.text) : null;
                    final gruppen = reaktionenJe[n.id] ?? const <ReaktionGruppe>[];
                    final meineReaktion = gruppen.where((g) => g.ich).map((g) => g.emoji).firstOrNull;
                    // das Ende einer Umfrage baut den Verlauf neu auf (sonst bliebe sie bis zur nächsten Änderung abstimmbar)
                    if (umfrage?.ende case final ende? when ende.isAfter(jetzt)) _planeTick(ende, jetzt);
                    final ergebnis = umfrage == null ? null : umfrageAuswerten(umfrage, stimmenJe[n.id] ?? const <Stimme>[], stimmeText, ich);
                    final autor = mitglieder[n.autorId];
                    // ein Zitat zeigt nur eine Nachricht derselben Konversation (der Server prüft das ebenfalls)
                    final zitatKandidat = n.antwortAuf == null ? null : nachId[n.antwortAuf];
                    final zitat = zitatKandidat != null && zitatKandidat.konversationId == n.konversationId ? zitatKandidat : null;
                    // Empfänger zum Sendezeitpunkt (Mitglieder der Epoche der Nachricht), nicht der heutige Stand
                    final zumZeitpunkt = eigen ? empfaengerZurNachricht(epoche: ChatKrypto.huellenEpoche(n.inhalt), epochen: epochenMitglieder, ich: ich ?? '', aktuell: empfaenger, gelesenBis: gelesenBis) : null;
                    final lese = zumZeitpunkt == null ? null : leseInfo(nachricht: n, empfaenger: zumZeitpunkt.empfaenger, gelesenBis: gelesenBis, geschaetzt: zumZeitpunkt.geschaetzt, ausgang: ausgang[n.id], jetzt: jetzt);
                    return _Blase(
                      key: _schluessel.putIfAbsent(n.id, GlobalKey.new),
                      nachricht: n,
                      lese: lese,
                      leseText: lese == null ? '' : leseBeschreibung(lese, leseName),
                      eigen: eigen,
                      autorName: eigen ? 'Du' : (autor?.displayName ?? 'Ehemaliges Mitglied'),
                      autorFarbe: autor == null ? kTextMuted : personColor(autor.colorIndex),
                      zeigeName: zeigeName,
                      inhalt: d,
                      angeheftet: pinJe.containsKey(n.id),
                      markiert: _treffer == n.id,
                      suchWoerter: _sucheOffen ? _suchWoerter : const [],
                      reaktionen: gruppen,
                      personName: (id) => id == ich ? 'Du' : (mitglieder[id]?.displayName ?? 'Unbekannt'),
                      onReaktion: (e) => _reagieren(n, e, meineReaktion),
                      umfrage: umfrage == null || ergebnis == null
                          ? null
                          : UmfrageKarte(
                              umfrage: umfrage,
                              ergebnis: ergebnis,
                              beendet: umfrage.beendet(jetzt),
                              wartet: n.rev == 0,
                              name: (id) => id == ich ? 'Du' : (mitglieder[id]?.displayName ?? 'Unbekannt'),
                              onWaehle: (o) => _abstimmen(n, umfrage, ergebnis, o),
                            ),
                      umfrageKopf: umfrage?.frage,
                      zitat: n.antwortAuf == null
                          ? null
                          : _Zitat(
                              autor: zitat == null ? '' : (zitat.autorId == ich ? 'Du' : (mitglieder[zitat.autorId]?.displayName ?? 'Unbekannt')),
                              text: zitat == null ? 'Nachricht nicht verfügbar' : nachrichtKurztext(zitat, inhalt),
                            ),
                      onTap: () => _aktionen(n, art, rechte, d.lesbar, d.text, lese: lese, istUmfrage: umfrage != null, meineReaktion: meineReaktion, pin: pinJe[n.id], verschluesselt: verschluesselt),
                    );
                  },
                ),
        ),
        if (darfSchreiben) eingabe else if (verschluesselt) const VerschluesselungHinweis(gross: false),
      ],
    );
    // private Chats (Direkt, Gruppe): kein Bildschirmfoto (Android, FLAG_SECURE; Web und Desktop ohne Wirkung); der Familienchat bleibt frei
    return art == ChatArt.family ? seite : BildschirmSchutz(child: seite);
  }
}

class _Kopf extends StatelessWidget {
  final VoidCallback? beiSchliessen;
  final String titel;
  final String untertitel;
  final bool verschluesselt;
  final Widget? avatar;
  final Widget? menue;

  /// Öffnet die Suche im Chat (null = Suche schon offen oder nicht möglich).
  final VoidCallback? beiSuche;
  const _Kopf({required this.beiSchliessen, required this.titel, required this.untertitel, required this.avatar, required this.menue, this.verschluesselt = false, this.beiSuche});

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
              if (untertitel.isNotEmpty)
                Row(
                  children: [
                    if (verschluesselt) ...[
                      Semantics(label: 'Ende-zu-Ende verschlüsselt', child: const Icon(Icons.lock_outline, size: 12, color: kTerminal)),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        verschluesselt ? 'ende-zu-ende verschlüsselt · $untertitel' : untertitel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        if (beiSuche != null) IconButton(tooltip: 'Im Chat suchen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.search), onPressed: beiSuche),
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
      child: Semantics(header: true, child: MonoLabel(text)),
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
  final LeseInfo? lese;
  final String leseText;
  final bool angeheftet;

  /// Der aktuell angesteuerte Suchtreffer (kräftiger Rand) und die Suchwörter für die Hervorhebung im Text.
  final bool markiert;
  final List<String> suchWoerter;
  final List<ReaktionGruppe> reaktionen;
  final String Function(String userId) personName;
  final ValueChanged<String> onReaktion;

  /// Umfrage statt Text (Karte) und ihre Frage für Screenreader.
  final Widget? umfrage;
  final String? umfrageKopf;
  const _Blase({
    super.key,
    required this.nachricht,
    required this.lese,
    required this.leseText,
    required this.eigen,
    required this.autorName,
    required this.autorFarbe,
    required this.zeigeName,
    required this.inhalt,
    required this.zitat,
    required this.onTap,
    required this.angeheftet,
    this.markiert = false,
    this.suchWoerter = const [],
    required this.reaktionen,
    required this.personName,
    required this.onReaktion,
    required this.umfrage,
    required this.umfrageKopf,
  });

  @override
  Widget build(BuildContext context) {
    final gesendet = nachricht.rev > 0;
    final text = switch (inhalt.status) {
      InhaltStatus.bereit => inhalt.text,
      InhaltStatus.wirdEntschluesselt => 'wird entschlüsselt …',
      InhaltStatus.nichtEntschluesselbar => 'Nachricht nicht lesbar – ${inhalt.hinweis ?? 'warte auf Schlüssel'}',
    };
    final lesbar = inhalt.lesbar;
    final zeit = uhrzeit(nachricht.createdAt);
    final bearbeitet = nachricht.bearbeitetAt != null;
    final beschreibung =
        '${eigen ? 'Du' : autorName}, $zeit${lese != null ? ', $leseText' : (gesendet ? '' : ', wird gesendet')}${bearbeitet ? ', bearbeitet' : ''}${angeheftet ? ', angeheftet' : ''}${markiert ? ', Suchtreffer' : ''}: ${umfrageKopf != null ? 'Umfrage: $umfrageKopf' : text}';
    return Padding(
      padding: EdgeInsets.only(top: zeigeName ? 8 : 2, bottom: 2),
      child: Align(
        alignment: eigen ? Alignment.centerRight : Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, c) => ConstrainedBox(
            constraints: BoxConstraints(maxWidth: c.maxWidth * 0.84),
            child: Column(
              crossAxisAlignment: eigen ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
            Semantics(
              container: true,
              button: true,
              label: beschreibung,
              hint: 'Aktionen öffnen',
              // die Umfrage hat eigene bedienbare Antworten: ihre Semantik bleibt erhalten
              excludeSemantics: umfrage == null,
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
                  side: BorderSide(color: markiert ? kAccent : (eigen ? kAccent.withValues(alpha: 0.4) : Colors.transparent), width: markiert ? 2 : 1),
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
                        if (umfrage != null)
                          umfrage!
                        else if (lesbar && suchWoerter.isNotEmpty && finde(text, suchWoerter) != null)
                          TrefferText(text, finde(text, suchWoerter)!, stil: const TextStyle(fontSize: 14, color: kText), maxLines: null)
                        else
                          Text(text, style: TextStyle(fontStyle: lesbar ? FontStyle.normal : FontStyle.italic, color: lesbar ? kText : kTextMuted)),
                        const SizedBox(height: 2),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            alignment: WrapAlignment.end,
                            children: [
                              if (angeheftet) const Icon(Icons.push_pin, size: 12, color: kAccent, semanticLabel: 'angeheftet'),
                              if (bearbeitet) const Text('bearbeitet', style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                              if (!gesendet && eigen) _SendeText(lese: lese),
                              Text(zeit, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                              if (lese != null) LeseHaken(info: lese!, text: leseText),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
                if (reaktionen.isNotEmpty) ReaktionsChips(gruppen: reaktionen, name: personName, onTap: onReaktion),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Zustandstext einer noch nicht bestätigten eigenen Nachricht: "wird gesendet", sanfter Hinweis bei "hängt", Fehler bei "abgelehnt".
class _SendeText extends StatelessWidget {
  final LeseInfo? lese;
  const _SendeText({required this.lese});

  @override
  Widget build(BuildContext context) {
    final (text, farbe) = switch (lese?.zustand) {
      LeseZustand.haengt => ('wartet auf Verbindung oder Schlüssel', kWarn),
      LeseZustand.abgelehnt => ('nicht gesendet · tippen', kDanger),
      _ => ('wird gesendet', kTextMuted),
    };
    return ExcludeSemantics(child: Text(text, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: farbe)));
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
    decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
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

  /// Umfrage erstellen (null beim Bearbeiten einer Nachricht: dann gibt es den Knopf nicht).
  final VoidCallback? onUmfrage;
  const _Eingabe({required this.controller, required this.fokus, required this.enterSendet, required this.onSenden, required this.banner, required this.onUmfrage});

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
              if (onUmfrage != null) IconButton(tooltip: 'Umfrage erstellen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.poll_outlined), onPressed: onUmfrage),
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
