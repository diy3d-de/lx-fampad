// Bausteine für die Oberflächentests der Tresor-Anhänge: aufzeichnendes Repository, Transfer-Dienst und Speicher-Dienst, Dateiwahl, Liste der Anhänge und der Übertragungen
// (alles ohne Netz und ohne Schlüsselmaterial; die echten Wege prüft tresor_anhang_test.dart). Die Liste der Anhänge folgt dem Sperrzustand wie im echten Anbieter: gesperrt = leer.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:lx_fampad/data/app_database.dart' show TransferZeile;
import 'package:lx_fampad/data/dateien/datei_modelle.dart';
import 'package:lx_fampad/data/dateien/datei_speichern.dart';
import 'package:lx_fampad/data/dateien/datei_state.dart' show dateienVerfuegbarProvider;
import 'package:lx_fampad/data/dateien/transfer_dienst.dart';
import 'package:lx_fampad/data/dateien/tresor_anhang_repository.dart';
import 'package:lx_fampad/data/dateien/tresor_anhang_state.dart';
import 'package:lx_fampad/data/dateien/tresor_anhang_waehler.dart';
import 'package:lx_fampad/data/dateien/upload_quelle.dart';

/// Ein kleines gültiges PNG (1 x 1 Pixel).
final Uint8List winzigPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

AnhangAnsicht anhang(String id, String eintragId, String name, {String? mime, int? groesse, String? hinweis, DateTime? am, bool lokalNeu = false}) => AnhangAnsicht(
  id: id,
  konversationId: 'k',
  blobId: 'b-$id',
  name: hinweis == null ? name : null,
  mime: mime,
  groesse: hinweis == null ? (groesse ?? 410 * 1024) : null,
  eintragId: hinweis == null ? eintragId : null,
  hinweis: hinweis,
  bearbeiterId: 'a',
  erstelltAt: am ?? DateTime.utc(2026, 9, 10, 12),
  lokalNeu: lokalNeu,
);

TransferZeile transferZeile(String id, String zustand, {int uebertragen = 0, int groesse = 1000, String? fehler, String art = 'anhang'}) => TransferZeile(
  id: id,
  richtung: 'Hoch',
  art: art,
  zustand: zustand,
  name: 'Anhang',
  mime: null,
  groesse: groesse,
  uebertragen: uebertragen,
  ordnerId: null,
  dateiId: null,
  versionId: null,
  audience: null,
  konversationId: null,
  blobId: null,
  thumbBlobId: null,
  quellePfad: null,
  zielPfad: null,
  sha256: null,
  fehlerCode: fehler,
  versuche: 0,
  naechsterVersuch: null,
  createdAt: DateTime.utc(2026, 10, 24),
  aktualisiertAt: DateTime.utc(2026, 10, 24),
);

class TestListe<T> extends Notifier<List<T>> {
  final List<T> start;
  TestListe(this.start);
  @override
  List<T> build() => start;
  void setzen(List<T> v) => state = v;
}

class FakeAnhangRepo implements TresorAnhangRepository {
  final AnhangTestAufbau a;
  FakeAnhangRepo(this.a);

  @override
  Future<Uint8List> herunterladen(String anhangId, {void Function(int)? fortschritt}) async {
    a.heruntergeladen.add(anhangId);
    final warte = a.ladeWarten;
    if (warte != null) await warte.future;
    final f = a.ladeFehler;
    if (f != null) throw f;
    final b = a.inhalte[anhangId] ?? Uint8List.fromList(const [1, 2, 3, 4]);
    a.ausgeliefert.add(b);
    return b;
  }

  @override
  Future<String> hochladen({required String name, required Uint8List bytes, String? mime, String? eintragId}) async {
    final f = a.hochladeFehler;
    if (f != null) throw f;
    a.hochgeladen.add((name: name, laenge: bytes.length, mime: mime, eintragId: eintragId, referenz: bytes));
    return 'T${a.hochgeladen.length}';
  }

  @override
  Future<void> loeschen(String anhangId) async {
    final f = a.loeschFehler;
    if (f != null) throw f;
    a.geloescht.add(anhangId);
    a.liste.setzen([for (final x in a.liste.state) if (x.id != anhangId) x]);
  }

  @override
  Future<int> fuerEintragLoeschen(String eintragId) async {
    final weg = [for (final x in a.liste.state) if (x.eintragId == eintragId) x.id];
    a.eintragGeloescht.add(eintragId);
    a.liste.setzen([for (final x in a.liste.state) if (x.eintragId != eintragId) x]);
    return weg.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class FakeTransferDienst implements TransferDienst {
  final AnhangTestAufbau a;
  FakeTransferDienst(this.a);

  @override
  Future<DateiNutzung> nutzung() async => a.nutzung;

  @override
  Future<void> abbrechen(String id) async {
    a.abgebrochen.add(id);
    a.transfers.setzen([for (final z in a.transfers.state) z.id == id ? z.copyWith(zustand: 'abgebrochen') : z]);
  }

  @override
  Future<void> wiederholen(String id, {UploadQuelle? quelle}) async => a.wiederholt.add(id);

  @override
  Future<void> entfernen(String id) async {
    a.entfernt.add(id);
    a.transfers.setzen([for (final z in a.transfers.state) if (z.id != id) z]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class FakeSpeichern implements DateiSpeichernDienst {
  final AnhangTestAufbau a;
  FakeSpeichern(this.a);

  @override
  Future<bool> bytes(String name, Uint8List bytes, {String? mime}) async {
    a.gespeichert.add((name: name, bytes: Uint8List.fromList(bytes), mime: mime));
    return a.speichernOk;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// Alles für die Tests der Anhänge: Zustand zum Beobachten und die Überschreibungen.
class AnhangTestAufbau {
  bool verfuegbar = true;
  DateiNutzung nutzung = DateiNutzung.standard;

  // Beobachtung
  final heruntergeladen = <String>[];
  final ausgeliefert = <Uint8List>[];
  final hochgeladen = <({String name, int laenge, String? mime, String? eintragId, Uint8List referenz})>[];
  final geloescht = <String>[];
  final eintragGeloescht = <String>[];
  final abgebrochen = <String>[];
  final wiederholt = <String>[];
  final entfernt = <String>[];
  final gespeichert = <({String name, Uint8List bytes, String? mime})>[];
  var wahlen = 0;

  // Steuerung
  Map<String, Uint8List> inhalte = {};
  Object? ladeFehler;
  Completer<void>? ladeWarten;
  Object? hochladeFehler;
  Object? loeschFehler;
  bool speichernOk = true;
  AnhangWahl? wahl;
  Completer<AnhangWahl?>? wahlWarten;

  late final NotifierProvider<TestListe<AnhangAnsicht>, List<AnhangAnsicht>> _listeProvider;
  late final NotifierProvider<TestListe<TransferZeile>, List<TransferZeile>> _transferProvider;
  late final ProviderContainer Function() _container;

  AnhangTestAufbau({List<AnhangAnsicht> daten = const []}) {
    _listeProvider = NotifierProvider<TestListe<AnhangAnsicht>, List<AnhangAnsicht>>(() => TestListe(daten));
    _transferProvider = NotifierProvider<TestListe<TransferZeile>, List<TransferZeile>>(() => TestListe(const []));
  }

  /// Muss nach dem Start der App gesetzt werden (Zugriff auf die Zustände der Listen).
  void verbinden(ProviderContainer c) => _container = () => c;

  ListeZugriff<AnhangAnsicht> get liste => ListeZugriff(_container(), _listeProvider);
  ListeZugriff<TransferZeile> get transfers => ListeZugriff(_container(), _transferProvider);

  List<Override> get overrides => [
    dateienVerfuegbarProvider.overrideWith((ref) async => verfuegbar),
    tresorAnhaengeProvider.overrideWith((ref) async {
      if (!ref.watch(tresorDokumenteAktivProvider)) return const <AnhangAnsicht>[];
      return ref.watch(_listeProvider);
    }),
    tresorAnhangRepositoryProvider.overrideWithValue(FakeAnhangRepo(this)),
    transferDienstProvider.overrideWithValue(FakeTransferDienst(this)),
    transferListeProvider.overrideWith((ref) => Stream.value(ref.watch(_transferProvider))),
    dateiSpeichernProvider.overrideWithValue(FakeSpeichern(this)),
    tresorAnhangWaehlerProvider.overrideWithValue(() async {
      wahlen++;
      final w = wahlWarten;
      if (w != null) return w.future;
      return wahl;
    }),
  ];
}

class ListeZugriff<T> {
  final ProviderContainer c;
  final NotifierProvider<TestListe<T>, List<T>> p;
  ListeZugriff(this.c, this.p);
  List<T> get state => c.read(p);
  void setzen(List<T> v) => c.read(p.notifier).setzen(v);
}

/// Eine Wahl der Dateiauswahl mit bekannter Größe.
AnhangWahl wahlVon(String name, Uint8List bytes, {int? laenge}) => AnhangWahl(name: name, laenge: laenge ?? bytes.length, bytes: Stream.value(bytes));
