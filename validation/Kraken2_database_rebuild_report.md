# Kraken2/Bracken Database Rebuild Report

**Date:** 2026-07-16
**Trigger:** `lr_meta_corrected_validation_report.md` found that `custom_db/vaginal` was almost empty (0/14 declared community species recoverable) and `custom_db/oral`/`custom_db/skin` were each missing one species (*P. gingivalis*, *M. restricta*). `custom_db/gut` needed no changes.

## Oral — targeted fix

Added *Porphyromonas gingivalis* (GCF_000010505.1, ATCC 33277 — the standard reference strain, already NCBI-verified in the CAMISIM audit) to the existing library, rebuilt the Kraken2 index and both Bracken read-length distributions (150, 1500).

## Skin — targeted fix

Added *Malassezia restricta* (GCF_003290485.1, already NCBI-verified) to the existing library, same rebuild process.

## Vaginal — full rebuild

`custom_db/vaginal` had only 794 total sequences and zero coverage of any of the 14 declared community species' taxids (verified directly via `seqid2taxid.map`, not inferred). The old DB was preserved at `custom_db/vaginal_BROKEN_<timestamp>` (not deleted) and a fresh database was built from:

- **17 CAMISIM genomes** — the corrected, NCBI-verified genomes from the CAMISIM audit (reused directly, not re-downloaded).
- **49 expansion genomes** — from `databases/vaginal/genome_list.tsv`'s `expand_all_sites.py` additions (a well-curated, literature-cited 51-entry candidate list that was apparently prepared to fix this exact gap but never successfully built into the deployed database). Per instruction, none of these were trusted from the file — **all 50 accessions were independently re-verified against live NCBI** (Datasets API) before use. 49/50 passed cleanly; **1 excluded**: *Lactobacillus psittaci* (GCF_000425905.1) — its genome checks out clean on NCBI's own QC (98% complete, 0.16% contamination, confirmed species match), but it had already been moved to a `removed_contaminants/` folder by a prior curation pass, and *L. psittaci* is a psittacine (parrot)-associated species of doubtful relevance to a human vaginal microbiome database — that prior exclusion was respected rather than overridden.

Result: 66 genomes, 844 total sequences, taxonomy downloaded fresh (see bug #3 below for how). All 14 core taxids and every spot-checked expansion taxid (*Chlamydia trachomatis*, *Neisseria gonorrhoeae*, *Treponema pallidum*, *Trichomonas vaginalis*, *Candida albicans*, *Mycoplasmoides genitalium*) confirmed present in the final Bracken output.

## Infrastructure bugs found and fixed during the rebuild

All three were silent-failure traps — each would have left a corrupted or stale database while reporting success, if not directly verified.

**1. `bracken-build` couldn't find `kmer2read_distr` on `PATH`.**
The Docker image (`stamina-biome-tools-lr:dev`) only ships the tool's source (`/opt/bracken/src/kmer2read_distr.cpp`), not a compiled binary, and it isn't installed anywhere on `PATH`. Fixed by mounting a pre-compiled ARM64 Linux binary already present in this repo at `validation/bracken_build_helpers/kmer2read_distr` (evidence this exact problem was hit and solved once before) into `/usr/local/bin/kmer2read_distr` inside the container.

**2. Missing `generate_kmer_distribution.py` caused a silent false-success.**
Fixing bug #1 alone wasn't enough — `bracken-build`'s fallback branch also expects `generate_kmer_distribution.py` on `PATH`. When it isn't found, a shell quirk in `bracken-build`'s own `[ -f $(command -v ...) ]` check evaluates true on the empty result, and the script runs `python -i /db/database<N>mers.kraken` — Python's `-i` flag, not the intended `-i <input-file>` argument — which tries to parse the binary kraken output file as Python source, throws `SyntaxError: source code cannot contain null bytes`, and drops into a dead interactive prompt. **`bracken-build` does not check this step's exit code**, so it prints "Finished creating database saved and kmer_distrib" regardless and continues — leaving the actual `.kmer_distrib` file untouched (stale, from before the rebuild). This was only caught by directly checking file modification timestamps and grepping for the target taxid in the output file, not by trusting the log. Fixed by also mounting `validation/bracken_build_helpers/generate_kmer_distribution.py` into `/usr/local/bin/` alongside the binary. All subsequent runs verify the target taxid is actually present in the output file before proceeding.

**3. `kraken2-build --download-taxonomy` requires `rsync`, which isn't installed in the image.**
Hit while starting the vaginal rebuild from scratch (oral/skin already had taxonomy directories from before). Worked around by extracting `nodes.dmp`, `names.dmp`, `merged.dmp`, and `delnodes.dmp` directly from the NCBI taxdump already present at `CAMISIM/camisim_genomes/ncbi_taxonomy/taxdump.tar.gz` (the same taxonomy data the other three databases use) instead of depending on the broken in-container download path.

**Also survived one unrelated Docker Desktop crash** (user restarted Docker mid-build) with zero data loss — the Kraken2 index for skin had already been fully written to the mounted volume before the crash, so only the interrupted Bracken step needed to be redone.

## Final verification (independent, content-based — not log-based)

For every rebuilt database: confirmed fresh file timestamps, confirmed file sizes changed as expected, and directly grepped the final `.kmer_distrib` files for the target taxid(s) rather than trusting any "success" message. All checks passed. Full end-to-end confirmation came from re-running the `lr_meta` validation pipeline against the rebuilt databases — see the update at the top of `lr_meta_corrected_validation_report.md`: all four sites now recover 100% of their declared community species (up from 0% vaginal, 91% oral, 89% skin; gut was already 100%).
