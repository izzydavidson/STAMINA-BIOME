# lr_meta Validation Run — Corrected CAMISIM Communities

**Date:** 2026-07-16
**Scope:** Regenerate CAMISIM long-read (Nanopore/NanoSim3) mock data for all four body sites from the corrected genome set (see `CAMISIM_audit_report.md`), then run STAMINA-BIOME's `lr_meta` pipeline on each against the existing `custom_db/{site}` Kraken2 databases.

## Update: databases rebuilt, re-validated — all four sites now 100%

The database gaps identified below were fixed (see `Kraken2_database_rebuild_report.md` for full detail) and the identical `lr_meta` runs (same fastq inputs, same parameters) were repeated against the rebuilt databases:

| Site | Recall before DB rebuild | Recall after DB rebuild |
|---|---|---|
| Vaginal | 0/14 (0%) | **14/14 (100%)** |
| Gut | 12/12 (100%) | **12/12 (100%)** — DB unchanged |
| Oral | 10/11 (91%) | **11/11 (100%)** |
| Skin | 8/9 (89%) | **9/9 (100%)** |

Results at `/Volumes/MyPassport/stamina_biome_camisim_rerun_dbfixed/lr_meta_{site}/`. Vaginal in particular shows clean recovery with abundance ordering matching the simulated distribution (*L. crispatus* 54% observed vs. 45.5% simulated combined across 3 strains; *L. iners* 13% vs. 18.5%) and negligible cross-classification noise. The findings and root-cause analysis below (from the pre-rebuild run) are kept for the audit trail.

---

## Parameters used (per site, as specified)

| Site | Confidence | Min Hit Groups | Min-qscore | Min read length | Host depletion | Bracken readlen |
|---|---|---|---|---|---|---|
| Vaginal | 0.02 | 2 | 10 | disabled (not a pipeline option — no length filter is ever applied) | disabled | 1500 |
| Gut | 0.03 | 4 | 10 | disabled | disabled | 1500 |
| Oral | 0.04 | 4 | 10 | disabled | disabled | 1500 |
| Skin | 0.03 | 4 | 10 | disabled | disabled | 1500 |

Full pipeline run in every case (no `--no-bracken`, `--no-postprocess`, `--no-finalize`, `--no-qc-in-final`, or `--no-container` flags).

## Step 1 — CAMISIM regeneration

Stale pre-correction simulated reads (dated Mar 27 / Jul 10, i.e. before the genome corrections) were moved aside and all four communities were re-simulated from scratch via `validation/run_camisim_lr.sh` (Nextflow + NanoSim3, 0.5 Gbp per community, matching the existing convention). All four completed successfully — 59 Nextflow tasks succeeded, 0 failed, ~2.6 CPU-hours total.

| Site | Output | Size |
|---|---|---|
| Vaginal | `camisim_output_sr/mock_metagenome_vaginal/nanopore/sample_0/reads/fastq/sample_0.fq.gz` | 565 MB |
| Gut | `.../mock_metagenome_gut/.../sample_0.fq.gz` | 567 MB |
| Oral | `.../mock_metagenome_oral/.../sample_0.fq.gz` | 566 MB |
| Skin | `.../mock_metagenome_skin/.../sample_0.fq.gz` | 567 MB |

## Step 2 — lr_meta runs

All four runs completed without pipeline errors (QC → classification → Bracken → Valencia (vaginal only) → postprocessing → finalization all ran to completion). Output: `/Volumes/MyPassport/stamina_biome_camisim_rerun_corrected/lr_meta_{site}/`. **However, run "success" (no crash) is not the same as classification correctness — results diverge sharply by site:**

| Site | Declared community species | Correctly recovered | Recall |
|---|---|---|---|
| **Gut** | 12 | **12** | **100%** |
| **Oral** | 11 | **10** | **91%** (missing *Porphyromonas gingivalis*) |
| **Skin** | 9 | **8** | **89%** (missing *Malassezia restricta*) |
| **Vaginal** | 14 unique species | **0** | **0%** — complete failure |

### Gut — clean pass

All 12 declared species recovered at their exact corrected taxid, with plausible abundance ordering relative to `distribution_0.txt` (e.g. *B. thetaiotaomicron* highest at 24.1% observed vs. 15.0% simulated abundance — read-count skew from genome-size/mappability differences is expected and normal). No investigation needed.

### Oral — near-clean pass, one isolated gap

10/11 species recovered cleanly, with sensible abundances and the expected low-level cross-classification noise between closely related species (*S. mitis*/*S. oralis*, *S. salivarius*/*S. parasanguinis* — these species pairs are notoriously difficult to distinguish by k-mer content and this kind of spillover is normal/expected, not a defect).

**Missing:** *Porphyromonas gingivalis* (taxid 837) — zero reads classified to it anywhere in `results.csv`, the raw `.kreport`, or the Bracken `.breport`.

**Root cause (verified directly, not inferred):** `custom_db/oral/seqid2taxid.map` contains **zero sequences** mapped to taxid 837. The database simply has no reference genome for *P. gingivalis* at all — this is a database content gap, not a Kraken2 parameter or CAMISIM issue. By contrast, *T. forsythia* (taxid 28112, the other species corrected in this audit) has 10 sequences in the same map and was classified correctly, confirming the pipeline and corrected ground truth are both working — the DB is just missing this one specific organism.

### Skin — near-clean pass, one isolated gap

8/9 species recovered cleanly with sensible abundances.

**Missing:** *Malassezia restricta* (taxid 76775) — zero reads classified anywhere in the output.

**Root cause (verified directly):** `custom_db/skin/seqid2taxid.map` contains zero sequences for taxid 76775. Same failure mode as oral's *P. gingivalis* gap — an isolated missing reference genome in the database, not a pipeline defect.

### Vaginal — complete failure, fully root-caused

**Zero of the 14 declared vaginal community species were recovered.** Every read was misclassified to unrelated organisms — e.g. *Lactobacillus acidophilus* and *Lactobacillus mulieris* (37% each) instead of any of the three declared *L. crispatus* strains or *L. iners*; *Gardnerella greenwoodii* (11.8%) instead of *G. vaginalis*/*leopoldii*/*piotii*; *Hoylesella timonensis*, *Peptoniphilus* spp., *Sneathia sanguinegens* and other taxa that were never part of this community at all.

**Root cause, directly verified:**
- `custom_db/vaginal/seqid2taxid.map` has **zero sequences** mapped to *any* of the 14 declared species' taxids (47770, 147802, 109790, 1596, 1633, 2702, 2792978, 2792977, 82135, 28125, 2052, 1311, 2130, 33034 — checked individually, all zero).
- The database has only **794 total sequences**, versus 18,630 (oral), 22,621 (gut), and a comparable count for skin — roughly **23–28× smaller** than the other three site databases.
- `databases/vaginal/genome_list.tsv` (the manifest used to build this DB) lists the 17 CAMISIM-layer genomes as `camisim_simulation` source with the note *"Custom assembly; no GCF accession"* — i.e., these entries are meant to be added directly from local FASTA files (`camisim_genomes/vaginal/fasta/*.fa`) rather than fetched fresh from NCBI by accession at build time. By contrast, gut/oral/skin's manifests list real GCF/GCA accessions for their CAMISIM-layer entries, which get independently (re-)fetched from NCBI during the DB build — decoupling their correctness from whatever happened to be sitting in `camisim_genomes/` at build time.
- This asymmetry explains the site-specific pattern precisely: gut/oral/skin's accession-driven builds pulled correct reference genomes for their common backbone species regardless of the (also broken, pre-correction) local CAMISIM files, and only lost the handful of species genuinely absent from the broader RefSeq backbone (*P. gingivalis*, *M. restricta*). Vaginal's local-file-driven build had nothing correct to fall back on — its dominant taxa (*Lactobacillus*, *Gardnerella*) are exactly the ones affected by major, recent taxonomic revisions and are consequently less consistently covered by a generic `kraken2-build --download-library bacteria` backbone pull, so when the local, custom-assembly layer failed to load (794 sequences total is far short of the "112 RefSeq representative genomes" the manifest claims plus 17 CAMISIM genomes), there was no successful fallback and the database ended up almost empty for this body site.

**This is a Kraken2 database defect, not a CAMISIM or pipeline defect.** The corrected CAMISIM vaginal community itself is verified correct (see `CAMISIM_audit_report.md` — 17/17 genomes and taxids independently NCBI-confirmed). The `lr_meta` pipeline ran correctly end-to-end. The failure is entirely attributable to `custom_db/vaginal` never having been properly (re)built with working reference content.

## Conclusion

CAMISIM regeneration and the `lr_meta` pipeline itself are both working correctly — confirmed by gut's clean 100% pass and oral/skin's 91%/89% passes with fully explained single-species gaps. **The Kraken2 databases are the limiting factor, not the corrected ground truth or the pipeline**, and this was flagged as an open risk before this validation run was started (the databases have not yet been through the Phase 3/4/7/8 NCBI-verification-and-rebuild process applied to the CAMISIM communities in this session).

**This validation run cannot be considered a genuine pass for vaginal, and is not fully conclusive for oral/skin, until the databases are corrected:**
- `custom_db/vaginal` needs a full rebuild — its current content is almost entirely missing.
- `custom_db/oral` needs *P. gingivalis* (taxid 837) added.
- `custom_db/skin` needs *M. restricta* (taxid 76775) added.
- `custom_db/gut` required no changes based on this test.

Rebuilding the Kraken2 databases (Phase 7/8 of the overall audit plan) was out of scope for this run and has not been done. Once rebuilt, this validation should be re-run to confirm.
