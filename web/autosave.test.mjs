import test from 'node:test';
import assert from 'node:assert/strict';
import {FeedbackAutosave} from './autosave.mjs';

test('autosave serializes rapid typing, retains a stable ID, and posts the latest body',async()=>{
  const calls=[],waiters=[];
  const session=new FeedbackAutosave({id:'stable'},(action,data)=>{calls.push({action,data});return new Promise(resolve=>waiters.push(resolve));},()=>{});
  const first=session.save('A');session.save('AB');session.save('ABC');
  assert.equal(calls.length,1);waiters.shift()();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(calls[1].data.body,'ABC');assert.equal(calls[1].data.baseBody,'A');waiters.shift()();await first;
  const post=session.save('ABCD',false);assert.equal(calls[2].data.baseBody,'ABC');assert.equal(calls[2].data.isDraft,false);
  waiters.shift()();await post;assert.equal(session.savedBody,'ABCD');assert.ok(calls.every(c=>c.data.id==='stable'));
});

test('failed writes retain the last saved base and never discard the draft silently',async()=>{
  const statuses=[];let failure=true;
  const session=new FeedbackAutosave({id:'stable'},async()=>{if(failure)throw new Error('Concurrent text edit');},status=>statuses.push(status),{body:'Original'});
  await assert.rejects(session.save('Changed'),/Concurrent text edit/);
  assert.equal(session.savedBody,'Original');assert.equal(statuses.at(-1),'error');
  failure=false;await session.save('Retry');assert.equal(session.savedBody,'Retry');assert.equal(statuses.at(-1),'saved');
});
