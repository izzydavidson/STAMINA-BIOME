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

---

## Directory Structure

```
databases/
├── README.md          (this file)
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
