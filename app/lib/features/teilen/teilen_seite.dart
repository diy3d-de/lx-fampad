// "Teilen mit lx-familyhub" (Android): Auswahl, wohin ein von einer anderen App geteilter Text soll: als neuer Eintrag in eine Liste, als Aufgabe oder als Nachricht in einen
// Chat (nur über den normalen, Ende-zu-Ende verschlüsselten Sendeweg des Chats). Die Seite erscheint erst nach der Anmeldung (siehe app.dart); Abbrechen und Zurück verwerfen den
// Text. Nur Text, nie Bilder oder Dateien. Der Text wird nirgends protokolliert.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/chat/nachrichten_inhalt.dart' show nachrichtenInhaltProvider;
import '../../data/crypto/e2ee_state.dart';
import '../../data/lists/list_repository.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../../data/teilen/teilen_logik.dart';
import '../../data/teilen/teilen_state.dart';
import '../../ui/widgets.dart';
import '../chat/chat_anzeige.dart';
import '../chat/chat_krypto_ui.dart';
import '../lists/list_dialogs.dart' show textDialog;

class TeilenSeite extends ConsumerStatefulWidget {
  const TeilenSeite({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TeilenSeite());

  @override
  ConsumerState<TeilenSeite> createState() => _TeilenSeiteState();
}

class _Eintrag {
  final String id;
  final String titel;
  final String untertitel;
  const _Eintrag(this.id, this.titel, this.untertitel);
}

class _TeilenSeiteState extends ConsumerState<TeilenSeite> {
  bool _beschaeftigt = false;

  void _fertig(String meldung) {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    ref.read(teilenProvider.notifier).verwerfen();
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(meldung)));
  }

  void _hinweis(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<String?> _waehlen(String titel, List<_Eintrag> eintraege) => showModalBottomSheet<String>(
    useRootNavigator: false,
    context: context,
    backgroundColor: kSurface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Semantics(header: true, child: Text(titel, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kTextStrong))),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in eintraege)
                    ListTile(
                      minTileHeight: 52,
                      title: Text(e.titel, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: e.untertitel.isEmpty ? null : Text(e.untertitel, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.of(c).pop(e.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _alsListe(String text) async {
    final listen = ref.read(listenProvider).value ?? const <Liste>[];
    if (listen.isEmpty) return;
    final id = await _waehlen('In welche Liste?', [for (final l in listen) _Eintrag(l.id, l.name, '')]);
    if (id == null || !mounted) return;
    final liste = listen.firstWhere((l) => l.id == id);
    setState(() => _beschaeftigt = true);
    try {
      await ref.read(listenRepositoryProvider).eintragAnlegen(id, eintragsText(text));
    } on Object {
      if (mounted) {
        setState(() => _beschaeftigt = false);
        _hinweis('Der Eintrag konnte nicht angelegt werden.');
      }
      return;
    }
    if (mounted) _fertig('Zu „${liste.name}“ hinzugefügt.');
  }

  Future<void> _alsAufgabe(String text) async {
    final vorschlag = aufgabenTitel(text);
    final titel = await textDialog(context, titel: 'Aufgabe anlegen', label: 'Titel', start: vorschlag, maxLaenge: kMaxAufgabeTitelZeichen, knopf: 'Anlegen');
    if (titel == null || !mounted) return;
    setState(() => _beschaeftigt = true);
    try {
      await ref.read(aufgabeRepositoryProvider).anlegen(AufgabeEingabe(titel: titel, beschreibung: aufgabenNotiz(text, titel)));
    } on Object {
      if (mounted) {
        setState(() => _beschaeftigt = false);
        _hinweis('Die Aufgabe konnte nicht angelegt werden.');
      }
      return;
    }
    if (mounted) _fertig('Aufgabe angelegt.');
  }

  Future<void> _alsNachricht(String text) async {
    final eintraege = [for (final e in ref.read(chatUebersichtProvider).value ?? const <ChatEintrag>[]) if (e.konversation.encVersion == 'e1') e];
    if (eintraege.isEmpty) return;
    final mitglieder = chatMitglieder(ref, eintraege);
    final ich = ref.read(authProvider).user?.id;
    final inhalt = ref.read(nachrichtenInhaltProvider);
    final namen = {for (final e in eintraege) e.id: chatName(e.konversation, e.teilnehmer, mitglieder, ich, inhalt)};
    final id = await _waehlen('In welchen Chat senden?', [
      for (final e in eintraege)
        _Eintrag(e.id, namen[e.id]!, switch (e.art) { ChatArt.family => 'alle in der Familie', ChatArt.direct => 'Direktchat', ChatArt.group => 'Gruppe', ChatArt.meds => 'Medikamente', ChatArt.zaehler => 'Zähler', ChatArt.tresor => 'Tresor' }),
    ]);
    if (id == null || !mounted) return;
    setState(() => _beschaeftigt = true);
    try {
      await ref.read(chatRepositoryProvider).senden(id, text);
    } on NachrichtZuLang {
      if (mounted) {
        setState(() => _beschaeftigt = false);
        _hinweis('Der Text ist für eine Nachricht zu lang. Teile einen kürzeren Ausschnitt.');
      }
      return;
    } on ChatNichtVerschluesselt {
      if (mounted) {
        setState(() => _beschaeftigt = false);
        _hinweis('Dieser Chat ist nicht verschlüsselt. Neue Nachrichten sind hier nicht möglich.');
      }
      return;
    } on Object {
      if (mounted) {
        setState(() => _beschaeftigt = false);
        _hinweis('Die Nachricht konnte nicht gesendet werden.');
      }
      return;
    }
    if (mounted) _fertig('An „${namen[id]}“ gesendet (verschlüsselt).');
  }

  void _abbrechen() {
    ref.read(teilenProvider.notifier).verwerfen();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final text = ref.watch(teilenProvider);
    final listen = ref.watch(listenProvider).value ?? const <Liste>[];
    final chats = ref.watch(chatUebersichtProvider).value ?? const <ChatEintrag>[];
    final chatBereit = chatKryptoZustand(ref.watch(e2eeProvider)).darfSchreiben && chats.any((e) => e.konversation.encVersion == 'e1');
    final t = text ?? '';
    return PopScope(
      onPopInvokedWithResult: (_, _) => ref.read(teilenProvider.notifier).verwerfen(),
      child: Scaffold(
        backgroundColor: kBg,
        body: LxBackground(
          child: Material(
            type: MaterialType.transparency,
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    children: [
                      const MonoLabel('Teilen'),
                      const SizedBox(height: 4),
                      Semantics(
                        header: true,
                        child: const Text('Teilen mit lx-familyhub', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.65, color: kTextStrong)),
                      ),
                      const SizedBox(height: 12),
                      if (t.isEmpty)
                        const Text('Es wartet kein Text mehr.', style: TextStyle(color: kTextMuted))
                      else ...[
                        LxCard(
                          child: Semantics(
                            label: 'Geteilter Text: ${teilenVorschau(t)}',
                            excludeSemantics: true,
                            child: Text(teilenVorschau(t), maxLines: 8, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.4, color: kText)),
                          ),
                        ),
                        if (teilenWahrscheinlichGekuerzt(t))
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text('Der Text wurde auf $kMaxTeilenZeichen Zeichen gekürzt.', style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                          ),
                        const SizedBox(height: 16),
                        const MonoLabel('Wohin damit?'),
                        const SizedBox(height: 8),
                        _Ziel(icon: Icons.checklist_outlined, titel: 'Zu einer Liste hinzufügen', hinweis: listen.isEmpty ? 'Noch keine Liste vorhanden.' : 'Als neuer Eintrag oben in der Liste.', aktiv: listen.isNotEmpty && !_beschaeftigt, onTap: () => _alsListe(t)),
                        _Ziel(icon: Icons.task_alt_outlined, titel: 'Als Aufgabe anlegen', hinweis: 'Titel und Notiz kannst du gleich anpassen.', aktiv: !_beschaeftigt, onTap: () => _alsAufgabe(t)),
                        _Ziel(
                          icon: Icons.chat_bubble_outline,
                          titel: 'Als Nachricht in einen Chat',
                          hinweis: chatBereit ? 'Wird Ende-zu-Ende verschlüsselt gesendet.' : 'Dafür muss der Nachrichten-Schutz auf diesem Gerät bereit sein.',
                          aktiv: chatBereit && !_beschaeftigt,
                          onTap: () => _alsNachricht(t),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          style: TextButton.styleFrom(minimumSize: const Size(44, 48), foregroundColor: kTextMuted),
                          onPressed: _beschaeftigt ? null : _abbrechen,
                          child: const Text('Abbrechen'),
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
    );
  }
}

class _Ziel extends StatelessWidget {
  final IconData icon;
  final String titel;
  final String hinweis;
  final bool aktiv;
  final VoidCallback onTap;
  const _Ziel({required this.icon, required this.titel, required this.hinweis, required this.aktiv, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Semantics(
      button: true,
      enabled: aktiv,
      label: '$titel. $hinweis',
      excludeSemantics: true,
      onTap: aktiv ? onTap : null,
      child: Opacity(
        opacity: aktiv ? 1 : 0.6,
        child: LxCard(
          onTap: aktiv ? onTap : null,
          child: Row(
            children: [
              Icon(icon, color: kAccent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titel, style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong)),
                    const SizedBox(height: 2),
                    Text(hinweis, style: const TextStyle(fontSize: 12, color: kTextMuted, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
