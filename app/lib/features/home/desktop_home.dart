// Startseite im Desktop-Layout: Kopfzeile (Datum, Begrüßung, Suche, Benachrichtigungen, "+ Neu") und Karten-Raster.
// Die Kacheln lassen sich umsortieren und ausblenden (lokal je Gerät, siehe startseite_anpassen_screen.dart).
// Echte Daten gibt es für Termine, Aufgaben, Einkaufsliste, Familie und Sync-Zustand; noch nicht gebaute Bereiche zeigen einen Leerzustand.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/chat/nachrichten_inhalt.dart';
import '../../data/lists/list_repository.dart';
import '../../data/lists/list_rights.dart';
import '../../data/lists/members.dart';
import '../../data/api/api_error.dart';
import '../../data/api/models.dart';
import '../../ui/widgets.dart';
import '../../data/calendar/termin_repository.dart';
import '../calendar/calendar_anzeige.dart';
import '../calendar/calendar_state.dart';
import '../calendar/countdown_karte.dart';
import '../profile/absicherung_screen.dart' show AbsicherungsKarte;
import '../wetter/wetter_hinweis_karte.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../chat/chat_anzeige.dart';
import '../lists/list_dialogs.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../tasks/aufgaben_anzeige.dart';
import '../tasks/fristen_anzeige.dart' show FristenStartKarte;
import '../shell/shell_tab.dart';
import '../../data/startseite/startseite_logik.dart';
import '../../data/startseite/startseite_state.dart';
import 'startseite_verfuegbar.dart';
import 'startseite_anpassen_zeile.dart';
import 'startseite_widgets.dart';
import '../files/dateien_start_karte.dart';
import '../files/dateien_screen.dart' show dateienOeffnen;
import '../standort/standort_start_karte.dart';
import '../wandtablet/wandtablet_steuerung.dart' show WandtabletStartZeile;
import '../wetter/wetter_karte.dart';
import '../muell/muell_karte.dart';
import '../medikamente/medikamente_karte.dart' show MedikamenteStartKarte;
import '../zaehler/zaehler_karte.dart' show ZaehlerStartKarte;
import '../../data/muell/muell_state.dart';
import '../../data/wetter/wetter_state.dart';
import '../../data/standort/standort_dienst.dart';
import '../suche/such_einstieg.dart';
import '../update/update_banner.dart';
import 'home_screen.dart';
import '../../widgets/benutzer_avatar.dart';

/// "Guten Morgen/Tag/Abend, Vorname" (bei leerem Namen nur die Tageszeit-Begrüßung).
String tagesgruss(String? anzeigename, DateTime jetzt) {
  final gruss = jetzt.hour < 11 ? 'Guten Morgen' : (jetzt.hour < 18 ? 'Guten Tag' : 'Guten Abend');
  final v = vorname(anzeigename);
  return v == null ? gruss : '$gruss, $v';
}

class DesktopHome extends ConsumerWidget {
  const DesktopHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(authProvider.select((s) => s.user?.displayName));
    final jetzt = DateTime.now();
    final heute = DateFormat('E, d. MMM', 'de_DE').format(jetzt).toLowerCase();
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
      children: [
        _Kopfzeile(label: '// $heute', gruss: tagesgruss(name, jetzt)),
        const SizedBox(height: 24),
        const UpdateAnzeige(),
        const AbsicherungsKarte(),
        const WetterHinweisKarte(),
        const _Raster(),
        const SizedBox(height: 8),
        const StartseiteAnpassenZeile(),
        const WandtabletStartZeile(),
      ],
    );
  }
}

class _Kopfzeile extends ConsumerWidget {
  final String label;
  final String gruss;
  const _Kopfzeile({required this.label, required this.gruss});

  Future<void> _neueListe(BuildContext context, WidgetRef ref) async {
    // alles Nötige vor dem await lesen: danach kann das Widget schon weg sein
    final u = ref.read(authProvider).user;
    final repo = ref.read(listenRepositoryProvider);
    final gewaehlt = ref.read(gewaehlteListeProvider.notifier);
    final tab = ref.read(shellTabProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final a = await neueListeDialog(context, ListenRechte(u?.role ?? Role.child, u?.id));
    if (a == null || !context.mounted) return;
    try {
      final id = await repo.listeAnlegen(name: a.name, art: a.art, sicht: a.sicht);
      gewaehlt.waehlen(id);
      tab.waehlen(kListenTab);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Die Liste konnte nicht angelegt werden.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            MonoLabel(label),
            const SizedBox(height: 4),
            Semantics(
              header: true,
              child: Text(gruss, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.7, color: kTextStrong)),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const SuchEinstieg(breite: 240),
            IconButton(
              tooltip: 'Benachrichtigungen',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: const Icon(Icons.notifications_none),
              onPressed: () => ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('Benachrichtigungen kommen mit Push in einer späteren Phase'))),
            ),
            PopupMenuButton<String>(
                tooltip: 'Neu anlegen',
                color: kSurface,
                onSelected: (_) => _neueListe(context, ref),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'liste', height: 44, child: Row(children: [Icon(Icons.checklist_outlined, size: 18, color: kAccent), SizedBox(width: 10), Text('Neue Liste')])),
                ],
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(12)),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 18, color: kOnAccent),
                      SizedBox(width: 6),
                      Text('Neu', style: TextStyle(fontWeight: FontWeight.w700, color: kOnAccent)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Karten-Raster: 3 Spalten ab ca. 840 px Inhaltsbreite, sonst 2 bzw. 1; Kartenhöhe wächst mit der Textskalierung.
/// Kacheln lassen sich mit gedrückter Maustaste (kurz halten, dann ziehen) umsortieren: die Zielstelle erscheint als gestrichelte Lücke,
/// die übrigen Kacheln rücken nach; Loslassen legt ab. Am oberen und unteren Rand scrollt die Seite mit. Reihenfolge und Ausblenden
/// gelten nur lokal je Gerät (data/startseite/); Pfeile und Schalter gibt es auf der Seite "Startseite anpassen".
class _Raster extends ConsumerStatefulWidget {
  const _Raster();

  @override
  ConsumerState<_Raster> createState() => _RasterState();
}

class _RasterState extends ConsumerState<_Raster> {
  /// Gerade gezogene Kachel und ihr Zielplatz in der Anzeige (null = keine Ziehgeste).
  String? _zieht;
  int? _ziel;
  int _urspruenglich = 0;

  /// Esc während des Ziehens: nichts ablegen (die Kachel springt zurück, beim Loslassen ändert sich nichts).
  bool _abgebrochen = false;
  EdgeDraggingAutoScroller? _scroller;

  /// Zeiger der Ziehgeste (global) und Maße des Rasters der letzten Zeichnung: beim Mitscrollen am Rand wandert die Kachel unter dem
  /// ruhenden Zeiger weiter, den Zielplatz rechnet dann [_beiScroll] aus der Rastergeometrie.
  Rect _zeiger = Rect.zero;
  final _gitter = GlobalKey();
  int _spalten = 1;
  double _zellenBreite = 0;
  double _zellenHoehe = 0;

  List<String> _sichtbar() {
    final a = ref.read(startseiteDesktopProvider);
    return sichtbareKacheln(reihenfolge: a.reihenfolge, verfuegbar: ref.read(desktopVerfuegbarProvider), ausgeblendet: a.ausgeblendet);
  }

  /// Reihenfolge mit der gezogenen Kachel an ihrem Zielplatz (ihr Platz selbst ist die Lücke).
  List<String> _anzeige(List<String> ids) {
    final z = _zieht;
    if (z == null || !ids.contains(z)) return ids;
    final basis = [...ids]..remove(z);
    return basis..insert((_ziel ?? ids.indexOf(z)).clamp(0, basis.length), z);
  }

  void _start(String id) {
    final ids = _sichtbar();
    _scroller?.stopAutoScroll();
    final scrollable = Scrollable.maybeOf(context);
    _scroller = scrollable == null ? null : EdgeDraggingAutoScroller(scrollable, velocityScalar: 7, onScrollViewScrolled: _beiScroll);
    HardwareKeyboard.instance.removeHandler(_taste);
    HardwareKeyboard.instance.addHandler(_taste);
    setState(() {
      _zieht = id;
      _abgebrochen = false;
      _urspruenglich = ids.indexOf(id);
      _ziel = _urspruenglich;
    });
  }

  bool _taste(KeyEvent e) {
    if (_zieht == null || e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return false;
    setState(() {
      _abgebrochen = true;
      _ziel = _urspruenglich;
    });
    return true;
  }

  void _ueber(String id, int platz) {
    if (_zieht == null || id == _zieht || _ziel == platz) return;
    setState(() => _ziel = platz);
  }

  /// Nach einem Scroll-Schritt am Rand: weiter scrollen, solange der Zeiger am Rand steht, und den Platz unter dem Zeiger als Ziel nehmen.
  void _beiScroll() {
    if (!mounted || _zieht == null) return;
    _scroller?.startAutoScrollIfNecessary(_zeiger);
    final box = _gitter.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || _zellenBreite <= 0) return;
    final lokal = box.globalToLocal(_zeiger.center);
    final spalte = (lokal.dx / (_zellenBreite + 16)).floor().clamp(0, _spalten - 1);
    final zeile = (lokal.dy / (_zellenHoehe + 16)).floor().clamp(0, 1000);
    final anzahl = _sichtbar().length;
    final platz = (zeile * _spalten + spalte).clamp(0, anzahl - 1);
    if (platz != _ziel) setState(() => _ziel = platz);
  }

  /// Ablegen: die Vorschau wird zur neuen Reihenfolge. Lässt man die Maustaste außerhalb einer Kachel los (auch zwischen den Kacheln oder
  /// außerhalb des Rasters), gilt die zuletzt angezeigte Zielstelle; Esc bricht ab. Ändert sich nichts, wird nichts gespeichert.
  void _ablegen() {
    if (_zieht == null) return;
    if (!_abgebrochen) unawaited(ref.read(startseiteDesktopProvider.notifier).teilmengeOrdnen(_anzeige(_sichtbar())));
    _ziehenBeenden();
  }

  /// Ziehzustand zurücksetzen (nach dem Ablegen, bei Esc-Abbruch oder wenn die gezogene Kachel verschwindet).
  void _ziehenBeenden() {
    _scroller?.stopAutoScroll();
    HardwareKeyboard.instance.removeHandler(_taste);
    if (!mounted) return;
    setState(() {
      _zieht = null;
      _ziel = null;
      _abgebrochen = false;
    });
  }

  @override
  void dispose() {
    _scroller?.stopAutoScroll();
    HardwareKeyboard.instance.removeHandler(_taste);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = ref.watch(startseiteDesktopProvider);
    final verf = ref.watch(desktopVerfuegbarProvider);
    // erst zeichnen, wenn die gemerkte Reihenfolge gelesen ist (sonst springen die Kacheln)
    if (!a.geladen) return const SizedBox.shrink();
    final sichtbar = sichtbareKacheln(reihenfolge: a.reihenfolge, verfuegbar: verf, ausgeblendet: a.ausgeblendet);
    // die gezogene Kachel ist verschwunden (ausgeblendet, nicht mehr verfügbar): Ziehzustand aufgeben, sonst bliebe eine Lücke ohne Kachel
    if (_zieht != null && !sichtbar.contains(_zieht)) WidgetsBinding.instance.addPostFrameCallback((_) => _ziehenBeenden());
    final anzeige = _anzeige(sichtbar);
    final skala = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return LayoutBuilder(
      builder: (context, c) {
        final spalten = c.maxWidth >= 840 ? 3 : (c.maxWidth >= 520 ? 2 : 1);
        final breite = (c.maxWidth - (spalten - 1) * 16) / spalten;
        final hoehe = 300 * skala;
        _spalten = spalten;
        _zellenBreite = breite;
        _zellenHoehe = hoehe;
        return GridView(
          key: _gitter,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: spalten, mainAxisSpacing: 16, crossAxisSpacing: 16, mainAxisExtent: hoehe),
          children: [
            for (var i = 0; i < anzeige.length; i++)
              // Schlüssel je Kachel: beim Umsortieren wandert das Element mit (die laufende Ziehgeste bleibt erhalten)
              KeyedSubtree(
                key: ValueKey(anzeige[i]),
                child: DragTarget<String>(
                  // nur die zuerst gezogene Kachel zählt (eine zweite Berührung zieht nichts: kein Bild, keine Lücke, kein Ablegen)
                  onWillAcceptWithDetails: (d) => d.data == _zieht,
                  onMove: (_) => _ueber(anzeige[i], i),
                  onAcceptWithDetails: (_) => _ablegen(),
                  builder: (context, _, _) => LongPressDraggable<String>(
                    data: anzeige[i],
                    maxSimultaneousDrags: 1,
                    feedback: _zieht == null || _zieht == anzeige[i]
                        ? SizedBox(width: breite, height: hoehe, child: StartseiteGehoben(child: _kachel(anzeige[i])))
                        : const SizedBox.shrink(),
                    childWhenDragging: _zieht == anzeige[i] ? const StartseiteLuecke() : _kachel(anzeige[i]),
                    onDragStarted: () {
                      if (_zieht == null) _start(anzeige[i]);
                    },
                    onDragUpdate: (d) {
                      if (_zieht != anzeige[i]) return;
                      _zeiger = Rect.fromCenter(center: d.globalPosition, width: 48, height: 48);
                      _scroller?.startAutoScrollIfNecessary(_zeiger);
                    },
                    onDragEnd: (_) {
                      if (_zieht == anzeige[i]) _ablegen();
                    },
                    child: _kachel(anzeige[i]),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Die Kachel zu einer Kennung (siehe [kDesktopKacheln]).
Widget _kachel(String id) => switch (id) {
  'termine' => const _TermineKarte(),
  'countdown' => const CountdownKarte(),
  'chat' => const _ChatKarte(),
  'einkauf' => const _EinkaufKarte(),
  'dateien' => const _DateienKarte(),
  'aufgaben' => const _AufgabenKarte(),
  'fristen' => const FristenStartKarte(),
  'medikamente' => const MedikamenteStartKarte(),
  'zaehler' => const ZaehlerStartKarte(),
  'familie' => const _FamilieKarte(),
  'standort' => const _StandortKarte(),
  'muell' => const _MuellKarte(),
  'wetter' => const _WetterKarte(),
  _ => const SizedBox.shrink(),
};

/// "Heute & morgen" mit echten Terminen (lokale Datenbank, auch offline); Tippen öffnet den Kalender.
class _TermineKarte extends ConsumerWidget {
  const _TermineKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daten = ref.watch(kalenderDatenProvider);
    final mitglieder = mitgliederFuer(ref, daten);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final heute = heuteTag(jetzt);
    final morgenEnde = heute.add(const Duration(days: 2));
    // heute und morgen: Vorkommen, die vor dem Ende von morgen beginnen
    final liste = [for (final v in anstehende(daten, jetzt, tage: 2)) if (v.startWand.isBefore(morgenEnde)) v];
    return _Karte(
      label: '// heute & morgen',
      zaehler: liste.isEmpty ? null : '${liste.length}',
      semantik: liste.isEmpty ? 'Heute und morgen: keine Termine. Kalender öffnen' : 'Heute und morgen: ${liste.length} Termine. Kalender öffnen',
      onTap: () => ref.read(shellTabProvider.notifier).waehlen(kKalenderTab),
      child: liste.isEmpty
          ? const EmptyState(icon: Icons.event_available_outlined, title: 'Keine Termine', hint: 'Heute und morgen steht nichts an.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final v in liste) AnstehenderTermin(v: v, mitglieder: mitglieder, heute: heute)],
            ),
    );
  }
}

/// Rahmen einer Karte: Mono-Label, optionaler Zähler rechts, Inhalt füllt den Rest (überstehender Inhalt wird abgeschnitten).
class _Karte extends StatelessWidget {
  final String label;
  final String? zaehler;
  final String semantik;
  final VoidCallback? onTap;
  final Widget child;

  /// Hervorgehoben (Akzentrand), z. B. die Müll-Karte am Tag vor der Abholung.
  final bool hervorgehoben;
  const _Karte({required this.label, required this.semantik, required this.child, this.zaehler, this.onTap, this.hervorgehoben = false});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: onTap != null,
    focusable: onTap != null,
    onTap: onTap,
    label: semantik,
    excludeSemantics: onTap != null,
    child: LxCard(
      gewaehlt: hervorgehoben,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: MonoLabel(label)),
              if (zaehler != null) Text(zaehler!, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
            ],
          ),
          const SizedBox(height: 12),
          // Überstand wird nicht abgeschnitten, sondern scrollt innerhalb der Karte
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                child: ConstrainedBox(constraints: BoxConstraints(minHeight: c.maxHeight), child: child),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Letzte Chats mit den neuesten Nachrichten (lokale Datenbank, auch offline); es erscheinen nur Chats, die die Person sehen darf
/// (der Server liefert nichts anderes). Tippen öffnet den Chat-Bereich.
class _ChatKarte extends ConsumerWidget {
  const _ChatKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(chatUebersichtProvider);
    final mitglieder = chatMitglieder(ref, async.value ?? const <ChatEintrag>[]);
    final ich = ref.watch(authProvider.select((s) => s.user?.id));
    final inhalt = ref.watch(nachrichtenInhaltProvider);
    final fehler = async.hasError;
    final laedt = !fehler && !async.hasValue;
    final mitNachricht = [for (final e in async.value ?? const <ChatEintrag>[]) if (e.letzte != null) e]..sort((a, b) => b.aktivitaet.compareTo(a.aktivitaet));
    final ungelesen = mitNachricht.fold<int>(0, (s, e) => s + e.ungelesen);
    return _Karte(
      label: '// chat · familie',
      zaehler: ungelesen > 0 ? '$ungelesen neu' : null,
      semantik: fehler
          ? 'Chat, nicht geladen. Öffnen'
          : laedt
          ? 'Chat, lädt. Öffnen'
          : mitNachricht.isEmpty
          ? 'Chat, noch keine Nachrichten. Öffnen'
          : 'Chat, $ungelesen ungelesen. Öffnen',
      onTap: () => ref.read(shellTabProvider.notifier).waehlen(kChatTab),
      child: fehler
          ? _fehler('Der Chat konnte nicht geladen werden.')
          : laedt
          ? _laedt()
          : mitNachricht.isEmpty
          ? const EmptyState(icon: Icons.chat_bubble_outline, title: 'Noch keine Nachrichten', hint: 'Schreib die erste Nachricht an die Familie.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in mitNachricht.take(4))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        ChatAvatar(
                          art: e.art,
                          person: e.art == ChatArt.direct ? mitglieder[e.teilnehmer.where((t) => t != ich).firstOrNull] : null,
                          name: chatName(e.konversation, e.teilnehmer, mitglieder, ich, inhalt),
                          size: 32,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(chatName(e.konversation, e.teilnehmer, mitglieder, ich, inhalt), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: e.ungelesen > 0 ? FontWeight.w800 : FontWeight.w600)),
                              Text(chatVorschau(e, mitglieder, ich, inhalt), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: kTextMuted)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(zeitKurz(e.letzte!.createdAt), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Müll: Datum der nächsten Abholung und Symbole der Arten; am Tag vor der Abholung hervorgehoben. Tippen öffnet die Müll-Seite.
class _MuellKarte extends ConsumerWidget {
  const _MuellKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(muellProvider);
    final d = MuellKachelDaten.aus(z, muellJetzt(ref));
    return _Karte(
      label: d.hervorgehoben ? '// müll · ${d.tage == 0 ? 'heute' : 'morgen'}' : '// müll',
      semantik: muellKachelSemantik(d),
      hervorgehoben: d.hervorgehoben,
      onTap: () => muellOeffnen(context),
      child: MuellKachelInhalt(daten: d),
    );
  }
}

/// Wetter der Station: Temperatur und Stand, Tippen öffnet die Detailseite (nur sichtbar, wenn es Daten gibt und der Schalter an ist).
class _WetterKarte extends ConsumerWidget {
  const _WetterKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(wetterProvider);
    if (!st.hatDaten) return const SizedBox.shrink();
    return _Karte(label: '// wetter', semantik: wetterSemantik(st), onTap: () => wetterOeffnen(context), child: WetterInhalt(zustand: st));
  }
}

/// Standort teilen: ein Satz zum Stand, Tippen öffnet die Standort-Seite.
class _StandortKarte extends ConsumerWidget {
  const _StandortKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(standortProvider);
    final text = standortKurzstatus(st, st.geteilt.isEmpty ? const <String, UserDto>{} : ref.watch(standortMitgliederProvider));
    return _Karte(
      label: '// standort',
      semantik: 'Standort. $text. Öffnen',
      onTap: () => standortOeffnen(context),
      child: EmptyState(icon: st.teilt ? Icons.my_location : Icons.location_on_outlined, title: text, hint: st.teilt ? 'Tippen zum Beenden oder Verlängern.' : 'Tippen, um deinen Standort zu teilen.'),
    );
  }
}

/// Kartenkörper für Laden und Fehler (kein falscher Leerzustand, solange Daten fehlen).
Widget _laedt() => const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
Widget _fehler(String text) => Text(text, style: const TextStyle(color: kDanger));

/// Einkaufsliste mit echten Daten: offene Einträge der ersten Einkaufsliste (lokale Datenbank, auch offline).
class _EinkaufKarte extends ConsumerWidget {
  const _EinkaufKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(authProvider.select((s) => s.user));
    final darfAnlegen = ListenRechte(u?.role ?? Role.child, u?.id).darfListeAnlegen;
    final listenAsync = ref.watch(listenProvider);
    final eintraegeAsync = ref.watch(alleEintraegeProvider);
    final fehler = listenAsync.hasError || eintraegeAsync.hasError;
    final laedt = !fehler && (!listenAsync.hasValue || !eintraegeAsync.hasValue);
    final listen = listenAsync.value ?? const <Liste>[];
    final alle = eintraegeAsync.value ?? const <Listeneintrag>[];
    final einkauf = listen.where((l) => l.kind == 'shopping').firstOrNull;
    final offen = einkauf == null ? <Listeneintrag>[] : sortiereEintraege(alle.where((e) => e.listId == einkauf.id && e.doneAt == null).toList());
    final erledigt = einkauf == null ? 0 : alle.where((e) => e.listId == einkauf.id && e.doneAt != null).length;
    return _Karte(
      label: '// einkaufsliste',
      zaehler: !fehler && !laedt && einkauf != null ? '${offen.length} offen' : null,
      semantik: fehler
          ? 'Einkaufsliste, nicht geladen. Öffnen'
          : laedt
          ? 'Einkaufsliste, lädt. Öffnen'
          : einkauf == null
          ? 'Einkaufsliste, noch keine Liste. Öffnen'
          : 'Einkaufsliste, ${offen.length} offen. Öffnen',
      onTap: () {
        if (einkauf != null) ref.read(gewaehlteListeProvider.notifier).waehlen(einkauf.id);
        ref.read(shellTabProvider.notifier).waehlen(kListenTab);
      },
      child: fehler
          ? _fehler('Die Einkaufsliste konnte nicht geladen werden.')
          : laedt
          ? _laedt()
          : einkauf == null
          ? Text(darfAnlegen ? 'Noch keine Einkaufsliste – klicken zum Anlegen' : 'Noch keine Einkaufsliste', style: const TextStyle(color: kTextMuted))
          : offen.isEmpty
          ? Text(erledigt == 0 ? 'Nichts auf der Liste' : 'Alles erledigt', style: const TextStyle(color: kTextMuted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in offen.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.check_box_outline_blank, size: 18, color: kTextMuted),
                        const SizedBox(width: 10),
                        Expanded(child: Text(e.inhalt, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                if (offen.length > 6) Text('+ ${offen.length - 6} weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              ],
            ),
    );
  }
}

/// Aufgaben mit echten Daten: offene Aufgaben nach Fälligkeit, Überfälliges rot (lokale Datenbank, auch offline). Tippen öffnet den Aufgaben-Tab.
class _AufgabenKarte extends ConsumerWidget {
  const _AufgabenKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wert = ref.watch(aufgabenProvider);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final fehler = wert.hasError && !wert.hasValue;
    final laedt = !wert.hasValue && !wert.hasError;
    final alle = wert.value ?? const <Aufgabe>[];
    final offen = startseitenAufgaben(alle, jetzt);
    final mitglieder = mitgliederFuerAufgaben(ref, offen);
    final ueberfaellig = offen.where((a) => istUeberfaellig(a, jetzt)).length;
    return _Karte(
      label: '// aufgaben',
      zaehler: fehler || laedt || offen.isEmpty ? null : (ueberfaellig > 0 ? '${offen.length} offen · $ueberfaellig überfällig' : '${offen.length} offen'),
      semantik: fehler
          ? 'Aufgaben, nicht geladen. Öffnen'
          : laedt
          ? 'Aufgaben, lädt. Öffnen'
          : offen.isEmpty
          ? 'Aufgaben: nichts offen. Öffnen'
          : 'Aufgaben, ${offen.length} offen, davon $ueberfaellig überfällig. Öffnen',
      onTap: () => ref.read(shellTabProvider.notifier).waehlen(kAufgabenTab),
      child: fehler
          ? _fehler('Die Aufgaben konnten nicht geladen werden.')
          : laedt
          ? _laedt()
          : offen.isEmpty
          ? EmptyState(icon: Icons.task_alt_outlined, title: alle.isEmpty ? 'Noch keine Aufgaben' : 'Alles erledigt', hint: alle.isEmpty ? 'Lege im Bereich Aufgaben die erste an.' : 'Es ist nichts mehr offen.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in offen.take(6)) AufgabeKurzzeile(aufgabe: a, mitglieder: mitglieder, jetzt: jetzt),
                if (offen.length > 6) Text('+ ${offen.length - 6} weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              ],
            ),
    );
  }
}

/// Familienmitglieder (echt, mit Personenfarbe); der Standort kommt erst in Phase 2.
class _FamilieKarte extends ConsumerWidget {
  const _FamilieKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mitgliederProvider);
    final mitglieder = async.value ?? const <UserDto>[];
    final bereit = async.hasValue;
    return _Karte(
      label: '// familie & orte',
      zaehler: bereit && mitglieder.isNotEmpty ? '${mitglieder.length}' : null,
      semantik: bereit ? 'Familie, ${mitglieder.length} Mitglieder. Standort kommt später' : 'Familie. Standort kommt später',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (async.hasError)
            _fehler('Die Mitglieder konnten nicht geladen werden.')
          else if (!bereit)
            SizedBox(height: 120, child: _laedt())
          else if (mitglieder.isEmpty)
            const Text('Keine Mitglieder geladen', style: TextStyle(color: kTextMuted))
          else ...[
            for (final u in mitglieder.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    BenutzerAvatar(user: u, size: 32),
                    const SizedBox(width: 10),
                    Expanded(child: Text(u.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Text(u.role.label.toLowerCase(), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                  ],
                ),
              ),
            if (mitglieder.length > 5) Text('+ ${mitglieder.length - 5} weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
          ],
          const SizedBox(height: 8),
          const Row(
            children: [
              Icon(Icons.place_outlined, size: 16, color: kTextFaint),
              SizedBox(width: 6),
              Expanded(child: Text('Standort teilen: kommt in Phase 2', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextFaint))),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Zuletzt geteilt": die letzten Dateien der Dateiablage, Tippen öffnet den Bereich (die Kachel gibt es nur, wenn der Server die Dateiablage meldet).
class _DateienKarte extends ConsumerWidget {
  const _DateienKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _Karte(label: '// zuletzt geteilt', semantik: dateienKachelSemantik(ref.watch(letzteDateienProvider)), onTap: () => dateienOeffnen(context), child: const DateienKachelInhalt());
}
