# Richtwerte Impf- und Vorsorge (Recherche 27.10.2026, nur offizielle Richtwerte, keine ärztliche Beratung)

**Stand: Oktober 2026.** Grundlage des Katalogs `app/lib/data/vorsorge/vorsorge_vorlagen.dart` (Abschnitt 6p der Projektbeschreibung). Die Quellen sind STIKO/RKI, G-BA und das Bundesgesundheitsministerium (Links unten); die App zeigt sie als Text und markiert alles mit „(K)“ als `ungeprueft`, freiwillige Leistungen als `freiwillig` und Risiko-Impfungen als `nurHinweis`. Wer Werte hier ändert, ändert den Katalog und den Stand (`kVorsorgeStand`) mit.
(K) = nicht live aus der Primärquelle gelesen (Wissen zum STIKO-Standard) → in der App „bitte mit Impfpass/Arzt prüfen“. Quellen-Basis: RKI Impfkalender https://www.rki.de/DE/Themen/Infektionskrankheiten/Impfen/Impfkalender/impfkalender-node.html (Epid. Bull. 4/2026), BMG Früherkennung Kinder https://www.bundesgesundheitsministerium.de/themen/praevention/kindergesundheit/frueherkennungsuntersuchung-bei-kindern, G-BA Gesundheitsuntersuchungen https://www.g-ba.de/themen/methodenbewertung/erwachsene/gesundheitsuntersuchungen/, BMG Krebsfrüherkennung https://www.bundesgesundheitsministerium.de/krebsfrueherkennung/, G-BA Zahn https://www.g-ba.de/themen/zahnaerztliche-versorgung/prophylaxe-frueherkennung/. Statt fester Werte immer den Quell-Link zeigen; STIKO ändert unterjährig.

## Kinder/Jugendliche Impfungen (Alter in Monaten, M; Jahre, J)
- Rotavirus (K): ab 6 Wochen, 2 oder 3 Dosen je Impfstoff, früh beenden
- 6-fach (Tetanus, Diphtherie, Pertussis, Hib, Polio, Hep B) (K): 2, 4, 11 M (2+1); Frühgeborene 2, 3, 4, 11 M (Hib 2026 geändert, Details unsicher)
- Pneumokokken Säuglinge (K): 2, 4, 11 M; Kinder 2–17 J mit Risiko: nur PCV20
- MMR (K): 11–14 M, 2. Dosis ab 15 M (≥4 Wochen Abstand); nachholen jederzeit
- Varizellen (K): 11–14 M, 2. Dosis ab 15 M; nachholen jederzeit
- Meningokokken C Säugling: ENTFÄLLT 2026 (belegt); Meningokokken ACWY neu: 12–14 J, 1 Dosis, nachholen bis 25 J (belegt)
- Tdap-Auffrischung (K): 5–6 J
- Td(ap)-IPV-Auffrischung (K): 9–16 J
- HPV (K): 9–14 J, 2 Dosen (5 Monate Abstand); ab 15 J 3 Dosen; nachholen bis 17 J
- RSV Säuglinge (K): einmal in der ersten RSV-Saison (Details ungeprüft)

## Kinder/Jugendliche Vorsorge (belegt, BMG)
U1 direkt nach Geburt · U2 3.–10. Lebenstag · U3 4.–5. Lebenswoche · U4 3.–4. Monat · U5 6.–7. Monat · U6 10.–12. Monat · U7 21.–24. Monat · U7a 34.–36. Monat · U8 46.–48. Monat · U9 60.–64. Monat · J1 13.–14. Lebensjahr. U10/U11/J2: KEINE G-BA-Regelleistung (freiwillige Kassenleistung/Regionalverträge; G-BA prüft U10 seit 08/2023, kein Abschluss gefunden) → als „freiwillig“ markieren oder weglassen.
Zahn Kleinkinder: 6 Früherkennungsuntersuchungen 6.–72. Lebensmonat (Fenster uneinheitlich, unsicher). Zahn-Individualprophylaxe 7.–18. J (G-BA 6.–17., unsicher), halbjährlich, ab 12 J Bonusheft.

## Erwachsene Impfungen
- Td (K): ab 18, alle 10 Jahre (120 M); Pertussis (Tdap) einmalig bei nächster fälliger Td-Dosis
- Masern: nach 1970 Geborene mit unklarem Status/keine oder nur 1 Dosis: einmalig
- Influenza: ab 60 jährlich (12 M), Herbst
- Pneumokokken: ab 60 einmalig (PCV20; nach PPSV23 ≥6 J Abstand)
- Herpes zoster: ab 60 (Totimpfstoff, 2 Dosen im Abstand 2–6 M (K)); ab 18 bei erhöhter Gefährdung
- COVID-19: ab 75 jährlich, ≥6 M nach letzter Impfung/Infektion (Altersgrenze Juli 2026 von 60 auf 75 angehoben, Stand 15.10.2026); jünger nur bei Risiko
- RSV: ab 75 einmalig (60–74 nur bei schwerer Grunderkrankung/Pflegeheim)
- Nur Hinweis nach Risiko: Hepatitis B, FSME (Risikogebiet), Chikungunya (Reise/Beruf)

## Erwachsene Früherkennung (GKV)
- Gesundheits-Check-up: ab 18; 18–34 einmalig; ab 35 alle 3 Jahre (36 M)
- Hautkrebs-Screening: ab 35 alle 2 Jahre (24 M)
- Darmkrebs Stuhltest: ab 50 alle 2 Jahre; Koloskopie ab 50, 2 Untersuchungen im Abstand 10 Jahre (120 M); seit 04/2025 auch Frauen ab 50
- Gebärmutterhals: Frauen 20–34 jährlich Pap; ab 35 alle 3 Jahre HPV+Pap
- Brust: Frauen ab 30 jährlich Abtasten; Mammographie-Screening Frauen 50–69 (70–75 auf Wunsch, Grenze unsicher) alle 2 Jahre
- Prostata: Männer ab 45 jährlich (Tastuntersuchung)
- Lungenkrebs Low-Dose-CT: 50–75, starke (ehemalige) Raucher, jährlich (Kriterien eng)
- Zahnvorsorge Erwachsene: halbjährlich üblich; Bonusheft mind. 1x/Jahr; Zahnstein 1x/Jahr (Sekundärquelle)

## Unsicherheiten
Kinder-Impfschemata (K), Hib 2026, MenB, RSV-Säugling zu prüfen; COVID/RSV/Zoster/Influenza/Hep B/FSME ändern sich/risikoabhängig; U10/U11/J2 keine Regelleistung; Mammographie-Obergrenze und Zahnfenster Kinder uneinheitlich.
