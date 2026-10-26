# Databases Guide

STAMINA-BIOME uses reference databases to classify microbiome reads. This guide covers how to download, set up, and build databases for each pipeline type.

---

## Which Database Do I Need?

| Pipeline | Database type | Recommended |
|----------|--------------|-------------|
| `lr_meta` | Kraken2 | STAMINA-BIOME body-site database or Kraken2 Standard |
| `sr_meta` | Kraken2 | STAMINA-BIOME body-site database or Kraken2 Standard |
| `lr_amp` (full-length 16S) | Emu | Emu default (bundled) |
| `lr_amp` (partial 16S) | Kraken2 | Kraken2 Standard or SILVA |
| `sr_amp` | QIIME2 classifier | SILVA 138 classifier |

---

## STAMINA-BIOME Body-Site Databases (Recommended)

These are curated Kraken2 databases built specifically for each body site. They contain only organisms that are relevant to that microbiome, which reduces false positives and improves sensitivity compared to large general-purpose databases.

Each database ships with Bracken kmer_distrib files for read lengths of 500, 750, 1000, 1200, 1500, and 2000 bp.

### Available databases

| Database | Body site | Contents |
|----------|-----------|----------|
| `stamina-biome-vaginal` | Vaginal | All CST-relevant *Lactobacillus* spp., *Gardnerella*, BV anaerobes, STI pathogens, vaginal fungi. Built from 112 RefSeq representative genomes + simulation-derived strains. |
| `stamina-biome-gut` | Gut | Gut-relevant commensals and pathogens. Validated against CAMISIM-simulated ground truth (100% species recovery at default thresholds). |
| `stamina-biome-oral` | Oral | Oral-relevant species including periodontal organisms. Validated against CAMISIM-simulated ground truth (100% species recovery at default thresholds). |
| `stamina-biome-skin` | Skin | Skin-relevant species including *Staphylococcus*, *Cutibacterium*, *Malassezia* and others. 161 taxids across bacteria and fungi. |

### Download

**Option 1 — Setup wizard (recommended):**

```bash
stamina-biome setup
```

**Option 2 — Zenodo:**

All STAMINA-BIOME body-site databases are archived on Zenodo: [https://doi.org/10.5281/zenodo.19617383](https://doi.org/10.5281/zenodo.19617383). Download the `.tar.gz` archive for the database you need and extract it to a directory of your choice.

**Option 3 — Build from source:**

Build scripts for constructing or extending each body-site database are available in the `validation/` directory of this repository. These scripts use publicly available genomes from NCBI RefSeq and can be adapted to add organisms relevant to your samples.

### Using a body-site database

```bash
stamina-biome run --pipeline lr_meta \
  --input reads/ \
  --sample-type vaginal \
  --db /path/to/stamina-biome-vaginal

stamina-biome run --pipeline lr_meta \
  --input reads/ \
  --sample-type gut \
  --db /path/to/stamina-biome-gut
```

---

## Generic Kraken2 Databases

Use these for general-purpose classification or when a body-site database doesn't cover your sample type.

| Database | Download size | Disk space | Best for |
|----------|--------------|-----------|---------|
| Standard-8 | ~8 GB | ~8 GB | Most use cases — good balance of coverage and speed |
| Standard-16 | ~16 GB | ~16 GB | Broader coverage |
| Standard | ~50 GB | ~50 GB | Comprehensive bacterial/viral/fungal coverage |
| PlusPF | ~87 GB | ~87 GB | Includes protozoa and fungi |

### Download via setup wizard

```bash
stamina-biome setup
# Follow prompts and select the database you want to download
```

### Download manually

```bash
# Using kraken2-build (requires kraken2 installed)
kraken2-build --download-library bacteria --db /path/to/my-db
kraken2-build --build --db /path/to/my-db --threads 8

# Or download a pre-built database directly
# See: https://benlangmead.github.io/aws-indexes/k2
```

After downloading, you also need to build Bracken kmer_distrib files (see [Bracken](#bracken-kmer-distribution-files) below).

---

## Bracken kmer Distribution Files

Bracken re-estimates species-level abundances after Kraken2 classification. It needs a `database<N>mers.kmer_distrib` file inside your database directory, where `<N>` matches your expected read length.

**STAMINA-BIOME body-site databases already include these files** for 500, 750, 1000, 1200, 1500, and 2000 bp.

For third-party databases, build them yourself:

```bash
# Inside a Bracken-capable container or with Bracken installed locally
bracken-build -d /path/to/db -t 8 -l 1200 -x /path/to/kraken2/

# Or using STAMINA-BIOME's Docker container
docker run --rm \
  -v /path/to/db:/db \
  stamina-biome-tools-lr:dev \
  bracken-build -d /db -t 8 -l 1200
```

Build one file for each read length you expect to use. For ONT long reads, 1200 or 1500 bp is typical. For Illumina short reads, 150 bp is standard.

---

## Emu Database (lr_amp full-length 16S)

The Emu database is used by the `lr_amp` pipeline for full-length 16S classification. The default Emu database (rdp) is downloaded automatically during setup:

```bash
stamina-biome setup
```

The default database covers 280,000+ species from the RDP database and is sufficient for most long-read 16S amplicon workflows.

To use a custom Emu database:

```bash
stamina-biome run --pipeline lr_amp \
  --input reads/ \
  --emu-db /path/to/custom-emu-db
```

---

## QIIME2 Classifier (sr_amp)

The `sr_amp` pipeline uses a QIIME2 Naive Bayes classifier trained on SILVA 138 sequences.

Download from the [QIIME2 data resources page](https://docs.qiime2.org/2024.5/data-resources/) — choose the classifier matching your primer region:

| Region | Classifier file |
|--------|----------------|
| V3–V4 (most common) | `silva-138-99-seqs-515-806.qza` |
| V4 full | `silva-138-99-nb-classifier.qza` |
| V1–V3 | `silva-138-99-seqs-27-338.qza` |

Specify the path when running:

```bash
stamina-biome run --pipeline sr_amp \
  --input reads/ \
  --qiime2-classifier /path/to/silva-138-99-nb-classifier.qza \
  --primer-f CCTACGGGNGGCWGCAG \
  --primer-r GACTACHVGGGTATCTAATCC
```

---

## Building a Custom Kraken2 Database

You can build a database from your own genome collection. This is useful if you want to include organisms not in standard databases, or create a lean database for a specific microbiome.

### Prerequisites

- A FASTA file for each genome you want to include
- Each FASTA sequence header must include a valid NCBI Taxonomy ID in the format: `>sequence_name|kraken:taxid|<taxid>|rest_of_name`
- The NCBI taxonomy database (downloaded automatically by kraken2-build)

### Step 1 — Create the database and download taxonomy

```bash
kraken2-build --download-taxonomy --db /path/to/my-custom-db --threads 8
```

### Step 2 — Add genomes to the library

For each genome FASTA file:

```bash
kraken2-build --add-to-library genome1.fasta --db /path/to/my-custom-db
kraken2-build --add-to-library genome2.fasta --db /path/to/my-custom-db
# ... repeat for all genomes
```

> **Important:** After adding genomes, delete `seqid2taxid.map` if it exists in the database directory before building. Otherwise, custom sequences may be assigned taxid=0 and not classified.

```bash
rm -f /path/to/my-custom-db/seqid2taxid.map
```

### Step 3 — Build the database

```bash
kraken2-build --build --db /path/to/my-custom-db --threads 8
```

### Step 4 — Build Bracken kmer_distrib files

```bash
bracken-build -d /path/to/my-custom-db -t 8 -l 1200
bracken-build -d /path/to/my-custom-db -t 8 -l 1500
```

### Step 5 — Test the database

```bash
stamina-biome run --pipeline lr_meta \
  --input /path/to/test-reads.fastq \
  --db /path/to/my-custom-db \
  --dry-run
```

---

## Database Troubleshooting

### "database not found" or Kraken2 errors at runtime

Check that the database directory contains all three required files:
- `hash.k2d`
- `taxo.k2d`
- `opts.k2d`

If any are missing, the database build did not complete successfully. Re-run `kraken2-build --build`.

### Bracken not running — missing kmer_distrib file

STAMINA-BIOME looks for a file like `database1500mers.kmer_distrib` in your database directory. If it isn't there, run `bracken-build` (see above). STAMINA-BIOME will fall back to raw Kraken2 counts if no kmer_distrib file is found, and will print a notice in the log.

### Custom genomes not being classified (taxid=0)

This happens when `seqid2taxid.map` is stale. Delete it and rebuild:

```bash
rm /path/to/db/seqid2taxid.map
rm /path/to/db/hash.k2d /path/to/db/opts.k2d /path/to/db/taxo.k2d
kraken2-build --build --db /path/to/db --threads 8
```

### Very low classification rates

- Check that your `--sample-type` matches your database (e.g. don't use the vaginal database for a gut sample)
- Try lowering `--confidence` (e.g. to `0.01`) and see if classification improves
- Check read quality — very short or low-quality reads classify poorly
- Verify that the species you expect are actually in the database

---

## Simulating Communities with CAMISIM (Validation / Testing)

[CAMISIM](https://github.com/CAMI-challenge/CAMISIM) is a tool for simulating realistic metagenomic datasets from known genome collections. It is useful for validating classification accuracy with ground-truth data.

### Install CAMISIM

```bash
git clone https://github.com/CAMI-challenge/CAMISIM.git
cd CAMISIM
pip install -r requirements.txt
```

### Prepare a genome collection

You need FASTA files for the organisms you want to simulate, and a metadata file mapping each genome to its NCBI taxonomy ID.

```bash
# metadata.tsv format:
# genome_id   ncbi_taxid   source_accession
GCF_000001405   9606   GCF_000001405.40
GCF_000005845   511145   GCF_000005845.2
```

### Configure and run

```bash
# Edit config/mini.ini to point to your genomes and set simulation parameters
python metagenomesimulation.py config/mini.ini
```

Output includes:
- Simulated FASTQ reads (use these as input to STAMINA-BIOME)
- `taxonomic_profile_0.txt` — ground truth species abundances for validation

### Validating STAMINA-BIOME output against ground truth

Once you have CAMISIM output and a STAMINA-BIOME results file, use the validation scripts in the `validation/` directory:

```bash
Rscript validation/generate_bodysite_validation.R \
  gut \
  /path/to/camisim_output/taxonomic_profile_0.txt \
  /path/to/outputs/my_run/results/tables/results.csv \
  output_validation.png
```

This generates a 6-panel figure comparing STAMINA-BIOME's classified abundances against the CAMISIM ground truth.
