# Series 002 print run record

| | |
|---|---|
| **Series** | `002` — London — Chilly Most, September 2026 |
| **Codes** | 40, all at `printed` |
| **Series status** | `closed` |
| **Closed (UTC)** | 2026-09-14T01:13:05Z |
| **Operator** | Scott Boyan |
| **Printer** | HP LaserJet Pro 200 color M251nw |
| **Stock** | Avery 94106, US Letter, 4 x 5 labels per sheet, 2 sheets |
| **Print path** | Microsoft Edge built-in PDF viewer on Windows 11 |
| **Scaling** | 100%, fit-to-page disabled; PDFs pin /PrintScaling /None |

Governed by IB0192 (code format and registry) and IB0193 (this repository and the
Series 2 run), both in `play-engine-project`.

## What was printed

| File | Bytes | SHA-256 |
|---|---|---|
| `series-002-sheet-1.pdf` | 295,389 | `5072710fb01bc4748bec8205b31436f346b888777409c393d62ed2536b659435` |
| `series-002-sheet-2.pdf` | 294,481 | `8558d2d3ecb70ae9fb2d87d6a675e94e6dbf62cd1f6d81aa2aeabd988fc90a84` |

Sheet and cell for every code: docs/series-002-sheet-manifest.json

## Pre-print verification (KDR-20)

Every QR was decoded out of the rendered PDFs at 400 dpi, per cell region, and
matched against the registry entry for that cell before anything was printed.

Transcript: docs/series-002-verification.json

The gate was also exercised against deliberately corrupted copies — two codes
swapped between cells, a registry code replaced with a valid but unprinted one, and
a registry entry removed — and refused all three with a non-zero exit.

## Physical verification (WP07.T03, T05)

The layout was calibrated over five rounds against plain-paper proofs read on a
transillumination rig against blank stock, until the heavy proof guide aligned with
the die-cut kerf line. The calibration is recorded in `templates/avery-94106.json`
and is valid only for the print path named above.

Labels scanned from the printed sheets with a phone camera:

| Sheet | Cell | Code | Resolved URL |
|---|---|---|---|
| 1 | 1 | `002-HSR8TF-R` | https://scottboyan.com/artifact/002HSR8TFR |
| 1 | 20 | `002-C598ZJ-9` | https://scottboyan.com/artifact/002C598ZJ9 |
| 2 | 10 | `002-ZF0ARZ-M` | https://scottboyan.com/artifact/002ZF0ARZM |

Per IB0191 Gate A the interim `/artifact/{code}` route does not exist yet, so these
resolve to the site's not-found page. That is expected: the check here is that the
scanned URL string is correct, not that the page is useful.

## Notes

The calibration in templates/avery-94106.json is only valid for this exact path -
Microsoft Edge's PDF viewer, the HP driver, this M251nw, and this stock together.
Any change to that chain invalidates it: reset the calibration and reproof rather
than assuming the numbers carry over.

Registration was calibrated over five plain-paper rounds on a transillumination rig
before any stock was loaded. Tightest ink-to-kerf clearance on the final layout is
1.314 mm at the ends of the action line; the QR dark modules clear the cut by
8.98 mm. Measured registration residual after calibration was 0.150 mm, an 8.8x
margin at the tightest point.

The per-row corrections fit a straight line against distance down the page with
slope 0.382%, meaning the printed image runs about 0.38% tall over the page - roughly
3 pt end to end, consistent with ordinary laser feed and fuser stretch rather than
viewer scaling.

One open question for the next series: the die-cut was measured at 37.875 mm
(1.4911 in) using a 1.7 mm inset. A 1.5 in die-cut would need a 1.5875 mm inset, and
that inset is exactly the cell box's own 4.5 pt offset from the grid origin - which
would mean the Avery origins ARE the die-cut corners and the 117 pt cell is that plus
4.5 pt of bleed per side. The difference is 0.11 mm and did not matter here. It is
worth settling before the next run.

## Closing

Series 002 is closed. No further codes are ever minted into it (IB0192). Every
code is at `printed` and is permanently spent whether or not the label it sits on is
ever applied to an object.
