import fs from 'node:fs';
const f='test/betrieb_test.dart'; let s=fs.readFileSync(f,'utf8');
const rep=(a,b)=>{ if(!s.includes(a)) throw new Error('fehlt: '+a.slice(0,60)); s=s.replace(a,b); };
rep("Object Function(Req)? audit,","FutureOr<Object?> Function(Req)? audit,");
rep("env.server.on('GET /admin/audit', (r) {\n      final a = audit?.call(r);","env.server.on('GET /admin/audit', (r) async {\n      final a = await audit?.call(r);");
rep("        audit: (r) {\n          if (r.query['category'] == 'fehler') {\n            // die Antwort kommt erst nach dem Wechsel zu \"Anmeldung\"\n            return {'items': [_eintrag(4, event: 'login_failed', category: 'fehler', person: null)], 'nextCursor': null, '_warte': spaet};\n          }","        audit: (r) async {\n          if (r.query['category'] == 'fehler') {\n            // die Antwort kommt erst nach dem Wechsel zu \"Anmeldung\"\n            await spaet.future;\n            return {'items': [_eintrag(4, event: 'login_failed', category: 'fehler', person: null)], 'nextCursor': null};\n          }");
rep("      // Hinweis: der Fake antwortet sofort; die Reihenfolge wird über zwei schnelle Wechsel ohne Zwischenpumpen erzwungen\n      await tester.tap(find.text('Fehler').first);\n      await tester.tap(find.text('Anmeldung').first);\n      spaet.complete();","      await tippe(tester, find.text('Fehler'));\n      await tippe(tester, find.text('Anmeldung').last);\n      expect(find.text('Abmeldung'), findsOneWidget);\n      spaet.complete();");
fs.writeFileSync(f,s);
