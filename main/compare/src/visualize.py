#!/usr/bin/env python3
"""
Visualization functions for comparison results.

Generates:
- Stacked bar plots
- Heatmaps
- Scatter plots
- Venn diagrams
- Alpha diversity boxplots
- PCoA plots
"""

from pathlib import Path
from typing import Dict, List, Optional

import numpy as np
import pandas as pd

try:
    import matplotlib
    matplotlib.use("Agg")  # Non-interactive backend
    import matplotlib.pyplot as plt
    from matplotlib.patches import Circle
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False

try:
    from matplotlib_venn import venn2, venn3
    HAS_VENN = True
except ImportError:
    HAS_VENN = False
    venn2 = venn3 = None

try:
    import seaborn as sns
    HAS_SEABORN = True
except ImportError:
    HAS_SEABORN = False

try:
    from .harmonise import HarmonisedData
    from .analysis import ComparisonResults
except ImportError:
    from harmonise import HarmonisedData
    from analysis import ComparisonResults


class ComparisonVisualizer:
    """Generate comparison visualizations."""

    def __init__(
        self,
        top_n: int = 20,
        verbose: bool = False,
    ):
        self.top_n = top_n
        self.verbose = verbose

        # White background style
        if HAS_MATPLOTLIB:
            plt.style.use("default")
            plt.rcParams["figure.facecolor"] = "white"
            plt.rcParams["axes.facecolor"] = "white"
            plt.rcParams["savefig.facecolor"] = "white"

    def generate_all(
        self,
        harmonised: HarmonisedData,
        results: ComparisonResults,
        output_dir: Path,
    ) -> Dict[str, str]:
        """
        Generate all plots.

        Returns dict of {plot_name: filename}
        """
        if not HAS_MATPLOTLIB:
            if self.verbose:
                print("[visualize] matplotlib not available, skipping plots")
            return {}

        plots = {}
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        # 1. Stacked bar plot
        try:
            fname = self._plot_stacked_bar(harmonised, output_dir)
            plots["stacked_bar"] = fname
        except Exception as e:
            if self.verbose:
                print(f"[visualize] Error creating stacked bar: {e}")

        # 2. Heatmap
        try:
            fname = self._plot_heatmap(harmonised, output_dir)
            plots["heatmap"] = fname
        except Exception as e:
            if self.verbose:
                print(f"[visualize] Error creating heatmap: {e}")

        # 3. Scatter plot (abundance correlation)
        try:
            fname = self._plot_scatter(harmonised, output_dir)
            if fname:
                plots["scatter"] = fname
        except Exception as e:
            if self.verbose:
                print(f"[visualize] Error creating scatter: {e}")

        # 4. Venn diagram
        try:
            fname = self._plot_venn(harmonised, output_dir)
            if fname:
                plots["venn"] = fname
        except Exception as e:
            if self.verbose:
                print(f"[visualize] Error creating venn: {e}")

        # 5. Alpha diversity boxplots
        if results.alpha_diversity is not None:
            try:
                fname = self._plot_alpha_boxplot(results.alpha_diversity, output_dir)
                plots["alpha_boxplot"] = fname
            except Exception as e:
                if self.verbose:
                    print(f"[visualize] Error creating alpha boxplot: {e}")

        # 6. PCoA plot
        if results.pcoa_coords is not None:
            try:
                fname = self._plot_pcoa(results.pcoa_coords, harmonised.run_labels, output_dir)
                plots["pcoa"] = fname
            except Exception as e:
                if self.verbose:
                    print(f"[visualize] Error creating PCoA: {e}")

        return plots

    def _plot_stacked_bar(
        self,
        harmonised: HarmonisedData,
        output_dir: Path,
    ) -> str:
        """Create side-by-side stacked bar plots."""
        df = harmonised.aligned_abundance
        run_labels = harmonised.run_labels

        # Get top N taxa by mean abundance
        top_taxa = df.mean().nlargest(self.top_n).index.tolist()

        # Aggregate others
        other = df.drop(columns=top_taxa, errors="ignore").sum(axis=1)
        plot_df = df[top_taxa].copy()
        plot_df["Other"] = other

        # Convert to relative abundance for plotting
        row_sums = plot_df.sum(axis=1)
        row_sums = row_sums.replace(0, 1)
        plot_df = plot_df.div(row_sums, axis=0) * 100

        # Group by run
        runs = run_labels.unique()

        fig, axes = plt.subplots(1, len(runs), figsize=(4 * len(runs), 8), sharey=True)
        if len(runs) == 1:
            axes = [axes]

        colors = list(plt.cm.tab20.colors[:len(top_taxa)]) + [(0.8, 0.8, 0.8)]  # Gray for Other

        for ax, run in zip(axes, runs):
            run_data = plot_df[run_labels == run]

            if len(run_data) == 0:
                continue

            # Mean profile for this run
            mean_profile = run_data.mean()

            # Create stacked bar
            bottom = 0
            for i, taxon in enumerate(list(top_taxa) + ["Other"]):
                height = mean_profile[taxon]
                ax.bar(0, height, bottom=bottom, color=colors[i], label=taxon, width=0.6)
                bottom += height

            ax.set_title(run, fontsize=12, fontweight="bold")
            ax.set_ylabel("Relative Abundance (%)" if ax == axes[0] else "")
            ax.set_xticks([])
            ax.set_ylim(0, 100)

        # Legend
        handles, labels = axes[0].get_legend_handles_labels()
        fig.legend(
            handles, labels,
            loc="center left",
            bbox_to_anchor=(1.0, 0.5),
            fontsize=8,
        )

        plt.tight_layout()
        fname = "stacked_bar.png"
        fig.savefig(output_dir / fname, dpi=150, bbox_inches="tight")
        plt.close(fig)

        return fname

    def _plot_heatmap(
        self,
        harmonised: HarmonisedData,
        output_dir: Path,
    ) -> str:
        """Create heatmap of top taxa."""
        df = harmonised.aligned_abundance
        run_labels = harmonised.run_labels

        # Get top N taxa
        top_taxa = df.mean().nlargest(self.top_n).index.tolist()
        plot_df = df[top_taxa].copy()

        # Log transform for better visualization (add pseudocount)
        plot_df = np.log10(plot_df + 1e-6)

        fig, ax = plt.subplots(figsize=(12, max(6, len(plot_df) * 0.3)))

        if HAS_SEABORN:
            # Create row colors for runs
            run_colors = {run: plt.cm.Set1(i) for i, run in enumerate(run_labels.unique())}
            row_colors = [run_colors[run_labels.loc[idx]] for idx in plot_df.index]

            g = sns.clustermap(
                plot_df,
                cmap="viridis",
                row_colors=row_colors,
                figsize=(12, max(6, len(plot_df) * 0.3)),
                dendrogram_ratio=0.1,
                cbar_pos=(0.02, 0.8, 0.03, 0.15),
            )
            g.ax_heatmap.set_ylabel("")
            g.ax_heatmap.set_xlabel("Taxa", fontsize=10)

            fname = "heatmap.png"
            g.savefig(output_dir / fname, dpi=150, bbox_inches="tight")
            plt.close()
        else:
            # Simple heatmap without clustering
            im = ax.imshow(plot_df.values, aspect="auto", cmap="viridis")
            ax.set_yticks(range(len(plot_df)))
            ax.set_yticklabels([f"{idx}" for idx in plot_df.index], fontsize=6)
            ax.set_xticks(range(len(top_taxa)))
            ax.set_xticklabels(top_taxa, rotation=90, fontsize=8)
            plt.colorbar(im, ax=ax, label="log10(abundance)")

            fname = "heatmap.png"
            fig.savefig(output_dir / fname, dpi=150, bbox_inches="tight")
            plt.close(fig)

        return fname

    def _plot_scatter(
        self,
        harmonised: HarmonisedData,
        output_dir: Path,
    ) -> Optional[str]:
        """Create scatter plot of abundances between runs."""
        df = harmonised.aligned_abundance
        run_labels = harmonised.run_labels
        runs = run_labels.unique()

        if len(runs) != 2:
            if self.verbose:
                print("[visualize] Scatter plot requires exactly 2 runs")
            return None

        # Aggregate to run-level profiles
        run_profiles = df.groupby(run_labels).mean()

        run1, run2 = runs[0], runs[1]
        x = run_profiles.loc[run1]
        y = run_profiles.loc[run2]

        # Log transform for better visualization
        x_log = np.log10(x + 1e-6)
        y_log = np.log10(y + 1e-6)

        fig, ax = plt.subplots(figsize=(8, 8))

        ax.scatter(x_log, y_log, alpha=0.6, edgecolors="black", linewidth=0.5)

        # Add diagonal line
        lims = [min(x_log.min(), y_log.min()), max(x_log.max(), y_log.max())]
        ax.plot(lims, lims, "k--", alpha=0.5, zorder=0)

        # Compute correlation
        from scipy.stats import spearmanr
        rho, p = spearmanr(x, y)

        ax.set_xlabel(f"{run1} (log10 abundance)", fontsize=12)
        ax.set_ylabel(f"{run2} (log10 abundance)", fontsize=12)
        ax.set_title(f"Taxon Abundance Correlation\nSpearman ρ = {rho:.3f}", fontsize=12)

        # Label top different taxa
        diff = np.abs(x_log - y_log)
        top_diff_idx = diff.nlargest(5).index
        for taxon in top_diff_idx:
            ax.annotate(
                taxon[:20],
                (x_log[taxon], y_log[taxon]),
                fontsize=7,
                alpha=0.8,
            )

        plt.tight_layout()
        fname = "scatter.png"
        fig.savefig(output_dir / fname, dpi=150)
        plt.close(fig)

        return fname

    def _plot_venn(
        self,
        harmonised: HarmonisedData,
        output_dir: Path,
    ) -> Optional[str]:
        """Create Venn diagram of taxa overlap."""
        df = harmonised.aligned_abundance
        run_labels = harmonised.run_labels
        runs = run_labels.unique()

        if len(runs) < 2 or len(runs) > 3:
            if self.verbose:
                print("[visualize] Venn diagram requires 2-3 runs")
            return None

        # Get taxa present in each run
        taxa_sets = {}
        for run in runs:
            run_df = df[run_labels == run]
            present = run_df.columns[run_df.sum() > 0]
            taxa_sets[run] = set(present)

        fig, ax = plt.subplots(figsize=(8, 8))

        try:
            if not HAS_VENN:
                raise ImportError("matplotlib_venn not available")
            if len(runs) == 2:
                venn2(
                    [taxa_sets[runs[0]], taxa_sets[runs[1]]],
                    set_labels=runs,
                    ax=ax,
                )
            else:
                venn3(
                    [taxa_sets[runs[0]], taxa_sets[runs[1]], taxa_sets[runs[2]]],
                    set_labels=runs,
                    ax=ax,
                )
        except Exception:
            # Fallback: simple text display
            ax.text(0.5, 0.5, f"Taxa overlap:\n" +
                    "\n".join([f"{r}: {len(taxa_sets[r])} taxa" for r in runs]),
                    ha="center", va="center", fontsize=12)
            ax.set_xlim(0, 1)
            ax.set_ylim(0, 1)
            ax.axis("off")

        ax.set_title("Taxa Overlap (Presence/Absence)", fontsize=12)

        fname = "venn.png"
        fig.savefig(output_dir / fname, dpi=150)
        plt.close(fig)

        return fname

    def _plot_alpha_boxplot(
        self,
        alpha_df: pd.DataFrame,
        output_dir: Path,
    ) -> str:
        """Create boxplots of alpha diversity metrics."""
        metrics = ["shannon", "simpson", "observed_taxa"]

        fig, axes = plt.subplots(1, len(metrics), figsize=(4 * len(metrics), 6))

        for ax, metric in zip(axes, metrics):
            if metric not in alpha_df.columns:
                continue

            if HAS_SEABORN:
                sns.boxplot(data=alpha_df, x="run", y=metric, ax=ax)
                sns.stripplot(data=alpha_df, x="run", y=metric, ax=ax,
                              color="black", alpha=0.5, size=4)
            else:
                runs = alpha_df["run"].unique()
                data = [alpha_df[alpha_df["run"] == r][metric].values for r in runs]
                ax.boxplot(data, labels=runs)

            ax.set_xlabel("")
            ax.set_ylabel(metric.replace("_", " ").title())
            ax.tick_params(axis="x", rotation=45)

        plt.suptitle("Alpha Diversity Comparison", fontsize=14, y=1.02)
        plt.tight_layout()

        fname = "alpha_boxplot.png"
        fig.savefig(output_dir / fname, dpi=150, bbox_inches="tight")
        plt.close(fig)

        return fname

    def _plot_pcoa(
        self,
        pcoa_coords: pd.DataFrame,
        run_labels: pd.Series,
        output_dir: Path,
    ) -> str:
        """Create PCoA plot."""
        fig, ax = plt.subplots(figsize=(10, 8))

        runs = run_labels.unique()
        colors = plt.cm.Set1(np.linspace(0, 1, len(runs)))

        for i, run in enumerate(runs):
            mask = run_labels == run
            ax.scatter(
                pcoa_coords.loc[mask, "PC1"],
                pcoa_coords.loc[mask, "PC2"],
                c=[colors[i]],
                label=run,
                s=100,
                alpha=0.7,
                edgecolors="black",
                linewidth=0.5,
            )

        # Variance explained
        var_exp = pcoa_coords.attrs.get("variance_explained", [0, 0])

        ax.set_xlabel(f"PC1 ({var_exp[0]*100:.1f}% variance)", fontsize=12)
        ax.set_ylabel(f"PC2 ({var_exp[1]*100:.1f}% variance)", fontsize=12)
        ax.set_title("PCoA (Bray-Curtis)", fontsize=14)
        ax.legend(loc="best")

        # Add origin lines
        ax.axhline(0, color="gray", linestyle="--", alpha=0.3)
        ax.axvline(0, color="gray", linestyle="--", alpha=0.3)

        plt.tight_layout()
        fname = "pcoa.png"
        fig.savefig(output_dir / fname, dpi=150)
        plt.close(fig)

        return fname
