import MarkdownIt from 'markdown-it';
import hljs from 'highlight.js/lib/common';
import dockerfile from 'highlight.js/lib/languages/dockerfile';
hljs.registerLanguage('dockerfile',dockerfile);

export const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

export function highlightedLines(code, language) {
  let html=escapeHTML(code);
  if(hljs.getLanguage(language)){
    try{html=hljs.highlight(code,{language,ignoreIllegals:true}).value;}catch{}
  }
  const lines=[''],stack=[];
  for(const chunk of html.split(/(<span\b[^>]*>|<\/span>|\n)/g)){
    if(chunk==='\n'){lines[lines.length-1]+='</span>'.repeat(stack.length);lines.push(stack.join(''));}
    else {lines[lines.length-1]+=chunk;if(chunk.startsWith('<span'))stack.push(chunk);else if(chunk==='</span>')stack.pop();}
  }
  return lines;
}

/** Preserve parser source positions before Markdown's formatting tokens disappear. */
export function createMarkdown() {
  const md = new MarkdownIt({html:false, linkify:false, typographer:false, breaks:false});
  md.inline.ruler2.disable('fragments_join');
  md.core.ruler.disable('text_join');
  const Base = md.inline.State;
  md.inline.State = class extends Base {
    pushPending() {
      const content = this.pending;
      const token = super.pushPending();
      const start = this.src.lastIndexOf(content, this.pos);
      token.meta = {localStart:start, localEnd:start + content.length};
      return token;
    }
    push(type, tag, nesting) {
      const token = super.push(type, tag, nesting);
      token.meta = {...token.meta, localStart:this.pos};
      return token;
    }
  };
  // The pinned parser exposes named rules; wrappers only record positions, never change parsing.
  for (const rule of [...md.inline.ruler.__rules__]) {
    const original = rule.fn;
    md.inline.ruler.at(rule.name, (state, silent) => {
      const count = state.tokens.length, start = state.pos;
      const result = original(state, silent);
      if (result && !silent) {
        for (let i=count; i<state.tokens.length; i++) {
          const token=state.tokens[i];
          if (token.meta?.localEnd == null) {
            token.meta={...token.meta, localEnd:state.pos};
            if (['emphasis','strikethrough'].includes(rule.name)) {
              token.meta.localStart=start+(i-count)*(rule.name==='strikethrough'?2:1);
              token.meta.localEnd=token.meta.localStart+token.content.length;
            }
          }
        }
      }
      return result;
    }, {alt:rule.alt});
  }
  const mappedText = (tokens, index) => {
    const t=tokens[index], text=escapeHTML(t.content), m=t.meta;
    if (!text) return '';
    if (m?.sourceStart == null) return text;
    return `<span data-src-start="${m.sourceStart}" data-src-end="${m.sourceEnd}"${m.atomic?' data-atomic="true"':''}>${text}</span>`;
  };
  md.renderer.rules.text = mappedText;
  md.renderer.rules.text_special = mappedText;
  md.renderer.rules.code_inline = (tokens, i) => `<code>${mappedText(tokens,i)}</code>`;
  md.renderer.rules.softbreak = (tokens, i) => tokens[i].meta?.sourceStart != null ? `<span data-src-start="${tokens[i].meta.sourceStart}" data-src-end="${tokens[i].meta.sourceEnd}">\n</span>` : '\n';
  md.renderer.rules.image = (tokens, i) => {
    const t=tokens[i], src=t.attrGet('src') || '';
    // Local files are requested through the native bridge; remote fetches remain opt-in links.
    return `<span class="image-placeholder" data-image="${escapeHTML(src)}" role="img" aria-label="${escapeHTML(t.content)}">${escapeHTML(t.content || 'Image')}<small>${escapeHTML(src)}</small></span>`;
  };
  md.renderer.rules.fence = (tokens, i) => {
    const t=tokens[i], language=t.info.trim().split(/\s/)[0];
    const sourceAttrs = t.meta ? ` data-block-start="${t.meta.start}" data-block-end="${t.meta.end}"` : '';
    if (language === 'mermaid') return `<figure class="diagram"${sourceAttrs}><div class="diagram-label">DIAGRAM <span>MERMAID</span></div><div class="mermaid">${escapeHTML(t.content)}</div></figure>`;
    const lines=highlightedLines(t.content,language),rawLines=t.content.split('\n');
    if(rawLines.at(-1)===''){rawLines.pop();lines.pop();}
    const count=rawLines.length;
    const body=lines.map((line,index)=>{
      const mapping=t.meta?.codeLines?.[index],last=index===lines.length-1;
      const attrs=mapping?` data-src-start="${mapping.start}" data-src-end="${mapping.end}"`:'';
      const newline=(!last||t.content.endsWith('\n'))?`<span${mapping?` data-src-start="${mapping.end}" data-src-end="${mapping.next}"${mapping.next-mapping.end!==1?' data-atomic="true"':''}`:''}>\n</span>`:'';
      return `<span class="code-line" data-line="${index+1}"><span class="code-source"${attrs}>${line}</span>${newline}</span>`;
    }).join('');
    const first=t.meta?.codeLines?.[0],last=t.meta?.codeLines?.at(-1);
    const editAttrs=first&&last?` data-edit-start="${first.start}" data-edit-end="${last.next}" data-code-editor="true" tabindex="0"`:'';
    return `<div class="code-block"${sourceAttrs}><div class="code-label"><span>${escapeHTML(language || 'TEXT')}<span class="code-line-count">${count} ${count===1?'line':'lines'}</span></span><div class="code-actions"><button class="suggest-code" title="Suggest a change to this code">Suggest</button><button class="wrap-code" aria-pressed="false" title="Wrap long lines">Wrap</button><button class="expand-code" aria-pressed="false" title="Expand code">Expand</button><button class="copy-code" aria-label="Copy code">Copy</button></div></div><pre><code${editAttrs}>${body}</code></pre></div>`;
  };
  return md;
}

/** Map normalized inline content back to the original bytes, including CRLF, lists and blockquotes. */
export function renderMarkdown(md, source) {
  const env={}, tokens=md.parse(source,env);
  const starts=[0];
  for(let i=0;i<source.length;i++) if(source[i]==='\n') starts.push(i+1);
  const lineEnd=line=>starts[line]??source.length;
  let currentMap=[0, starts.length], rowCursor=0, lastMapKey='';
  const headings=[],usedSlugs=new Set();
  for(let i=0;i<tokens.length;i++) {
    const token=tokens[i];
    if(token.map) {
      currentMap=token.map;
      token.meta={...token.meta,start:lineEnd(token.map[0]),end:lineEnd(token.map[1])};
      if(token.type==='fence'){
        const lines=token.content.split('\n');if(lines.at(-1)==='')lines.pop();
        token.meta.codeLines=lines.map((line,index)=>{
          const start=lineEnd(token.map[0]+1+index),end=lineEnd(token.map[0]+2+index);
          const found=source.indexOf(line,start);
          return found>=start&&found+line.length<=end?{start:found,end:found+line.length,next:end}:null;
        });
        if(token.meta.codeLines.some(x=>!x))token.meta.codeLines=[];
      }
      if(token.nesting===1 || ['fence','code_block'].includes(token.type)) {
        token.attrSet('data-block-start',String(token.meta.start));
        token.attrSet('data-block-end',String(token.meta.end));
      }
    }
    if(token.type!=='inline') continue;
    const map=token.map||currentMap;
    const key=map.join(':');
    if(key!==lastMapKey) rowCursor=lineEnd(map[0]);
    lastMapKey=key;
    const boundary=lineEnd(map[1]), mapping=[];
    let cursor=rowCursor, local=0;
    let valid=true;
    for(const line of token.content.split('\n')) {
      const found=source.indexOf(line,cursor);
      if(found<0 || found+line.length>boundary) {valid=false;break;}
      for(let c=0;c<line.length;c++) mapping[local+c]=found+c;
      local+=line.length;
      cursor=found+line.length;
      if(local<token.content.length) {
        const newline=source.indexOf('\n',cursor);
        if(newline<0 || newline>=boundary){valid=false;break;}
        mapping[local++]=newline;
        cursor=newline+1;
      }
    }
    mapping[token.content.length]=cursor;
    rowCursor=cursor;
    if(valid) {
      for(const child of token.children||[]) {
        const m=child.meta;
        if(!m || m.localStart<0 || m.localEnd==null) continue;
        let a=m.localStart,b=m.localEnd;
        if(child.type==='code_inline') {
          const raw=token.content.slice(a,b), inner=raw.indexOf(child.content);
          if(inner>=0) {a+=inner;b=a+child.content.length;}
        }
        if(mapping[a]==null || mapping[b-1]==null) continue;
        m.sourceStart=mapping[a];m.sourceEnd=mapping[b-1]+1;
        m.atomic=source.slice(m.sourceStart,m.sourceEnd)!==child.content;
      }
      const open=tokens[i-1];
      if(open?.nesting===1 && ['p','h1','h2','h3','h4','h5','h6','td','th'].includes(open.tag) && token.content) {
        open.hidden=false;
        if(tokens[i+1]) tokens[i+1].hidden=false;
        open.attrSet('data-edit-start',String(mapping[0]));
        open.attrSet('data-edit-end',String(mapping[token.content.length-1]+1));
        open.attrSet('tabindex','0');
      }
    }
    if(tokens[i-1]?.type==='heading_open') {
      const heading=tokens[i-1], id=`section-${headings.length}`;
      heading.attrSet('id',id);
      const text=token.children.filter(c=>['text','text_special','code_inline','image'].includes(c.type)).map(c=>c.content).join('');
      const base=text.toLowerCase().replace(/[^\p{L}\p{N}\p{M}\s_-]/gu,'').replace(/\s/g,'-');
      let slug=base,suffix=0;
      while(usedSlugs.has(slug))slug=`${base}-${++suffix}`;
      usedSlugs.add(slug);
      // Keep DOM IDs separate so headings like "document" cannot shadow app controls.
      headings.push({id,slug,level:Number(heading.tag.slice(1)),text,start:heading.meta.start});
    }
  }
  return {html:md.renderer.render(tokens,md.options,env),headings,tokens};
}

export function sourceBoundary(span, textOffset, end=false) {
  const start=Number(span.dataset.srcStart), finish=Number(span.dataset.srcEnd);
  if(span.dataset.atomic) return textOffset===0 ? start : (end || textOffset===span.textContent.length ? finish : start);
  return Math.min(finish,start+textOffset);
}
