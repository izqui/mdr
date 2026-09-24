import test from 'node:test';
import assert from 'node:assert/strict';
import {createMarkdown,renderMarkdown} from './markdown.mjs';

function texts(source){const r=renderMarkdown(createMarkdown(),source);return r.tokens.filter(t=>t.type==='inline').flatMap(t=>t.children).filter(t=>t.content&&['text','text_special','code_inline'].includes(t.type));}
test('rendered text spans point to exact Markdown, including repeated words and links',()=>{
  const source='# Title\n\nA **bright** idea and [bright](https://example.com/bright) again bright.';
  const tokens=texts(source);
  for(const t of tokens){assert.ok(t.meta.sourceStart!=null,JSON.stringify(t));assert.equal(source.slice(t.meta.sourceStart,t.meta.sourceEnd),t.content);}
  const bright=tokens.filter(t=>t.content==='bright');assert.equal(bright.length,2);assert.notEqual(bright[0].meta.sourceStart,bright[1].meta.sourceStart);
});
test('entities and escapes map atomically to their original source',()=>{
  const source='Fish &amp; chips and \\*stars\\*.';
  const tokens=texts(source),entity=tokens.find(t=>t.content==='&');
  assert.equal(source.slice(entity.meta.sourceStart,entity.meta.sourceEnd),'&amp;');assert.equal(entity.meta.atomic,true);
  const star=tokens.find(t=>t.content==='*');assert.equal(source.slice(star.meta.sourceStart,star.meta.sourceEnd),'\\*');
});
test('CRLF, emoji, nested lists and blockquote line prefixes retain offsets',()=>{
  const source='# 🪴 Café\r\n\r\n- A **small** item\r\n- Another item\r\n\r\n> Quiet words\r\n> on two lines.\r\n';
  for(const t of texts(source)){assert.ok(t.meta.sourceStart!=null,JSON.stringify(t));assert.equal(source.slice(t.meta.sourceStart,t.meta.sourceEnd),t.content);}
});
test('table cells with repeated content have different edit ranges',()=>{
  const source='| A | A |\n|---|---|\n| same | same |\n';
  const r=renderMarkdown(createMarkdown(),source);
  const cells=r.tokens.filter(t=>t.type==='td_open');
  assert.equal(cells.length,2);assert.notEqual(cells[0].attrGet('data-edit-start'),cells[1].attrGet('data-edit-start'));
  for(const c of cells)assert.equal(source.slice(Number(c.attrGet('data-edit-start')),Number(c.attrGet('data-edit-end'))),'same');
});
test('unsafe HTML stays text and Mermaid stays a strict rendering input',()=>{
  const source='<script>alert(1)</script>\n\n```mermaid\ngraph LR\n A-->B\n```';
  const {html}=renderMarkdown(createMarkdown(),source);assert.ok(!html.includes('<script>'));assert.ok(html.includes('class="mermaid"'));assert.ok(html.includes('A--&gt;B'));
});
test('inline code excludes delimiters from the selected text span',()=>{
  const source='Use `a ** b` in the code.';const code=texts(source).find(t=>t.type==='code_inline');
  assert.equal(source.slice(code.meta.sourceStart,code.meta.sourceEnd),'a ** b');
});
test('fenced code maps CRLF lines back to exact source and retains multiline highlighting',()=>{
  const source='# Code\r\n\r\n```typescript\r\n/* first\r\n   second */\r\nconst thing = "<hello>";\r\n```\r\n';
  const rendered=renderMarkdown(createMarkdown(),source),token=rendered.tokens.find(t=>t.type==='fence');
  assert.equal(token.meta.codeLines.length,3);
  assert.equal(source.slice(token.meta.codeLines[0].start,token.meta.codeLines[0].end),'/* first');
  assert.equal(source.slice(token.meta.codeLines[2].end,token.meta.codeLines[2].next),'\r\n');
  assert.match(rendered.html,/hljs-comment/);assert.match(rendered.html,/hljs-keyword/);assert.match(rendered.html,/&lt;hello&gt;/);
});
test('heading fragments use visible text and distinguish duplicates without shadowing app IDs',()=>{
  const {headings,html}=renderMarkdown(createMarkdown(),'# API **contract**\n\n## API `contract`\n\n## API contract-1\n\n## API contract\n\n## Café & [details](next.md)\n\n## Document\n');
  assert.deepEqual(headings.map(h=>h.slug),['api-contract','api-contract-1','api-contract-1-1','api-contract-2','café--details','document']);
  assert.match(html,/id="section-5"/);assert.ok(!html.includes('id="document"'));
});
