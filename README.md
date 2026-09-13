# printing-project

Local operations tooling for printing physical artifacts: serialized label sheets,
QR symbols, and the mint registries that record what was committed to stock.

This repository is deliberately separate from `play-engine-project`. Printing is a
local, physical, operator-present process that ends at a sheet feeder. It does not
belong in a repository whose discipline is cloud deployment and automated pipelines.

## Authority

**Governing documents live in `play-engine-project`. Implementation lives here.**

| Brief | Path | What it governs |
|---|---|---|
| IB0192 | `ohmai/8000-issue-briefs/doc_8126-issue-briefs-for-2026/doc_8126_067-ib0192-serialized-artifact-code-format-and-mint-registry.md` | The code format: alphabet, structure, check character, series namespace, registry schema, test vectors. A permanent product contract. |
| IB0193 | `ohmai/8000-issue-briefs/doc_8126-issue-briefs-for-2026/doc_8126_068-ib0193-printing-project-repository-and-the-series-2-label-print-run.md` | This repository, the sheet geometry, and the Series 2 print run. |
| doc_2007 | `ohmai/2000-conventions/doc_2007-powershell-argument-and-array-conventions.md` | PowerShell argument and array conventions. Binding on every cross-script call here. |

If code here disagrees with those briefs, the briefs win. Change the brief first.

## The one architectural rule

**Agents and operators invoke `orchestrators/*.ps1` and nothing else.**

An orchestrator sequences a job and reports on it. It owns no domain logic. Beneath
it sit processors: small, tightly scoped scripts that each do one thing, return a
value, print nothing, and are filed by domain rather than by job.

```
orchestrators/          the only entry points
processors/codes/       minting, validation, format conversion
processors/registry/    series registry create, append, validate
processors/qr/          QR symbol generation
processors/layout/      sheet templates and sheet composition
processors/pdf/         PDF property inspection
templates/              sheet geometry as data, not code
lib/                    vendored dependencies + manifest.json (SHA-256 pinned)
data/series/            mint registries. COMMITTED - these are the system of record
out/                    build artifacts. Ignored.
tests/                  Pester suites
docs/                   run records
```

The reason to hold this boundary on day one, when there is exactly one job, is that
it is nearly free to establish now and nearly impossible to retrofit once three
orchestrators have grown their own private copies of the same QR logic.

Read `AGENTS.md` before writing anything here.

## Requirements

- PowerShell 7 (developed against 7.6.5 on .NET 10)
- No network access. All dependencies are vendored in `lib/` and pinned by SHA-256
  in `lib/manifest.json`.
- Pester 5 for the test suites.

## Series 2

The first job this repository ran: forty serialized codes for the London cards,
printed 2026-09-13 on Avery 94106. The registry is `data/series/series-002.json`
and the run record is under `docs/`.
