# garage.html SVG Topology Diagram — Audit Report

**File:** `/opt/data/km_inspect/kubernetes/apps/base/home/home/homepage/garage.html`
**SVG:** `viewBox="0 0 1000 730"`
**Date:** 2026-06-12

---

## HIGH Severity

### 1. Callout box overlaps region box bottoms (10px)
- **SVG Lines 318 / 220, 255, 282**
- Callout `rect x=40 y=660 width=920 height=50` spans y=660→710.
- All three region boxes span y=265→670 (y=265 + height=405).
- **Result:** The callout rect overlaps the bottom 10px of every region box (y=660→670), drawing its dashed border on top of the region interior.
- **Fix:** Shift the callout to `y=675` (height can stay 50, extending to 725, still within the 730 viewBox), OR reduce region box heights to 395 (y=265→660).

### 2. StPete description text overflows its 280px-wide region box
- **Line 284:** `<text x="820" y="308" ... font-size="9">3 Nodes (K3s, arm64+GPU) · AI/ML · orin-0 (control-plane)</text>`
- ~56 characters at 9px sans-serif ≈ 300–330px rendered width.
- Region box width = 280px (x=680→960). Centered at x=820: text spans ~665–975.
- **Result:** Text clips ~15px on each side beyond the box border.
- **Fix:** Shorten the text (e.g. `3 Nodes (K3s, arm64+GPU) · orin-0 cp`), reduce font-size to 8, or widen the StPete box slightly.

### 3. "9/8 TS services" labels have critically low contrast
- **Lines 153, 159, 165:** `<text ... fill="#fb7185" font-size="7" opacity="0.5">9 TS services</text>`
- `#fb7185` at 50% opacity on a near-black background (`#1a1612` body / `#2e2621` grid) yields an effective color of roughly `#8a434b` on `#1a1612` — a contrast ratio well below 3:1.
- **Result:** These labels are nearly invisible, especially at small viewport sizes.
- **Fix:** Raise opacity to at least 0.8, or use a lighter tint of the rose color (e.g. `#fda4af` at 0.7).

---

## MEDIUM Severity

### 4. StPete ingress-2 / egress-2 rects extend outside group borders
- **Lines 164, 191:** `rect x="912" y="116" width="75"` → ends at x=987.
- common-ingress group rect: `x=40 width=920` → ends at x=960.
- common-egress group rect: `x=40 width=920` → ends at x=960.
- **Result:** The third proxy pod in StPete protrudes 27px past the dashed group border, visually inconsistent with Ottawa and Robbinsdale layouts.
- **Fix:** Center the StPete ingress/egress columns so the third pod fits inside the group (e.g. shift StPete column from x=830→912 to x=845→920+75=995, which still exceeds 960). Better: reduce ingress-2/egress-2 rect width to 65px (x=917→982, keeps within 960) or shift the whole StPete column left by 15px.

### 5. "13 egress TS services" labels have marginal contrast
- **Lines 182, 187, 192:** `<text ... fill="#c084fc" font-size="7" opacity="0.7">13 egress TS services</text>`
- `#c084fc` at 0.7 opacity on near-black yields an effective luminance that may fail WCAG AA for small text (7px). Estimated contrast ratio ~3.5–4:1.
- **Fix:** Raise opacity to 0.85 or use `#d8b4fe` (lighter purple) at 0.7.

### 6. Hardcoded node counts in SVG (not driven by live data)
- **Line 222:** `4 Nodes (Talos) · Services & Media`
- **Line 257:** `3 Nodes (Talos) · Production Home Lab`
- **Line 284:** `3 Nodes (K3s, arm64+GPU) · AI/ML · orin-0 (control-plane)`
- The cluster-card sections below use dynamic JS (`m.nodes_ottawa` etc.) to update node counts and health, but the SVG text is a static string.
- **Result:** If cluster node counts change, the SVG topology line will show stale data while the metric cards update correctly.
- **Fix:** Either (a) add JS to update these SVG text nodes from METRICS_DATA, or (b) document that the SVG is a static architecture diagram and remove the numeric pretence (e.g. "Talos cluster · Services & Media").

### 7. GSLB arc traverses the interior of all three region boxes
- **Line 311:** `path d="M180,590 C300,640 700,640 820,590"` — the arc reaches ~y=615, which is inside every region box (y=265→670), 55px above each box's bottom edge.
- The S3 endpoint rects end at y=547 (Ottawa/Robbinsdale) or y=587 (StPete), so the arc doesn't overlap content, but it visually sits *inside* the region boxes rather than below them.
- **Result:** Semantic confusion — GSLB should appear as a global layer below all regions.
- **Fix:** Move GSLB arc below the region box bottoms (y ≥ 675) by adjusting the path to `M180,675 C300,710 700,710 820,675`.

### 8. SVG becomes microscopically unreadable on small viewports
- **CSS (line 33):** `.topology svg { width: 100%; height: auto; max-width: 1000px; }` — the SVG scales down proportionally.
- At viewport <400px, the 1000px viewBox is rendered at <400px wide. Font sizes (7–12px SVG units) shrink to 2.8–4.8px physical pixels — unreadable without pinch-zoom.
- **CSS (line 34):** `overflow-x: auto` provides horizontal scrolling, which is the standard escape hatch, but the initial render is illegible.
- **Fix:** Add a `<style>` within the SVG or a media query that prevents SVG scaling below a minimum width (e.g. `min-width: 700px` on the SVG wrapper, forcing scroll at narrow widths), or provide a text-fallback summary printed below the SVG at small viewports.

### 9. No `<title>` or `<desc>` in SVG — missing accessible semantics
- The `<svg>` element has no `<title>`, `<desc>`, or `role="img"` with `aria-label`.
- Interactive `.region-box` elements have `cursor: pointer` but no `role`, `tabindex`, or `aria-label`.
- **Fix:** Add `<title>Multi-region Garage topology with Tailscale proxy groups</title>` and `<desc>` explaining the layers.

---

## LOW Severity

### 10. Static version strings may be stale
- **Line 87:** `Garage v2.3.0`
- **Line 436:** `Tailscale operator v1.98` / `Garage v2.3.0`
- **Line 377:** `Rejoined 2026-06-04` — hardcoded date.
- These aren't driven by Mimir metrics and must be manually updated when versions change.

### 11. Arrow marker tips may slightly overlap their target rects
- VPN→ingress arrows (lines 168–170): `M97,56 L97,88` — arrow tip lands at y=88, exactly the top edge of the `ingress-0` rects (also y=88). The `marker-end` arrowhead may visually cross the rect border by 1–2px.
- Minimal visual impact. Only noticeable on zoom.
- **Fix:** Shorten arrows by 1–2px (e.g. `L97,89`).

### 12. No responsive font scaling inside SVG
- All SVG text uses fixed `font-size` (7–12). No CSS `@media` queries target SVG text at narrow widths.
- Not fixable with CSS alone (SVG viewBox scaling is uniform); acceptable with overflow-x scroll.

---

## Summary

| # | Issue | Severity | Impact |
|---|-------|----------|--------|
| 1 | Callout overlaps region boxes (10px) | **HIGH** | Visual artifact |
| 2 | StPete description overflows box | **HIGH** | Text clipped |
| 3 | TS services labels nearly invisible (0.5 opacity) | **HIGH** | Readability |
| 4 | StPete proxy pods extend past group border | **MEDIUM** | Visual inconsistency |
| 5 | Egress service labels marginal contrast (0.7 opacity) | **MEDIUM** | Readability |
| 6 | Hardcoded node counts in SVG | **MEDIUM** | Stale data risk |
| 7 | GSLB arc inside region boxes | **MEDIUM** | Semantic confusion |
| 8 | Microscopic SVG text at narrow viewports | **MEDIUM** | Mobile UX |
| 9 | Missing SVG title/desc and ARIA | **MEDIUM** | Accessibility |
| 10 | Static version strings | **LOW** | Documentation drift |
| 11 | Arrow tips on border | **LOW** | Cosmetic |
| 12 | No responsive SVG font scaling | **LOW** | Mobile UX (mitigated by scroll) |

**Recommended immediate fixes (HIGH):** raise TS-service-label opacity (3), shift callout rect down by 15px (1), shorten StPete description (2).