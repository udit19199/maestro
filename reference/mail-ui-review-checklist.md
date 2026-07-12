# Mail UI Review Checklist

Use before merging mail UI or briefing changes. Cite **Rule IDs** from the [UI/UX Learning Archive](https://docs.google.com/spreadsheets/d/1epO0tyC2_UTWbMDR-KdvOuG_OUoZOaTUdxIKPL6ohik/edit?usp=sharing) in review comments.

Primary design authority: [`docs/DESIGN.md`](../docs/DESIGN.md) (Morning Desk).

---

## macOS native (Video 07)

| Check ID | Prompt | Pass? |
|---|---|---|
| CHK-096 | Does the UI follow platform conventions (sidebar, Settings Form, bordered buttons, semantic colors)? | |
| CHK-144 | Are mail controls out of the draggable title/toolbar zone? | |
| CHK-069 | Are utility surfaces minimal (slim composer, focused cleanup sheet)? | |
| CHK-062 | Can users inspect mail in context (row → composer prefill, not full reader hop)? | |
| CHK-143 | Is the first action obvious (digest visible before deep setup)? | |

---

## Canonical rules (mail-scoped)

### RULE-001 — Contextual AI at point of use

- [ ] AI digest sits inside the Inbox card, not a separate mode
- [ ] Row selection prefills composer with sender/subject context
- [ ] Mail actions are adjacent to the content they affect

### RULE-003 — Glass as material, not haze

- [ ] No custom glassmorphism on mail cards
- [ ] Critical text is not placed behind blur or transparency

### RULE-004 — Legibility before aesthetics

- [ ] Unread dots, badges, and digest pass contrast in light and dark mode
- [ ] Secondary text uses `.secondary`, not low-contrast custom grays

### RULE-005 — Native targets and chrome

- [ ] Click targets are comfortably sized (rows, buttons, cleanup CTA)
- [ ] Controls use system `.bordered` / `.borderedProminent`

### RULE-008 — Data form by user decision

- [ ] Briefing shows digest + max ~8 rows (overview)
- [ ] Full thread detail happens in chat, not an inline mail reader

### RULE-014 — Component states

- [ ] Loading state while sync runs
- [ ] Empty state when no accounts connected
- [ ] Error state with recovery hint (Settings link or retry)
- [ ] Stale "Updated" timestamp when data is old

### RULE-017 — Feedback after action

- [ ] Archive batch shows confirm → result (not silent)
- [ ] Send confirm panel shows success or failure after action

### RULE-020 — Flows over pages

- [ ] Flow is: briefing overview → chat inspect → confirm panel → feedback
- [ ] No dead-end screens without a return path

### RULE-022 — Contextual controls

- [ ] "Review N newsletters" CTA hidden when `pendingCleanupCount == 0`
- [ ] Destructive actions require explicit confirm

### RULE-031 — Orientation

- [ ] Every mail row shows an account badge or label
- [ ] Digest line includes category counts (reply / newsletters / invites)

### RULE-033 — Production references

- [ ] Patterns borrowed from Apple Mail / Spark (rows, confirm), not pixel clones
- [ ] Mobbin-inspired layout still matches Zoro 720pt Morning Desk column

### RULE-038 — Visual hierarchy

- [ ] Unread indicator + sender dominate the row
- [ ] Subject secondary; snippet tertiary
- [ ] Time and account badge are metadata (caption weight)

---

## DESIGN.md compliance

- [ ] Flat surfaces: `controlBackgroundColor`, 12pt radius, 1pt subtle border
- [ ] No purple gradients, neon, or sparkle decoration
- [ ] SF Pro body text; SF Mono only in code blocks
- [ ] One accent (system blue) for primary actions
- [ ] Max content width 720pt preserved

---

## Confirm panel parity

Mail send and cleanup confirms must match `PendingActionsBar` confirm cards:

- [ ] `.padding(12)` on `controlBackgroundColor` panel
- [ ] Cancel = `.bordered`, primary = `.borderedProminent`
- [ ] Title uses `.subheadline.semibold()`

---

## Reviewer notes

| Rule ID | Finding |
|---|---|
| | |
| | |
