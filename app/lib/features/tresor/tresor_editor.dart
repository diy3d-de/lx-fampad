// Tresor (Abschnitt 6m): Eintrag anlegen und bearbeiten. Vorlagen (WLAN, Versicherung, Ausweis, Arzt, Eigener) füllen die Felder vor; Felder lassen sich hinzufügen, entfernen und mit Pfeilen
// umsortieren, jedes Feld hat einen "Geheim"-Schalter. Der Eintrag gehört allen Eltern (feste Hinweiskarte statt einer Auswahl "Sichtbar für"). Geheime Werte bekommen keine
// Tastaturvorschläge und keine Autokorrektur. Mit der Sperre schließt sich der Editor, eine ungespeicherte Eingabe geht dabei bewusst verloren. Dokumente (Anhänge) hängen an einem gespeicherten Eintrag: im Editor eines bestehenden Eintrags erscheint der Abschnitt "Dokumente" (sofort wirksam, unabhängig vom Speichern der Felder), bei einem neuen nur ein Hinweis.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/chat/chat_krypto.dart' show VerschluesselungNichtBereit;
import '../../data/tresor/tresor_daten.dart';
import '../../data/tresor/tresor_logik.dart';
import '../../data/tresor/tresor_modelle.dart';
import '../../data/tresor/tresor_repository.dart';
import '../../data/tresor/tresor_sperre.dart';
import '../../data/tresor/tresor_state.dart';
import '../../data/tresor/tresor_vorlagen.dart';
import '../../ui/widgets.dart';
import '../../widgets/ungespeichert_schutz.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'tresor_bausteine.dart';
import 'tresor_dokumente.dart';

/// Öffnet den Editor: [id] = bearbeiten, sonst einen neuen Eintrag anlegen. Nur für Eltern und Admins.
Future<void> tresorEditorOeffnen(BuildContext context, {String? id}) {
  final c = ProviderScope.containerOf(context);
  if (!c.read(tresorDarfProvider) || !c.read(tresorSperreProvider).entsperrt) return Future.value();
  return Navigator.of(context).push<void>(tresorUnterseiteRoute((_) => TresorEditor(id: id)));
}

/// Meldet jede Eingabe (Textfelder, Schalter, Reihenfolge) für den Schutz vor ungespeicherten Änderungen und die Auto-Sperre.
class _Aenderung extends ChangeNotifier {
  void melden() => notifyListeners();
}

class _FeldEingabe {
  final TextEditingController bezeichnung;
  final TextEditingController wert;
  bool geheim;
  bool sichtbar = false;
  final Key key = UniqueKey();
  _FeldEingabe({String bezeichnung = '', String wert = '', this.geheim = false}) : bezeichnung = TextEditingController(text: bezeichnung), wert = TextEditingController(text: wert);

  TresorFeld get feld => TresorFeld(bezeichnung: bezeichnung.text.trim(), wert: wert.text, geheim: geheim);

  void dispose() {
    bezeichnung.dispose();
    wert.dispose();
  }
}

class TresorEditor extends ConsumerStatefulWidget {
  final String? id;
  const TresorEditor({super.key, this.id});

  @override
  ConsumerState<TresorEditor> createState() => _TresorEditorState();
}

class _TresorEditorState extends ConsumerState<TresorEditor> {
  final _titel = TextEditingController();
  final _kategorieName = TextEditingController();
  final _notiz = TextEditingController();
  final _aenderung = _Aenderung();
  final _felder = <_FeldEingabe>[];
  var _kategorie = TresorKategorie.zugang;
  TresorVorlage? _vorlage;
  TresorInhalt? _alt;
  String? _ausgang;
  String? _fehler;
  var _speichert = false;

  bool get _neu => widget.id == null;

  @override
  void initState() {
    super.initState();
    if (!_neu) _alt = ref.read(tresorDatenProvider).eintrag(widget.id!)?.inhalt;
    final a = _alt;
    if (a != null) {
      _titel.text = a.titel;
      _kategorie = a.kategorie;
      _kategorieName.text = a.kategorieName;
      _notiz.text = a.notiz;
      _vorlage = a.vorlage;
      for (final f in a.felder) {
        _feldHinzu(_FeldEingabe(bezeichnung: f.bezeichnung, wert: f.wert, geheim: f.geheim));
      }
    } else if (_neu) {
      _feldHinzu(_FeldEingabe());
    }
    for (final c in [_titel, _kategorieName, _notiz]) {
      c.addListener(_aenderung.melden);
    }
    _aenderung.addListener(_eingabe);
    _ausgang = _stand();
  }

  void _eingabe() => ref.read(tresorSperreProvider.notifier).aktivitaet();

  void _feldHinzu(_FeldEingabe f) {
    f.bezeichnung.addListener(_aenderung.melden);
    f.wert.addListener(_aenderung.melden);
    _felder.add(f);
  }

  @override
  void dispose() {
    _aenderung.removeListener(_eingabe);
    for (final c in [_titel, _kategorieName, _notiz]) {
      c.dispose();
    }
    for (final f in _felder) {
      f.dispose();
    }
    _aenderung.dispose();
    super.dispose();
  }

  String _stand() => jsonEncode([_titel.text, _kategorie.wire, _kategorieName.text, _notiz.text, for (final f in _felder) [f.bezeichnung.text, f.wert.text, f.geheim]]);

  TresorInhalt _inhalt() => TresorInhalt(
    kategorie: _kategorie,
    kategorieName: _kategorie == TresorKategorie.eigene ? _kategorieName.text.trim() : '',
    titel: _titel.text.trim(),
    felder: tresorLeereFelderWeg([for (final f in _felder) f.feld]),
    notiz: _notiz.text,
    vorlage: _vorlage,
  );

  /// Gibt die Eingabefelder erst nach dem nächsten Bild frei (bis dahin hängt noch ein TextField daran).
  void _entsorgen(_FeldEingabe f) => WidgetsBinding.instance.addPostFrameCallback((_) => f.dispose());

  void _struktur(VoidCallback f) {
    setState(f);
    _aenderung.melden();
  }

  Future<void> _vorlageWaehlen(TresorVorlagenDaten v) async {
    final belegt = _felder.any((f) => f.wert.text.isNotEmpty);
    if (belegt) {
      final ok = await showDialog<bool>(
        useRootNavigator: false,
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Vorlage „${v.name}“ übernehmen?'),
          content: const Text('Die Felder werden durch die der Vorlage ersetzt. Eingetragene Werte gehen dabei verloren.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Ersetzen')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    _struktur(() {
      for (final f in _felder) {
        _entsorgen(f);
      }
      _felder.clear();
      for (final f in v.felder) {
        _feldHinzu(_FeldEingabe(bezeichnung: f.bezeichnung, geheim: f.geheim));
      }
      if (_felder.isEmpty) _feldHinzu(_FeldEingabe());
      _kategorie = v.kategorie;
      if (v.kategorie != TresorKategorie.eigene) _kategorieName.clear();
      _vorlage = v.kennung;
      _fehler = null;
    });
  }

  void _verschieben(int von, int nach) {
    if (nach < 0 || nach >= _felder.length) return;
    _struktur(() => _felder.insert(nach, _felder.removeAt(von)));
  }

  Future<void> _speichern() async {
    final inhalt = _inhalt();
    final probleme = tresorProbleme(inhalt);
    if (probleme.isNotEmpty) {
      setState(() => _fehler = probleme.map((p) => p.meldung).toSet().join(' '));
      return;
    }
    if (_neu && ref.read(tresorDatenProvider).eintraege.length >= kMaxTresorEintraege) {
      setState(() => _fehler = 'Der Tresor ist voll: höchstens $kMaxTresorEintraege Einträge. Lösche zuerst einen alten Eintrag.');
      return;
    }
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    final nav = Navigator.of(context);
    try {
      final repo = ref.read(tresorRepositoryProvider);
      if (_neu) {
        await repo.anlegen(inhalt);
      } else {
        await repo.aendern(widget.id!, inhalt);
      }
      // gespeichert: die Seite schließt ohne Rückfrage
      _ausgang = _stand();
      if (mounted) nav.pop();
    } on TresorEingabeFehler catch (e) {
      if (mounted) setState(() => _fehler = e.probleme.map((p) => p.meldung).toSet().join(' '));
    } on TresorFehler catch (e) {
      if (mounted) setState(() => _fehler = e.meldung);
    } on VerschluesselungNichtBereit catch (e) {
      if (mounted) setState(() => _fehler = e.meldung);
    } on Object {
      if (mounted) setState(() => _fehler = 'Das Speichern hat nicht geklappt. Versuche es noch einmal.');
    } finally {
      if (mounted) setState(() => _speichert = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(tresorDarfProvider)) return const TresorNichtVerfuegbar(eingebettet: false);
    if (!_neu && _alt == null) {
      return TresorSeite(unterseite: true, child: const AuthSeite(titel: 'Eintrag', maxBreite: kMaxContentWidth, kinder: [EmptyState(icon: Icons.lock_outline, title: 'Nicht lesbar', hint: 'Dieser Eintrag lässt sich gerade nicht bearbeiten.')]));
    }
    final eigene = tresorEigeneKategorien([for (final e in ref.watch(tresorDatenProvider).lesbare) e.inhalt!]);
    return TresorSeite(
      unterseite: true,
      child: UngespeichertSchutz(
        geaendert: () => _ausgang != null && _stand() != _ausgang,
        aenderungen: _aenderung,
        child: AuthSeite(
          label: _neu ? 'Neu' : _alt!.kategorieAnzeige,
          titel: _neu ? 'Eintrag' : 'Eintrag bearbeiten',
          maxBreite: kMaxContentWidth,
          fussleiste: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _speichert ? null : () => unawaited(_speichern()),
            child: Text(_neu ? 'Speichern' : 'Änderungen speichern'),
          ),
          kinder: [
            if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 12)],
            if (_neu) ...[
              const MonoLabel('Vorlage'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [for (final v in kTresorVorlagen) AuswahlKnopf(text: v.name, gewaehlt: _vorlage == v.kennung, onTap: () => unawaited(_vorlageWaehlen(v)))]),
              const SizedBox(height: 14),
            ],
            TextField(controller: _titel, maxLength: kMaxTresorTitel, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Titel (zum Beispiel WLAN Zuhause)', counterText: '')),
            const SizedBox(height: 14),
            const MonoLabel('Kategorie'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in TresorKategorie.values)
                  AuswahlKnopf(
                    text: k == TresorKategorie.notfall ? 'Notfall-Infos' : k.anzeige,
                    gewaehlt: _kategorie == k,
                    onTap: () => _struktur(() => _kategorie = k),
                  ),
              ],
            ),
            if (_kategorie == TresorKategorie.eigene) ...[
              const SizedBox(height: 10),
              TextField(controller: _kategorieName, maxLength: kMaxTresorKategorieName, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Name der Kategorie', counterText: '')),
              if (eigene.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final n in eigene) AuswahlKnopf(text: n, gewaehlt: foldeText(_kategorieName.text.trim()) == foldeText(n), onTap: () => _struktur(() => _kategorieName.text = n))]),
              ],
            ],
            const SizedBox(height: 14),
            const MonoLabel('Felder'),
            const SizedBox(height: 8),
            for (var n = 0; n < _felder.length; n++) ...[_feldKarte(n), const SizedBox(height: 8)],
            OutlinedButton.icon(
              onPressed: _felder.length >= kMaxTresorFelder ? null : () => _struktur(() => _feldHinzu(_FeldEingabe())),
              icon: const Icon(Icons.add),
              label: const Text('Feld hinzufügen'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _felder.length >= kMaxTresorFelder ? 'Mehr als $kMaxTresorFelder Felder passen nicht in einen Eintrag.' : '${_felder.length} von $kMaxTresorFelder Feldern',
                style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _notiz,
              minLines: 3,
              maxLines: 8,
              maxLength: kMaxTresorNotiz,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notiz', counterText: '', alignLabelWithHint: true),
            ),
            const SizedBox(height: 14),
            TresorDokumente(eintragId: widget.id),
            const SizedBox(height: 14),
            const TresorHinweis(titel: 'Alle Eltern sehen diesen Eintrag', text: 'Er liegt Ende-zu-Ende verschlüsselt und ist für alle Eltern und Admins sichtbar und bearbeitbar. Ein Eintrag hat höchstens 16 KB Text.', icon: Icons.groups_outlined),
          ],
        ),
      ),
    );
  }

  Widget _feldKarte(int n) {
    final f = _felder[n];
    final versteckt = f.geheim && !f.sichtbar;
    return LxCard(
      key: f.key,
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(controller: f.bezeichnung, maxLength: kMaxTresorBezeichnung, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: 'Bezeichnung (Feld ${n + 1})', counterText: '')),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              controller: f.wert,
              obscureText: versteckt,
              autocorrect: false,
              enableSuggestions: false,
              maxLines: versteckt ? 1 : 4,
              minLines: 1,
              maxLength: kMaxTresorWert,
              keyboardType: versteckt ? TextInputType.visiblePassword : TextInputType.multiline,
              decoration: InputDecoration(
                labelText: 'Wert',
                counterText: '',
                suffixIcon: f.geheim
                    ? IconButton(
                        tooltip: f.sichtbar ? 'Wert verbergen' : 'Wert anzeigen',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        icon: Icon(f.sichtbar ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                        onPressed: () => setState(() => f.sichtbar = !f.sichtbar),
                      )
                    : null,
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.only(right: 8),
            title: const Text('Geheim'),
            subtitle: const Text('Wird verdeckt angezeigt und nie durchsucht.', style: TextStyle(fontSize: 12, color: kTextMuted)),
            value: f.geheim,
            onChanged: (v) => _struktur(() {
              f.geheim = v;
              if (!v) f.sichtbar = false;
            }),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(tooltip: 'Feld ${n + 1} nach oben', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: n == 0 ? null : () => _verschieben(n, n - 1), icon: const Icon(Icons.arrow_upward)),
              IconButton(tooltip: 'Feld ${n + 1} nach unten', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: n == _felder.length - 1 ? null : () => _verschieben(n, n + 1), icon: const Icon(Icons.arrow_downward)),
              IconButton(
                tooltip: 'Feld ${n + 1} entfernen',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _struktur(() => _entsorgen(_felder.removeAt(n))),
                icon: const Icon(Icons.delete_outline, color: kDanger),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
