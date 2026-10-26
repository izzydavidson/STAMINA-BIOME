# STAMINA-BIOME Compare Module

Compare taxonomic profiling results across multiple pipeline runs.

## Overview

The compare module enables comparison of analysis outputs from STAMINA-BIOME pipelines (sr_amp, sr_meta, lr_amp, lr_meta). It harmonises abundance tables, computes similarity metrics, and generates comparison reports.

**Important**: This module compares ANALYSIS OUTPUTS, not raw reads. It is not a pipeline itself.

## Usage

### CLI Usage

```bash
# Compare two or more run directories
python3 -m cli compare \
  --run main/data/outputs/run1 \
  --run main/data/outputs/run2 \
  --rank genus \
  --norm relative \
  --top-n 20 \
  --outdir main/data/outputs \
  --name my_comparison \
  -v

# Compare with manual tables
python3 -m cli compare \
  --table abundance1.tsv \
  --table abundance2.tsv \
  --taxonomy taxonomy.tsv \
  --rank genus \
  --outdir ./compare_results
```

### CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `--run <path>` | Run directory or outputs.json (repeat for ≥2 runs) | - |
| `--table <path>` | Manual abundance table (repeat for ≥2 tables) | - |
| `--taxonomy <path>` | Taxonomy mapping file | - |
| `--metadata <path>` | Sample metadata file | - |
| `--rank` | Taxonomic rank: species, genus, family | genus |
| `--norm` | Normalisation: relative, clr | relative |
| `--top-n` | Number of top taxa in plots | 20 |
| `--sample-align` | Sample alignment: intersection, union | intersection |
| `--min-prevalence` | Minimum taxon prevalence (fraction) | 0.1 |
| `--group-col` | Metadata column for grouping | - |
| `--diff` | Enable differential abundance analysis | False |
| `--outdir` | Output directory | - |
| `--name` | Comparison run name | timestamp |
| `-v/--verbose` | Verbose output | False |

## Input Data Sources

### From Run Directories (Preferred)

The compare module reads `outputs.json` from each run to locate:

| Pipeline | Abundance Table | Taxonomy | Alpha Diversity |
|----------|-----------------|----------|-----------------|
| sr_amp | qiime2_exports.table_tsv | qiime2_exports.taxonomy_tsv | qiime2_artifacts.alpha_diversity_tsv |
| sr_meta | results/kraken2/*.report.tsv | (embedded) | - |
| lr_amp | results/emu/*_rel-abundance.tsv | (embedded) | - |
| lr_meta | results/kraken2/*.report.tsv | (embedded) | - |

### Fallback Paths

If outputs.json is missing, the module searches for:
- `results/qiime2/exports/table/feature-table.tsv`
- `results/qiime2/exports/taxonomy/taxonomy.tsv`
- `results/kraken2/*.report.tsv`
- `results/emu/*_rel-abundance.tsv`

### Manual Tables

Tables should be samples × taxa (rows = samples, columns = taxa) or taxa × samples. The module auto-detects orientation.

## Harmonisation Steps

All decisions are recorded in `compare_config.json`:

1. **Rank aggregation**: Collapse to specified taxonomic rank
2. **Name standardisation**: Remove prefixes (g__, s__, etc.)
3. **Sample alignment**: Match samples across runs
4. **Normalisation**: Convert to relative abundance or CLR
5. **Filtering**: Apply prevalence/abundance thresholds

## Output Structure

```
<outdir>/<name>/compare/
├── compare_config.json    # Locked configuration
├── outputs.json           # Artifact index for UI
├── report/
│   └── index.html         # HTML report
├── plots/
│   ├── stacked_bar.png
│   ├── heatmap.png
│   ├── scatter.png
│   ├── venn.png
│   ├── alpha_boxplot.png
│   └── pcoa.png
└── tables/
    ├── aligned_abundance.tsv
    ├── similarity_metrics.tsv
    ├── alpha_diversity.tsv
    ├── taxa_mapping.tsv
    └── top_differential.tsv
```

## Comparison Metrics

### Similarity
- Jaccard index (presence/absence)
- Sørensen index (presence/absence)
- Spearman correlation (abundance)
- Bray-Curtis dissimilarity

### Alpha Diversity
- Shannon index
- Simpson index
- Observed taxa (richness)
- Wilcoxon signed-rank (if paired samples)

### Beta Diversity
- PCoA (Bray-Curtis, Aitchison)
- PERMANOVA (if groups provided)

## Integration with UI

The `outputs.json` file provides artifact paths for UI discovery:

```json
{
  "module_name": "compare",
  "runs_compared": ["run1", "run2"],
  "compare_config": "compare_config.json",
  "plots": {
    "stacked_bar": "plots/stacked_bar.png",
    "heatmap": "plots/heatmap.png"
  },
  "tables": {
    "aligned_abundance": "tables/aligned_abundance.tsv"
  },
  "summary_metrics": {
    "jaccard_mean": 0.65,
    "spearman_mean": 0.82
  }
}
```

## License

Part of STAMINA-BIOME - Standardised, Technology-Agnostic Framework for Microbiome Investigation and Analysis.
