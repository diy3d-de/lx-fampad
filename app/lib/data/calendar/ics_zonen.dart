// Zeitzonen-Namen aus ICS-Dateien auf IANA-Kennungen abbilden. Outlook und Exchange schreiben Windows-Namen ("W. Europe Standard Time"),
// ältere Programme Pfade wie "/softwarestudio.org/Olson_20011030_5/Europe/Berlin". Die Windows-Namen stammen aus der CLDR-Tabelle
// windowsZones.xml (Hauptgebiet 001 je Name); sie sind hier fest eingebettet, es wird nichts nachgeladen.
import 'package:timezone/timezone.dart' as tz;

/// Windows-Zeitzonenname (klein geschrieben) -> IANA-Kennung.
const Map<String, String> kWindowsZonen = {
  'dateline standard time': 'Etc/GMT+12',
  'utc-11': 'Etc/GMT+11',
  'aleutian standard time': 'America/Adak',
  'hawaiian standard time': 'Pacific/Honolulu',
  'marquesas standard time': 'Pacific/Marquesas',
  'alaskan standard time': 'America/Anchorage',
  'utc-09': 'Etc/GMT+9',
  'pacific standard time (mexico)': 'America/Tijuana',
  'utc-08': 'Etc/GMT+8',
  'pacific standard time': 'America/Los_Angeles',
  'us mountain standard time': 'America/Phoenix',
  'mountain standard time (mexico)': 'America/Mazatlan',
  'mountain standard time': 'America/Denver',
  'yukon standard time': 'America/Whitehorse',
  'central america standard time': 'America/Guatemala',
  'central standard time': 'America/Chicago',
  'easter island standard time': 'Pacific/Easter',
  'central standard time (mexico)': 'America/Mexico_City',
  'canada central standard time': 'America/Regina',
  'sa pacific standard time': 'America/Bogota',
  'eastern standard time (mexico)': 'America/Cancun',
  'eastern standard time': 'America/New_York',
  'haiti standard time': 'America/Port-au-Prince',
  'cuba standard time': 'America/Havana',
  'us eastern standard time': 'America/Indianapolis',
  'turks and caicos standard time': 'America/Grand_Turk',
  'paraguay standard time': 'America/Asuncion',
  'atlantic standard time': 'America/Halifax',
  'venezuela standard time': 'America/Caracas',
  'central brazilian standard time': 'America/Cuiaba',
  'sa western standard time': 'America/La_Paz',
  'pacific sa standard time': 'America/Santiago',
  'newfoundland standard time': 'America/St_Johns',
  'tocantins standard time': 'America/Araguaina',
  'e. south america standard time': 'America/Sao_Paulo',
  'sa eastern standard time': 'America/Cayenne',
  'argentina standard time': 'America/Buenos_Aires',
  'greenland standard time': 'America/Godthab',
  'montevideo standard time': 'America/Montevideo',
  'magallanes standard time': 'America/Punta_Arenas',
  'saint pierre standard time': 'America/Miquelon',
  'bahia standard time': 'America/Bahia',
  'utc-02': 'Etc/GMT+2',
  'azores standard time': 'Atlantic/Azores',
  'cape verde standard time': 'Atlantic/Cape_Verde',
  'utc': 'Etc/UTC',
  'gmt standard time': 'Europe/London',
  'greenwich standard time': 'Atlantic/Reykjavik',
  'sao tome standard time': 'Africa/Sao_Tome',
  'morocco standard time': 'Africa/Casablanca',
  'w. europe standard time': 'Europe/Berlin',
  'central europe standard time': 'Europe/Budapest',
  'romance standard time': 'Europe/Paris',
  'central european standard time': 'Europe/Warsaw',
  'w. central africa standard time': 'Africa/Lagos',
  'jordan standard time': 'Asia/Amman',
  'gtb standard time': 'Europe/Bucharest',
  'middle east standard time': 'Asia/Beirut',
  'egypt standard time': 'Africa/Cairo',
  'e. europe standard time': 'Europe/Chisinau',
  'syria standard time': 'Asia/Damascus',
  'west bank standard time': 'Asia/Hebron',
  'south africa standard time': 'Africa/Johannesburg',
  'fle standard time': 'Europe/Kiev',
  'israel standard time': 'Asia/Jerusalem',
  'south sudan standard time': 'Africa/Juba',
  'kaliningrad standard time': 'Europe/Kaliningrad',
  'sudan standard time': 'Africa/Khartoum',
  'libya standard time': 'Africa/Tripoli',
  'namibia standard time': 'Africa/Windhoek',
  'arabic standard time': 'Asia/Baghdad',
  'turkey standard time': 'Europe/Istanbul',
  'arab standard time': 'Asia/Riyadh',
  'belarus standard time': 'Europe/Minsk',
  'russian standard time': 'Europe/Moscow',
  'e. africa standard time': 'Africa/Nairobi',
  'iran standard time': 'Asia/Tehran',
  'arabian standard time': 'Asia/Dubai',
  'astrakhan standard time': 'Europe/Astrakhan',
  'azerbaijan standard time': 'Asia/Baku',
  'russia time zone 3': 'Europe/Samara',
  'mauritius standard time': 'Indian/Mauritius',
  'saratov standard time': 'Europe/Saratov',
  'georgian standard time': 'Asia/Tbilisi',
  'volgograd standard time': 'Europe/Volgograd',
  'caucasus standard time': 'Asia/Yerevan',
  'afghanistan standard time': 'Asia/Kabul',
  'west asia standard time': 'Asia/Tashkent',
  'ekaterinburg standard time': 'Asia/Yekaterinburg',
  'pakistan standard time': 'Asia/Karachi',
  'qyzylorda standard time': 'Asia/Qyzylorda',
  'india standard time': 'Asia/Calcutta',
  'sri lanka standard time': 'Asia/Colombo',
  'nepal standard time': 'Asia/Katmandu',
  'central asia standard time': 'Asia/Almaty',
  'bangladesh standard time': 'Asia/Dhaka',
  'omsk standard time': 'Asia/Omsk',
  'myanmar standard time': 'Asia/Rangoon',
  'se asia standard time': 'Asia/Bangkok',
  'altai standard time': 'Asia/Barnaul',
  'w. mongolia standard time': 'Asia/Hovd',
  'north asia standard time': 'Asia/Krasnoyarsk',
  'n. central asia standard time': 'Asia/Novosibirsk',
  'tomsk standard time': 'Asia/Tomsk',
  'china standard time': 'Asia/Shanghai',
  'north asia east standard time': 'Asia/Irkutsk',
  'singapore standard time': 'Asia/Singapore',
  'w. australia standard time': 'Australia/Perth',
  'taipei standard time': 'Asia/Taipei',
  'ulaanbaatar standard time': 'Asia/Ulaanbaatar',
  'aus central w. standard time': 'Australia/Eucla',
  'transbaikal standard time': 'Asia/Chita',
  'tokyo standard time': 'Asia/Tokyo',
  'north korea standard time': 'Asia/Pyongyang',
  'korea standard time': 'Asia/Seoul',
  'yakutsk standard time': 'Asia/Yakutsk',
  'cen. australia standard time': 'Australia/Adelaide',
  'aus central standard time': 'Australia/Darwin',
  'e. australia standard time': 'Australia/Brisbane',
  'aus eastern standard time': 'Australia/Sydney',
  'west pacific standard time': 'Pacific/Port_Moresby',
  'tasmania standard time': 'Australia/Hobart',
  'vladivostok standard time': 'Asia/Vladivostok',
  'lord howe standard time': 'Australia/Lord_Howe',
  'bougainville standard time': 'Pacific/Bougainville',
  'russia time zone 10': 'Asia/Srednekolymsk',
  'magadan standard time': 'Asia/Magadan',
  'norfolk standard time': 'Pacific/Norfolk',
  'sakhalin standard time': 'Asia/Sakhalin',
  'central pacific standard time': 'Pacific/Guadalcanal',
  'russia time zone 11': 'Asia/Kamchatka',
  'new zealand standard time': 'Pacific/Auckland',
  'utc+12': 'Etc/GMT-12',
  'fiji standard time': 'Pacific/Fiji',
  'kamchatka standard time': 'Asia/Kamchatka',
  'chatham islands standard time': 'Pacific/Chatham',
  'utc+13': 'Etc/GMT-13',
  'tonga standard time': 'Pacific/Tongatapu',
  'samoa standard time': 'Pacific/Apia',
  'line islands standard time': 'Pacific/Kiritimati',
};

Map<String, String>? _kleinNachName;

/// IANA-Kennung zu einem Zeitzonennamen aus der Datei, oder null, wenn er nicht bekannt ist. Erkennt IANA-Namen (auch in anderer
/// Groß-/Kleinschreibung), Windows-Namen und Pfade mit IANA-Namen am Ende. Setzt voraus, dass die Zeitzonen-Daten geladen sind.
String? iana(String? roh) {
  if (roh == null) return null;
  var s = roh.trim();
  if (s.isEmpty || s.length > 120) return null;
  if (s == 'Z') return 'UTC';
  final klein = s.toLowerCase();
  final win = kWindowsZonen[klein];
  if (win != null) return _bekannt(win);
  final direkt = _bekannt(s);
  if (direkt != null) return direkt;
  // Pfad-Formen: von hinten zwei, dann drei Segmente probieren
  if (s.contains('/')) {
    final teile = s.split('/').where((t) => t.isNotEmpty).toList();
    for (final n in [2, 3, 1]) {
      if (teile.length >= n) {
        final k = _bekannt(teile.sublist(teile.length - n).join('/'));
        if (k != null) return k;
      }
    }
  }
  return null;
}

String? _bekannt(String name) {
  try {
    tz.getLocation(name);
    return name;
  } catch (_) {
    // auch andere Schreibweise probieren
  }
  final karte = _kleinNachName ??= {for (final n in tz.timeZoneDatabase.locations.keys) n.toLowerCase(): n};
  return karte[name.toLowerCase()];
}

/// Nur für Tests: die Zuordnung "klein geschrieben -> Name" neu aufbauen (nach dem Laden anderer Zeitzonen-Daten).
void zonenZwischenspeicherLeeren() => _kleinNachName = null;
