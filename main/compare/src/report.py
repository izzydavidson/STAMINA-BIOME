#!/usr/bin/env python3
"""
HTML report generation for comparison results.

Generates a self-contained HTML report with:
- Summary statistics
- Embedded plots
- Interactive tables
- Downloadable data links
"""

import base64
import json
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import pandas as pd

try:
    from .harmonise import HarmonisedData
    from .analysis import ComparisonResults
except ImportError:
    from harmonise import HarmonisedData
    from analysis import ComparisonResults


class ReportGenerator:
    """Generate HTML comparison report."""

    def __init__(self, verbose: bool = False):
        self.verbose = verbose

    def generate(
        self,
        config: Any,
        harmonised: HarmonisedData,
        results: ComparisonResults,
        plots: Dict[str, str],
        output_dir: Path,
    ) -> str:
        """
        Generate HTML report.

        Returns path to generated report.
        """
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        # Build report sections
        html_parts = [
            self._html_header(config),
            self._summary_section(config, harmonised, results),
            self._similarity_section(results),
            self._diversity_section(results),
            self._plots_section(plots, output_dir.parent / "plots"),
            self._run_summaries_section(results),
            self._html_footer(),
        ]

        html_content = "\n".join(html_parts)

        # Write report
        report_path = output_dir / "index.html"
        with open(report_path, "w") as f:
            f.write(html_content)

        if self.verbose:
            print(f"[report] Generated: {report_path}")

        return str(report_path)

    def _html_header(self, config: Any) -> str:
        """Generate HTML header with styles."""
        title = f"STAMINA-BIOME Compare Report: {config.name}"
        return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{title}</title>
    <style>
        :root {{
            --primary: #2563eb;
            --primary-dark: #1d4ed8;
            --success: #16a34a;
            --warning: #ca8a04;
            --danger: #dc2626;
            --gray-50: #f9fafb;
            --gray-100: #f3f4f6;
            --gray-200: #e5e7eb;
            --gray-300: #d1d5db;
            --gray-600: #4b5563;
            --gray-800: #1f2937;
            --gray-900: #111827;
        }}

        * {{
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }}

        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            line-height: 1.6;
            color: var(--gray-800);
            background: var(--gray-50);
        }}

        .container {{
            max-width: 1200px;
            margin: 0 auto;
            padding: 2rem;
        }}

        header {{
            background: linear-gradient(135deg, var(--primary) 0%, var(--primary-dark) 100%);
            color: white;
            padding: 2rem 0;
            margin-bottom: 2rem;
        }}

        header h1 {{
            font-size: 2rem;
            font-weight: 700;
        }}

        header .subtitle {{
            opacity: 0.9;
            margin-top: 0.5rem;
        }}

        .card {{
            background: white;
            border-radius: 8px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
            margin-bottom: 1.5rem;
            overflow: hidden;
        }}

        .card-header {{
            background: var(--gray-100);
            padding: 1rem 1.5rem;
            border-bottom: 1px solid var(--gray-200);
        }}

        .card-header h2 {{
            font-size: 1.25rem;
            font-weight: 600;
            color: var(--gray-900);
        }}

        .card-body {{
            padding: 1.5rem;
        }}

        .metric-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1rem;
        }}

        .metric {{
            background: var(--gray-50);
            padding: 1rem;
            border-radius: 6px;
            text-align: center;
        }}

        .metric-value {{
            font-size: 1.75rem;
            font-weight: 700;
            color: var(--primary);
        }}

        .metric-label {{
            font-size: 0.875rem;
            color: var(--gray-600);
            margin-top: 0.25rem;
        }}

        table {{
            width: 100%;
            border-collapse: collapse;
        }}

        th, td {{
            padding: 0.75rem 1rem;
            text-align: left;
            border-bottom: 1px solid var(--gray-200);
        }}

        th {{
            background: var(--gray-50);
            font-weight: 600;
            color: var(--gray-700);
        }}

        tr:hover {{
            background: var(--gray-50);
        }}

        .plot-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 1.5rem;
        }}

        .plot-item {{
            text-align: center;
        }}

        .plot-item img {{
            max-width: 100%;
            height: auto;
            border-radius: 4px;
            border: 1px solid var(--gray-200);
        }}

        .plot-item .caption {{
            margin-top: 0.5rem;
            font-size: 0.875rem;
            color: var(--gray-600);
        }}

        .badge {{
            display: inline-block;
            padding: 0.25rem 0.75rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
        }}

        .badge-success {{
            background: #dcfce7;
            color: var(--success);
        }}

        .badge-warning {{
            background: #fef3c7;
            color: var(--warning);
        }}

        footer {{
            text-align: center;
            padding: 2rem;
            color: var(--gray-600);
            font-size: 0.875rem;
        }}

        .run-summary {{
            margin-bottom: 1rem;
            padding: 1rem;
            background: var(--gray-50);
            border-radius: 6px;
        }}

        .run-summary h4 {{
            color: var(--primary);
            margin-bottom: 0.5rem;
        }}

        .run-summary .stats {{
            display: flex;
            gap: 2rem;
            flex-wrap: wrap;
        }}

        .run-summary .stat {{
            font-size: 0.875rem;
        }}

        .run-summary .stat strong {{
            color: var(--gray-900);
        }}
    </style>
</head>
<body>
"""

    def _summary_section(
        self,
        config: Any,
        harmonised: HarmonisedData,
        results: ComparisonResults,
    ) -> str:
        """Generate summary section."""
        n_samples = harmonised.aligned_abundance.shape[0]
        n_taxa = harmonised.aligned_abundance.shape[1]
        runs = harmonised.run_labels.unique().tolist()

        runs_html = ", ".join(f"<strong>{r}</strong>" for r in runs)

        return f"""
<header>
    <div class="container">
        <h1>STAMINA-BIOME Comparison Report</h1>
        <p class="subtitle">{config.name} | Generated {datetime.now().strftime('%Y-%m-%d %H:%M')}</p>
    </div>
</header>

<div class="container">
    <div class="card">
        <div class="card-header">
            <h2>Summary</h2>
        </div>
        <div class="card-body">
            <div class="metric-grid">
                <div class="metric">
                    <div class="metric-value">{len(runs)}</div>
                    <div class="metric-label">Runs Compared</div>
                </div>
                <div class="metric">
                    <div class="metric-value">{n_samples}</div>
                    <div class="metric-label">Total Samples</div>
                </div>
                <div class="metric">
                    <div class="metric-value">{n_taxa}</div>
                    <div class="metric-label">Taxa ({config.rank})</div>
                </div>
                <div class="metric">
                    <div class="metric-value">{config.norm.upper()}</div>
                    <div class="metric-label">Normalisation</div>
                </div>
            </div>
            <p style="margin-top: 1rem;">Runs: {runs_html}</p>
        </div>
    </div>
"""

    def _similarity_section(self, results: ComparisonResults) -> str:
        """Generate similarity metrics section."""
        metrics = results.similarity_metrics

        if not metrics:
            return """
    <div class="card">
        <div class="card-header">
            <h2>Similarity Metrics</h2>
        </div>
        <div class="card-body">
            <p>No similarity metrics available.</p>
        </div>
    </div>
"""

        rows = []
        metric_descriptions = {
            "jaccard_mean": ("Jaccard Index", "Taxa overlap (presence/absence)"),
            "sorensen_mean": ("Sørensen Index", "Taxa overlap (presence/absence)"),
            "spearman_mean": ("Spearman Correlation", "Abundance rank correlation"),
            "bray_curtis_similarity_mean": ("Bray-Curtis Similarity", "Abundance-based similarity"),
            "total_taxa": ("Total Taxa", "Unique taxa across all runs"),
            "total_taxa_observed": ("Taxa Observed", "Taxa present in at least one sample"),
        }

        for key, value in metrics.items():
            if key in metric_descriptions:
                name, desc = metric_descriptions[key]
                if isinstance(value, float):
                    value_str = f"{value:.3f}"
                else:
                    value_str = str(value)
                rows.append(f"""
                <tr>
                    <td><strong>{name}</strong><br><small style="color: var(--gray-600);">{desc}</small></td>
                    <td style="text-align: right; font-size: 1.25rem; font-weight: 600;">{value_str}</td>
                </tr>
""")

        rows_html = "\n".join(rows)

        return f"""
    <div class="card">
        <div class="card-header">
            <h2>Similarity Metrics</h2>
        </div>
        <div class="card-body">
            <table>
                <tbody>
                    {rows_html}
                </tbody>
            </table>
        </div>
    </div>
"""

    def _diversity_section(self, results: ComparisonResults) -> str:
        """Generate diversity section."""
        if results.alpha_diversity is None:
            return ""

        alpha_df = results.alpha_diversity

        # Compute summary stats per run
        runs = alpha_df["run"].unique()
        rows = []

        for run in runs:
            run_data = alpha_df[alpha_df["run"] == run]
            shannon_mean = run_data["shannon"].mean()
            simpson_mean = run_data["simpson"].mean()
            richness_mean = run_data["observed_taxa"].mean()

            rows.append(f"""
                <tr>
                    <td><strong>{run}</strong></td>
                    <td>{shannon_mean:.2f}</td>
                    <td>{simpson_mean:.3f}</td>
                    <td>{richness_mean:.1f}</td>
                    <td>{len(run_data)}</td>
                </tr>
""")

        rows_html = "\n".join(rows)

        # PERMANOVA results if available
        permanova_html = ""
        if results.permanova_results and "f_statistic" in results.permanova_results:
            perm = results.permanova_results
            sig = "Yes" if perm.get("p_value", 1) < 0.05 else "No"
            permanova_html = f"""
            <div style="margin-top: 1.5rem; padding: 1rem; background: var(--gray-50); border-radius: 6px;">
                <h4 style="margin-bottom: 0.5rem;">PERMANOVA Results</h4>
                <p>F-statistic: <strong>{perm['f_statistic']:.2f}</strong> |
                   p-value: <strong>{perm['p_value']:.4f}</strong> |
                   Significant: <span class="badge {'badge-success' if sig == 'Yes' else 'badge-warning'}">{sig}</span>
                </p>
            </div>
"""

        return f"""
    <div class="card">
        <div class="card-header">
            <h2>Diversity Analysis</h2>
        </div>
        <div class="card-body">
            <h4 style="margin-bottom: 1rem;">Alpha Diversity (Mean per Run)</h4>
            <table>
                <thead>
                    <tr>
                        <th>Run</th>
                        <th>Shannon</th>
                        <th>Simpson</th>
                        <th>Observed Taxa</th>
                        <th>Samples</th>
                    </tr>
                </thead>
                <tbody>
                    {rows_html}
                </tbody>
            </table>
            {permanova_html}
        </div>
    </div>
"""

    def _plots_section(self, plots: Dict[str, str], plots_dir: Path) -> str:
        """Generate plots section with embedded images."""
        if not plots:
            return """
    <div class="card">
        <div class="card-header">
            <h2>Visualizations</h2>
        </div>
        <div class="card-body">
            <p>No plots available. Install matplotlib to generate visualizations.</p>
        </div>
    </div>
"""

        plot_items = []
        plot_titles = {
            "stacked_bar": "Taxonomic Composition",
            "heatmap": "Abundance Heatmap",
            "scatter": "Abundance Correlation",
            "venn": "Taxa Overlap",
            "alpha_boxplot": "Alpha Diversity",
            "pcoa": "PCoA Ordination",
        }

        for plot_name, filename in plots.items():
            plot_path = plots_dir / filename
            title = plot_titles.get(plot_name, plot_name.replace("_", " ").title())

            if plot_path.exists():
                # Embed image as base64
                with open(plot_path, "rb") as f:
                    img_data = base64.b64encode(f.read()).decode()
                img_src = f"data:image/png;base64,{img_data}"
            else:
                # Link to file
                img_src = f"../plots/{filename}"

            plot_items.append(f"""
            <div class="plot-item">
                <img src="{img_src}" alt="{title}">
                <p class="caption">{title}</p>
            </div>
""")

        plots_html = "\n".join(plot_items)

        return f"""
    <div class="card">
        <div class="card-header">
            <h2>Visualizations</h2>
        </div>
        <div class="card-body">
            <div class="plot-grid">
                {plots_html}
            </div>
        </div>
    </div>
"""

    def _run_summaries_section(self, results: ComparisonResults) -> str:
        """Generate per-run summaries section."""
        if not results.run_summaries:
            return ""

        summaries_html = []
        for run_id, summary in results.run_summaries.items():
            top_taxa = summary.get("top_taxa", {})
            top_taxa_str = ", ".join(
                f"{taxon} ({abundance:.1%})"
                for taxon, abundance in list(top_taxa.items())[:3]
            ) if top_taxa else "N/A"

            summaries_html.append(f"""
            <div class="run-summary">
                <h4>{run_id}</h4>
                <div class="stats">
                    <div class="stat">Samples: <strong>{summary.get('n_samples', 'N/A')}</strong></div>
                    <div class="stat">Taxa observed: <strong>{summary.get('n_taxa_observed', 'N/A')}</strong></div>
                    <div class="stat">Mean richness: <strong>{summary.get('mean_richness', 0):.1f}</strong></div>
                </div>
                <p style="margin-top: 0.5rem; font-size: 0.875rem;">
                    <strong>Top taxa:</strong> {top_taxa_str}
                </p>
            </div>
""")

        summaries_joined = "\n".join(summaries_html)

        return f"""
    <div class="card">
        <div class="card-header">
            <h2>Run Summaries</h2>
        </div>
        <div class="card-body">
            {summaries_joined}
        </div>
    </div>
"""

    def _html_footer(self) -> str:
        """Generate HTML footer."""
        return f"""
</div>

<footer>
    <p>Generated by STAMINA-BIOME Compare | {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    <p><a href="https://github.com/your-org/stamina-biome" target="_blank">STAMINA-BIOME Documentation</a></p>
</footer>

</body>
</html>
"""
