import {test,expect} from '@playwright/test';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const source=await readFile(new URL('../../examples/quiet-workspace.md',import.meta.url),'utf8');
const hash=createHash('sha256').update(source).digest('hex');
const revision={sha256:hash,modifiedAt:'2026-09-23T12:00:00.000Z',byteLength:Buffer.byteLength(source)};

test.beforeEach(async({page})=>{
  await page.addInitScript(({source,revision})=>{
    window.testState={source,revision,feedback:[],author:'Maya',fileName:'quiet-workspace.md',filePath:'/specs/quiet-workspace.md',feedbackPath:'/specs/quiet-workspace.feedback.md',isWelcome:false,hasSidecar:false};
    window.testMessages=[];
    window.webkit={messageHandlers:{mdr:{postMessage(message){
      window.testMessages.push(message);
      const {action,requestId}=message;
      if(action==='dirty')return;
      setTimeout(()=>{
        if(action==='ready')window.mdr.receive(structuredClone(window.testState));
        if(action==='openLink'&&message.href.startsWith('#'))window.mdr.navigateToHeading(decodeURIComponent(message.href.slice(1)));
        if(action==='saveFeedback'){
          let item=window.testState.feedback.find(item=>item.id===message.id);
          if(item){if(!item.isDraft&&message.isDraft)item.draftBase=item.body;if(!message.isDraft){if(item.draftBase!==undefined||!item.isDraft)item.editedBy=window.testState.author;delete item.draftBase;}item.body=message.body;item.isDraft=message.isDraft;}
          else{
            const anchor={start:message.start,end:message.end,exact:message.exact,prefix:source.slice(Math.max(0,message.start-64),message.start),suffix:source.slice(message.end,message.end+64)};
            window.testState.feedback.push({id:message.id,kind:message.kind,body:message.body,isDraft:message.isDraft,addressed:false,replies:[],author:window.testState.author,createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),createdAgainst:revision,originalAnchor:anchor,anchor,state:'attached',resolved:false});
          }
          window.testState.hasSidecar=true;window.mdr.receive(structuredClone(window.testState));
        }
        if(action==='discardDraft'){
          const item=window.testState.feedback.find(item=>item.id===message.id);
          if(item?.draftBase!==undefined){item.body=item.draftBase;delete item.draftBase;item.isDraft=false;}
          else window.testState.feedback=window.testState.feedback.filter(item=>item.id!==message.id);
          window.mdr.receive(structuredClone(window.testState));
        }
        if(action==='saveReply'){
          const item=window.testState.feedback.find(item=>item.id===message.threadID);item.replies??=[];
          let reply=item.replies.find(reply=>reply.id===message.id);
          if(reply){if(!reply.isDraft&&message.isDraft)reply.draftBase=reply.body;if(!message.isDraft){if(reply.draftBase!==undefined||!reply.isDraft)reply.editedBy=window.testState.author;delete reply.draftBase;}reply.body=message.body;reply.isDraft=message.isDraft;reply.updatedAt=new Date().toISOString();}
          else item.replies.push({id:message.id,body:message.body,isDraft:message.isDraft,author:window.testState.author,createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),createdAgainst:revision});
          window.mdr.receive(structuredClone(window.testState));
        }
        if(action==='discardReply'){
          const item=window.testState.feedback.find(item=>item.id===message.threadID),reply=item.replies.find(reply=>reply.id===message.id);
          if(reply?.draftBase!==undefined){reply.body=reply.draftBase;delete reply.draftBase;reply.isDraft=false;}else item.replies=item.replies.filter(reply=>reply.id!==message.id);
          window.mdr.receive(structuredClone(window.testState));
        }
        if(action==='addFeedback'){
          const anchor={start:message.start,end:message.end,exact:message.exact,prefix:source.slice(Math.max(0,message.start-64),message.start),suffix:source.slice(message.end,message.end+64)};
          window.testState.feedback.push({id:crypto.randomUUID(),kind:message.kind,body:message.body,author:window.testState.author,createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),createdAgainst:revision,originalAnchor:anchor,anchor,state:'attached',resolved:false});
          window.testState.hasSidecar=true;window.mdr.receive(structuredClone(window.testState));
        }
        if(action==='resolve'){const item=window.testState.feedback.find(x=>x.id===message.id);item.resolved=!item.resolved;window.mdr.receive(structuredClone(window.testState));}
        if(action==='delete'){window.testState.feedback=window.testState.feedback.filter(x=>x.id!==message.id);window.mdr.receive(structuredClone(window.testState));}
        if(action==='setAuthor')window.testState.author=message.value;
        if(action==='setPreference')window.testState[message.key]=message.value;
        window.mdr.resolve(requestId,{ok:true});
      },10);
    }}}};
  },{source,revision});
  await page.goto('/');await expect(page.locator('#document h1')).toHaveText('A quieter workspace');
});

async function selectText(page,text){
  await page.evaluate(text=>{
    const walker=document.createTreeWalker(document.getElementById('document'),NodeFilter.SHOW_TEXT);let node;
    while(node=walker.nextNode()){const start=node.textContent.indexOf(text);if(start>=0){const range=document.createRange();range.setStart(node,start);range.setEnd(node,start+text.length);window.getSelection().removeAllRanges();window.getSelection().addRange(range);node.parentElement.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));return;}}
    throw new Error('Text not found: '+text);
  },text);
  await expect(page.locator('#selection-menu')).toBeVisible();
}

test('typing autosaves one recoverable draft and posting makes it ready for an agent',async({page})=>{
  await selectText(page,'projects');await page.locator('#comment-selection').click();
  await page.locator('#comment-text').fill('Please clarify how this works.');
  await expect(page.locator('#comment-autosave')).toHaveText('Draft saved');
  const id=await page.evaluate(()=>window.testState.feedback[0].id);
  expect(await page.evaluate(()=>window.testState.feedback[0].isDraft)).toBe(true);
  await page.locator('#comment-text').fill('Please clarify how nested projects work.');
  await expect.poll(()=>page.evaluate(()=>window.testState.feedback[0].body)).toBe('Please clarify how nested projects work.');
  await page.locator('#save-comment').click();await expect(page.locator('#composer')).toBeHidden();
  expect(await page.evaluate(()=>window.testState.feedback.map(x=>({id:x.id,isDraft:x.isDraft})))).toEqual([{id,isDraft:false}]);
});

test('agent replies appear while typing another draft and addressed notes stay open',async({page})=>{
  await selectText(page,'projects');await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('Clarify nesting.');await page.locator('#save-comment').click();
  await expect(page.locator('#composer')).toBeHidden();
  await selectText(page,'workspace');await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('Keep my live typing.');
  await expect(page.locator('#comment-autosave')).toHaveText('Draft saved');
  await page.evaluate(()=>{
    const item=window.testState.feedback[0];item.addressed=true;item.replies=[{id:'agent-reply',author:'Agent',body:'Added examples and clarified nesting.',createdAt:new Date().toISOString(),createdAgainst:window.testState.revision}];
    window.mdr.receive(structuredClone(window.testState));
  });
  await expect(page.locator('.reply-body')).toHaveText('Added examples and clarified nesting.');
  await expect(page.locator('.note-status.addressed')).toHaveText('Addressed by agent');
  await expect(page.locator('#comment-text')).toHaveValue('Keep my live typing.');
  await page.locator('#comment-text').fill('Keep my live typing and this addition.');
  await expect(page.locator('#comment-autosave')).toHaveText('Draft saved');
  expect(await page.evaluate(()=>window.testState.feedback[0].replies.length)).toBe(1);
  await page.locator('#cancel-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await expect(page.locator('.feedback-card')).toHaveCount(1);await expect(page.locator('.reply-body')).toBeVisible();
  await page.screenshot({path:'work/qa/live-replies.png'});
});

test('an incoming review refresh preserves the selected text and comment toolbar',async({page})=>{
  await selectText(page,'projects');
  // Same-source updates repaint annotations and the overview, like an agent reply.
  await page.evaluate(()=>window.mdr.receive(structuredClone(window.testState)));
  await expect(page.locator('#selection-menu')).toBeVisible();
  expect(await page.evaluate(()=>window.getSelection().toString())).toBe('projects');
  await page.locator('#comment-selection').click();
  await expect(page.locator('#composer-quote')).toHaveText('projects');
  await page.locator('#comment-text').fill('Keep the selected passage through a refresh.');
  await page.locator('#save-comment').click();
  await expect(page.locator('.card-quote')).toHaveText('projects');
  expect(await page.evaluate(()=>window.testState.feedback[0].anchor.exact)).toBe('projects');
});

test('saved drafts can resume after the reader reloads',async({page})=>{
  await selectText(page,'projects');await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('An unfinished thought.');
  await expect(page.locator('#comment-autosave')).toHaveText('Draft saved');
  const saved=await page.evaluate(()=>window.testState);
  await page.reload();await expect(page.locator('#document h1')).toBeVisible();
  await page.evaluate(saved=>{window.testState=saved;window.mdr.receive(structuredClone(saved));},saved);
  await page.locator('#feedback-toggle').click();await page.locator('[data-action=resume]').click();
  await expect(page.locator('#comment-text')).toHaveValue('An unfinished thought.');
  await page.locator('#comment-text').fill('A finished thought.');await page.locator('#save-comment').click();
  await expect(page.locator('#composer')).toBeHidden();await expect(page.locator('.feedback-card')).toHaveCount(1);
  expect(await page.evaluate(()=>window.testState.feedback[0].isDraft)).toBe(false);
});

test('human threads support replies, comment edits, reply edits, and cancel restores posted text',async({page})=>{
  await selectText(page,'projects');await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('Original question.');await page.locator('#save-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await page.locator('[data-action=reply]').click();await page.locator('#comment-text').fill('A clarification below the question.');
  await expect(page.locator('#comment-autosave')).toHaveText('Draft saved');await page.locator('#save-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await expect(page.locator('.thread-reply')).toHaveCount(1);await expect(page.locator('.reply-body')).toHaveText('A clarification below the question.');
  await page.locator('[data-action=edit]').click();await page.locator('#cancel-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await expect(page.locator('.card-body')).toHaveText('Original question.');
  await page.locator('[data-action=edit]').click();await page.locator('#comment-text').fill('Cancel this text.');await expect(page.locator('#comment-autosave')).toHaveText('Draft saved');await page.locator('#cancel-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await expect(page.locator('.card-body')).toHaveText('Original question.');await expect(page.locator('.reply-body')).toHaveText('A clarification below the question.');
  await page.locator('[data-action=edit]').click();await page.locator('#comment-text').fill('Corrected question.');await page.locator('#save-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await expect(page.locator('.card-body')).toHaveText('Corrected question.');
  await page.locator('[data-action=edit-reply]').click();await page.locator('#comment-text').fill('Corrected clarification.');await page.locator('#save-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await expect(page.locator('.reply-body')).toHaveText('Corrected clarification.');await expect(page.locator('.thread-reply')).toHaveCount(1);
  expect(await page.evaluate(()=>window.testState.feedback[0].author)).toBe('Maya');
  expect(await page.evaluate(()=>window.testState.feedback[0].editedBy)).toBe('Maya');
  await page.screenshot({path:'work/qa/thread-editing.png'});
});

test('reading view, table of contents, Mermaid and minimap render',async({page})=>{
  await expect(page.locator('.mermaid svg')).toBeVisible();
  await expect(page.locator('#toc a')).toHaveCount(9);
  await page.screenshot({path:'work/qa/reader.png'});
  await page.locator('#toc a').filter({hasText:'Open questions'}).click();
  await expect(page.locator('#progress-number')).toHaveText('100%');
  expect(await page.locator('body').evaluate(el=>el.scrollWidth<=innerWidth)).toBeTruthy();
});
test('selected formatted text creates a comment and can be resolved',async({page})=>{
  await selectText(page,'projects');await page.locator('#comment-selection').click();
  await page.locator('#comment-text').fill('Can projects contain nested documents?');await page.locator('#save-comment').click();
  await expect(page.locator('.feedback-card')).toHaveCount(1);
  await expect(page.locator('.card-body')).toHaveText('Can projects contain nested documents?');
  expect(await page.evaluate(()=>window.testState.feedback[0].originalAnchor.exact)).toBe('projects');
  expect(await page.evaluate(()=>window.testState.source)).toBe(source);
  await page.screenshot({path:'work/qa/comment.png'});
  await page.locator('[data-action=resolve]').click();await expect(page.locator('.feedback-card')).toHaveCount(0);
  await page.locator('#filter-resolved').click();await expect(page.locator('.feedback-card')).toHaveCount(1);
});
test('WYSIWYG suggestion returns the paragraph to its original rendering',async({page})=>{
  await page.locator('#suggest-mode').click();
  const paragraph=page.locator('#document p').nth(1);const original=await paragraph.textContent();
  await paragraph.click();await expect(paragraph).toHaveAttribute('contenteditable','true');
  await paragraph.fill('A calmer home for documents, decisions, and thoughtful conversations.');
  await page.locator('#save-edit').click();
  await expect(page.locator('.suggestion-after')).toHaveText('A calmer home for documents, decisions, and thoughtful conversations.');
  await expect(paragraph).toHaveText(original);expect(await page.evaluate(()=>window.testState.source)).toBe(source);
  await page.screenshot({path:'work/qa/suggestion.png'});
});
test('external document updates keep an active draft intact',async({page})=>{
  await selectText(page,'workspace');await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('Keep this thought.');
  await expect(page.locator('#comment-autosave')).toHaveText('Draft saved');
  await page.evaluate(()=>{window.testState={...window.testState,source:'# Changed\n\nA new document.',revision:{...window.testState.revision,sha256:'new-hash'}};window.mdr.receive(structuredClone(window.testState));});
  await expect(page.locator('#comment-text')).toHaveValue('Keep this thought.');await expect(page.locator('#document h1')).toHaveText('A quieter workspace');
  await page.locator('#cancel-comment').click();await expect(page.locator('#document h1')).toHaveText('Changed');
});
test('dark appearance, find and constrained window sizes stay usable',async({page})=>{
  await page.locator('#settings-toggle').click();await page.locator('.theme-options [data-theme=dark]').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme','dark');await page.locator('#settings-close').click();
  await page.locator('#find-button').click();await page.locator('#find-input').fill('document');await expect(page.locator('#find-count')).toContainText('1 of');
  await page.locator('#find-close').click();await page.screenshot({path:'work/qa/dark.png'});
  await page.setViewportSize({width:800,height:650});await page.locator('#feedback-toggle').click();
  expect(await page.locator('body').evaluate(el=>el.scrollWidth<=innerWidth)).toBeTruthy();
  await page.screenshot({path:'work/qa/compact.png'});
});
test('canceling a suggestion removes its autosaved draft',async({page})=>{
  await page.locator('#suggest-mode').click();const p=page.locator('#document p').nth(1);const before=await p.textContent();await p.click();await p.fill('Discard me');await page.locator('#cancel-edit').click();
  await expect(p).toHaveText(before);expect(await page.evaluate(()=>window.testState.feedback.length)).toBe(0);
});

test('Markdown links pass the original relative URL to mdr and remain editable in Suggest mode',async({page})=>{
  const readerURL=page.url();
  await page.evaluate(()=>window.mdr.receive({...window.testState,source:'# Links\n\nRead [the linked spec](../design/Review%20flow.md#api-contract).',revision:{...window.testState.revision,sha256:'links'}}));
  const link=page.locator('#document a');
  await link.click();
  await expect.poll(()=>page.evaluate(()=>window.testMessages.filter(m=>m.action==='openLink').map(m=>m.href))).toEqual(['../design/Review%20flow.md#api-contract']);
  expect(page.url()).toBe(readerURL);
  await page.locator('#suggest-mode').click();await link.click();
  await expect(page.locator('#document p')).toHaveAttribute('contenteditable','true');
  expect(await page.evaluate(()=>window.testMessages.filter(m=>m.action==='openLink').length)).toBe(1);
  await page.locator('#cancel-edit').click();
});

test('same-document fragments find formatted and duplicate headings without navigating the browser',async({page})=>{
  const readerURL=page.url();
  await page.evaluate(()=>window.mdr.receive({...window.testState,source:'# Links\n\n[Jump](#api-contract-1)\n\n'+('A paragraph with some breathing room.\n\n'.repeat(25))+'## API **contract**\n\nFirst.\n\n'+('More details.\n\n'.repeat(20))+'## API `contract`\n\nSecond.\n\n[Top](#)\n\n'+('Room below.\n\n'.repeat(20)),revision:{...window.testState.revision,sha256:'anchors'}}));
  await page.locator('#document a').filter({hasText:'Jump'}).click();
  await expect.poll(()=>page.locator('#section-2').evaluate(el=>Math.abs(el.getBoundingClientRect().top-document.getElementById('scroll-area').getBoundingClientRect().top))).toBeLessThan(100);
  expect(page.url()).toBe(readerURL);
  await page.locator('#document a').filter({hasText:'Top'}).click();
  await expect.poll(()=>page.locator('#scroll-area').evaluate(el=>el.scrollTop)).toBe(0);
  await page.evaluate(()=>window.mdr.navigateToHeading('missing-heading'));
  await expect(page.locator('#toast')).toHaveText('Heading not found: missing-heading');
});

test('code has syntax colors, precise selections, wrapping and an expanded view',async({page})=>{
  const block=page.locator('.code-block').first();await block.scrollIntoViewIfNeeded();
  await expect(block.locator('.code-line')).toHaveCount(6);
  await expect(block.locator('.hljs-keyword').first()).toHaveText('type');
  await expect(block.locator('code')).toHaveText('type Review = {\n  author: string;\n  createdAt: string;\n  sourceVersion: string;\n  feedback: Comment | Suggestion;\n};\n');
  await block.locator('.wrap-code').click();await expect(block).toHaveClass(/code-wrapped/);
  await block.locator('.expand-code').click();await expect(block).toHaveClass(/code-expanded/);
  await page.screenshot({path:'work/qa/code-expanded.png'});
  await page.keyboard.press('Escape');await expect(block).not.toHaveClass(/code-expanded/);
  await selectText(page,'createdAt');await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('Use an ISO-8601 UTC timestamp.');await page.locator('#save-comment').click();
  await expect(page.locator('.feedback-card')).toHaveCount(1);
  expect(await page.evaluate(()=>window.testState.feedback[0].anchor.exact)).toBe('createdAt');
  await page.screenshot({path:'work/qa/code-review.png'});
});
test('code suggestions preserve literal punctuation and indentation',async({page})=>{
  const block=page.locator('.code-block').first();await block.scrollIntoViewIfNeeded();await block.locator('.suggest-code').click();
  const code=block.locator('.code-editor');await expect(code).toBeVisible();
  const replacement='type Review = {\n  sourceSHA256: string;\n  flags: string[];\n};\n';
  await code.fill(replacement);
  await page.locator('#save-edit').click();
  await expect(page.locator('.feedback-card')).toHaveCount(1);
  expect(await page.evaluate(()=>window.testState.feedback[0].body)).toBe(replacement);
  expect(await page.evaluate(()=>window.testState.feedback[0].anchor.exact)).toBe('type Review = {\n  author: string;\n  createdAt: string;\n  sourceVersion: string;\n  feedback: Comment | Suggestion;\n};\n');
  expect(await page.evaluate(()=>window.testState.source)).toBe(source);
});
test('export action reaches the native bridge and print layout excludes the app chrome',async({page})=>{
  await page.locator('#export-pdf').click();await expect.poll(()=>page.evaluate(()=>window.testMessages.some(x=>x.action==='exportPDF'))).toBeTruthy();
  await page.emulateMedia({media:'print'});await expect(page.locator('.toolbar')).toBeHidden();await expect(page.locator('.outline')).toBeHidden();await expect(page.locator('#document h1')).toBeVisible();
  expect(await page.locator('#scroll-area').evaluate(el=>getComputedStyle(el).overflow)).toBe('visible');
});

test('a long code review keeps deep selections, scrolling geometry and complete print output',async({page})=>{
  const large='# Code review\n\n'+Array.from({length:25},(_,block)=>
    `## Response ${block+1}\n\n\`\`\`json\n{\n`+
    Array.from({length:98},(_,line)=>`  "field_${block}_${line}": "${'value '.repeat(28)}"${line<97?',':''}`).join('\n')+
    '\n}\n```\n\n').join('');
  await page.evaluate(source=>{
    window.testState={...window.testState,source,revision:{...window.testState.revision,sha256:'large-code-review'}};
    window.mdr.receive(structuredClone(window.testState));
  },large);
  await expect(page.locator('.code-block')).toHaveCount(25);
  const first=page.locator('.code-block').first(),last=page.locator('.code-block').last();
  const height=await page.locator('#scroll-area').evaluate(el=>el.scrollHeight);
  await last.scrollIntoViewIfNeeded();
  expect(await last.locator('pre').evaluate(el=>el.scrollWidth>el.clientWidth)).toBe(true);
  await last.locator('.wrap-code').click();
  expect(await last.locator('pre').evaluate(el=>el.scrollWidth<=el.clientWidth+1)).toBe(true);
  await last.locator('.wrap-code').click();
  await last.locator('pre').evaluate(el=>{el.scrollTop=el.scrollHeight;});
  await selectText(page,'field_24_97');
  await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('Review this final field.');
  await page.locator('#save-comment').click();await expect(page.locator('#composer')).toBeHidden();
  const anchor=await page.evaluate(()=>window.testState.feedback[0].anchor);
  expect(large.slice(anchor.start,anchor.end)).toBe('field_24_97');
  await first.scrollIntoViewIfNeeded();
  expect(await page.locator('#scroll-area').evaluate(el=>el.scrollHeight)).toBe(height);
  await page.emulateMedia({media:'print'});
  const panes=await page.locator('.code-block pre').evaluateAll(elements=>elements.map(el=>({
    containment:getComputedStyle(el).contain,overflow:getComputedStyle(el).overflow,
    clipped:el.scrollHeight>el.clientHeight+1,lines:el.querySelectorAll('.code-line').length
  })));
  expect(panes).toHaveLength(25);
  for(const pane of panes)expect(pane).toEqual({containment:'none',overflow:'visible',clipped:false,lines:100});
});

test('offscreen code stays lightweight, selection survives highlighting, and print prepares every block',async({page})=>{
  const source='# Deferred code\n\n'+Array.from({length:35},(_,i)=>`## Block ${i}\n\n\`\`\`typescript\nconst unique_${i} = "hello";\nconst next_${i} = 42;\n\`\`\`\n\n`).join('');
  await page.evaluate(source=>{window.testState={...window.testState,source,feedback:[],revision:{...window.testState.revision,sha256:'deferred-code'}};window.mdr.receive(structuredClone(window.testState));},source);
  const last=page.locator('.code-block').last();
  await expect(last).toHaveAttribute('data-highlight-pending','true');
  await page.evaluate(async()=>{
    const span=document.querySelectorAll('.code-block')[34].querySelector('.code-source');
    const text=span.firstChild,range=document.createRange(),start=text.textContent.indexOf('unique_34');
    range.setStart(text,start);range.setEnd(text,start+'unique_34'.length);
    window.getSelection().removeAllRanges();window.getSelection().addRange(range);
    span.scrollIntoView({block:'center',behavior:'instant'});
    await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
    span.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));
  });
  await expect(page.locator('#selection-menu')).toBeVisible();
  expect(await page.evaluate(()=>window.getSelection().toString())).toBe('unique_34');
  await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('This exact identifier.');await page.locator('#save-comment').click();
  await expect(page.locator('#composer')).toBeHidden();
  const anchor=await page.evaluate(()=>window.testState.feedback[0].anchor);
  expect(source.slice(anchor.start,anchor.end)).toBe('unique_34');
  await expect(last).not.toHaveAttribute('data-highlight-pending');
  await page.locator('#find-button').click();await page.locator('#find-input').fill('unique_0');
  await page.evaluate(()=>window.mdr.prepareForPrint());
  expect(await page.evaluate(()=>[...CSS.highlights.get('mdr-find')].map(r=>r.toString()))).toEqual(['unique_0']);
  await expect(page.locator('[data-highlight-pending]')).toHaveCount(0);
  expect(await page.locator('.code-block code').last().textContent()).toBe('const unique_34 = "hello";\nconst next_34 = 42;\n');
  expect(await page.evaluate(()=>[...CSS.highlights.get('mdr-comments')].map(r=>r.toString()))).toContain('unique_34');
});

test('appearance and replies preserve document nodes, search matches, and unrelated comment cards',async({page})=>{
  await selectText(page,'projects');await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('First question.');await page.locator('#save-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await selectText(page,'workspace');await page.locator('#comment-selection').click();await page.locator('#comment-text').fill('Second question.');await page.locator('#save-comment').click();await expect(page.locator('#composer')).toBeHidden();
  await page.evaluate(()=>{window.retainedHeading=document.querySelector('#document h1');window.retainedCard=document.querySelector('.feedback-card');});
  await page.locator('#find-button').click();await page.locator('#find-input').fill('workspace');
  const found=await page.locator('#find-count').textContent();
  await page.evaluate(()=>{window.testState.feedback[1].body='Updated second question.';window.mdr.receive(structuredClone(window.testState));});
  expect(await page.evaluate(()=>window.retainedCard===document.querySelector('.feedback-card'))).toBe(true);
  await expect(page.locator('#find-count')).toHaveText(found);
  await page.locator('#settings-toggle').click();await page.locator('[data-theme="dark"]').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
  expect(await page.evaluate(()=>window.retainedHeading===document.querySelector('#document h1'))).toBe(true);
  await expect(page.locator('.mermaid svg')).toBeVisible();
});

test('discarding a suggestion restores live search ranges in the original paragraph',async({page})=>{
  await page.evaluate(()=>{window.testState={...window.testState,source:'# Search review\n\nA searchable passage.\n',feedback:[],revision:{...window.testState.revision,sha256:'search-restoration'}};window.mdr.receive(structuredClone(window.testState));});
  await page.locator('#find-button').click();await page.locator('#find-input').fill('searchable');
  await expect(page.locator('#find-count')).toHaveText('1 of 1');
  await page.locator('#suggest-mode').click();await page.locator('#document p').click();
  await page.locator('#document [contenteditable=true]').fill('A proposed passage.');
  await page.locator('#cancel-edit').click();await expect(page.locator('#edit-bar')).toBeHidden();
  expect(await page.evaluate(()=>[...CSS.highlights.get('mdr-find')].map(r=>({text:r.toString(),connected:r.startContainer.isConnected})))).toEqual([{text:'searchable',connected:true}]);
});
