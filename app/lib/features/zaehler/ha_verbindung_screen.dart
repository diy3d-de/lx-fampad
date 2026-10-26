// Seite "Home Assistant" (Zähler, Abschnitt 6l). Auf dem Abholgerät (dem Gerät mit dem Postfach-Schlüssel): Schalter "Werte automatisch abholen" (je Gerät), der Zustand nach Handlungen
// geordnet (zuerst, was die Person tun kann: Zu prüfen, Zähler zuordnen; dann die letzte Abholung; Zahlen für Technikinteressierte eingeklappt), "Jetzt abholen". Auf jedem anderen Gerät
// (zweites Elternteil) kein Schalter und kein "aus": ein ruhiger Text "Läuft über ein anderes Gerät" mit dem Stand der Zähler. Dazu die Verbindungsliste und für Admins das Koppeln und
// Trennen. Erreichbar über die Zeile "Home Assistant" der Zähler-Seite; nur für Eltern und Admins und nur, wenn der Server den Einwurf kennt. Der Server sieht nur verschlüsselte Werte;
// sie öffnet nur das Abholgerät. Nie Werte, Kanäle oder Päckchen in Meldungen, nie ein Servertext.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/api/models.dart' show Role;
import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart' show schluesselSpeicherProvider;
import '../../data/ingest/ingest_anzeige.dart';
import '../../data/ingest/ingest_dienst.dart' show ingestAbbruchText;
import '../../data/ingest/ingest_logik.dart' show paketLoeschInTagen, paketLoeschText;
import '../../data/ingest/ingest_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart' show tagDeutsch;
import '../../data/zaehler/zaehler_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import '../lists/list_dialogs.dart' show bestaetigen;
import 'ha_koppeln_screen.dart';
import 'ha_pruefen_screen.dart';
import 'ha_zuordnen_screen.dart';
import 'zaehler_anzeige.dart';

/// Öffnet die Seite (nur Eltern und Admins; für alle anderen passiert nichts).
Future<void> haVerbindungOeffnen(BuildContext context) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const HaVerbindungScreen()));
}

/// Meldung zu einem Fehler (nie ein Servertext oder ein Wert).
String haFehlerText(Object e) => e is ApiException ? e.message : zaehlerFehlerText(e);

/// "heute 12:05", sonst "26.10. 12:05" (Ortszeit des Geräts).
String haZeitText(DateTime t, DateTime jetzt) {
  final l = t.toLocal();
  final n = jetzt.toLocal();
  final uhr = '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  if (l.year == n.year && l.month == n.month && l.day == n.day) return 'heute $uhr';
  return '${l.day.toString().padLeft(2, '0')}.${l.month.toString().padLeft(2, '0')}. $uhr';
}

class HaVerbindungScreen extends ConsumerStatefulWidget {
  const HaVerbindungScreen({super.key});

  @override
  ConsumerState<HaVerbindungScreen> createState() => _HaVerbindungScreenState();
}

class _HaVerbindungScreenState extends ConsumerState<HaVerbindungScreen> {
  String? _fehler;
  var _beschaeftigt = false;

  @override
  void initState() {
    super.initState();
    unawaited(Future.microtask(() => ref.read(ingestProvider.notifier).neuLesen()));
  }

  Future<void> _trennen(IngestVerbindungStand v) async {
    final ok = await bestaetigen(
      context,
      titel: 'Verbindung trennen?',
      text: '„${v.name}“ kann dann keine Werte mehr einwerfen. Schon abgelegte Werte bleiben beim Server abholbar, bis du sie abgeholt hast (höchstens 30 Tage).',
      knopf: 'Trennen',
    );
    if (!ok || !mounted) return;
    setState(() {
      _beschaeftigt = true;
      _fehler = null;
    });
    try {
      final api = ref.read(apiProvider);
      final erledigt = await mitStepUp<bool>(context, ref, () async {
        await api.ingestTokenWiderrufen(v.id);
        return true;
      });
      if (erledigt != true || !mounted) {
        if (mounted) setState(() => _beschaeftigt = false);
        return;
      }
      ref.invalidate(ingestVerbindungenProvider);
      // Die Verbindung ist getrennt. Was danach noch schiefgeht (Liste, Schlüssel dieses Geräts), ist KEIN Fehler des Trennens und zeigt nie eine Fehlermeldung dazu.
      try {
        // war es die letzte aktive Verbindung, kann der Postfach-Schlüssel von diesem Gerät weg (nach Bestätigung)
        final rest = (await api.ingestTokens()).where((t) => t.aktiv).length;
        final uid = ref.read(authProvider).user?.id;
        if (rest == 0 && uid != null && ref.read(ingestProvider).postfachDa && mounted) {
          // ein letzter Abholvorgang, solange der Schlüssel noch da ist (die Päckchen der getrennten Verbindung bleiben abholbar); scheitert er, geht es trotzdem weiter
          var offen = 0;
          try {
            final lauf = await ref.read(ingestDienstProvider).abholen();
            if (lauf.ok) offen = lauf.wartend;
          } on Object {
            // ohne letzten Abholvorgang weiter
          }
          if (!mounted) return;
          final weg = await bestaetigen(
            context,
            titel: 'Schlüssel dieser Verbindung löschen?',
            text:
                'Das war die letzte Verbindung. Soll auch der Schlüssel zum Öffnen der Werte von diesem Gerät gelöscht werden? '
                'Noch nicht abgeholte Werte lassen sich danach nicht mehr öffnen und gehen verloren.'
                '${offen > 0 ? ' Beim Server warten noch $offen ${offen == 1 ? 'Wert' : 'Werte'} (zum Beispiel zur Prüfung oder ohne Zähler).' : ''}',
            knopf: 'Löschen',
          );
          if (weg) {
            await ref.read(ingestProvider.notifier).schalterSetzen(false);
            await postfachSchluesselLoeschen(ref.read(schluesselSpeicherProvider), uid);
            await ref.read(ingestProvider.notifier).neuLesen();
          }
        }
      } on Object {
        // nur die Nacharbeit: die Liste lädt sich beim nächsten Öffnen neu
      }
      if (mounted) setState(() => _beschaeftigt = false);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _beschaeftigt = false;
          _fehler = haFehlerText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(zaehlerDarfProvider)) {
      return const AuthSeite(titel: 'Nicht verfügbar', maxBreite: kMaxContentWidth, kinder: [EmptyState(icon: Icons.lock_outline, title: 'Nicht verfügbar', hint: 'Diesen Bereich gibt es für dich nicht.')]);
    }
    final z = ref.watch(ingestProvider);
    final admin = ref.watch(authProvider.select((a) => a.user?.role)) == Role.admin;
    final daten = ref.watch(zaehlerDatenProvider);
    final jetzt = DateTime.now();
    final lauf = z.letzter;
    final abbruch = lauf?.abbruch;
    final text = StringBuffer();
    if (lauf != null && abbruch == null) {
      text.write('${haZeitText(lauf.zeit, jetzt)} · ${lauf.eingetragen == 1 ? '1 Wert' : '${lauf.eingetragen} Werte'} eingetragen');
    }
    // Ein Gerät ohne Postfach-Schlüssel holt nie ab (zweites Elternteil, anderes Gerät): dort kein Schalter, nur ein ruhiger Hinweis. Solange noch nicht gelesen wurde, wird nichts behauptet.
    final anderesGeraet = z.geladen && !z.postfachDa;
    final letzter = letzterAutomatischerStand(daten.reihen);
    final doppelt = doppeltBelieferte(daten.eintraege);
    final ohneLoeschen = lauf == null || lauf.ohneZaehler == 0 ? null : paketLoeschInTagen(lauf.aeltestOhneZaehler, jetzt);
    String werte(int n) => n == 1 ? '1 Wert' : '$n Werte';
    return AuthSeite(
      label: '// zähler',
      titel: 'Home Assistant',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
        if (anderesGeraet)
          LxCard(
            child: Semantics(
              container: true,
              label: 'Läuft über ein anderes Gerät. Die Werte holt das Gerät ab, auf dem die Verbindung gekoppelt wurde.${letzter == null ? '' : ' Letzter Wert: ${letzter.name}, ${tagDeutsch(letzter.tag)}.'}',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [Icon(Icons.devices_other, size: 20, color: kAccent), SizedBox(width: 10), Expanded(child: Text('Läuft über ein anderes Gerät', style: TextStyle(fontWeight: FontWeight.w700)))]),
                  const SizedBox(height: 6),
                  const Text('Die Werte aus Home Assistant holt das Gerät ab, auf dem die Verbindung gekoppelt wurde. Du siehst sie trotzdem in deinen Zählern, sobald dieses Gerät sie abgeholt hat.', style: TextStyle(fontSize: 13, color: kTextMuted)),
                  const SizedBox(height: 8),
                  Text(letzter == null ? 'Noch kein Wert angekommen.' : 'Letzter Wert: ${letzter.name} · ${tagDeutsch(letzter.tag)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
          )
        else ...[
          if (z.geladen && z.postfachDa && !z.schalter) ...[
            LxCard(
              child: Semantics(
                container: true,
                label: 'Dieses Gerät holt gerade keine Werte ab. Einschalten möglich.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(children: [Icon(Icons.pause_circle_outline, size: 20, color: kWarn), SizedBox(width: 10), Expanded(child: Text('Dieses Gerät holt gerade nichts ab', style: TextStyle(fontWeight: FontWeight.w700)))]),
                    const SizedBox(height: 6),
                    const Text('Der Schalter ist aus, zum Beispiel nach dem Abmelden. Solange das so ist, kommen keine neuen Werte aus Home Assistant in deine Zähler.', style: TextStyle(fontSize: 13, color: kTextMuted)),
                    const SizedBox(height: 8),
                    FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => unawaited(ref.read(ingestProvider.notifier).schalterSetzen(true)), child: const Text('Einschalten')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          LxCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: const Text('Werte automatisch abholen', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Auf diesem Gerät. Aus = es wird nichts eingetragen.', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              value: z.schalter,
              onChanged: z.postfachDa ? (v) => unawaited(ref.read(ingestProvider.notifier).schalterSetzen(v)) : null,
            ),
          ),
          const SizedBox(height: 16),
          const MonoLabel('// zustand'),
          const SizedBox(height: 6),
          LxCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                // zuerst, was die Person tun kann
                if (z.zuPruefen.isNotEmpty)
                  _ZustandsZeile(
                    titel: 'Zu prüfen',
                    untertitel: z.zuPruefen.length == 1 ? '1 Wert wartet auf dich' : '${z.zuPruefen.length} Werte warten auf dich',
                    pille: StatusPill('${z.zuPruefen.length} ›', color: kWarn),
                    onTap: () => unawaited(haPruefenOeffnen(context)),
                  ),
                if (lauf != null && lauf.ohneZaehler > 0)
                  _ZustandsZeile(
                    titel: 'Noch kein Zähler zugeordnet',
                    untertitel: '${werte(lauf.ohneZaehler)} warten, bis du einen Zähler zuordnest.${ohneLoeschen == null ? '' : ' ${paketLoeschText(ohneLoeschen)}.'}',
                    pille: const StatusPill('Zuordnen ›', color: kWarn),
                    onTap: () => unawaited(haZuordnenOeffnen(context)),
                  ),
                if (doppelt.zaehler.isNotEmpty)
                  _ZustandsZeile(
                    titel: 'Werte kommen doppelt an',
                    untertitel:
                        'Für ${doppelt.zaehler.map((n) => '„$n“').join(', ')} liefern mehrere Verbindungen oder Geräte denselben Kanal (${doppelt.kanaele.map(haKanalLabel).join(', ')}). Es zählt der zuletzt geschriebene Wert je Tag. Lass nur ein Gerät abholen.',
                    pille: const StatusPill('DOPPELT', color: kWarn),
                  ),
                if (lauf != null && lauf.fehler > 0)
                  _ZustandsZeile(titel: 'Nicht eingetragen', untertitel: '${werte(lauf.fehler)} ließen sich gerade nicht eintragen (neuer Versuch beim nächsten Abholen)', pille: StatusPill('${lauf.fehler}', color: kWarn)),
                // dann die letzte Abholung
                _ZustandsZeile(
                  titel: 'Letzte Abholung',
                  untertitel: abbruch != null ? ingestAbbruchText(abbruch) : (lauf == null ? (z.aktiv ? 'noch nicht abgeholt' : 'aus') : text.toString()),
                  pille: abbruch != null ? const StatusPill('FEHLER', color: kWarn) : (lauf != null && lauf.fehler == 0 && !lauf.quittungFehlgeschlagen ? const StatusPill('OK') : (lauf == null ? null : const StatusPill('TEILWEISE', color: kWarn))),
                ),
              ],
            ),
          ),
          if (lauf != null)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: const Text('Technische Details', style: TextStyle(fontSize: 14, color: kTextMuted)),
                children: [
                  _Detail(titel: 'Wartet beim Server', text: werte(lauf.wartend)),
                  if (lauf.ungueltig > 0) _Detail(titel: 'Unlesbar entfernt', text: '${werte(lauf.ungueltig)} waren beschädigt oder gefälscht und wurden entfernt.'),
                  if (lauf.fremd > 0) _Detail(titel: 'Für ein anderes Gerät', text: '${werte(lauf.fremd)} kann nur ein anderes Gerät oder eine neuere App öffnen. Sie bleiben beim Server (höchstens 30 Tage).'),
                ],
              ),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: z.aktiv && !z.laeuft ? () => unawaited(ref.read(ingestProvider.notifier).abholen()) : null,
            icon: z.laeuft ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync, size: 18),
            label: Text(z.laeuft ? 'Holt ab …' : 'Jetzt abholen'),
          ),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => unawaited(haZuordnenOeffnen(context)),
          icon: const Icon(Icons.rule, size: 18),
          label: const Text('Zähler zuordnen …'),
        ),
        if (admin) ...[
          const SizedBox(height: 18),
          const MonoLabel('// verbindung (nur admin)'),
          const SizedBox(height: 6),
          _Verbindungen(beschaeftigt: _beschaeftigt, onTrennen: (v) => unawaited(_trennen(v))),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _beschaeftigt ? null : () => unawaited(haKoppelnOeffnen(context)),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Neue Verbindung koppeln …'),
          ),
        ],
        const SizedBox(height: 14),
        const Text('Die Werte kommen verschlüsselt an. Nur ihr Eltern könnt sie lesen, der Server nicht. Pro Zähler zählt ein Wert am Tag, und nichts wird überschrieben.', style: TextStyle(fontSize: 12, color: kTextMuted)),
      ],
    );
  }
}

/// Eine Zeile der technischen Details.
class _Detail extends StatelessWidget {
  final String titel;
  final String text;
  const _Detail({required this.titel, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Semantics(
      container: true,
      label: '$titel: $text',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titel),
          Text(text, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
        ],
      ),
    ),
  );
}

class _ZustandsZeile extends StatelessWidget {
  final String titel;
  final String untertitel;
  final Widget? pille;
  final VoidCallback? onTap;
  const _ZustandsZeile({required this.titel, required this.untertitel, this.pille, this.onTap});

  @override
  Widget build(BuildContext context) {
    final inhalt = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel),
                  Text(untertitel, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
          ),
          if (pille != null) ...[const SizedBox(width: 8), pille!],
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      container: true,
      label: '$titel: $untertitel',
      excludeSemantics: true,
      onTap: onTap,
      child: onTap == null ? inhalt : InkWell(onTap: onTap, child: inhalt),
    );
  }
}

class _Verbindungen extends ConsumerWidget {
  final bool beschaeftigt;
  final ValueChanged<IngestVerbindungStand> onTrennen;
  const _Verbindungen({required this.beschaeftigt, required this.onTrennen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liste = ref.watch(ingestVerbindungenProvider);
    final jetzt = DateTime.now();
    return liste.when(
      loading: () => const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
      error: (_, _) => const Text('Die Verbindungen lassen sich gerade nicht laden.', style: TextStyle(color: kTextMuted)),
      data: (l) {
        final aktiv = l.where((v) => v.aktiv).toList();
        if (aktiv.isEmpty) return const Text('Noch keine Verbindung. Koppele Home Assistant mit dem Kopplungscode.', style: TextStyle(fontSize: 13, color: kTextMuted));
        return LxCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(
            children: [
              for (final v in aktiv)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(v.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                            Text(v.zuletztGehoert == null ? 'Noch nie gehört' : 'Zuletzt gehört: ${haZeitText(v.zuletztGehoert!, jetzt)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const StatusPill('AKTIV'),
                      TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: kDanger),
                        onPressed: beschaeftigt ? null : () => onTrennen(v),
                        child: Semantics(label: 'Verbindung ${v.name} trennen', excludeSemantics: true, child: const Text('Trennen')),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
