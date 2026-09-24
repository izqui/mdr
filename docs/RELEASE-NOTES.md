A quiet Mac reader for the specs you write with agents.

New in 0.3.1: file creation and update times above the document heading, refreshed
as the source changes, plus clearer review messaging and Mac-framed demo images.
Hover a timestamp to see the full date and timezone. Creation uses the local
file's creation date; copies and replacements can have a new one.

- Rendered Markdown with an outline, minimap, offline Mermaid, and code highlighting.
- Comments, editable threads, and replacement suggestions that leave the source untouched.
- Autosaved review files with authors, timestamps, source hashes, and live agent replies.
- PDF export, relative Markdown links, and light, dark, paper, and system appearances.
- Optional Terminal command installation from the app, plus a bundled agent skill.

**Install:** download the universal DMG, drag mdr to Applications, and open it.
Requires macOS 14 or later; includes Apple Silicon and Intel binaries.

This early release is **ad hoc signed, not notarized by Apple**. If macOS blocks
the first launch, follow [Apple's per-app Open Anyway instructions](https://support.apple.com/en-us/102445).

Choose **mdr → Install Terminal Command…**, then run `mdr --help`.
Install the skill with `mdr skill --install "$HOME/.agents/skills/mdr"` for Codex,
or use `"$HOME/.claude/skills/mdr"` for Claude Code. A standalone skill ZIP is
also attached. See the README for PATH setup, examples, and the review workflow.

`SHA256SUMS` covers the attached app ZIP, DMG, and skill ZIP. Download it alongside
those files and run `shasum -a 256 -c SHA256SUMS` to check download integrity.
