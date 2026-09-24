#!/usr/bin/env python3
"""Run the packaged app's commands from an unrelated directory, without a checkout."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
scratch = project / 'work/qa/distribution'
scratch.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="Mac with spaces ' and $ ", dir=scratch))
app = root / 'Applications/mdr.app'
subprocess.run(['ditto', str(project / 'dist/mdr.app'), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['lipo', str(app / 'Contents/MacOS/mdr'), '-verify_arch', 'arm64', 'x86_64'], check=True)
binary = app / 'Contents/MacOS/mdr'

def run(command, *arguments, success=True, input=None):
    result = subprocess.run([str(command), *map(str, arguments)], cwd=root,
                            input=input, text=True, capture_output=True, timeout=15)
    assert (result.returncode == 0) == success, (result.stdout, result.stderr)
    return result.stdout

info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == json.loads((project / 'package.json').read_text())['version']
assert 'mdr feedback watch' in run(binary, '--help')
guide = run(binary, '--skill')
assert guide.strip() == (project / 'AGENT-REVIEW.md').read_text().strip()
command_dir = root / 'local bin'
run(binary, '--install-cli', command_dir)
command = command_dir / 'mdr'
assert command.is_symlink()
assert 'mdr feedback watch' in run(command, '--help')
assert guide == run(command, 'skill')
run(command, 'skill', '--invalid', success=False)
skill = root / 'agent skills/mdr'
run(command, 'skill', '--install', skill)
assert (skill / 'SKILL.md').read_bytes() == (project / 'skills/mdr/SKILL.md').read_bytes()
run(command, 'skill', '--install', skill, success=False)
source = root / 'Spec with spaces.md'
source.write_text('# Fictional spec\n\nA retry returns the same job.\n')
review = json.loads(run(command, 'feedback', 'comment', source, '--author', 'Demo reviewer',
                        '--quote', 'same job', '--body-file', '-', input='Include the original job ID.'))
run(command, 'feedback', 'reply', source, review['feedback'][0]['id'], '--author', 'Demo agent',
    '--body-file', '-', '--addressed', input='Confirmed: retries return the original ID.')
result = json.loads(run(command, 'feedback', 'show', source))
assert result['feedback'][0]['addressed']
assert result['feedback'][0]['replies'][0]['author'] == 'Demo agent'
assert source.read_text() == '# Fictional spec\n\nA retry returns the same job.\n'
# Source installer also works away from the author's home, including updates.
environment = dict(os.environ, MDR_APPLICATIONS_DIR=str(root / 'Installed apps'), MDR_BIN_DIR=str(root / 'installed bin'))
for _ in range(2):
    subprocess.run(['bash', str(project / 'scripts/install.sh')], env=environment,
                   check=True, capture_output=True, text=True, timeout=30)
assert 'mdr feedback watch' in run(root / 'installed bin/mdr', '--help')
print('Distribution checks passed: universal signature, standalone resources, paths with spaces and shell characters, CLI installation, skill installation, live review commands, and installer upgrades.')
