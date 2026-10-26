#!/usr/bin/env python3
"""
Data harmonisation for comparison.

Steps:
1. Aggregate to specified taxonomic rank
2. Standardise taxon names
3. Align samples across runs
4. Normalise abundances
5. Apply filters
"""

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import pandas as pd

try:
    from .run_parser import RunData
except ImportError:
    from run_parser import RunData


@dataclass
class HarmonisedData:
    """Harmonised data ready for comparison."""

    # Main abundance matrix (samples x taxa)
    aligned_abundance: pd.DataFrame

    # Run labels for each sample
    run_labels: pd.Series

    # Original run data
    runs: List[RunData]

    # Mapping from original to cleaned taxon names
    taxa_mapping: List[Dict[str, str]] = field(default_factory=list)

    # Settings used for harmonisation
    settings: Dict[str, Any] = field(default_factory=dict)

    # Missingness info (for union alignment)
    missingness: Optional[pd.DataFrame] = None


class Harmoniser:
    """Harmonise abundance data across runs."""

    # Taxonomic rank prefixes
    RANK_PREFIXES = {
        "domain": "d__",
        "kingdom": "k__",
        "phylum": "p__",
        "class": "c__",
        "order": "o__",
        "family": "f__",
        "genus": "g__",
        "species": "s__",
    }

    # Rank order for parsing lineages
    RANK_ORDER = ["domain", "kingdom", "phylum", "class", "order", "family", "genus", "species"]

    def __init__(
        self,
        rank: str = "genus",
        norm: str = "relative",
        sample_align: str = "intersection",
        min_prevalence: float = 0.1,
        min_mean_abundance: float = 0.0,
        verbose: bool = False,
    ):
        self.rank = rank
        self.norm = norm
        self.sample_align = sample_align
        self.min_prevalence = min_prevalence
        self.min_mean_abundance = min_mean_abundance
        self.verbose = verbose

    def harmonise(self, runs: List[RunData]) -> HarmonisedData:
        """
        Harmonise multiple runs.

        Args:
            runs: List of RunData objects

        Returns:
            HarmonisedData with aligned abundance matrix
        """
        if len(runs) < 2:
            raise ValueError("Need at least 2 runs to harmonise")

        all_taxa_mapping = []
        processed_dfs = []
        run_labels = []

        for run in runs:
            if run.abundance_table is None or run.abundance_table.empty:
                if self.verbose:
                    print(f"[harmonise] Skipping {run.run_id}: no abundance data")
                continue

            df = run.abundance_table.copy()

            # Ensure samples are rows
            if df.shape[0] > df.shape[1]:
                # Likely taxa are rows, transpose
                df = df.T

            # Aggregate to rank if taxonomy available
            if run.taxonomy is not None and not run.taxonomy.empty:
                df, mapping = self._aggregate_to_rank(df, run.taxonomy, self.rank)
                all_taxa_mapping.extend(mapping)
            else:
                # Try to parse rank from column names (lineage strings)
                df, mapping = self._parse_rank_from_names(df, self.rank)
                all_taxa_mapping.extend(mapping)

            # Clean taxon names
            df = self._clean_taxon_names(df)

            # Add run label
            for sample in df.index:
                run_labels.append(run.run_id)

            # Prefix sample names with run ID to avoid collisions
            df.index = [f"{run.run_id}:{s}" for s in df.index]

            processed_dfs.append(df)

        if not processed_dfs:
            raise ValueError("No valid abundance data in any run")

        # Align taxa across runs
        aligned = self._align_taxa(processed_dfs)

        # Align samples
        if self.sample_align == "intersection":
            aligned = self._align_samples_intersection(aligned, runs)
        else:
            aligned = self._align_samples_union(aligned)

        # Normalise
        if self.norm == "relative":
            aligned = self._normalise_relative(aligned)
        elif self.norm == "clr":
            aligned = self._normalise_clr(aligned)

        # Filter
        aligned = self._filter_taxa(aligned)

        if aligned.empty or aligned.shape[1] == 0:
            raise ValueError(
                "No taxa remaining after prevalence/abundance filters. "
                "Try lowering --min-prevalence (current: {}) or --min-abundance.".format(self.min_prevalence)
            )

        # Create run labels series
        run_label_series = pd.Series(
            [lbl.split(":")[0] for lbl in aligned.index],
            index=aligned.index,
            name="run"
        )

        # Build settings dict
        settings = {
            "rank": self.rank,
            "norm": self.norm,
            "sample_align": self.sample_align,
            "min_prevalence": self.min_prevalence,
            "min_mean_abundance": self.min_mean_abundance,
            "n_runs": len(runs),
            "n_samples_final": len(aligned),
            "n_taxa_final": len(aligned.columns),
        }

        return HarmonisedData(
            aligned_abundance=aligned,
            run_labels=run_label_series,
            runs=runs,
            taxa_mapping=all_taxa_mapping,
            settings=settings,
        )

    def _aggregate_to_rank(
        self,
        df: pd.DataFrame,
        taxonomy: pd.DataFrame,
        rank: str,
    ) -> Tuple[pd.DataFrame, List[Dict[str, str]]]:
        """Aggregate ASV abundances to specified taxonomic rank."""
        mapping = []

        # Build ASV -> taxon at rank mapping
        asv_to_taxon = {}

        # Expect taxonomy columns: Feature ID, Taxon, (Confidence)
        if "Feature ID" in taxonomy.columns and "Taxon" in taxonomy.columns:
            for _, row in taxonomy.iterrows():
                asv_id = row["Feature ID"]
                lineage = row["Taxon"]
                taxon_at_rank = self._extract_rank(lineage, rank)
                asv_to_taxon[asv_id] = taxon_at_rank
                mapping.append({
                    "original": asv_id,
                    "lineage": lineage,
                    "rank": rank,
                    "cleaned": taxon_at_rank,
                })

        # Aggregate
        aggregated = {}
        for col in df.columns:
            taxon = asv_to_taxon.get(col, col)
            if taxon not in aggregated:
                aggregated[taxon] = df[col].copy()
            else:
                aggregated[taxon] = aggregated[taxon] + df[col]

        return pd.DataFrame(aggregated), mapping

    def _parse_rank_from_names(
        self,
        df: pd.DataFrame,
        rank: str,
    ) -> Tuple[pd.DataFrame, List[Dict[str, str]]]:
        """Parse taxonomic rank from column names (lineage strings)."""
        mapping = []
        aggregated = {}

        for col in df.columns:
            taxon_at_rank = self._extract_rank(str(col), rank)
            mapping.append({
                "original": col,
                "rank": rank,
                "cleaned": taxon_at_rank,
            })

            if taxon_at_rank not in aggregated:
                aggregated[taxon_at_rank] = df[col].copy()
            else:
                aggregated[taxon_at_rank] = aggregated[taxon_at_rank] + df[col]

        return pd.DataFrame(aggregated), mapping

    def _extract_rank(self, lineage: str, rank: str) -> str:
        """Extract taxon name at specified rank from lineage string."""
        # Handle SILVA/QIIME format: d__Bacteria;p__Firmicutes;...;g__Lactobacillus;s__
        prefix = self.RANK_PREFIXES.get(rank, "")

        # Split lineage
        parts = re.split(r"[;|]", lineage)

        for part in parts:
            part = part.strip()
            if part.startswith(prefix):
                name = part[len(prefix):]
                if name and name != "__":
                    return name

        # Fallback: try to find by position
        rank_idx = self.RANK_ORDER.index(rank) if rank in self.RANK_ORDER else -1
        if rank_idx >= 0 and rank_idx < len(parts):
            part = parts[rank_idx].strip()
            # Remove any prefix
            for p in self.RANK_PREFIXES.values():
                if part.startswith(p):
                    part = part[len(p):]
                    break
            if part and part != "__":
                return part

        # Return last meaningful part
        for part in reversed(parts):
            part = part.strip()
            for p in self.RANK_PREFIXES.values():
                if part.startswith(p):
                    part = part[len(p):]
                    break
            if part and part not in ("", "__", "unclassified"):
                return part

        return "Unclassified"

    def _clean_taxon_names(self, df: pd.DataFrame) -> pd.DataFrame:
        """Clean and standardise taxon names."""
        new_cols = {}
        for col in df.columns:
            clean = str(col).strip()

            # Remove rank prefixes
            for prefix in self.RANK_PREFIXES.values():
                if clean.startswith(prefix):
                    clean = clean[len(prefix):]

            # Remove trailing underscores
            clean = clean.rstrip("_")

            # Normalise whitespace
            clean = re.sub(r"\s+", " ", clean)

            # Handle empty
            if not clean or clean in ("", "__"):
                clean = "Unclassified"

            new_cols[col] = clean

        return df.rename(columns=new_cols)

    def _align_taxa(self, dfs: List[pd.DataFrame]) -> pd.DataFrame:
        """Align taxa across all dataframes."""
        # Get union of all taxa
        all_taxa = set()
        for df in dfs:
            all_taxa.update(df.columns)

        # Reindex each df to have all taxa
        aligned_dfs = []
        for df in dfs:
            aligned = df.reindex(columns=sorted(all_taxa), fill_value=0)
            aligned_dfs.append(aligned)

        # Concatenate
        return pd.concat(aligned_dfs, axis=0)

    def _align_samples_intersection(
        self,
        df: pd.DataFrame,
        runs: List[RunData],
    ) -> pd.DataFrame:
        """Keep only samples present in all runs (by sample ID suffix)."""
        # Extract sample IDs (part after run_id:)
        sample_ids = df.index.str.split(":").str[-1]

        # Count occurrences of each sample ID
        sample_counts = sample_ids.value_counts()

        # Keep samples present in all runs
        n_runs = len(set(df.index.str.split(":").str[0]))
        common_samples = sample_counts[sample_counts >= n_runs].index

        if len(common_samples) == 0:
            if self.verbose:
                print("[harmonise] No common samples found, keeping all")
            return df

        # Filter to common samples
        mask = sample_ids.isin(common_samples)
        return df.loc[mask]

    def _align_samples_union(self, df: pd.DataFrame) -> pd.DataFrame:
        """Keep all samples (union)."""
        return df

    def _normalise_relative(self, df: pd.DataFrame) -> pd.DataFrame:
        """Convert to relative abundances (row sums = 1)."""
        row_sums = df.sum(axis=1)
        row_sums = row_sums.replace(0, 1)  # Avoid division by zero
        return df.div(row_sums, axis=0)

    def _normalise_clr(self, df: pd.DataFrame, pseudocount: float = 0.5) -> pd.DataFrame:
        """Apply centered log-ratio transformation."""
        # Add pseudocount
        df_pseudo = df + pseudocount

        # Log transform
        log_df = np.log(df_pseudo)

        # Subtract geometric mean per sample
        geo_mean = log_df.mean(axis=1)
        return log_df.sub(geo_mean, axis=0)

    def _filter_taxa(self, df: pd.DataFrame) -> pd.DataFrame:
        """Apply prevalence and abundance filters."""
        # Prevalence filter
        if self.min_prevalence > 0:
            prevalence = (df > 0).mean(axis=0)
            keep_taxa = prevalence >= self.min_prevalence
            df = df.loc[:, keep_taxa]

            if self.verbose:
                print(f"[harmonise] After prevalence filter: {df.shape[1]} taxa")

        # Mean abundance filter
        if self.min_mean_abundance > 0:
            mean_abundance = df.mean(axis=0)
            keep_taxa = mean_abundance >= self.min_mean_abundance
            df = df.loc[:, keep_taxa]

            if self.verbose:
                print(f"[harmonise] After abundance filter: {df.shape[1]} taxa")

        return df
