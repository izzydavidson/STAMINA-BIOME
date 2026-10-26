#!/usr/bin/env python3
"""
Main compare orchestration module.

Workflow: Inputs -> Harmonise -> Compare -> Report
"""

import json
import os
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import pandas as pd

try:
    from .run_parser import RunParser, RunData
    from .harmonise import Harmoniser, HarmonisedData
    from .analysis import ComparisonAnalyzer, ComparisonResults
    from .visualize import ComparisonVisualizer
    from .report import ReportGenerator
except ImportError:
    from run_parser import RunParser, RunData
    from harmonise import Harmoniser, HarmonisedData
    from analysis import ComparisonAnalyzer, ComparisonResults
    from visualize import ComparisonVisualizer
    from report import ReportGenerator


@dataclass
class CompareConfig:
    """Configuration for a comparison run."""

    # Input runs or tables
    run_paths: List[str] = field(default_factory=list)
    table_paths: List[str] = field(default_factory=list)
    taxonomy_path: str = ""
    metadata_path: str = ""

    # Harmonisation settings
    rank: str = "genus"  # species, genus, family
    norm: str = "relative"  # relative, clr
    sample_align: str = "intersection"  # intersection, union
    min_prevalence: float = 0.1
    min_mean_abundance: float = 0.0

    # Analysis settings
    top_n: int = 20
    group_col: str = ""
    enable_diff: bool = False

    # Output settings
    outdir: str = ""
    name: str = ""
    verbose: bool = False

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return asdict(self)

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "CompareConfig":
        """Create from dictionary."""
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


class CompareError(Exception):
    """Error during comparison."""
    pass


def run_compare(config: CompareConfig) -> int:
    """
    Run the compare workflow.

    Returns exit code (0 = success).
    """
    try:
        # Generate run name if not provided
        if not config.name:
            config.name = f"compare_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

        # Create output directory structure
        compare_dir = Path(config.outdir) / config.name / "compare"
        compare_dir.mkdir(parents=True, exist_ok=True)
        (compare_dir / "plots").mkdir(exist_ok=True)
        (compare_dir / "tables").mkdir(exist_ok=True)
        (compare_dir / "report").mkdir(exist_ok=True)

        if config.verbose:
            print(f"[compare] Output directory: {compare_dir}")

        # Step 1: Parse inputs
        if config.verbose:
            print("[compare] Step 1: Parsing inputs...")

        runs_data: List[RunData] = []

        if config.run_paths:
            # Mode 1: Parse run directories
            parser = RunParser(verbose=config.verbose)
            for run_path in config.run_paths:
                run_data = parser.parse_run(run_path)
                if run_data is not None:
                    runs_data.append(run_data)
                else:
                    print(f"[compare] WARNING: Could not parse run: {run_path}")

        elif config.table_paths:
            # Mode 2: Parse manual tables
            for i, table_path in enumerate(config.table_paths):
                try:
                    abundance = pd.read_csv(table_path, sep="\t", index_col=0)
                except Exception as e:
                    raise CompareError(f"Could not read table '{table_path}': {e}")
                run_data = RunData(
                    run_id=f"table_{i+1}",
                    pipeline="manual",
                    run_dir=Path(table_path).parent,
                    abundance_table=abundance,
                )
                # Load taxonomy if provided
                if config.taxonomy_path and Path(config.taxonomy_path).exists():
                    run_data.taxonomy = pd.read_csv(config.taxonomy_path, sep="\t")
                runs_data.append(run_data)

        if len(runs_data) < 2:
            raise CompareError(f"Need at least 2 runs to compare, got {len(runs_data)}")

        if config.verbose:
            print(f"[compare] Loaded {len(runs_data)} runs:")
            for rd in runs_data:
                print(f"  - {rd.run_id} ({rd.pipeline}): {rd.abundance_table.shape if rd.abundance_table is not None else 'no data'}")

        # Step 2: Harmonise
        if config.verbose:
            print("[compare] Step 2: Harmonising data...")

        harmoniser = Harmoniser(
            rank=config.rank,
            norm=config.norm,
            sample_align=config.sample_align,
            min_prevalence=config.min_prevalence,
            min_mean_abundance=config.min_mean_abundance,
            verbose=config.verbose,
        )

        harmonised = harmoniser.harmonise(runs_data)

        if config.verbose:
            print(f"[compare] Harmonised: {harmonised.aligned_abundance.shape[0]} samples x {harmonised.aligned_abundance.shape[1]} taxa")

        # Save harmonised config
        config_dict = config.to_dict()
        config_dict["harmonisation"] = harmonised.settings
        config_dict["timestamp"] = datetime.now().isoformat()
        config_dict["runs_compared"] = [rd.run_id for rd in runs_data]

        config_path = compare_dir / "compare_config.json"
        with open(config_path, "w") as f:
            json.dump(config_dict, f, indent=2, default=str)

        if config.verbose:
            print(f"[compare] Config saved: {config_path}")

        # Step 3: Analyze
        if config.verbose:
            print("[compare] Step 3: Running comparisons...")

        # Load metadata if provided
        metadata = None
        if config.metadata_path and Path(config.metadata_path).exists():
            metadata = pd.read_csv(config.metadata_path, sep="\t", index_col=0)

        analyzer = ComparisonAnalyzer(
            group_col=config.group_col if metadata is not None else "",
            enable_diff=config.enable_diff,
            verbose=config.verbose,
        )

        results = analyzer.analyze(harmonised, metadata)

        if config.verbose:
            print(f"[compare] Computed {len(results.similarity_metrics)} similarity metrics")

        # Save tables
        if config.verbose:
            print("[compare] Saving tables...")

        # Aligned abundance
        harmonised.aligned_abundance.to_csv(
            compare_dir / "tables" / "aligned_abundance.tsv",
            sep="\t"
        )

        # Similarity metrics
        if results.similarity_metrics:
            pd.DataFrame([results.similarity_metrics]).to_csv(
                compare_dir / "tables" / "similarity_metrics.tsv",
                sep="\t", index=False
            )

        # Alpha diversity
        if results.alpha_diversity is not None:
            results.alpha_diversity.to_csv(
                compare_dir / "tables" / "alpha_diversity.tsv",
                sep="\t"
            )

        # Taxa mapping
        if harmonised.taxa_mapping:
            pd.DataFrame(harmonised.taxa_mapping).to_csv(
                compare_dir / "tables" / "taxa_mapping.tsv",
                sep="\t", index=False
            )

        # Top differential (if diff enabled)
        if results.differential_taxa is not None:
            results.differential_taxa.head(50).to_csv(
                compare_dir / "tables" / "top_differential.tsv",
                sep="\t"
            )

        # Step 4: Visualize
        if config.verbose:
            print("[compare] Step 4: Generating plots...")

        visualizer = ComparisonVisualizer(
            top_n=config.top_n,
            verbose=config.verbose,
        )

        plots = visualizer.generate_all(
            harmonised=harmonised,
            results=results,
            output_dir=compare_dir / "plots",
        )

        if config.verbose:
            print(f"[compare] Generated {len(plots)} plots")

        # Step 5: Generate report
        if config.verbose:
            print("[compare] Step 5: Generating report...")

        report_gen = ReportGenerator(verbose=config.verbose)
        report_path = report_gen.generate(
            config=config,
            harmonised=harmonised,
            results=results,
            plots=plots,
            output_dir=compare_dir / "report",
        )

        # Step 6: Write outputs.json
        if config.verbose:
            print("[compare] Step 6: Writing outputs.json...")

        outputs = {
            "module_name": "compare",
            "compare_id": config.name,
            "timestamp": datetime.now().isoformat(),
            "runs_compared": [rd.run_id for rd in runs_data],
            "run_paths": [str(rd.run_dir) for rd in runs_data],
            "compare_config": "compare_config.json",
            "plots": {k: f"plots/{v}" for k, v in plots.items()},
            "tables": {
                "aligned_abundance": "tables/aligned_abundance.tsv",
                "similarity_metrics": "tables/similarity_metrics.tsv",
                "alpha_diversity": "tables/alpha_diversity.tsv" if results.alpha_diversity is not None else None,
                "taxa_mapping": "tables/taxa_mapping.tsv" if harmonised.taxa_mapping else None,
                "top_differential": "tables/top_differential.tsv" if results.differential_taxa is not None else None,
            },
            "report": "report/index.html",
            "summary_metrics": results.similarity_metrics,
            "harmonisation_summary": {
                "n_samples": harmonised.aligned_abundance.shape[0],
                "n_taxa": harmonised.aligned_abundance.shape[1],
                "rank": config.rank,
                "norm": config.norm,
            },
        }

        # Remove None values from tables
        outputs["tables"] = {k: v for k, v in outputs["tables"].items() if v is not None}

        outputs_path = compare_dir / "outputs.json"
        with open(outputs_path, "w") as f:
            json.dump(outputs, f, indent=2, default=str)

        # Final summary
        print()
        print("=" * 60)
        print("COMPARE COMPLETE")
        print("=" * 60)
        print(f"  Runs compared: {len(runs_data)}")
        print(f"  Samples: {harmonised.aligned_abundance.shape[0]}")
        print(f"  Taxa: {harmonised.aligned_abundance.shape[1]}")
        print(f"  Rank: {config.rank}")
        print(f"  Normalisation: {config.norm}")
        print()
        print(f"  Report: {compare_dir / 'report' / 'index.html'}")
        print(f"  Outputs: {outputs_path}")
        print("=" * 60)

        return 0

    except (CompareError, ValueError) as e:
        print(f"[compare] ERROR: {e}")
        return 1
    except Exception as e:
        print(f"[compare] UNEXPECTED ERROR: {e}")
        if config.verbose:
            import traceback
            traceback.print_exc()
        return 1
