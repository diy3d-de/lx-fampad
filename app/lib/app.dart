import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'constants.dart';
import 'data/auth/auth_state.dart';
import 'data/betrieb/betrieb_hinweis.dart' show betriebWarnSteuerungProvider;
import 'data/chat/chat_krypto_state.dart';
import 'data/crypto/geraet_schluessel_melder.dart' show geraetSchluesselMelderProvider;
import 'data/geraet_version_melder.dart' show geraetVersionMelderProvider;
import 'data/lists/members.dart' show mitgliederAktualisierungProvider;
import 'data/teilen/teilen_state.dart';
import 'data/push/chat_benachrichtigung_raeumen.dart';
import 'widgets/ungelesen_titel.dart';
import 'features/auth/adresszeile.dart';
import 'features/calendar/erinnerung_steuerung.dart';
import 'features/medikamente/medikament_steuerung.dart';
import 'features/home/heute_widget_steuerung.dart';
import 'features/auth/auth_widgets.dart';
import 'features/auth/invite_intake.dart';
import 'features/auth/invite_screen.dart';
import 'features/auth/invite_link.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/pending_screen.dart';
import 'features/shell/home_shell.dart';
import 'features/teilen/teilen_seite.dart';
import 'data/wandtablet/wandtablet_einstellungen.dart';
import 'features/wandtablet/wandtablet_screen.dart';
import 'features/wandtablet/wandtablet_steuerung.dart';
import 'features/update/update_banner.dart';
import 'features/update/update_service.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

final _navigatorKey = GlobalKey<NavigatorState>();
final _messengerKey = GlobalKey<ScaffoldMessengerState>();

class FampadApp extends ConsumerStatefulWidget {
  const FampadApp({super.key});

  @override
  ConsumerState<FampadApp> createState() => _FampadAppState();
}

class _FampadAppState extends ConsumerState<FampadApp> with WidgetsBindingObserver {
  StreamSubscription<String>? _links;
  StreamSubscription<String>? _teilen;
  bool _teilenOffen = false;
  bool _wandtabletGestartet = false;

  @override
  void initState() {
    super.initState();
    // Die App hat keine benannten Routen. Meldet der Browser einen neuen Pfad (Einfügen eines Einladungslinks in einen schon offenen
    // Tab, Vor/Zurück), wird das hier abgefangen, BEVOR Flutters Navigator daraus eine Route mit dem Token als Namen macht, die
    // ihn in Adresszeile und Verlauf zurückschreiben könnte. Der Link selbst wird unten über das hashchange-Ereignis verarbeitet.
    WidgetsBinding.instance.addObserver(this);
    // Einladungslink in einem schon offenen Browser-Tab (Fragment ändert sich): wird sofort aus der Adresszeile entfernt
    aufEinladungInAdresszeileHoeren((l) => ref.read(inviteIntakeProvider.notifier).eingegangen(l.token));
    final kanal = ref.read(systemChannelProvider);
    _links = kanal.links.listen(_linkVonAussen);
    // Text aus "Teilen mit lx-familyhub" (Android): bleibt im Arbeitsspeicher, bis die angemeldete Person das Ziel gewählt hat
    _teilen = kanal.teilen.listen((t) => ref.read(teilenProvider.notifier).eingegangen(t));
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Sitzung prüfen (GET /me); parallel Pflicht-Update erkennen, bevor jemand sich anmeldet
      unawaited(ref.read(updateProvider.notifier).pruefen());
      await ref.read(authProvider.notifier).start();
      final start = await kanal.startLink();
      if (start != null) _linkVonAussen(start);
      final geteilt = await kanal.startTeilen();
      if (geteilt != null && mounted) ref.read(teilenProvider.notifier).eingegangen(geteilt);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_links?.cancel());
    unawaited(_teilen?.cancel());
    super.dispose();
  }

  /// Pfadmeldung des Browsers. Sie wird immer verschluckt (keine Route). Enthält sie einen Einladungslink, geht das Token von hier
  /// in den Speicher, falls das Fragment schon aus der Adresszeile verschwunden war, bevor der Listener in adresszeile_web.dart es las
  /// (Flutters Engine springt nach einer unbekannten Adresse mit history.go(-1) zurück). Doppelte Meldungen fängt der Intake ab.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final pfad = routeInformation.uri.toString();
    if (istEinladungsFragment('#$pfad')) ref.read(inviteIntakeProvider.notifier).eingegangen(parseInviteToken('#$pfad'));
    return true;
  }

  /// Link, mit dem Android die App geöffnet hat (https://familie.lx-labs.dev/#/einladung/…). Nur Einladungslinks (Fragment
  /// #/einladung…) zählen; andere Links der Domain (z. B. nur die Startseite, die verifizierte App Links ebenfalls öffnen) ignoriert die App.
  void _linkVonAussen(String link) {
    if (!istEinladungsLink(link)) return;
    ref.read(inviteIntakeProvider.notifier).eingegangen(parseInviteToken(link));
  }

  /// Geteilter Text wartet und die Person ist angemeldet: die Auswahl "Wohin damit?" öffnen (eine Seite über allem, nur einmal). Nicht angemeldet: der Text bleibt liegen
  /// und wird nach der Anmeldung angeboten.
  void _teilenAnbieten() {
    if (_teilenOffen || ref.read(teilenProvider) == null || ref.read(authProvider).status != AuthStatus.angemeldet) return;
    _teilenOffen = true;
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = _navigatorKey.currentState;
      if (nav == null || ref.read(teilenProvider) == null || ref.read(authProvider).status != AuthStatus.angemeldet) {
        _teilenOffen = false;
        return;
      }
      unawaited(nav.push<void>(TeilenSeite.route()).whenComplete(() => _teilenOffen = false));
    });
  }

  void _einladungVerarbeiten() {
    final link = ref.read(inviteIntakeProvider);
    if (link == null) return;
    final status = ref.read(authProvider).status;
    if (status == AuthStatus.pruefe) return; // erst wenn klar ist, ob schon jemand angemeldet ist
    ref.read(inviteIntakeProvider.notifier).verbraucht();
    // Ein Post-Frame-Callback läuft nur, wenn ein Frame kommt; hier ändert sich vorher kein Widget (Link kommt von außen),
    // deshalb wird ein Frame ausdrücklich angefordert. Sonst bliebe der Link bis zur nächsten Eingabe liegen.
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = _navigatorKey.currentState;
      final messenger = _messengerKey.currentState;
      if (nav == null) return;
      if (link.token == null) {
        messenger?.showSnackBar(const SnackBar(content: Text('Der Einladungslink ist ungültig.')));
      } else if (status == AuthStatus.abgemeldet || status == AuthStatus.verbindungsfehler || status == AuthStatus.wartend) {
        nav.popUntil((r) => r.isFirst);
        nav.push<void>(MaterialPageRoute(builder: (_) => InviteScreen(token: link.token)));
      } else {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Du bist schon angemeldet. Melde dich ab, wenn du eine Einladung annehmen möchtest.')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Terminerinnerungen (Android) aktuell halten: hier am Wurzel-Widget, das nie pausiert (hinter geöffneten Seiten pausieren Beobachter)
    ref.watch(erinnerungSteuerungProvider);
    // Startbildschirm-Widget "Heute" (Android) aktuell halten und Tipps darauf auswerten
    ref.watch(heuteWidgetSteuerungProvider);
    // Chat-Verschlüsselung (Schlüsselbund, Epochen, Entschlüsselung) am Laufen halten
    ref.watch(chatKryptoSteuerungProvider);
    // Medikamenten-Plan: Teilnehmer der verborgenen Konversationen nach Mitglieder- und Rollenwechseln nachziehen (nur vertrauenswürdige Schlüssel)
    ref.watch(medikamentSteuerungProvider);
    // Betreiber: lokales Konto-Flag für die Warnungen (nur dann fragt ein Wecker den Warnstand ab) und Meldung des Schlüsselstands dieses Geräts
    ref.watch(betriebWarnSteuerungProvider);
    ref.watch(geraetSchluesselMelderProvider);
    ref.watch(geraetVersionMelderProvider);
    ref.watch(mitgliederAktualisierungProvider);
    ref.watch(chatBenachrichtigungenRaeumenProvider);
    ref.watch(ungelesenTitelProvider);
    ref.listen(authProvider.select((s) => s.status), (alt, neu) {
      // Sitzung weg oder Konto wartet: alle offenen Unterseiten (Profil, Admin ...) schließen
      if (alt != neu && neu != AuthStatus.angemeldet) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _navigatorKey.currentState?.popUntil((r) => r.isFirst));
      }
      if (neu != AuthStatus.angemeldet) _wandtabletGestartet = false;
      // Abmelden, Sitzungsverlust und Personenwechsel verwerfen einen wartenden geteilten Text; nach der Anmeldung wird er angeboten
      if (alt == AuthStatus.angemeldet && neu != AuthStatus.angemeldet) {
        ref.read(teilenProvider.notifier).verwerfen();
      } else {
        _teilenAnbieten();
      }
      _einladungVerarbeiten();
    });
    // Wandtablet-Modus: "Beim Start der App automatisch starten" (lokal je Gerät), einmal je Anmeldung
    ref.listen(wandtabletBereitProvider, (_, bereit) {
      if (!bereit || _wandtabletGestartet) return;
      _wandtabletGestartet = true; // nur die erste Prüfung nach der Anmeldung zählt
      if (!ref.read(wandtabletEinstellungenProvider).autostart) return;
      WidgetsBinding.instance.scheduleFrame();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(wandtabletBereitProvider)) unawaited(_navigatorKey.currentState?.push<void>(WandtabletScreen.route()));
      });
    });
    ref.listen(teilenProvider, (_, _) => _teilenAnbieten());
    ref.listen(inviteIntakeProvider, (_, _) => _einladungVerarbeiten());
    return MaterialApp(
      title: kAppName,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      locale: const Locale('de', 'DE'),
      supportedLocales: const [Locale('de', 'DE')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(),
      // Der Startpfad der Adresszeile (Web: /einladung/<token>) wird ignoriert: der Link wird über den Intake verarbeitet.
      // Alle Seiten werden direkt (unbenannt) mit Navigator.push geöffnet; ein Token steht nie in einem Routennamen.
      onGenerateInitialRoutes: (_) => [MaterialPageRoute<void>(builder: (_) => const _Einstieg())],
      // Formal nötig (MaterialApp verlangt eine Routenquelle). Unerreichbar, weil didPushRouteInformation alle Pfadmeldungen schluckt.
      onUnknownRoute: (_) => MaterialPageRoute<void>(builder: (_) => const _Einstieg()),
    );
  }
}

/// Wählt je nach Zustand die Startseite: Pflicht-Update, Prüfung, Anmeldung, App, Warten auf Freigabe, Verbindungsfehler.
class _Einstieg extends ConsumerWidget {
  const _Einstieg();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pflichtUpdate = ref.watch(updateProvider.select((u) => u.pflicht));
    final auth = ref.watch(authProvider);
    if (pflichtUpdate) return const PflichtUpdateSeite();
    return switch (auth.status) {
      AuthStatus.pruefe => const _Laedt(),
      AuthStatus.abgemeldet => const LoginScreen(),
      AuthStatus.angemeldet => const HomeShell(),
      AuthStatus.wartend => const PendingScreen(),
      AuthStatus.verbindungsfehler => _Verbindungsfehler(meldung: auth.hinweis),
    };
  }
}

class _Laedt extends StatelessWidget {
  const _Laedt();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Colors.transparent,
    body: LxBackground(child: Center(child: CircularProgressIndicator())),
  );
}

class _Verbindungsfehler extends ConsumerWidget {
  final String? meldung;
  const _Verbindungsfehler({this.meldung});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AuthSeite(
    zurueck: false,
    maxBreite: 420,
    kinder: [
      const SizedBox(height: 24),
      const MarkenKopf(),
      const SizedBox(height: 28),
      MeldungsBox(meldung ?? 'Keine Verbindung zum Server.'),
      const SizedBox(height: 16),
      HauptKnopf(text: 'Erneut versuchen', icon: Icons.refresh, onPressed: ref.read(authProvider.notifier).start),
    ],
  );
}
