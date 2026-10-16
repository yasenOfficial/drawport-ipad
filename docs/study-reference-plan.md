# Scoped study references (design; not implemented)

## Student-facing organization

- Two top-level destinations: **Notebooks** and **Library**. Existing top notebook tabs remain notebooks only, never pages or courses.
- Library has four filters, not four full-screen navigation hierarchies: **Scripts**, **Lectures**, **Presentations**, **Study materials**. Add PDF with one import action; optionally classify it then or leave it **Unassigned**. Do not infer a semester from file timestamps.
- A course is a stable identity with an explicit academic year and term, e.g. Mathematics · year 1 · term 2. A folder may offer a default course, but a notebook stores an explicit course link, independently of its title or folder. Student can change this link without moving pages or documents.
- Opening a notebook shows its active course/term chip and the number of eligible references. The student may temporarily pin other resources for this question, including previous semesters; pins must be visible and expire with that request unless explicitly saved.
- Tags (e.g. derivatives, circuits, exams) refine search inside the permitted scope, never silently widen the course/term filter. Make tags optional, editable and suggested after local text extraction. Imported date is audit metadata, not relevance logic.

## Retrieval rules and cost

1. On explicit Ask/Check only, start with resources linked to the active notebook's **course AND term**. Include separately visible, manually selected/pinned resources. Never scan all prior semesters by default.
2. Search locally extracted PDF text with SQLite FTS and page identifiers; deduplicate by source content hash. Do not use an LLM to classify every import or every stroke. Scanned PDFs are marked as requiring OCR, performed locally/on demand and confirmed if low-confidence.
3. Rerank a bounded set of matches; pass at most 3–5 short, exact source excerpts with stable resource ID, page, text range and PDF bounding boxes. Cap the combined reference context by tokens, not PDF pages. If no relevant excerpt is found, say so rather than inventing a reference.
4. One user request aims for one model response; no background polling or automatic repeated model calls. Cache by question-region hash, selected course/term, pinned sources, and resource revision. Sliders and citations resolve locally with zero additional model calls.
5. Answer links open the locally imported PDF at the cited page, selecting the verified text or region. Display an OCR-uncertain flag and do not present a guessed formula as an exact quote.

## Storage and migration

- Extend the local resource catalog with versioned `Course`, `Term`, `ResourceType`, and resource-to-course links. Preserve original PDFs and their existing UUIDs. Existing unclassified imports migrate to **Unassigned**; never silently tag them as the current semester or delete old files.
- Keep deterministic retrieval metadata local; cloud sync/import sharing is separately opt-in. A notebook PDF export can include a bibliography without bundling copyrighted full PDFs. A DrawPort package can retain exact local IDs and verify the source hash on reimport.
- Test old notebook decoding and resource migration with fixture copies before any device update. Notebook deletion must not delete shared resources; remove only its course association. Rebuilding the index must not alter the originals.

## Privacy and product boundary

- The present AI button has no backend. Do not embed a provider API key in the IPA or enable the existing legacy full-notebook AI upload as a shortcut. Commercial users must explicitly approve sending a selected region and bounded source excerpts; project-level provider data-sharing defaults cannot be silently assumed on their behalf.
- Observe request latency, cost, citation precision and failures with redacted diagnostics. A slow locally hosted model should not be marketed as instant merely because it runs without paid API requests.
