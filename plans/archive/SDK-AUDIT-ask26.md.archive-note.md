# Archive note — SDK-AUDIT-ask26.md

Archived: 2026-05-07.

**Why archived:** This audit enumerated 13 P0/P1/P2 findings against the
NXP `ask-6.6-port` SDK source tree as of `kernel-6.6.137-ask26`. Findings
A1–A3 were implemented in `ask27`; A4/A5/B6/B1/B2/B3/C1/C2/C5/C6 were
sequenced for `ask28..ask30`. By `ask42` (final 6.6.137 release before the
mainline-6.18 pivot) the relevant fixes had landed or been superseded.

The strategic context that motivated the audit — "we are continuing to
mirror NXP's `ask-6.6-port` and need to harden it" — was retired when the
project pivoted to patching `kernel.org` mainline 6.18 directly (see
`plans/MIGRATION-PLAN-6.18.md`). Future audits will target the mainline
base + our re-ported ASK overlay, not the NXP `ask-6.6-port` branch.

Kept as historical reference only.