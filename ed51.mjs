import fs from 'fs';
const p='test/crypto/e2ee_controller_test.dart';let s=fs.readFileSync(p,'utf8');
const a=`      group('Dauerhafter Browser-Speicher (nur Web, hier mit Fake)', () {`;
if(!s.includes(a))throw 1;
s=s.replace(a,()=>`      test('Vertrag mit dem Server (docs/API.md): GET /me/keys im Format von main und 403 destructive_locked mit retryAfterSec', () async {
        // genau die Antwort von server/src/auth/keys.ts (getOwnKeys)
        final dto = EigeneSchluesselDto.fromJson({
          'keys': {'publicEncKey': base64urlKodieren(Uint8List(32)), 'publicSignKey': base64urlKodieren(Uint8List(32)), 'keyVersion': 3},
          'hasBackup': true,
          'pwBackupStale': true,
          'pwBackupVerifiedAt': '2026-10-21T08:15:30.123Z',
          'recoveryBackupAt': null,
          'archiveCount': 4,
        });
        expect(dto.hatSicherung, isTrue);
        expect(dto.pwSicherungVeraltet, isTrue);
        expect(dto.pwSicherungBestaetigtAm, DateTime.utc(2026, 10, 21, 8, 15, 30, 123));
        expect(dto.wiederherstellungsSicherungAm, isNull, reason: 'null = keine Wiederherstellungssicherung zur aktuellen Version');
        expect(dto.archivAnzahl, 4);
        // 403 mit retryAfterSec im Antworttext (und ohne Header): die Dauer kommt an
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        fake.on('PUT /me/keys', (_) => jsonAntwort({'error': 'destructive_locked', 'message': 'x', 'retryAfterSec': 7200}, status: 403));
        await expectLater(
          a.ctrl.schluesselWechseln(),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'destructive_locked').having((e) => e.message, 'message', contains('frühestens in 2 Stunden'))),
        );
        // mit Header Retry-After (wie der echte Server, beides gesetzt)
        fake.on('PUT /me/keys', (_) => jsonAntwort({'error': 'destructive_locked', 'message': 'x', 'retryAfterSec': 5400}, status: 403, headers: {'retry-after': '5400'}));
        await expectLater(a.ctrl.schluesselWechseln(), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('frühestens in 2 Stunden'))));
        expect(await a.speicher.lesen(personenschluesselName(_anna)), isNotNull, reason: 'der Schlüssel bleibt bei der Sperre unverändert');
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), isNull);
      });

`+a);
fs.writeFileSync(p,s);
