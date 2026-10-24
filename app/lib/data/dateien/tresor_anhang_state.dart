// Anhänge im Tresor (Abschnitt 6m/6n), Zustand für die Oberfläche: wann es Dokumente gibt (Rolle + entsperrt + Server meldet `features.files`), die gelesene Liste der Anhänge (nur im
// Arbeitsspeicher, mit der Sperre sofort leer), die laufenden Uploads dieser Sitzung (Zuordnung Übertragung -> Eintrag, Name nur im Speicher) und die verständlichen Fehlertexte.
// Die Anhänge tauchen nirgends sonst auf (nie Dateien-Bereich, Suche, Wandtablet, Widget, Teilen, Push) und nie im Vorschau-Zwischenspeicher der Dateien-Ablage.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_database.dart' show TresorAnhangZeile;
import '../auth/auth_state.dart';
import '../chat/chat_krypto.dart' show VerschluesselungNichtBereit;
import '../crypto/crypto_fehler.dart';
import '../tresor/tresor_repository.dart' show TresorFehler;
import '../tresor/tresor_sperre.dart';
import '../tresor/tresor_state.dart';
import 'datei_logik.dart';
import 'datei_modelle.dart';
import 'datei_state.dart' show dateienVerfuegbarProvider;
import 'transfer_modelle.dart' show transferFehlerText;
import 'tresor_anhang_inhalt.dart' show kMaxTresorAnhaenge;
import 'tresor_anhang_repository.dart';
import 'tus_client.dart' show TusFehler;

/// Höchstens so viele Dokumente je Eintrag (kleiner als die Grenze des Servers von [kMaxTresorAnhaenge] je Tresor).
const int kMaxAnhaengeJeEintrag = 10;

/// Gibt es Dokumente? Nur für Eltern und Admins, nur bei entsperrtem Tresor und nur wenn der Server die Dateiablage anbietet. Sonst zeigt die Oberfläche den Abschnitt nicht (alte Einträge
/// funktionieren weiter).
final tresorDokumenteAktivProvider = Provider<bool>((ref) {
  if (!ref.watch(tresorDarfProvider)) return false;
  if (!ref.watch(tresorSperreProvider.select((s) => s.entsperrt))) return false;
  return ref.watch(dateienVerfuegbarProvider).value ?? false;
});

/// Die rohen Zeilen (verschlüsselt) der Anhänge; ohne Zugriff leer.
final tresorAnhangZeilenProvider = StreamProvider.autoDispose<List<TresorAnhangZeile>>((ref) {
  if (!ref.watch(tresorDokumenteAktivProvider)) return Stream.value(const <TresorAnhangZeile>[]);
  return ref.watch(tresorAnhangRepositoryProvider).zeilen();
});

/// Alle Anhänge des Tresors, gelesen (Name, Größe, Zuordnung; nie der Dateischlüssel). Mit der Sperre (oder dem Verlust des Rechts) ist die Liste sofort leer.
final tresorAnhaengeProvider = FutureProvider.autoDispose<List<AnhangAnsicht>>((ref) async {
  if (!ref.watch(tresorDokumenteAktivProvider)) return const <AnhangAnsicht>[];
  final zeilen = await ref.watch(tresorAnhangZeilenProvider.future);
  if (!ref.read(tresorDokumenteAktivProvider)) return const <AnhangAnsicht>[];
  return ref.read(tresorAnhangRepositoryProvider).lesen(zeilen);
});

/// Die Anhänge eines Eintrags (älteste zuerst); null, solange noch gelesen wird.
List<AnhangAnsicht>? anhaengeFuerEintrag(List<AnhangAnsicht>? alle, String eintragId) => alle == null ? null : [for (final a in alle) if (a.eintragId == eintragId) a];

/// Ein laufender Upload: nur Anzeige (Name, Größe des Klartexts), nur im Arbeitsspeicher.
class AnhangUpload {
  final String transferId;
  final String eintragId;
  final String name;
  final int groesse;
  const AnhangUpload({required this.transferId, required this.eintragId, required this.name, required this.groesse});
}

/// Laufende Uploads dieser Sitzung (Übertragung -> Eintrag und Name). Mit der Sperre, dem Abmelden und einem Rollenwechsel leer; die Übertragung selbst läuft weiter (verschlüsselt).
class TresorAnhangUploads extends Notifier<Map<String, AnhangUpload>> {
  @override
  Map<String, AnhangUpload> build() {
    ref.watch(tresorSperreProvider.select((s) => s.entsperrt));
    ref.watch(authProvider.select((a) => a.user?.id));
    ref.watch(tresorDarfProvider);
    return const {};
  }

  void hinzu(AnhangUpload u) => state = {...state, u.transferId: u};

  void weg(String transferId) {
    if (!state.containsKey(transferId)) return;
    state = {...state}..remove(transferId);
  }
}

final tresorAnhangUploadsProvider = NotifierProvider<TresorAnhangUploads, Map<String, AnhangUpload>>(TresorAnhangUploads.new);

/// Überschreibt Klartext im Arbeitsspeicher.
void anhangUeberschreiben(Uint8List? b) {
  if (b != null && b.isNotEmpty) b.fillRange(0, b.length, 0);
}

/// Verständlicher Text zu einem Fehler beim Anhängen, Öffnen, Speichern oder Löschen (nie Dateiname, nie Text des Servers).
String anhangFehlerText(Object e, {int? maxKlartextBytes}) {
  if (e is DateiFehler) {
    if (e.code == DateiFehler.zuGross.code && maxKlartextBytes != null) return 'Die Datei ist zu groß. Ein Dokument darf höchstens ${groesseText(maxKlartextBytes)} haben.';
    if (e.code == DateiFehler.speicherVoll.code) return 'Der Speicher der Familie ist voll. Lösche zuerst Dateien oder Dokumente, die du nicht mehr brauchst.';
    if (e.code == DateiFehler.zuVieleAnhaenge.code) return 'Der Tresor hat schon sehr viele Dokumente. Lösche zuerst ein altes.';
    if (e.code == DateiFehler.nichtGefunden.code) return 'Dieses Dokument gibt es nicht mehr.';
    return e.meldung;
  }
  if (e is TresorFehler) return e.meldung;
  if (e is VerschluesselungNichtBereit) return e.meldung;
  if (e is CryptoFehler) return 'Dieses Dokument ist beschädigt oder wurde verändert. Aus Sicherheitsgründen wird es nicht geöffnet.';
  if (e is TusFehler) return transferFehlerText(e.code);
  return 'Das hat nicht geklappt. Versuche es noch einmal.';
}
