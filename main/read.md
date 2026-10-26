# Claude prompt: Fix FastQC/MultiQC not running + improve live logging (NO module edits, DRY-RUN ONLY, NO commits, NO planning mode)

You are in the STAMINA-BIOME repo.

ABSOLUTE RULES:
- Do NOT commit any changes.
- Do NOT use planning mode. Implement directly.
- ABSOLUTELY NOT ALLOWED to modify ANY pipeline module scripts at all (`pipelines/modules/*.sh` or any module entrypoints). You may read them for background only.
- DRY-RUN TESTS ONLY: do NOT run full pipelines. You may only run preflight/dry-run style checks and any lightweight “smoke” checks that do not execute the full workflow (no QIIME2 denoise/classify runs, no full Kraken runs, etc.).
- You MAY change: CLI orchestration, preflight/dry-run logic, logging utilities, docker image selection/build logic, and other shared (non-module) code.

## Problem
FastQC and MultiQC still do not run, and logs are not showing meaningful incremental progress.
FastQC should be one of the first things completed and running (early pipeline step), so this indicates orchestration/tool discovery is still wrong.

We must fix:
1) FastQC and MultiQC availability and execution triggering (without changing modules).
2) Live logging / log files so that the user sees “where it is up to” and logs get updated.

## Background reading (required, no edits)
Read the module scripts to learn the expected behavior/order, but do NOT modify them:
- sr_amp.sh (confirm FastQC/MultiQC are early steps and how they are invoked: command -v vs config keys like tools.fastqc_bin/tools.multiqc_bin)
- sr_meta.sh, lr_amp.sh, lr_meta.sh (confirm expectations are consistent)

Then read the CLI/shared runner that:
- decides execution model (host vs container)
- decides images used
- constructs PATH/env/config for the module
- decides whether to run QC stages separately (if implemented)
- writes logs and streams output

## What to fix (without running full pipelines)
### A) Ensure FastQC/MultiQC can be found and would run
Because we cannot run full workflows, implement and validate via DRY-RUN:

1) Add (or fix) a DRY-RUN validation step per pipeline that checks:
- how the module would resolve FastQC and MultiQC:
  - if module uses `command -v fastqc`, test that in the exact environment the module will run in
  - if module uses config keys (e.g. `tools.fastqc_bin`), validate that they are set and executable
- check whether the chosen execution model provides those binaries:
  - if running on host: check host has fastqc/multiqc or the CLI points to containerized equivalents
  - if running inside a container: check the container image contains fastqc/multiqc and they are on PATH

2) Make DRY-RUN print an explicit QC readiness report:
- FastQC: FOUND (path) / MISSING (explain why)
- MultiQC: FOUND (path) / MISSING (explain why)
- Where it was checked (host vs which image)
- What config/env keys were used

3) Fix the orchestration so the DRY-RUN report becomes “FOUND” for both tools for sr_amp (and other pipelines that require them).
This can be done by:
- correcting image selection (sr should use sr-tools image, not lr)
- correcting PATH injection
- correcting config defaults for tools.fastqc_bin/tools.multiqc_bin
- or defining a “QC tools container” that the CLI uses (but do not run it—only validate it would work)

### B) Logging improvements (DRY-RUN verifiable)
1) Ensure a run always produces:
- `run_dir/logs/` directory
- a top-level run log file that is appended to during all stages
2) In DRY-RUN:
- write a structured “plan log” that shows the exact commands that WOULD be run for FastQC and MultiQC (and where outputs would go)
- show which environment would execute them (host vs container) and which mounts/paths would be used
3) Improve verbosity:
- Add a `--vv` mode that prints tool discovery + command plan lines even in dry-run

### C) Do NOT run pipelines; only dry tests
Implement/repair a `--dry-run` mode (or a `preflight` command) that:
- does not execute the pipeline
- does all tool discovery checks
- prints the planned command(s) for early QC stages
- verifies files/paths/mounts exist and are writable

## Required dry-run tests to run (only these)
Run these after changes and show output:

1) sr_amp dry-run (single-end):
python3 -m cli run -p sr_amp -i main/data/test_inputs/ERR10233589_1.fastq.gz -o main/data/outputs --run-id sr_amp_dry1 --sample-type vaginal --valencia -v --dry-run

2) sr_amp dry-run (paired-end):
python3 -m cli run -p sr_amp -i main/data/test_inputs/ERR10233586_1.fastq.gz main/data/test_inputs/ERR10233586_2.fastq.gz -o main/data/outputs --run-id sr_amp_dry2 --sample-type vaginal --valencia -v --dry-run

Expected DRY-RUN output must clearly show:
- FastQC: FOUND + where
- MultiQC: FOUND + where
- planned commands that would run early
- log file paths that were written/updated

If either tool is still missing:
- identify why (wrong image, missing binaries, PATH not set, config mismatch)
- fix the smallest shared/orchestration issue
- re-run dry-run until both are FOUND.

## Deliverables
- List files changed.
- Provide full contents of each changed file.
- Paste the dry-run outputs proving FastQC and MultiQC are FOUND and would run first.
- Show the created/updated log files (paths + brief snippets) proving logs are being written even in dry-run.

Do NOT commit.
Do NOT use planning mode.
Do NOT run full pipelines — DRY-RUN ONLY.
