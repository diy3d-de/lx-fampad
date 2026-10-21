import fs from 'node:fs';
const f='test/betrieb_test.dart'; let s=fs.readFileSync(f,'utf8');
const a="      await start(tester, skala: 2.0);\n      await betriebOeffnenMobil(tester);\n      final a";
if(!s.includes(a)) throw 1;
s=s.replace(a,"      // die Startseite selbst läuft bei 2.0 über (nicht Teil dieses Pakets): erst danach die Schrift vergrößern\n      await start(tester);\n      await tippe(tester, find.byTooltip('Profil und Sicherheit'));\n      tester.platformDispatcher.textScaleFactorTestValue = 2.0;\n      await tippe(tester, find.text('Betrieb'));\n      final a");
fs.writeFileSync(f,s);
