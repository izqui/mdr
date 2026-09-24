A quiet Mac reader for the specs you write with agents.

New in 0.4.0: open a whole folder of specs.

- Run `mdr ./specs` or choose File → Open Folder… (⌘⇧O).
- Expand nested folders in Files, with keyboard navigation and dimmed unsupported files.
- Switch between Files and the current document's Outline in the same sidebar.
- Files load as you expand folders; additions and removals appear live.
- Switch documents in one window, retaining reading positions and saved feedback drafts.
- Relative Markdown links within the folder keep its browsing context.

New in 0.3.4: faster, more precise text selection.

- Drag toward the top or bottom of the reader to scroll at a speed that follows the pointer's distance from the edge.
- Long code panes scroll within the code before continuing through the document.
- Selections stop at the intended paragraph; empty overlaps no longer include Markdown from the following heading.
- The Comment/Suggest menu follows the selection endpoint and remains available after releasing outside the document.
- Selection anchoring searches the document index instead of scanning all selected spans. Syntax highlighting pauses throughout a drag.
- Local installation refreshes macOS app registrations and verifies the terminal command points to the installed app.

New in 0.3.3: search highlights remain attached after discarding suggestions or
preparing code for PDF export. Includes the 0.3.2 performance improvements below.

New in 0.3.2: faster reading and reviewing of large, code-heavy documents.

- Syntax colors load near the viewport and wait for fast scrolling to settle.
- Leaner code lines retain precise comment and suggestion anchors, including CRLF files.
- Indexed anchors, cached outline/minimap geometry, faster search, and incremental thread updates reduce work during reviews.
- Mermaid loads only when a document needs it; changing appearance preserves the document.
- PDF export waits for diagrams and prepares all code, including offscreen blocks.
- A reproducible native benchmark generates a fictional spec with 160 code blocks.

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
