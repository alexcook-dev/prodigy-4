# TODOs

Design/engineering debt tracked outside the plan file — not blocking, not forgotten.

## Unify spacing to a base grid

**What:** Replace the ad hoc spacing values in the design plan's Visual System
(9/10/12/14/16/20/24px) with a single base unit (4px or 8px grid).

**Why:** The values were pulled straight from the 3 hand-authored wireframes with
no shared unit behind them. A real spacing scale keeps future panes consistent
almost for free; ad hoc values compound into visible inconsistency as more screens
get built.

**Pros:** Cheap to retrofit now while few real screens exist; prevents slow drift
toward mismatched padding across future panes.

**Cons:** None of the 3 current wireframes are wrong as drawn — this is polish,
not a bug. Deriving the "right" scale now is time spent before there's a second
real screen to validate it against.

**Context:** Surfaced during `/plan-design-review` (2026-07-19), Pass 5 (Design
System Alignment). Full palette/type/spacing values live in the design plan at
`~/.gstack/projects/alexcook-dev-prodigy-4/alexcook-office-hours-design-20260718-221655.md`
under "UI/UX Design → Visual System".

**Depends on / blocked by:** Nothing — independent of all other work. Best done
once Step 1's semantic-color pass (D7) is in progress, so both land together.

- Status: Open

## Pin down the exact text-safe blue hex

**What:** Pass 6's contrast fix requires "a lighter, text-safe blue variant" for
text/link accents (raw system blue `#0a84ff` fails 4.5:1 as body text) — the
requirement is decided, but no actual hex value was chosen.

**Why:** Same shape of gap as the spacing-grid TODO above — a real decision,
correctly deferred, easy to lose once `#0a84ff` is sitting in the Visual System
section looking usable for text by default.

**Pros:** Five-minute fix once someone's looking at it in context (pick a value,
verify 4.5:1, done); prevents the raw accent color leaking into text use.

**Cons:** Blocks nothing today — no text/link accent gets built before Step 1's
semantic-color pass exists to hold the value anyway.

**Context:** Surfaced during `/plan-design-review` (2026-07-19), Pass 6
(Responsive & Accessibility), contrast computation against the Visual System
palette. See the design plan's "Visual System → Contrast fixes" note.

**Depends on / blocked by:** Nothing; naturally lands alongside the spacing-grid
TODO and Step 1's semantic-color work.

- Status: Open
