import {measure,performanceSnapshot} from './performance.mjs';
import {FeedbackAutosave} from './autosave.mjs';
import {createMarkdown,renderMarkdown,escapeHTML as esc,sourceBoundary,highlightedLines} from './markdown.mjs';
import TurndownService from 'turndown';

const $=id=>document.getElementById(id);
const icons={
  outline:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M13 9h4M13 13h4"/>',
  comment:'<path d="M20 11.5a7.5 7.5 0 0 1-7.5 7.5H5l-3 3v-9.5A7.5 7.5 0 0 1 9.5 5h3A7.5 7.5 0 0 1 20 11.5Z"/><path d="M7 10h8M7 14h5"/>',
  find:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4.5 4.5"/>',
  pen:'<path d="m15 4 5 5M4 20l5-1L20 8a2.1 2.1 0 0 0-5-5L4 14l-1 7Z"/>',
  export:'<path d="M12 3v12m-4-4 4 4 4-4M4 16v4h16v-4"/>'
};
const icon=name=>`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.45" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name]}</svg>`;
$('outline-toggle').innerHTML=icon('outline');$('feedback-icon').innerHTML=icon('comment');$('find-button').innerHTML=icon('find');$('find-icon').innerHTML=icon('find');
$('comment-selection').innerHTML=icon('comment')+'Comment';$('suggest-selection').innerHTML=icon('pen')+'Suggest';
$('export-pdf').innerHTML=icon('export');

const md=createMarkdown({highlight:false}), turndown=new TurndownService({headingStyle:'atx',bulletListMarker:'-',codeBlockStyle:'fenced',emDelimiter:'*'});
let state=null,headings=[],mode='read',selection=null,editing=null,composer=false,pendingState=null,filter='open',activeFeedback=null,reattachID=null,renderID=0;
let theme='paper',fontSize=18,toastTimer,findMatches=[],findIndex=0;
let documentLayout=Promise.resolve(),headingJump=0;
let draftSession=null;
let sourceSpans=[],sourceBlocks=[],blockMaxEnds=[],findTextIndex=null;
let headingOffsets=[],tocLinks=new Map(),activeHeading=null,overviewFrame=0,progressFrame=0;
let overviewGeometry=[],geometryDirty=true,lastAnnotationSignature='';
const lowerBound=(items,value,key)=>{let lo=0,hi=items.length;while(lo<hi){const mid=(lo+hi)>>>1;if(key(items[mid])<value)lo=mid+1;else hi=mid;}return lo;};
function rebuildSourceIndex(){
  sourceSpans=[...$('document').querySelectorAll('[data-src-start]')].map(element=>({element,start:Number(element.dataset.srcStart),end:Number(element.dataset.srcEnd)}));
  sourceBlocks=[...$('document').querySelectorAll('[data-edit-start],[data-block-start]')].map(element=>({element,start:Number(element.dataset.editStart??element.dataset.blockStart),end:Number(element.dataset.editEnd??element.dataset.blockEnd)})).sort((a,b)=>a.start-b.start);
  let max=0;blockMaxEnds=sourceBlocks.map(item=>max=Math.max(max,item.end));
  findTextIndex=null;lastAnnotationSignature='';geometryDirty=true;
}
function scheduleOverview(layout=false){
  geometryDirty ||= layout;
  if(!overviewFrame)overviewFrame=requestAnimationFrame(()=>{overviewFrame=0;drawMinimap();});
}

const pendingRequests=new Map();
const native=!!window.webkit?.messageHandlers?.mdr;
const initials=name=>name.trim().split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase();

function host(action,data={}) {
  const requestId=crypto.randomUUID();
  return new Promise((resolve,reject)=>{
    const timeout=setTimeout(()=>{pendingRequests.delete(requestId);reject(new Error('The app did not respond. Your draft is still here.'));},20000);
    pendingRequests.set(requestId,{resolve,reject,timeout});
    if(native) window.webkit.messageHandlers.mdr.postMessage({action,requestId,...data});
    else previewHost(action,data,requestId);
  });
}
function dirty(value,saved=false) { if(native)window.webkit.messageHandlers.mdr.postMessage({action:'dirty',value,saved}); }
function toast(message) {clearTimeout(toastTimer);$('toast').textContent=message;$('toast').hidden=false;toastTimer=setTimeout(()=>$('toast').hidden=true,3800);}
function notice(message,warning=false) {$('notice-text').textContent=message;$('notice').hidden=!message;$('notice').classList.toggle('warning',warning);}
function safeRun(fn){return (...args)=>Promise.resolve().then(()=>fn(...args)).catch(error=>notice(error.message,true));}

window.mdr={
  performance:performanceSnapshot,
  prepareForPrint,
  resolve(id,result){const p=pendingRequests.get(id);if(!p)return;clearTimeout(p.timeout);pendingRequests.delete(id);result.ok?p.resolve(result):p.reject(Object.assign(new Error(result.error||'Could not save feedback.'),{retryable:result.retryable}));},
  receive(value){
    if(window.__mdrProfile)window.__mdrLastState=value;
    const knownReplies=new Set(state?.feedback.flatMap(item=>(item.replies??[]).map(reply=>reply.id))??[]);
    if(state&&value.feedback.some(item=>(item.replies??[]).some(reply=>!reply.isDraft&&!knownReplies.has(reply.id))))toast('New reply in your feedback.');
    if(editing||composer){
      pendingState=value;
      if(state?.revision.sha256!==value.revision.sha256)notice('The source changed. Your draft is safe; its anchor will be checked when you save.');
      state={...value,source:state.source,revision:state.revision};renderFeedback();return;
    }
    applyState(value);
  },
  warning(message){notice(message,true);},
  exported(message){toast(message);},
  navigateToHeading,
  command(action){
    const actions={find:toggleFind,comment:()=>openComment(),suggest:()=>setMode(mode==='read'?'suggest':'read'),feedback:()=>toggleFeedback(),outline:toggleOutline,
      reveal:()=>host('reveal'),exportPDF:()=>exportPDF(false),print:()=>exportPDF(true),zoomIn:()=>zoom(1),zoomOut:()=>zoom(-1),zoomReset:()=>zoom(0),settings:toggleSettings};
    if(actions[action])safeRun(actions[action])();
  }
};

function applyStateMeasured(value){
  const previousHash=state?.revision.sha256,previousScroll=$('scroll-area').scrollTop;
  state=value;
  if(value.theme)theme=value.theme;if(value.fontSize)fontSize=value.fontSize;
  applyTheme();applySize();
  $('file-name').textContent=value.fileName;$('file-name').title=value.filePath;
  $('document-kind').textContent=value.isWelcome?'A QUIETER WAY TO REVIEW':'MARKDOWN DOCUMENT';
  const sourceChanged=previousHash!==value.revision.sha256 || !$('document').childElementCount;
  const words=sourceChanged?value.source.trim().split(/\s+/).filter(Boolean).length:null;
  if(sourceChanged)$('reading-time').textContent=`${Math.max(1,Math.ceil(words/220))} min read`;
  renderDocumentDates(value);
  if(sourceChanged)$('word-count').textContent=`${words.toLocaleString()} words`;
  $('document-status').textContent=value.hasSidecar?'Feedback saved beside your document':value.isWelcome?'Welcome to mdr':'Original document · read only';
  $('settings-toggle').textContent=initials(value.author);$('settings-toggle').title=`${value.author} · Appearance and reviewer`;
  $('reviewer-name').value=value.author;$('composer-author').textContent=value.author;$('composer-avatar').textContent=initials(value.author);
  $('welcome-cta').hidden=!value.isWelcome;
  if(sourceChanged){
    const rendered=measure('markdown',()=>renderMarkdown(md,value.source));headings=rendered.headings;
    measure('dom',()=>{$('document').innerHTML=rendered.html;});
    // WebKit's printer may otherwise orphan a heading at a page boundary.
    for(const heading of $('document').querySelectorAll('h1,h2,h3,h4')){
      const next=heading.nextElementSibling;
      if(next?.tagName==='P'&&next.textContent.length<1400){const group=document.createElement('div');group.className='print-lead';heading.before(group);group.append(heading,next);}
    }
    rebuildSourceIndex();renderTOC();observeCode();
    $('scroll-area').scrollTop=previousHash?previousScroll:0;
    documentLayout=Promise.all([renderDiagrams(++renderID),loadImages()]);
  }
  renderFeedback();paintAnnotations();if(sourceChanged)updateFind();
  if(sourceChanged)scheduleOverview(true);
  if(value.notice)notice(value.notice);
}

// Highlight close to the viewport, keeping offscreen code lightweight. Outer
// source spans stay stable; selection/edit/find ranges are never replaced mid-use.
let codeObserver,codeFrame=0,lastReaderScroll=-Infinity;
const nearbyCode=new Set();
function highlightCode(block){
  if(!block.hasAttribute('data-highlight-pending'))return;
  measure('highlight',()=>{
    const code=block.querySelector('code'),lines=highlightedLines(code.textContent,block.dataset.codeLanguage);
    code.querySelectorAll('.code-source').forEach((span,index)=>{span.innerHTML=(lines[index]??'')+(span.hasAttribute('data-code-newline')?'\n':'');});
    block.removeAttribute('data-highlight-pending');
  });
}
async function prepareForPrint(){
  let layout;do{layout=documentLayout;await layout;}while(layout!==documentLayout);
  if(editing||composer)throw new Error('Save or cancel your current feedback before exporting.');
  for(const block of $('document').querySelectorAll('[data-highlight-pending]')){
    if(editing||composer)throw new Error('Save or cancel your current feedback before exporting.');
    if(!block.isConnected)return prepareForPrint();
    highlightCode(block);
    await new Promise(resolve=>setTimeout(resolve,0));
  }
  if(layout!==documentLayout)return prepareForPrint();
  findTextIndex=null;lastAnnotationSignature='';paintAnnotations();if($('find-input').value)updateFind();
  return true;
}
function highlightNearbyCode(){
  codeFrame=0;
  const remaining=80-(performance.now()-lastReaderScroll);
  if(remaining>0){codeFrame=setTimeout(highlightNearbyCode,remaining);return;}
  if(editing||composer||!window.getSelection()?.isCollapsed||$('find-input').value)return;
  let changed=false,annotationsChanged=false;
  const started=performance.now();
  for(const block of nearbyCode){
    if(!block.isConnected){nearbyCode.delete(block);continue;}
    if(!block.hasAttribute('data-highlight-pending')){nearbyCode.delete(block);continue;}
    highlightCode(block);
    nearbyCode.delete(block);changed=true;
    annotationsChanged ||= state.feedback.some(item=>!item.resolved&&item.state==='attached'&&item.anchor.start<Number(block.dataset.blockEnd)&&item.anchor.end>Number(block.dataset.blockStart));
    // Yield between blocks so a fast scroll never drains a document-sized queue.
    if(performance.now()-started>6)break;
  }
  if(changed)findTextIndex=null;
  if(annotationsChanged){lastAnnotationSignature='';paintAnnotations();}
  if(nearbyCode.size)codeFrame=setTimeout(highlightNearbyCode,0);
}
function queueCodeHighlight(){if(!codeFrame&&nearbyCode.size)codeFrame=setTimeout(highlightNearbyCode,0);}
function observeCode(){
  codeObserver?.disconnect();nearbyCode.clear();
  codeObserver=new IntersectionObserver(entries=>{
    for(const entry of entries){if(entry.isIntersecting)nearbyCode.add(entry.target);else nearbyCode.delete(entry.target);}
    queueCodeHighlight();
  },{root:$('scroll-area'),rootMargin:'1000px 0px'});
  for(const block of $('document').querySelectorAll('[data-highlight-pending]'))codeObserver.observe(block);
}
document.addEventListener('selectionchange',queueCodeHighlight);

let mermaidLoading;
const diagramSources=new WeakMap();
function loadMermaid(){
  return mermaidLoading??=new Promise((resolve,reject)=>{
    const script=document.createElement('script');script.src='diagrams.js';
    script.onload=()=>resolve(window.mdrMermaid);
    script.onerror=()=>{mermaidLoading=null;script.remove();reject(new Error('The bundled diagram renderer could not load.'));};
    document.head.append(script);
  });
}
async function renderDiagrams(id){
  const nodes=[...$('document').querySelectorAll('.mermaid:not([data-processed])')];
  if(!nodes.length)return;
  try{
    const mermaid=await loadMermaid();
    if(id!==renderID)return;
    const dark=document.documentElement.dataset.theme==='dark';
    mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,maxTextSize:100000,
      theme:'base',fontFamily:'-apple-system, Helvetica Neue, sans-serif',
      themeVariables:{primaryColor:dark?'#343f30':'#edf0e7',primaryTextColor:dark?'#d8e2d1':'#46503f',primaryBorderColor:dark?'#697d5d':'#bac5ac',lineColor:dark?'#88927f':'#a4ac9a',secondaryColor:dark?'#2c2e29':'#f8f7f0',tertiaryColor:dark?'#262824':'#f6f5ee',fontSize:'12px'},
      flowchart:{htmlLabels:false,curve:'basis',padding:15,nodeSpacing:25,rankSpacing:30}});
    for(const node of nodes){
      if(id!==renderID)return;
      const original=diagramSources.get(node)??node.textContent;diagramSources.set(node,original);
      try{await mermaid.run({nodes:[node]});}
      catch(error){node.className='diagram-error';node.textContent=`This diagram couldn’t be rendered.\n\n${original}`;node.title=String(error);}
    }
    findTextIndex=null;if($('find-input').value)updateFind();scheduleOverview(true);
  }catch(error){for(const node of nodes){node.classList.add('diagram-error');node.title=String(error);}}
}

async function loadImages(){
  if(!native)return;
  for(const placeholder of $('document').querySelectorAll('[data-image]')){
    const path=placeholder.dataset.image;
    try{
      const result=await host('image',{path});
      if(result.dataURL&&placeholder.isConnected){const img=document.createElement('img');img.src=result.dataURL;img.alt=placeholder.getAttribute('aria-label');img.loading='lazy';img.onload=()=>scheduleOverview(true);placeholder.replaceWith(img);}
    }catch{/* Keep a useful caption when a referenced image is unavailable. */}
  }
}

function renderTOC(){
  $('toc').innerHTML=headings.map(h=>`<a class="toc-link depth-${h.level}" href="#${h.id}" data-section="${h.id}" title="${esc(h.text)}">${esc(h.text)}</a>`).join('') || '<div class="feedback-empty"><span>No headings yet.<br>Just room for words.</span></div>';
  tocLinks=new Map([...$('toc').querySelectorAll('a')].map(a=>[a.dataset.section,a]));activeHeading=null;
  $('toc').querySelectorAll('a').forEach(a=>a.addEventListener('click',e=>{e.preventDefault();$(a.dataset.section)?.scrollIntoView({block:'start',behavior:'smooth'});}));
}

function navigateToHeading(fragment){
  const jump=++headingJump;
  const heading=headings.find(h=>h.slug===fragment)??headings.find(h=>h.id===fragment);
  if(fragment&&!heading){toast(`Heading not found: ${fragment}`);return;}
  const scroll=()=>{if(fragment)$(heading.id)?.scrollIntoView({block:'start',behavior:'instant'});else $('scroll-area').scrollTop=0;};
  scroll();
  // Diagrams can change the heading's position after the initial document render.
  documentLayout.then(()=>{if(jump===headingJump)scroll();});
}
for(const type of ['wheel','pointerdown','keydown'])document.addEventListener(type,()=>headingJump++,{passive:true,capture:true});

function updateProgressMeasured(){
  const scroll=$('scroll-area'),height=scroll.scrollHeight,view=scroll.clientHeight,top=scroll.scrollTop;
  const max=height-view,progress=max>0?Math.round(top/max*100):100,track=$('minimap-track').clientHeight;
  const label=`${Math.min(100,Math.max(0,progress))}%`;
  if($('progress-number').textContent!==label)$('progress-number').textContent=label;
  $('minimap-viewport').style.transform=`translateY(${height?top/height*track:0}px)`;
  $('minimap-viewport').style.height=`${Math.max(8,height?view/height*track:0)}px`;
  const index=Math.max(0,lowerBound(headingOffsets,top+110,item=>item.top)-1);
  const active=headingOffsets[index]?.id;
  if(active!==activeHeading){tocLinks.get(activeHeading)?.classList.remove('active');tocLinks.get(active)?.classList.add('active');activeHeading=active;}
}

function drawMinimapMeasured(){
  const canvas=$('minimap-canvas'),track=$('minimap-track'),scroll=$('scroll-area');
  const width=track.clientWidth,height=track.clientHeight;
  if(!width||!height)return;
  const dpr=window.devicePixelRatio||1;canvas.width=width*dpr;canvas.height=height*dpr;
  const ctx=canvas.getContext('2d');ctx.scale(dpr,dpr);
  const styles=getComputedStyle(document.documentElement),color=styles.getPropertyValue('--muted'),accent=styles.getPropertyValue('--accent');
  if(geometryDirty){
    const areaTop=scroll.getBoundingClientRect().top,scrollTop=scroll.scrollTop;
    const blocks=[...$('document').children].flatMap(el=>el.classList.contains('print-lead')?[...el.children]:[el]);
    overviewGeometry=blocks.map(element=>{const rect=element.getBoundingClientRect();return {element,top:rect.top-areaTop+scrollTop,height:rect.height,length:element.textContent.length};});
    headingOffsets=headings.map(heading=>({id:heading.id,top:$(heading.id).getBoundingClientRect().top-areaTop+scrollTop}));
    geometryDirty=false;
  }
  const scaleY=height/scroll.scrollHeight;
  for(const {element,top:offset,height:blockHeight,length:textLength} of overviewGeometry){
    const top=offset*scaleY,h=Math.max(2,blockHeight*scaleY);
    if(/^H[1-6]$/.test(element.tagName)){ctx.fillStyle=accent;ctx.globalAlpha=.5;ctx.fillRect(10,top,Math.min(width-18,Math.max(18,textLength*1.6)),2.5);}
    else if(element.matches('figure,.code-block,table')){ctx.fillStyle=color;ctx.globalAlpha=.13;ctx.fillRect(10,top,width-18,h);ctx.globalAlpha=.25;ctx.strokeStyle=color;ctx.strokeRect(10,top,width-18,h);}
    else{
      ctx.fillStyle=color;ctx.globalAlpha=.25;
      const lines=Math.max(1,Math.round(blockHeight/32)),gap=Math.max(2,h/lines);
      for(let i=0;i<lines;i++){const last=i===lines-1;const length=last?Math.max(14,(textLength%70)/70*(width-18)):width-18;ctx.fillRect(10,top+i*gap,length,1);}
    }
    if(element.hasAttribute('data-has-feedback')){ctx.fillStyle=accent;ctx.globalAlpha=.8;ctx.beginPath();ctx.arc(3,top+2,1.5,0,Math.PI*2);ctx.fill();}
  }
  ctx.globalAlpha=1;updateProgress();
  // An incoming reply or delayed resize must not dismiss an active selection.
  if(!$('selection-menu').hidden)captureSelection();
}

function moveMinimap(event){const box=$('minimap-track').getBoundingClientRect();const y=Math.max(0,Math.min(box.height,event.clientY-box.top));$('scroll-area').scrollTop=y/box.height*$('scroll-area').scrollHeight-$('scroll-area').clientHeight/2;}
$('minimap-track').addEventListener('pointerdown',event=>{moveMinimap(event);$('minimap-track').setPointerCapture(event.pointerId);});
$('minimap-track').addEventListener('pointermove',event=>{if($('minimap-track').hasPointerCapture(event.pointerId))moveMinimap(event);});
$('scroll-area').addEventListener('scroll',()=>{
  lastReaderScroll=performance.now();
  if(!progressFrame)progressFrame=requestAnimationFrame(()=>{progressFrame=0;updateProgress();});
  $('selection-menu').hidden=true;
},{passive:true});
const layoutObserver=new ResizeObserver(()=>scheduleOverview(true));
layoutObserver.observe($('scroll-area'));layoutObserver.observe($('document').parentElement);

function mappedSelectionMeasured(){
  const selected=window.getSelection();
  if(!selected?.rangeCount||selected.isCollapsed)return null;
  const range=selected.getRangeAt(0);
  if(!$('document').contains(range.startContainer)||!$('document').contains(range.endContainer))return null;
  const startElement=range.startContainer.nodeType===1?range.startContainer:range.startContainer.parentElement;
  const endElement=range.endContainer.nodeType===1?range.endContainer:range.endContainer.parentElement;
  const startSpan=startElement.closest('[data-src-start]'),endSpan=endElement.closest('[data-src-start]');
  const common=range.commonAncestorContainer.nodeType===1?range.commonAncestorContainer:range.commonAncestorContainer.parentElement;
  const spans=startSpan&&endSpan?[startSpan,endSpan]:[...(common.matches('[data-src-start]')?[common]:common.querySelectorAll('[data-src-start]'))].filter(span=>range.intersectsNode(span));
  if(!spans.length){
    const startEl=range.startContainer.nodeType===1?range.startContainer:range.startContainer.parentElement;
    const block=startEl.closest('[data-block-start]');
    if(block&&block.contains(range.endContainer))return {start:Number(block.dataset.blockStart),end:Number(block.dataset.blockEnd),text:selected.toString(),rect:range.getBoundingClientRect(),range:range.cloneRange()};
    return null;
  }
  const first=spans[0],last=spans.at(-1);
  const insideOffset=(span,node,offset,fallback)=>{
    if(!span.contains(node))return fallback;
    const r=document.createRange();r.selectNodeContents(span);r.setEnd(node,offset);return r.toString().length;
  };
  const start=sourceBoundary(first,insideOffset(first,range.startContainer,range.startOffset,0));
  const end=sourceBoundary(last,insideOffset(last,range.endContainer,range.endOffset,last.textContent.length),true);
  if(end<=start)return null;
  return {start,end,text:selected.toString(),rect:range.getBoundingClientRect(),range:range.cloneRange()};
}

function captureSelection(){
  if(editing||composer)return;
  const found=mappedSelection();
  if(!found){$('selection-menu').hidden=true;return;}
  selection=found;
  if(reattachID){safeRun(async()=>{await host('reattach',{id:reattachID,...anchorPayload(found)});reattachID=null;notice('');toast('Feedback reattached. Original provenance preserved.');})();return;}
  const menu=$('selection-menu');menu.hidden=false;
  menu.style.left=`${Math.max(12,Math.min(innerWidth-menu.offsetWidth-12,found.rect.left+(found.rect.width-menu.offsetWidth)/2))}px`;
  menu.style.top=`${Math.max(68,found.rect.top-menu.offsetHeight-9)}px`;
}
$('document').addEventListener('mouseup',()=>setTimeout(captureSelection,0));
$('document').addEventListener('keyup',event=>{if(event.shiftKey)setTimeout(captureSelection,0);});
$('selection-menu').addEventListener('mousedown',e=>e.preventDefault());

function anchorPayload(anchor){return {start:anchor.start,end:anchor.end,exact:state.source.slice(anchor.start,anchor.end),sourceHash:state.revision.sha256};}
function ensureDocument(){if(state?.isWelcome){toast('Open a Markdown file with ⌘O to start reviewing.');return false;}return true;}

function beginDraft(kind,anchor,existing=null,thread=null){
  const payload=thread?{id:existing?.id??crypto.randomUUID(),threadID:thread.id,kind:'comment',editExisting:!!existing&&!existing.isDraft}:existing?{id:existing.id,kind:existing.kind,editExisting:!existing.isDraft,start:existing.originalAnchor.start,end:existing.originalAnchor.end,exact:existing.originalAnchor.exact,sourceHash:existing.createdAgainst.sha256}:{id:crypto.randomUUID(),kind,...anchorPayload(anchor)};
  draftSession=new FeedbackAutosave(payload,host,status=>{
    const text=status==='saved'?'Draft saved':status==='saving'?'Saving…':'Not saved · retry by typing';
    $('comment-autosave').textContent=text;$('edit-autosave').textContent=text;
    dirty(true,status==='saved');
  },{body:existing?.body??null,isDraft:existing?.isDraft??true,action:thread?'saveReply':'saveFeedback',discardAction:thread?'discardReply':'discardDraft'});
  $('comment-autosave').textContent=existing?'Draft saved':'Saves as you type';
  $('edit-autosave').textContent=existing?'Draft saved':'Saves as you type';dirty(true,true);
}
function openComment(existing=null,thread=null){
  if(editing||composer||!ensureDocument())return;
  if(!existing&&!thread){const current=mappedSelection();if(current)selection=current;}
  if(!existing&&!thread&&!selection){toast('Select a passage, then leave a comment.');return;}
  composer=true;$('selection-menu').hidden=true;$('composer').hidden=false;$('composer-error').hidden=true;
  $('composer-quote').textContent=thread?.body??existing?.originalAnchor.exact??selection.text;$('comment-text').value=existing?.body??'';
  $('save-comment').textContent=thread?'Post reply':existing?.kind==='suggestion'?'Post suggestion':'Post comment';
  document.querySelector('.composer-heading>span').textContent=thread?'Reply':existing?.kind==='suggestion'?'Suggestion':'Comment';
  $('composer-author').textContent=existing?.author??state.author;$('composer-avatar').textContent=initials(existing?.author??state.author);
  const box=selection?.rect??{right:innerWidth/2,bottom:innerHeight/3},pop=$('composer');
  pop.style.left=`${Math.max(15,Math.min(innerWidth-pop.offsetWidth-18,box.right-90))}px`;
  pop.style.top=`${Math.max(75,Math.min(innerHeight-pop.offsetHeight-48,box.bottom+12))}px`;
  beginDraft(existing?.kind??'comment',selection,existing,thread);$('comment-text').focus();
}
function endDraft(){draftSession=null;queueCodeHighlight();dirty(false);selection=null;window.getSelection()?.removeAllRanges();if(pendingState){const next=pendingState;pendingState=null;applyState(next);}else{paintAnnotations();}}
async function cancelComment(){if(!composer||draftSession.finishing)return;await draftSession.discard();composer=false;$('composer').hidden=true;endDraft();await host('reload');}
async function saveComment(){
  if(!composer||draftSession.finishing)return;
  if(draftSession.payload.kind==='comment'&&!$('comment-text').value.trim()){$('comment-text').focus();return;}
  const button=$('save-comment');button.disabled=true;button.textContent='Posting…';draftSession.finishing=true;$('comment-text').readOnly=true;
  try{await draftSession.save($('comment-text').value,false);composer=false;$('composer').hidden=true;endDraft();toggleFeedback(true);toast('Feedback posted.');}
  catch(error){$('composer-error').textContent=error.message;$('composer-error').hidden=false;}
  finally{if(draftSession)draftSession.finishing=false;$('comment-text').readOnly=false;button.disabled=false;button.textContent=draftSession?.payload.threadID?'Post reply':draftSession?.payload.kind==='suggestion'?'Post suggestion':'Post comment';}
}
$('comment-text').addEventListener('input',()=>{
  if(!draftSession||draftSession.finishing)return;
  draftSession.save($('comment-text').value).catch(error=>{$('composer-error').textContent=error.message;$('composer-error').hidden=false;});
});

function setMode(value){
  if(editing){toast('Save or discard this suggestion first.');return;}
  if(composer){toast('Save or cancel your comment first.');return;}
  mode=value;document.body.classList.toggle('suggesting',mode==='suggest');$('read-mode').classList.toggle('active',mode==='read');$('suggest-mode').classList.toggle('active',mode==='suggest');$('suggest-hint').hidden=mode!=='suggest';$('status-hint').textContent=mode==='suggest'?'Click a paragraph and make it better':'Select any text to leave a thought';$('selection-menu').hidden=true;
}
function startEditing(element){
  if(editing||composer||!element?.hasAttribute('data-edit-start')||!ensureDocument())return;
  const start=Number(element.dataset.editStart),end=Number(element.dataset.editEnd);
  editing={element,start,end,html:element.innerHTML,text:element.textContent,original:state.source.slice(start,end),isCode:element.dataset.codeEditor==='true'};
  if(editing.isCode){
    const input=document.createElement('textarea');input.className='code-editor';input.value=editing.text;input.spellcheck=false;input.setAttribute('aria-label','Suggested code');input.rows=Math.max(6,Math.min(25,editing.text.split('\n').length));
    element.hidden=true;element.after(input);editing.input=input;input.focus();input.setSelectionRange(input.value.length,input.value.length);
  }else{element.contentEditable='true';element.spellcheck=true;element.focus();}
  document.body.classList.add('editing');$('edit-bar').hidden=false;$('selection-menu').hidden=true;beginDraft('suggestion',editing);
  // Preserve a mouse-selected caret where possible; keyboard starts at the end.
  if(!editing.isCode){const selected=window.getSelection();if(!selected?.rangeCount||!element.contains(selected.anchorNode)){const r=document.createRange();r.selectNodeContents(element);r.collapse(false);selected.removeAllRanges();selected.addRange(r);}}
}
function restoreEdit(edit){edit.input?.remove();edit.element.hidden=false;edit.element.innerHTML=edit.html;edit.element.removeAttribute('contenteditable');rebuildSourceIndex();if($('find-input').value)updateFind();}
async function cancelEdit(){if(!editing||draftSession.finishing)return;await draftSession.discard();restoreEdit(editing);editing=null;document.body.classList.remove('editing');$('edit-bar').hidden=true;endDraft();await host('reload');}
function replacementForEdit(edit){
  let replacement=edit.isCode?edit.input.value:turndown.turndown(edit.element.innerHTML);
  if(edit.isCode&&replacement&&edit.original.endsWith('\n')&&!replacement.endsWith('\n'))replacement+='\n';
  const sourceLine=state.source.slice(state.source.lastIndexOf('\n',edit.start-1)+1,edit.start);
  if(edit.isCode&&sourceLine)replacement=replacement.replace(/\n(?!$)/g,'\n'+sourceLine);
  else if(/^\s*>/.test(sourceLine))replacement=replacement.replace(/\n/g,'\n'+sourceLine.replace(/(?:[-*+] |\d+\. )$/,''));
  else if(/^\s*(?:[-*+] |\d+\. )/.test(sourceLine))replacement=replacement.replace(/\n/g,'\n'+' '.repeat(sourceLine.length));
  if(edit.element.matches('td,th'))replacement=replacement.replace(/\|/g,'\\|').replace(/\n/g,' ');
  if(state.source.includes('\r\n'))replacement=replacement.replace(/\r?\n/g,'\r\n');
  return replacement;
}
async function saveEdit(){
  if(!editing||draftSession.finishing)return;
  const edit=editing;
  if(edit.isCode?edit.input.value===edit.text:edit.element.innerHTML===edit.html){await cancelEdit();toast('No changes to suggest.');return;}
  const replacement=replacementForEdit(edit);
  const button=$('save-edit');button.disabled=true;button.textContent='Saving…';
  try{
    draftSession.finishing=true;if(edit.isCode)edit.input.readOnly=true;else edit.element.contentEditable='false';await draftSession.save(replacement,false);
    restoreEdit(edit);editing=null;document.body.classList.remove('editing');$('edit-bar').hidden=true;endDraft();toggleFeedback(true);toast('Suggestion saved. Original untouched.');
  }catch(error){notice(error.message,true);}
  finally{if(draftSession)draftSession.finishing=false;if(editing){if(edit.isCode)edit.input.readOnly=false;else edit.element.contentEditable='true';}button.disabled=false;button.textContent='Post suggestion';}
}
$('document').addEventListener('input',()=>{
  if(!editing||!draftSession||draftSession.finishing)return;
  draftSession.save(replacementForEdit(editing)).catch(error=>notice(error.message,true));
});
$('document').addEventListener('click',event=>{
  const wrap=event.target.closest('.wrap-code');if(wrap){const block=wrap.closest('.code-block');block.classList.toggle('code-wrapped');wrap.setAttribute('aria-pressed',String(block.classList.contains('code-wrapped')));scheduleOverview(true);return;}
  const expand=event.target.closest('.expand-code');if(expand){const block=expand.closest('.code-block');block.classList.toggle('code-expanded');const expanded=block.classList.contains('code-expanded');expand.textContent=expanded?'Close':'Expand';expand.setAttribute('aria-pressed',String(expanded));return;}
  const suggest=event.target.closest('.suggest-code');if(suggest){setMode('suggest');startEditing(suggest.closest('.code-block').querySelector('code'));return;}
  const copy=event.target.closest('.copy-code');if(copy){safeRun(async()=>{const block=copy.closest('.code-block');const text=block.querySelector('.code-editor')?.value??block.querySelector('code').textContent;if(native)await host('copyText',{text});else await navigator.clipboard.writeText(text);copy.textContent='Copied';setTimeout(()=>copy.textContent='Copy',1400);})();return;}
  const link=event.target.closest('a[href]');
  if(link){
    event.preventDefault();
    if(mode!=='suggest'){
      // .href resolves against the app's bundled HTML, not the Markdown file.
      safeRun(()=>host('openLink',{href:link.getAttribute('href')}))();
      return;
    }
  }
  const block=event.target.closest('[data-edit-start]');
  if(mode==='suggest'&&!editing&&window.getSelection()?.isCollapsed){startEditing(block);return;}
  const noted=event.target.closest('[data-feedback-ids]');
  if(noted&&!editing&&window.getSelection()?.isCollapsed){activeFeedback=noted.dataset.feedbackIds.split(',')[0];toggleFeedback(true);renderFeedback();paintAnnotations();$(activeFeedback)?.scrollIntoView({block:'nearest'});}
});
$('document').addEventListener('paste',event=>{if(editing&&!editing.isCode){event.preventDefault();document.execCommand('insertText',false,event.clipboardData.getData('text/plain'));}});
$('document').addEventListener('keydown',event=>{
  if(editing&&event.key==='Enter'&&!event.metaKey&&!event.ctrlKey){
    event.preventDefault();
    if(editing.isCode){const input=editing.input;const start=input.value.lastIndexOf('\n',input.selectionStart-1)+1;const indent=input.value.slice(start,input.selectionStart).match(/^\s*/)[0];input.setRangeText('\n'+indent,input.selectionStart,input.selectionEnd,'end');input.dispatchEvent(new Event('input',{bubbles:true}));}
    else document.execCommand('insertLineBreak');
  }
  if(editing?.isCode&&event.key==='Tab'){event.preventDefault();const input=editing.input;input.setRangeText('  ',input.selectionStart,input.selectionEnd,'end');input.dispatchEvent(new Event('input',{bubbles:true}));}
  if(!editing&&mode==='suggest'&&event.key==='Enter'){const element=event.target.closest('[data-edit-start]');if(element){event.preventDefault();startEditing(element);}}
});

function toggleFeedback(force){const open=force??$('feedback-panel').hidden;$('feedback-panel').hidden=!open;document.body.classList.toggle('has-feedback-panel',open);$('feedback-toggle').classList.toggle('active',open);scheduleOverview(true);}
function rangeForAnchor(anchor){
  const first=sourceSpans[lowerBound(sourceSpans,anchor.start+1,item=>item.end)]?.element;
  const last=sourceSpans[lowerBound(sourceSpans,anchor.end,item=>item.start)-1]?.element;
  if(!first||!last||Number(first.dataset.srcStart)>=anchor.end||Number(last.dataset.srcEnd)<=anchor.start)return null;
  const r=document.createRange();
  const locate=(span,offset,isEnd)=>{
    const walker=document.createTreeWalker(span,NodeFilter.SHOW_TEXT);let node=walker.nextNode();
    let remaining=span.dataset.atomic?(isEnd?span.textContent.length:0):Math.max(0,Math.min(span.textContent.length,offset-Number(span.dataset.srcStart)));
    while(node){if(remaining<=node.length)return [node,remaining];remaining-=node.length;node=walker.nextNode();}
    return [span,isEnd?span.childNodes.length:0];
  };
  try{r.setStart(...locate(first,anchor.start,false));r.setEnd(...locate(last,anchor.end,true));return r;}catch{return null;}
}
function blockForAnchor(anchor){
  let index=lowerBound(sourceBlocks,anchor.start+1,item=>item.start)-1;
  for(;index>=0&&blockMaxEnds[index]>=anchor.start;index--){const item=sourceBlocks[index];if(item.end>=anchor.start)return item.element;}
  return null;
}

function paintAnnotationsMeasured(){
  if(!state||editing)return;
  const signature=JSON.stringify([activeFeedback,state.feedback.map(x=>[x.id,x.resolved,x.state,x.kind,x.anchor.start,x.anchor.end])]);
  if(signature===lastAnnotationSignature)return;lastAnnotationSignature=signature;
  $('document').querySelectorAll('[data-has-feedback]').forEach(el=>{delete el.dataset.hasFeedback;delete el.dataset.feedbackIds;delete el.dataset.suggestion;});
  const all=[],active=[];
  for(const item of state.feedback.filter(x=>!x.resolved&&x.state==='attached')){
    const range=rangeForAnchor(item.anchor);if(range)all.push(range);if(item.id===activeFeedback&&range)active.push(range);
    const block=blockForAnchor(item.anchor);if(block){const ids=(block.dataset.feedbackIds?block.dataset.feedbackIds.split(','):[]).concat(item.id);block.dataset.feedbackIds=ids.join(',');block.dataset.hasFeedback=String(ids.length);if(item.kind==='suggestion')block.dataset.suggestion='true';}
  }
  if(window.CSS?.highlights){CSS.highlights.set('mdr-comments',new Highlight(...all));CSS.highlights.set('mdr-active',new Highlight(...active));}
  scheduleOverview();
}
function renderDocumentDates(value){
  const render=(id,raw,description)=>{
    const element=$(id),date=raw?new Date(raw):null,valid=date&&!Number.isNaN(date.getTime());
    element.parentElement.hidden=!valid;
    if(!valid)return false;
    element.dateTime=date.toISOString();
    element.textContent=new Intl.DateTimeFormat(undefined,{month:'short',day:'numeric',year:date.getFullYear()===new Date().getFullYear()?undefined:'numeric',hour:'numeric',minute:'2-digit'}).format(date);
    element.title=`${description}\n${new Intl.DateTimeFormat(undefined,{dateStyle:'full',timeStyle:'long'}).format(date)}`;
    return true;
  };
  const created=render('document-created',value.documentCreatedAt,'File creation date on this Mac. Copies or replacements may have a new creation date.');
  const updated=render('document-updated',value.revision?.modifiedAt,'Last modification of the source file.');
  $('document-dates').hidden=value.isWelcome||(!created&&!updated);
}
const feedbackDateFormatter=new Intl.DateTimeFormat(undefined,{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'});
const feedbackTimeFormatter=new Intl.DateTimeFormat(undefined,{hour:'numeric',minute:'2-digit'});
function formatTime(value){try{return feedbackTimeFormatter.format(new Date(value));}catch{return value;}}
function formatDate(value){try{return feedbackDateFormatter.format(new Date(value));}catch{return value;}}
function renderFeedbackMeasured(){
  const open=state.feedback.filter(x=>!x.resolved),resolved=state.feedback.filter(x=>x.resolved),visible=filter==='open'?open:resolved;
  $('feedback-count').textContent=open.length;$('filter-open').querySelector('span').textContent=open.length;$('filter-resolved').querySelector('span').textContent=resolved.length;
  $('filter-open').classList.toggle('active',filter==='open');$('filter-resolved').classList.toggle('active',filter==='resolved');
  $('panel-subtitle').textContent=open.length?`${open.length} ${open.length===1?'thought':'thoughts'} for the next draft`:'A conversation in the margins';
  $('save-status').textContent=state.hasSidecar?'Saved to .feedback.md':'Your source stays untouched';$('reveal-file').disabled=!state.hasSidecar;
  const list=$('feedback-list');
  if(!visible.length){const html=`<div class="feedback-empty">${icon('comment')}<strong>${filter==='resolved'?'A clean slate.':'Leave a little clarity.'}</strong><span>${filter==='resolved'?'Resolved notes will live here.':'Select a passage to leave a thought,<br>or suggest a better way to say it.'}</span></div>`;if(list.innerHTML!==html)list.innerHTML=html;return;}
  list.querySelector('.feedback-empty')?.remove();
  const existing=new Map([...list.children].map(card=>[card.id,card]));
  let position=list.firstElementChild;
  for(const item of visible){
    const html=feedbackCardHTML(item);let card=existing.get(item.id);
    existing.delete(item.id);
    if(!card||card._mdrHTML!==html){const template=document.createElement('template');template.innerHTML=html;const next=template.content.firstElementChild;next._mdrHTML=html;if(card){card.replaceWith(next);if(position===card)position=next;}card=next;}
    if(card!==position)list.insertBefore(card,position);
    position=card.nextElementSibling;
  }
  for(const card of existing.values())card.remove();
}
function feedbackCardHTML(item){return `<section id="${esc(item.id)}" class="feedback-card ${item.state==='conflict'?'conflict':''} ${activeFeedback===item.id?'active':''}" data-id="${esc(item.id)}"><div class="card-top"><span class="avatar">${esc(initials(item.author))}</span><span class="card-author">${esc(item.author)}</span><time class="card-time" title="${esc(formatDate(item.createdAt))}">${esc(formatTime(item.createdAt))}</time></div><div class="card-kind">${item.kind==='suggestion'?'Suggested change':'Comment'}${item.isDraft?'<span class="note-status">Draft</span>':item.addressed?'<span class="note-status addressed">Addressed by agent</span>':''}</div>${item.state==='conflict'?'<div class="conflict-label">Passage changed · needs a new anchor</div>':''}${item.kind==='comment'?`<blockquote class="card-quote">${esc(item.originalAnchor.exact)}</blockquote><div class="card-body">${esc(item.body)}</div>`:`<div class="suggestion-before">${esc(item.originalAnchor.exact)||'(insertion)'}</div><div class="suggestion-after">${esc(item.body)||'(delete this text)'}</div>`}${(item.replies??[]).map(reply=>`<div class="thread-reply" data-reply-id="${esc(reply.id)}"><div class="reply-meta"><strong>${esc(reply.author)}</strong><time title="${esc(reply.createdAt)}">${esc(formatDate(reply.createdAt))}</time></div><div class="reply-body">${esc(reply.body)}</div>${reply.isDraft?'<span class="edit-label">Draft</span>':reply.editedBy?`<span class="edit-label" title="${esc(reply.updatedAt)}">Edited by ${esc(reply.editedBy)}</span>`:''}<button class="reply-edit" data-action="edit-reply">${reply.isDraft?'Continue draft':'Edit'}</button><span class="card-revision" title="Source modified ${esc(reply.createdAgainst.modifiedAt)}">${esc(reply.createdAgainst.sha256.slice(0,8))}</span></div>`).join('')}${item.editedBy?`<div class="edit-label" title="${esc(item.updatedAt)}">Edited by ${esc(item.editedBy)}</div>`:''}<div class="card-bottom"><button data-action="reply">Reply</button>${item.isDraft?'<button data-action="resume">Continue draft</button>':'<button data-action="edit">Edit</button>'}<button data-action="resolve">${item.resolved?'↶ Reopen':'✓ Resolve'}</button>${item.state==='conflict'?'<button data-action="reattach">Reattach</button>':''}<button class="card-delete" data-action="delete">Delete</button></div><span class="card-revision" title="Created ${esc(item.createdAt)} · Source modified ${esc(item.createdAgainst.modifiedAt)} · SHA-256 ${esc(item.createdAgainst.sha256)}">${esc(formatDate(item.createdAt))} · ${esc(item.createdAgainst.sha256.slice(0,8))}</span></section>`;
}
$('feedback-list').addEventListener('click',safeRun(async event=>{
  const card=event.target.closest('[data-id]');if(!card)return;
  const item=state.feedback.find(x=>x.id===card.dataset.id);if(!item)return;
  const action=event.target.closest('[data-action]')?.dataset.action;
  if(['resume','edit','reply','edit-reply'].includes(action)){
    if(editing||composer){toast('Finish the current draft first.');return;}
    if(action==='reply')openComment(null,item);
    else if(action==='edit-reply'){const id=event.target.closest('[data-reply-id]')?.dataset.replyId;const reply=item.replies?.find(reply=>reply.id===id);if(reply)openComment(reply,item);}
    else openComment(item);
    return;
  }
  if(action==='reattach'){reattachID=item.id;notice('Select the passage this note should refer to. Press Escape to cancel.');return;}
  if(action==='delete'){
    const button=event.target.closest('button');if(button.dataset.confirm!=='true'){button.dataset.confirm='true';button.textContent='Delete note?';setTimeout(()=>{if(button.isConnected){delete button.dataset.confirm;button.textContent='Delete';}},3500);return;}
  }
  if(action){await host(action,{id:item.id});toast(action==='delete'?'Feedback deleted.':item.resolved?'Feedback reopened.':'Feedback resolved.');return;}
  activeFeedback=item.id;renderFeedback();paintAnnotations();
  if(item.state==='attached')blockForAnchor(item.anchor)?.scrollIntoView({behavior:'smooth',block:'center'});
}));

function toggleOutline(){document.body.classList.toggle('outline-hidden');scheduleOverview(true);}
async function exportPDF(print){
  if(editing||composer){toast('Save or cancel your current feedback before exporting.');return;}
  const button=$('export-pdf');if(button.disabled)return;button.disabled=true;
  try{await prepareForPrint();await host(print?'print':'exportPDF');}finally{button.disabled=false;}
}
function toggleSettings(){$('settings').hidden=!$('settings').hidden;if(!$('settings').hidden)$('reviewer-name').value=state.author;}
function applyTheme(){
  const effective=theme==='system'?(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'):theme;
  if(document.documentElement.dataset.theme!==effective)document.documentElement.dataset.theme=effective;
  document.querySelectorAll('.theme-options button').forEach(b=>b.classList.toggle('active',b.dataset.theme===theme));
}
function applySize(){document.documentElement.style.setProperty('--font-size',`${fontSize}px`);$('zoom-label').textContent=`${Math.round(fontSize/18*100)}%`;$('size-value').textContent=fontSize===18?'Comfortable':`${fontSize} px`;}
function zoom(delta){fontSize=delta===0?18:Math.max(14,Math.min(26,fontSize+delta));if(state)state.fontSize=fontSize;applySize();host('setPreference',{key:'fontSize',value:fontSize}).catch(()=>{});scheduleOverview(true);}
async function setTheme(value){
  if(editing||composer){toast('Finish your current draft before changing appearance.');return;}
  theme=value;if(state)state.theme=value;applyTheme();
  await host('setPreference',{key:'theme',value});
  for(const node of $('document').querySelectorAll('.mermaid')){const source=diagramSources.get(node);if(source!==undefined){node.textContent=source;node.removeAttribute('data-processed');}}
  documentLayout=renderDiagrams(++renderID);scheduleOverview();
}
matchMedia('(prefers-color-scheme: dark)').addEventListener('change',()=>{if(theme==='system')setTheme(theme);});

function toggleFind(){if($('find-bar').hidden){$('find-bar').hidden=false;$('find-input').focus();$('find-input').select();}else{$('find-input').focus();$('find-input').select();}}
function closeFind(){$('find-bar').hidden=true;$('find-input').value='';updateFind();queueCodeHighlight();}
function updateFindMeasured(){
  findMatches=[];const query=$('find-input').value.toLocaleLowerCase();
  if(query){
    if(!findTextIndex){
      const walker=document.createTreeWalker($('document'),NodeFilter.SHOW_ELEMENT|NodeFilter.SHOW_TEXT,{acceptNode:n=>n.nodeType===Node.TEXT_NODE?(n.length?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT):n.matches('.code-label,.diagram-label,svg')?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_SKIP});
      const nodes=[];let text='',node;
      while(node=walker.nextNode()){nodes.push({node,start:text.length});text+=node.textContent;}
      findTextIndex={nodes,text:text.toLocaleLowerCase()};
    }
    const {nodes,text:lowered}=findTextIndex;let cursor=0;
    while(cursor<lowered.length&&findMatches.length<1000){const start=lowered.indexOf(query,cursor);if(start<0)break;const end=start+query.length;const first=nodes[lowerBound(nodes,start+1,x=>x.start)-1],last=nodes[lowerBound(nodes,end,x=>x.start)-1];if(first&&last){const range=document.createRange();range.setStart(first.node,start-first.start);range.setEnd(last.node,Math.min(last.node.length,end-last.start));findMatches.push(range);}cursor=end;}

  }
  findIndex=Math.min(findIndex,Math.max(0,findMatches.length-1));paintFind();
}
function paintFind(){
  $('find-count').textContent=$('find-input').value?`${findMatches.length?findIndex+1:0} of ${findMatches.length}`:'';
  if(window.CSS?.highlights){CSS.highlights.set('mdr-find',new Highlight(...findMatches));CSS.highlights.set('mdr-find-current',new Highlight(...(findMatches[findIndex]?[findMatches[findIndex]]:[])));}
}
function nextFind(direction){if(!findMatches.length)return;findIndex=(findIndex+direction+findMatches.length)%findMatches.length;paintFind();const r=findMatches[findIndex];const node=r.startContainer.parentElement;node.scrollIntoView({block:'center',behavior:'smooth'});}

const handlers={
  'open-file':()=>host('open'),'open-small':()=>host('open'),'welcome-open':()=>host('open'),'outline-toggle':toggleOutline,'export-pdf':()=>exportPDF(false),
  'read-mode':()=>setMode('read'),'suggest-mode':()=>setMode('suggest'),'feedback-toggle':()=>toggleFeedback(),'feedback-close':()=>toggleFeedback(false),
  'comment-selection':()=>openComment(),'cancel-comment':cancelComment,'save-comment':saveComment,
  'suggest-selection':()=>{const element=selection?.range.startContainer.parentElement.closest('[data-edit-start]');if(!element){toast('Click a paragraph in Suggest mode to edit it.');return;}setMode('suggest');startEditing(element);},
  'cancel-edit':cancelEdit,'save-edit':saveEdit,'settings-toggle':toggleSettings,'settings-close':()=>{$('settings').hidden=true;},
  'save-name':async()=>{const value=$('reviewer-name').value.trim();await host('setAuthor',{value});state.author=value;$('settings-toggle').textContent=initials(value);$('composer-author').textContent=value;$('composer-avatar').textContent=initials(value);toast('Reviewer name saved.');},
  'filter-open':()=>{filter='open';renderFeedback();},'filter-resolved':()=>{filter='resolved';renderFeedback();},
  'reveal-file':()=>host('reveal'),'dismiss-notice':()=>notice(''),'zoom-in':()=>zoom(1),'zoom-out':()=>zoom(-1),'zoom-label':()=>zoom(0),
  'find-button':toggleFind,'find-close':closeFind,'find-prev':()=>nextFind(-1),'find-next':()=>nextFind(1)
};
for(const[id,handler]of Object.entries(handlers))$(id).addEventListener('click',safeRun(handler));
document.querySelectorAll('.theme-options button').forEach(button=>button.addEventListener('click',safeRun(()=>setTheme(button.dataset.theme))));
$('find-input').addEventListener('input',()=>{findIndex=0;updateFind();if(findMatches.length){findIndex=findMatches.length-1;nextFind(1);}});
$('find-input').addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();nextFind(e.shiftKey?-1:1);}});
document.addEventListener('keydown',event=>{
  const mod=event.metaKey||event.ctrlKey;
  if(event.key==='Escape'){
    if(composer)safeRun(cancelComment)();else if(editing)safeRun(cancelEdit)();else if(document.querySelector('.code-expanded')){document.querySelector('.code-expanded .expand-code').click();}else if(reattachID){reattachID=null;notice('');}else if(!$('settings').hidden)$('settings').hidden=true;else if(!$('find-bar').hidden)closeFind();else{$('selection-menu').hidden=true;selection=null;setMode('read');}return;
  }
  if(mod&&event.key==='Enter'){event.preventDefault();if(composer)safeRun(saveComment)();else if(editing)safeRun(saveEdit)();return;}
  if(mod&&event.key.toLowerCase()==='f'){event.preventDefault();toggleFind();}
  if(mod&&event.key.toLowerCase()==='m'&&event.altKey){event.preventDefault();openComment();}
});
document.addEventListener('mousedown',event=>{if(!event.target.closest('#settings,#settings-toggle'))$('settings').hidden=true;if(!event.target.closest('#selection-menu,#document'))$('selection-menu').hidden=true;});

// The standalone web preview is deliberately explicit about its in-memory behavior.
async function previewHost(action,data,id){
  if(action==='ready'){
    const source=await(await fetch('welcome.md')).text();
    const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(source));
    const hash=[...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');
    window.mdr.receive({source,revision:{sha256:hash,modifiedAt:new Date().toISOString(),byteLength:source.length},feedback:[],author:'You',fileName:'The mdr field guide',filePath:'',isWelcome:true,hasSidecar:false});
    notice('Web preview · Open the Mac app to review your own files.');
  }else if(action==='open')toast('Open mdr.app to choose a Markdown file.');
  else if(action==='openLink'){
    if(data.href.startsWith('#'))navigateToHeading(decodeURIComponent(data.href.slice(1)));
    else if(/^(https?:|mailto:)/i.test(data.href))window.open(data.href,'_blank','noopener');
    else toast('Open mdr.app to follow links to Markdown files.');
  }
  window.mdr.resolve(id,{ok:true});
}
host('ready').catch(error=>notice(error.message,true));

function applyState(...args){return measure('state',()=>applyStateMeasured(...args));}

function updateProgress(...args){return measure('scroll',()=>updateProgressMeasured(...args));}

function drawMinimap(...args){return measure('minimap',()=>drawMinimapMeasured(...args));}

function mappedSelection(...args){return measure('selection',()=>mappedSelectionMeasured(...args));}

function paintAnnotations(...args){return measure('annotations',()=>paintAnnotationsMeasured(...args));}

function renderFeedback(...args){return measure('feedback',()=>renderFeedbackMeasured(...args));}

function updateFind(...args){return measure('find',()=>updateFindMeasured(...args));}
