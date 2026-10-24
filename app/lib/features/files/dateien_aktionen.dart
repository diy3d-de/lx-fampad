// Abläufe der Oberfläche der Dateiablage (Abschnitt 6n): Namen abfragen, Bestätigen, Ordnerwahl mit Zyklus-/Tiefenprüfung, Neuer Ordner, Freigabe ändern (mit verständlicher Meldung bei der
// blockierten Änderung), Hochladen (Dateien und Fotos wählen, vorab prüfen, einreihen), Speichern (Browser-Download bzw. Systemdialog nach dem Laden in den Cache) und Löschen. Die Regeln stehen in
// der Datenschicht (`DateiRepository`, `TransferDienst`); hier steht nur, was die Person sieht und bestätigt. Alle Dialoge und Blätter mit `useRootNavigator: false` (Desktop-Shell).
import 'dart:async';

import 'package:drift/drift.dart' show BooleanExpressionOperators;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/app_database.dart';
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_modelle.dart';
import '../../data/dateien/datei_repository.dart';
import '../../data/dateien/datei_speichern.dart';
import '../../data/dateien/datei_state.dart';
import '../../data/dateien/datei_waehler.dart';
import '../../data/dateien/transfer_dienst.dart';
import '../../data/dateien/transfer_modelle.dart';
import '../auth/auth_widgets.dart' show zeigeHinweis;
import 'dateien_bausteine.dart' show dateienAnzahlText;
import 'uebertragungen_screen.dart';

/// Meldung zu einem Fehler: die feste Meldung der Dateiablage, sonst die der Verbindung, sonst ein allgemeiner Satz (nie ein Text des Servers, nie ein Name).
String dateiFehlerText(Object e) => switch (e) {
  DateiFehler() => e.meldung,
  ApiException() => e.message,
  _ => 'Das hat nicht geklappt.',
};

// ---------------------------------------------------------------------------------------------------- Namen und Bestätigen

/// Fragt einen Namen ab (neuer Ordner, Umbenennen). Liefert den eingegebenen Text (die Datenschicht prüft und bereinigt ihn); null = abgebrochen. Ein unzulässiger Name wird im Dialog erklärt.
Future<String?> nameAbfragen(BuildContext context, {required String titel, required String knopf, String start = '', String label = 'Name'}) =>
    showDialog<String>(context: context, useRootNavigator: false, builder: (_) => _NameDialog(titel: titel, knopf: knopf, start: start, label: label));

class _NameDialog extends StatefulWidget {
  final String titel;
  final String knopf;
  final String start;
  final String label;
  const _NameDialog({required this.titel, required this.knopf, required this.start, required this.label});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _c = TextEditingController(text: widget.start);
  String? _fehler;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    if (bereinigeName(_c.text) == null) {
      setState(() => _fehler = DateiFehler.nameUngueltig.meldung);
      return;
    }
    Navigator.of(context).pop(_c.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: kSurface,
    title: Text(widget.titel),
    content: TextField(
      controller: _c,
      autofocus: true,
      maxLength: kNameMaxZeichen,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _ok(),
      onChanged: (_) {
        if (_fehler != null) setState(() => _fehler = null);
      },
      decoration: InputDecoration(labelText: widget.label, errorText: _fehler, errorMaxLines: 4, counterText: ''),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
      FilledButton(onPressed: _ok, child: Text(widget.knopf)),
    ],
  );
}

/// Bestätigung vor einer Änderung mit Folgen; [gefahr] färbt den Knopf rot (Löschen).
Future<bool> bestaetigen(BuildContext context, {required String titel, required String text, required String knopf, bool gefahr = false}) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (d) => AlertDialog(
        backgroundColor: kSurface,
        title: Text(titel),
        content: SingleChildScrollView(child: Text(text, style: const TextStyle(color: kTextMuted, height: 1.4))),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            style: gefahr ? FilledButton.styleFrom(backgroundColor: kDanger, foregroundColor: kOnAccent) : null,
            child: Text(knopf),
          ),
        ],
      ),
    ) ??
    false;

// ---------------------------------------------------------------------------------------------------- Ordnerwahl

/// Ergebnis der Ordnerwahl: [id] null heißt "oberste Ebene" (kein Abbruch; der Abbruch ist ein null der ganzen Wahl).
class OrdnerWahl {
  final String? id;
  const OrdnerWahl(this.id);
}

/// Warum ein Ordner als Ziel nicht geht (null: geht). [bewegterOrdner] ist der Ordner, der verschoben wird (null: eine Datei), [audience] die Stufe des Eintrags.
String? ordnerZielGrund(List<OrdnerZeile> alle, OrdnerZeile ziel, DateiRechte rechte, {String? bewegterOrdner, required String audience}) {
  if (bewegterOrdner != null && liegtUnterOderIn(alle, ziel.id, bewegterOrdner)) return 'Nicht in sich selbst oder einen Unterordner.';
  if (!rechte.darfZielOrdner(ziel, audience)) return 'Dieser Ordner ist nur für Eltern: für alle sichtbare Einträge gehen dort nicht hinein.';
  if (bewegterOrdner != null) {
    final t = ordnerTiefe(alle, ziel.id);
    if (t < 0 || t + 1 + hoeheUnter(alle, bewegterOrdner) > kMaxOrdnerTiefe) return 'So tief lassen sich Ordner nicht schachteln.';
  }
  return null;
}

/// Zeigt die Ordnerwahl (Blatt mit "Oberste Ebene" und allen Ordnern samt Pfad). Ordner, die als Ziel nicht gehen, stehen grau mit dem Grund da. Liefert die Wahl oder null bei Abbruch.
Future<OrdnerWahl?> ordnerWaehlen(
  BuildContext context,
  WidgetRef ref, {
  required String titel,
  required String? aktuell,
  required String audience,
  String? bewegterOrdner,
}) {
  final alle = ref.read(alleOrdnerProvider).value ?? const <OrdnerZeile>[];
  final rechte = ref.read(dateiRechteProvider);
  final liste = [...alle]..sort((a, b) => namensVergleich(ordnerPfadText(alle, a.id), ordnerPfadText(alle, b.id)));
  return showModalBottomSheet<OrdnerWahl>(
    context: context,
    useRootNavigator: false,
    isScrollControlled: true,
    backgroundColor: kSurface,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8, maxWidth: kMaxContentWidth),
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Semantics(header: true, child: Text(titel, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kTextStrong)))),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                _WahlZeile(titel: 'Oberste Ebene', grund: null, aktuell: aktuell == null, onTap: () => Navigator.of(sheet).pop(const OrdnerWahl(null))),
                for (final o in liste)
                  if (o.id != bewegterOrdner)
                    () {
                      final grund = ordnerZielGrund(alle, o, rechte, bewegterOrdner: bewegterOrdner, audience: audience);
                      return _WahlZeile(titel: ordnerPfadText(alle, o.id), grund: grund, aktuell: o.id == aktuell, onTap: () => Navigator.of(sheet).pop(OrdnerWahl(o.id)));
                    }(),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _WahlZeile extends StatelessWidget {
  final String titel;
  final String? grund;
  final bool aktuell;
  final VoidCallback onTap;
  const _WahlZeile({required this.titel, required this.grund, required this.aktuell, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final gesperrt = grund != null;
    return ListTile(
      enabled: !gesperrt,
      minTileHeight: 56,
      leading: Icon(aktuell ? Icons.folder_open : Icons.folder_outlined, color: gesperrt ? kTextFaint : kAccent),
      title: Text(titel, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: gesperrt ? Text(grund!, style: const TextStyle(color: kTextMuted, fontSize: 12)) : (aktuell ? const Text('Hier liegt es jetzt', style: TextStyle(color: kTextMuted, fontSize: 12)) : null),
      onTap: gesperrt ? null : onTap,
    );
  }
}

// ---------------------------------------------------------------------------------------------------- Ordner anlegen und Freigabe

/// Stufe, mit der in [ordnerId] angelegt wird: ein Ordner nur für Eltern vererbt es (sonst wäre der Eintrag offener als der Ordner), sonst für alle.
String stufeFuerOrdner(WidgetRef ref, String? ordnerId) {
  if (ordnerId == null) return kStufeFamilie;
  final o = (ref.read(alleOrdnerProvider).value ?? const <OrdnerZeile>[]).where((x) => x.id == ordnerId).firstOrNull;
  return o?.audience == kStufeEltern ? kStufeEltern : kStufeFamilie;
}

Future<void> ordnerNeuAnlegen(BuildContext context, WidgetRef ref, String? parentId) async {
  final name = await nameAbfragen(context, titel: 'Neuer Ordner', knopf: 'Anlegen', label: 'Name des Ordners');
  if (name == null || !context.mounted) return;
  try {
    await ref.read(dateiRepositoryProvider).ordnerAnlegen(name: name, parentId: parentId, audience: stufeFuerOrdner(ref, parentId));
  } on Object catch (e) {
    if (context.mounted) zeigeHinweis(context, dateiFehlerText(e));
  }
}

/// Wie viele Einträge (Ordner und Dateien) in [ordnerId] und darunter für alle sichtbar sind (ohne den Ordner selbst): sie würden bei "Nur Eltern" mit umgestellt.
Future<int> anzahlFuerAlleDarunter(DateiRepository repo, List<OrdnerZeile> alle, String ordnerId) async {
  final ids = [ordnerId, ...unterordnerVonUnten(alle, ordnerId).map((o) => o.id)];
  var n = unterordnerVonUnten(alle, ordnerId).where((o) => o.audience == kStufeFamilie).length;
  final db = repo.db;
  for (final id in ids) {
    final d = await (db.select(db.dateien)..where((t) => t.ordnerId.equals(id) & t.audience.equals(kStufeFamilie))).get();
    n += d.length;
  }
  return n;
}

/// Ändert die Freigabe eines Ordners. Auf "Nur Eltern" fragt sie zuerst nach (es gilt auch für alles darunter, Kinder sehen es dann nicht mehr; die Datenschicht stellt es von unten nach oben um).
/// Auf "Familie" geht es nur, wenn der Ordner oben oder in einem Ordner für alle liegt: sonst erklärt die Meldung der Datenschicht den Grund und bietet an, die übergeordneten Ordner mit freizugeben.
Future<bool> ordnerFreigabeAendern(BuildContext context, WidgetRef ref, OrdnerZeile o, String stufe) async {
  final repo = ref.read(dateiRepositoryProvider);
  final alle = ref.read(alleOrdnerProvider).value ?? const <OrdnerZeile>[];
  try {
    if (stufe == kStufeEltern) {
      final n = await anzahlFuerAlleDarunter(repo, alle, o.id);
      if (!context.mounted) return false;
      final ok = await bestaetigen(
        context,
        titel: 'Nur für Eltern?',
        text: n == 0
            ? 'Der Ordner „${o.name}“ ist dann nur noch für Eltern sichtbar. Kinder sehen ihn nicht mehr.'
            : 'Der Ordner „${o.name}“ und $n ${n == 1 ? 'Eintrag' : 'Einträge'} darunter werden nur noch für Eltern sichtbar. Kinder sehen sie nicht mehr. Neue Dateien und Unterordner dürfen nicht offener sein als der Ordner.',
        knopf: 'Nur Eltern',
      );
      if (!ok) return false;
    }
    await repo.ordnerStufeAendern(o.id, stufe);
    return true;
  } on DateiFehler catch (e) {
    if (e.code != DateiFehler.stufeFamilieNurInFamilie.code || stufe != kStufeFamilie) {
      if (context.mounted) zeigeHinweis(context, e.meldung);
      return false;
    }
    if (!context.mounted) return false;
    final oben = ordnerPfad(alle, o.id).where((x) => x.id != o.id && x.audience != kStufeFamilie).toList();
    final namen = oben.map((x) => '„${x.name}“').join(', ');
    final ok = await bestaetigen(
      context,
      titel: 'Erst die übergeordneten Ordner freigeben?',
      text: '${e.meldung}\n\nDer Ordner liegt in $namen, und das ist nur für Eltern. Wenn du ${oben.length == 1 ? 'ihn' : 'sie'} auch für die Familie freigibst, sehen Kinder dort alles, was selbst für die Familie freigegeben ist. Alles andere behält seine Freigabe.',
      knopf: 'Auch freigeben',
    );
    if (!ok) return false;
    try {
      for (final x in oben) {
        await repo.ordnerStufeAendern(x.id, kStufeFamilie); // von oben nach unten: jeder Schritt hält die Regel ein
      }
      await repo.ordnerStufeAendern(o.id, kStufeFamilie);
      return true;
    } on Object catch (e2) {
      if (context.mounted) zeigeHinweis(context, dateiFehlerText(e2));
      return false;
    }
  } on Object catch (e) {
    if (context.mounted) zeigeHinweis(context, dateiFehlerText(e));
    return false;
  }
}

/// Ändert die Freigabe einer Datei (nur Eltern und Admins); auf "Familie" erklärt die Meldung, wenn der Ordner nur für Eltern ist.
Future<bool> dateiFreigabeAendern(BuildContext context, WidgetRef ref, DateiEintrag d, String stufe) async {
  try {
    await ref.read(dateiRepositoryProvider).dateiStufeAendern(d.id, stufe);
    return true;
  } on Object catch (e) {
    if (context.mounted) {
      final nurOrdner = e is DateiFehler && e.code == DateiFehler.stufeFamilieNurInFamilie.code;
      zeigeHinweis(context, nurOrdner ? '${dateiFehlerText(e)} Verschiebe die Datei zuerst in einen Ordner für alle.' : dateiFehlerText(e));
    }
    return false;
  }
}

// ---------------------------------------------------------------------------------------------------- Hochladen

/// Lässt die Person Dateien (oder nur Fotos) wählen und reiht sie in [ordnerId] (null = oberste Ebene) zum Hochladen ein. Vorab prüft die Datenschicht Größe, Kontingent und Rechte; der Fortschritt
/// steht nur in der Liste der Übertragungen (Hinweis mit Weg dorthin). Liefert die Zahl der eingereihten Dateien.
Future<int> dateienHochladen(BuildContext context, WidgetRef ref, {String? ordnerId, bool nurBilder = false}) async {
  final auswahl = await ref.read(dateiWaehlerProvider)(nurBilder: nurBilder);
  if (!context.mounted) {
    for (final d in auswahl.dateien) {
      unawaited(d.quelle.schliessen());
    }
    return 0;
  }
  final dienst = ref.read(transferDienstProvider);
  final audience = stufeFuerOrdner(ref, ordnerId);
  final vorhanden = [for (final e in ref.read(dateienInProvider(ordnerId)).value ?? const <DateiEintrag>[]) e.name];
  var ok = 0;
  final probleme = <String>[];
  for (final d in auswahl.dateien) {
    try {
      final name = freierName(bereinigeName(d.name) ?? d.name, vorhanden);
      await dienst.hochladenDatei(name: name, quelle: d.quelle, quellePfad: d.pfad, ordnerId: ordnerId, audience: audience);
      vorhanden.add(name);
      ok++;
    } on Object catch (e) {
      unawaited(d.quelle.schliessen());
      final text = dateiFehlerText(e);
      if (!probleme.contains(text)) probleme.add(text);
    }
  }
  if (auswahl.nichtLesbar > 0) probleme.add(auswahl.nichtLesbar == 1 ? 'Eine Datei ließ sich nicht öffnen.' : '${auswahl.nichtLesbar} Dateien ließen sich nicht öffnen.');
  if (!context.mounted) return ok;
  if (ok > 0 || probleme.isNotEmpty) {
    final text = [if (ok > 0) ok == 1 ? 'Eine Datei wird hochgeladen.' : '$ok Dateien werden hochgeladen.', ...probleme].join(' ');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(seconds: 6),
          action: ok > 0 ? SnackBarAction(label: 'Anzeigen', onPressed: () => unawaited(Navigator.of(context).push<void>(UebertragungenScreen.route()))) : null,
        ),
      );
  }
  return ok;
}

/// Das Blatt "Hochladen" (Dateien wählen, Fotos wählen, Neuer Ordner) für den Knopf der Übersicht.
Future<void> hochladenBlattOeffnen(BuildContext context, WidgetRef ref, {required String? ordnerId}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: false,
  backgroundColor: kSurface,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
  builder: (sheet) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          minTileHeight: 56,
          leading: const Icon(Icons.upload_file_outlined, color: kAccent),
          title: const Text('Dateien wählen'),
          onTap: () {
            Navigator.of(sheet).pop();
            unawaited(dateienHochladen(context, ref, ordnerId: ordnerId));
          },
        ),
        ListTile(
          minTileHeight: 56,
          leading: const Icon(Icons.image_outlined, color: kAccent),
          title: const Text('Fotos wählen'),
          onTap: () {
            Navigator.of(sheet).pop();
            unawaited(dateienHochladen(context, ref, ordnerId: ordnerId, nurBilder: true));
          },
        ),
        ListTile(
          minTileHeight: 56,
          leading: const Icon(Icons.create_new_folder_outlined, color: kAccent),
          title: const Text('Neuer Ordner'),
          onTap: () {
            Navigator.of(sheet).pop();
            unawaited(ordnerNeuAnlegen(context, ref, ordnerId));
          },
        ),
      ],
    ),
  ),
);

// ---------------------------------------------------------------------------------------------------- Speichern und Löschen

/// Lädt eine Fassung in den Cache dieses Geräts (Android; fortsetzbar, Fortschritt als Text in [status]) und liefert den Pfad; null bei Abbruch oder Fehler (eine Meldung erklärt den Fehler).
/// Ist die Kopie schon da, kommt sie ohne Netz.
Future<String?> fassungInCache(
  BuildContext context,
  WidgetRef ref, {
  required DateiZeile datei,
  required DateiVersionZeile fassung,
  ValueNotifier<String?>? status,
}) async {
  final cache = ref.read(dateiCacheDienstProvider);
  final dienst = ref.read(transferDienstProvider);
  if (!cache.verfuegbar) {
    zeigeHinweis(context, DateiFehler.nichtVerfuegbar.meldung);
    return null;
  }
  try {
    final da = await cache.pfadFuer(fassung.blobId);
    if (da != null) return da;
    final id = await dienst.herunterladen(blobId: fassung.blobId, name: datei.name, groesse: fassung.size, mime: fassung.mime, sha256: fassung.sha256, dateiId: datei.id, versionId: fassung.id);
    while (true) {
      final z = await dienst.transfer(id);
      if (z == null) return null;
      if (z.zustandTyp == TransferZustand.fertig) return z.zielPfad;
      if (z.zustandTyp == TransferZustand.abgebrochen) return null;
      if (z.zustandTyp == TransferZustand.fehler) {
        if (context.mounted) zeigeHinweis(context, transferFehlerText(z.fehlerCode));
        return null;
      }
      status?.value = 'Lädt ${(z.fortschritt * 100).floor()} %';
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!context.mounted) return null;
    }
  } on Object catch (e) {
    if (context.mounted) zeigeHinweis(context, dateiFehlerText(e));
    return null;
  } finally {
    status?.value = null;
  }
}

/// Speichert eine Fassung: im Browser als Download (normale Navigation auf die Adresse des Servers), auf Android erst in den Cache laden und dann über den Systemdialog speichern.
/// Liefert true, wenn gespeichert (im Browser: angestoßen); eine Meldung erklärt jeden Misserfolg.
Future<bool> fassungSpeichern(
  BuildContext context,
  WidgetRef ref, {
  required DateiZeile datei,
  required DateiVersionZeile fassung,
  ValueNotifier<String?>? status,
}) async {
  final speichern = ref.read(dateiSpeichernProvider);
  if (kIsWeb) {
    final ok = speichern.imBrowser(fassung.blobId, datei.name);
    zeigeHinweis(context, ok ? 'Der Download startet im Browser.' : 'Der Download hat nicht geklappt.');
    return ok;
  }
  final pfad = await fassungInCache(context, ref, datei: datei, fassung: fassung, status: status);
  if (pfad == null || !context.mounted) return false;
  try {
    final ok = await speichern.ausPfad(pfad, datei.name, mime: fassung.mime);
    if (context.mounted && ok) zeigeHinweis(context, 'Gespeichert.');
    return ok;
  } on Object catch (e) {
    if (context.mounted) zeigeHinweis(context, dateiFehlerText(e));
    return false;
  }
}

/// Löscht eine Datei endgültig (es gibt in dieser Version keinen Papierkorb) nach Bestätigung; Offline-Kopien dieses Geräts verschwinden mit. Liefert true, wenn gelöscht.
Future<bool> dateiLoeschenFragen(BuildContext context, WidgetRef ref, DateiEintrag d) async {
  final text = d.fassungen > 1
      ? '„${d.name}“ wird mit allen ${d.fassungen} Fassungen für die ganze Familie gelöscht. Das lässt sich nicht rückgängig machen, es gibt keinen Papierkorb.'
      : '„${d.name}“ wird für die ganze Familie gelöscht. Das lässt sich nicht rückgängig machen, es gibt keinen Papierkorb.';
  final ok = await bestaetigen(context, titel: 'Datei endgültig löschen?', text: text, knopf: 'Endgültig löschen', gefahr: true);
  if (!ok || !context.mounted) return false;
  final repo = ref.read(dateiRepositoryProvider);
  try {
    final versionen = await (repo.db.select(repo.db.dateiVersionen)..where((v) => v.dateiId.equals(d.id))).get();
    await repo.dateiLoeschen(d.id);
    final cache = ref.read(dateiCacheDienstProvider);
    for (final v in versionen) {
      try {
        await cache.entfernen(v.blobId);
      } on Object {
        // eine Kopie, die nicht verschwindet, fliegt beim Aufräumen heraus
      }
    }
    return true;
  } on Object catch (e) {
    if (context.mounted) zeigeHinweis(context, dateiFehlerText(e));
    return false;
  }
}

/// Löscht einen Ordner: leer sofort nach Bestätigung, sonst nur "Ordner mit Inhalt löschen" mit Anzahl (nur Eltern und Admins). Liefert true, wenn gelöscht.
Future<bool> ordnerLoeschenFragen(BuildContext context, WidgetRef ref, OrdnerZeile o) async {
  final repo = ref.read(dateiRepositoryProvider);
  final alle = ref.read(alleOrdnerProvider).value ?? const <OrdnerZeile>[];
  final unter = unterordnerVonUnten(alle, o.id);
  var dateien = 0;
  for (final id in [o.id, ...unter.map((x) => x.id)]) {
    dateien += (await (repo.db.select(repo.db.dateien)..where((t) => t.ordnerId.equals(id))).get()).length;
  }
  if (!context.mounted) return false;
  final leer = dateien == 0 && unter.isEmpty;
  if (!leer && !ref.read(dateiRechteProvider).erwachsen) {
    zeigeHinweis(context, '${DateiFehler.nichtLeer.meldung} Räume ihn zuerst auf: Einen Ordner mit Inhalt löschen nur Eltern.');
    return false;
  }
  final String text;
  if (leer) {
    text = 'Der leere Ordner „${o.name}“ wird gelöscht.';
  } else {
    final teile = [if (dateien > 0) dateienAnzahlText(dateien), if (unter.isNotEmpty) '${unter.length} ${unter.length == 1 ? 'Unterordner' : 'Unterordnern'}'];
    text = 'Der Ordner „${o.name}“ ist nicht leer: ${teile.join(' und ')}. Alles wird endgültig für die ganze Familie gelöscht, es gibt keinen Papierkorb.';
  }
  final ok = await bestaetigen(context, titel: leer ? 'Ordner löschen?' : 'Ordner mit Inhalt löschen?', text: text, knopf: leer ? 'Löschen' : 'Mit Inhalt löschen', gefahr: true);
  if (!ok || !context.mounted) return false;
  try {
    if (leer) {
      await repo.ordnerLoeschen(o.id);
    } else {
      await repo.ordnerMitInhaltLoeschen(o.id);
    }
    return true;
  } on Object catch (e) {
    if (context.mounted) zeigeHinweis(context, dateiFehlerText(e));
    return false;
  }
}

/// Ein Wert, den die Übersicht für "Erledigte entfernen" und Ähnliches braucht, ohne dass die Seite den Dienst kennen muss.
Future<void> erledigteEntfernen(WidgetRef ref) => ref.read(transferDienstProvider).erledigteEntfernen();

