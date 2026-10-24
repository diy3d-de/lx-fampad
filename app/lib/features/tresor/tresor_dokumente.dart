// Tresor (Abschnitt 6m/6n): der Abschnitt "Dokumente" eines Eintrags. Er zeigt die Anhänge dieses Eintrags (Name, Größe, Datum; Tipp öffnet), laufende Uploads mit Fortschritt (Zeile hier;
// die Übertragung steht zugleich in der Liste der Übertragungen, die Kopfzeile bleibt unverändert) und "Dokument anhängen". Anhängen geht nur an einem Eintrag, den es schon gibt: bei einem NEUEN,
// noch nicht gespeicherten Eintrag erscheint stattdessen ein Hinweis (so hält die App nie Klartext von Dateien vor, bis die Person speichert, und es gibt keinen Zustand "Anhang ohne Eintrag").
// Die Datei wird auf dem Gerät verschlüsselt, bevor sie hochgeladen wird (Datenschicht); der Klartext liegt nur im Arbeitsspeicher und wird danach überschrieben. Nach einem Neustart sind
// Anhang-Uploads nicht fortsetzbar: die Zeile sagt dann "Bitte Datei neu wählen". Ohne `features.files` des Servers (oder gesperrt, oder als Kind) erscheint nichts.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart' show TransferZeile;
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_modelle.dart' show DateiFehler;
import '../../data/dateien/e2ee_blob.dart';
import '../../data/dateien/transfer_dienst.dart';
import '../../data/dateien/transfer_modelle.dart';
import '../../data/dateien/tresor_anhang_repository.dart';
import '../../data/dateien/tresor_anhang_state.dart';
import '../../data/dateien/tresor_anhang_waehler.dart';
import '../../data/tresor/tresor_sperre.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show bestaetigen;
import 'tresor_anhang_screen.dart';
import 'tresor_bausteine.dart';

/// Feste Codes von Übertragungen, bei denen nur eine neue Dateiwahl hilft (die Quelle ist weg oder hat sich geändert).
const _neuWaehlen = {'anhang_neu', 'quelle_fehlt', 'datei_geaendert', 'invalid_reference'};

class TresorDokumente extends ConsumerStatefulWidget {
  /// Der Eintrag, zu dem die Dokumente gehören; null = neuer, noch nicht gespeicherter Eintrag (nur der Hinweis).
  final String? eintragId;
  const TresorDokumente({super.key, required this.eintragId});

  @override
  ConsumerState<TresorDokumente> createState() => _TresorDokumenteState();
}

class _TresorDokumenteState extends ConsumerState<TresorDokumente> {
  String? _fehler;
  var _beschaeftigt = false;

  Future<void> _anhaengen() async {
    final eintragId = widget.eintragId;
    if (eintragId == null || _beschaeftigt) return;
    final vorhanden = anhaengeFuerEintrag(ref.read(tresorAnhaengeProvider).value, eintragId)?.length ?? 0;
    final laufend = ref.read(tresorAnhangUploadsProvider).values.where((u) => u.eintragId == eintragId).length;
    if (vorhanden + laufend >= kMaxAnhaengeJeEintrag) {
      setState(() => _fehler = 'Ein Eintrag hat höchstens $kMaxAnhaengeJeEintrag Dokumente. Lösche zuerst ein altes.');
      return;
    }
    setState(() {
      _beschaeftigt = true;
      _fehler = null;
    });
    Uint8List? bytes;
    var max = 0;
    try {
      final n = await ref.read(transferDienstProvider).nutzung();
      max = e2eeKlartextMax(n.maxE2eeBytes);
      final wahl = await ref.read(tresorSperreProvider.notifier).mitSystemDialog(() => ref.read(tresorAnhangWaehlerProvider)());
      if (wahl == null || !mounted || !ref.read(tresorDokumenteAktivProvider)) return;
      // Größe und Kontingent vorab prüfen, wenn die Größe schon bekannt ist (bevor die Datei geladen wird)
      final l = wahl.laenge;
      if (l != null) {
        final f = l > max ? DateiFehler.zuGross : groessePruefen(e2eeGroesse(l), n, e2ee: true);
        if (f != null) {
          setState(() => _fehler = anhangFehlerText(f, maxKlartextBytes: max));
          return;
        }
      }
      bytes = await anhangWahlLesen(wahl, max: max);
      if (!mounted || !ref.read(tresorDokumenteAktivProvider)) return;
      final f = groessePruefen(e2eeGroesse(bytes.length), n, e2ee: true);
      if (f != null) {
        setState(() => _fehler = anhangFehlerText(f, maxKlartextBytes: max));
        return;
      }
      final mime = mimeFuerUpload(wahl.name, Uint8List.sublistView(bytes, 0, math.min(16, bytes.length)));
      final id = await ref.read(tresorAnhangRepositoryProvider).hochladen(name: wahl.name, bytes: bytes, mime: mime, eintragId: eintragId);
      if (!mounted) return;
      ref.read(tresorAnhangUploadsProvider.notifier).hinzu(AnhangUpload(transferId: id, eintragId: eintragId, name: wahl.name, groesse: bytes.length));
    } on Object catch (e) {
      if (mounted) setState(() => _fehler = anhangFehlerText(e, maxKlartextBytes: max > 0 ? max : null));
    } finally {
      anhangUeberschreiben(bytes);
      if (mounted) setState(() => _beschaeftigt = false);
    }
  }

  Future<void> _loeschen(AnhangAnsicht a) async {
    final ok = await bestaetigen(context, titel: 'Dokument löschen?', text: '„${a.name ?? 'Dokument'}“ verschwindet für alle Eltern und lässt sich nicht wiederherstellen.', knopf: 'Löschen');
    if (!ok || !mounted) return;
    try {
      await ref.read(tresorAnhangRepositoryProvider).loeschen(a.id);
    } on Object catch (e) {
      if (mounted) setState(() => _fehler = anhangFehlerText(e));
    }
  }

  Future<void> _verwerfen(AnhangUpload u) async {
    final dienst = ref.read(transferDienstProvider);
    ref.read(tresorAnhangUploadsProvider.notifier).weg(u.transferId);
    await dienst.entfernen(u.transferId);
  }

  Future<void> _neuWaehlenFuer(AnhangUpload u) async {
    await _verwerfen(u);
    if (mounted) await _anhaengen();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(tresorDokumenteAktivProvider)) return const SizedBox.shrink();
    final id = widget.eintragId;
    if (id == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 14),
        child: TresorHinweis(titel: 'Dokumente anhängen', text: 'Speichere den Eintrag zuerst. Danach kannst du Dokumente anhängen, indem du den Eintrag öffnest oder bearbeitest.', icon: Icons.attach_file),
      );
    }
    final alle = ref.watch(tresorAnhaengeProvider);
    final liste = anhaengeFuerEintrag(alle.value, id);
    final uploads = [for (final u in ref.watch(tresorAnhangUploadsProvider).values) if (u.eintragId == id) u];
    final transfers = {for (final z in ref.watch(transferListeProvider).value ?? const <TransferZeile>[]) z.id: z};
    // fertige und abgebrochene Uploads verschwinden aus der Zeile (der Anhang steht dann in der Liste)
    ref.listen(transferListeProvider, (_, neu) {
      for (final z in neu.value ?? const <TransferZeile>[]) {
        final u = ref.read(tresorAnhangUploadsProvider)[z.id];
        if (u == null) continue;
        if (z.zustandTyp == TransferZustand.fertig || z.zustandTyp == TransferZustand.abgebrochen) unawaited(_verwerfen(u));
      }
    });
    final anzahl = (liste?.length ?? 0) + uploads.length;
    final voll = anzahl >= kMaxAnhaengeJeEintrag;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: MonoLabel('// dokumente')),
              Text('$anzahl von $kMaxAnhaengeJeEintrag', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
            ],
          ),
          const SizedBox(height: 8),
          if (_fehler != null) ...[MeldungsBox(_fehler!), const SizedBox(height: 8)],
          if (alle.hasError && liste == null)
            const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Die Dokumente lassen sich gerade nicht lesen.', style: TextStyle(color: kTextMuted)))
          else if (liste == null)
            const Padding(padding: EdgeInsets.only(bottom: 8), child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))))
          else if (liste.isEmpty && uploads.isEmpty)
            const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Noch kein Dokument angehängt.', style: TextStyle(color: kTextMuted))),
          for (final u in uploads) _UploadZeile(key: ValueKey('upload-${u.transferId}'), upload: u, zeile: transfers[u.transferId], verwerfen: () => unawaited(_verwerfen(u)), neuWaehlen: () => unawaited(_neuWaehlenFuer(u))),
          for (final a in liste ?? const <AnhangAnsicht>[]) _AnhangZeile(key: ValueKey('anhang-${a.id}'), anhang: a, loeschen: () => unawaited(_loeschen(a))),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: voll || _beschaeftigt ? null : () => unawaited(_anhaengen()),
            icon: const Icon(Icons.attach_file),
            label: Text(_beschaeftigt ? 'Wird vorbereitet …' : 'Dokument anhängen'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
          if (voll) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Mehr Dokumente passen nicht an diesen Eintrag.', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted))),
          const SizedBox(height: 10),
          const TresorHinweis(titel: 'Anhänge sind verschlüsselt', text: 'Anhänge werden auf deinem Gerät verschlüsselt, bevor sie hochgeladen werden. Der Server sieht weder Namen noch Inhalt. Änderungen an Dokumenten gelten sofort.', icon: Icons.lock_outline),
        ],
      ),
    );
  }
}

BoxDecoration _rahmen({Color farbe = kBorderSoft}) => BoxDecoration(border: Border.all(color: farbe), borderRadius: BorderRadius.circular(12));

class _AnhangZeile extends StatelessWidget {
  final AnhangAnsicht anhang;
  final VoidCallback loeschen;
  const _AnhangZeile({super.key, required this.anhang, required this.loeschen});

  @override
  Widget build(BuildContext context) {
    final a = anhang;
    final lesbar = a.lesbar;
    final name = lesbar ? a.name! : 'Nicht lesbar';
    final meta = lesbar
        ? [if (a.groesse != null) groesseText(a.groesse!), tresorAnhangDatum(a.erstelltAt), if (a.lokalNeu) 'wird abgeglichen'].join(' · ')
        : 'Dieses Dokument lässt sich gerade nicht lesen.';
    void oeffnen() {
      if (lesbar) unawaited(tresorAnhangOeffnen(context, a));
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: _rahmen(),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: lesbar,
                label: 'Dokument $name, $meta',
                excludeSemantics: true,
                onTap: lesbar ? oeffnen : null,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: lesbar ? oeffnen : null,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 52),
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    child: Row(
                      children: [
                        Icon(lesbar ? tresorAnhangIcon(a.mime, a.name!) : Icons.lock_outline, size: 20, color: lesbar ? kAccent : kTextMuted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text(meta, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: lesbar ? 'Dokument $name löschen' : 'Dokument löschen',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: loeschen,
              icon: const Icon(Icons.delete_outline, color: kDanger),
            ),
          ],
        ),
      ),
    );
  }
}

class _UploadZeile extends StatelessWidget {
  final AnhangUpload upload;
  final TransferZeile? zeile;
  final VoidCallback verwerfen;
  final VoidCallback neuWaehlen;
  const _UploadZeile({super.key, required this.upload, required this.zeile, required this.verwerfen, required this.neuWaehlen});

  @override
  Widget build(BuildContext context) {
    final z = zeile;
    final zustand = z?.zustandTyp ?? TransferZustand.wartet;
    final proz = z == null ? 0 : (z.fortschritt * 100).round();
    final fehler = zustand == TransferZustand.fehler || zustand == TransferZustand.dateiNoetig;
    final code = z?.fehlerCode;
    final neu = zustand == TransferZustand.dateiNoetig || (code != null && _neuWaehlen.contains(code));
    final text = switch (zustand) {
      TransferZustand.wartet => z?.naechsterVersuch != null ? 'Wartet auf eine bessere Verbindung …' : 'Wartet …',
      TransferZustand.laeuft => 'Wird hochgeladen · $proz %',
      TransferZustand.abschliessen => 'Wird abgeschlossen …',
      TransferZustand.fehler || TransferZustand.dateiNoetig => neu ? 'Bitte Datei neu wählen.' : transferFehlerText(code),
      _ => '',
    };
    final aktiv = zustand.aktiv;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        container: true,
        label: 'Dokument ${upload.name}, $text',
        child: Container(
          decoration: _rahmen(farbe: fehler ? kWarn : kBorderSoft),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          constraints: const BoxConstraints(minHeight: 52),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(fehler ? Icons.error_outline : Icons.cloud_upload_outlined, size: 20, color: fehler ? kWarn : kAccent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(upload.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text('${groesseText(upload.groesse)} · $text', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                        ],
                      ),
                    ),
                  ),
                  if (aktiv)
                    Consumer(
                      builder: (context, ref, _) => IconButton(
                        tooltip: 'Upload von ${upload.name} abbrechen',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: () => unawaited(ref.read(transferDienstProvider).abbrechen(upload.transferId)),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                ],
              ),
              if (aktiv)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 4, bottom: 2),
                  child: ExcludeSemantics(child: LinearProgressIndicator(value: zustand == TransferZustand.laeuft && z != null ? z.fortschritt : null)),
                ),
              if (fehler)
                Wrap(
                  spacing: 8,
                  children: [
                    Consumer(
                      builder: (context, ref, _) => TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: neu ? neuWaehlen : () => unawaited(ref.read(transferDienstProvider).wiederholen(upload.transferId)),
                        child: Text(neu ? 'Datei neu wählen' : 'Erneut versuchen'),
                      ),
                    ),
                    TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: verwerfen, child: const Text('Verwerfen')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
