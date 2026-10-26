// Chat-Suche (nur lokal, nur Arbeitsspeicher): die Leiste im Verlauf eines Chats und die Seite "In allen Chats suchen" auf der Chat-Liste. Gesucht wird in den
// Nachrichten, die dieses Gerät entschlüsseln kann (über NachrichtenInhalt, wie die Anzeige); es gibt keinen Klartext-Index auf der Platte, nichts geht an den Server und
// nichts wird protokolliert. Nachrichten, die nicht entschlüsselt werden können, bleiben außen vor und werden ehrlich gezählt. Reaktionen und Stimmen werden nicht durchsucht.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/chat/nachrichten_inhalt.dart';
import '../../data/suche/chat_sprung.dart';
import '../../data/suche/chat_suche.dart';
import '../../data/suche/such_logik.dart';
import '../../ui/widgets.dart';
import '../suche/treffer_text.dart';
import 'chat_anzeige.dart';

/// Steuert eine Suche: Eingabe entprellen, Nachrichten holen, Klartext im Arbeitsspeicher aufbauen, Treffer berechnen. Eine neue Eingabe ersetzt die laufende Arbeit
/// (die Berechnung wird verworfen, der schon geöffnete Klartext bleibt für die nächste Eingabe stehen). [dispose] löscht allen Klartext.
class ChatSuchSteuerung {
  final ChatSucher sucher;

  /// Holt die Nachrichten, in denen gesucht wird (einmal je neuer Eingabe).
  final Future<List<Nachricht>> Function() lade;

  /// Die Oberfläche soll neu zeichnen.
  final void Function() beiAenderung;
  String eingabe = '';
  ChatSuchStand stand = const ChatSuchStand();

  /// Die Eingabe ist lang genug, um zu suchen.
  bool gueltig = false;
  Timer? _entprellen;
  Timer? _nachfassen;
  Timer? _drosseln;
  int _runde = 0;
  int _nachfassRunden = 0;
  bool _weg = false;
  List<Nachricht> _liste = const [];

  ChatSuchSteuerung({required this.sucher, required this.lade, required this.beiAenderung});

  /// Neue Eingabe der Person (entprellt).
  void tippen(String text) {
    eingabe = text;
    _entprellen?.cancel();
    _entprellen = Timer(const Duration(milliseconds: 250), _neu);
  }

  Future<void> _neu() async {
    final runde = ++_runde;
    _nachfassRunden = 0;
    gueltig = suchWoerter(eingabe).isNotEmpty && normalisiere(eingabe).trim().length >= 2;
    if (!gueltig) {
      _nachfassen?.cancel();
      stand = sucher.suche('');
      if (!_weg) beiAenderung();
      return;
    }
    final liste = await lade();
    if (_weg || runde != _runde) return; // eine neuere Eingabe hat übernommen
    _liste = liste;
    _pumpen();
  }

  /// Die Liste der Nachrichten hat sich geändert (neue, bearbeitete, gelöschte).
  void listeGeaendert(List<Nachricht> liste) {
    _liste = liste;
    entschluesselungGeaendert();
  }

  /// Etwas wurde entschlüsselt oder die Liste hat sich geändert: Treffer neu berechnen (gedrosselt).
  void entschluesselungGeaendert() {
    if (!gueltig || _weg || (_drosseln?.isActive ?? false)) return;
    _drosseln = Timer(const Duration(milliseconds: 150), () {
      if (!_weg && gueltig) _pumpen();
    });
  }

  void _pumpen() {
    sucher.aktualisieren(_liste);
    stand = sucher.suche(eingabe);
    beiAenderung();
    _nachfassen?.cancel();
    // Es werden noch Nachrichten geöffnet: nachfassen, falls keine Meldung kommt (höchstens etwa eine Minute)
    if (stand.offen > 0 && _nachfassRunden++ < 150) {
      _nachfassen = Timer(const Duration(milliseconds: 400), () {
        if (!_weg && gueltig) _pumpen();
      });
    }
  }

  void dispose() {
    _weg = true;
    _entprellen?.cancel();
    _nachfassen?.cancel();
    _drosseln?.cancel();
    sucher.verwerfen();
  }
}

/// Zusätze zum Stand: läuft noch, nicht durchsuchbare Nachrichten (nur Zahlen und feste Texte).
String chatSuchZusatz(ChatSuchStand s) {
  final teile = <String>[
    if (s.laeuft && s.treffer.isNotEmpty) 'Suche läuft noch …',
    if (s.nichtDurchsuchbar == 1) '1 Nachricht nicht durchsuchbar (nicht lesbar).',
    if (s.nichtDurchsuchbar > 1) '${s.nichtDurchsuchbar} Nachrichten nicht durchsuchbar (nicht lesbar).',
  ];
  return teile.join(' ');
}

/// Zeile unter dem Suchfeld: Zustand der Suche in Worten.
String chatSuchStatus(ChatSuchStand s, {required bool gueltig}) {
  if (!gueltig) return 'Gib mindestens zwei Zeichen ein.';
  final kopf = s.treffer.isEmpty
      ? (s.laeuft ? 'Suche läuft …' : 'Keine Treffer.')
      : (s.trefferGesamt > s.treffer.length ? '${s.trefferGesamt} Treffer, die neuesten ${s.treffer.length} sind hier.' : (s.trefferGesamt == 1 ? '1 Treffer.' : '${s.trefferGesamt} Treffer.'));
  final zusatz = chatSuchZusatz(s);
  return zusatz.isEmpty ? kopf : '$kopf $zusatz';
}

// ---------------------------------------------------------------------------------------------------------------------- Leiste im Verlauf

/// Suchleiste im Verlauf eines Chats: Eingabe, Treffer-Zähler, "Älterer/Neuerer Treffer", Schließen. Ein Treffer wird über [beiTreffer] im Verlauf angesteuert und hervorgehoben;
/// [beiWoerter] meldet die Suchwörter (der Verlauf hebt sie in den sichtbaren Nachrichten hervor).
class ChatSuchLeiste extends ConsumerStatefulWidget {
  final String konversationId;
  final void Function(String nachrichtId) beiTreffer;
  final void Function(List<String> woerter) beiWoerter;
  final VoidCallback beiSchliessen;
  const ChatSuchLeiste({super.key, required this.konversationId, required this.beiTreffer, required this.beiWoerter, required this.beiSchliessen});

  @override
  ConsumerState<ChatSuchLeiste> createState() => _ChatSuchLeisteState();
}

class _ChatSuchLeisteState extends ConsumerState<ChatSuchLeiste> {
  final _feld = TextEditingController();
  late final ChatSuchSteuerung _steuerung;
  int _index = 0;
  String _gesprungenFuer = '';

  @override
  void initState() {
    super.initState();
    _steuerung = ChatSuchSteuerung(
      sucher: ChatSucher(inhalt: (n) => ref.read(nachrichtenInhaltProvider).nachricht(n)),
      lade: () async => ref.read(nachrichtenProvider(widget.konversationId)).value ?? const <Nachricht>[],
      beiAenderung: _stand,
    );
  }

  @override
  void dispose() {
    _steuerung.dispose();
    _feld.dispose();
    super.dispose();
  }

  void _stand() {
    if (!mounted) return;
    final s = _steuerung.stand;
    // beim ersten Ergebnis einer neuen Eingabe zum neuesten Treffer springen
    if (_steuerung.gueltig && s.treffer.isNotEmpty && _gesprungenFuer != _steuerung.eingabe) {
      _gesprungenFuer = _steuerung.eingabe;
      _index = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.beiTreffer(s.treffer.first.nachrichtId);
      });
    }
    if (_index >= s.treffer.length) _index = s.treffer.isEmpty ? 0 : s.treffer.length - 1;
    setState(() {});
  }

  void _gehe(int schritt) {
    final t = _steuerung.stand.treffer;
    if (t.isEmpty) return;
    setState(() => _index = (_index + schritt).clamp(0, t.length - 1));
    widget.beiTreffer(t[_index].nachrichtId);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(nachrichtenInhaltProvider, (_, _) => _steuerung.entschluesselungGeaendert());
    ref.listen(nachrichtenProvider(widget.konversationId), (_, neu) => _steuerung.listeGeaendert(neu.value ?? const <Nachricht>[]));
    final s = _steuerung.stand;
    final gueltig = _steuerung.gueltig;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.beiSchliessen},
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 6),
        decoration: const BoxDecoration(color: kSurface, border: Border(bottom: BorderSide(color: kBorderSoft))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(tooltip: 'Suche schließen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.arrow_back), onPressed: widget.beiSchliessen),
                Expanded(
                  child: TextField(
                    controller: _feld,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    inputFormatters: [LengthLimitingTextInputFormatter(100)],
                    onChanged: (t) {
                      _steuerung.tippen(t);
                      widget.beiWoerter(suchWoerter(t));
                    },
                    decoration: const InputDecoration(hintText: 'In diesem Chat suchen …', isDense: true),
                  ),
                ),
                IconButton(
                  tooltip: 'Älterer Treffer',
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: s.treffer.isNotEmpty && _index < s.treffer.length - 1 ? () => _gehe(1) : null,
                ),
                IconButton(
                  tooltip: 'Neuerer Treffer',
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: s.treffer.isNotEmpty && _index > 0 ? () => _gehe(-1) : null,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 4, 0),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  s.treffer.isEmpty ? chatSuchStatus(s, gueltig: gueltig) : 'Treffer ${_index + 1} von ${s.treffer.length}${s.trefferGesamt > s.treffer.length ? ' (${s.trefferGesamt} insgesamt)' : ''}. ${chatSuchZusatz(s)}'.trim(),
                  style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------- Seite über alle Chats

/// "In allen Chats suchen": Treffer mit Chat, Absender und Zeit; Tippen liefert das Ziel zurück ([ChatSprungZiel]), der Aufrufer öffnet den Chat und der Verlauf springt zur Nachricht.
class ChatSuchSeite extends ConsumerStatefulWidget {
  const ChatSuchSeite({super.key});

  static Route<ChatSprungZiel> route() => MaterialPageRoute<ChatSprungZiel>(builder: (_) => const ChatSuchSeite());

  @override
  ConsumerState<ChatSuchSeite> createState() => _ChatSuchSeiteState();
}

class _ChatSuchSeiteState extends ConsumerState<ChatSuchSeite> {
  final _feld = TextEditingController();
  late final ChatSuchSteuerung _steuerung;

  @override
  void initState() {
    super.initState();
    _steuerung = ChatSuchSteuerung(
      sucher: ChatSucher(inhalt: (n) => ref.read(nachrichtenInhaltProvider).nachricht(n)),
      lade: () {
        final ids = [for (final e in ref.read(chatUebersichtProvider).value ?? const <ChatEintrag>[]) e.id];
        return ref.read(chatRepositoryProvider).fuerSuche(ids, je: kChatSucheMaxNachrichten);
      },
      beiAenderung: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _steuerung.dispose();
    _feld.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(nachrichtenInhaltProvider, (_, _) => _steuerung.entschluesselungGeaendert());
    final s = _steuerung.stand;
    final gueltig = _steuerung.gueltig;
    final eintraege = ref.watch(chatUebersichtProvider).value ?? const <ChatEintrag>[];
    final mitglieder = chatMitglieder(ref, eintraege);
    final ich = ref.watch(authProvider.select((x) => x.user?.id));
    final inhalt = ref.read(nachrichtenInhaltProvider);
    final namen = {for (final e in eintraege) e.id: chatName(e.konversation, e.teilnehmer, mitglieder, ich, inhalt)};
    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(tooltip: 'Zurück', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const MonoLabel('Chat'),
                          const SizedBox(height: 4),
                          Semantics(header: true, child: const Text('In Chats suchen', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.65, color: kTextStrong))),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _feld,
                            autofocus: true,
                            textInputAction: TextInputAction.search,
                            inputFormatters: [LengthLimitingTextInputFormatter(100)],
                            onChanged: _steuerung.tippen,
                            decoration: const InputDecoration(hintText: 'Nachrichten durchsuchen …', prefixIcon: Icon(Icons.search, size: 20)),
                          ),
                          const SizedBox(height: 8),
                          Semantics(
                            liveRegion: true,
                            child: Text(chatSuchStatus(s, gueltig: gueltig), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Gesucht wird nur auf diesem Gerät, in den jüngsten Nachrichten jedes Chats. Nichts davon wird gespeichert oder gesendet.',
                            style: TextStyle(fontSize: 12, color: kTextMuted, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: s.treffer.isEmpty
                          ? (gueltig && !s.laeuft ? const EmptyState(icon: Icons.search_off, title: 'Nichts gefunden', hint: 'Probiere ein anderes Wort.') : const SizedBox.shrink())
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                              itemCount: s.treffer.length,
                              itemBuilder: (context, i) {
                                final t = s.treffer[i];
                                final autor = t.autorId == ich ? 'Du' : (mitglieder[t.autorId]?.displayName ?? 'Unbekannt');
                                final chat = namen[t.konversationId] ?? 'Chat';
                                return _TrefferZeile(
                                  chat: chat,
                                  autor: autor,
                                  zeit: '${datumTrenner(t.zeit)}, ${uhrzeit(t.zeit)}',
                                  ausschnitt: t.ausschnitt,
                                  onTap: () => Navigator.of(context).pop<ChatSprungZiel>((chatId: t.konversationId, nachrichtId: t.nachrichtId)),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrefferZeile extends StatelessWidget {
  final String chat;
  final String autor;
  final String zeit;
  final Ausschnitt ausschnitt;
  final VoidCallback onTap;
  const _TrefferZeile({required this.chat, required this.autor, required this.zeit, required this.ausschnitt, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Treffer in $chat, $autor, $zeit: ${ausschnitt.text}',
    excludeSemantics: true,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$chat · $autor · $zeit', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
              const SizedBox(height: 4),
              TrefferText(ausschnitt.text, ausschnitt.bereiche, stil: const TextStyle(fontSize: 14, color: kText), maxLines: 3),
            ],
          ),
        ),
      ),
    ),
  );
}
