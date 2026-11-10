# Custom DB rebuild plan — November 2026 (gut, oral, skin)

## Outcome (2026-11-06) — all three rebuilt and passed

| DB | Added | Minimizers (July → now) | CAMISIM mock, before vs after | Notes |
|---|---|---|---|---|
| Gut | 38 / 38 | 1.3 GB index, rebuilt | Bray-Curtis 0.000, 12/12 species, 0 FP | *H. mulieris* now 7.6–10 % in Test6 gut; classified fraction 58–59 % → 65–66 % (Med/High) |
| Oral | 30 / 32 | 117 M → 152 M | Bray-Curtis 0.000, 21/21 species, 0 FP | *S. pneumoniae* and *S. infantis* **excluded**: mitis-group false positives in the mock (0.42 % / 0.14 %), taking reads from *S. mitis*. Rows are commented out in `oral/additions_2026-11.tsv`; their genomes are in `_rebuild_2026-11/oral/staging/` and not indexed |
| Skin | 61 / 61 | 176 M → 300 M | Bray-Curtis 0.000, 10/10 species, 0 FP | 5 genomes in the **July** skin DB carried a wrong or genus-only label next to the correct one (see below); fixed |
| Vaginal | — | — | — | Nothing missing |

**Skin label fix.** These accessions were in the July skin map under a second taxid. The bad
labels were removed and the NCBI assembly's species kept (13 map lines, backup in
`_rebuild_2026-11/skin/seqid2taxid.map.before_relabel_fix`):

| Genome | July label | Kept (NCBI) |
|---|---|---|
| NZ_LS483460.1 (GCF_900478045.1, NCTC 10288) | *C. tuberculostearicum* 38304 — **wrong species** | *C. minutissimum* 38301 |
| NC_010729.1 (*P. gingivalis* ATCC 33277) | genus *Porphyromonas* 836 | 837 |
| NC_083370–8 (*M. japonica* CBS 9431) | genus *Malassezia* 55193 | 223818 |
| NZ_CP065738.1 | genus *Rothia* 32207 | *R. kristinae* 37923 |
| NC_003450.3 | genus *Corynebacterium* 1716 | *C. glutamicum* 1718 |

So results from the July skin DB reported *C. minutissimum* reads as *C. tuberculostearicum*,
and reported the other four only at genus level. *C. tuberculostearicum* keeps its 15 genuine
sequences. Gut, oral and vaginal had no cross-labelled accessions.

**Test6 Skin Med contains a lot of *Klebsiella* (≈ 31 % of species-level reads).** This was already
in the July skin DB's results: *K. pneumoniae* at 24 %, which was in the July DB. The rebuild
splits it as *K. pneumoniae* 27 % + *K. aerogenes* 4 % (new), plus *E. cloacae* 1 % (new).
(*K. pneumoniae* doesn't appear in the rebuild's compare report because that report lists only
added species.) core_nt agrees the signal is real: 613 of its 1,179 classified Skin Med reads are
Enterobacterales. But it resolves them only to genus (4 reads reach *K. michiganensis*), so
Bracken dropped them from the comparison chart. Species-level *Klebsiella* calls are uncertain.
Given that it's a skin swab and Skin Low has none, contamination is most likely.

**Problems hit during the run, now handled by `rebuild_site_db.sh`:**
1. Docker Desktop's mount of the NTFS drive makes a recursive `find library/` return nothing
   (directories report nlink 0). The first gut build indexed 0 sequences. The script now
   mounts patched copies of `build_kraken2_db.sh` and `bracken-build` that search
   `library/added/` directly, and stops if a build processes 0 sequences.
2. The July maps contain thousands of harmless same-taxid duplicate seqids. The check now
   fails only on new collisions, on conflicting taxids, or when an accession maps to
   more than one taxid (the skin problem).
3. `hash.k2d`'s file size is a pre-allocated capacity, not content. The check compares
   stored minimizers (`kraken2-inspect --skip-counts`) instead.
4. The Bracken sequence-count check allows for genomes that were moved out of the library
   on purpose (the two excluded *Streptococcus*).

**Still to do:** re-run Test_FeMHS_471_Test6 in the app so its final tables use the new DBs.
Re-run the full CAMISIM `lr_meta` validation for gut, oral and skin, and update
`validation/*_report.md` for the paper. Delete the backups
(`/Volumes/MyPassport/custom_db/_rebuild_2026-11/*/backup`, ~2 GB each) once you're happy.

---

## Why

An audit of all four custom Kraken2 DBs on 2026-11-06 found that a large share of the July
`expand_all_sites.py` additions were **downloaded but never indexed**. The script writes FASTAs
straight into `library/added/` but never runs `kraken2-build --add-to-library`. With no
`prelim_map_*.txt` entry, `kraken2-build --build` silently skips the files.

| DB | July additions | Indexed | Never indexed | Plus new | Total to add |
|---|---|---|---|---|---|
| Vaginal | 50 | 49 | 0 (*L. psittaci* excluded on purpose) | — | **nothing to do** |
| Gut | 116 | 83 | 32 + *V. parvula* | 5 species seen by core_nt in Test6 | **38** |
| Oral | 102 | 70 | 32 | — | **32** |
| Skin | 188 | 127 | 61 | — | **61** |

- In Test6, the core_nt comparison found species missing from the site DBs **only in gut**.
  Oral and skin had no comparison-only species.
- All 126 orphaned files were checked. Every header carries the correct
  `kraken:taxid|T|`, every genome is full-size, and every taxid exists in the DB's
  taxonomy. They are reused as they are; only the 5 new gut genomes are downloaded.
  The 6 additions that skin's validation flagged as large are fungal genomes: *Aspergillus* ×3,
  *Trichophyton*, *Microsporum* and *Lodderomyces*, 16–38 Mb each.
- Deliberate curation is kept. The removed contaminants are gut *Salinispora*/*Acidothermus*,
  oral *Aquabacterium* and skin ×8, plus vaginal *L. psittaci*. None of them is in an
  additions list, and the build refuses to bring them back (see "verify").
- The full lists, with the reason for each genome, are in
  `databases/{gut,oral,skin}/additions_2026-11.tsv`.

## How (and the traps it avoids)

`databases/rebuild_site_db.sh <site> <phase…>` does the work for one site;
`databases/rebuild_all_dbs.sh` runs gut → oral → skin in order. Work files (backups,
staging, reports, logs) go to `/Volumes/MyPassport/custom_db/_rebuild_2026-11/<site>/`.

| Phase | What it does |
|---|---|
| `preflight` | Checks Docker, the image, the drive (≥ 20 GB free; 120 GB now) and the validation inputs |
| `baseline` | Classifies the site's CAMISIM mock + its Test6 samples with the **current** DB, using the validated site parameters (gut 0.03/4, oral 0.04/4, skin 0.03/4; Bracken 1500) |
| `stage` | Moves each orphan out of `library/added/` into staging, downloads anything not on disk, and validates headers, taxids and sizes |
| `backup` | Copies `hash/opts/taxo.k2d`, `seqid2taxid.map`, `database.kraken`, both Bracken files and `prelim_map.txt` |
| `add` | Runs `kraken2-build --add-to-library` per genome. **Appends** the new seqids to the existing map instead of regenerating it, so curated exclusions survive. Checks there are no duplicate seqids |
| `build` | Deletes the old index **and `database.kraken`** (otherwise `bracken-build` silently reuses it), then runs `kraken2-build --build` |
| `bracken` | `bracken-build -l 150` and `-l 1500` (k = 35) |
| `verify` | Every output must be newer than the build start. Every addition must have seqs in the map, direct minimizers in `kraken2-inspect`, and genome entries in both `kmer_distrib` files. **No taxid** may appear that was in neither the old map nor the additions |
| `after` | Repeats `baseline` against the new DB |
| `compare` | Writes the before/after report and applies the acceptance gate (below); exits non-zero on failure |
| `record` | Runs only after a pass. Appends any rows missing from `genome_list.tsv` (only the 5 new gut species; the orphans are already listed) |
| `rollback` | Restores the backup and removes the newly added library files. The index ends up exactly as it was before |

### Acceptance gate (per site, CAMISIM mock)

The mocks contain none of the 131 added species, so any reads they pull in are false positives.

- No added species above **0.1 %** of the mock.
- No mock species that was above 0.1 % before may disappear.
- Mock profile Bray-Curtis before vs after **≤ 0.05**.

If a site fails, the wrapper stops before moving on to the next site. The new DB stays in
place so you can inspect it. Then either accept it (`… <site> record`) or undo it
(`… <site> rollback`). **Some risk is expected:** the closest relatives of current mock
species are the most likely to trip the gate. Examples: skin *Malassezia sympodialis*/*pachydermatis*
next to *M. restricta*, and oral *Streptococcus pneumoniae* and *S. infantis* next to *S. mitis*/*oralis*.
If that happens, the report names the exact species to drop.

The Test6 samples aren't gated, because they have no ground truth. For gut, expect
*H. mulieris* at about 5–10 %, a higher classified fraction, and a small shift from
*B. thetaiotaomicron* to *B. faecis*.

## Running it

About **5–6 h** in total, unattended: roughly 1.5–2 h each for gut and oral, and ~2 h for
skin because of the larger fungal genomes. The Mac has to stay awake with the drive
mounted. Don't edit the scripts while they run. A re-run skips sites that have already completed.

```bash
cd ~/Desktop/STAMINA-BIOME
bash databases/rebuild_all_dbs.sh 2>&1 | tee ~/db_rebuild_2026-11.log
```

One site at a time instead:

```bash
bash databases/rebuild_site_db.sh gut all
```

Results to read afterwards: `/Volumes/MyPassport/custom_db/_rebuild_2026-11/<site>/compare_report.txt`.

## After it passes

1. Re-run `Test_FeMHS_471_Test6` in the app so the final tables and plots use the rebuilt DBs.
2. Re-run the CAMISIM `lr_meta` validation for gut/oral/skin with the full pipeline, and
   update `validation/lr_meta_corrected_validation_report.md` and
   `validation/Kraken2_database_rebuild_report.md`. The databases changed, so the published
   recall/FP table needs fresh numbers.
3. Add the 5 new gut taxa to `GUT_TAXA` in `databases/expand_all_sites.py`.
4. Once everything has been checked, delete the backups (~2 GB per site).

## Known list issues (not blocking)

- `databases/skin/genome_list.tsv` lists *Cutibacterium acnes* under taxid **1743460**,
  which is *Allopiophila luteata*. The DB correctly indexes *C. acnes* under **1747**.
- `databases/gut/genome_list.tsv` lists *B. longum* as 1678. The DB indexes it as
  *B. longum* subsp. *longum* (216816), which is fine.
- `databases/gut/build.sh` describes a RefSeq-backbone build. That isn't how the deployed
  147-taxon DB was built, so the script doesn't reproduce it.
