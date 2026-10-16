# Resources: folder scope and study proposals

## What the app currently does

- **Resources mirrors notebook folders by ID**. Creating, renaming or moving a notebook folder immediately changes the folder tree shown in Resources. Resources can be opened from the notebook; notebook tabs at the top remain **notebook-only**. No `Scripts / Lectures / Presentations / Study materials` categories exist.
- A PDF is imported into the folder currently browsed. Existing PDF UUIDs and original bytes are preserved; PDFs from the older flat catalog remain **Unassigned**. Swipe a PDF → **Move PDF** to reassign its catalog folder without moving/deleting its original file. If a folder is removed, its PDF remains browsable as Unassigned but is *not* silently added to a root notebook's active set.
- The Resources header reports the current notebook's reference folder and eligible PDF count. ✓ marks eligible PDFs. The **exact assigned folder** of the notebook is the automatic scope; **not child folders**, even if they represent previous or other semesters. An Unassigned/root notebook has **no automatic references**, so historical unclassified PDFs cannot slip into a new semester. Swipe a PDF outside that folder to pin/unpin it explicitly for this notebook's **current app session**. Browsing another folder does not implicitly expand the scope. A past-semester file requires manual selection. The UI explicitly says **AI is not connected yet**; these selections do not send anything today.
- Source PDFs are app-private; PDFKit offers local exact-text search and highlights. Scanned images lack OCR. No FTS, answer citation pipeline, semantic retrieval, reliable quoted bounds/hashes, course/year/term metadata, or automatic source selection from prose is implemented yet. Import timestamps never determine semester. Notebook folder organization serves as today's explicit scope; a future optional subject/semester identity should never broaden it automatically.
- Folders, original PDFs, study-graph sidecars and visual sidecars are currently **outside** the notebook/cloud-sync and PDF-export guarantees unless those subsystems explicitly include them later. Do not infer the data has been backed up to a server.

## AI answer contract: future backend (not active)

Explicit Ask/Check only: select the purple question/region and inspect only the exact folder plus manually pinned PDF UUIDs. A model must not search files itself or run shell tools. A local index must eventually fetch a few short passages and verify exact text, page, selection bounds and content hash against the original PDF. Where text extraction/OCR cannot verify a quote, say so; never invent a citation. No whole notebook/PDF upload, no model request for each Pencil stroke. Consent before sending another person's material. Stream a single bounded request, track TTFT/total/cost, and let the client decide whether a graphic is naturally useful or explicitly requested. If not, `assets` is empty.

## Versioned, typed visual proposal v1 (implemented locally)

`StudyVisualProtocol.swift` parses a bounded JSON object: `version=1`, `requestID` UUID, a matching lowercase SHA-256 `contextHash`, `explanation`, and at most two `assets`. Unknown versions, kinds, colors, operators, foreign attributes, nonfinite coordinates and references outside the consented `availableSources` are rejected. Each asset has a unique UUID, a `trigger` (`requested` or `naturallyUseful`), a bounded caption, normalized placement hint `x,y`, bounded `width,height`, and at most four source UUIDs. Assets stay **inert proposals until explicit acceptance** in the future AI UI; the current app does not ingest model answers or attach them automatically.

| `kind` | Typed payload; never model-authored executable code |
| --- | --- |
| `function2D` | Bounded x/y ranges and an acyclic, topologically ordered expression DAG. Whitelisted nodes: constant, x, parameter a/b/c, +, −, ×, ÷, sin, cos, integer power 0–4. Up to three bounded parameter sliders with allowed units. |
| `surface3D` | Same bounded DAG with y coordinate; sampled 3D mesh drawn locally and rotatable offline. |
| `vectors3D` | Up to 12 bounded labeled `(x,y,z)` vectors; whitelist palette and local rotatable 3D axes. |
| `diagram` | Up to 80 bounded normalized primitives: line, polyline, polygon, rectangle, ellipse, text. No raw SVG/XML, path strings, URLs, HTML or scripts. |
| `table` | Up to eight columns and 32 bounded rows; plain text cells, no markup. |

Native UIKit renders accepted/test visuals; sidecars are versioned, atomic and separate from PencilKit. A corrupt sidecar is **not overwritten**. The Add interactive graph menu has an **offline 3D-vector example** for device testing; this is *not* a model-produced answer. Existing one-parameter graph cards keep an icon-only values-table toggle and an inline slider/value row. A standalone legacy graph HTML export remains separate, with fixed app-authored JS; **model text never enters its script**. Visual sidecars do not yet export as editable standalone HTML or appear in PDF snapshot. The v1 renderer is a foundation, not a full 3D engine or a validated real iPad user experience.

## Pi trial and security boundary

A local Pi invocation using a public arithmetic prompt with tools, extensions, context files, skills, prompt templates, session persistence and approvals disabled returned the correct answer (warm JSON run: ~3.2 s first text, ~5.35 s wall-clock before the stream settled). It is only a **local test**, not an iPad transport, deployed provider, commercial entitlement or secure study backend. Pi's default full coding-agent session can access files/shell with the host user's permissions; never run that against notebook content. A production adapter needs OS-level isolation, dedicated provider credentials, an authenticated/TLS iPad transport, streaming, request/context limits and explicit per-user consent. Never embed an API key or personal Pi authorization in the IPA.
