// Anhänge im Tresor (Abschnitt 6n und 6m), Datenschicht: verschlüsselte Dateien zu Tresor-Einträgen. Die Datei wird auf dem Gerät mit einem Zufallsschlüssel je Datei verschlüsselt (secretstream, `e2ee_blob.dart`),
// als Modus `e2ee` hochgeladen (der Server sieht nur Größe und SHA-256 der Bytes) und danach als Sync-Entität `tresor_anhang` angelegt; deren `inhalt` ist eine e1-Hülle der Art `f` mit Name, Typ, Größe,
// Dateischlüssel, Prüfsumme und der Zuordnung zum Eintrag (`tresor_anhang_inhalt.dart`). Im Ausgang liegt der Inhalt als lokaler Klartext (`l1:`), den der Abgleich erst beim Senden verschlüsselt
// (ChatOpVorbereiter): er verlässt das Gerät nie im Klartext. Herunterladen und Entschlüsseln geschehen NUR im Arbeitsspeicher (nie eine Datei, nie Klartext in Cache oder Log); Schlüssel und Klartext
// werden überschrieben. Rechte: nur Eltern und Admins (Kinder nie), wie der Tresor. Nie Namen, Typen oder Inhalte loggen. Noch ohne Oberfläche.
import 'dart:async';

import 'package:crypto/crypto.dart' as c;
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show UserDto;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../chat/chat_ids.dart';
import '../chat/chat_krypto.dart';
import '../chat/chat_krypto_state.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/e2ee_state.dart' show cryptoProviderProvider;
import '../database_provider.dart';
import '../lists/members.dart';
import '../sync/sync_entities.dart' show zeitFuerServer;
import '../sync/sync_store.dart';
import '../sync_state.dart';
import '../tresor/tresor_repository.dart' show TresorFehler, TresorNichtErlaubt;
import '../tresor/tresor_teilnehmer.dart';
import 'blob_lader.dart';
import 'datei_logik.dart';
import 'datei_modelle.dart';
import 'e2ee_blob.dart';
import 'transfer_dienst.dart';
import 'tresor_anhang_inhalt.dart';
import 'tus_client.dart';
import 'upload_quelle.dart';

/// Ein Anhang für die Oberfläche: gelesen oder mit Hinweis, warum nicht.
class AnhangAnsicht {
  final String id;
  final String konversationId;
  final String blobId;

  /// Name, Typ, Größe, Zuordnung (der Dateischlüssel steckt nicht mehr darin: [AnhangAnsicht.inhalt] liefert ihn nur kurz, [AnhangAnsicht.name] usw. sind die Anzeigewerte).
  final String? name;
  final String? mime;
  final int? groesse;
  final String? eintragId;
  final String? hinweis;
  final String? bearbeiterId;
  final DateTime erstelltAt;

  /// Noch nicht vom Server bestätigt (liegt im Ausgang).
  final bool lokalNeu;
  const AnhangAnsicht({
    required this.id,
    required this.konversationId,
    required this.blobId,
    required this.name,
    required this.mime,
    required this.groesse,
    required this.eintragId,
    required this.hinweis,
    required this.bearbeiterId,
    required this.erstelltAt,
    required this.lokalNeu,
  });

  bool get lesbar => name != null;
}

class TresorAnhangRepository {
  final AppDatabase db;
  final SyncStore store;
  final Future<ChatKrypto?> Function() krypto;
  final E2eeBlobHelfer blob;
  final BlobLader lader;
  final TransferDienst dienst;
  final String? Function() ich;
  final String? Function() familie;
  final Future<List<UserDto>> Function() mitglieder;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  TresorAnhangRepository({
    required this.db,
    required this.store,
    required this.krypto,
    required this.blob,
    required this.lader,
    required this.dienst,
    required this.ich,
    required this.familie,
    required this.mitglieder,
    required this.beiAenderung,
    DateTime Function()? jetzt,
    String Function()? neueId,
  }) : _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid;

  /// ID der Tresor-Konversation dieser Familie (null: Familie unbekannt).
  String? get konversationId {
    final f = familie();
    return f == null ? null : tresorChatId(f);
  }

  Future<void> _darf() async {
    final me = ich();
    if (me == null || !darfTresorSehen(ich: me, mitglieder: await mitglieder())) throw const TresorNichtErlaubt();
  }

  // ------------------------------------------------------------------ Lesen

  /// Alle Anhänge des Tresors (älteste zuerst); leer, wenn es die Konversation lokal nicht gibt.
  Stream<List<TresorAnhangZeile>> zeilen() {
    final id = konversationId;
    if (id == null) return Stream.value(const []);
    return (db.select(db.tresorAnhaenge)
          ..where((z) => z.konversationId.equals(id))
          ..orderBy([(z) => OrderingTerm.asc(z.createdAt), (z) => OrderingTerm.asc(z.id)]))
        .watch();
  }

  /// Öffnet die Hülle einer Zeile: Klartext mit `f1:` oder ein Grund. Lokaler Klartext (`l1:`) gilt nur für eigene, noch nicht bestätigte Zeilen.
  Future<({String? text, String? hinweis})> _oeffnen(TresorAnhangZeile z) async {
    if (z.inhalt.startsWith(kPraefixLokal)) {
      if (z.bearbeiterId != null && z.bearbeiterId == ich()) return (text: z.inhalt.substring(kPraefixLokal.length), hinweis: null);
      return (text: null, hinweis: 'unverschlüsselt');
    }
    if (z.bearbeiterId == null) return (text: null, hinweis: 'Person nicht mehr in der Familie');
    final k = await krypto();
    if (k == null) return (text: null, hinweis: 'Nachrichten-Schutz nicht bereit');
    try {
      final d = await k.nachrichtOeffnen(konversationId: z.konversationId, nachrichtId: z.id, autorId: z.bearbeiterId, wire: z.inhalt, art: kArtAnhang);
      return d.lesbar ? (text: d.text, hinweis: null) : (text: null, hinweis: d.hinweis ?? 'nicht lesbar');
    } on Object {
      return (text: null, hinweis: 'nicht lesbar');
    }
  }

  /// Liest Anhänge (entschlüsselt, geprüft: Signatur, Konversation, eigene ID, Art). Nicht lesbare kommen mit Hinweis und ohne Inhalt; der Dateischlüssel erscheint nie in der Ansicht.
  Future<List<AnhangAnsicht>> lesen(Iterable<TresorAnhangZeile> zeilen) async {
    final out = <AnhangAnsicht>[];
    for (final z in zeilen) {
      final r = await _oeffnen(z);
      final i = r.text == null ? null : anhangLesen(r.text!);
      out.add(
        AnhangAnsicht(
          id: z.id,
          konversationId: z.konversationId,
          blobId: z.blobId,
          name: i?.name,
          mime: i?.mime,
          groesse: i?.groesse,
          eintragId: i?.eintragId,
          hinweis: i != null ? null : (r.hinweis ?? 'neuere App-Version nötig oder beschädigt'),
          bearbeiterId: z.bearbeiterId,
          erstelltAt: z.createdAt,
          lokalNeu: z.rev == 0,
        ),
      );
      i?.vergessen();
    }
    return out;
  }

  /// Die Anhänge eines Eintrags (die Zuordnung steht verschlüsselt im Inhalt, darum werden alle gelesen und gefiltert).
  Future<List<AnhangAnsicht>> fuerEintrag(String eintragId) async => [for (final a in await lesen(await (db.select(db.tresorAnhaenge)..orderBy([(z) => OrderingTerm.asc(z.createdAt)])).get())) if (a.eintragId == eintragId) a];

  // ------------------------------------------------------------------ Schreiben

  /// Verschlüsselt [bytes] und reiht den Upload ein (Übertragung der Art `anhang`); liefert die ID der Übertragung. Der Datensatz entsteht erst, wenn der Chiffretext oben ist (Rückruf des Transfer-Dienstes).
  /// Prüft vorab Rechte, Obergrenze der Anhänge, Größe (Klartext + Overhead höchstens `maxE2eeBytes` des Servers) und ob es die Tresor-Konversation gibt (Anhänge gehören zu einem Eintrag, den es schon gibt).
  /// [eintragId] ordnet den Anhang einem Tresor-Eintrag zu (nur verschlüsselt im Inhalt). Der Klartext [bytes] bleibt beim Aufrufer (er überschreibt ihn danach).
  Future<String> hochladen({required String name, required Uint8List bytes, String? mime, String? eintragId}) async {
    await _darf();
    final konv = konversationId;
    if (konv == null) throw const TresorFehler('Die Familie ist nicht bekannt.');
    final k = await krypto();
    if (k == null) throw const VerschluesselungNichtBereit('Richte zuerst den Nachrichten-Schutz ein (Profil › Sicherheit › Nachrichten-Schutz).');
    final vorhanden = await (db.select(db.tresorAnhaenge)..where((z) => z.konversationId.equals(konv))).get();
    if (vorhanden.length >= kMaxTresorAnhaenge) throw DateiFehler.zuVieleAnhaenge;
    final n = await dienst.nutzung();
    if (bytes.isEmpty) throw DateiFehler.leer;
    if (bytes.length > e2eeKlartextMax(n.maxE2eeBytes)) throw DateiFehler.zuGross;
    final fehler = await dienst.vorabPruefen(e2eeGroesse(bytes.length), e2ee: true);
    if (fehler != null) throw fehler;
    final bereinigt = bereinigeName(name);
    if (bereinigt == null) throw DateiFehler.nameUngueltig;
    final me = ich()!;
    final b = await blob.verschluesseln(bytes);
    final id = _neueId();
    final inhalt = AnhangInhalt(name: bereinigt, mime: mime, groesse: bytes.length, schluessel: b.schluessel, sha256: b.sha256, eintragId: eintragId);
    final klartext = anhangKodieren(inhalt); // wirft, wenn die Hülle zu groß würde: nichts wird hochgeladen
    final chiffre = b.chiffretext;
    try {
      return await dienst.hochladenAnhang(
        anhangId: id,
        konversationId: konv,
        anzeigeName: 'Anhang',
        quelle: UploadQuelle.ausBytes(chiffre),
        abschluss: (blobId, serverSha) async {
          // der Server nennt die SHA-256 der übertragenen Bytes: sie muss zu den eigenen passen (sonst kam etwas anderes an)
          if (serverSha != null && serverSha.toLowerCase() != b.sha256) throw const CryptoFehler(CryptoFehlerArt.format, 'Prüfsumme stimmt nicht.');
          await store.aendern(
            'tresor_anhang',
            id,
            {'konversationId': konv, 'blobId': blobId, 'inhalt': '$kPraefixLokal$klartext'},
            nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'bearbeiterId': me, 'size': chiffre.length},
          );
          beiAenderung();
          b.schluesselVergessen(); // der Schlüssel steckt jetzt (lokal als l1:, danach nur verschlüsselt) im Datensatz
        },
      );
    } on Object {
      b.schluesselVergessen();
      rethrow;
    }
  }

  // ------------------------------------------------------------------ Herunterladen

  /// Lädt den Chiffretext in den Arbeitsspeicher, prüft die Prüfsumme, entschlüsselt und liefert die Bytes der Datei (die der Aufrufer nach der Benutzung überschreibt). Nie eine Datei, nie Klartext
  /// im Cache. Wirft [TresorFehler] (nicht lesbar), [DateiFehler] oder [TusFehler] (Netz, keine Sicht = 404) und bei Manipulation [CryptoFehler].
  Future<Uint8List> herunterladen(String anhangId, {void Function(int)? fortschritt}) async {
    await _darf();
    final z = await (db.select(db.tresorAnhaenge)..where((t) => t.id.equals(anhangId))).getSingleOrNull();
    if (z == null) throw DateiFehler.nichtGefunden;
    final r = await _oeffnen(z);
    final i = r.text == null ? null : anhangLesen(r.text!);
    if (i == null) throw const TresorFehler('Dieser Anhang lässt sich gerade nicht lesen.');
    try {
      final n = await dienst.nutzung();
      final chiffre = await lader.laden(z.blobId, z.size, maxBytes: n.maxE2eeBytes, fortschritt: fortschritt);
      final klar = await blob.entschluesseln(chiffretext: chiffre, schluessel: i.schluessel, erwarteteSha256: i.sha256);
      if (klar.length != i.groesse) {
        klar.fillRange(0, klar.length, 0);
        throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
      }
      return klar;
    } finally {
      i.vergessen();
    }
  }

  // ------------------------------------------------------------------ Löschen

  /// Löscht den Anhang endgültig (auch auf allen Geräten; der Server räumt den Blob nach 7 Tagen auf).
  Future<void> loeschen(String anhangId) async {
    await _darf();
    final z = await (db.select(db.tresorAnhaenge)..where((t) => t.id.equals(anhangId))).getSingleOrNull();
    if (z == null) throw DateiFehler.nichtGefunden;
    await store.loeschen('tresor_anhang', anhangId);
    beiAenderung();
  }

  /// Löscht alle Anhänge eines Eintrags (wenn der Eintrag gelöscht wird; der Server kennt die Zuordnung nicht). Liefert die Zahl.
  Future<int> fuerEintragLoeschen(String eintragId) async {
    await _darf();
    final liste = await fuerEintrag(eintragId);
    if (liste.isEmpty) return 0;
    await store.loeschenMehrere([for (final a in liste) ('tresor_anhang', a.id)]);
    beiAenderung();
    return liste.length;
  }

  /// SHA-256 des Chiffretexts (Hex) für Prüfungen von außen.
  static String pruefsumme(Uint8List bytes) => c.sha256.convert(bytes).toString();
}

final tresorAnhangRepositoryProvider = Provider<TresorAnhangRepository>((ref) {
  return TresorAnhangRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    krypto: () => ref.read(chatKryptoProvider.notifier).krypto(),
    blob: E2eeBlobHelfer.spaet(() => ref.read(cryptoProviderProvider.future)),
    lader: BlobLader(ref.watch(apiClientProvider)),
    dienst: ref.watch(transferDienstProvider),
    ich: () => ref.read(authProvider).user?.id,
    familie: () => ref.read(authProvider).me?.familyId,
    mitglieder: () async => ref.read(mitgliederProvider.future),
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});
