// Datei (Abschnitt 6n): Vorschau (Bilder), Öffnen (Bilder in der App) und Speichern (Browser-Download bzw. Systemdialog), "Offline verfügbar" (nur Android, mit der belegten Größe), Umbenennen,
// Verschieben, Freigabe (nur Eltern und Admins), neue Fassung hochladen mit der Liste der Fassungen, endgültiges Löschen (kein Papierkorb in dieser Version) und der Datenschutz-Hinweis. Kinder ändern,
// verschieben, löschen und laden Fassungen nur für eigene Dateien hoch (`DateiRechte`). Teilen gibt es nur in der Familie (Freigabe), nie per Link nach außen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/dateien/datei_alle.dart';
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_modelle.dart';
import '../../data/dateien/datei_repository.dart';
import '../../data/dateien/datei_state.dart';
import '../../data/dateien/datei_waehler.dart';
import '../../data/dateien/transfer_dienst.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart' show zeigeHinweis;
import 'bild_ansicht_screen.dart';
import 'dateien_aktionen.dart';
import 'dateien_bausteine.dart';
import 'ordner_screen.dart' show ZeilenKnopf;
import 'uebertragungen_screen.dart';

String _artText(VorschauArt a) => switch (a) {
  VorschauArt.bild => 'Bild',
  VorschauArt.pdf => 'PDF',
  VorschauArt.text => 'Text',
  VorschauArt.video => 'Video',
  VorschauArt.audio => 'Audio',
  VorschauArt.archiv => 'Archiv',
  VorschauArt.sonstige => 'Datei',
};

class DateiScreen extends ConsumerStatefulWidget {
  final String dateiId;
  const DateiScreen({super.key, required this.dateiId});

  static Route<void> route(String id) => MaterialPageRoute<void>(builder: (_) => DateiScreen(dateiId: id));

  @override
  ConsumerState<DateiScreen> createState() => _DateiScreenState();
}

class _DateiScreenState extends ConsumerState<DateiScreen> {
  final _status = ValueNotifier<String?>(null);
  var _arbeitet = false;

  @override
  void dispose() {
    _status.dispose();
    super.dispose();
  }

  /// Führt [f] aus und sperrt währenddessen die Knöpfe für Laden (nur eine Sache auf einmal).
  Future<void> _mit(Future<void> Function() f) async {
    if (_arbeitet) return;
    setState(() => _arbeitet = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _arbeitet = false);
    }
  }

  Future<void> _umbenennen(DateiEintrag e) async {
    final name = await nameAbfragen(context, titel: 'Datei umbenennen', knopf: 'Umbenennen', start: e.name, label: 'Name der Datei');
    if (name == null || !mounted) return;
    try {
      await ref.read(dateiRepositoryProvider).dateiUmbenennen(e.id, name);
    } on Object catch (x) {
      if (mounted) zeigeHinweis(context, dateiFehlerText(x));
    }
  }

  Future<void> _verschieben(DateiEintrag e) async {
    final wahl = await ordnerWaehlen(context, ref, titel: 'Datei verschieben nach', aktuell: e.datei.ordnerId, audience: e.audience);
    if (wahl == null || !mounted) return;
    try {
      await ref.read(dateiRepositoryProvider).dateiVerschieben(e.id, wahl.id);
    } on Object catch (x) {
      if (mounted) zeigeHinweis(context, dateiFehlerText(x));
    }
  }

  Future<void> _neueFassung(DateiEintrag e) async {
    final a = await ref.read(dateiWaehlerProvider)(nurBilder: false);
    if (a.dateien.isEmpty) {
      if (mounted && a.nichtLesbar > 0) zeigeHinweis(context, 'Die Datei ließ sich nicht öffnen.');
      return;
    }
    for (final d in a.dateien.skip(1)) {
      unawaited(d.quelle.schliessen());
    }
    final d = a.dateien.first;
    try {
      await ref.read(transferDienstProvider).hochladenFassung(dateiId: e.id, quelle: d.quelle, quellePfad: d.pfad);
    } on Object catch (x) {
      unawaited(d.quelle.schliessen());
      if (mounted) zeigeHinweis(context, dateiFehlerText(x));
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: const Text('Die neue Fassung wird hochgeladen.'), action: SnackBarAction(label: 'Anzeigen', onPressed: () => unawaited(Navigator.of(context).push<void>(UebertragungenScreen.route())))));
  }

  Future<void> _loeschen(DateiEintrag e) async {
    // die Seite schließt von selbst, sobald die Datei aus der Datenbank verschwindet (build)
    await dateiLoeschenFragen(context, ref, e);
  }

  Future<void> _offlineSchalten(DateiEintrag e, bool an) => _mit(() async {
    final v = e.neueste;
    if (v == null) return;
    final cache = ref.read(dateiCacheDienstProvider);
    if (an) {
      final pfad = await fassungInCache(context, ref, datei: e.datei, fassung: v, status: _status);
      if (pfad != null) await cache.anheften(v.blobId, true);
    } else {
      await cache.anheften(v.blobId, false);
      await cache.entfernen(v.blobId);
    }
  });

  @override
  Widget build(BuildContext context) {
    final rechte = ref.watch(dateiRechteProvider);
    final async = ref.watch(dateiEintragProvider(widget.dateiId));
    final e = async.value;
    if (e == null) {
      if (async.hasValue) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) unawaited(Navigator.of(context).maybePop());
        });
      }
      return DateiRahmen(
        label: '// datei',
        titel: 'Datei',
        child: async.hasValue ? const Text('Diese Datei gibt es nicht mehr.', style: TextStyle(color: kTextMuted)) : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final alleOrdner = ref.watch(alleOrdnerProvider).value ?? const <OrdnerZeile>[];
    final ort = ordnerPfadText(alleOrdner, e.datei.ordnerId);
    final art = vorschauArt(e.mime, e.name);
    final voll = zeigtVollbild(e.mime, e.name);
    final cacheDa = ref.watch(dateiCacheDienstProvider).verfuegbar;
    final kopie = e.neueste == null ? null : ref.watch(offlineKopienProvider).value?[e.neueste!.blobId];
    final offline = kopie?.angeheftet ?? false;
    final versionen = ref.watch(dateiVersionenProvider(e.id)).value ?? const <DateiVersionZeile>[];
    final darfAendern = rechte.darfAendern(e.datei.ownerId);

    return DateiRahmen(
      label: '// datei',
      titel: e.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Semantics(
              button: voll,
              label: voll ? 'Vorschau von ${e.name}. Bild öffnen' : 'Dateiart ${_artText(art)}',
              excludeSemantics: true,
              onTap: voll && e.neueste != null ? () => _bildOeffnen(e) : null,
              child: InkWell(
                onTap: voll && e.neueste != null ? () => _bildOeffnen(e) : null,
                borderRadius: BorderRadius.circular(14),
                child: DateiMiniatur(thumbBlobId: e.thumbBlobId, art: art, kante: 160, fit: BoxFit.contain),
              ),
            ),
          ),
          const SizedBox(height: 16),
          LxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Zeile('Typ', _artText(art)),
                _Zeile('Größe', groesseText(e.groesse)),
                _Zeile('Geändert', dateiZeit(e.geaendert)),
                _Zeile('Ordner', ort.isEmpty ? 'Oberste Ebene' : ort),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: StufenPille(e.audience)),
                if (e.lokalNeu) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Wird noch an die anderen Geräte gesendet.', style: TextStyle(fontSize: 12, color: kTextMuted))),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<String?>(
            valueListenable: _status,
            builder: (context, status, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (voll && e.neueste != null) FilledButton.icon(onPressed: _arbeitet ? null : () => _bildOeffnen(e), icon: const Icon(Icons.open_in_full), label: const Text('Öffnen')),
                if (e.neueste != null)
                  OutlinedButton.icon(
                    onPressed: _arbeitet ? null : () => unawaited(_mit(() => fassungSpeichern(context, ref, datei: e.datei, fassung: e.neueste!, status: _status))),
                    icon: const Icon(Icons.download_outlined),
                    label: Text(status ?? 'Speichern'),
                  ),
              ],
            ),
          ),
          if (cacheDa && e.neueste != null) ...[
            const SizedBox(height: 8),
            ValueListenableBuilder<String?>(
              valueListenable: _status,
              builder: (context, status, _) => SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                minTileHeight: 56,
                value: offline,
                onChanged: _arbeitet ? null : (an) => unawaited(_offlineSchalten(e, an)),
                title: const Text('Offline verfügbar'),
                subtitle: Text(status ?? (kopie == null ? 'Die Datei wird auf diesem Gerät gespeichert.' : 'Auf diesem Gerät: ${groesseText(kopie.groesse)}'), style: const TextStyle(color: kTextMuted, fontSize: 12)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (darfAendern) ...[
            ZeilenKnopf(icon: Icons.drive_file_rename_outline, text: 'Umbenennen', onTap: () => unawaited(_umbenennen(e))),
            ZeilenKnopf(icon: Icons.drive_file_move_outlined, text: 'Verschieben', onTap: () => unawaited(_verschieben(e))),
          ],
          if (rechte.darfStufeAendern)
            LxCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MonoLabel('// freigabe'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      DateiChip(label: 'Familie', icon: Icons.groups_outlined, gewaehlt: e.audience == kStufeFamilie, onTap: () => unawaited(dateiFreigabeAendern(context, ref, e, kStufeFamilie))),
                      DateiChip(label: 'Nur Eltern', icon: Icons.lock_outline, gewaehlt: e.audience == kStufeEltern, onTap: () => unawaited(dateiFreigabeAendern(context, ref, e, kStufeEltern))),
                    ],
                  ),
                ],
              ),
            ),
          if (rechte.darfStufeAendern) const SizedBox(height: 8),
          if (rechte.darfFassungHochladen(e.datei.ownerId)) ZeilenKnopf(icon: Icons.upload_file_outlined, text: 'Neue Fassung hochladen', onTap: () => unawaited(_neueFassung(e))),
          if (rechte.darfLoeschen(e.datei.ownerId)) ZeilenKnopf(icon: Icons.delete_outline, text: 'Datei endgültig löschen', farbe: kDanger, onTap: () => unawaited(_loeschen(e))),
          if (versionen.isNotEmpty) ...[
            const SizedBox(height: 12),
            const MonoLabel('// fassungen'),
            const SizedBox(height: 8),
            for (final v in versionen) _FassungZeile(e: e, v: v, aktuell: v.id == e.neueste?.id, gesperrt: _arbeitet, onSpeichern: () => unawaited(_mit(() => fassungSpeichern(context, ref, datei: e.datei, fassung: v, status: _status)))),
          ],
          const SizedBox(height: 12),
          const DateiHinweis(
            icon: Icons.shield_outlined,
            titel: 'Datenschutz',
            text: 'Vorschaubilder enthalten keinen Standort und keine Kameradaten. Das Original bleibt unverändert: Fotos können Aufnahmeort und Kamera enthalten. Teilen geht nur in der Familie über die Freigabe, nie per Link nach außen.',
          ),
        ],
      ),
    );
  }

  void _bildOeffnen(DateiEintrag e) {
    final v = e.neueste;
    if (v == null) return;
    unawaited(Navigator.of(context).push<void>(BildAnsichtScreen.route(name: e.name, blobId: v.blobId, groesse: v.size)));
  }
}

class _Zeile extends StatelessWidget {
  final String name;
  final String wert;
  const _Zeile(this.name, this.wert);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Semantics(
      container: true,
      label: '$name: $wert',
      excludeSemantics: true,
      child: Wrap(
        spacing: 8,
        children: [
          Text(name, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
          Text(wert, style: const TextStyle(fontSize: 13)),
        ],
      ),
    ),
  );
}

class _FassungZeile extends StatelessWidget {
  final DateiEintrag e;
  final DateiVersionZeile v;
  final bool aktuell;
  final bool gesperrt;
  final VoidCallback onSpeichern;
  const _FassungZeile({required this.e, required this.v, required this.aktuell, required this.gesperrt, required this.onSpeichern});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: LxCard(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              label: 'Fassung ${v.nr}${aktuell ? ', aktuell' : ''}, ${groesseText(v.size)}, ${dateiZeit(v.createdAt)}',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Fassung ${v.nr}${aktuell ? ' · aktuell' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${groesseText(v.size)} · ${dateiZeit(v.createdAt)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
          ),
          IconButton(tooltip: 'Fassung ${v.nr} speichern', icon: const Icon(Icons.download_outlined), onPressed: gesperrt ? null : onSpeichern),
        ],
      ),
    ),
  );
}
