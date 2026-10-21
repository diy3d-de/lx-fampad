// Betreiber-Ansicht "Betrieb" (nur lesend): Modelle zu GET /admin/status und GET /admin/audit. Die Auswertung ist tolerant: unbekannte Felder
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
  const BetriebMigrationen({this.angewendet, this.erwartet, this.letzte, this.ausstehend});
}

class BetriebSicherung {
  final BetriebStufe stufe;
  final DateTime? letzterErfolg;
  final int? alterStunden;
  final int? bytes;
  const BetriebSicherung({this.stufe = BetriebStufe.unbekannt, this.letzterErfolg, this.alterStunden, this.bytes});
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

/// `GET /admin/status`
class BetriebStatus {
  final DateTime erzeugt;
  final BetriebStufe gesamt;
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
      ),
      dienste: dienste,
      sicherung: BetriebSicherung(
        stufe: BetriebStufe.lesen(backup['state']),
        letzterErfolg: _zeit(backup['lastSuccessAt']),
        alterStunden: _zahl(backup['ageHours']),
        bytes: _zahl(backup['totalBytes']),
      ),
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
