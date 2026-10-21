// Profil > Verschlüsselung (Phase 1 der Ende-zu-Ende-Verschlüsselung): Status, Einrichtung, neues Gerät verbinden, Sicherheitscode,
// Warnungen bei Schlüsselwechsel. Die Schlüssel schützen die Chats (Ende-zu-Ende); diese Seite verwaltet sie.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show MemberStatus;
import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/sicherheitscode.dart';
import '../../data/crypto/vertrauen.dart';
import '../../ui/widgets.dart';
import '../../widgets/benutzer_avatar.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import 'geraet_verbinden_screens.dart';
import 'profile_screen.dart';
import 'pw_sicherung_screen.dart';
import 'wiederherstellungsschluessel_screen.dart';

class VerschluesselungScreen extends ConsumerStatefulWidget {
  const VerschluesselungScreen({super.key});

  @override
  ConsumerState<VerschluesselungScreen> createState() => _VerschluesselungScreenState();
}

class _VerschluesselungScreenState extends ConsumerState<VerschluesselungScreen> with AktionsZustand<VerschluesselungScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(ref.read(e2eeProvider.notifier).laden()));
  }

  E2eeController get _c => ref.read(e2eeProvider.notifier);

  Future<void> _oeffne(Widget seite) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => seite));
    if (mounted) unawaited(_c.laden());
  }

  Future<bool> _bestaetigen(String titel, String text, String knopf) async =>
      await showDialog<bool>(useRootNavigator: false,
        context: context,
        builder: (_) => AlertDialog(
          title: Text(titel),
          content: Text(text),
          scrollable: true,
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: kDanger),
              child: Text(knopf),
            ),
          ],
        ),
      ) ??
      false;

  /// Erstmalige Einrichtung: Schlüssel erzeugen, dann den Wiederherstellungsschlüssel zeigen und sichern lassen.
  Future<void> _einrichten() async {
    Einrichtung? e;
    final ok = await ausfuehren(() async => e = await _c.einrichten());
    final einrichtung = e;
    if (!ok || einrichtung == null || !mounted) return;
    await _oeffne(WiederherstellungsschluesselScreen(einrichtung: einrichtung));
  }

  Future<void> _neuerSchluessel() async {
    Einrichtung? e;
    final ok = await ausfuehren(() async => e = await _c.neuerWiederherstellungsschluessel());
    final einrichtung = e;
    if (!ok || einrichtung == null || !mounted) return;
    await _oeffne(WiederherstellungsschluesselScreen(einrichtung: einrichtung, ersatz: true));
  }

  Future<void> _wechseln() async {
    final ja = await _bestaetigen(
      'Neuen Schlüssel erzeugen?',
      'Damit kannst du verschlüsselte Inhalte, die mit deinem bisherigen Schlüssel geschützt waren, nicht mehr lesen. '
      'Alle anderen in der Familie sehen eine Warnung, dass sich dein Schlüssel geändert hat. Mache das nur, wenn du keinen anderen Weg mehr hast: '
      'kein verbundenes Gerät und keinen Wiederherstellungsschlüssel.',
      'Neuen Schlüssel erzeugen',
    );
    if (!ja || !mounted) return;
    Einrichtung? e;
    final ok = await ausfuehren(() async => e = await mitStepUp(context, ref, _c.schluesselWechseln));
    final einrichtung = e;
    if (!ok || einrichtung == null || !mounted) return;
    await _oeffne(WiederherstellungsschluesselScreen(einrichtung: einrichtung));
  }

  Future<void> _verwerfen() async {
    final ja = await _bestaetigen(
      'Dieses Gerät neu verbinden?',
      'Der Schlüssel wird von diesem Gerät entfernt. Danach verbindest du es wieder per QR-Code von einem anderen Gerät oder mit deinem Wiederherstellungsschlüssel.',
      'Schlüssel entfernen',
    );
    if (!ja || !mounted) return;
    await ausfuehren(_c.lokalenSchluesselVerwerfen);
  }

  Future<void> _vertrauenZuruecksetzen() async {
    final ja = await _bestaetigen(
      'Vertrauen zurücksetzen?',
      'Dieses Gerät vergisst dann alle gemerkten Schlüssel der Familie und den Stand der Chat-Mitglieder. Danach gilt jeder Schlüssel, den der Server nennt, wieder als "beim ersten Sehen" '
      'vertrauenswürdig: Ein falsch untergeschobener Schlüssel würde nicht auffallen. In Chats gilt die erste lesbare Epoche als Basis, und bewusst entfernte Personen könnten '
      'ohne Rückfrage zurückkommen. Vergleiche danach die Sicherheitscodes und die Mitglieder deiner Chats mit den Personen. Verschlüsselte Chats bleiben lesbar.',
      'Vertrauen zurücksetzen',
    );
    if (!ja || !mounted) return;
    await ausfuehren(_c.vertrauenZuruecksetzen);
  }

  Future<void> _akzeptieren(SchluesselWarnung w, String name) async {
    final ja = await _bestaetigen(
      'Neuen Schlüssel akzeptieren?',
      'Akzeptiere den neuen Schlüssel von $name nur, wenn $name den Wechsel bestätigt hat, am besten durch Vergleichen des Sicherheitscodes. '
      'Sonst könnte jemand einen falschen Schlüssel untergeschoben haben.',
      'Neuen Schlüssel akzeptieren',
    );
    if (!ja || !mounted) return;
    await ausfuehren(() => _c.warnungAkzeptieren(w.userId));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(e2eeProvider);
    final auth = ref.watch(authProvider);
    return AuthSeite(
      label: '// verschlüsselung',
      titel: 'Verschlüsselung',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Mit einem persönlichen Schlüssel, der nur auf deinen Geräten liegt, werden deine Chat-Nachrichten so geschützt, dass sie nicht einmal der Server lesen kann. '
          'Ohne eingerichteten Schlüssel kannst du Chats nicht lesen und nicht schreiben.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        ..._warnungen(s),
        ..._inhalt(s, auth),
        const SizedBox(height: 16),
        const _Vertrauensmodell(),
      ],
    );
  }

  List<Widget> _warnungen(E2eeState s) {
    if (s.warnungen.isEmpty) return const [];
    String name(String id) => s.mitglieder.where((m) => m.id == id).map((m) => m.displayName).firstOrNull ?? 'Unbekannt';
    return [
      for (final w in s.warnungen) ...[
        _WarnKarte(
          name: name(w.userId),
          warnung: w,
          onAkzeptieren: laeuft ? null : () => _akzeptieren(w, name(w.userId)),
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  List<Widget> _inhalt(E2eeState s, AuthState auth) {
    switch (s.status) {
      case E2eeStatus.laedt:
        return const [Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))];
      case E2eeStatus.nichtVerfuegbar:
        return [
          MeldungsBox(s.meldung ?? 'Die Verschlüsselung ist gerade nicht verfügbar.'),
          const SizedBox(height: 12),
          if (s.vertrauenDefekt)
            ZweitKnopf(text: 'Vertrauen zurücksetzen', icon: Icons.restart_alt, onPressed: laeuft ? null : _vertrauenZuruecksetzen)
          else
            ZweitKnopf(text: 'Erneut versuchen', icon: Icons.refresh, onPressed: laeuft ? null : () => unawaited(_c.laden())),
        ];
      case E2eeStatus.keinSchluessel:
        return [
          const MonoLabel('// status'),
          const SizedBox(height: 8),
          const EinstellungsZeile(icon: Icons.lock_open, titel: 'Nicht eingerichtet', untertitel: 'noch kein schlüssel'),
          const SizedBox(height: 8),
          const Text(
            'Bei der Einrichtung entsteht dein Schlüssel auf diesem Gerät. Du bekommst einen Wiederherstellungsschlüssel, den du sicher aufbewahrst, '
            'damit du ihn auch nach Geräteverlust nicht verlierst.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          HauptKnopf(text: 'Verschlüsselung einrichten', icon: Icons.lock_outline, laeuft: laeuft, onPressed: _einrichten),
        ];
      case E2eeStatus.geraetNichtVerbunden:
        return [
          const MonoLabel('// status'),
          const SizedBox(height: 8),
          const EinstellungsZeile(icon: Icons.phonelink_lock, titel: 'Dieses Gerät ist nicht verbunden', untertitel: 'schlüssel fehlt hier'),
          const SizedBox(height: 8),
          const Text(
            'Dein Schlüssel liegt auf einem anderen Gerät. Verbinde dieses Gerät per QR-Code oder Code von dort, oder mit deinem Wiederherstellungsschlüssel.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          HauptKnopf(text: 'Mit anderem Gerät verbinden', icon: Icons.qr_code_scanner, onPressed: laeuft ? null : () => _oeffne(const GeraetVerbindenScreen())),
          const SizedBox(height: 8),
          ZweitKnopf(
            text: 'Mit Wiederherstellungsschlüssel verbinden',
            icon: Icons.key_outlined,
            onPressed: laeuft || !s.hatSicherung ? null : () => _oeffne(const WiederherstellungVerbindenScreen()),
          ),
          if (!s.hatSicherung) ...[
            const SizedBox(height: 8),
            const Text('Es gibt noch keine Sicherung mit einem Wiederherstellungsschlüssel.', style: TextStyle(fontSize: 13, color: kTextMuted)),
          ],
          if (s.pwSicherungVerfuegbar) ...[
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Mit Passwort verbinden', icon: Icons.password, onPressed: laeuft ? null : () => _oeffne(const PwVerbindenScreen())),
          ],
          const SizedBox(height: 16),
          _gefahr(),
        ];
      case E2eeStatus.abweichend:
        return [
          const MeldungsBox(
            'Der Schlüssel auf diesem Gerät passt nicht mehr zu deinem Konto. Vermutlich wurde er auf einem anderen Gerät gewechselt. Verbinde dieses Gerät neu.',
          ),
          const SizedBox(height: 12),
          HauptKnopf(text: 'Dieses Gerät neu verbinden', icon: Icons.sync_problem, laeuft: laeuft, onPressed: _verwerfen),
        ];
      case E2eeStatus.bereit:
        return [
          const MonoLabel('// status'),
          const SizedBox(height: 8),
          EinstellungsZeile(
            icon: Icons.lock,
            titel: 'Eingerichtet',
            untertitel: 'schlüsselversion ${s.serverSchluessel?.version ?? 1}',
            status: const RollenPille('aktiv', farbe: kTerminal),
          ),
          EinstellungsZeile(
            icon: Icons.key_outlined,
            titel: 'Wiederherstellungsschlüssel',
            untertitel: s.hatSicherung ? 'gesichert · neuen erzeugen' : 'nicht gesichert · jetzt erzeugen',
            status: s.hatSicherung ? null : const RollenPille('offen', farbe: kWarn),
            onTap: laeuft ? null : _neuerSchluessel,
          ),
          if (s.pwSicherungVerfuegbar) _pwZeile(s),
          EinstellungsZeile(
            icon: Icons.qr_code_2,
            titel: 'Neues Gerät verbinden',
            untertitel: 'qr-code oder code zeigen',
            onTap: laeuft ? null : () => _oeffne(const UebertragungAnbietenScreen()),
          ),
          const SizedBox(height: 12),
          _SicherheitscodeKarte(state: s, eigeneId: auth.user?.id),
          const SizedBox(height: 16),
          _gefahr(),
        ];
    }
  }

  /// Passwort-Sicherung (nur wenn der Server sie anbietet): zusätzlich zum Wiederherstellungsschlüssel, ersetzt ihn nicht.
  Widget _pwZeile(E2eeState s) {
    final v = s.pwSicherungVersion;
    final aktuell = s.serverSchluessel?.version;
    final (String untertitel, Widget pille) = s.pwSicherungVeraltet && s.status == E2eeStatus.bereit
        ? ('veraltet nach Passwort-Reset · Sicherung erneuern', const RollenPille('erneuern', farbe: kWarn))
        : v == null
        ? ('nicht gesichert · jetzt einrichten', const RollenPille('offen', farbe: kWarn))
        : v == aktuell
        ? ('geprüft · neues passwort wählen', const RollenPille('aktiv', farbe: kTerminal))
        : ('veraltet · neu sichern', const RollenPille('offen', farbe: kWarn));
    return EinstellungsZeile(
      icon: Icons.password,
      titel: 'Passwort-Sicherung',
      untertitel: untertitel,
      status: pille,
      onTap: laeuft ? null : () => _oeffne(const PwSicherungScreen()),
    );
  }

  Widget _gefahr() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const MonoLabel('// notfall', color: kTextMuted),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: laeuft ? null : _wechseln,
        style: OutlinedButton.styleFrom(foregroundColor: kDanger, side: const BorderSide(color: kDanger), minimumSize: const Size.fromHeight(48)),
        icon: const Icon(Icons.warning_amber_rounded),
        label: const Text('Neuen Schlüssel erzeugen', textAlign: TextAlign.center),
      ),
      const SizedBox(height: 4),
      const Text(
        'Nur, wenn dir kein Gerät und kein Wiederherstellungsschlüssel mehr bleibt. Alte verschlüsselte Inhalte lassen sich dann nicht mehr lesen.',
        style: TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
      ),
    ],
  );
}

/// Warnung: Der Schlüssel einer Person hat sich geändert (oder fehlt jetzt).
class _WarnKarte extends StatelessWidget {
  final String name;
  final SchluesselWarnung warnung;
  final VoidCallback? onAkzeptieren;
  const _WarnKarte({required this.name, required this.warnung, required this.onAkzeptieren});

  @override
  Widget build(BuildContext context) {
    final alt = VertrauensPruefer.codeVon(warnung.userId, warnung.gemerkt);
    final neu = warnung.aktuell == null ? null : personenSicherheitscode(MitgliedSchluessel(warnung.userId, warnung.aktuell!));
    return Semantics(
      container: true,
      label: 'Warnung: Der Schlüssel von $name hat sich geändert',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kDanger.withValues(alpha: 0.08),
          border: Border.all(color: kDanger.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, color: kDanger),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    warnung.rueckfall
                        ? 'Der Server nennt für $name einen ÄLTEREN Schlüssel als bisher.'
                        : neu == null
                        ? 'Der Schlüssel von $name fehlt jetzt.'
                        : 'Der Schlüssel von $name hat sich geändert.',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (warnung.rueckfall)
              const Text(
                'Schlüsselversionen steigen nur. Ein Rückfall ist ein Hinweis auf einen Fehler oder einen Angriff auf den Server; die App akzeptiert ihn nie. Melde das dem Admin.',
                style: TextStyle(fontSize: 13, height: 1.4, color: kText),
              )
            else
              const Text(
              'Das kann vorkommen, wenn die Person ein neues Konto oder alle Geräte verloren hat. Es kann aber auch ein Angriff sein. Frage die Person und vergleiche den Sicherheitscode, '
              'bevor du den neuen Schlüssel akzeptierst. Bis dahin vertraut die App ihm nicht.',
              style: TextStyle(fontSize: 13, height: 1.4, color: kText),
            ),
            const SizedBox(height: 8),
            Text('bisher: $alt', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
            if (neu != null) Text('neu:    $neu', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kWarn)),
            const SizedBox(height: 10),
            if (!warnung.rueckfall) ZweitKnopf(text: 'Neuen Schlüssel akzeptieren', icon: Icons.check, onPressed: onAkzeptieren),
          ],
        ),
      ),
    );
  }
}

/// Familien-Sicherheitscode und Codes je Person zum optionalen Vergleichen (vorlesen oder abgleichen, nicht über denselben Chat).
class _SicherheitscodeKarte extends StatelessWidget {
  final E2eeState state;
  final String? eigeneId;
  const _SicherheitscodeKarte({required this.state, required this.eigeneId});

  @override
  Widget build(BuildContext context) {
    final mitSchluessel = state.mitglieder.where((m) => m.schluessel != null && m.status == MemberStatus.active).toList();
    return LxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MonoLabel('// sicherheitscode'),
          const SizedBox(height: 8),
          Semantics(
            label: 'Sicherheitscode der Familie: ${state.sicherheitscode}',
            child: SelectableText(
              state.sicherheitscode.isEmpty ? '–' : state.sicherheitscode,
              style: const TextStyle(fontFamily: kFontMono, fontSize: 18, height: 1.5, color: kAccent, letterSpacing: 1.2),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Dieser Code entsteht aus den öffentlichen Schlüsseln aller Familienmitglieder. Stimmt er auf euren Geräten überein (zum Beispiel beim nächsten Treffen oder am Telefon vorlesen), '
            'hat niemand Schlüssel untergeschoben. Das Vergleichen ist freiwillig.',
            style: TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
          ),
          if (mitSchluessel.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Codes je Person', style: TextStyle(fontSize: 14)),
                children: [
                  for (final m in mitSchluessel)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          BenutzerAvatar(user: m, size: 32),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(m.id == eigeneId ? '${m.displayName} (du)' : m.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                SelectableText(
                                  personenSicherheitscode(MitgliedSchluessel(m.id, m.schluessel!)),
                                  style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Ehrliche Erklärung, was die Verschlüsselung schützt und was nicht.
class _Vertrauensmodell extends StatelessWidget {
  const _Vertrauensmodell();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      MonoLabel('// was das schützt', color: kTextMuted),
      SizedBox(height: 6),
      Text(
        'Geschützt vor einem Datenleck auf dem Server, vor dem Hoster und vor gestohlenen Sicherungen. '
        'Nicht geschützt: Wer wann mit wem schreibt (Metadaten) sieht der Server weiterhin. '
        'Und ein bösartiger Admin des Servers könnte falsche Schlüssel unterschieben; die App warnt bei Änderungen, '
        'sicher bist du aber erst, wenn ihr den Sicherheitscode einmal vergleicht.',
        style: TextStyle(fontSize: 12, height: 1.5, color: kTextMuted),
      ),
    ],
  );
}

/// Zeile für das Profil: zeigt den Zustand der Verschlüsselung (Warnung bei Schlüsselwechsel).
class VerschluesselungsZeile extends ConsumerWidget {
  final VoidCallback onTap;
  const VerschluesselungsZeile({super.key, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(e2eeProvider);
    final (String untertitel, Widget? pille) = switch (s.status) {
      _ when s.warnungen.isNotEmpty => ('schlüssel geändert', const RollenPille('Warnung', farbe: kDanger)),
      E2eeStatus.bereit => ('schlüssel · geräte verbinden', const RollenPille('aktiv', farbe: kTerminal)),
      E2eeStatus.keinSchluessel => ('nicht eingerichtet', null),
      E2eeStatus.geraetNichtVerbunden => ('gerät verbinden', const RollenPille('offen', farbe: kWarn)),
      E2eeStatus.abweichend => ('schlüssel weicht ab', const RollenPille('Warnung', farbe: kDanger)),
      _ => ('schlüssel · geräte verbinden', null),
    };
    return EinstellungsZeile(icon: Icons.lock_outline, titel: 'Verschlüsselung', untertitel: untertitel, status: pille, onTap: onTap);
  }
}
