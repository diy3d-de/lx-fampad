// Vorsorge und Impfungen (Abschnitt 6p): Planung der Erinnerungen (rein) und die Einstellung. Verbindlich: lokal, neutraler Text (nie Name, Person oder Art), Nutzlast nur `vorsorge`,
// ein Alarm je Person und Tag um 09:00 Familienzone, ab dem Vorlauf vor dem Zeitfenster und danach wöchentlich bis erledigt; nichts bei erledigten, Hinweis-Einträgen und nicht lesbaren.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_erinnerung.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_modelle.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_repository.dart' show VorsorgeProfilAnsicht;
import 'package:lx_fampad/data/vorsorge/vorsorge_state.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

const _ich = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _kind = 'cccccccc-0000-4000-8000-00000000000c';

UserDto _u(String id, Role r, String name) => UserDto(id: id, email: null, displayName: name, colorIndex: 0, role: r, status: MemberStatus.active);

var _n = 0;
VorsorgeAnsicht _e(VorsorgeEintragInhalt? i, {String subjekt = _ich}) => VorsorgeAnsicht(id: 'dddddddd-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}', konversationId: 'k', subjektId: subjekt, inhalt: i, erstelltAt: DateTime.utc(2026, 1, 1));

VorsorgeDaten _daten(List<VorsorgeAnsicht> e, {Map<String, String> geburt = const {}, bool kind = true, bool geladen = true}) => VorsorgeDaten(
  geladen: geladen,
  ich: _ich,
  ichRolle: Role.parent,
  personen: [_u(_ich, Role.parent, 'Mama Geheimname'), if (kind) _u(_kind, Role.child, 'Emil Geheimname')],
  eintraege: e,
  profile: {for (final g in geburt.entries) g.key: VorsorgeProfilAnsicht(subjektId: g.key, inhalt: VorsorgeProfilInhalt(geburt: g.value))},
);

void main() {
  tzdata.initializeTimeZones();
  // Dienstag, 27.10.2026, 07:00 Uhr Berlin (06:00 UTC, Normalzeit seit dem 25.10.)
  final jetzt = DateTime.utc(2026, 10, 27, 6, 0);

  test('Termin von Hand: Beginn des Fensters minus Vorlauf, danach wöchentlich, 09:00 Berlin; neutral', () {
    final d = _daten([_e(const VorsorgeEintragInhalt(name: 'Geheim-Augenarzt', art: VorsorgeArt.sonstiges, naechstes: '2026-11-10', vorlauf: 14, notiz: 'Geheimnotiz'))]);
    final plan = planeVorsorgeErinnerungen(daten: d, jetzt: jetzt);
    // Start am 27.10. (14 Tage vor dem 10.11.), dann 03.11. und 10.11., danach jede Woche weiter, soweit der Horizont (28 Tage) reicht (bis 17.11.)
    expect(plan.map((p) => p.zeit).toList()..sort(), [for (final t in [DateTime.utc(2026, 10, 27), DateTime.utc(2026, 11, 3), DateTime.utc(2026, 11, 10), DateTime.utc(2026, 11, 17)]) DateTime.utc(t.year, t.month, t.day, 8, 0)]);
    for (final p in plan) {
      expect(p.titel, 'Eine Vorsorge ist fällig');
      expect(p.payload, 'vorsorge');
      final alles = '${p.titel} ${p.text} ${p.payload}';
      for (final w in ['Geheim', 'Augenarzt', 'Emil', 'Mama', 'Impf', 'Zahn']) {
        expect(alles, isNot(contains(w)), reason: w);
      }
    }
    expect(plan.map((p) => p.id).toSet().length, plan.length);
  });

  test('heute 09:00 schon vorbei: der Alarm von heute entfällt, der nächste bleibt', () {
    final d = _daten([_e(const VorsorgeEintragInhalt(name: 'X', art: VorsorgeArt.sonstiges, naechstes: '2026-11-10', vorlauf: 14))]);
    final plan = planeVorsorgeErinnerungen(daten: d, jetzt: DateTime.utc(2026, 10, 27, 9, 0));
    expect(plan.map((p) => p.zeit).reduce((a, b) => a.isBefore(b) ? a : b), DateTime.utc(2026, 11, 3, 8, 0));
  });

  test('Vorlauf einstellbar: 0 Tage = am Tag selbst; später als der Horizont ergibt nichts', () {
    final heute = planeVorsorgeErinnerungen(daten: _daten([_e(const VorsorgeEintragInhalt(name: 'X', art: VorsorgeArt.sonstiges, naechstes: '2026-10-28', vorlauf: 0))]), jetzt: jetzt);
    expect(heute.map((p) => p.zeit).toList()..sort(), [DateTime.utc(2026, 10, 28, 8, 0), DateTime.utc(2026, 11, 4, 8, 0), DateTime.utc(2026, 11, 11, 8, 0), DateTime.utc(2026, 11, 18, 8, 0)]);
    final fern = planeVorsorgeErinnerungen(daten: _daten([_e(const VorsorgeEintragInhalt(name: 'X', art: VorsorgeArt.sonstiges, naechstes: '2027-06-01', vorlauf: 14))]), jetzt: jetzt);
    expect(fern, isEmpty);
  });

  test('höchstens ein Alarm je Person und Tag; zwei Personen ergeben zwei; Kinder-Einträge plant das Elternteil mit', () {
    final d = _daten([
      _e(const VorsorgeEintragInhalt(name: 'A', art: VorsorgeArt.sonstiges, naechstes: '2026-10-27')),
      _e(const VorsorgeEintragInhalt(name: 'B', art: VorsorgeArt.sonstiges, naechstes: '2026-10-20')),
      _e(const VorsorgeEintragInhalt(name: 'K', art: VorsorgeArt.sonstiges, naechstes: '2026-10-27'), subjekt: _kind),
    ]);
    final plan = planeVorsorgeErinnerungen(daten: d, jetzt: jetzt);
    final heute = plan.where((p) => p.zeit.isAtSameMomentAs(DateTime.utc(2026, 10, 27, 8, 0))).toList();
    expect(heute, hasLength(2), reason: 'Mama und Emil je einmal');
    expect(heute.map((p) => p.id).toSet(), hasLength(2));
  });

  test('Vorlage nach Alter: mit Profil geplant, ohne Profil nicht; Kind mit eigenem Profil', () {
    final u4 = _e(const VorsorgeEintragInhalt(vorlage: 'u4', art: VorsorgeArt.vorsorge), subjekt: _kind);
    expect(planeVorsorgeErinnerungen(daten: _daten([u4]), jetzt: jetzt), isEmpty, reason: 'ohne Geburtsdatum keine Rechnung');
    // Geburt 2026-08-01: U4 ab 01.10. (fällig), bis 01.12.
    final plan = planeVorsorgeErinnerungen(daten: _daten([u4], geburt: {_kind: '2026-08-01'}), jetzt: jetzt);
    expect(plan, isNotEmpty);
    expect(plan.every((p) => p.titel == kVorsorgeTitel), isTrue);
  });

  test('keine Erinnerung bei erledigt, nur Hinweis, nicht lesbar, ungeladen, ohne Einträge', () {
    final erledigt = _e(const VorsorgeEintragInhalt(vorlage: 'u4', art: VorsorgeArt.vorsorge, erledigt: ['2026-10-01']), subjekt: _kind);
    final hinweis = _e(const VorsorgeEintragInhalt(vorlage: 'fsme_risiko', art: VorsorgeArt.impfung));
    final unlesbar = _e(null);
    expect(planeVorsorgeErinnerungen(daten: _daten([erledigt, hinweis, unlesbar], geburt: {_kind: '2026-08-01', _ich: '1980-01-01'}), jetzt: jetzt), isEmpty);
    expect(planeVorsorgeErinnerungen(daten: _daten([], geburt: {_ich: '1980-01-01'}), jetzt: jetzt), isEmpty);
    expect(planeVorsorgeErinnerungen(daten: _daten([_e(const VorsorgeEintragInhalt(name: 'X', art: VorsorgeArt.sonstiges, naechstes: '2026-10-28'))], geladen: false), jetzt: jetzt), isEmpty);
  });

  test('Fenster 300: der Horizont bleibt klein (höchstens ein Alarm je Person und Woche und Tag)', () {
    final viele = [for (var i = 0; i < 40; i++) _e(VorsorgeEintragInhalt(name: 'E$i', art: VorsorgeArt.sonstiges, naechstes: '2026-10-${(1 + i % 27).toString().padLeft(2, '0')}'))];
    final plan = planeVorsorgeErinnerungen(daten: _daten(viele), jetzt: jetzt);
    expect(plan.length, lessThanOrEqualTo(kVorsorgeHorizontTage), reason: 'ein Alarm je Person und Tag, 28 Tage Horizont');
  });

  test('Nutzlast: nur die Kennung ist gültig', () {
    expect(istVorsorgePayload('vorsorge'), isTrue);
    expect(istVorsorgePayload('vorsorge|abc'), isFalse);
    expect(istVorsorgePayload(null), isFalse);
    expect(istVorsorgePayload('medikament|dddddddd-0000-4000-8000-00000000000d'), isFalse);
  });

  test('Einstellung: Standard an, "nein" aus, Wert bleibt erhalten', () async {
    final speicher = MemoryErinnerungSpeicher();
    expect(const ErinnerungEinstellungen().vorsorgeAn, isTrue);
    expect(const ErinnerungEinstellungen().kopie(vorsorgeAn: false).vorsorgeAn, isFalse);
    expect(const ErinnerungEinstellungen().kopie(vorsorgeAn: false), isNot(const ErinnerungEinstellungen()));
    speicher.daten['erinnerung_vorsorge'] = 'nein';
    expect((await speicher.lesen())['erinnerung_vorsorge'], 'nein');
  });
}
