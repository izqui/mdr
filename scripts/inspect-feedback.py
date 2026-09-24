#!/usr/bin/env python3
"""Validate and inspect an mdr v1 or v2 sidecar without modifying any files."""
import argparse
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('file', type=Path)
parser.add_argument('--json', action='store_true', help='Emit metadata and reconstructed source')
args = parser.parse_args()
try:
    text = args.file.read_bytes().decode('utf-8')
    prefix = '<!-- mdr:review v2\n' if text.startswith('<!-- mdr:review v2\n') else '<!-- mdr:review v1\n'
    if not text.startswith(prefix):
        raise ValueError('Not an mdr review')
    header, body = text[len(prefix):].split('\n-->\n\n<!-- mdr:body -->\n', 1)
    review = json.loads(header)
    if review['formatVersion'] not in (1, 2):
        raise ValueError('Unsupported review version')
    ids = set()
    notes = review.get('feedback', [{'id': identifier} for identifier in review.get('feedbackIDs', [])])
    for note in notes:
        identifier = note['id']
        if identifier in ids:
            raise ValueError('Duplicate note ID')
        ids.add(identifier)
        pattern = re.compile(r'<!-- mdr:note:' + re.escape(identifier) + r'\n(.*?)\n/mdr:note:' + re.escape(identifier) + r' -->', re.S)
        matches = list(pattern.finditer(body))
        if len(matches) != 1:
            raise ValueError(f'Missing or duplicate inline note: {identifier}')
        inline = json.loads(matches[0].group(1))
        if review['formatVersion'] == 1:
            field = 'comment' if note['kind'] == 'comment' else 'replacementMarkdown'
            if inline.get(field) != note['body'] or inline['sourceSHA256'] != note['createdAgainst']['sha256'] or inline['quote'] != note['originalAnchor']['exact']:
                raise ValueError(f'Inline note differs from metadata: {identifier}')
        else:
            if inline['id'] != identifier:
                raise ValueError('Inline ID differs from its marker')
            note.update(inline)
        body = body[:matches[0].start()] + body[matches[0].end():]
    review['feedback'] = notes
    if hashlib.sha256(body.encode('utf-8')).hexdigest() != review['revision']['sha256']:
        raise ValueError('Snapshot hash mismatch')
    if len(body.encode('utf-8')) != review['revision']['byteLength']:
        raise ValueError('Snapshot byte length mismatch')
    for note in review['feedback']:
        if note['state'] == 'attached':
            anchor = note['anchor']
            exact = body.encode('utf-16-le')[anchor['start'] * 2:anchor['end'] * 2].decode('utf-16-le')
            if exact != anchor['exact']:
                raise ValueError(f'Anchor mismatch: {note["id"]}')
    if args.json:
        print(json.dumps({**review, 'source': body}, ensure_ascii=False, indent=2))
    else:
        print(f'Source: {review["sourcePath"]}\nRevision: {review["revision"]["sha256"]}\nSnapshot verified: {len(body.encode("utf-8"))} bytes')
        for note in review['feedback']:
            status = 'draft' if note.get('isDraft') else 'resolved' if note['resolved'] else 'addressed' if note.get('addressed') else note['state']
            print(f'\n[{status}] {note["kind"]} by {note["author"]} at {note["createdAt"]}\nQuote: {note["originalAnchor"]["exact"]}\nFeedback: {note["body"]}')
            for reply in note.get('replies', []):
                print(f'  Reply by {reply["author"]} at {reply["createdAt"]}: {reply["body"]}')
except (KeyError, ValueError, UnicodeError, OSError) as error:
    parser.exit(1, f'mdr: {error}\n')
