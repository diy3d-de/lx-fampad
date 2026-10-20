// Aufbau für Oberflächentests des verschlüsselten Chats: drei Personen mit echten (Fake-)Schlüsseln, ein ChatKrypto für die angemeldete Person (Anna) auf der Datenbank
// der Testumgebung, ein fester Stand der Verschlüsselung (bereit) und Hilfen, die Epochen und verschlüsselte Nachrichten der anderen als "vom Server" anlegen.
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart';
import 'package:lx_fampad/data/chat/chat_krypto_state.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/huelle.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/vertrauen.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';

import 'chat_welt.dart';
import 'fake_crypto.dart';
import 'fake_server.dart';
import 'test_app.dart';

const coraId = '33333333-3333-4333-8333-333333333333';

/// Kontrolle über die Verschlüsselung in Oberflächentests: kein Netz, kein Hintergrundlauf; Schlüsselbund wird bei jedem Zugriff aufgefrischt.
class TestKryptoController extends ChatKryptoController {
  final ChatKrypto Function() fabrik;
  final bool Function() aktiv;
  TestKryptoController(this.fabrik, this.aktiv);

  @override
  void starten() {}

  @override
  Future<void> mitgliederAktualisieren({bool erzwingen = false}) async {}

  @override
  Future<ChatKrypto?> krypto() async {
    if (!aktiv()) return null; // ohne eingerichteten Schlüssel auf diesem Gerät gibt es kein Krypto
    final k = fabrik();
    await k.aktualisieren();
    return k;
  }
}

/// Fester Stand der Verschlüsselung (Status bereit, Mitglieder mit Schlüsseln); ohne Netz.
class TestE2ee extends E2eeController {
  final E2eeState Function() zustand;
  final Personenschluessel? Function() lokal;
  TestE2ee(this.zustand, this.lokal);

  @override
  E2eeState build() => zustand();

  @override
  Future<void> laden() async {}

  @override
  Personenschluessel? get lokalerSchluessel => lokal();

  @override
  Future<int?> letzteBekannteVersion() async => 1;
}

class ChatUiAufbau {
  final TestUmgebung env;
  late final FakeCryptoProvider crypto = FakeCryptoProvider();
  late final ChatWelt welt = ChatWelt(crypto);
  late final TestPerson anna = TestPerson(fixIdAdmin, 'Anna', crypto);
  late final TestPerson ben = TestPerson(fixIdKind, 'Ben', crypto);
  late final TestPerson cora = TestPerson(coraId, 'Cora Berger', crypto);
  late final Geraet bens;
  late final ChatKrypto annasKrypto;
  final Map<String, OeffentlicheSchluessel> _tofu = {};

  /// Wer keine Verschlüsselung eingerichtet hat (für die Anzeige in der Personenwahl).
  Set<String> ohneSchluessel;

  /// Stand der Verschlüsselung dieser Person (Status), zum Beispiel keinSchluessel für die Hinweise.
  E2eeStatus status;

  /// Ungeprüfte Schlüsseländerungen anderer Personen (Warnungen).
  List<SchluesselWarnung> warnungen = const [];

  ChatUiAufbau(this.env, {this.ohneSchluessel = const {}, this.status = E2eeStatus.bereit}) {
    for (final p in [ben, cora]) {
      _tofu[p.id] = p.oeffentlich;
    }
    bens = Geraet.neu(welt, ben)..mitgliederLernen([anna, ben, cora]);
    annasKrypto = ChatKrypto(
      crypto: crypto,
      db: env.db,
      store: SyncStore(env.db),
      ichId: anna.id,
      meinSchluessel: anna.pk,
      meineKeyVersion: anna.version,
      gemerkt: (u, {version}) async => _tofu[u],
      serverSchluessel: () => null,
      absenderSchluessel: (u, v) async => _tofu[u]!,
    );
  }

  UserDto _mitglied(TestPerson p, {String role = 'child', String? email}) => UserDto(
    id: p.id,
    email: email,
    displayName: p.name,
    colorIndex: 0,
    role: Role.parse(p.id == anna.id ? 'admin' : role),
    status: MemberStatus.active,
    schluessel: ohneSchluessel.contains(p.id) ? null : p.oeffentlich,
  );

  E2eeState get zustand => E2eeState(
    status: status,
    serverSchluessel: status == E2eeStatus.keinSchluessel ? null : anna.oeffentlich,
    mitglieder: [_mitglied(anna), _mitglied(ben), _mitglied(cora, role: 'parent')],
    warnungen: warnungen,
    sicherheitscode: '12345 67890 12345 67890 12345 67890',
  );

  List<Override> get overrides => [
    chatKryptoProvider.overrideWith(() => TestKryptoController(() => annasKrypto, () => status == E2eeStatus.bereit)),
    e2eeProvider.overrideWith(() => TestE2ee(() => zustand, () => status == E2eeStatus.bereit ? anna.pk : null)),
  ];

  /// Epoche 1 (oder die nächste) einer Konversation, verteilt von Ben, als Zeilen für den Fake-Server (kommen mit dem Abgleich bei Anna an).
  Future<void> epoche(String konversationId, List<TestPerson> mitglieder, {String? art}) async {
    // Bens Gerät kennt die Konversation (sonst öffnet er keine Schlüssel)
    await bens.db.into(bens.db.konversationen).insertOnConflictUpdate(
      KonversationenCompanion.insert(id: konversationId, art: art ?? (mitglieder.length == 2 ? 'direct' : 'group'), createdAt: DateTime.now(), rev: const Value(1)),
    );
    final liste = await bens.krypto.epocheErstellen(konversationId: konversationId, mitglieder: {for (final m in mitglieder) m.id});
    await bens.store.aendernMehrere(liste);
    for (final a in liste) {
      env.sync.andereAendert(a.entity, a.id, {...a.fields, 'verteilerId': ben.id});
    }
    // Bens Epoche gilt für ihn als bestätigt (damit er und die Hilfe [verschluesselt] sie benutzen können)
    await bens.db.customStatement('UPDATE konversation_epochen SET rev = 1');
    await bens.krypto.aktualisieren();
  }

  /// Eine echte verschlüsselte Hülle `e1:` von [autor] mit dem Epochenschlüssel von Ben (Epoche [epoche]).
  Future<String> verschluesselt(String konversationId, String nachrichtId, TestPerson autor, String klartext, {int epoche = 1, String? antwortAuf}) async {
    final key = bens.krypto.schluessel(konversationId, epoche)!;
    final wire = HuellenCodec(crypto).versiegeln(
      schluessel: key,
      klartext: utf8Bytes(klartext),
      kontext: HuellenKontext(conversationId: konversationId, messageId: nachrichtId, senderId: autor.id, epoch: epoche, senderKeyVersion: autor.version, antwortAuf: antwortAuf),
      signGeheim: autor.pk.signGeheim,
    );
    return '$kPraefixE1$wire';
  }

  /// Nachricht eines anderen "vom Server" (verschlüsselt).
  Future<void> nachricht(String konversationId, String id, TestPerson autor, String klartext, String createdAt, {String? antwortAuf, int epoche = 1}) async {
    env.sync.andereAendert('nachricht', id, {
      'konversationId': konversationId,
      'text': await verschluesselt(konversationId, id, autor, klartext, epoche: epoche, antwortAuf: antwortAuf),
      'autorId': autor.id,
      'antwortAuf': ?antwortAuf,
      'createdAt': createdAt,
    });
  }
}
