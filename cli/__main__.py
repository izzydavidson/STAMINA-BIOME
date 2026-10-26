#!/usr/bin/env python3
"""STAMINA-BIOME CLI entry point."""

import argparse
import glob
import os
import sys
import textwrap
from pathlib import Path

from cli.discovery import (
    find_repo_root,
    get_pipeline_info,
    list_pipeline_ids,
)
from cli.runner import RunConfig, RunnerError, run_pipeline
from cli.progress import Colors, is_tty, print_banner


class StaminaBiomeHelpFormatter(argparse.RawDescriptionHelpFormatter):
    """Custom help formatter with colored headers and better styling."""

    def __init__(self, prog, indent_increment=2, max_help_position=40, width=100):
        super().__init__(prog, indent_increment, max_help_position, width)

    def start_section(self, heading):
        """Override to add colors to section headers."""
        if heading:
            # Check for specific headers that need special coloring
            if "REQUIRED" in heading.upper():
                heading = Colors.red_bold(heading) if is_tty() else f"*** {heading} ***"
            elif any(x in heading.upper() for x in ["OUTPUT", "SAMPLE", "PRIMER", "DATABASE", "DEMUX", "EXECUTION"]):
                heading = Colors.cyan_bold(heading) if is_tty() else heading
        super().start_section(heading)


def build_run_epilog():
    """Build the detailed epilog for the run command with examples."""
    if is_tty():
        examples_header = Colors.green_bold("EXAMPLES:")
        pipelines_header = Colors.cyan_bold("PIPELINES:")
        sample_types_header = Colors.cyan_bold("SAMPLE TYPES:")
    else:
        examples_header = "EXAMPLES:"
        pipelines_header = "PIPELINES:"
        sample_types_header = "SAMPLE TYPES:"

    return f"""
{examples_header}
  # Basic run with required parameters only
  stamina-biome run -p sr_amp -i reads/*.fastq.gz

  # Short-read metagenomics with Kraken2 database
  stamina-biome run -p sr_meta -i reads/ --db /path/to/kraken2/db -o ./results

  # Long-read amplicon with vaginal sample (enables Valencia)
  stamina-biome run -p lr_amp -i pod5_pass/ --sample-type vaginal -o ./results

  # Multiplexed samples with barcode kit
  stamina-biome run -p lr_amp -i data/ --barcode-kit SQK-NBD114-24 -t 8

  # Dry-run to preview configuration
  stamina-biome run -p sr_meta -i reads/ --sample-type vaginal --dry-run

  # With primer sequences for cutadapt
  stamina-biome run -p sr_amp -i reads/ --primer-f CCTACGGGNGGCWGCAG --primer-r GACTACHVGGGTATCTAATCC

{pipelines_header}
  lr_amp   Long-read 16S amplicon (ONT, full-length 16S)
  lr_meta  Long-read shotgun metagenomics (ONT)
  sr_amp   Short-read 16S amplicon (Illumina)
  sr_meta  Short-read shotgun metagenomics (Illumina)

{sample_types_header}
  vaginal  Enables Valencia CST analysis automatically
  gut      Gut microbiome samples
  oral     Oral microbiome samples
  skin     Skin microbiome samples
  other    Generic sample type (default)
"""


def print_run_help_header():
    """Print custom header before help text."""
    print_banner()


class CustomArgumentParser(argparse.ArgumentParser):
    """ArgumentParser that prints banner before help for 'run' command."""

    def __init__(self, *args, show_banner=False, **kwargs):
        self.show_banner = show_banner
        super().__init__(*args, **kwargs)

    def format_help(self):
        """Format help with optional banner."""
        help_text = super().format_help()
        if self.show_banner:
            # Prepend newline for spacing
            return "\n" + help_text
        return help_text


def main():
    # Print banner if --help is in argv for run command
    show_run_help = len(sys.argv) >= 2 and sys.argv[1] == "run" and ("--help" in sys.argv or "-h" in sys.argv)

    if show_run_help:
        print_banner()

    # Top-level parser
    parser = argparse.ArgumentParser(
        prog="stamina-biome",
        formatter_class=StaminaBiomeHelpFormatter,
        description=textwrap.dedent("""
        STAMINA-BIOME - Standardised, Technology-Agnostic Framework for Microbiome Investigation and Analysis

        A unified CLI for running microbiome analysis pipelines on long-read
        and short-read sequencing data (16S amplicon and shotgun metagenomics).
        """),
        epilog=textwrap.dedent(f"""
{Colors.cyan_bold("COMMANDS:") if is_tty() else "COMMANDS:"}
  setup    Set up STAMINA-BIOME (first-time installation)
  run      Run a microbiome analysis pipeline
  compare  Compare results from multiple pipeline runs
  list     List available pipelines
  info     Show detailed pipeline information
  doctor   Check system requirements and diagnose issues

Use 'stamina-biome <command> --help' for more information on a specific command.
        """),
    )
    subparsers = parser.add_subparsers(dest="command", metavar="command")

    # =========================================================================
    # RUN COMMAND - with argument groups for clarity
    # =========================================================================
    run_parser = subparsers.add_parser(
        "run",
        help="Run a pipeline",
        formatter_class=StaminaBiomeHelpFormatter,
        description=textwrap.dedent("""
        Run a microbiome analysis pipeline on your sequencing data.

        This command executes the full pipeline including quality control,
        taxonomic classification (Kraken2/Bracken, QIIME2/DADA2, or Emu),
        and optional Valencia CST analysis for vaginal samples.

        Supports files, directories, and glob patterns as input.
        Automatically detects paired-end vs single-end reads.
        """),
        epilog=build_run_epilog(),
    )

    # --- REQUIRED arguments ---
    required_group = run_parser.add_argument_group(
        'REQUIRED arguments',
        'These parameters must be specified for every run'
    )
    required_group.add_argument(
        "--pipeline", "-p",
        required=True,
        choices=list_pipeline_ids(),
        metavar="PIPELINE",
        help="Pipeline to run: lr_amp | lr_meta | sr_amp | sr_meta",
    )
    required_group.add_argument(
        "--input", "-i",
        required=False,
        nargs="+",
        metavar="PATH",
        help="Input file(s), directory, or glob pattern (e.g., 'reads/', '*.fastq.gz'). "
             "Required unless --samples-csv is given.",
    )

    # --- OUTPUT options ---
    output_group = run_parser.add_argument_group(
        'OUTPUT options',
        'Control where and how results are saved'
    )
    output_group.add_argument(
        "--outdir", "-o",
        default="./outputs",
        metavar="DIR",
        help="Output directory (default: ./outputs)",
    )
    output_group.add_argument(
        "--run-id",
        default="",
        metavar="ID",
        help="Custom run ID. If empty, auto-generates YYYYMMDD_HHMMSS timestamp",
    )
    output_group.add_argument(
        "--force",
        action="store_true",
        help="Force overwrite if output directory already exists",
    )

    # --- SAMPLE options ---
    sample_group = run_parser.add_argument_group(
        'SAMPLE options',
        'Describe your samples for appropriate analysis'
    )
    sample_group.add_argument(
        "--sample-type",
        default="other",
        metavar="TYPE",
        help="Sample type: vaginal | gut | oral | skin | other (default: other). "
             "'vaginal' auto-enables Valencia CST analysis",
    )
    sample_group.add_argument(
        "--sample-id",
        default="sample",
        metavar="ID",
        help="Sample identifier for single-sample runs (default: sample)",
    )
    sample_group.add_argument(
        "--samples-csv",
        default="",
        metavar="PATH",
        help="Run a BATCH of independent samples instead of a single run. CSV with header "
             "'sample_name,r1,r2' (leave r2 blank for single-end). Mutually exclusive with "
             "--input. Each sample becomes its own run under "
             "<outdir>/<batch-id>/<sample_name>/, followed by an automatic comparison "
             "report across all samples (see: stamina-biome compare).",
    )
    sample_group.add_argument(
        "--sample-sheet",
        default="",
        metavar="PATH",
        help="Path to a barcode->sample-name CSV/TSV (header: barcode,sample_name) for "
             "demultiplexed runs. Relabels barcode IDs with human-readable sample names "
             "in final tables/plots (heatmap, piechart, stacked bar, results.csv).",
    )
    sample_group.add_argument(
        "--valencia",
        action="store_true",
        help="Force enable Valencia CST analysis (auto-enabled for --sample-type vaginal)",
    )
    sample_group.add_argument(
        "--no-valencia",
        action="store_true",
        help="Disable Valencia CST analysis even for vaginal samples",
    )
    sample_group.add_argument(
        "--valencia-centroids",
        metavar="PATH",
        help="Path to Valencia CST centroids CSV file (default: auto-detect)",
    )

    # --- PRIMER options (sr_amp only) ---
    primer_group = run_parser.add_argument_group(
        'PRIMER options (sr_amp only)',
        'Primer sequences for cutadapt trimming in QIIME2'
    )
    primer_group.add_argument(
        "--primer-f",
        default="",
        metavar="SEQ",
        help="Forward primer sequence (e.g., CCTACGGGNGGCWGCAG for V3-V4)",
    )
    primer_group.add_argument(
        "--primer-r",
        default="",
        metavar="SEQ",
        help="Reverse primer sequence (e.g., GACTACHVGGGTATCTAATCC for V3-V4)",
    )

    # --- AMPLICON options (lr_amp only) ---
    amplicon_group = run_parser.add_argument_group(
        'AMPLICON options (lr_amp only)',
        'Configure amplicon type for long-read 16S classification'
    )
    amplicon_group.add_argument(
        "--amplicon-type",
        choices=["full-length", "partial"],
        default="full-length",
        metavar="TYPE",
        help="16S amplicon type: 'full-length' uses Emu classifier (default), "
             "'partial' uses Kraken2 classifier. Full-length is recommended for "
             "ONT long-read 16S data targeting the complete 16S gene (~1500bp).",
    )
    amplicon_group.add_argument(
        "--type",
        dest="seq_type",
        choices=["map-ont", "map-pb", "map-hifi", "lr:hq"],
        default="map-ont",
        metavar="PRESET",
        help="Sequencing technology preset for Emu/minimap2 alignment: "
             "map-ont = ONT standard Nanopore reads (default); "
             "map-pb = PacBio CLR (general PacBio mapping preset); "
             "map-hifi = PacBio HiFi high-accuracy CCS reads; "
             "lr:hq = Nanopore Q20+ high-quality long reads.",
    )
    amplicon_group.add_argument(
        "--min-pid",
        dest="emu_min_pid",
        type=float,
        default=None,
        metavar="FLOAT",
        help="Emu minimum percent identity (0-100) for a read alignment to count "
             "as evidence for a species (Emu's own default is 0, i.e. no identity "
             "filter). Recommended: 95 -- empirically found to reduce false-positive "
             "species calls (near-neighbor misclassification) with no recall cost "
             "across all 4 body sites tested. min-pid=99 is too strict and causes "
             "near-total recovery collapse; do not use.",
    )

    # --- DATABASE options ---
    db_group = run_parser.add_argument_group(
        'DATABASE options',
        'Paths to reference databases for taxonomic classification'
    )
    db_group.add_argument(
        "--db",
        default="",
        metavar="PATH",
        help="Kraken2 database path (required for sr_meta, lr_meta; also used by lr_amp with --amplicon-type partial). "
             "Download from: https://benlangmead.github.io/aws-indexes/k2",
    )
    db_group.add_argument(
        "--emu-db",
        default="",
        metavar="PATH",
        help="Emu database path (optional for lr_amp, overrides default)",
    )
    db_group.add_argument(
        "--kraken-confidence",
        type=float,
        default=None,
        metavar="FLOAT",
        help="Kraken2 confidence threshold (0–1). Fraction of k-mers that must support a "
             "classification. Site defaults: vaginal=0.02, gut=0.03, oral=0.04, skin=0.03. "
             "Applies to both vaginal and non-vaginal classifications for this run.",
    )
    db_group.add_argument(
        "--kraken-min-hit-groups",
        type=int,
        default=None,
        metavar="N",
        help="Kraken2 minimum distinct k-mer hit groups required for a classification. "
             "Site defaults: vaginal=2, gut=4, oral=4, skin=4. "
             "Applies to both vaginal and non-vaginal classifications for this run.",
    )
    db_group.add_argument(
        "--bracken-readlen",
        type=int,
        default=None,
        metavar="BP",
        help="Bracken abundance re-estimation read length in bp. Must match a "
             "database{N}mers.kmer_distrib file present in the Kraken2 DB, or Bracken "
             "is silently skipped for that run. Pipeline defaults: lr_meta=1500, sr_meta=150. "
             "Applies to both vaginal and non-vaginal classifications for this run.",
    )
    db_group.add_argument(
        "--no-bracken",
        action="store_true",
        help="Disable Bracken abundance re-estimation for this run (kraken2 classification "
             "still runs; results.csv falls back to the raw kraken2 report).",
    )
    db_group.add_argument(
        "--kraken-memory-mapping",
        action="store_true",
        help="Enable kraken2 --memory-mapping: read the hash table from disk instead of "
             "loading it fully into RAM. Slower (disk I/O bound) but avoids OOM on low-RAM "
             "hosts when the database is large relative to available memory.",
    )

    # --- PREPROCESSING options ---
    preproc_group = run_parser.add_argument_group(
        'PREPROCESSING options',
        'Control read preprocessing before classification'
    )
    preproc_group.add_argument(
        "--host-depletion",
        action="store_true",
        help="Enable host read removal (human genome depletion) before classification. "
             "Useful for sr_meta/lr_meta when samples may contain human contamination.",
    )
    preproc_group.add_argument(
        "--human-index",
        default="",
        metavar="PATH",
        help="Path to human genome minimap2 index (.mmi file) for host depletion. "
             "Required when --host-depletion is enabled. "
             "Example: main/data/reference/human/grch38.mmi",
    )
    preproc_group.add_argument(
        "--minimap2-split",
        action="store_true",
        help="Enable minimap2 split-prefix mode for low-RAM machines. "
             "Processes the index in chunks to reduce memory usage.",
    )
    preproc_group.add_argument(
        "--min-qscore",
        type=int,
        default=10,
        metavar="N",
        help="Minimum quality score for read filtering (default: 10). "
             "Uses NanoFilt for long-read, fastp for short-read pipelines.",
    )
    preproc_group.add_argument(
        "--no-qfilter",
        action="store_true",
        help="Disable quality score filtering entirely.",
    )

    # --- DEMULTIPLEXING options (ONT long-read) ---
    demux_group = run_parser.add_argument_group(
        'DEMULTIPLEXING options (long-read only)',
        'For multiplexed ONT runs with barcoded samples'
    )
    demux_group.add_argument(
        "--barcode-kit",
        default="",
        metavar="KIT",
        help="Barcode kit (e.g., SQK-NBD114-24, EXP-PBC001). "
             "Empty = single sample, no demultiplexing",
    )
    demux_group.add_argument(
        "--ligation-kit",
        default="SQK-LSK114",
        metavar="KIT",
        help="Ligation kit used for library prep (default: SQK-LSK114)",
    )
    demux_group.add_argument(
        "--sequencing-kit",
        default="",
        metavar="KIT",
        help="Sequencing kit for Dorado adapter trimming (e.g., SQK-LSK114). "
             "If not specified, defaults to --ligation-kit value. "
             "Required for Dorado trim operation.",
    )
    demux_group.add_argument(
        "--dorado-model",
        default="",
        metavar="MODEL",
        help="Dorado basecalling model for FAST5/POD5 input (e.g., 'dna_r10.4.1_e8.2_400bps_hac@v4.1.0'). "
             "Required when input is FAST5/POD5 raw signal data.",
    )
    demux_group.add_argument(
        "--dorado-bin",
        default="",
        metavar="PATH",
        help="Absolute path to Dorado binary (e.g., '/path/to/dorado-1.0.0/bin/dorado'). "
             "Required for FAST5 input. Download from https://github.com/nanoporetech/dorado/releases",
    )
    demux_group.add_argument(
        "--dorado-models-dir",
        default="",
        metavar="DIR",
        help="Absolute path to directory containing Dorado models (e.g., '/path/to/models'). "
             "Required for FAST5 input. The model specified by --dorado-model must exist in this directory.",
    )

    # --- EXECUTION options ---
    exec_group = run_parser.add_argument_group(
        'EXECUTION options',
        'Control how the pipeline runs'
    )
    exec_group.add_argument(
        "--threads", "-t",
        type=int,
        default=4,
        metavar="N",
        help="Number of CPU threads to use (default: 4)",
    )
    exec_group.add_argument(
        "--no-container",
        action="store_true",
        help="Run without Docker container (use locally installed tools)",
    )
    exec_group.add_argument(
        "--image",
        default="",
        metavar="TAG",
        help="Override Docker image (e.g., 'stamina-biome-tools-sr:dev'). "
             "Useful for dev/testing with custom images.",
    )
    exec_group.add_argument(
        "--no-postprocess",
        action="store_true",
        help="Skip postprocessing (plots, summaries, Valencia)",
    )
    exec_group.add_argument(
        "--no-finalize",
        action="store_true",
        help="Skip finalization steps (report generation)",
    )
    exec_group.add_argument(
        "--no-qc-in-final",
        action="store_true",
        help="Don't copy FastQC/MultiQC reports to final/qc/ directory",
    )
    exec_group.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would run without executing anything",
    )
    exec_group.add_argument(
        "--verbose", "-v",
        action="store_true",
        default=True,
        help="Enable verbose output with detailed progress (enabled by default)",
    )
    exec_group.add_argument(
        "--quiet", "-q",
        action="store_true",
        help="Suppress real-time logging output",
    )
    exec_group.add_argument(
        "--debug-config",
        action="store_true",
        help="Print full config JSON (for debugging only)",
    )

    # =========================================================================
    # LIST COMMAND
    # =========================================================================
    list_parser = subparsers.add_parser(
        "list",
        help="List available pipelines",
        formatter_class=StaminaBiomeHelpFormatter,
        description="Display all available STAMINA-BIOME pipelines with brief descriptions.",
    )

    # =========================================================================
    # SETUP COMMAND
    # =========================================================================
    setup_parser = subparsers.add_parser(
        "setup",
        help="Set up STAMINA-BIOME (install Docker, download databases)",
        formatter_class=StaminaBiomeHelpFormatter,
        description=textwrap.dedent("""
        Interactive setup wizard for STAMINA-BIOME.

        Checks system requirements, helps install Docker if needed,
        and downloads reference databases for your pipelines.

        Run this after first installing STAMINA-BIOME to ensure everything
        is configured correctly.
        """),
    )
    setup_parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Run without prompts (for CI/automation)",
    )
    setup_parser.add_argument(
        "--database", "-d",
        action="append",
        dest="databases",
        metavar="DB",
        help="Database to download: kraken2-standard-8, kraken2-standard-16, emu-default",
    )
    setup_parser.add_argument(
        "--skip-path",
        action="store_true",
        help="Skip adding stamina-biome to PATH",
    )

    # =========================================================================
    # DOCTOR COMMAND
    # =========================================================================
    doctor_parser = subparsers.add_parser(
        "doctor",
        help="Check system requirements and diagnose issues",
        formatter_class=StaminaBiomeHelpFormatter,
        description=textwrap.dedent("""
        Diagnose your STAMINA-BIOME installation.

        Checks Docker status, installed databases, disk space,
        and other requirements. Use this to troubleshoot issues.
        """),
    )

    # =========================================================================
    # INFO COMMAND
    # =========================================================================
    info_parser = subparsers.add_parser(
        "info",
        help="Show pipeline information",
        formatter_class=StaminaBiomeHelpFormatter,
        description="Show detailed information about one or all pipelines.",
    )
    info_parser.add_argument(
        "pipeline",
        nargs="?",
        metavar="PIPELINE",
        help="Pipeline ID to show info for (omit to show all pipelines)",
    )

    # =========================================================================
    # COMPARE COMMAND
    # =========================================================================
    compare_parser = subparsers.add_parser(
        "compare",
        help="Compare pipeline run outputs",
        formatter_class=StaminaBiomeHelpFormatter,
        description=textwrap.dedent("""
        Compare taxonomic profiles from multiple pipeline runs.

        This command harmonises abundance data across runs, computes similarity
        metrics, diversity analyses, and generates visualizations and reports.

        Supports two input modes:
        1. Run directories (preferred): Automatically parses outputs.json
        2. Manual tables: Provide TSV abundance tables directly
        """),
        epilog=textwrap.dedent(f"""
{Colors.green_bold("EXAMPLES:") if is_tty() else "EXAMPLES:"}
  # Compare two pipeline runs
  stamina-biome compare --run outputs/run1 --run outputs/run2

  # Compare runs with custom settings
  stamina-biome compare --run run1 --run run2 --rank species --norm clr --top-n 30

  # Compare manual abundance tables
  stamina-biome compare --table table1.tsv --table table2.tsv --taxonomy tax.tsv

  # With metadata for PERMANOVA
  stamina-biome compare --run run1 --run run2 --metadata meta.tsv --group-col treatment

  # Enable differential abundance analysis
  stamina-biome compare --run run1 --run run2 --diff -v
        """),
    )

    # --- INPUT options ---
    compare_input_group = compare_parser.add_argument_group(
        'INPUT options',
        'Specify runs or tables to compare (use --run OR --table, not both)'
    )
    compare_input_group.add_argument(
        "--run",
        action="append",
        dest="runs",
        metavar="PATH",
        help="Path to pipeline run directory (can specify multiple times)",
    )
    compare_input_group.add_argument(
        "--table",
        action="append",
        dest="tables",
        metavar="PATH",
        help="Path to TSV abundance table (can specify multiple times)",
    )
    compare_input_group.add_argument(
        "--taxonomy",
        default="",
        metavar="PATH",
        help="Taxonomy file for manual tables (TSV with Feature ID, Taxon columns)",
    )
    compare_input_group.add_argument(
        "--metadata",
        default="",
        metavar="PATH",
        help="Sample metadata file (TSV, index = sample ID)",
    )

    # --- HARMONISATION options ---
    compare_harm_group = compare_parser.add_argument_group(
        'HARMONISATION options',
        'Control how data is processed before comparison'
    )
    compare_harm_group.add_argument(
        "--rank",
        default="genus",
        choices=["species", "genus", "family", "order", "class", "phylum"],
        metavar="RANK",
        help="Taxonomic rank for aggregation (default: genus)",
    )
    compare_harm_group.add_argument(
        "--norm",
        default="relative",
        choices=["relative", "clr"],
        metavar="METHOD",
        help="Normalisation method: relative | clr (default: relative)",
    )
    compare_harm_group.add_argument(
        "--sample-align",
        default="intersection",
        choices=["intersection", "union"],
        metavar="MODE",
        help="Sample alignment: intersection | union (default: intersection)",
    )
    compare_harm_group.add_argument(
        "--min-prevalence",
        type=float,
        default=0.1,
        metavar="FRAC",
        help="Minimum prevalence filter (0-1, default: 0.1)",
    )
    compare_harm_group.add_argument(
        "--min-abundance",
        type=float,
        default=0.0,
        metavar="FRAC",
        help="Minimum mean abundance filter (default: 0.0)",
    )

    # --- ANALYSIS options ---
    compare_analysis_group = compare_parser.add_argument_group(
        'ANALYSIS options',
        'Control comparison analyses'
    )
    compare_analysis_group.add_argument(
        "--top-n",
        type=int,
        default=20,
        metavar="N",
        help="Number of top taxa to display in plots (default: 20)",
    )
    compare_analysis_group.add_argument(
        "--group-col",
        default="",
        metavar="COL",
        help="Metadata column for PERMANOVA grouping",
    )
    compare_analysis_group.add_argument(
        "--diff",
        action="store_true",
        help="Enable differential abundance analysis (requires exactly 2 runs)",
    )

    # --- OUTPUT options ---
    compare_output_group = compare_parser.add_argument_group(
        'OUTPUT options',
        'Control where and how results are saved'
    )
    compare_output_group.add_argument(
        "--outdir", "-o",
        default="./outputs",
        metavar="DIR",
        help="Output directory (default: ./outputs)",
    )
    compare_output_group.add_argument(
        "--name",
        default="",
        metavar="NAME",
        help="Comparison name (default: compare_YYYYMMDD_HHMMSS)",
    )
    compare_output_group.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable verbose output",
    )

    args = parser.parse_args()

    if args.command is None:
        print_banner()
        parser.print_help()
        sys.exit(0)

    if args.command == "list":
        print("\nAvailable pipelines:")
        for pid in list_pipeline_ids():
            info = get_pipeline_info(pid)
            print(f"  {Colors.cyan_bold(pid):20} - {info['label']}")
        print()
        sys.exit(0)

    if args.command == "setup":
        from cli.setup import run_setup
        exit_code = run_setup(
            interactive=not args.non_interactive,
            databases=args.databases,
            skip_path=args.skip_path,
        )
        sys.exit(exit_code)

    if args.command == "doctor":
        from cli.setup import run_doctor
        exit_code = run_doctor()
        sys.exit(exit_code)

    if args.command == "info":
        if args.pipeline:
            pipelines = [args.pipeline]
        else:
            pipelines = list_pipeline_ids()

        for pid in pipelines:
            info = get_pipeline_info(pid)
            if info:
                print(f"\n{Colors.cyan_bold(pid)}:")
                print(f"  Label:       {info['label']}")
                print(f"  Read type:   {info['read_technology']}")
                print(f"  Approach:    {info['approach']}")
                print(f"  Description: {info['description']}")
            else:
                print(f"\n{Colors.red_bold('Unknown pipeline')}: {pid}")
        print()
        sys.exit(0)

    if args.command == "compare":
        # Import compare module
        try:
            from compare.src.compare import CompareConfig, run_compare
        except ImportError as e:
            print(f"{Colors.red_bold('ERROR')}: Could not import compare module: {e}", file=sys.stderr)
            print("Make sure you're running from the STAMINA-BIOME repository root.", file=sys.stderr)
            sys.exit(1)

        # Validate inputs
        runs = args.runs or []
        tables = args.tables or []

        if runs and tables:
            print(f"{Colors.red_bold('ERROR')}: Cannot use both --run and --table. Choose one input mode.", file=sys.stderr)
            sys.exit(1)

        if not runs and not tables:
            print(f"{Colors.red_bold('ERROR')}: Must specify at least 2 runs (--run) or 2 tables (--table).", file=sys.stderr)
            sys.exit(1)

        if runs and len(runs) < 2:
            print(f"{Colors.red_bold('ERROR')}: Need at least 2 runs to compare, got {len(runs)}.", file=sys.stderr)
            sys.exit(1)

        if tables and len(tables) < 2:
            print(f"{Colors.red_bold('ERROR')}: Need at least 2 tables to compare, got {len(tables)}.", file=sys.stderr)
            sys.exit(1)

        # Build config
        config = CompareConfig(
            run_paths=runs,
            table_paths=tables,
            taxonomy_path=args.taxonomy,
            metadata_path=args.metadata,
            rank=args.rank,
            norm=args.norm,
            sample_align=args.sample_align,
            min_prevalence=args.min_prevalence,
            min_mean_abundance=args.min_abundance,
            top_n=args.top_n,
            group_col=args.group_col,
            enable_diff=args.diff,
            outdir=args.outdir,
            name=args.name,
            verbose=args.verbose,
        )

        if args.verbose:
            print(f"\n{Colors.cyan_bold('STAMINA-BIOME Compare')}")
            print(f"  Runs: {len(runs)}" if runs else f"  Tables: {len(tables)}")
            print(f"  Rank: {args.rank}")
            print(f"  Normalisation: {args.norm}")
            print()

        try:
            exit_code = run_compare(config)
            sys.exit(exit_code)
        except KeyboardInterrupt:
            print(f"\n{Colors.yellow_bold('Interrupted by user')}", file=sys.stderr)
            sys.exit(130)
        except Exception as e:
            print(f"{Colors.red_bold('ERROR')}: {e}", file=sys.stderr)
            if args.verbose:
                import traceback
                traceback.print_exc()
            sys.exit(1)

    if args.command == "run":
        # Validate mutually exclusive flags
        if args.valencia and args.no_valencia:
            print(f"{Colors.red_bold('ERROR')}: --valencia and --no-valencia are mutually exclusive.", file=sys.stderr)
            sys.exit(1)

        if args.input and args.samples_csv:
            print(f"{Colors.red_bold('ERROR')}: --input and --samples-csv are mutually exclusive. "
                  "Use --input for a single sample, or --samples-csv for a batch.", file=sys.stderr)
            sys.exit(1)

        if not args.input and not args.samples_csv:
            print(f"{Colors.red_bold('ERROR')}: Must specify --input (single sample) or "
                  "--samples-csv (batch of samples).", file=sys.stderr)
            sys.exit(1)

        # Check for Docker if containers are being used
        if not args.no_container and not args.dry_run:
            from cli.setup import check_docker
            docker_ok, docker_msg = check_docker()
            if not docker_ok:
                print(f"{Colors.red_bold('ERROR')}: {docker_msg}", file=sys.stderr)
                print(file=sys.stderr)
                print("Docker is required to run pipelines. To set up STAMINA-BIOME:", file=sys.stderr)
                print("  stamina-biome setup", file=sys.stderr)
                print(file=sys.stderr)
                print("Or run without containers (requires local tool installation):", file=sys.stderr)
                print("  stamina-biome run --no-container ...", file=sys.stderr)
                sys.exit(1)

        # --- BATCH mode: run each row of --samples-csv as its own independent sample run ---
        if args.samples_csv:
            import csv
            import datetime
            import json
            import re

            def _sanitize_sample_name(name: str) -> str:
                cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", name.strip())
                return cleaned.strip("_") or "sample"

            samples_csv_path = Path(args.samples_csv)
            if not samples_csv_path.exists():
                print(f"{Colors.red_bold('ERROR')}: --samples-csv file not found: {samples_csv_path}", file=sys.stderr)
                sys.exit(1)

            rows = []
            with open(samples_csv_path, newline="") as fh:
                reader = csv.DictReader(fh)
                if not reader.fieldnames or "sample_name" not in reader.fieldnames or "r1" not in reader.fieldnames:
                    print(f"{Colors.red_bold('ERROR')}: --samples-csv must have a header with at least "
                          "'sample_name,r1' columns (and optionally 'r2').", file=sys.stderr)
                    sys.exit(1)
                for row in reader:
                    name = (row.get("sample_name") or "").strip()
                    r1 = (row.get("r1") or "").strip()
                    r2 = (row.get("r2") or "").strip()
                    if not name or not r1:
                        continue
                    rows.append({"sample_name": name, "r1": r1, "r2": r2})

            if not rows:
                print(f"{Colors.red_bold('ERROR')}: --samples-csv has no usable rows (need sample_name and r1).", file=sys.stderr)
                sys.exit(1)

            seen_names = set()
            for row in rows:
                sanitized = _sanitize_sample_name(row["sample_name"])
                if sanitized in seen_names:
                    print(f"{Colors.red_bold('ERROR')}: Duplicate sample name after sanitization: "
                          f"'{row['sample_name']}' -> '{sanitized}'. Sample names must be unique.", file=sys.stderr)
                    sys.exit(1)
                seen_names.add(sanitized)

            batch_id = args.run_id or f"{args.pipeline}_batch_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}"
            batch_outdir = Path(args.outdir) / batch_id

            print(f"\n{Colors.cyan_bold('STAMINA-BIOME Batch Run')}")
            print(f"  Batch ID: {batch_id}")
            print(f"  Samples:  {len(rows)}")
            print(f"  Output:   {batch_outdir}\n")

            if not args.no_container and not args.dry_run:
                pass  # Docker already checked above

            repo_root = find_repo_root()
            batch_results = []
            for row in rows:
                sample_name = row["sample_name"]
                sanitized = _sanitize_sample_name(sample_name)
                input_paths = [row["r1"]] + ([row["r2"]] if row["r2"] else [])

                for p in input_paths:
                    if not Path(p).exists():
                        print(f"{Colors.red_bold('ERROR')}: Input file not found for sample "
                              f"'{sample_name}': {p}", file=sys.stderr)
                        sys.exit(1)

                print(f"{Colors.green_bold('-> Sample:')} {sample_name} ({sanitized})")

                sample_config = RunConfig(
                    pipeline=args.pipeline,
                    input_paths=input_paths,
                    outdir=str(batch_outdir),
                    run_id=sanitized,
                    threads=args.threads,
                    sample_type=args.sample_type,
                    sample_id=sample_name,
                    sample_sheet=args.sample_sheet or "",
                    valencia=args.valencia,
                    no_valencia=args.no_valencia,
                    valencia_centroids=args.valencia_centroids or "",
                    barcode_kit=args.barcode_kit,
                    ligation_kit=args.ligation_kit,
                    sequencing_kit=args.sequencing_kit or args.ligation_kit,
                    primer_f=args.primer_f,
                    primer_r=args.primer_r,
                    amplicon_type=args.amplicon_type,
                    seq_type=args.seq_type,
                    emu_min_pid=args.emu_min_pid,
                    kraken2_db=args.db,
                    emu_db=args.emu_db,
                    kraken_confidence=args.kraken_confidence,
                    kraken_min_hit_groups=args.kraken_min_hit_groups,
                    bracken_readlen=args.bracken_readlen,
                    no_bracken=args.no_bracken,
                    kraken_memory_mapping=args.kraken_memory_mapping,
                    host_depletion=args.host_depletion,
                    human_index=args.human_index,
                    minimap2_split_index=args.minimap2_split,
                    min_qscore=args.min_qscore,
                    no_qfilter=args.no_qfilter,
                    dorado_model=args.dorado_model,
                    dorado_bin=args.dorado_bin,
                    dorado_models_dir=args.dorado_models_dir,
                    postprocess=not args.no_postprocess,
                    finalize=not args.no_finalize,
                    qc_in_final=not args.no_qc_in_final,
                    use_container=not args.no_container,
                    docker_image=args.image,
                    verbose=args.verbose and not getattr(args, 'quiet', False),
                    force_overwrite=args.force,
                    debug_config=args.debug_config,
                )

                try:
                    exit_code = run_pipeline(sample_config, dry_run=args.dry_run, repo_root=repo_root)
                except RunnerError as e:
                    print(f"{Colors.red_bold('ERROR')}: sample '{sample_name}': {e}", file=sys.stderr)
                    exit_code = 1
                except KeyboardInterrupt:
                    print(f"\n{Colors.yellow_bold('Interrupted by user')}", file=sys.stderr)
                    sys.exit(130)

                batch_results.append({
                    "name": sample_name,
                    "run_id": sanitized,
                    "run_dir": str(batch_outdir / sanitized),
                    "status": "completed" if exit_code == 0 else "failed",
                })

            n_ok = sum(1 for r in batch_results if r["status"] == "completed")
            print(f"\n{Colors.cyan_bold('Batch summary')}: {n_ok}/{len(batch_results)} samples completed")
            for r in batch_results:
                marker = Colors.green_bold("OK") if r["status"] == "completed" else Colors.red_bold("FAILED")
                print(f"  [{marker}] {r['name']} -> {r['run_dir']}")

            comparison_dir = None
            if not args.dry_run and n_ok >= 2:
                ok_dirs = [r["run_dir"] for r in batch_results if r["status"] == "completed"]
                try:
                    from compare.src.compare import CompareConfig, run_compare
                    print(f"\n{Colors.cyan_bold('Running cross-sample comparison...')}")
                    compare_cfg = CompareConfig(
                        run_paths=ok_dirs,
                        outdir=str(batch_outdir),
                        name="comparison",
                        verbose=args.verbose,
                    )
                    compare_exit = run_compare(compare_cfg)
                    if compare_exit == 0:
                        comparison_dir = str(batch_outdir / "comparison")
                        print(f"{Colors.green_bold('Comparison report:')} {comparison_dir}/compare/report/index.html")
                    else:
                        print(f"{Colors.yellow_bold('WARNING')}: comparison exited with code {compare_exit} "
                              "(sample results are still valid)", file=sys.stderr)
                except Exception as e:
                    print(f"{Colors.yellow_bold('WARNING')}: cross-sample comparison failed: {e} "
                          "(sample results are still valid)", file=sys.stderr)

            if not args.dry_run:
                batch_outdir.mkdir(parents=True, exist_ok=True)
                manifest = {
                    "batch_id": batch_id,
                    "pipeline": args.pipeline,
                    "samples": batch_results,
                    "comparison_dir": comparison_dir,
                }
                with open(batch_outdir / "batch_manifest.json", "w") as fh:
                    json.dump(manifest, fh, indent=2)

            sys.exit(0 if n_ok == len(batch_results) else 1)

        # Expand glob patterns and directories in input paths
        input_paths = []
        for pattern in args.input:
            path = Path(pattern)

            # If it's a directory, find all relevant files
            if path.is_dir():
                # Find FASTQ files
                fastq_files = list(path.glob("*.fastq.gz")) + list(path.glob("*.fastq")) + \
                              list(path.glob("*.fq.gz")) + list(path.glob("*.fq"))
                # Find FAST5 files
                fast5_files = list(path.glob("*.fast5"))

                if fastq_files:
                    input_paths.extend([str(f) for f in sorted(fastq_files)])
                elif fast5_files:
                    input_paths.extend([str(f) for f in sorted(fast5_files)])
                else:
                    # Treat as directory input (for pipelines that expect directories)
                    input_paths.append(str(path))
            else:
                # Expand glob patterns
                expanded = glob.glob(pattern)
                if expanded:
                    input_paths.extend(sorted(expanded))
                else:
                    # If no glob match, use the pattern as-is (will error later if not found)
                    input_paths.append(pattern)

        if not input_paths:
            print(f"{Colors.red_bold('ERROR')}: No input files found matching: {args.input}", file=sys.stderr)
            sys.exit(1)

        # Print input summary
        if args.verbose:
            print(f"\nInput ({len(input_paths)} file{'s' if len(input_paths) != 1 else ''}):")
            for p in input_paths[:10]:
                print(f"  - {p}")
            if len(input_paths) > 10:
                print(f"  ... and {len(input_paths) - 10} more")

        config = RunConfig(
            pipeline=args.pipeline,
            input_paths=input_paths,
            outdir=args.outdir,
            run_id=args.run_id,
            threads=args.threads,
            sample_type=args.sample_type,
            sample_id=args.sample_id,
            sample_sheet=args.sample_sheet or "",
            valencia=args.valencia,
            no_valencia=args.no_valencia,
            valencia_centroids=args.valencia_centroids or "",
            barcode_kit=args.barcode_kit,
            ligation_kit=args.ligation_kit,
            sequencing_kit=args.sequencing_kit or args.ligation_kit,
            primer_f=args.primer_f,
            primer_r=args.primer_r,
            amplicon_type=args.amplicon_type,
            seq_type=args.seq_type,
            emu_min_pid=args.emu_min_pid,
            kraken2_db=args.db,
            emu_db=args.emu_db,
            kraken_confidence=args.kraken_confidence,
            kraken_min_hit_groups=args.kraken_min_hit_groups,
            bracken_readlen=args.bracken_readlen,
            no_bracken=args.no_bracken,
            kraken_memory_mapping=args.kraken_memory_mapping,
            host_depletion=args.host_depletion,
            human_index=args.human_index,
            minimap2_split_index=args.minimap2_split,
            min_qscore=args.min_qscore,
            no_qfilter=args.no_qfilter,
            dorado_model=args.dorado_model,
            dorado_bin=args.dorado_bin,
            dorado_models_dir=args.dorado_models_dir,
            postprocess=not args.no_postprocess,
            finalize=not args.no_finalize,
            qc_in_final=not args.no_qc_in_final,
            use_container=not args.no_container,
            docker_image=args.image,
            verbose=args.verbose and not getattr(args, 'quiet', False),
            force_overwrite=args.force,
            debug_config=args.debug_config,
        )

        try:
            repo_root = find_repo_root()
            exit_code = run_pipeline(config, dry_run=args.dry_run, repo_root=repo_root)
            sys.exit(exit_code)
        except RunnerError as e:
            print(f"{Colors.red_bold('ERROR')}: {e}", file=sys.stderr)
            sys.exit(1)
        except KeyboardInterrupt:
            print(f"\n{Colors.yellow_bold('Interrupted by user')}", file=sys.stderr)
            sys.exit(130)


if __name__ == "__main__":
    main()
