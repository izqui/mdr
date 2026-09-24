# Large documents, less work

The 0.3.2 performance pass uses a generated, fictional implementation spec with
160 code blocks, 4,160 code lines, and 286,861 bytes of Markdown. The native
benchmark opens the real AppKit/WKWebView reader and records local timings.

Three-run diagnostic medians on the development Mac:

| Measurement | 0.3.1 | 0.3.2 |
| :--- | ---: | ---: |
| Initial document elements | 38,490 | 9,393 |
| Markdown rendering | 178 ms | 46 ms |
| Apply document state initially | 503 ms | 341 ms |
| Refresh a review containing 60 comments | 258 ms | 7 ms |
| Find a repeated identifier | 143 ms | 13 ms |
| Native document ready | 1,229 ms | 1,059 ms |

These are local diagnostics, not a performance guarantee. System load varied,
and macOS put two runs of each version on an inactive Space. The table describes
JavaScript work and document readiness, not time to a visible frame. Frame-rate
results from hidden windows are excluded; this sample is insufficient to claim
an FPS improvement. Reproduce measurements on an idle Mac with the benchmark
window visible using the commands in [CONTRIBUTING.md](../CONTRIBUTING.md#performance).

## What changed

- Ordinary Markdown loads a roughly 312 KB reader bundle. The separate 5 MB
  Mermaid bundle loads locally only when the document contains a diagram.
- Code starts as fully selectable, source-mapped text. Syntax colors are added
  near the viewport, in small batches, after scrolling settles. Suggestions,
  selections, and active search ranges pause decoration so their text nodes stay
  intact. Highlight results have a bounded cache for repeated code and updates.
- A normal LF code line uses one mapped element instead of three. CRLF and
  prefixed fences keep their precise newline mappings.
- Source spans and blocks are indexed once per document. Feedback anchors use
  binary search instead of rescanning the whole DOM for every comment.
- Scroll events coalesce into a frame; heading positions and minimap geometry
  are measured when layout changes. Only the active outline entries change.
- Search caches its text index and locates matches with binary search. Incoming
  replies leave unchanged thread cards and document nodes intact.
- Appearance changes preserve the document and rerender only diagrams.
- PDF preparation waits for diagrams and highlights every code block, including
  those the reader has never scrolled to. The source remains untouched.

An experiment with `content-visibility` was rejected because deferred geometry
changed code-pane behavior. The shipped reader retains the full document text
and stable pane geometry instead of virtualizing away reviewable content.

Instrumentation is disabled by default. It records durations and counts locally;
there is no network telemetry. Generated documents, reports, and snapshots live
under the ignored `work/performance` directory.
