import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/auth/auth_state.dart';
import 'features/auth/adresszeile.dart';
import 'features/auth/auth_widgets.dart';
import 'features/auth/invite_intake.dart';
import 'features/auth/invite_screen.dart';
import 'features/auth/invite_link.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/pending_screen.dart';
import 'features/shell/home_shell.dart';
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

class _FampadAppState extends ConsumerState<FampadApp> {
  StreamSubscription<String>? _links;

  @override
  void initState() {
    super.initState();
    // Einladungslink in einem schon offenen Browser-Tab (Fragment ändert sich): wird sofort aus der Adresszeile entfernt
    aufEinladungInAdresszeileHoeren((l) => ref.read(inviteIntakeProvider.notifier).eingegangen(l.token));
    final kanal = ref.read(systemChannelProvider);
    _links = kanal.links.listen(_linkVonAussen);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Sitzung prüfen (GET /me); parallel Pflicht-Update erkennen, bevor jemand sich anmeldet
      unawaited(ref.read(updateProvider.notifier).pruefen());
      await ref.read(authProvider.notifier).start();
      final start = await kanal.startLink();
      if (start != null) _linkVonAussen(start);
    });
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    super.dispose();
  }

  /// Link, mit dem Android die App geöffnet hat (https://familie.lx-labs.dev/#/einladung/…).
  void _linkVonAussen(String link) => ref.read(inviteIntakeProvider.notifier).eingegangen(parseInviteToken(link));

  void _einladungVerarbeiten() {
    final link = ref.read(inviteIntakeProvider);
    if (link == null) return;
    final status = ref.read(authProvider).status;
    if (status == AuthStatus.pruefe) return; // erst wenn klar ist, ob schon jemand angemeldet ist
    ref.read(inviteIntakeProvider.notifier).verbraucht();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = _navigatorKey.currentState;
      final messenger = _messengerKey.currentState;
      if (nav == null) return;
      if (link.token == null) {
        messenger?.showSnackBar(const SnackBar(content: Text('Der Einladungslink ist ungültig.')));
      } else if (status == AuthStatus.abgemeldet || status == AuthStatus.verbindungsfehler) {
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
    ref.listen(authProvider.select((s) => s.status), (alt, neu) {
      // Sitzung weg oder Konto wartet: alle offenen Unterseiten (Profil, Admin ...) schließen
      if (alt != neu && neu != AuthStatus.angemeldet) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _navigatorKey.currentState?.popUntil((r) => r.isFirst));
      }
      _einladungVerarbeiten();
    });
    ref.listen(inviteIntakeProvider, (_, _) => _einladungVerarbeiten());
    return MaterialApp(
      title: 'lx-fampad',
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
      onGenerateInitialRoutes: (_) => [MaterialPageRoute<void>(builder: (_) => const _Einstieg())],
      // Meldet der Browser später einen Pfad (z. B. /einladung/<token> nach dem Einfügen in die Adresszeile), kein Fehler:
      // das Token geht in den Intake, die Seite schließt sich sofort wieder.
      onGenerateRoute: (settings) {
        final name = settings.name ?? '';
        if (name.startsWith('/einladung')) {
          ref.read(inviteIntakeProvider.notifier).eingegangen(parseInviteToken('#$name'));
        }
        return MaterialPageRoute<void>(builder: (_) => const _SofortZurueck());
      },
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

class _SofortZurueck extends StatefulWidget {
  const _SofortZurueck();

  @override
  State<_SofortZurueck> createState() => _SofortZurueckState();
}

class _SofortZurueckState extends State<_SofortZurueck> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
