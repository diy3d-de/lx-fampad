// Hinweis-Zahlen im Blatt "Mehr" für Vorsorge und Müll: Summe, rotes Zeichen bei Überfälligem, Kinder sehen die Zahl für sich, ohne Daten keine Zahl, nie Namen oder Art im Text.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/shell/leiste_logik.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_modelle.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_repository.dart' show VorsorgeProfilAnsicht;
import 'package:lx_fampad/data/vorsorge/vorsorge_state.dart';
import 'package:lx_fampad/features/calendar/calendar_anzeige.dart' show minutenTaktProvider;
import 'package:lx_fampad/features/vorsorge/vorsorge_anzeige.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

const _ich = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _kind = 'cccccccc-0000-4000-8000-00000000000c';

UserDto _u(String id, Role r) => UserDto(id: id, email: null, displayName: 'GeheimName$id', colorIndex: 0, role: r, status: MemberStatus.active);
var _n = 0;
VorsorgeAnsicht _e(String s, VorsorgeEintragInhalt? i) => VorsorgeAnsicht(id: 'dddddddd-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}', konversationId: 'k', subjektId: s, inhalt: i, erstelltAt: DateTime.utc(2026, 10, 1));

({int offen, int ueberfaellig}) _zahl(VorsorgeDaten d) {
  final c = ProviderContainer(overrides: [vorsorgeDatenProvider.overrideWithValue(d), minutenTaktProvider.overrideWith((ref) => Stream.value(DateTime.utc(2026, 10, 24, 10)))]);
  addTearDown(c.dispose);
  c.listen(minutenTaktProvider, (_, _) {});
  return c.read(vorsorgeHinweisProvider);
}

void main() {
  tzdata.initializeTimeZones();

  test('Zahl: fällige und überfällige Einträge der sichtbaren Personen; Überfälliges einzeln; Bald und Erledigtes zählen nicht', () async {
    final d = VorsorgeDaten(
      geladen: true,
      ich: _ich,
      ichRolle: Role.parent,
      personen: [_u(_ich, Role.parent), _u(_kind, Role.child)],
      eintraege: [
        _e(_ich, const VorsorgeEintragInhalt(vorlage: 'checkup_35', art: VorsorgeArt.vorsorge)), // fällig
        _e(_ich, const VorsorgeEintragInhalt(name: 'Bald', art: VorsorgeArt.sonstiges, naechstes: '2026-11-20')), // bald
        _e(_kind, const VorsorgeEintragInhalt(vorlage: 'u4', art: VorsorgeArt.vorsorge)), // Fenster 2026-08-01 + 2..4 Monate: überfällig
        _e(_kind, const VorsorgeEintragInhalt(vorlage: 'u9', art: VorsorgeArt.vorsorge)), // später
        _e(_kind, null),
      ],
      profile: {
        _ich: const VorsorgeProfilAnsicht(subjektId: _ich, inhalt: VorsorgeProfilInhalt(geburt: '1985-04-04')),
        _kind: const VorsorgeProfilAnsicht(subjektId: _kind, inhalt: VorsorgeProfilInhalt(geburt: '2026-03-01')),
      },
    );
    final z = _zahl(d);
    expect(z.offen, 2);
    expect(z.ueberfaellig, 1);
  });

  test('ohne Daten keine Zahl; ein Kind sieht die Zahl für sich', () {
    expect(_zahl(const VorsorgeDaten(geladen: true, ich: _ich, ichRolle: Role.parent)), (offen: 0, ueberfaellig: 0));
    final kind = VorsorgeDaten(
      geladen: true,
      ich: _kind,
      ichRolle: Role.child,
      personen: [_u(_kind, Role.child)],
      eintraege: [_e(_kind, const VorsorgeEintragInhalt(vorlage: 'u4', art: VorsorgeArt.vorsorge))],
      profile: {_kind: const VorsorgeProfilAnsicht(subjektId: _kind, inhalt: VorsorgeProfilInhalt(geburt: '2026-08-01'))},
    );
    expect(_zahl(kind), (offen: 1, ueberfaellig: 0), reason: 'U4 beginnt am 01.10., am 24.10. im Fenster');
  });

  test('MehrHinweise: Summe und rotes Zeichen enthalten Vorsorge und Müll (liegen immer hinter Mehr)', () {
    const h = MehrHinweise(vorsorge: 3, vorsorgeUeberfaellig: 1, muell: 1, fristen: 2);
    expect(h.summe(const [1, 2, 4, 5]), 6);
    expect(h.summe(const [1, 2, 4, 6]), 6);
    expect(h.ueberfaellig(const [1, 2, 4, 6]), isTrue);
    const ohneRot = MehrHinweise(vorsorge: 2, muell: 1);
    expect(ohneRot.summe(const [1, 2, 4, 6]), 3);
    expect(ohneRot.ueberfaellig(const [1, 2, 4, 6]), isFalse);
    expect(const MehrHinweise().summe(const [1, 2, 4, 6]), 0);
  });

  test('Darf Kinder nur ansehen: Schreiben nur für Eltern und Admins', () {
    expect(vorsorgeDarfSchreiben(Role.child), isFalse);
    expect(vorsorgeDarfSchreiben(Role.parent), isTrue);
    expect(vorsorgeDarfSchreiben(Role.admin), isTrue);
  });
}
