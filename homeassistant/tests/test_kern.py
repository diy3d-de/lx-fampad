import base64
import hashlib
import json
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from nacl.public import PrivateKey, SealedBox

UTC = timezone.utc


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def code_aus(obj: dict) -> str:
    roh = json.dumps(obj, separators=(",", ":")).encode()
    return "FH1-" + base64.urlsafe_b64encode(roh).decode().rstrip("=")


def gueltig() -> dict:
    return {
        "v": 1,
        "u": "https://familyhub.lx-labs.dev",
        "t": "fhi_" + "A" * 43,
        "p": b64(bytes(32)),
        "s": b64(bytes(range(32))),
        "n": "Haus Keller",
    }


# ------------------------------------------------------------ Testvektor

def test_vektor_box_oeffnen_und_mac(kern, vektor):
    geheim = PrivateKey(bytes.fromhex(vektor["geheimHex"]))
    klartext = SealedBox(geheim).decrypt(base64.b64decode(vektor["boxBase64"])).decode()
    assert klartext == vektor["klartext"]
    objekt = json.loads(klartext)
    assert objekt["mac"] == vektor["mac"]
    s = bytes.fromhex(vektor["sHex"])
    erwartet = kern.mac_berechnen(s, objekt["kanal"], objekt["d"], objekt["t"], objekt["stand"], objekt["e"])
    assert erwartet == vektor["mac"]
    # Spezifikation unabhängig nachgerechnet
    nachricht = (
        "fampad-ingest-v1\n" + objekt["kanal"] + "\n" + objekt["d"] + "\n" + str(objekt["t"])
        + "\n" + objekt["stand"] + "\n" + objekt["e"]
    ).encode()
    assert hashlib.blake2b(nachricht, key=s, digest_size=32).hexdigest() == vektor["mac"]


def test_vektor_klartext_felder(vektor):
    objekt = json.loads(vektor["klartext"])
    assert set(objekt) == {"v", "kanal", "d", "t", "stand", "e", "mac"}
    assert objekt["v"] == 1 and isinstance(objekt["t"], int)
    assert len(objekt["mac"]) == 64 and objekt["mac"] == objekt["mac"].lower()
    assert " " not in vektor["klartext"]  # kompakt


def test_vektor_kopplungscode(kern, vektor):
    k = kern.kopplungscode_lesen(vektor["kopplungscode"])
    assert k.oeffentlich.hex() == vektor["oeffentlichHex"]
    assert k.geheimnis.hex() == vektor["sHex"]
    assert k.url == "https://test.invalid" and k.name == "Testverbindung"


def test_paeckchen_roundtrip(kern, vektor):
    k = kern.kopplungscode_lesen(vektor["kopplungscode"])
    p = kern.paeckchen_bauen(k, "solar_erzeugung", "2026-10-26", 1000, "12.5")
    assert len(p["k"]) == 32 and set(p["k"]) <= set("0123456789abcdef")
    assert "solar" not in p["k"] and "2026" not in p["k"]
    assert p["k"] == kern.eindeutigkeit(k.geheimnis, "solar_erzeugung", "2026-10-26")
    geheim = PrivateKey(bytes.fromhex(vektor["geheimHex"]))
    objekt = json.loads(SealedBox(geheim).decrypt(base64.b64decode(p["box"])))
    assert objekt["stand"] == "12.5" and objekt["kanal"] == "solar_erzeugung" and objekt["e"] == "kWh"
    assert len(base64.b64decode(p["box"])) <= 1024


def test_sealed_box_ist_zufaellig(kern, vektor):
    pub = bytes.fromhex(vektor["oeffentlichHex"])
    assert kern.versiegeln(pub, "x") != kern.versiegeln(pub, "x")


# ------------------------------------------------------------ Stand

@pytest.mark.parametrize(
    "eingabe,erwartet",
    [
        ("2951.709566", "2951.709566"),
        ("0", "0"),
        ("0.0", "0"),
        ("12", "12"),
        ("12.50", "12.5"),
        ("2951.7095664", "2951.709566"),
        ("2951.7095665", "2951.709567"),
        ("0.0000004", "0"),
        ("9999999999", "9999999999"),
        ("9999999999.999999", "9999999999.999999"),
        ("0012.5", "12.5"),
        ("123456.1", "123456.1"),
        (Decimal("1.10"), "1.1"),
        (3, "3"),
        (0.1, "0.1"),  # kein Gleitkomma-Artefakt
        (2951.709566, "2951.709566"),
    ],
)
def test_stand_text_ok(kern, eingabe, erwartet):
    assert kern.stand_text(eingabe) == erwartet


@pytest.mark.parametrize(
    "eingabe",
    ["12,5", "1.234,5", "-1", "-0", "+1", "1e3", "1E+3", "NaN", "inf", "unknown", "unavailable", "",
     " ", None, True, "1.", ".5", "0x10", "1 000", "100000000000000000000", float("nan"), -1.0,
     "10000000000", "9999999999.9999996", "99999999999999999999"],
)
def test_stand_text_abgelehnt(kern, eingabe):
    assert kern.stand_text(eingabe) is None


def test_stand_einheiten(kern):
    assert kern.stand_aus_zustand("2951.709566", "kWh") == "2951.709566"
    assert kern.stand_aus_zustand("2951.709566", None) == "2951.709566"
    assert kern.stand_aus_zustand("1500", "Wh") == "1.5"
    assert kern.stand_aus_zustand("1.5", "MWh") == "1500"
    assert kern.stand_aus_zustand("5", "m³") is None
    assert kern.stand_aus_zustand("12,5", "kWh") is None
    assert kern.stand_aus_zustand("unavailable", "kWh") is None


def test_klartext_pruefungen(kern):
    s = bytes(32)
    with pytest.raises(ValueError):
        kern.klartext_bauen(s, "Strom", "2026-10-26", 1, "1")
    with pytest.raises(ValueError):
        kern.klartext_bauen(s, "a", "26.10.2026", 1, "1")
    with pytest.raises(ValueError):
        kern.klartext_bauen(s, "a", "2026-10-26", 1, "1,5")
    with pytest.raises(ValueError):
        kern.klartext_bauen(s, "a", "2026-10-26", 1, "-1")
    with pytest.raises(ValueError):
        kern.klartext_bauen(s, "a", "2026-10-26", 1, "1.1234567")


# ------------------------------------------------------------ Datum

@pytest.mark.parametrize(
    "utc,erwartet",
    [
        (datetime(2026, 10, 25, 23, 5, tzinfo=UTC), "2026-10-26"),  # Winter: UTC+1
        (datetime(2026, 10, 24, 22, 5, tzinfo=UTC), "2026-10-25"),  # Sommer: UTC+2
        (datetime(2026, 10, 24, 21, 59, tzinfo=UTC), "2026-10-24"),
        (datetime(2026, 6, 30, 22, 0, tzinfo=UTC), "2026-07-01"),
        (datetime(2026, 6, 30, 21, 59, tzinfo=UTC), "2026-06-30"),
        # Umstellung auf Sommerzeit 2026-03-29
        (datetime(2026, 3, 28, 22, 59, tzinfo=UTC), "2026-03-28"),
        (datetime(2026, 3, 28, 23, 0, tzinfo=UTC), "2026-03-29"),
        # Umstellung auf Winterzeit 2026-10-25 (25 Stunden)
        (datetime(2026, 10, 25, 22, 59, tzinfo=UTC), "2026-10-25"),
        (datetime(2026, 10, 25, 23, 0, tzinfo=UTC), "2026-10-26"),
    ],
)
def test_berliner_datum(kern, utc, erwartet):
    assert kern.berliner_datum(utc) == erwartet


def test_datum_aus_anderer_zeitzone(kern):
    from zoneinfo import ZoneInfo

    lokal = datetime(2026, 10, 26, 0, 5, tzinfo=ZoneInfo("America/New_York"))  # = 06:05 Berlin
    assert kern.berliner_datum(lokal) == "2026-10-26"
    lokal = datetime(2026, 10, 25, 20, 0, tzinfo=ZoneInfo("America/New_York"))  # = 02:00 Berlin am 26.
    assert kern.berliner_datum(lokal) == "2026-10-26"


def test_epoch_ms(kern):
    assert kern.epoch_ms(datetime(2026, 10, 26, 0, 0, tzinfo=UTC)) == 1792972800000


# ------------------------------------------------------------ Backoff

def test_backoff_folge(kern):
    assert [kern.backoff_minuten(n) for n in range(0, 9)] == [0, 1, 5, 15, 60, 60, 60, 60, 60]


# ------------------------------------------------------------ Warteschlange

def paket(kanal="strom_bezug", d="2026-10-26"):
    return {"k": "0" * 32, "kanal": kanal, "d": d, "box": "QUJD"}


def test_queue_duplikate(kern):
    w = kern.Warteschlange()
    assert w.hinzufuegen(paket()) is True
    assert w.hinzufuegen(paket()) is False
    assert len(w) == 1
    assert w.hat_tag("strom_bezug", "2026-10-26")
    assert not w.hat_tag("strom_bezug", "2026-10-27")
    w.bestaetigen(["strom_bezug:2026-10-26"])
    assert len(w) == 0
    assert w.hat_tag("strom_bezug", "2026-10-26")  # bestätigt bleibt gemerkt
    assert w.hinzufuegen(paket()) is False


def test_queue_verwerfen_nach_7_tagen(kern):
    w = kern.Warteschlange()
    for d in ["2026-10-18", "2026-10-19", "2026-10-26"]:
        w.hinzufuegen(paket(d=d))
    weg = w.verwerfen_alte("2026-10-26")
    assert weg == ["strom_bezug:2026-10-18"]  # 8 Tage alt
    assert sorted(w.offen) == ["strom_bezug:2026-10-19", "strom_bezug:2026-10-26"]  # genau 7 Tage bleibt


def test_queue_merkliste_wird_geleert(kern):
    w = kern.Warteschlange()
    w.hinzufuegen(paket(d="2026-10-01"))
    w.bestaetigen(["strom_bezug:2026-10-01"])
    w.verwerfen_alte("2026-10-26")
    assert w.bestaetigt == {}


def test_queue_persistenz(kern):
    w = kern.Warteschlange()
    w.hinzufuegen(paket())
    w.hinzufuegen(paket("solar_erzeugung"))
    w.bestaetigen(["solar_erzeugung:2026-10-26"])
    neu = kern.Warteschlange.aus_dict(json.loads(json.dumps(w.zu_dict())))
    assert list(neu.offen) == ["strom_bezug:2026-10-26"]
    assert neu.bestaetigt == {"solar_erzeugung:2026-10-26": "2026-10-26"}


def test_queue_kaputter_zustand(kern):
    assert len(kern.Warteschlange.aus_dict(None)) == 0
    assert len(kern.Warteschlange.aus_dict({"offen": [1, {"k": "x"}, {"k": 1}]})) == 0
    w = kern.Warteschlange.aus_dict({"offen": [dict(paket(), d="kaputt")], "bestaetigt": {"a": 5}})
    assert len(w) == 0 and w.bestaetigt == {}


def test_queue_stapelgroesse(kern):
    w = kern.Warteschlange()
    for i in range(60):
        w.hinzufuegen(paket(kanal=f"k{i:02d}"))
    assert len(w.naechste()) == 50


# ------------------------------------------------------------ Kopplungscode

def test_code_gueltig(kern):
    k = kern.kopplungscode_lesen(code_aus(gueltig()))
    assert k.url == "https://familyhub.lx-labs.dev" and k.name == "Haus Keller"
    assert len(k.oeffentlich) == 32 and len(k.geheimnis) == 32


def test_code_mit_leerraum_um_den_code(kern):
    k = kern.kopplungscode_lesen("  " + code_aus(gueltig()) + "\n")
    assert k.url == "https://familyhub.lx-labs.dev"


def fehler(kern, text):
    with pytest.raises(kern.KopplungsFehler) as e:
        kern.kopplungscode_lesen(text)
    return e.value.code


def test_code_kaputt(kern):
    assert fehler(kern, "") == "format"
    assert fehler(kern, "hallo") == "format"
    assert fehler(kern, "FH1-") == "format"
    assert fehler(kern, "FH1-!!!") == "format"
    assert fehler(kern, "FH1-" + base64.urlsafe_b64encode(b"kein json").decode().rstrip("=")) == "format"
    assert fehler(kern, "FH1-" + base64.urlsafe_b64encode(b"[1]").decode().rstrip("=")) == "format"
    assert fehler(kern, code_aus(gueltig())[:-6]) in ("format", "adresse", "token", "schluessel_laenge")
    assert fehler(kern, "FH2-" + code_aus(gueltig())[4:]) == "format"
    assert fehler(kern, None) == "format"


def test_code_version(kern):
    assert fehler(kern, code_aus(gueltig() | {"v": 2})) == "version"
    assert fehler(kern, code_aus({k: v for k, v in gueltig().items() if k != "v"})) == "version"
    assert fehler(kern, code_aus(gueltig() | {"v": "1"})) == "version"
    assert fehler(kern, code_aus(gueltig() | {"v": True})) == "version"


@pytest.mark.parametrize(
    "url",
    ["http://familyhub.lx-labs.dev", "ftp://x.de", "familyhub.lx-labs.dev", "https://", "https://a b.de",
     "https://user:pw@familyhub.lx-labs.dev", "https://x.de/?a=1", "https://x.de/#f", "", None, 5,
     "https://familyhub.lx-labs.dev/", "https://x.de/pfad", "https://x.de/api/v1",
     "https://127.0.0.1", "https://10.0.0.5:8443", "https://[::1]", "https://[::1]:8443", "https://127.1",
     "https://2130706433", "https://1.2.3", "https://x.de:443", "https://x.de:0", "https://x.de:99999",
     "https://x.de:", "https://x.de:80a", "https://X.de", "https://-x.de", "https://x..de", "https://x.de.",
     " https://x.de", "https://x.de ", "https://x.de\n", "HTTPS://x.de"],
)
def test_code_adresse(kern, url):
    assert fehler(kern, code_aus(gueltig() | {"u": url})) == "adresse"


def test_code_token(kern):
    assert fehler(kern, code_aus(gueltig() | {"t": "abc"})) == "token"
    assert fehler(kern, code_aus(gueltig() | {"t": "fhi_" + "A" * 42})) == "token"
    assert fehler(kern, code_aus(gueltig() | {"t": "xyz_" + "A" * 43})) == "token"


def test_code_schluessel_laenge(kern):
    assert fehler(kern, code_aus(gueltig() | {"p": b64(bytes(31))})) == "schluessel_laenge"
    assert fehler(kern, code_aus(gueltig() | {"p": b64(bytes(33))})) == "schluessel_laenge"
    assert fehler(kern, code_aus(gueltig() | {"s": b64(bytes(16))})) == "schluessel_laenge"
    assert fehler(kern, code_aus(gueltig() | {"s": "***"})) == "schluessel_laenge"
    assert fehler(kern, code_aus(gueltig() | {"p": 5})) == "schluessel_laenge"
    d = gueltig()
    del d["s"]
    assert fehler(kern, code_aus(d)) == "schluessel_laenge"


def test_code_name_optional(kern):
    d = gueltig()
    del d["n"]
    assert kern.kopplungscode_lesen(code_aus(d)).name == "Familyhub"
    assert kern.kopplungscode_lesen(code_aus(gueltig() | {"n": "x" * 100})).name == "x" * 40


def test_code_unbekannte_felder_ok(kern):
    assert kern.kopplungscode_lesen(code_aus(gueltig() | {"zukunft": 1}))


# ------------------------------------------------------------ stündliches Nachholen

def test_nachholen_nur_fehlende_kanaele(kern):
    w = kern.Warteschlange()
    kan = ["strom_bezug", "solar_erzeugung"]
    assert kern.fehlende_kanaele(w, kan, "2026-10-26") == kan
    w.hinzufuegen(paket("strom_bezug"))
    assert kern.fehlende_kanaele(w, kan, "2026-10-26") == ["solar_erzeugung"]
    w.bestaetigen(["strom_bezug:2026-10-26"])  # bestätigt: nie doppelt senden
    assert kern.fehlende_kanaele(w, kan, "2026-10-26") == ["solar_erzeugung"]
    w.hinzufuegen(paket("solar_erzeugung"))
    assert kern.fehlende_kanaele(w, kan, "2026-10-26") == []
    # neuer Tag: wieder alle fällig
    assert kern.fehlende_kanaele(w, kan, "2026-10-27") == kan


def test_nachholen_erst_ab_versandzeit(kern):
    assert not kern.nachholen_faellig((0, 0, 0), (0, 5, 0))
    assert kern.nachholen_faellig((1, 0, 0), (0, 5, 0))
    assert kern.nachholen_faellig((0, 5, 0), (0, 5, 0))
    assert not kern.nachholen_faellig((13, 0, 0), (23, 30, 0))


# ------------------------------------------------------------ Neukopplung

def test_warteschlange_passt_nur_zum_selben_schluessel(kern):
    assert kern.warteschlange_passt("AAA=", "AAA=")
    assert not kern.warteschlange_passt("AAA=", "BBB=")
    assert kern.warteschlange_passt(None, "BBB=")  # ältere Ablage ohne Angabe


@pytest.mark.parametrize(
    "url", ["https://familyhub.lx-labs.dev", "https://x.de:8443", "https://localhost", "https://a-b.c1.example.org:65535"]
)
def test_code_adresse_gueltig(kern, url):
    assert kern.kopplungscode_lesen(code_aus(gueltig() | {"u": url})).url == url
    assert kern.kopplungs_adresse(url) == url


def test_host_anzeige(kern):
    assert kern.host_anzeige("https://familyhub.lx-labs.dev") == "familyhub.lx-labs.dev"
    assert kern.host_anzeige("https://x.de:8443") == "x.de:8443"


# ------------------------------------------------------------ Eindeutigkeitsschlüssel k

def test_k_vektor(kern, vektor):
    s = bytes.fromhex(vektor["sHex"])
    assert kern.eindeutigkeit(s, "strom_bezug", "2026-10-26") == vektor["k"]
    erwartet = hashlib.blake2b(
        b"fampad-ingest-v1-k\nstrom_bezug\n2026-10-26", key=s, digest_size=16
    ).hexdigest()
    assert vektor["k"] == erwartet and len(vektor["k"]) == 32


def test_k_haengt_von_kanal_tag_und_geheimnis_ab(kern):
    s = bytes(range(32))
    a = kern.eindeutigkeit(s, "strom_bezug", "2026-10-26")
    assert a == kern.eindeutigkeit(s, "strom_bezug", "2026-10-26")
    assert a != kern.eindeutigkeit(s, "strom_bezug", "2026-10-27")
    assert a != kern.eindeutigkeit(s, "solar_erzeugung", "2026-10-26")
    assert a != kern.eindeutigkeit(bytes(32), "strom_bezug", "2026-10-26")


def test_queue_arbeitet_nach_kanal_und_tag_nicht_nach_k(kern):
    w = kern.Warteschlange()
    p1 = dict(paket(), k="a" * 32)
    p2 = dict(paket(), k="b" * 32)  # anderer Hash, gleicher Kanal und Tag: Duplikat
    assert w.hinzufuegen(p1) is True and w.hinzufuegen(p2) is False
    assert w.hat_tag("strom_bezug", "2026-10-26")
    w.abgelehnt(p1)
    assert len(w) == 0 and w.hat_tag("strom_bezug", "2026-10-26")
    assert w.hinzufuegen(p1) is False


def test_queue_alte_ablage_mit_klartext_k(kern):
    alt = {"offen": [{"k": "strom_bezug:2026-10-26", "kanal": "strom_bezug", "d": "2026-10-26", "box": "QUJD"}],
           "bestaetigt": {"solar_erzeugung:2026-10-26": "2026-10-26"}}
    w = kern.Warteschlange.aus_dict(alt)
    assert w.hat_tag("strom_bezug", "2026-10-26") and w.hat_tag("solar_erzeugung", "2026-10-26")
    w.bestaetigen(["strom_bezug:2026-10-26"])
    assert len(w) == 0


# ------------------------------------------------------------ Versandzeit in Europe/Berlin

def test_naechster_versand_berlin(kern):
    utc = timezone.utc
    # Winter: 00:05 Berlin = 23:05 UTC am Vortag
    assert kern.naechster_versand(datetime(2026, 1, 10, 12, 0, tzinfo=utc), (0, 5, 0)) == datetime(2026, 1, 10, 23, 5, tzinfo=utc)
    # Sommer: 00:05 Berlin = 22:05 UTC am Vortag
    assert kern.naechster_versand(datetime(2026, 7, 10, 12, 0, tzinfo=utc), (0, 5, 0)) == datetime(2026, 7, 10, 22, 5, tzinfo=utc)
    # exakt zur Versandzeit: der nächste Tag
    assert kern.naechster_versand(datetime(2026, 7, 10, 22, 5, tzinfo=utc), (0, 5, 0)) == datetime(2026, 7, 11, 22, 5, tzinfo=utc)
    # Sommerzeit-Wechsel (29.3.2026): der Tag hat 23 Stunden
    assert kern.naechster_versand(datetime(2026, 3, 28, 23, 6, tzinfo=utc), (0, 5, 0)) == datetime(2026, 3, 29, 22, 5, tzinfo=utc)


def test_berlin_zeit_unabhaengig_von_ha_zone(kern):
    utc = timezone.utc
    z = kern.berlin_zeit(datetime(2026, 10, 26, 23, 30, tzinfo=utc))
    assert (z.day, z.hour) == (27, 0) and kern.berliner_datum(z) == "2026-10-27"
    assert kern.berliner_datum(datetime(2026, 10, 26, 23, 30, tzinfo=timezone(timedelta(hours=-8)))) == "2026-10-27"
