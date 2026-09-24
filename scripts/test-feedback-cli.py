#!/usr/bin/env python3
"""Exercise the actual CLI, concurrent writers, and watch streams on isolated fixtures."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

project = Path(__file__).resolve().parents[1]
binary = Path(os.environ.get('MDR_TEST_BINARY', project / '.build/debug/mdr'))
scratch = project / 'work/qa/cli'
scratch.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(dir=scratch))
source = root / 'Spec with spaces.md'
original = '# Spec\r\n\r\nCafé 🐈 stays intact.\r\n\r\nrepeat and repeat. aaa.\r\n'
source.write_bytes(original.encode())
sidecar = source.with_suffix('.feedback.md')
checks = []

def call(*args, body=None, success=True):
    result = subprocess.run([str(binary), '--feedback', *map(str, args)], input=body, text=True, capture_output=True, timeout=10)
    if success:
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    assert result.returncode != 0, result.stdout
    return result.stderr

def wait_for(test, message):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(.05)
    raise AssertionError(message)

def events(path):
    text = path.read_text()
    rows = text.splitlines()
    if rows and not text.endswith('\n'):
        rows.pop()
    return [json.loads(row) for row in rows if row.strip()]

def alter_note(identifier, mutation):
    text = sidecar.read_bytes().decode()
    a = text.index(f'<!-- mdr:note:{identifier}\n') + len(f'<!-- mdr:note:{identifier}\n')
    b = text.index(f'\n/mdr:note:{identifier} -->', a)
    note = json.loads(text[a:b]); mutation(note)
    encoded = json.dumps(note, ensure_ascii=False, indent=2).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    temporary = root / 'atomic.tmp'
    temporary.write_bytes((text[:a] + encoded + text[b:]).encode())
    temporary.replace(sidecar)

log = root / 'watch.ndjson'
with log.open('w') as output, (root / 'watch-errors.txt').open('w') as errors:
    watcher = subprocess.Popen([str(binary), '--feedback', 'watch', str(source)], stdout=output, stderr=errors)
    try:
        wait_for(lambda: events(log), 'Watcher did not start before the feedback file existed')
        assert events(log)[0]['event'] == 'waiting'
        identifier = str(uuid.uuid4())
        review = call('comment', source, '--author', 'Agent', '--quote', 'Café 🐈', '--note-id', identifier, '--body-file', '-', body='An agent-created comment.')
        first = review['feedback'][0]
        assert first['author'] == 'Agent' and first['anchor']['exact'] == 'Café 🐈'
        wait_for(lambda: any(event.get('review', {}).get('feedback') for event in events(log)), 'Watcher missed creation')
        assert call('comment', source, '--author', 'Agent', '--quote', 'Café 🐈', '--note-id', identifier, '--body-file', '-', body='An agent-created comment.')['feedback'] == review['feedback']
        assert 'ambiguous' in call('comment', source, '--author', 'Agent', '--quote', 'repeat', '--body-file', '-', body='Ambiguous', success=False)
        assert 'ambiguous' in call('comment', source, '--author', 'Agent', '--quote', 'aa', '--body-file', '-', body='Overlapping quote', success=False)
        checks.append('Agent-created comments, Unicode anchors, ambiguous-quote rejection, and retry-safe IDs')

        def add_reply(index):
            return call('reply', source, identifier, '--author', f'Agent {index}', '--reply-id', str(uuid.uuid4()), '--body-file', '-', body=f'Concurrent reply {index}')
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(add_reply, range(4)))
        review = call('show', sidecar)
        assert len(review['feedback'][0]['replies']) == 4
        checks.append('Four simultaneous CLI writers retain every reply')

        reply = review['feedback'][0]['replies'][0]
        review = call('edit', source, identifier, '--reply', reply['id'], '--author', 'Human', '--body-file', '-', body='Corrected reply.')
        edited = review['feedback'][0]['replies'][0]
        assert edited['id'] == reply['id'] and edited['author'] == reply['author'] and edited['createdAgainst'] == reply['createdAgainst'] and edited['editedBy'] == 'Human'
        review = call('edit', source, identifier, '--author', 'Human', '--body-file', '-', body='Corrected original comment.')
        assert review['feedback'][0]['author'] == first['author'] and review['feedback'][0]['originalAnchor'] == first['originalAnchor']
        assert len(review['feedback'][0]['replies']) == 4
        review = call('reply', source, identifier, '--author', 'Agent', '--body-file', '-', '--addressed', body='Done.')
        assert review['feedback'][0]['addressed'] and not review['feedback'][0]['resolved']
        assert call('resolve', source, identifier, '--author', 'Agent')['feedback'][0]['resolved']
        assert not call('reopen', source, identifier, '--author', 'Agent')['feedback'][0]['resolved']
        review = call('reply', source, identifier, '--author', 'Human', '--body-file', '-', body='One more clarification.')
        assert not review['feedback'][0]['addressed']
        checks.append('Comment and reply edits preserve authors and versions; status changes and follow-ups work')

        alter_note(identifier, lambda note: note.update(isDraft=True, draftBase=note['body']))
        wait_for(lambda: events(log)[-1].get('review', {}).get('feedback') == [], 'Default watcher exposed a draft')
        count = len(events(log))
        alter_note(identifier, lambda note: note.update(body='A draft keystroke.', updatedAt='2026-09-23T16:00:00.000Z'))
        time.sleep(.5)
        assert len(events(log)) == count, 'Draft keystrokes woke the default watcher'
        call('edit', source, identifier, '--author', 'Agent', '--body-file', '-', body='Overwrite active typing', success=False)
        alter_note(identifier, lambda note: (note.update(isDraft=False, body='Posted human correction.'), note.pop('draftBase', None)))
        wait_for(lambda: (events(log)[-1].get('review', {}).get('feedback') or [{}])[0].get('body') == 'Posted human correction.', 'Watcher missed publication')
        checks.append('Watch waits for creation, follows atomic edits, skips draft typing, and emits posted corrections')
    finally:
        watcher.terminate()
        watcher.wait(timeout=5)

assert source.read_bytes() == original.encode(), 'CLI review commands changed the source'
inspected = subprocess.run(['python3', str(project / 'scripts/inspect-feedback.py'), str(sidecar), '--json'], capture_output=True, text=True, check=True)
assert json.loads(inspected.stdout)['source'] == original
help_text = subprocess.check_output([str(binary), '--help'], text=True)
skill = subprocess.check_output([str(binary), '--skill'], text=True)
assert 'feedback comment' in help_text and 'feedback watch' in help_text
assert 'full participant' in skill and 'Portable feedback format v2' in skill
checks.append('Help, bundled agent guide, standalone inspector, and exact source preservation')
report = {'ok': True, 'checks': checks, 'fixture': str(source)}
(scratch / 'cli-report.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
