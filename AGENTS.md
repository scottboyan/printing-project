# AGENTS.md

Read this before writing or invoking anything in this repository.

## 1. Only orchestrators are entry points

**An agent or operator invokes `orchestrators/*.ps1`. Nothing else.**

`processors/**` is not an entry point. Not for an agent, not for the operator, not
"just to test something quickly". If you find yourself wanting to call a processor
directly, the thing you actually want is an orchestrator that calls it, and writing
that orchestrator is the work.

A processor invoked directly will often appear to work. That is the problem: the
call sites are where this architecture is load-bearing, and a habit of bypassing
them is how the boundary erodes.

## 2. What an orchestrator is

An orchestrator **sequences a job and reports on it**. It owns no domain logic.

If an orchestrator computes a check character, lays out a grid, knows what Crockford
Base32 is, or contains an alphabet literal, **the logic is in the wrong file**. Move
it into a processor and call it.

An orchestrator may: read parameters, call processors in order, branch on their
returned results, write console output for the operator, write files to `out/`, and
set an exit code.

## 3. What a processor is

- **One thing.** A processor does a single job and returns a value.
- **Returns, never prints.** Console output is not a processor's return channel. A
  processor writes nothing to the host. Failures come back as a returned result
  object with a reason, not as a thrown string, wherever the caller needs to report
  several failures at once rather than stopping at the first.
- **Ignorant of its caller.** A processor does not know which orchestrator invoked
  it, and never contains the word for the job it was first written for.
- **Filed by domain, never by job.** `processors/codes/`, `processors/registry/`,
  `processors/qr/`, `processors/layout/`, `processors/pdf/`. A processor's path says
  what it is about, never what it was first used for. There is no
  `processors/series-2/`, and there never will be.

A processor written for one orchestrator must be usable unchanged by a different
orchestrator next year. That is the whole point.

## 4. Cross-script calls: hashtable splat only

**Build a `[hashtable]` and splat it. Never splat an array.**

```powershell
# CORRECT
$params = @{ Series = '002'; Count = 40 }
$result = & $processor @params

# WRONG - binds positionally and fails SILENTLY
$args = @('-Series', '002', '-Count', 40)
$result = & $processor @args        # '-Series' becomes the VALUE of the first parameter
```

`doc_2007` §1.1 records why: `@` before a variable is the splat operator, and
splatting an array passes every element **positionally**. Elements that look like
`-Name` are not parsed as parameter names. A script without `[CmdletBinding()]`
binds what it can and drops the rest into `$args` with no error at all.

`doc_2007` §1.3 records the cost: this exact mistake disabled a whole subsystem for
its entire first day in production, and the callee's 64-test suite could not see it
because every test splatted a hashtable. **Cover the call site, not just the callee.**

Where a call must be assembled conditionally, add keys conditionally:

```powershell
$params = @{ Path = $path }
if ($Strict) { $params['Strict'] = $true }
& $processor @params
```

The one legitimate array splat is a **native executable** (`pwsh.exe`, `git`), which
has no parameter binder. Everything in `processors/` is a `.ps1` and is not that.

## 5. StrictMode is inherited, so every processor must be clean under it

Processors are invoked with `&` and therefore run under **the caller's** session
state, not their own (`doc_2007` §4.1). Strict mode is session state, not a per-file
setting.

Every processor must be correct under `Set-StrictMode -Version Latest` on its own
terms: no unset variables, no missing properties, no `.Count` on a scalar. The Pester
suites run under it, and so does every orchestrator here.

Processors set `Set-StrictMode -Version Latest` at the top of their own body. They
are `&`-invoked scripts, not dot-sourced libraries, so this does not leak into a
caller — but a dot-sourced library file must **not** set it, for exactly that reason.

## 6. Script header convention

Mirrored from `play-engine-project/helpers/`. Every `.ps1` in this repository opens
with a comment block:

```powershell
# file_name    : processors/codes/new-artifact-code.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Mint one artifact code for a series.
# related_docs : IB0192 (format, R4 randomness); IB0193 (KDR-10)
```

`related_docs` names the governing brief by ID. A processor implementing a normative
format cites the brief that makes it normative, so the next reader knows where the
authority lives.

## 7. Things that are settled

The Key Design Resolutions table in IB0193 is settled. Do not re-litigate it mid-task.
In particular:

- `System.Security.Cryptography.RandomNumberGenerator` for code generation.
  **`Get-Random` is forbidden on the minting path** (KDR-10).
- The IB0192 test vectors are normative, including the Luhn parity convention.
- `data/series/*.json` is committed. The registry is the system of record (KDR-22).
- Every emitted PDF sets `/PrintScaling /None` (KDR-14).
- Dependencies are vendored in `lib/` and pinned by SHA-256 (KDR-19). No network.

If you believe you have found a genuine defect in a governing brief, say so and stop.
Do not silently diverge from it.
