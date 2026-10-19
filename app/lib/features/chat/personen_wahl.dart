// Personen für einen Chat wählen: "Neuer Chat" (eine Person = Direktchat, mehrere = Gruppe mit optionalem Namen) und "Teilnehmer ändern".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/nachrichten_inhalt.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/lists/members.dart';
import '../../ui/widgets.dart';
import 'chat_krypto_ui.dart';

/// Ergebnis der Auswahl: die gewählten Personen (ohne die eigene) und der Gruppenname (leer: ohne Namen).
class PersonenAuswahl {
  final Set<String> personen;
  final String name;
  const PersonenAuswahl(this.personen, this.name);
}

enum PersonenWahlModus {
  /// Neuer Chat: eine Person ergibt einen Direktchat, mehrere eine Gruppe.
  neuerChat,

  /// Teilnehmer einer Gruppe ändern (mindestens eine weitere Person).
  teilnehmer,
}

class PersonenWahlSeite extends ConsumerStatefulWidget {
  final PersonenWahlModus modus;
  final Set<String> vorgewaehlt;
  const PersonenWahlSeite({super.key, required this.modus, this.vorgewaehlt = const {}});

  @override
  ConsumerState<PersonenWahlSeite> createState() => _PersonenWahlSeiteState();
}

class _PersonenWahlSeiteState extends ConsumerState<PersonenWahlSeite> {
  late final Set<String> _gewaehlt = {...widget.vorgewaehlt};
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _neu => widget.modus == PersonenWahlModus.neuerChat;
  bool get _gruppe => _gewaehlt.length >= 2;
  bool get _gueltig => _neu ? _gewaehlt.isNotEmpty : _gewaehlt.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final ich = ref.watch(authProvider.select((s) => s.user?.id));
    final async = ref.watch(mitgliederProvider);
    final andere = [for (final u in async.value ?? const <UserDto>[]) if (u.id != ich) u];
    final krypto = ref.watch(e2eeProvider);
    final knopf = _neu ? (_gruppe ? 'Gruppe anlegen' : 'Chat starten') : 'Übernehmen';
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: Text(_neu ? 'Neuer Chat' : 'Teilnehmer ändern')),
      body: LxBackground(
        child: SafeArea(
          child: LxContentWidth(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _neu ? 'Wähle eine Person für einen Direktchat oder mehrere für eine Gruppe.' : 'Wer gehört zur Gruppe? Du bleibst dabei.',
                      style: const TextStyle(color: kTextMuted),
                    ),
                  ),
                ),
                Expanded(
                  child: async.hasError && andere.isEmpty
                      ? const EmptyState(icon: Icons.wifi_off, title: 'Mitglieder nicht geladen', hint: 'Prüfe die Verbindung und versuche es noch einmal.')
                      : andere.isEmpty
                      ? EmptyState(
                          icon: Icons.group_outlined,
                          title: async.isLoading ? 'Lädt …' : 'Keine weiteren Mitglieder',
                          hint: async.isLoading ? 'Die Familie wird geladen.' : 'Lade zuerst jemanden in die Familie ein.',
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          children: [
                            for (final u in andere)
                              Semantics(
                                container: true,
                                checked: _gewaehlt.contains(u.id),
                                enabled: _waehlbar(u.id, personKryptoHindernis(krypto, u.id)),
                                label: '${u.displayName}, ${u.role.label}${personKryptoHindernis(krypto, u.id) == null ? '' : ', ${personKryptoHindernis(krypto, u.id)}'}',
                                excludeSemantics: true,
                                onTap: _waehlbar(u.id, personKryptoHindernis(krypto, u.id)) ? () => _umschalten(u.id) : null,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: _waehlbar(u.id, personKryptoHindernis(krypto, u.id)) ? () => _umschalten(u.id) : null,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(minHeight: 56),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      child: Row(
                                        children: [
                                          PersonAvatar(name: u.displayName, colorIndex: u.colorIndex, size: 36),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(u.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _waehlbar(u.id, personKryptoHindernis(krypto, u.id)) ? kText : kTextMuted)),
                                                // Personen ohne eingerichtete Verschlüsselung können nicht teilnehmen, bis sie so weit sind
                                                if (personKryptoHindernis(krypto, u.id) case final h?) Text(h, style: const TextStyle(fontSize: 12, color: kWarn)),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(u.role.label.toLowerCase(), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                                          ExcludeSemantics(
                                            child: Checkbox(
                                              value: _gewaehlt.contains(u.id),
                                              onChanged: _waehlbar(u.id, personKryptoHindernis(krypto, u.id)) ? (_) => _umschalten(u.id) : null,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
                if (_neu && _gruppe)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: TextField(
                      controller: _name,
                      maxLength: kMaxChatNameZeichen,
                      inputFormatters: [LengthLimitingTextInputFormatter(kMaxChatNameZeichen)],
                      decoration: const InputDecoration(labelText: 'Gruppenname (optional)', counterText: ''),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(onPressed: _gueltig ? () => Navigator.of(context).pop(PersonenAuswahl({..._gewaehlt}, _gruppe ? _name.text.trim() : '')) : null, child: Text(knopf)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Eine Person ohne eingerichtete Verschlüsselung (oder mit ungeprüftem Schlüssel) lässt sich nicht neu wählen; wer schon gewählt ist, kann abgewählt werden.
  bool _waehlbar(String id, String? hindernis) => hindernis == null || _gewaehlt.contains(id);

  /// Höchstens 20 Teilnehmer je Gruppe (mit der eigenen Person), wie auf dem Server.
  static const _maxAndere = 19;

  void _umschalten(String id) => setState(() {
    if (_gewaehlt.remove(id)) return;
    if (_gewaehlt.length < _maxAndere) {
      _gewaehlt.add(id);
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Eine Gruppe hat höchstens 20 Teilnehmer.')));
    }
  });
}
