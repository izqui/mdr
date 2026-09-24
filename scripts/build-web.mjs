import {build} from 'esbuild';
import {mkdir,writeFile,readFile,cp,rm,readdir} from 'node:fs/promises';
await mkdir('Sources/MDRApp/Resources/Web',{recursive:true});
await writeFile('Sources/MDRApp/Resources/Web/mdr-skill.md',await readFile('AGENT-REVIEW.md'));
const skillDestination='Sources/MDRApp/Resources/Web/mdr-agent-skill';
await rm(skillDestination,{recursive:true,force:true});
await cp('skills/mdr',skillDestination,{recursive:true});
const result=await build({entryPoints:['web/reader.mjs','web/diagrams.mjs'],bundle:true,format:'iife',target:['safari17'],minify:true,legalComments:'eof',metafile:true,outdir:'Sources/MDRApp/Resources/Web',logLevel:'info'});
// Ship the licenses with the application, not just with the source checkout.
const licenseParts=[];
const packages=[...new Set(Object.keys(result.metafile.inputs).map(path=>path.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1]).filter(Boolean))].sort();
for(const directory of packages) {
  const manifest=JSON.parse(await readFile(`${directory}/package.json`,'utf8'));
  const files=(await readdir(directory)).filter(file=>/^(licen[cs]e|copying|notice)([.\-_]|$)/i.test(file));
  if(!files.length) throw new Error(`Missing license notice for bundled dependency ${manifest.name}`);
  licenseParts.push(`${manifest.name} ${manifest.version}\n${(await Promise.all(files.map(file=>readFile(`${directory}/${file}`,'utf8')))).join('\n')}`);
}
await writeFile('Sources/MDRApp/Resources/Web/THIRD-PARTY-LICENSES.txt',licenseParts.join('\n\n'+'—'.repeat(60)+'\n\n'));
