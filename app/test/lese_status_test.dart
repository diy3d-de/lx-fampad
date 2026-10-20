// Lesebestätigung: Zustand einer eigenen Nachricht aus den Lesestandsdaten der Teilnehmer.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/lese_status.dart';

Nachricht _n({int rev = 5, required DateTime t}) => Nachricht(id: 'n1', konversationId: 'k', autorId: 'ich', inhalt: 'e1:x', antwortAuf: null, bearbeitetAt: null, createdAt: t, rev: rev);

void main() {
  final t = DateTime.utc(2026, 10, 20, 10);
  test('noch nicht beim Server: wird gesendet, egal was die anderen gelesen haben', () {
    final i = leseInfo(nachricht: _n(rev: 0, t: t), empfaenger: {'b'}, gelesenBis: {'b': t});
    expect(i.zustand, LeseZustand.wirdGesendet);
  });

  test('bestätigt, niemand hat gelesen: gesendet', () {
    expect(leseInfo(nachricht: _n(t: t), empfaenger: {'b'}, gelesenBis: const {}).zustand, LeseZustand.gesendet);
    expect(leseInfo(nachricht: _n(t: t), empfaenger: {'b'}, gelesenBis: {'b': t.subtract(const Duration(milliseconds: 1))}).zustand, LeseZustand.gesendet);
  });

  test('Lesestand gleich oder neuer als die Nachricht: gelesen', () {
    expect(leseInfo(nachricht: _n(t: t), empfaenger: {'b'}, gelesenBis: {'b': t}).zustand, LeseZustand.gelesen);
    expect(leseInfo(nachricht: _n(t: t), empfaenger: {'b'}, gelesenBis: {'b': t.add(const Duration(hours: 1))}).zustand, LeseZustand.gelesen);
  });

  test('mehrere Empfänger: erst wenn alle gelesen haben; teilweise bleibt es bei einem Haken, die Lesenden sind bekannt', () {
    final teil = leseInfo(nachricht: _n(t: t), empfaenger: {'b', 'c'}, gelesenBis: {'b': t});
    expect(teil.zustand, LeseZustand.gesendet);
    expect(teil.teilweise, isTrue);
    expect(teil.gelesenVon, {'b'});
    expect(leseInfo(nachricht: _n(t: t), empfaenger: {'b', 'c'}, gelesenBis: {'b': t, 'c': t}).zustand, LeseZustand.gelesen);
    // Lesestand einer Person, die kein Empfänger ist (z. B. entfernt), zählt nicht
    expect(leseInfo(nachricht: _n(t: t), empfaenger: {'b', 'c'}, gelesenBis: {'b': t, 'x': t}).zustand, LeseZustand.gesendet);
  });

  test('ohne Empfänger (allein im Chat): bleibt bei gesendet', () {
    expect(leseInfo(nachricht: _n(t: t), empfaenger: const {}, gelesenBis: const {}).zustand, LeseZustand.gesendet);
  });
}
