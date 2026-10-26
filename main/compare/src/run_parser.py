#!/usr/bin/env python3
"""
Parse STAMINA-BIOME pipeline run outputs.

Handles outputs.json and fallback path discovery for:
- sr_amp (QIIME2/DADA2)
- sr_meta (Kraken2/Bracken)
- lr_amp (Emu)
- lr_meta (Kraken2)
"""

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import pandas as pd


@dataclass
class RunData:
    """Parsed data from a pipeline run."""

    run_id: str
    pipeline: str
    run_dir: Path
    abundance_table: Optional[pd.DataFrame] = None
    taxonomy: Optional[pd.DataFrame] = None
    alpha_diversity: Optional[Dict[str, pd.DataFrame]] = None
    metadata: Optional[pd.DataFrame] = None
    qc_summary: Optional[Dict[str, Any]] = None
    outputs_json: Optional[Dict[str, Any]] = None


class RunParser:
    """Parse pipeline run outputs."""

    def __init__(self, verbose: bool = False):
        self.verbose = verbose

    def parse_run(self, run_path: str) -> Optional[RunData]:
        """
        Parse a run directory or outputs.json file.

        Args:
            run_path: Path to run directory or outputs.json

        Returns:
            RunData or None if parsing fails
        """
        path = Path(run_path).resolve()

        # Handle outputs.json path directly
        if path.name == "outputs.json" and path.exists():
            return self._parse_from_outputs_json(path)

        # Handle run directory
        if path.is_dir():
            # Try to find outputs.json in standard locations
            candidates = [
                path / "outputs.json",
                # Pipeline-specific locations
                path / "sr_amp" / "outputs.json",
                path / "sr_meta" / "outputs.json",
                path / "lr_amp" / "outputs.json",
                path / "lr_meta" / "outputs.json",
            ]

            for candidate in candidates:
                if candidate.exists():
                    return self._parse_from_outputs_json(candidate)

            # Fallback: try to detect pipeline type and parse directly
            return self._parse_fallback(path)

        if self.verbose:
            print(f"[run_parser] Could not find valid run at: {run_path}")
        return None

    def _parse_from_outputs_json(self, outputs_path: Path) -> Optional[RunData]:
        """Parse run using outputs.json as source of truth."""
        try:
            with open(outputs_path) as f:
                outputs = json.load(f)

            run_dir = outputs_path.parent
            if outputs_path.parent.name in ("sr_amp", "sr_meta", "lr_amp", "lr_meta"):
                run_dir = outputs_path.parent.parent

            pipeline = outputs.get("pipeline_id", outputs.get("module_name", "unknown"))
            run_id = outputs.get("run_id", run_dir.name)

            if self.verbose:
                print(f"[run_parser] Parsing {run_id} ({pipeline}) from outputs.json")

            run_data = RunData(
                run_id=run_id,
                pipeline=pipeline,
                run_dir=run_dir,
                outputs_json=outputs,
            )

            # Parse based on pipeline type
            if pipeline == "sr_amp":
                self._parse_sr_amp(run_data, outputs, outputs_path.parent)
            elif pipeline == "sr_meta":
                self._parse_sr_meta(run_data, outputs, outputs_path.parent)
            elif pipeline == "lr_amp":
                self._parse_lr_amp(run_data, outputs, outputs_path.parent)
            elif pipeline == "lr_meta":
                self._parse_lr_meta(run_data, outputs, outputs_path.parent)
            else:
                if self.verbose:
                    print(f"[run_parser] Unknown pipeline: {pipeline}")

            return run_data

        except Exception as e:
            if self.verbose:
                print(f"[run_parser] Error parsing {outputs_path}: {e}")
            return None

    def _parse_sr_amp(self, run_data: RunData, outputs: Dict, module_dir: Path):
        """Parse sr_amp (QIIME2) outputs."""
        # Feature table
        table_path = outputs.get("qiime2_exports", {}).get("table_tsv")
        if table_path:
            table_path = self._resolve_path(table_path, module_dir)
            if table_path.exists():
                run_data.abundance_table = self._read_qiime2_feature_table(table_path)

        # Taxonomy
        tax_path = outputs.get("qiime2_exports", {}).get("taxonomy_tsv")
        if tax_path:
            tax_path = self._resolve_path(tax_path, module_dir)
            if tax_path.exists():
                run_data.taxonomy = pd.read_csv(tax_path, sep="\t")

        # Alpha diversity
        alpha_tsvs = outputs.get("qiime2_artifacts", {}).get("alpha_diversity_tsv", {})
        if alpha_tsvs:
            run_data.alpha_diversity = {}
            for metric, path in alpha_tsvs.items():
                path = self._resolve_path(path, module_dir)
                if path.exists():
                    df = pd.read_csv(path, sep="\t", index_col=0)
                    run_data.alpha_diversity[metric] = df

        # Metrics/QC
        metrics_path = outputs.get("metrics_path")
        if metrics_path:
            metrics_path = self._resolve_path(metrics_path, module_dir)
            if metrics_path.exists():
                with open(metrics_path) as f:
                    run_data.qc_summary = json.load(f)

    def _parse_sr_meta(self, run_data: RunData, outputs: Dict, module_dir: Path):
        """Parse sr_meta (Kraken2) outputs."""
        # Look for Kraken2 reports in standard location
        kraken_dir = module_dir / "results" / "kraken2"
        if kraken_dir.exists():
            reports = list(kraken_dir.glob("*.report.tsv")) + list(kraken_dir.glob("*.kreport"))
            if reports:
                # Parse first report (single sample)
                run_data.abundance_table = self._read_kraken_report(reports[0])

        # Check multiple locations for tidy CSV (preferred - has all samples)
        # 1. r_postprocess tables directory (from outputs.json)
        # 2. Standard postprocess directory
        species_csv = None
        r_postprocess = outputs.get("r_postprocess", {})
        tables_dir = r_postprocess.get("tables_dir")
        if tables_dir:
            tables_path = Path(tables_dir)
            if tables_path.exists():
                candidate = tables_path / "kraken_species_tidy.csv"
                if candidate.exists():
                    species_csv = candidate
                    if self.verbose:
                        print(f"[run_parser] Found species CSV in r_postprocess: {species_csv}")

        # Fallback to standard locations
        if not species_csv:
            fallback_candidates = [
                module_dir / "results" / "tables" / "kraken_species_tidy.csv",
                module_dir / "results" / "postprocess" / "kraken_species_tidy.csv",
                module_dir / "sr_meta" / "results" / "tables" / "kraken_species_tidy.csv",
                module_dir / "sr_meta" / "results" / "postprocess" / "kraken_species_tidy.csv",
                module_dir / "sr_meta" / "final" / "tables" / "kraken_species_tidy.csv",
            ]
            for candidate in fallback_candidates:
                if candidate.exists():
                    species_csv = candidate
                    break

        if species_csv and species_csv.exists():
            df = pd.read_csv(species_csv)
            # Handle both column naming conventions
            sample_col = "sample_id" if "sample_id" in df.columns else "sample"
            taxon_col = "species" if "species" in df.columns else "taxon"
            value_col = "reads" if "reads" in df.columns else "abundance"

            if sample_col in df.columns and taxon_col in df.columns and value_col in df.columns:
                # Pivot to abundance matrix
                run_data.abundance_table = df.pivot(
                    index=sample_col, columns=taxon_col, values=value_col
                ).fillna(0)
                if self.verbose:
                    print(f"[run_parser] Loaded species tidy CSV: {run_data.abundance_table.shape}")

        # Metrics/QC
        metrics_path = outputs.get("metrics_path")
        if metrics_path:
            metrics_path = self._resolve_path(metrics_path, module_dir)
            if metrics_path.exists():
                with open(metrics_path) as f:
                    run_data.qc_summary = json.load(f)

    def _parse_lr_amp(self, run_data: RunData, outputs: Dict, module_dir: Path):
        """Parse lr_amp (Emu) outputs."""
        # Look for Emu abundance files
        emu_dir = module_dir / "results" / "emu"
        if emu_dir.exists():
            abundance_files = list(emu_dir.glob("*_rel-abundance.tsv"))
            if abundance_files:
                run_data.abundance_table = self._read_emu_abundance(abundance_files[0])

        # Metrics/QC
        metrics_path = outputs.get("metrics_path")
        if metrics_path:
            metrics_path = self._resolve_path(metrics_path, module_dir)
            if metrics_path.exists():
                with open(metrics_path) as f:
                    run_data.qc_summary = json.load(f)

    def _parse_lr_meta(self, run_data: RunData, outputs: Dict, module_dir: Path):
        """Parse lr_meta (Kraken2) outputs."""
        # lr_meta stores kreports in results/taxonomy/{run_name}/barcode*/
        taxonomy_dir = module_dir / "results" / "taxonomy"
        if taxonomy_dir.exists():
            # Find all kreport files recursively
            reports = list(taxonomy_dir.glob("*/*/*.kreport")) + list(taxonomy_dir.glob("*/*.kreport"))
            if reports and self.verbose:
                print(f"[run_parser] Found {len(reports)} kreport files in taxonomy dir")

        # Check multiple locations for tidy CSV (preferred - has all samples)
        # 1. r_postprocess tables directory (from outputs.json)
        # 2. Standard postprocess directory
        species_csv = None
        r_postprocess = outputs.get("r_postprocess", {})
        tables_dir = r_postprocess.get("tables_dir")
        if tables_dir:
            tables_path = Path(tables_dir)
            if tables_path.exists():
                candidate = tables_path / "kraken_species_tidy.csv"
                if candidate.exists():
                    species_csv = candidate
                    if self.verbose:
                        print(f"[run_parser] Found species CSV in r_postprocess: {species_csv}")

        # Fallback to standard locations
        if not species_csv:
            fallback_candidates = [
                module_dir / "results" / "tables" / "kraken_species_tidy.csv",
                module_dir / "results" / "postprocess" / "kraken_species_tidy.csv",
                module_dir / "lr_meta" / "results" / "tables" / "kraken_species_tidy.csv",
                module_dir / "lr_meta" / "results" / "postprocess" / "kraken_species_tidy.csv",
                module_dir / "lr_meta" / "final" / "tables" / "kraken_species_tidy.csv",
            ]
            for candidate in fallback_candidates:
                if candidate.exists():
                    species_csv = candidate
                    break

        if species_csv and species_csv.exists():
            df = pd.read_csv(species_csv)
            # Handle both column naming conventions
            sample_col = "sample_id" if "sample_id" in df.columns else "sample"
            taxon_col = "species" if "species" in df.columns else "taxon"
            value_col = "reads" if "reads" in df.columns else "abundance"

            if sample_col in df.columns and taxon_col in df.columns and value_col in df.columns:
                # Pivot to abundance matrix
                run_data.abundance_table = df.pivot(
                    index=sample_col, columns=taxon_col, values=value_col
                ).fillna(0)
                if self.verbose:
                    print(f"[run_parser] Loaded species tidy CSV: {run_data.abundance_table.shape}")

        # Metrics/QC
        metrics_path = outputs.get("metrics_path")
        if metrics_path:
            metrics_path = self._resolve_path(metrics_path, module_dir)
            if metrics_path.exists():
                with open(metrics_path) as f:
                    run_data.qc_summary = json.load(f)

    def _parse_fallback(self, run_dir: Path) -> Optional[RunData]:
        """Fallback parsing when outputs.json is missing."""
        if self.verbose:
            print(f"[run_parser] Using fallback parsing for: {run_dir}")

        # Try to detect pipeline type from directory structure
        pipeline = "unknown"
        module_dir = run_dir

        # Check for pipeline subdirectories
        for p in ("sr_amp", "sr_meta", "lr_amp", "lr_meta"):
            if (run_dir / p).is_dir():
                pipeline = p
                module_dir = run_dir / p
                break

        run_data = RunData(
            run_id=run_dir.name,
            pipeline=pipeline,
            run_dir=run_dir,
        )

        # QIIME2 outputs (sr_amp)
        qiime2_table = module_dir / "results" / "qiime2" / "exports" / "table" / "feature-table.tsv"
        if qiime2_table.exists():
            run_data.abundance_table = self._read_qiime2_feature_table(qiime2_table)
            run_data.pipeline = "sr_amp"

            tax_path = module_dir / "results" / "qiime2" / "exports" / "taxonomy" / "taxonomy.tsv"
            if tax_path.exists():
                run_data.taxonomy = pd.read_csv(tax_path, sep="\t")

        # Kraken2 outputs (sr_meta, lr_meta) — prefer tidy aggregate CSV over raw kreport
        kraken_tidy_candidates = [
            module_dir / "results" / "tables" / "kraken_species_tidy.csv",
            module_dir / "results" / "postprocess" / "kraken_species_tidy.csv",
            module_dir / "lr_meta" / "results" / "tables" / "kraken_species_tidy.csv",
            module_dir / "lr_meta" / "final" / "tables" / "kraken_species_tidy.csv",
            module_dir / "sr_meta" / "results" / "tables" / "kraken_species_tidy.csv",
            module_dir / "sr_meta" / "final" / "tables" / "kraken_species_tidy.csv",
        ]
        for tidy_csv in kraken_tidy_candidates:
            if tidy_csv.exists():
                df = pd.read_csv(tidy_csv)
                sample_col = "sample_id" if "sample_id" in df.columns else "sample"
                taxon_col = "species" if "species" in df.columns else "taxon"
                value_col = "reads" if "reads" in df.columns else "abundance"
                if sample_col in df.columns and taxon_col in df.columns and value_col in df.columns:
                    run_data.abundance_table = df.pivot(
                        index=sample_col, columns=taxon_col, values=value_col
                    ).fillna(0)
                    run_data.pipeline = "lr_meta" if "lr_meta" in str(tidy_csv) else "sr_meta"
                    if self.verbose:
                        print(f"[run_parser] Fallback: loaded tidy CSV {tidy_csv}")
                    break

        # If no tidy CSV, fall back to raw kreport (single-sample only)
        if run_data.abundance_table is None:
            kraken_dir = module_dir / "results" / "kraken2"
            if kraken_dir.exists():
                reports = list(kraken_dir.glob("*.report.tsv")) + list(kraken_dir.glob("*.kreport"))
                if reports:
                    run_data.abundance_table = self._read_kraken_report(reports[0])
                    run_data.pipeline = "sr_meta"

        # Emu outputs (lr_amp)
        emu_dir = module_dir / "results" / "emu"
        if emu_dir.exists():
            abundance_files = list(emu_dir.glob("*_rel-abundance.tsv"))
            if abundance_files:
                run_data.abundance_table = self._read_emu_abundance(abundance_files[0])
                run_data.pipeline = "lr_amp"

        if run_data.abundance_table is None:
            if self.verbose:
                print(f"[run_parser] No abundance data found in: {run_dir}")
            return None

        return run_data

    def _resolve_path(self, path_str: str, base_dir: Path) -> Path:
        """Resolve a path, handling container paths (/work/...)."""
        path = Path(path_str)

        # Handle container paths
        if str(path).startswith("/work/"):
            # Try to find relative to base_dir
            rel_path = str(path).replace("/work/outputs/", "").replace("/work/", "")
            # Try various bases
            candidates = [
                base_dir / rel_path,
                base_dir.parent / rel_path,
                base_dir.parent.parent / rel_path,
            ]
            for c in candidates:
                if c.exists():
                    return c
            # Return as-is if nothing found
            return path

        # Absolute path
        if path.is_absolute():
            if path.exists():
                return path
            # Try relative to base_dir
            return base_dir / path.name

        # Relative path
        return base_dir / path

    def _read_qiime2_feature_table(self, path: Path) -> pd.DataFrame:
        """Read QIIME2 feature table (taxa x samples) and transpose to samples x taxa."""
        # Skip comment lines
        with open(path) as f:
            lines = f.readlines()

        # Find header line
        start_idx = 0
        for i, line in enumerate(lines):
            if not line.startswith("#") or line.startswith("#OTU ID"):
                start_idx = i
                break

        # Read as DataFrame
        df = pd.read_csv(path, sep="\t", skiprows=start_idx, index_col=0)

        # Transpose so samples are rows
        return df.T

    def _read_kraken_report(self, path: Path) -> pd.DataFrame:
        """Read Kraken2 report and convert to abundance matrix."""
        # Kraken report format:
        # percent  reads_clade  reads_taxon  rank  taxid  name
        try:
            df = pd.read_csv(
                path,
                sep="\t",
                header=None,
                names=["percent", "reads_clade", "reads_taxon", "rank", "taxid", "name"],
            )

            # Clean taxon names
            df["name"] = df["name"].str.strip()

            # Filter to species/genus level
            # S = species, G = genus
            df_filtered = df[df["rank"].isin(["S", "G", "F", "O", "C", "P", "K", "D"])]

            # Create a simple abundance series (single sample)
            # Use reads_clade for hierarchical abundance
            sample_id = path.stem.replace(".report", "").replace(".kreport", "")

            abundance = df_filtered.set_index("name")["reads_clade"].to_frame(sample_id)

            return abundance.T  # Samples as rows

        except Exception as e:
            print(f"[run_parser] Error reading Kraken report {path}: {e}")
            return pd.DataFrame()

    def _read_emu_abundance(self, path: Path) -> pd.DataFrame:
        """Read Emu relative abundance file."""
        try:
            df = pd.read_csv(path, sep="\t")

            # Emu format: tax_id, abundance, lineage columns
            # Pivot to get taxa as columns
            if "lineage" in df.columns and "abundance" in df.columns:
                # Use lineage as taxon name
                sample_id = path.stem.replace("_rel-abundance", "")
                abundance = df.set_index("lineage")["abundance"].to_frame(sample_id)
                return abundance.T

            return df

        except Exception as e:
            print(f"[run_parser] Error reading Emu file {path}: {e}")
            return pd.DataFrame()
