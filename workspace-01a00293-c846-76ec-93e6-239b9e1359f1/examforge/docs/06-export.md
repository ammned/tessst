# 06 — Preview & Export Pipeline

## 1. Principle

**Print is the real UI.** The teacher's deliverable is paper. So rendering is server-side, and the
web preview is the *same* renderer output — what you see is what prints.

One normalised **layout model** feeds three targets (HTML preview, PDF, DOCX), so the paper and the
answer key can never drift apart: they are projections of the same `exam_item` objects.

```
exam (DB)
  └─► LayoutModel (pure python dataclasses; numbering, marks, sections, media resolved)
        ├─► Jinja2 + print CSS ──► HTML  ──► (Playwright/Chromium) ──► PDF
        ├─► Jinja2 + print CSS ──► HTML preview (served to the browser)
        └─► python-docx builder ──────────► DOCX
```

## 2. LayoutModel (the intermediate representation)

```python
@dataclass
class LayoutModel:
    header: Header            # school, class, subject, date, duration, total marks, name/grade lines
    instructions: str | None
    sections: list[Section]   # each: title, instructions, items
    is_rtl: bool
    options: LayoutOptions    # paper, columns, font size, answer space, show marks
    answer_key: AnswerKey     # parallel structure, same numbering

@dataclass
class Item:
    display_number: str       # server-computed: '1', '2', '3.a'
    type_code: str
    instruction: str | None
    stem: RichText
    body: MCQBody | MatchingBody | FillBlankBody | ...   # type-specific
    media: MediaRef | None
    marks: float
    answer_space: AnswerSpace # lines | box | grid | none  (computed from type + year)
    page_break_before: bool
```

Numbering, mark totals and answer-space sizing are computed **once**, here — never in a template.
That's why the answer key's "Question 7" is guaranteed to be the paper's question 7.

## 3. Per-type rendering rules

| Type | Paper rendering | Answer space | Key rendering |
|---|---|---|---|
| `mcq` | Stem + lettered options (A/B/C), boxes or circles | none | Correct letter + one-line rationale |
| `multi_select` | Checkboxes, "choose all that apply" | none | All correct letters |
| `true_false` | Two boxes / ○ Vrai ○ Faux | none | V/F |
| `fill_blank` | Underscored gaps sized to answer length | inline | Ordered answer list + accepted variants |
| `matching` | Two columns, letters left / numbers right, join area | between columns | Pair mapping (A→3, B→1…) |
| `ordering` | Numbered empty boxes before each element | inline | Correct sequence |
| `short_answer` | Stem + 1–2 ruled lines | lines | Model answer + accepted variants |
| `open_ended` | Stem + 4–8 ruled lines (year-dependent) | lines | Rubric with marks per criterion |
| `problem_solving` | Stem + working box + answer line | box + line | Step-by-step solution with step marks |
| `label_diagram` | Image + numbered callout lines | callouts | Label list per number |

## 4. Print CSS essentials

```css
@page { size: A4; margin: 18mm 15mm 20mm 15mm;
        @bottom-center { content: "Page " counter(page) " / " counter(pages); } }
.item        { break-inside: avoid; margin-bottom: 6mm; }   /* never split a question */
.item__media { break-inside: avoid; max-height: 55mm; }
.section     { break-before: auto; }
.item--break { break-before: page; }
.answer-lines { border-bottom: 1px solid #999; height: 8mm; }
html[dir="rtl"] { direction: rtl; }                          /* Arabic papers */
@media print { .no-print { display: none; } }
```

**Break-avoidance is the highest-value rule:** a question split across pages is the single most
common complaint about hand-made papers.

## 5. Multilingual / RTL

- Font stack: **Amiri / Noto Naskh Arabic** (ar), **Noto Sans** (fr/en), **Noto Sans Math** for
  formulas. Fonts are bundled in the render image — never fetched at render time.
- `dir="rtl"` set from `exam.is_rtl`; mirrored margins, right-aligned numbering, RTL-aware option
  lettering (أ/ب/ج instead of A/B/C when the paper language is Arabic).
- Mixed-language items (Arabic instruction + French vocabulary) use per-run `dir` spans, with
  bidi isolation (`&#8296;…&#8297;`) so punctuation doesn't jump sides.
- **Golden-image regression tests:** a fixture exam per language is rendered on every CI run and
  compared pixel-wise against a stored reference; drift fails the build.

## 6. Answer key generation

Never a second AI call. Built from the same `exercise_version.answer_key` JSON already validated
during generation:

```
answer_key_mode:
  separate_document  → key.pdf, own header "CORRIGÉ", same numbering  (default)
  appended           → paper + page break + key in one file
  inline             → answers printed in colour/margin (for teacher's own copy)
```

Key includes: correct answer, explanation, marking scheme with per-step marks, total marks per
section, and (optionally) the curriculum objective code per question — useful for inspection.

## 7. Export job flow

```
POST /exams/{id}/exports
  ├─ validate: exam not empty; all referenced assets ready-or-fallback
  ├─ insert export_job(queued) → 202 {export_id}
  └─ enqueue export.render
       ├─ build LayoutModel (single DB read, no N+1: items+versions+assets in one query)
       ├─ resolve media → signed short-lived URLs (or embedded data URIs for DOCX)
       ├─ render paper → PDF/DOCX
       ├─ render key  → PDF/DOCX (if requested)
       ├─ upload artefacts to S3 (private, immutable, content-addressed)
       └─ export_job(ready, paper_uri, answer_key_uri, page_count)
GET /exports/{id} → signed URLs, 1h expiry
```

**Idempotency:** same exam version + same options ⇒ artefacts reused, no re-render.
**Failure:** any item failing to render is replaced by a visible placeholder box and the job
completes with a warning, rather than failing the whole export.

## 8. Performance & limits

| Metric | Target |
|---|---|
| 12-question PDF | < 3 s |
| 40-question PDF with 10 images | < 8 s |
| DOCX | < 2 s |
| Concurrent renders per pod | 4 (Chromium memory-bound) |
| Max pages | 40 (guard against runaway) |

Chromium runs pre-warmed with a page pool; images are pre-fetched to local disk before rendering to
avoid in-render network stalls.
