// Aufbau für die Tests der Oberfläche der Dateiablage: die ganze App mit dem Fake-Server (features.files, Kontingent, tus und Blobs), Daten in der lokalen Datenbank, ein Speicher-Ort im
// Arbeitsspeicher (Android: Offline-Kopien), eine überschreibbare Dateiauswahl und ein aufzeichnender Speichern-Dienst. Die echten Wege der Datenschicht prüfen die Tests der Datenschicht.
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:crypto/crypto.dart' as c;
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/dateien/datei_ort.dart';
import 'package:lx_fampad/data/dateien/datei_speichern.dart';
import 'package:lx_fampad/data/dateien/datei_waehler.dart';
import 'package:lx_fampad/data/dateien/upload_quelle.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/sync_state.dart' show SyncZeiten;

import 'datei_welt.dart';
import 'fake_erinnerung_port.dart';
import 'fake_server.dart';
import 'harness.dart';
import 'test_app.dart';

/// Ein Speicher-Ort im Arbeitsspeicher (Android): Dateien und Teil-Dateien als Bytes.
class SpeicherOrt implements DateiOrt {
  final Map<String, BytesBuilder> dateien = {};
  int alleGeloescht = 0;

  @override
  bool get verfuegbar => true;
  @override
  Future<String?> pfad(String name) async => '/cache/$name';
  @override
  Future<bool> existiert(String pfad) async => dateien.containsKey(pfad);
  @override
  Future<int> laenge(String pfad) async => dateien[pfad]?.length ?? 0;
  @override
  Future<void> anhaengen(String pfad, Uint8List bytes) async => (dateien[pfad] ??= BytesBuilder(copy: false)).add(bytes);
  @override
  Future<Uint8List> lesen(String pfad) async => dateien[pfad]!.toBytes();
  @override
  Future<void> umbenennen(String von, String nach) async {
    final b = dateien.remove(von);
    if (b != null) dateien[nach] = b;
  }

  @override
  Future<void> loeschen(String pfad) async => dateien.remove(pfad);
  @override
  Future<String> sha256(String pfad) async => c.sha256.convert(dateien[pfad]!.toBytes()).toString();
  @override
  Future<void> alleLoeschen() async {
    alleGeloescht++;
    dateien.clear();
  }
}

class GespeicherteDatei {
  final String name;
  final int laenge;
  GespeicherteDatei(this.name, this.laenge);
}

/// Alles für einen Test der Oberfläche der Dateiablage.
class DateiUi {
  final TestUmgebung env;
  final FakeDateien welt;
  final SpeicherOrt? ort;
  final gespeichert = <GespeicherteDatei>[];
  final browserLaden = <(String, String)>[];

  /// Was die Dateiauswahl als Nächstes liefert (Tests setzen es vor dem Tipp).
  DateiAuswahl naechsteAuswahl = const DateiAuswahl([]);
  final auswahlAnfragen = <bool>[];

  DateiUi._(this.env, this.welt, this.ort);

  static const ich = fixIdAdmin;
  static const anderer = fixIdKind;

  /// [rolle] bestimmt Rechte und Sicht; [dateiablage] false = der Server meldet `features.files` nicht; [android] gibt einen Speicher-Ort (Offline-Kopien, Speichern über den Systemdialog).
  static DateiUi neu({String rolle = 'admin', bool dateiablage = true, bool android = false, int belegt = 5368709120, int kontingent = 10737418240, int maxDatei = 104857600}) {
    final server = standardServer(role: rolle);
    server.json('GET /version', {'service': 'lx-fampad', 'features': dateiablage ? {'files': true} : <String, dynamic>{}});
    final env = TestUmgebung(server);
    final welt = FakeDateien(server, env.sync);
    welt.kontingent = kontingent;
    welt.maxDateiBytes = maxDatei;
    welt.rollen['access-1'] = Role.parse(rolle);
    // Belegung vortäuschen: ein fertiger Blob der gewünschten Größe
    if (belegt > 0) {
      welt.blobs['00000000-0000-4000-8000-0000000000aa'] = FakeBlob('00000000-0000-4000-8000-0000000000aa', 'server', 'datei', null, belegt, 'x')..zustand = 'claimed';
    }
    env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
    final ort = android ? SpeicherOrt() : null;
    // lokale Änderungen gehen im Test nicht zum Server (die Daten liegen nur lokal): kein Abgleich, der sie als unbekannt zurückweist
    env.zeiten = const SyncZeiten(entprellen: Duration(hours: 1), periodisch: Duration(hours: 1));
    final d = DateiUi._(env, welt, ort);
    if (ort != null) env.dateiOrt = ort;
    env.extraOverrides.add(dateiWaehlerProvider.overrideWithValue(({required bool nurBilder}) async {
      d.auswahlAnfragen.add(nurBilder);
      final a = d.naechsteAuswahl;
      d.naechsteAuswahl = const DateiAuswahl([]);
      return a;
    }));
    env.extraOverrides.add(dateiSpeichernProvider.overrideWith((ref) => DateiSpeichernDienst(
      ort: ort ?? const KeinDateiOrt(),
      adresse: (b) => 'https://familie.test/api/v1/files/blobs/$b',
      bytes: (n, b, m) async {
        d.gespeichert.add(GespeicherteDatei(n, b.length));
        return true;
      },
      browserLaden: (a, n) {
        d.browserLaden.add((a, n));
        return true;
      },
    )));
    return d;
  }

  Future<ProviderContainer> start(WidgetTester tester, {double skala = 1.0, Size groesse = const Size(360, 800)}) async {
    await env.angemeldet();
    return starteApp(tester, env, skala: skala, groesse: groesse);
  }

  AppDatabase get db => env.db;

  // ------------------------------------------------------------------ Daten (direkt in die lokale Datenbank, als schon vom Server bestätigt)

  Future<void> ordner(String id, String name, {String? parent, String audience = 'family', String? besitzer = ich}) => db.into(db.ordner).insert(
    OrdnerCompanion.insert(id: id, name: name, createdAt: DateTime.utc(2026, 3, 1), parentId: Value(parent), audience: Value(audience), ownerId: Value(besitzer), rev: const Value(1)),
  );

  /// Legt eine Datei mit [fassungen] Fassungen an (die neueste zuletzt); die Blob-IDs sind `<id>-v<nr>`.
  Future<void> datei(
    String id,
    String name, {
    String? ordner,
    String audience = 'family',
    String? besitzer = ich,
    int groesse = 2048,
    String? mime = 'text/plain',
    int fassungen = 1,
    String? thumb,
    DateTime? zeit,
  }) async {
    await db.into(db.dateien).insert(DateienCompanion.insert(id: id, name: name, createdAt: zeit ?? DateTime.utc(2026, 3, 2, 10, 5), ordnerId: Value(ordner), audience: Value(audience), ownerId: Value(besitzer), rev: const Value(1)));
    for (var nr = 1; nr <= fassungen; nr++) {
      await db.into(db.dateiVersionen).insert(
        DateiVersionenCompanion.insert(
          id: '$id-f$nr',
          dateiId: id,
          nr: nr,
          blobId: '$id-v$nr',
          createdAt: (zeit ?? DateTime.utc(2026, 3, 2, 10, 5)).add(Duration(hours: nr)),
          size: Value(groesse * nr),
          mime: Value(mime),
          thumbBlobId: Value(nr == fassungen ? thumb : null),
          rev: const Value(1),
        ),
      );
    }
  }

  /// Ein fertiger Blob beim Fake-Server, den die App herunterladen kann.
  void blob(String blobId, Uint8List bytes, {String kind = 'datei', String? mime}) {
    welt.blobs[blobId] = FakeBlob(blobId, 'server', kind, mime, bytes.length, 'x')
      ..zustand = 'claimed'
      ..sha256 = c.sha256.convert(bytes).toString()
      ..daten.add(bytes);
  }

  GewaehlteDatei gewaehlt(String name, int laenge) => GewaehlteDatei(name: name, laenge: laenge, quelle: UploadQuelle.ausBytes(Uint8List(laenge)));
}
