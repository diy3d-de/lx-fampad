import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/providers.dart';
import 'features/login/login_screen.dart';
import 'features/shell/home_shell.dart';
import 'features/update/update_banner.dart';
import 'features/update/update_service.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

class FampadApp extends ConsumerWidget {
  const FampadApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final angemeldet = ref.watch(authProvider);
    final pflichtUpdate = ref.watch(updateProvider.select((u) => u.pflicht));
    return MaterialApp(
      title: 'lx-fampad',
      debugShowCheckedModeBanner: false,
      locale: const Locale('de', 'DE'),
      supportedLocales: const [Locale('de', 'DE')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(),
      home: pflichtUpdate
          ? const PflichtUpdateSeite()
          : angemeldet
          ? const HomeShell()
          : const Scaffold(body: LxBackground(child: SafeArea(child: LoginScreen()))),
    );
  }
}
