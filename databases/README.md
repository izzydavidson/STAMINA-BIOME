# STAMINA-BIOME Databases

This directory contains genome manifests and build scripts for the STAMINA-BIOME custom Kraken2 databases. These scripts reproduce every database used in the STAMINA-BIOME paper exactly.

---

## Pre-built Downloads

Pre-built database archives (Kraken2 index + Bracken kmer_distrib files for 500–2000 bp) are available on Zenodo:

| Database | Body site | Zenodo DOI |
|----------|-----------|------------|
| `stamina-biome-vaginal` | Vaginal | *[pending upload]* |
| `stamina-biome-gut` | Gut | *[pending upload]* |
| `stamina-biome-oral` | Oral | *[pending upload]* |
| `stamina-biome-skin` | Skin | *[pending upload]* |

Download and use directly with STAMINA-BIOME:

```bash
# Example — vaginal database
wget https://zenodo.org/record/XXXXXXX/files/stamina-biome-vaginal-v1.tar.gz
tar -xzf stamina-biome-vaginal-v1.tar.gz
stamina-biome run -p lr_meta -i sample.fastq --sample-type vaginal --db ./stamina-biome-vaginal
```

Or let `stamina-biome setup` handle the download interactively.

---

## Rebuilding from Scratch

Each subdirectory contains:
- `genome_list.tsv` — every genome accession, species, taxid, and source layer that went into the database
- `build.sh` — exact steps to reproduce the database

### Requirements

- Docker with the `stamina-biome-tools-lr:dev` image
- ~20 GB disk space per database (pre-build; final indexes are 1–3 GB)
- Internet access to NCBI FTP

### Database composition

Each database has two layers:

1. **RefSeq backbone** — downloaded directly via `kraken2-build --download-library bacteria` for the relevant taxonomy subset. This covers broad background organisms.
2. **Site-specific genomes** — curated assemblies chosen for accuracy at that body site:
   - CAMISIM simulation genomes (the exact assemblies used in validation)
   - Additional high-quality NCBI RefSeq assemblies for species that showed low recall in validation sweeps

All site-specific genome FASTA headers are rewritten to `>kraken:taxid|TAXID|original_id` before addition to the library, so Kraken2 maps reads to the correct species taxid.

### Build order

```
1. Download/prepare genomes        (add_ncbi_strains.py / prepare_camisim_genomes.py)
2. Add to library                  (kraken2-build --add-to-library)
3. Build Kraken2 index             (kraken2-build --build)
4. Build Bracken kmer distributions (bracken-build, run once per read length)
```

**Important:** Before rebuilding, delete `hash.k2d`, `opts.k2d`, `taxo.k2d`, and `seqid2taxid.map` from the database directory. Stale index files cause silent failures where custom sequences get assigned taxid=0.

> **Adding genomes to an existing database? Use `databases/rebuild_site_db.sh`.**
> It is the safe incremental path. It stages and validates downloads, backs up the current index,
> registers each genome with `--add-to-library`, appends to the curated `seqid2taxid.map`
> instead of regenerating it, rebuilds Kraken2 and Bracken from clean state, then verifies the
> result and compares classification before and after (with rollback). Plan and rationale:
> `databases/REBUILD_PLAN_2026-11.md`.

#### Silent-failure traps

The build tools report success in each of these cases while the database is left stale or incomplete.
The scripts in this repo now guard against all of them.

1. **A FASTA copied into `library/added/` is not part of the database.** `kraken2-build --build`
   indexes only sequences that have an entry in a `library/*/prelim_map.txt`. Only
   `kraken2-build --add-to-library` creates that entry (one `prelim_map_*.txt` per file). In July 2026,
   older versions of `expand_all_sites.py` (and `validation/add_ncbi_strains.py`) wrote files straight
   into `library/added/`. As a result, 126 gut/oral/skin genomes were downloaded but never indexed.
   `expand_all_sites.py` now downloads to `<db>/expand_staging/`, registers each file and checks
   the new prelim map. `--no-register` skips registration with a loud warning and leaves
   `genome_list.tsv` untouched. Files named `<taxid>_GCF_*_genomic.fna` in `library/added/` are
   leftovers of the old behaviour. `rebuild_site_db.sh` (phase `stage`) picks them up.
2. **`bracken-build` reuses an existing `database.kraken`.** If that file exists,
   `/opt/bracken/bracken-build` skips regenerating it. Every `database<L>mers.kmer_distrib` is then
   computed from the *old* index, even after `kraken2-build --build`. Delete `database.kraken` and all
   `database*mers.kraken` / `database*mers.kmer_distrib` before running `bracken-build`. `build.sh`,
   `build_sr.sh` and `validation/rebuild_custom_dbs.sh` now do this (`build_sr.sh --bracken-only` removes
   `database.kraken` only if it is older than `hash.k2d`). Any Bracken read lengths that a script
   does not rebuild are gone afterwards and must be rebuilt (e.g. `build_sr.sh --bracken-only` for
   75–250 bp).
3. **Deleting `seqid2taxid.map` undoes curation.** When the map is missing, `kraken2-build --build`
   regenerates it from `library/*/prelim_map.txt`. That brings back every sequence that was removed
   from a curated map (e.g. contaminant exclusions). For a DB with a curated map, pass
   `--keep-seqid-map` to `build.sh`, `build_sr.sh` or `validation/rebuild_custom_dbs.sh`. The existing
   map is then used as-is. Library sequences not in it are **not** indexed, and the scripts log how
   many there are. New genomes must therefore be appended to the map, which `rebuild_site_db.sh` and
   `expand_all_sites.py` do.

---

## Directory Structure

```
databases/
├── README.md          (this file)
├── rebuild_site_db.sh (safe incremental add + rebuild for one site DB)
├── expand_all_sites.py (download + register new genomes for one/all sites)
├── vaginal/
│   ├── genome_list.tsv
│   └── build.sh
├── gut/
│   ├── genome_list.tsv
│   └── build.sh
├── oral/
│   ├── genome_list.tsv
│   └── build.sh
└── skin/
    ├── genome_list.tsv
    └── build.sh
```

---

## Validated Parameters

These Kraken2 parameters were optimised per body site against CAMISIM ground truth:

| Body site | Confidence | Min Hit Groups | Recovery | False Positives |
|-----------|-----------|----------------|----------|-----------------|
| Vaginal | 0.02 | 2 | 100% | 0 |
| Gut | 0.03 | 4 | 100% | 0 |
| Oral | 0.04 | 4 | 100% | 0 |
| Skin | 0.03 | 4 | 100% | 0 |

STAMINA-BIOME pre-sets these automatically when you select a sample type.
