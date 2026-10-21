import fs from 'node:fs';
const f='src/operator/probes.ts'; let s=fs.readFileSync(f,'utf8');
s=s.replace("      let timer: NodeJS.Timeout | undefined;\n","");
s=s.replace("      // Nur das Zertifikat lesen","      const timer = setTimeout(() => finish(null), TIMEOUT_MS);\n      // Nur das Zertifikat lesen");
s=s.replace("        resolve(null);\n        return;","        finish(null);\n        return;");
s=s.replace("      timer = setTimeout(() => finish(null), TIMEOUT_MS);\n","");
fs.writeFileSync(f,s);
