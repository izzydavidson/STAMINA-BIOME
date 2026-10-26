# Validation Scripts

This directory contains scripts and configuration files used to validate STAMINA-BIOME's taxonomic classification performance.

## Scripts

| Script | Purpose |
|--------|---------|
| `sweep.sh` / `sweep_confidence.sh` / `sweep_bracken.sh` | Sweep Kraken2/Bracken parameter combinations over CAMISIM test data |
| `score.sh` | Score sweep results against ground truth |
| `rebuild_custom_dbs.sh` | Rebuild gut/oral/skin Kraken2+Bracken DBs (accepts `--db-base /path/to/custom_db`) |
| `rebuild_v5.sh` | v5 DB rebuild script (accepts `--db-base /path/to/custom_db`) |
| `prepare_camisim_genomes.py` | Prepare CAMISIM simulation genomes for DB inclusion (accepts `--db-base`) |
| `add_ncbi_strains.py` | Add additional NCBI RefSeq strains to DBs (accepts `--db-base`) |
| `generate_*.R` | Generate validation plots and comparison figures |

## Sweep Configs

The JSON files in `sweep_configs/`, `sweep_bracken_configs/`, and `sweep_confidence_configs/` are **developer reference configs** with machine-specific file paths. They are provided for reproducibility of published validation results but require updating paths (`work_dir`, `fastq`, `db`, `human_mmi`, `centroids_csv`) before use on another machine.

## Validation Data

Sweep results are pre-computed in `sweep_results/`. These represent the parameter sweep outcomes used to select recommended Kraken2 confidence and minimum-hit-groups thresholds for each body site.
