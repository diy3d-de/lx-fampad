// Einstellungen "Müll" (nur dieses Gerät, lokal in `sync_meta`): "Im Kalender anzeigen" für alle Mitglieder (auch Kinder), die Erinnerung am Abend
// vor der Abholung nur für Eltern und Admins (Rolle, nie die Familienrolle; nur Android) und "Jetzt nach neuer Datei suchen" (Eltern/Admins).
// Admins erreichen von hier die Seite "Abfuhrkalender" (Status je Jahr).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show Role;
import '../../data/auth/auth_state.dart';
import '../../data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider, erinnerungStatusProvider;
import '../../data/erinnerungen/erinnerung_einstellungen.dart';
import '../../data/muell/muell_logik.dart';
import '../../data/muell/muell_modelle.dart';
import '../../data/muell/muell_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../profile/profile_screen.dart' show EinstellungsZeile;
import 'muell_abfuhrkalender_screen.dart';
import 'muell_pruefen.dart';
import 'muell_widgets.dart';

class MuellEinstellungenScreen extends ConsumerWidget {
  const MuellEinstellungenScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(muellProvider);
    final rolle = ref.watch(authProvider.select((s) => s.user?.role));
    final eltern = rolle == Role.admin || rolle == Role.parent;
    final admin = rolle == Role.admin;
    final notifier = ref.read(muellProvider.notifier);
    final einst = z.einst;
    final android = ref.watch(erinnerungPortProvider).verfuegbar;
    final sperre = ref.watch(erinnerungEinstellungenProvider.select((e) => e.sperrbildschirmTitel));
    final arten = vorkommendeArten(z.tage);
    // Standard-Arten (auch ohne Termine) und was vorkommt; "Sonstiges" nur, wenn es vorkommt
    final listeArten = [for (final a in MuellArt.values) if (a != MuellArt.sonst || arten.contains(a)) a];
    return AuthSeite(
      label: '// müll',
      titel: 'Einstellungen',
      maxBreite: kMaxContentWidth,
      kinder: [
        LxCard(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: const Text('Im Kalender anzeigen', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('nur Anzeige, nur auf diesem Gerät', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
            value: einst.imKalender,
            onChanged: (v) => unawaited(notifier.kalenderSetzen(v)),
          ),
        ),
        if (eltern) ...[
          const SizedBox(height: 16),
          const MonoLabel('// erinnerung'),
          const SizedBox(height: 8),
          if (!android)
            const MeldungsBox('Erinnerungen gibt es nur in der Android-App. Im Browser zeigt die App keine Benachrichtigungen an.', fehler: false)
          else ...[
            // Fehlen die Systemrechte, kommt keine Erinnerung: der Hinweis sagt, wo man sie erlaubt
            if (ref.watch(erinnerungStatusProvider).value case final s? when s.verfuegbar && !s.erlaubt && !s.unbekannt) ...[
              const MeldungsBox('Benachrichtigungen sind für die App nicht erlaubt, darum kommt keine Erinnerung. Erlaube sie unter Profil > Erinnerungen oder in den Systemeinstellungen.', fehler: false),
              const SizedBox(height: 8),
            ],
            LxCard(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: const Text('Abend vorher erinnern', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('nur für Eltern und Admins, auf diesem Gerät', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                    value: einst.erinnerungAn,
                    onChanged: (v) => unawaited(notifier.erinnerungAnSetzen(v)),
                  ),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    enabled: einst.erinnerungAn,
                    minVerticalPadding: 8,
                    title: const Text('Uhrzeit', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('am Abend vor der Abholung', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: kSurface2, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(8)),
                      child: Text(uhrzeitAusMinuten(einst.minuten), style: const TextStyle(fontFamily: kFontMono, color: kTextStrong)),
                    ),
                    onTap: () async {
                      final t = await showTimePicker(
                        context: context,
                        useRootNavigator: false,
                        initialTime: TimeOfDay(hour: einst.minuten ~/ 60, minute: einst.minuten % 60),
                        helpText: 'Uhrzeit der Erinnerung',
                      );
                      if (t != null) unawaited(notifier.zeitSetzen(t.hour * 60 + t.minute));
                    },
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: const Text('Arten auf dem Sperrbildschirm', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('aus: nur „Morgen ist Abholung“; gilt auch für Termine', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                    value: sperre,
                    onChanged: (v) => unawaited(ref.read(erinnerungEinstellungenProvider.notifier).sperrbildschirmSetzen(v)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const MonoLabel('// für diese abfallarten'),
            const SizedBox(height: 8),
            LxCard(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Column(
                children: [
                  for (final a in listeArten)
                    SwitchListTile(
                      key: ValueKey('muell-art-${a.code}'),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      secondary: MuellSymbol(a),
                      title: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      value: einst.arten.contains(a),
                      onChanged: einst.erinnerungAn ? (v) => unawaited(notifier.artSetzen(a, v)) : null,
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          const MonoLabel('// neue datei'),
          const SizedBox(height: 8),
          const Text('Für ein neues Jahr gibt es die Datei erst später. Der Server prüft das von selbst (im Dezember wöchentlich); hier kannst du es sofort anstoßen.', style: TextStyle(fontSize: 13, color: kTextMuted)),
          const SizedBox(height: 10),
          const MuellPruefenBlock(),
          if (admin) ...[
            const SizedBox(height: 16),
            EinstellungsZeile(icon: Icons.event_repeat_outlined, titel: 'Abfuhrkalender', untertitel: 'status je jahr und prüfungen', onTap: () => unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MuellAbfuhrkalenderScreen())))),
          ],
        ],
        const SizedBox(height: 12),
        const Text('Die Abfuhrtermine lädt der Server (nie dein Gerät) aus dem Abfallkalender; es werden keine persönlichen Daten übertragen. Erinnerungen entstehen nur lokal auf dem Gerät.', style: TextStyle(fontSize: 12, color: kTextMuted)),
      ],
    );
  }
}
