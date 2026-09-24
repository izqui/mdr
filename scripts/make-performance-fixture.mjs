import {mkdir,writeFile} from 'node:fs/promises';
import {dirname} from 'node:path';

const output=process.argv[2]??'work/performance/large-spec.md';
const sections=Number(process.argv[3]??80);
let text='# Harbor delivery platform — implementation review\n\nA fictional engineering spec for reviewing a large, code-heavy document in mdr. All names, endpoints, and data are invented.\n\n';
for(let i=1;i<=sections;i++){
  text+=`## ${i}. Reliable delivery partition\n\nPartition ${i} owns an independent queue. Requests must retain their idempotency key across retries, and acknowledgements must only advance after durable storage. Review the transaction boundary and the timeout policy below.\n\n### Request handling ${i}\n\n`;
  text+='```typescript\n';
  text+=`// Partition ${i}: preserve exact source mapping while reviewing code.\n`;
  text+=`export async function deliverPartition${i}(request: DeliveryRequest): Promise<Receipt> {\n`;
  for(let j=0;j<8;j++)text+=`  const attempt${j} = await queue.reserve({ partition: ${i}, key: request.key, timeout: ${1000+j*250} });\n  if (!attempt${j}.durable) throw new RetryableError("Reservation must be persisted before acknowledgement");\n  await journal.append({ kind: "reserved", sequence: ${j}, receipt: attempt${j}.id });\n`;
  text+='  return { accepted: true, key: request.key, committedAt: new Date().toISOString() };\n}\n```\n\n';
  text+='The agent should explain why repeated delivery cannot create a second receipt. A timeout is not proof of failure: the client checks the operation before retrying.\n\n';
  text+='```json\n'+JSON.stringify({partition:i,request:{id:`delivery-${String(i).padStart(4,'0')}`,mode:'durable',retry:{limit:5,backoffMs:[250,500,1000,2000,4000]}},response:{state:'accepted',deduplicated:false,links:{status:`/v1/partitions/${i}/deliveries/current`}}},null,2)+'\n```\n\n';
  text+='| Scenario | Expected behavior | Evidence |\n|---|---|---|\n| Duplicate request | Return original receipt | Stable key |\n| Worker timeout | Reconcile before retry | Journal sequence |\n| Agent update | Preserve reviewer context | Source hash |\n\n';
}
text+='## Final acceptance criteria\n\nEvery partition preserves the original receipt, comments stay anchored to the exact code, and the final section remains searchable and printable.\n';
await mkdir(dirname(output),{recursive:true});await writeFile(output,text);
console.log(JSON.stringify({output,bytes:Buffer.byteLength(text),sections,codeBlocks:sections*2,lines:text.split('\n').length}));
