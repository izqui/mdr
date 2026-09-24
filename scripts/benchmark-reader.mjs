import {execFileSync} from 'node:child_process';
import {mkdir,readFile,writeFile,copyFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {build} from 'esbuild';

// Real WKWebView, generated data only. Run serially so other tests don't skew it.
const args=process.argv.slice(2),option=(name,fallback)=>args.includes(name)?args[args.indexOf(name)+1]:fallback;
const baseline=option('--baseline',null),runs=Number(option('--runs','3'));
if(!Number.isInteger(runs)||runs<1||runs>10)throw new Error('--runs must be between 1 and 10');
const directory=resolve('work/performance',baseline?'baseline':'current');
await mkdir(directory,{recursive:true});
execFileSync(process.execPath,['scripts/make-performance-fixture.mjs',`${directory}/large-spec.md`],{stdio:'inherit'});
let webDirectory;
if(baseline){
  const commit=execFileSync('git',['rev-parse','--verify',`${baseline}^{commit}`],{encoding:'utf8'}).trim();
  webDirectory=`${directory}/web`;await mkdir(webDirectory,{recursive:true});
  const versionFile=path=>execFileSync('git',['show',`${commit}:${path}`],{encoding:'utf8'});
  for(const name of ['index.html','reader.css'])await writeFile(`${webDirectory}/${name}`,versionFile(`Sources/MDRApp/Resources/Web/${name}`));
  for(const name of ['markdown.mjs','autosave.mjs'])await writeFile(`${webDirectory}/${name}`,versionFile(`web/${name}`));
  await copyFile('web/performance.mjs',`${webDirectory}/performance.mjs`);
  let reader=versionFile('web/reader.mjs');
  if(!reader.includes('performanceSnapshot')){
    reader="import {measure,performanceSnapshot} from './performance.mjs';\n"+reader;
    reader=reader.replace('window.mdr={','window.mdr={\n  performance:performanceSnapshot,').replace('  receive(value){','  receive(value){if(window.__mdrProfile)window.__mdrLastState=value;');
    for(const [name,label] of [['applyState','state'],['updateProgress','scroll'],['drawMinimap','minimap'],['mappedSelection','selection'],['paintAnnotations','annotations'],['renderFeedback','feedback'],['updateFind','find']]){
      if(!reader.includes(`function ${name}(`))throw new Error(`Baseline does not expose ${name}; use v0.3.1.`);
      reader=reader.replace(`function ${name}(`,`function ${name}Measured(`);
      reader+=`\nfunction ${name}(...args){return measure('${label}',()=>${name}Measured(...args));}\n`;
    }
    reader=reader.replace('renderMarkdown(md,value.source)',"measure('markdown',()=>renderMarkdown(md,value.source))").replace("$('document').innerHTML=rendered.html;","measure('dom',()=>{$('document').innerHTML=rendered.html;});");
  }
  await writeFile(`${webDirectory}/reader.mjs`,reader);
  await build({entryPoints:[`${webDirectory}/reader.mjs`],bundle:true,format:'iife',target:['safari17'],minify:true,outfile:`${webDirectory}/reader.js`});
}
const app=resolve('work/performance/Benchmark.app');
await mkdir(`${app}/Contents/MacOS`,{recursive:true});
await mkdir(`${app}/Contents/Resources`,{recursive:true});
await copyFile('.build/debug/mdr',`${app}/Contents/MacOS/mdr`);
execFileSync('ditto',['.build/debug/mdr_MDRApp.bundle',`${app}/Contents/Resources/mdr_MDRApp.bundle`]);
await writeFile(`${app}/Contents/Info.plist`,'<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.mdr.benchmark</string><key>CFBundleName</key><string>mdr Benchmark</string><key>CFBundleExecutable</key><string>mdr</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string><key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>');
execFileSync('codesign',['--force','--deep','--sign','-',app],{stdio:'pipe'});
const reports=[];
for(let run=1;run<=runs;run++){
  const output=execFileSync(`${app}/Contents/MacOS/mdr`,[],{encoding:'utf8',timeout:45000,maxBuffer:8*1024*1024,
    env:{...process.env,MDR_PERFORMANCE_DIR:directory,...(webDirectory?{MDR_PERFORMANCE_WEB_DIR:webDirectory}:{})}});
  await writeFile(`${directory}/run-${run}.log`,output);
  const report=JSON.parse(await readFile(`${directory}/report.json`,'utf8'));reports.push(report);
  await writeFile(`${directory}/run-${run}.json`,JSON.stringify(report,null,2));
  console.log(`Run ${run}: opened ${Math.round(report.openMilliseconds)} ms, state ${report.initial.state.total} ms, review ${report.reviewing.state.median} ms`);
}
const median=values=>{const valid=values.filter(Number.isFinite).sort((a,b)=>a-b);return valid.length?valid[Math.floor(valid.length/2)]:null;};
const summary={baseline:baseline??'working tree',runs,backgroundRuns:reports.filter(r=>r.background).length,sourceBytes:reports[0].sourceBytes,codeBlocks:reports[0].codeBlocks,codeLines:reports[0].codeLines,
  openMilliseconds:median(reports.map(r=>r.openMilliseconds)),initialElements:median(reports.map(r=>r.initialElements)),
  initialStateMs:median(reports.map(r=>r.initial.state.total)),markdownMs:median(reports.map(r=>r.initial.markdown.total)),
  reviewMedianMs:median(reports.map(r=>r.reviewing.state.median)),annotationTotalMs:median(reports.map(r=>r.reviewing.annotations.total)),
  scrollWorkMs:median(reports.map(r=>r.background?null:(r.scrolling.scroll?.total??0))),skimFrameP95Ms:median(reports.map(r=>r.frames.p95)),
  readingFrameP95Ms:median(reports.map(r=>r.readingFrames.p95)),findMs:median(reports.map(r=>r.finding.find.total))};
await writeFile(`${directory}/summary.json`,JSON.stringify(summary,null,2)+'\n');console.log(summary);
