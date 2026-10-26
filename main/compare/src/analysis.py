#!/usr/bin/env python3
"""
Comparison analysis functions.

Computes:
- Similarity metrics (Jaccard, Sørensen, Spearman, Bray-Curtis)
- Alpha diversity (Shannon, Simpson, observed)
- Beta diversity (PCoA, PERMANOVA)
- Differential abundance (optional)
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import pandas as pd
from scipy import stats
from scipy.spatial.distance import braycurtis, pdist, squareform

try:
    from .harmonise import HarmonisedData
except ImportError:
    from harmonise import HarmonisedData


@dataclass
class ComparisonResults:
    """Results from comparison analysis."""

    # Similarity metrics between runs
    similarity_metrics: Dict[str, float] = field(default_factory=dict)

    # Pairwise similarity matrix
    pairwise_similarity: Optional[pd.DataFrame] = None

    # Alpha diversity per sample
    alpha_diversity: Optional[pd.DataFrame] = None

    # Beta diversity distance matrix
    beta_distance: Optional[pd.DataFrame] = None

    # PCoA coordinates
    pcoa_coords: Optional[pd.DataFrame] = None

    # PERMANOVA results
    permanova_results: Optional[Dict[str, Any]] = None

    # Differential taxa (if enabled)
    differential_taxa: Optional[pd.DataFrame] = None

    # Per-run summaries
    run_summaries: Dict[str, Dict[str, Any]] = field(default_factory=dict)


class ComparisonAnalyzer:
    """Analyze harmonised data."""

    def __init__(
        self,
        group_col: str = "",
        enable_diff: bool = False,
        verbose: bool = False,
    ):
        self.group_col = group_col
        self.enable_diff = enable_diff
        self.verbose = verbose

    def analyze(
        self,
        harmonised: HarmonisedData,
        metadata: Optional[pd.DataFrame] = None,
    ) -> ComparisonResults:
        """
        Run all comparison analyses.

        Args:
            harmonised: Harmonised data from Harmoniser
            metadata: Optional sample metadata

        Returns:
            ComparisonResults with all metrics
        """
        results = ComparisonResults()

        df = harmonised.aligned_abundance
        run_labels = harmonised.run_labels

        if self.verbose:
            print(f"[analysis] Analyzing {len(df)} samples, {len(df.columns)} taxa")

        # 1. Compute similarity metrics
        results.similarity_metrics = self._compute_similarity_metrics(df, run_labels)

        # 2. Compute pairwise similarity between runs
        results.pairwise_similarity = self._compute_pairwise_similarity(df, run_labels)

        # 3. Compute alpha diversity
        results.alpha_diversity = self._compute_alpha_diversity(df, run_labels)

        # 4. Compute beta diversity
        results.beta_distance, results.pcoa_coords = self._compute_beta_diversity(df)

        # 5. PERMANOVA if groups available
        if metadata is not None and self.group_col and self.group_col in metadata.columns:
            results.permanova_results = self._compute_permanova(
                results.beta_distance, metadata, self.group_col
            )

        # 6. Differential abundance if enabled
        if self.enable_diff:
            results.differential_taxa = self._compute_differential(df, run_labels)

        # 7. Per-run summaries
        results.run_summaries = self._compute_run_summaries(df, run_labels)

        return results

    def _compute_similarity_metrics(
        self,
        df: pd.DataFrame,
        run_labels: pd.Series,
    ) -> Dict[str, float]:
        """Compute overall similarity metrics between runs."""
        metrics = {}

        runs = run_labels.unique()
        if len(runs) < 2:
            return metrics

        # Aggregate to run-level profiles
        run_profiles = df.groupby(run_labels).mean()

        # Taxa present in each run (presence/absence)
        presence = (run_profiles > 0).astype(int)

        # Jaccard index (average pairwise)
        jaccard_values = []
        sorensen_values = []
        spearman_values = []
        bray_values = []

        for i, run1 in enumerate(runs):
            for run2 in runs[i+1:]:
                p1 = presence.loc[run1]
                p2 = presence.loc[run2]
                a1 = run_profiles.loc[run1]
                a2 = run_profiles.loc[run2]

                # Jaccard
                intersection = (p1 & p2).sum()
                union = (p1 | p2).sum()
                if union > 0:
                    jaccard_values.append(intersection / union)

                # Sørensen
                if (p1.sum() + p2.sum()) > 0:
                    sorensen = 2 * intersection / (p1.sum() + p2.sum())
                    sorensen_values.append(sorensen)

                # Spearman correlation
                # Only on taxa present in both
                common_taxa = (p1 == 1) & (p2 == 1)
                if common_taxa.sum() >= 3:
                    rho, _ = stats.spearmanr(a1[common_taxa], a2[common_taxa])
                    if not np.isnan(rho):
                        spearman_values.append(rho)

                # Bray-Curtis dissimilarity
                if a1.sum() > 0 and a2.sum() > 0:
                    bc = braycurtis(a1, a2)
                    if not np.isnan(bc):
                        bray_values.append(1 - bc)  # Convert to similarity

        if jaccard_values:
            metrics["jaccard_mean"] = np.mean(jaccard_values)
            metrics["jaccard_std"] = np.std(jaccard_values)
        if sorensen_values:
            metrics["sorensen_mean"] = np.mean(sorensen_values)
        if spearman_values:
            metrics["spearman_mean"] = np.mean(spearman_values)
            metrics["spearman_std"] = np.std(spearman_values)
        if bray_values:
            metrics["bray_curtis_similarity_mean"] = np.mean(bray_values)

        # Total unique taxa
        metrics["total_taxa"] = len(df.columns)

        # Shared taxa count
        all_presence = (df > 0).any(axis=0)
        metrics["total_taxa_observed"] = all_presence.sum()

        return metrics

    def _compute_pairwise_similarity(
        self,
        df: pd.DataFrame,
        run_labels: pd.Series,
    ) -> pd.DataFrame:
        """Compute pairwise similarity matrix between runs."""
        runs = run_labels.unique()
        run_profiles = df.groupby(run_labels).mean()

        similarity_matrix = pd.DataFrame(
            index=runs,
            columns=runs,
            dtype=float,
        )

        for run1 in runs:
            for run2 in runs:
                if run1 == run2:
                    similarity_matrix.loc[run1, run2] = 1.0
                else:
                    a1 = run_profiles.loc[run1]
                    a2 = run_profiles.loc[run2]

                    # Bray-Curtis similarity
                    if a1.sum() > 0 and a2.sum() > 0:
                        bc = braycurtis(a1, a2)
                        similarity_matrix.loc[run1, run2] = 1 - bc
                    else:
                        similarity_matrix.loc[run1, run2] = 0.0

        return similarity_matrix

    def _compute_alpha_diversity(
        self,
        df: pd.DataFrame,
        run_labels: pd.Series,
    ) -> pd.DataFrame:
        """Compute alpha diversity metrics per sample."""
        alpha = pd.DataFrame(index=df.index)
        alpha["run"] = run_labels

        # Shannon index
        def shannon(row):
            row = row[row > 0]
            if len(row) == 0:
                return 0
            p = row / row.sum()
            return -np.sum(p * np.log(p))

        alpha["shannon"] = df.apply(shannon, axis=1)

        # Simpson index (1 - D)
        def simpson(row):
            row = row[row > 0]
            if len(row) == 0:
                return 0
            p = row / row.sum()
            return 1 - np.sum(p ** 2)

        alpha["simpson"] = df.apply(simpson, axis=1)

        # Observed taxa (richness)
        alpha["observed_taxa"] = (df > 0).sum(axis=1)

        # Pielou evenness
        alpha["pielou_evenness"] = alpha["shannon"] / np.log(alpha["observed_taxa"].replace(0, 1))

        return alpha

    def _compute_beta_diversity(
        self,
        df: pd.DataFrame,
    ) -> Tuple[pd.DataFrame, pd.DataFrame]:
        """Compute beta diversity and PCoA."""
        # Bray-Curtis distance matrix
        distances = pdist(df.values, metric="braycurtis")
        dist_matrix = squareform(distances)
        dist_df = pd.DataFrame(dist_matrix, index=df.index, columns=df.index)

        # PCoA via classical MDS
        pcoa_coords = self._pcoa(dist_df)

        return dist_df, pcoa_coords

    def _pcoa(self, dist_df: pd.DataFrame, n_components: int = 2) -> pd.DataFrame:
        """Principal Coordinates Analysis."""
        D = dist_df.values
        n = D.shape[0]

        # Double centering
        D2 = D ** 2
        centering = np.eye(n) - np.ones((n, n)) / n
        B = -0.5 * centering @ D2 @ centering

        # Eigendecomposition
        eigvals, eigvecs = np.linalg.eigh(B)

        # Sort by decreasing eigenvalue
        idx = np.argsort(eigvals)[::-1]
        eigvals = eigvals[idx]
        eigvecs = eigvecs[:, idx]

        # Take top components
        coords = eigvecs[:, :n_components] * np.sqrt(np.maximum(eigvals[:n_components], 0))

        # Variance explained
        total_var = np.sum(np.maximum(eigvals, 0))
        var_explained = eigvals[:n_components] / total_var if total_var > 0 else np.zeros(n_components)

        pcoa_df = pd.DataFrame(
            coords,
            index=dist_df.index,
            columns=[f"PC{i+1}" for i in range(n_components)],
        )

        # Store variance explained as attributes
        pcoa_df.attrs["variance_explained"] = var_explained

        return pcoa_df

    def _compute_permanova(
        self,
        dist_df: pd.DataFrame,
        metadata: pd.DataFrame,
        group_col: str,
        n_permutations: int = 999,
    ) -> Dict[str, Any]:
        """Compute PERMANOVA for group differences."""
        # Align metadata with distance matrix
        common_samples = dist_df.index.intersection(metadata.index)
        if len(common_samples) < 3:
            return {"error": "Not enough samples with metadata"}

        groups = metadata.loc[common_samples, group_col]
        D = dist_df.loc[common_samples, common_samples].values

        # Get unique groups
        unique_groups = groups.unique()
        if len(unique_groups) < 2:
            return {"error": "Need at least 2 groups"}

        # Compute F statistic
        def pseudo_f(D, groups):
            n = len(groups)
            groups_arr = groups.values

            # Sum of squares
            D2 = D ** 2

            # Total SS
            ss_total = D2.sum() / (2 * n)

            # Within-group SS
            ss_within = 0
            for g in unique_groups:
                mask = groups_arr == g
                n_g = mask.sum()
                if n_g > 1:
                    D_g = D[np.ix_(mask, mask)]
                    ss_within += D_g.sum() / (2 * n_g)

            # Between-group SS
            ss_between = ss_total - ss_within

            # Degrees of freedom
            df_between = len(unique_groups) - 1
            df_within = n - len(unique_groups)

            if df_within <= 0 or ss_within == 0:
                return np.nan

            f_stat = (ss_between / df_between) / (ss_within / df_within)
            return f_stat

        observed_f = pseudo_f(D, groups)

        # Permutation test
        perm_f_values = []
        for _ in range(n_permutations):
            perm_groups = groups.sample(frac=1, replace=False)
            perm_groups.index = groups.index
            perm_f = pseudo_f(D, perm_groups)
            if not np.isnan(perm_f):
                perm_f_values.append(perm_f)

        # P-value
        if perm_f_values and not np.isnan(observed_f):
            p_value = (np.sum(np.array(perm_f_values) >= observed_f) + 1) / (len(perm_f_values) + 1)
        else:
            p_value = np.nan

        return {
            "f_statistic": observed_f,
            "p_value": p_value,
            "n_permutations": n_permutations,
            "n_groups": len(unique_groups),
            "groups": list(unique_groups),
        }

    def _compute_differential(
        self,
        df: pd.DataFrame,
        run_labels: pd.Series,
    ) -> pd.DataFrame:
        """Compute differential abundance between runs."""
        runs = run_labels.unique()
        if len(runs) != 2:
            if self.verbose:
                print("[analysis] Differential analysis requires exactly 2 runs")
            return None

        run1, run2 = runs[0], runs[1]
        df1 = df[run_labels == run1]
        df2 = df[run_labels == run2]

        # Mean abundances
        mean1 = df1.mean()
        mean2 = df2.mean()

        # Log fold change (with pseudocount)
        pseudocount = 1e-6
        lfc = np.log2((mean2 + pseudocount) / (mean1 + pseudocount))

        # Mann-Whitney U test per taxon
        p_values = []
        for taxon in df.columns:
            if df1[taxon].sum() > 0 or df2[taxon].sum() > 0:
                try:
                    _, p = stats.mannwhitneyu(df1[taxon], df2[taxon], alternative="two-sided")
                    p_values.append(p)
                except:
                    p_values.append(1.0)
            else:
                p_values.append(1.0)

        # FDR correction (Benjamini-Hochberg)
        p_values = np.array(p_values)
        n = len(p_values)
        sorted_idx = np.argsort(p_values)
        sorted_p = p_values[sorted_idx]
        fdr = sorted_p * n / (np.arange(n) + 1)
        fdr = np.minimum.accumulate(fdr[::-1])[::-1]
        fdr_corrected = np.zeros(n)
        fdr_corrected[sorted_idx] = fdr

        results = pd.DataFrame({
            "taxon": df.columns,
            f"mean_{run1}": mean1.values,
            f"mean_{run2}": mean2.values,
            "log2_fold_change": lfc.values,
            "p_value": p_values,
            "fdr": fdr_corrected,
        })

        # Sort by absolute LFC
        results["abs_lfc"] = np.abs(results["log2_fold_change"])
        results = results.sort_values("abs_lfc", ascending=False)
        results = results.drop("abs_lfc", axis=1)

        return results

    def _compute_run_summaries(
        self,
        df: pd.DataFrame,
        run_labels: pd.Series,
    ) -> Dict[str, Dict[str, Any]]:
        """Compute summary statistics per run."""
        summaries = {}

        for run in run_labels.unique():
            run_df = df[run_labels == run]

            summaries[run] = {
                "n_samples": len(run_df),
                "n_taxa_observed": (run_df > 0).any(axis=0).sum(),
                "mean_richness": (run_df > 0).sum(axis=1).mean(),
                "mean_total_abundance": run_df.sum(axis=1).mean(),
                "top_taxa": run_df.mean().nlargest(5).to_dict(),
            }

        return summaries
