// Betreiber-Ansicht "Betrieb" (fast nur lesend): Modelle zu GET /admin/status, /admin/audit, /admin/key-status, /admin/members und /admin/warnings. Die Auswertung ist tolerant: unbekannte Felder
// und Werte einer neueren Server-Version werden ignoriert bzw. als "unbekannt" gezeigt, nie ein Absturz. Angezeigt wird nie ein Rohtext des Servers,
// nur feste Wörter dieser App zu festen Codes.
import '../api/api_error.dart';
import '../api/models.dart';

/// Zustand eines Dienstes oder einer Messung (feste Liste des Servers; alles andere gilt als [unbekannt]).
enum BetriebStufe {
  ok,
  warn,
  fehler,
  aus,
  unbekannt;

  static BetriebStufe lesen(Object? v) => switch (v) {
    'ok' => ok,
    'warn' => warn,
    'error' => fehler,
    'off' => aus,
    _ => unbekannt,
  };
}

int? _zahl(Object? v) => v is num && v.isFinite ? v.toInt() : null;
String? _text(Object? v) => v is String ? v : null;
DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v) : null;
Json _map(Object? v) => v is Map<String, dynamic> ? v : const <String, dynamic>{};

class BetriebDienst {
  /// Feste Kennung des Servers: api, database, weather, ntfy, caddy (Unbekanntes wird nicht angezeigt).
  final String id;
  final BetriebStufe stufe;
  final Json detail;
  const BetriebDienst({required this.id, required this.stufe, this.detail = const {}});

  factory BetriebDienst.fromJson(Object? raw) {
    final m = asJson(raw);
    return BetriebDienst(id: _text(m['id']) ?? '', stufe: BetriebStufe.lesen(m['state']), detail: _map(m['detail']));
  }
}

class BetriebMigrationen {
  final int? angewendet;
  final int? erwartet;
  final String? letzte;
  final bool? ausstehend;

  /// Die Laufzeitrolle darf die Migrationstabelle nicht lesen (Grant fehlt, siehe deploy/README).
  final bool grantFehlt;
  const BetriebMigrationen({this.angewendet, this.erwartet, this.letzte, this.ausstehend, this.grantFehlt = false});
}

class BetriebSicherung {
  final BetriebStufe stufe;
  final DateTime? letzterErfolg;
  final int? alterStunden;
  final int? bytes;

  /// Ergebnis des letzten Laufs laut Statusdatei (feste Codes ok/fehler; alles andere null).
  final String? ergebnis;
  const BetriebSicherung({this.stufe = BetriebStufe.unbekannt, this.letzterErfolg, this.alterStunden, this.bytes, this.ergebnis});
}

String? _ergebnis(Object? v) => v == 'ok' || v == 'fehler' ? v as String : null;

/// Letzte Abholung der Sicherung durch das NAS (Rückmeldung des NAS, Betrieb Paket 3). Die Angaben stammen vom NAS und sind ein Hinweis, kein Beweis.
class BetriebNasAbholung {
  final BetriebStufe stufe;
  final String? ergebnis;
  final DateTime? letzterLauf;
  final DateTime? letzterErfolg;
  final int? alterStunden;
  final DateTime? neuesteSicherung;
  final int? anzahl;
  const BetriebNasAbholung({this.stufe = BetriebStufe.unbekannt, this.ergebnis, this.letzterLauf, this.letzterErfolg, this.alterStunden, this.neuesteSicherung, this.anzahl});

  factory BetriebNasAbholung.fromJson(Object? raw) {
    final m = _map(raw);
    return BetriebNasAbholung(
      stufe: BetriebStufe.lesen(m['state']),
      ergebnis: _ergebnis(m['result']),
      letzterLauf: _zeit(m['lastRunAt']),
      letzterErfolg: _zeit(m['lastSuccessAt']),
      alterStunden: _zahl(m['ageHours']),
      neuesteSicherung: _zeit(m['newestBackupAt']),
      anzahl: _zahl(m['count']),
    );
  }
}

/// Letzter automatischer Wiederherstellungstest auf dem NAS.
class BetriebNasTest {
  final BetriebStufe stufe;
  final String? ergebnis;
  final DateTime? letzterLauf;
  final DateTime? letzterErfolg;
  final int? alterTage;

  /// Wurde auch das Konfigurationsarchiv geprüft? (null: nicht gemeldet)
  final bool? konfigGeprueft;
  const BetriebNasTest({this.stufe = BetriebStufe.unbekannt, this.ergebnis, this.letzterLauf, this.letzterErfolg, this.alterTage, this.konfigGeprueft});

  factory BetriebNasTest.fromJson(Object? raw) {
    final m = _map(raw);
    return BetriebNasTest(
      stufe: BetriebStufe.lesen(m['state']),
      ergebnis: _ergebnis(m['result']),
      letzterLauf: _zeit(m['lastRunAt']),
      letzterErfolg: _zeit(m['lastSuccessAt']),
      alterTage: _zahl(m['ageDays']),
      konfigGeprueft: m['configChecked'] is bool ? m['configChecked'] as bool : null,
    );
  }
}

/// Rückmeldung des NAS im Feld `nas` von `GET /admin/status`. [bekannt] = false: ein älterer Server kennt sie nicht; [eingerichtet] = false: das NAS hat noch nichts gemeldet
/// (oder die Datei war ungültig, dann [ungueltig]); beides ist nie ein Alarm.
class BetriebNas {
  final bool bekannt;
  final bool eingerichtet;
  final bool ungueltig;
  final DateTime? empfangen;
  final BetriebNasAbholung abholung;
  final BetriebNasTest test;
  const BetriebNas({this.bekannt = false, this.eingerichtet = false, this.ungueltig = false, this.empfangen, this.abholung = const BetriebNasAbholung(), this.test = const BetriebNasTest()});

  factory BetriebNas.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return const BetriebNas();
    return BetriebNas(
      bekannt: true,
      eingerichtet: raw['configured'] == true,
      ungueltig: raw['invalid'] == true,
      empfangen: _zeit(raw['receivedAt']),
      abholung: BetriebNasAbholung.fromJson(raw['pull']),
      test: BetriebNasTest.fromJson(raw['restore']),
    );
  }
}

class BetriebPlatte {
  final int gesamt;
  final int frei;
  final int belegtProzent;
  const BetriebPlatte({required this.gesamt, required this.frei, required this.belegtProzent});
}

class BetriebAppVersion {
  final String version;
  final int? versionCode;
  final String? mindestversion;
  const BetriebAppVersion({required this.version, this.versionCode, this.mindestversion});
}

/// Push-Wecker (`push` in `GET /admin/status`): nur Zähler und eine Zeit, nie Endpunkte oder Themen.
class BetriebPush {
  /// Geräte mit einem aktiven Wecker.
  final int aktiv;

  /// Geräte, deren Endpunkt der Server deaktiviert hat.
  final int deaktiviert;

  /// Aktive Geräte mit mindestens einem Zustellfehler in Folge.
  final int fehlerhaft;

  /// Geräte mit einem Zustellfehler in den letzten 24 Stunden.
  final int fehler24h;
  final DateTime? letzterErfolg;
  const BetriebPush({this.aktiv = 0, this.deaktiviert = 0, this.fehlerhaft = 0, this.fehler24h = 0, this.letzterErfolg});

  factory BetriebPush.fromJson(Object? raw) {
    final m = _map(raw);
    return BetriebPush(
      aktiv: _zahl(m['devicesActive']) ?? 0,
      deaktiviert: _zahl(m['devicesDisabled']) ?? 0,
      fehlerhaft: _zahl(m['devicesFailing']) ?? 0,
      fehler24h: _zahl(m['errors24h']) ?? 0,
      letzterErfolg: _zeit(m['lastOkAt']),
    );
  }
}

/// Ein täglicher Messpunkt der Betreiber-Ansicht (`GET /admin/metrics`): nur Zahlen, [tag] ist der UTC-Tag.
class VerlaufTag {
  final DateTime tag;
  final int personen7;
  final int personen30;
  final int geraete7;
  final int geraete30;
  final int abgleiche;
  final int fehler;
  final int rateLimit;
  final int? datenbankBytes;
  final int? dateienBytes;
  const VerlaufTag({
    required this.tag,
    this.personen7 = 0,
    this.personen30 = 0,
    this.geraete7 = 0,
    this.geraete30 = 0,
    this.abgleiche = 0,
    this.fehler = 0,
    this.rateLimit = 0,
    this.datenbankBytes,
    this.dateienBytes,
  });

  /// Liest einen Tag; ohne gültiges Datum gibt es null (der Eintrag entfällt).
  static VerlaufTag? versuchen(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final text = _text(raw['day']);
    final tag = text == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ? null : DateTime.tryParse('${text}T00:00:00Z');
    if (tag == null) return null;
    int n(String k) => (_zahl(raw[k]) ?? 0).clamp(0, 1 << 52);
    return VerlaufTag(
      tag: tag,
      personen7: n('activePersons7'),
      personen30: n('activePersons30'),
      geraete7: n('activeDevices7'),
      geraete30: n('activeDevices30'),
      abgleiche: n('syncRuns'),
      fehler: n('syncErrors'),
      rateLimit: n('rateLimited'),
      datenbankBytes: _zahl(raw['dbBytes']),
      dateienBytes: _zahl(raw['filesBytes']),
    );
  }
}

/// `GET /admin/metrics`: der Verlauf (aufsteigend nach Tag; Lücken bleiben Lücken).
class BetriebVerlauf {
  final DateTime erzeugt;
  final int aufbewahrungTage;
  final List<VerlaufTag> tage;
  const BetriebVerlauf({required this.erzeugt, required this.aufbewahrungTage, required this.tage});

  factory BetriebVerlauf.fromJson(Object? raw) {
    final m = asJson(raw);
    final tage = [if (m['days'] is List) for (final e in m['days'] as List) ?VerlaufTag.versuchen(e)]..sort((a, b) => a.tag.compareTo(b.tag));
    return BetriebVerlauf(erzeugt: _zeit(m['generatedAt']) ?? DateTime.now(), aufbewahrungTage: _zahl(m['retentionDays']) ?? 400, tage: tage);
  }

  VerlaufTag? get letzter => tage.isEmpty ? null : tage.last;
}

/// Stand der App-Version eines Geräts (feste Codes des Servers; alles andere gilt als [unbekannt], nie als aktuell).
enum AppStand {
  aktuell,
  aelter,
  unterMindestversion,
  inaktiv,
  unbekannt;

  /// null: das Gerät hat keine Release-Verfolgung (Web, andere Plattformen) oder ein älterer Server kennt das Feld nicht.
  static AppStand? lesen(Object? v) => switch (v) {
    null => null,
    'current' => aktuell,
    'outdated' => aelter,
    'below_min' => unterMindestversion,
    'inactive' => inaktiv,
    _ => unbekannt,
  };

  /// Ist das Gerät hinter der neuesten Version zurück (älter oder unter der Mindestversion)?
  bool get zurueck => this == aelter || this == unterMindestversion;
}

/// Update-Stand der Android-Geräte in `GET /admin/status` (`updates`): nur Zähler, keine Namen. Die Einzelheiten je Person stehen in der Mitgliederseite.
class BetriebUpdates {
  /// Neueste veröffentlichte Android-Version laut Release-Manifest (null: nicht lesbar).
  final String? neueste;
  final String mindestversion;
  final int gesamt;
  final int aktuell;
  final int aelter;
  final int unterMindestversion;
  final int inaktiv;
  final int unbekannt;

  /// Geräte ohne Release-Verfolgung (Web und andere).
  final int andere;

  /// Personen mit mindestens einem zurückgebliebenen Gerät.
  final int personenZurueck;
  const BetriebUpdates({
    this.neueste,
    this.mindestversion = '–',
    this.gesamt = 0,
    this.aktuell = 0,
    this.aelter = 0,
    this.unterMindestversion = 0,
    this.inaktiv = 0,
    this.unbekannt = 0,
    this.andere = 0,
    this.personenZurueck = 0,
  });

  factory BetriebUpdates.fromJson(Object? raw) {
    final m = _map(raw);
    final a = _map(m['android']);
    return BetriebUpdates(
      neueste: _text(m['reference']),
      mindestversion: _text(m['minAppVersion']) ?? '–',
      gesamt: _zahl(a['total']) ?? 0,
      aktuell: _zahl(a['current']) ?? 0,
      aelter: _zahl(a['outdated']) ?? 0,
      unterMindestversion: _zahl(a['belowMin']) ?? 0,
      inaktiv: _zahl(a['inactive']) ?? 0,
      unbekannt: _zahl(a['unknown']) ?? 0,
      andere: _zahl(m['otherDevices']) ?? 0,
      personenZurueck: _zahl(m['personsBehind']) ?? 0,
    );
  }

  int get zurueck => aelter + unterMindestversion;
}

/// `GET /admin/status`
class BetriebStatus {
  final DateTime erzeugt;
  final BetriebStufe gesamt;

  /// Quellen ohne Messwert: "in Ordnung" gilt dann nur für das Gemessene.
  final int unbekannt;
  final String serverVersion;
  final int protokoll;
  final int laufzeitSekunden;
  final int speicherMb;
  final bool datenbankOk;
  final int? datenbankMs;
  final int? datenbankBytes;
  final BetriebMigrationen migrationen;
  final List<BetriebDienst> dienste;
  final BetriebSicherung sicherung;
  final BetriebNas nas;

  /// Push-Wecker: Geräte und Zustellfehler als Zähler; null bei einem älteren Server.
  final BetriebPush? push;

  /// Update-Stand der Android-Geräte; null bei einem älteren Server.
  final BetriebUpdates? updates;
  final BetriebPlatte? platte;
  final DateTime? zertifikatBis;
  final int? zertifikatTage;
  final int mitglieder;
  final int geraete;
  final int pushGeraete;
  final int sitzungen;
  final String? webVersion;
  final BetriebAppVersion? appVersion;
  final String mindestversionApp;
  final bool schalterPwSicherung;
  final bool schalterKlartextLogin;
  final bool schalterWetter;
  final bool schalterPush;
  final bool karteDa;
  final int? karteBytes;

  const BetriebStatus({
    required this.erzeugt,
    required this.gesamt,
    required this.unbekannt,
    required this.serverVersion,
    required this.protokoll,
    required this.laufzeitSekunden,
    required this.speicherMb,
    required this.datenbankOk,
    required this.datenbankMs,
    required this.datenbankBytes,
    required this.migrationen,
    required this.dienste,
    required this.sicherung,
    required this.nas,
    required this.push,
    required this.updates,
    required this.platte,
    required this.zertifikatBis,
    required this.zertifikatTage,
    required this.mitglieder,
    required this.geraete,
    required this.pushGeraete,
    required this.sitzungen,
    required this.webVersion,
    required this.appVersion,
    required this.mindestversionApp,
    required this.schalterPwSicherung,
    required this.schalterKlartextLogin,
    required this.schalterWetter,
    required this.schalterPush,
    required this.karteDa,
    required this.karteBytes,
  });

  BetriebDienst? dienst(String id) {
    for (final d in dienste) {
      if (d.id == id) return d;
    }
    return null;
  }

  factory BetriebStatus.fromJson(Object? raw) {
    final m = asJson(raw);
    final server = _map(m['server']);
    final db = _map(m['database']);
    final mig = _map(db['migrations']);
    final backup = _map(m['backup']);
    final disk = m['disk'] is Map<String, dynamic> ? _map(m['disk']) : null;
    final cert = m['certificate'] is Map<String, dynamic> ? _map(m['certificate']) : null;
    final counts = _map(m['counts']);
    final versions = _map(m['versions']);
    final app = versions['app'] is Map<String, dynamic> ? _map(versions['app']) : null;
    final features = _map(m['features']);
    final map = _map(features['map']);
    final dienste = <BetriebDienst>[];
    final liste = m['services'];
    if (liste is List) {
      for (final e in liste) {
        try {
          dienste.add(BetriebDienst.fromJson(e));
        } on Object {
          // unbekannter Eintrag: überspringen
        }
      }
    }
    final gesamt = BetriebStufe.lesen(m['overall']);
    return BetriebStatus(
      erzeugt: _zeit(m['generatedAt']) ?? DateTime.now(),
      gesamt: gesamt == BetriebStufe.aus ? BetriebStufe.unbekannt : gesamt,
      unbekannt: _zahl(m['unknownCount']) ?? 0,
      serverVersion: _text(server['version']) ?? '–',
      protokoll: _zahl(server['protocolVersion']) ?? 0,
      laufzeitSekunden: _zahl(server['uptimeSec']) ?? 0,
      speicherMb: _zahl(server['memoryRssMb']) ?? 0,
      datenbankOk: db['ok'] == true,
      datenbankMs: _zahl(db['latencyMs']),
      datenbankBytes: _zahl(db['sizeBytes']),
      migrationen: BetriebMigrationen(
        angewendet: _zahl(mig['applied']),
        erwartet: _zahl(mig['expected']),
        letzte: _text(mig['latest']),
        ausstehend: mig['pending'] is bool ? mig['pending'] as bool : null,
        grantFehlt: mig['grantMissing'] == true,
      ),
      dienste: dienste,
      sicherung: BetriebSicherung(
        stufe: BetriebStufe.lesen(backup['state']),
        letzterErfolg: _zeit(backup['lastSuccessAt']),
        alterStunden: _zahl(backup['ageHours']),
        bytes: _zahl(backup['totalBytes']),
        ergebnis: _ergebnis(backup['lastResult']),
      ),
      nas: BetriebNas.fromJson(m['nas']),
      push: m['push'] is Map<String, dynamic> ? BetriebPush.fromJson(m['push']) : null,
      updates: m['updates'] is Map<String, dynamic> ? BetriebUpdates.fromJson(m['updates']) : null,
      platte: disk == null
          ? null
          : BetriebPlatte(gesamt: _zahl(disk['totalBytes']) ?? 0, frei: _zahl(disk['freeBytes']) ?? 0, belegtProzent: _zahl(disk['usedPercent']) ?? 0),
      zertifikatBis: cert == null ? null : _zeit(cert['validTo']),
      zertifikatTage: cert == null ? null : _zahl(cert['daysLeft']),
      mitglieder: _zahl(counts['members']) ?? 0,
      geraete: _zahl(counts['devices']) ?? 0,
      pushGeraete: _zahl(counts['pushDevices']) ?? 0,
      sitzungen: _zahl(counts['activeSessions']) ?? 0,
      webVersion: _text(versions['web']),
      appVersion: app == null || _text(app['version']) == null
          ? null
          : BetriebAppVersion(version: _text(app['version'])!, versionCode: _zahl(app['versionCode']), mindestversion: _text(app['minVersion'])),
      mindestversionApp: _text(versions['minAppVersion']) ?? '–',
      schalterPwSicherung: features['pwBackup'] == true,
      schalterKlartextLogin: features['legacyPasswordLogin'] == true,
      schalterWetter: features['weather'] == true,
      schalterPush: features['push'] == true,
      karteDa: map['available'] == true,
      karteBytes: _zahl(map['sizeBytes']),
    );
  }
}

/// Kategorie des Protokolls (Filter der Seite und Wert des Servers).
enum ProtokollArt {
  alle('alle', 'Alle'),
  anmeldung('anmeldung', 'Anmeldung'),
  aenderungen('aenderungen', 'Änderungen'),
  fehler('fehler', 'Fehler');

  final String code;
  final String label;
  const ProtokollArt(this.code, this.label);

  static ProtokollArt? lesen(Object? v) {
    for (final a in values) {
      if (a.code == v && a != alle) return a;
    }
    return null;
  }
}

/// Ein Eintrag des Audit-Protokolls: nur Art, Zeit, Person und gekürzte Netzadresse.
class ProtokollEintrag {
  final String id;
  final DateTime zeit;
  final String ereignis;
  final ProtokollArt art;
  final String? person;
  final String? netz;
  const ProtokollEintrag({required this.id, required this.zeit, required this.ereignis, required this.art, this.person, this.netz});

  factory ProtokollEintrag.fromJson(Object? raw) {
    final m = asJson(raw);
    final id = _text(m['id']);
    final at = _zeit(m['at']);
    final event = _text(m['event']);
    if (id == null || at == null || event == null) throw ApiException.unerwarteteAntwort;
    final actor = m['actor'] is Map<String, dynamic> ? _map(m['actor']) : null;
    return ProtokollEintrag(
      id: id,
      zeit: at,
      ereignis: event,
      art: ProtokollArt.lesen(m['category']) ?? ProtokollArt.aenderungen,
      person: actor == null ? null : _text(actor['displayName']),
      netz: _text(m['network']),
    );
  }
}

class ProtokollSeite {
  final List<ProtokollEintrag> eintraege;
  final String? weiter;
  const ProtokollSeite({required this.eintraege, required this.weiter});

  factory ProtokollSeite.fromJson(Object? raw) {
    final m = asJson(raw);
    return ProtokollSeite(eintraege: parseListe(m['items'], ProtokollEintrag.fromJson), weiter: _text(m['nextCursor']));
  }
}

// ------------------------------------------------------------------ Paket 2a: Schlüssel-Ampel, Mitglieder und Geräte, Warnungen

/// Ampel einer Person oder der Familie (feste Werte des Servers; alles andere gilt als [unbekannt], nie als grün).
enum BetriebAmpel {
  gruen,
  gelb,
  rot,
  unbekannt;

  static BetriebAmpel lesen(Object? v) => switch (v) {
    'green' => gruen,
    'yellow' => gelb,
    'red' => rot,
    _ => unbekannt,
  };
}

/// Stand des Schlüssels auf einem Gerät, wie das Gerät ihn gemeldet hat (feste Codes des Servers).
enum GeraeteSchluesselStand {
  aktuell,
  veraltet,
  alterSchluessel,
  keiner,
  unbekannt;

  static GeraeteSchluesselStand lesen(Object? v) => switch (v) {
    'current' => aktuell,
    'stale' => veraltet,
    'old' => alterSchluessel,
    'none' => keiner,
    _ => unbekannt,
  };
}

/// Die unabhängigen Wege zum Personenschlüssel (je ein Haken).
class SchluesselWege {
  final bool geraet;
  final bool passwortSicherung;
  final bool wiederherstellung;
  const SchluesselWege({this.geraet = false, this.passwortSicherung = false, this.wiederherstellung = false});

  factory SchluesselWege.fromJson(Object? raw) {
    final m = _map(raw);
    return SchluesselWege(geraet: m['device'] == true, passwortSicherung: m['pwBackup'] == true, wiederherstellung: m['recoveryBackup'] == true);
  }

  int get anzahl => [geraet, passwortSicherung, wiederherstellung].where((w) => w).length;
}

/// Ein Schlüsselereignis (nur Art und Zeit).
class SchluesselEreignis {
  final String art;
  final DateTime zeit;
  const SchluesselEreignis({required this.art, required this.zeit});

  static SchluesselEreignis? versuchen(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final art = _text(raw['kind']);
    final zeit = _zeit(raw['at']);
    return art == null || zeit == null ? null : SchluesselEreignis(art: art, zeit: zeit);
  }
}

class SchluesselPerson {
  final String id;
  final String name;
  final BetriebAmpel ampel;
  final bool hatSchluessel;
  final int? version;
  final SchluesselWege wege;
  final int geraeteGesamt;
  final int geraeteMitSchluessel;
  final bool altesPasswortVerfahren;
  final int archiv;
  final List<SchluesselEreignis> ereignisse;
  const SchluesselPerson({
    required this.id,
    required this.name,
    required this.ampel,
    required this.hatSchluessel,
    required this.version,
    required this.wege,
    required this.geraeteGesamt,
    required this.geraeteMitSchluessel,
    required this.altesPasswortVerfahren,
    required this.archiv,
    required this.ereignisse,
  });

  /// Liest eine Person; fehlt Kennung oder Name, gibt es null (die Zeile entfällt).
  static SchluesselPerson? versuchen(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = _text(raw['userId']);
    final name = _text(raw['displayName']);
    if (id == null || name == null) return null;
    return SchluesselPerson(
      id: id,
      name: name,
      ampel: BetriebAmpel.lesen(raw['ampel']),
      hatSchluessel: raw['hasKeys'] == true,
      version: _zahl(raw['keyVersion']),
      wege: SchluesselWege.fromJson(raw['ways']),
      geraeteGesamt: _zahl(raw['devicesTotal']) ?? 0,
      geraeteMitSchluessel: _zahl(raw['devicesWithKey']) ?? 0,
      altesPasswortVerfahren: raw['legacyPassword'] == true,
      archiv: _zahl(raw['archiveCount']) ?? 0,
      ereignisse: [if (raw['events'] is List) for (final e in raw['events'] as List) ?SchluesselEreignis.versuchen(e)],
    );
  }
}

/// `GET /admin/key-status?summary=1`: Familienampel (nur Zähler, ohne Namen und Ereignisse, ohne Step-up). Die Einzelheiten je Person liefert `/admin/members` (mit Step-up).
class SchluesselStatus {
  final BetriebAmpel gesamt;

  /// "Stichtag-bereit": alle Mitglieder grün.
  final bool bereit;
  final int gruen;
  final int gelb;
  final int rot;

  /// Nur gefüllt, wenn der Server Einzelheiten liefert (die Übersicht fragt nur die Zusammenfassung ab).
  final List<SchluesselPerson> personen;
  const SchluesselStatus({required this.gesamt, required this.bereit, required this.gruen, required this.gelb, required this.rot, this.personen = const []});

  factory SchluesselStatus.fromJson(Object? raw) {
    final m = asJson(raw);
    final counts = _map(m['counts']);
    final personen = [if (m['persons'] is List) for (final p in m['persons'] as List) ?SchluesselPerson.versuchen(p)];
    return SchluesselStatus(
      gesamt: BetriebAmpel.lesen(m['overall']),
      // Fehlt eine Angabe oder ist jemand nicht grün, gilt die Familie nie als bereit (die App glaubt `ready` nur zusammen mit den Zählern)
      bereit: m['ready'] == true && (_zahl(counts['green']) ?? 0) > 0 && (_zahl(counts['yellow']) ?? 1) == 0 && (_zahl(counts['red']) ?? 1) == 0 && personen.every((p) => p.ampel == BetriebAmpel.gruen),
      gruen: _zahl(counts['green']) ?? personen.where((p) => p.ampel == BetriebAmpel.gruen).length,
      gelb: _zahl(counts['yellow']) ?? personen.where((p) => p.ampel == BetriebAmpel.gelb).length,
      rot: _zahl(counts['red']) ?? personen.where((p) => p.ampel == BetriebAmpel.rot).length,
      personen: personen,
    );
  }

  int get anzahl => gruen + gelb + rot;
}

class BetriebGeraet {
  final String id;
  final String name;
  final String plattform;
  final String? appVersion;
  final DateTime? zuletztGesehen;
  final GeraeteSchluesselStand schluessel;
  final int? schluesselVersion;

  /// Stand der App-Version (null: keine Release-Verfolgung oder älterer Server).
  final AppStand? appStand;
  const BetriebGeraet({
    required this.id,
    required this.name,
    required this.plattform,
    required this.appVersion,
    required this.zuletztGesehen,
    required this.schluessel,
    required this.schluesselVersion,
    this.appStand,
  });

  static BetriebGeraet? versuchen(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = _text(raw['id']);
    if (id == null) return null;
    return BetriebGeraet(
      id: id,
      name: _text(raw['name']) ?? 'Gerät',
      plattform: _text(raw['platform']) ?? '',
      appVersion: _text(raw['appVersion']),
      zuletztGesehen: _zeit(raw['lastSeenAt']),
      schluessel: GeraeteSchluesselStand.lesen(raw['keyState']),
      schluesselVersion: _zahl(raw['keyVersion']),
      appStand: AppStand.lesen(raw['appState']),
    );
  }
}

class BetriebMitglied {
  final String id;
  final String name;
  final Role rolle;
  final FamilyRole? familienrolle;
  final bool betreiber;
  final bool ich;
  final DateTime? letzteAnmeldung;
  final int passkeys;
  final bool passwort;
  final bool totp;

  /// Restdauer der Anmeldesperre des Kontos in Sekunden (null: nicht gesperrt).
  final int? gesperrtSekunden;
  final SchluesselPerson schluessel;
  final List<BetriebGeraet> geraete;

  /// Android-Geräte dieser Person, die älter als die neueste Version oder unter der Mindestversion sind (0 bei einem älteren Server).
  final int geraeteZurueck;
  const BetriebMitglied({
    required this.id,
    required this.name,
    required this.rolle,
    required this.familienrolle,
    required this.betreiber,
    required this.ich,
    required this.letzteAnmeldung,
    required this.passkeys,
    required this.passwort,
    required this.totp,
    required this.gesperrtSekunden,
    required this.schluessel,
    required this.geraete,
    this.geraeteZurueck = 0,
  });

  static BetriebMitglied? versuchen(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final person = SchluesselPerson.versuchen(raw);
    if (person == null) return null;
    final rolleText = _text(raw['role']);
    // eine unbekannte Rolle wird wie überall in der App als Kind behandelt (die geringsten Rechte), nie als Fehler
    final rolle = Role.values.firstWhere((r) => r.wire == rolleText, orElse: () => Role.child);
    final creds = _map(raw['credentials']);
    final gesperrt = raw['locked'] is Map<String, dynamic> ? _zahl(_map(raw['locked'])['seconds']) : null;
    return BetriebMitglied(
      id: person.id,
      name: person.name,
      rolle: rolle,
      familienrolle: FamilyRole.tolerant(raw['familyRole']),
      betreiber: raw['operator'] == true,
      ich: raw['you'] == true,
      letzteAnmeldung: _zeit(raw['lastLoginAt']),
      passkeys: _zahl(creds['passkeys']) ?? 0,
      passwort: creds['password'] == true,
      totp: creds['totp'] == true,
      gesperrtSekunden: gesperrt != null && gesperrt > 0 ? gesperrt : null,
      schluessel: person,
      geraete: [if (raw['devices'] is List) for (final g in raw['devices'] as List) ?BetriebGeraet.versuchen(g)],
      geraeteZurueck: _zahl(raw['devicesBehind']) ?? 0,
    );
  }
}

/// `GET /admin/members`
class BetriebMitglieder {
  final List<BetriebMitglied> mitglieder;
  const BetriebMitglieder(this.mitglieder);

  factory BetriebMitglieder.fromJson(Object? raw) {
    final m = asJson(raw);
    return BetriebMitglieder([if (m['members'] is List) for (final e in m['members'] as List) ?BetriebMitglied.versuchen(e)]);
  }
}

/// Feste Arten der Betreiber-Warnungen (Kennungen des Servers; Unbekanntes zeigt die Oberfläche allgemein als "Hinweis").
const kWarnArten = <String>['cert', 'backup', 'database', 'ntfy', 'disk', 'logins', 'key', 'nas_pull', 'nas_restore'];

/// `GET /admin/warnings`
class BetriebWarnungen {
  /// Hat dieser Betreiber die Warnungen eingeschaltet?
  final bool an;

  /// Kann der Server überhaupt warnen (Push eingerichtet)?
  final bool pushDa;
  final DateTime? gepruefteAm;

  /// Zeitpunkt des letzten Weckers (die App zeigt daraufhin einmal den festen Hinweis).
  final DateTime? zuletztGewarnt;

  /// Aktive Warnungen je Art (seit wann, wie viele: bei der Schlüssel-Ampel die Zahl der Personen). Ein älterer Server liefert keine Anzahl (dann 1).
  final List<({String art, DateTime? seit, int anzahl})> aktiv;
  const BetriebWarnungen({required this.an, required this.pushDa, required this.gepruefteAm, required this.zuletztGewarnt, required this.aktiv});

  factory BetriebWarnungen.fromJson(Object? raw) {
    final m = asJson(raw);
    final aktiv = <({String art, DateTime? seit, int anzahl})>[];
    if (m['active'] is List) {
      for (final e in m['active'] as List) {
        if (e is! Map<String, dynamic>) continue;
        final art = _text(e['kind']);
        final n = _zahl(e['count']);
        if (art != null) aktiv.add((art: art, seit: _zeit(e['since']), anzahl: n != null && n > 0 ? n : 1));
      }
    }
    return BetriebWarnungen(
      // fehlt die Angabe, gilt "an" (der Standard des Servers)
      an: m['enabled'] != false,
      pushDa: m['pushAvailable'] == true,
      gepruefteAm: _zeit(m['checkedAt']),
      zuletztGewarnt: _zeit(m['lastNotifiedAt']),
      aktiv: aktiv,
    );
  }
}
