"""Thin adapter for invoking the existing pipeline runner."""

import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, TextIO, Tuple

from cli.discovery import (
    find_repo_root,
    get_pipeline_info,
    get_pipeline_container_images,
    get_runner_script,
    list_pipeline_ids,
    pipeline_spawns_containers,
    validate_pipeline_id,
)
from cli.progress import (
    Colors,
    ProgressTracker,
    StageRunner,
    format_input_detection,
    is_tty,
    print_stage_summary,
)


# =============================================================================
# Output Buffering Control
# =============================================================================

# Cache for stdbuf availability check
_STDBUF_AVAILABLE: Optional[bool] = None


def stdbuf_available() -> bool:
    """Check if stdbuf command is available (coreutils on Linux, may need Homebrew on macOS)."""
    global _STDBUF_AVAILABLE
    if _STDBUF_AVAILABLE is None:
        _STDBUF_AVAILABLE = shutil.which("stdbuf") is not None
    return _STDBUF_AVAILABLE


def wrap_cmd_for_unbuffered(cmd: List[str]) -> List[str]:
    """
    Wrap a command with stdbuf for line-buffered output if available.

    This ensures real-time log streaming for all pipelines regardless of their
    internal output buffering behavior.
    """
    if stdbuf_available():
        return ["stdbuf", "-oL", "-eL"] + cmd
    return cmd


# =============================================================================
# Pipeline Log Directory Watcher
# =============================================================================

class LogDirectoryWatcher:
    """
    Watches a pipeline's logs directory and streams log file contents in real-time.

    Some pipelines (like sr_amp) redirect tool output to log files rather than
    stdout/stderr. This watcher monitors those log files and streams their content
    to the console so users see progress as it happens.
    """

    def __init__(
        self,
        logs_dir: Path,
        pipeline: str,
        verbose: bool = True,
        poll_interval: float = 0.5,
    ):
        self.logs_dir = logs_dir
        self.pipeline = pipeline
        self.verbose = verbose
        self.poll_interval = poll_interval
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._file_positions: Dict[str, int] = {}
        self._seen_files: set = set()

    def start(self) -> None:
        """Start watching the logs directory in a background thread."""
        if self._thread is not None:
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._watch_loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        """Stop watching and wait for the thread to finish."""
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def _watch_loop(self) -> None:
        """Main watch loop - polls for new/updated log files."""
        while not self._stop_event.is_set():
            try:
                self._check_logs()
            except Exception:
                pass  # Silently ignore errors during watching
            self._stop_event.wait(self.poll_interval)

        # Final check to catch any remaining output
        try:
            self._check_logs()
        except Exception:
            pass

    def _check_logs(self) -> None:
        """Check for new content in log files."""
        if not self.logs_dir.exists():
            return

        for log_file in self.logs_dir.glob("*.log"):
            self._tail_file(log_file)

    def _tail_file(self, log_file: Path) -> None:
        """Read new content from a log file and display it."""
        file_key = str(log_file)

        try:
            current_size = log_file.stat().st_size
        except OSError:
            return

        # Get last read position (0 for new files)
        last_pos = self._file_positions.get(file_key, 0)

        if current_size <= last_pos:
            return  # No new content

        # Announce new log file
        if file_key not in self._seen_files:
            self._seen_files.add(file_key)
            if self.verbose:
                log_name = log_file.stem
                timestamp = datetime.now().strftime("%H:%M:%S")
                print(f"\033[2m[{timestamp}]\033[0m [{self.pipeline}] Starting: {log_name}")
                sys.stdout.flush()

        try:
            with open(log_file, "r", encoding="utf-8", errors="replace") as f:
                f.seek(last_pos)
                new_content = f.read()
                self._file_positions[file_key] = f.tell()

            if new_content and self.verbose:
                log_name = log_file.stem
                for line in new_content.splitlines():
                    if line.strip():
                        timestamp = datetime.now().strftime("%H:%M:%S")
                        # Format: [HH:MM:SS] [pipeline] [log_name] message
                        print(f"\033[2m[{timestamp}]\033[0m [{self.pipeline}] [{log_name}] {line}")
                sys.stdout.flush()
        except Exception:
            pass


# =============================================================================
# Log Normalization (to match lr_meta reference format)
# =============================================================================

# ANSI color codes (matching lr_meta.sh)
ANSI_BOLD = "\033[1m"
ANSI_RESET = "\033[0m"
ANSI_CYAN = "\033[36m"
ANSI_YELLOW = "\033[33m"
ANSI_GREEN = "\033[32m"
ANSI_RED = "\033[31m"
ANSI_PURPLE = "\033[35m"

# Pattern to detect step-prefixed log lines: [step_name] message
# Examples: [postprocess] Starting..., [fastp] q_cutoff=10, [sr_meta] Done
STEP_PREFIX_PATTERN = re.compile(r'^\[([a-zA-Z0-9_]+)\]\s*(.*)$')

# Pattern to detect lr_meta-style ISO timestamp: [YYYY-MM-DD HH:MM:SS]
ISO_TIMESTAMP_PATTERN = re.compile(r'^\[\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\]')

# Keywords that indicate log severity
WARN_KEYWORDS = ('warn', 'warning', 'skip', 'skipping', 'no ')
ERROR_KEYWORDS = ('error', 'fail', 'failed', 'missing', 'not found')
SUCCESS_KEYWORDS = ('succeeded', 'completed', 'done', 'ok', 'success')

# Critical error patterns that indicate pipeline failure even when steps show "succeeded"
CRITICAL_ERROR_PATTERNS = [
    (re.compile(r'ERROR:\s*failed to open file.*No such file or directory', re.IGNORECASE),
     "Input file not found during processing"),
    (re.compile(r'ERROR:\s*failed to map the query file', re.IGNORECASE),
     "Alignment failed - no reads mapped"),
    (re.compile(r'processed 0 reads', re.IGNORECASE),
     "Zero reads processed in alignment/filtering"),
    (re.compile(r'0 sequences \(0\.00 Mbp\) processed', re.IGNORECASE),
     "Zero sequences processed by Kraken2"),
]

# Warning patterns for missing optional tools (with suggested fixes)
MISSING_TOOL_PATTERNS = [
    (re.compile(r'VALENCIA centroid CSV missing at ([^;]+)', re.IGNORECASE),
     "VALENCIA CST assignment disabled",
     "Configure valencia.centroids_csv in config or download CST_centroids_012920.csv"),
    (re.compile(r'Krona tools not available', re.IGNORECASE),
     "Krona visualization disabled",
     "Install KronaTools or include ktImportTaxonomy in container"),
    (re.compile(r'Skipping Bracken for', re.IGNORECASE),
     "Bracken abundance estimation skipped",
     "Ensure Bracken database is built for the Kraken2 DB"),
    (re.compile(r'Skipping Python summary script \(not set or missing\)', re.IGNORECASE),
     "Python summary script not available",
     "Set tools.summary_script path or include in container"),
    (re.compile(r'Skipping R plotting script \(not set or missing\)', re.IGNORECASE),
     "R plotting script not available",
     "Set tools.rplot_script path or use host-side postprocessing"),
]


def scan_log_for_issues(log_path: Path) -> Dict[str, Any]:
    """
    Scan a pipeline log file for critical errors and missing tool warnings.

    Returns:
        Dict with:
          - critical_errors: List of (line_number, message, explanation)
          - missing_tools: List of (tool_name, suggestion)
          - sequences_processed: Total sequences seen in Kraken2 output (0 = problem)
          - zero_read_steps: Steps that processed 0 reads
    """
    result = {
        "critical_errors": [],
        "missing_tools": [],
        "sequences_processed": 0,
        "zero_read_steps": [],
    }

    if not log_path.exists():
        return result

    try:
        content = log_path.read_text(errors='replace')
        lines = content.splitlines()

        # Track sequences processed by Kraken2
        kraken_seq_pattern = re.compile(r'(\d+) sequences \([\d.]+ Mbp\) processed')

        for i, line in enumerate(lines, 1):
            # Check for critical errors
            for pattern, explanation in CRITICAL_ERROR_PATTERNS:
                if pattern.search(line):
                    result["critical_errors"].append((i, line.strip(), explanation))

            # Check for missing tools
            for pattern, tool_name, suggestion in MISSING_TOOL_PATTERNS:
                match = pattern.search(line)
                if match:
                    # Avoid duplicates
                    if not any(t[0] == tool_name for t in result["missing_tools"]):
                        result["missing_tools"].append((tool_name, suggestion))

            # Track Kraken2 sequences processed
            seq_match = kraken_seq_pattern.search(line)
            if seq_match:
                result["sequences_processed"] += int(seq_match.group(1))

            # Track steps with 0 reads
            if 'processed 0 reads' in line.lower():
                # Extract barcode/sample name if present
                barcode_match = re.search(r'barcode\d+', line, re.IGNORECASE)
                step_name = barcode_match.group(0) if barcode_match else f"line {i}"
                result["zero_read_steps"].append(step_name)

    except Exception:
        pass

    return result


def check_kreport_has_data(kreport_path: Path) -> Tuple[bool, int]:
    """
    Check if a Kraken2 kreport file has actual classified sequences.

    Returns:
        (has_data, total_sequences) tuple
    """
    if not kreport_path.exists():
        return False, 0

    try:
        content = kreport_path.read_text()
        if not content.strip():
            return False, 0

        # Kreport format: pct, count_clade, count_direct, rank, taxid, name
        # First line with rank='U' is unclassified, 'R' is root (total)
        total_seqs = 0
        for line in content.splitlines():
            parts = line.split('\t')
            if len(parts) >= 3:
                try:
                    # count_clade is column 2 (0-indexed: 1)
                    count = int(parts[1].strip())
                    if len(parts) >= 4 and parts[3].strip() in ('U', 'R'):
                        total_seqs = max(total_seqs, count)
                except (ValueError, IndexError):
                    continue

        return total_seqs > 0, total_seqs
    except Exception:
        return False, 0


def check_fastq_gz_not_empty(fastq_path: Path, min_size: int = 50) -> bool:
    """
    Check if a gzipped FASTQ file is not effectively empty.

    An empty gzip file is typically ~20 bytes (just header/footer).
    A FASTQ with at least 1 read will be larger.

    Args:
        fastq_path: Path to .fastq.gz file
        min_size: Minimum size in bytes to consider non-empty (default 50)

    Returns:
        True if file exists and is larger than min_size bytes
    """
    if not fastq_path.exists():
        return False
    return fastq_path.stat().st_size > min_size


def normalize_log_line(line: str, pipeline: str) -> str:
    """
    Normalize a log line to match lr_meta reference format.

    lr_meta format: [YYYY-MM-DD HH:MM:SS] [ANSI_COLOR]message[ANSI_RESET]
    sr_meta format: [step_name] message

    This function converts sr_meta-style lines to lr_meta-style, while
    preserving lines that already follow lr_meta format.
    """
    line = line.rstrip('\n\r')
    if not line:
        return line

    # If line already has ISO timestamp (lr_meta style), return as-is
    if ISO_TIMESTAMP_PATTERN.match(line):
        return line

    # Check for step-prefix pattern: [step_name] message
    match = STEP_PREFIX_PATTERN.match(line)
    if match:
        step_name = match.group(1)
        message = match.group(2)

        # Determine color based on message content and step
        color = ANSI_CYAN  # Default info color
        message_lower = message.lower()

        if any(kw in message_lower for kw in ERROR_KEYWORDS):
            color = ANSI_RED
        elif any(kw in message_lower for kw in WARN_KEYWORDS):
            color = ANSI_YELLOW
        elif any(kw in message_lower for kw in SUCCESS_KEYWORDS):
            color = ANSI_GREEN

        # Format with ISO timestamp and color (matching lr_meta log() function)
        iso_ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        return f"[{iso_ts}] {color}{ANSI_BOLD}{message}{ANSI_RESET}"

    # For lines without step prefix, check if they're tool output
    # (e.g., MultiQC, FastQC progress) - pass through as-is
    return line



# =============================================================================
# Docker Image Management
# =============================================================================

# Default image names for each pipeline type
DEFAULT_IMAGES = {
    "sr": "stamina-biome-sr:latest",
    "lr": "stamina-biome-lr:latest",
}

# Fallback images to try if default doesn't exist (in order of preference)
FALLBACK_IMAGES = {
    "sr": [
        "stamina-biome-tools-sr:dev",
        "stamina-biome-tools-sr:latest",
        "stamina-biome-sr:dev",
    ],
    "lr": [
        "stamina-biome-tools-lr:dev",
        "stamina-biome-tools-lr:latest",
        "stamina-biome-lr:dev",
    ],
}


def docker_image_exists_locally(image_tag: str) -> bool:
    """
    Check if a Docker image exists locally (without attempting to pull).

    Args:
        image_tag: Full image tag (e.g., "stamina-biome-sr:latest")

    Returns:
        True if image exists locally, False otherwise
    """
    try:
        # First try docker image inspect (most reliable when it works)
        result = subprocess.run(
            ["docker", "image", "inspect", image_tag],
            capture_output=True,
            timeout=10,
        )
        if result.returncode == 0:
            return True

        # Fallback: check via docker images list (handles Docker inconsistencies
        # where inspect fails but the image is actually listed)
        result = subprocess.run(
            ["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            images = result.stdout.strip().split("\n")
            if image_tag in images:
                return True

        return False
    except Exception:
        return False


def list_local_stamina_biome_images() -> List[str]:
    """
    List all locally available stamina-biome-related Docker images.

    Returns:
        List of image tags (e.g., ["stamina-biome-tools-sr:dev", "stamina-biome-lr:latest"])
    """
    try:
        result = subprocess.run(
            ["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return []

        images = []
        for line in result.stdout.strip().split("\n"):
            if line and "stamina-biome" in line.lower():
                images.append(line)
        return sorted(images)
    except Exception:
        return []


def find_matching_local_images(pipeline_type: str) -> List[str]:
    """
    Find local images that match a pipeline type (sr or lr).

    Args:
        pipeline_type: "sr" for short-read, "lr" for long-read

    Returns:
        List of matching image tags, sorted by preference
    """
    all_images = list_local_stamina_biome_images()

    # Filter by type
    matching = []
    for img in all_images:
        img_lower = img.lower()
        if pipeline_type == "sr":
            if "-sr:" in img_lower or "-sr-" in img_lower:
                matching.append(img)
        elif pipeline_type == "lr":
            if "-lr:" in img_lower or "-lr-" in img_lower:
                matching.append(img)

    return matching


def select_docker_image(
    pipeline: str,
    override_image: str = "",
    verbose: bool = False,
) -> Tuple[str, str]:
    """
    Select the best available Docker image for a pipeline.

    Args:
        pipeline: Pipeline ID (e.g., "sr_meta", "lr_amp")
        override_image: User-specified image override (--image flag)
        verbose: Print detailed selection info

    Returns:
        Tuple of (selected_image, selection_reason)
        selection_reason explains why this image was chosen

    Raises:
        RunnerError: If no suitable image is available
    """
    # Determine pipeline type
    pipeline_type = "sr" if pipeline.startswith("sr_") else "lr"
    default_image = DEFAULT_IMAGES[pipeline_type]

    # Case 1: User explicitly specified an image
    if override_image:
        if docker_image_exists_locally(override_image):
            return override_image, f"user override (--image {override_image})"
        else:
            # User specified an image that doesn't exist - error
            local_alternatives = find_matching_local_images(pipeline_type)
            alt_list = "\n    ".join(local_alternatives) if local_alternatives else "(none found)"
            raise RunnerError(
                f"Specified image '{override_image}' not found locally.\n"
                f"  Available {pipeline_type.upper()} images:\n    {alt_list}\n"
                f"  Either pull/build the image or use an available alternative."
            )

    # Case 2: Check if default image exists
    if docker_image_exists_locally(default_image):
        return default_image, "default image"

    # Case 3: Try fallback images in order
    for fallback in FALLBACK_IMAGES.get(pipeline_type, []):
        if docker_image_exists_locally(fallback):
            if verbose:
                print(f"{Colors.yellow_bold('Note')}: Image '{default_image}' not found locally.")
                print(f"       Using fallback: {Colors.cyan_bold(fallback)}")
            return fallback, f"fallback (default '{default_image}' not found)"

    # Case 4: No suitable image found - provide helpful error
    local_alternatives = find_matching_local_images(pipeline_type)
    all_stamina_biome_images = list_local_stamina_biome_images()

    error_msg = f"No suitable Docker image found for {pipeline}.\n\n"
    error_msg += f"  Expected: {default_image}\n"
    error_msg += f"  Fallbacks tried: {', '.join(FALLBACK_IMAGES.get(pipeline_type, []))}\n\n"

    if local_alternatives:
        error_msg += f"  Available {pipeline_type.upper()} images locally:\n"
        for img in local_alternatives:
            error_msg += f"    - {img}\n"
        error_msg += f"\n  Use --image <tag> to specify one of these.\n"
    elif all_stamina_biome_images:
        error_msg += f"  No {pipeline_type.upper()} images found. Available stamina-biome images:\n"
        for img in all_stamina_biome_images:
            error_msg += f"    - {img}\n"
        error_msg += f"\n  Build the {pipeline_type.upper()} image with:\n"
        error_msg += f"    docker build -f main/pipelines/container/dockerfile.{pipeline_type} -t {default_image} main/pipelines/container/\n"
    else:
        error_msg += f"  No stamina-biome Docker images found locally.\n"
        error_msg += f"\n  Build the {pipeline_type.upper()} image with:\n"
        error_msg += f"    docker build -f main/pipelines/container/dockerfile.{pipeline_type} -t {default_image} main/pipelines/container/\n"

    error_msg += f"\n  Or run without container: --no-container"

    raise RunnerError(error_msg)


def stream_output_to_file_and_console(
    proc: subprocess.Popen,
    log_file: TextIO,
    verbose: bool = True,
    prefix: str = "",
    pipeline: str = "",
    normalize_logs: bool = True,
) -> int:
    """
    Stream subprocess output to both a log file and console in real-time.

    Handles both stdout and stderr, preserving ANSI colors.
    When normalize_logs=True, converts non-lr_meta log formats to match
    the lr_meta reference format (ISO timestamps, colored output).
    Returns the process exit code.
    """
    def reader_thread(stream: TextIO, log_file: TextIO, is_stderr: bool = False):
        """Read from stream and write to both log file and console."""
        try:
            for line in iter(stream.readline, ''):
                if not line:
                    break

                raw_line = line.rstrip('\n\r')

                # Normalize log line if enabled (convert sr_meta/sr_amp style to lr_meta style)
                if normalize_logs and pipeline:
                    normalized = normalize_log_line(raw_line, pipeline)
                else:
                    normalized = raw_line

                # Add timestamp for log file (raw, unnormalized for log file)
                timestamp = datetime.now().strftime("%H:%M:%S")
                log_line = f"[{timestamp}] {line}"

                # Write to log file
                log_file.write(log_line)
                log_file.flush()

                # Write to console with normalized output
                if verbose:
                    output = sys.stderr if is_stderr else sys.stdout
                    # Use normalized line for console output
                    if is_tty():
                        formatted = f"{Colors.dim(f'[{timestamp}]')} {prefix}{normalized}\n"
                    else:
                        formatted = f"[{timestamp}] {prefix}{normalized}\n"
                    output.write(formatted)
                    output.flush()
        except Exception:
            pass
        finally:
            stream.close()

    threads = []

    if proc.stdout:
        stdout_thread = threading.Thread(
            target=reader_thread,
            args=(proc.stdout, log_file, False),
            daemon=True
        )
        stdout_thread.start()
        threads.append(stdout_thread)

    if proc.stderr:
        stderr_thread = threading.Thread(
            target=reader_thread,
            args=(proc.stderr, log_file, True),
            daemon=True
        )
        stderr_thread.start()
        threads.append(stderr_thread)

    # Wait for process to complete
    proc.wait()

    # Wait for threads to finish reading
    for t in threads:
        t.join(timeout=5.0)

    return proc.returncode


def run_with_streaming(
    cmd: List[str],
    log_path: Path,
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[str] = None,
    verbose: bool = True,
    prefix: str = "",
    pipeline: str = "",
    normalize_logs: bool = True,
) -> int:
    """
    Run a command with live log streaming to both file and console.

    When normalize_logs=True, converts non-lr_meta log formats to match
    the lr_meta reference format (ISO timestamps, colored output).
    Returns the exit code.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)

    with open(log_path, "w", encoding="utf-8") as log_file:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,  # Merge stderr into stdout for ordering
            env=env,
            cwd=cwd,
            text=True,
            bufsize=1,  # Line buffered
        )

        return stream_output_to_file_and_console(
            proc,
            log_file,
            verbose=verbose,
            prefix=prefix,
            pipeline=pipeline,
            normalize_logs=normalize_logs,
        )


def run_postprocess(
    pipeline: str,
    run_dir: Path,
    config_path: Path,
    repo_root: Path,
    verbose: bool = True,
) -> int:
    """
    Run R postprocessing after pipeline completion.

    Returns exit code (0 for success).
    """
    module_dir = run_dir / pipeline
    outputs_json = module_dir / "outputs.json"

    if not outputs_json.exists():
        if verbose:
            print(f"[stamina-biome] Postprocess: No outputs.json found at {outputs_json}")
        return 0  # Not an error, just nothing to postprocess

    # Use the unified R postprocess runner
    r_postprocess_script = repo_root / "main" / "pipelines" / "postprocess" / "r" / "run_r_postprocess.sh"

    if not r_postprocess_script.exists():
        if verbose:
            print(f"[stamina-biome] Postprocess: R postprocess script not found at {r_postprocess_script}")
        return 0

    postprocess_log = module_dir / "logs" / "r_postprocess_runner.log"
    postprocess_log.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        str(r_postprocess_script),
        "--config", str(config_path),
        "--outputs", str(outputs_json),
        "--module", pipeline,
    ]

    if verbose:
        print(f"[stamina-biome] Running R postprocess...")
        print(f"[stamina-biome]   Script: {r_postprocess_script}")
        print(f"[stamina-biome]   Log: {postprocess_log}")

    env = os.environ.copy()

    return run_with_streaming(
        cmd,
        postprocess_log,
        env=env,
        cwd=str(repo_root / "main"),
        verbose=verbose,
        prefix=f"[{pipeline}] ",
        pipeline=pipeline,
        normalize_logs=True,
    )


@dataclass
class RunConfig:
    """Configuration for a pipeline run."""

    pipeline: str
    input_paths: List[str]  # List of input file/directory paths
    outdir: str = "./outputs"
    run_id: str = ""
    threads: int = 4
    postprocess: bool = True
    finalize: bool = True
    use_container: bool = True
    verbose: bool = True  # Enable real-time logging by default
    force_overwrite: bool = True
    valencia: bool = False  # Enable Valencia CST analysis
    no_valencia: bool = False  # Disable Valencia even for vaginal samples
    valencia_centroids: str = ""  # Path to Valencia CST centroids CSV
    debug_config: bool = False  # Print full config JSON

    # Additional pipeline-specific settings
    sample_id: str = "sample"
    sample_type: str = "other"
    sample_sheet: str = ""  # Path to barcode->sample_name CSV/TSV (demux naming, lr_amp/lr_meta/sr_amp/sr_meta)
    technology: str = ""  # auto-detected based on pipeline
    input_style: str = ""  # auto-detected based on input

    # Dorado demux settings (for lr_amp/lr_meta)
    barcode_kit: str = ""  # e.g., "EXP-PBC001", "SQK-NBD114-24"
    ligation_kit: str = "SQK-LSK114"
    sequencing_kit: str = ""  # Sequencing kit for Dorado trim (defaults to ligation_kit if not specified)

    # Primer sequences for cutadapt (sr_amp only)
    primer_f: str = ""  # Forward primer (e.g., CCTACGGGNGGCWGCAG for V3-V4)
    primer_r: str = ""  # Reverse primer (e.g., GACTACHVGGGTATCTAATCC for V3-V4)

    # Amplicon type for lr_amp (determines classifier: Emu for full-length, Kraken2 for partial)
    amplicon_type: str = "full-length"  # "full-length" or "partial"

    # Sequencing technology preset for lr_amp (controls Emu/minimap2 alignment preset)
    # Options: map-ont (default), map-pb, map-hifi, lr:hq
    seq_type: str = "map-ont"

    # Emu minimum percent identity (0-100), lr_amp only. None = pipeline script
    # default (95). Recommended: 95 -- see --min-pid help text.
    emu_min_pid: Optional[float] = None

    # Database paths
    kraken2_db: str = ""  # Path to Kraken2 database (for sr_meta, lr_meta, lr_amp)
    emu_db: str = ""  # Path to Emu database (for lr_amp)

    # Kraken2 classification params (lr_meta; also stored for sr_meta future use)
    # Applied to both vaginal and non-vaginal classifications for this run.
    # None = use pipeline script defaults (vaginal: conf=0.02/mhg=2, nonvaginal: conf=0.02/mhg=2)
    kraken_confidence: Optional[float] = None
    kraken_min_hit_groups: Optional[int] = None

    # Bracken abundance re-estimation read length, in bp (sr_meta, lr_meta).
    # Must match a database{N}mers.kmer_distrib file present in the Kraken2 DB, or
    # Bracken is silently skipped for that run. None = use pipeline script defaults
    # (lr_meta: 1500bp; sr_meta: 150bp).
    bracken_readlen: Optional[int] = None
    no_bracken: bool = False  # Disable Bracken re-estimation for this run

    # Kraken2 --memory-mapping: read the hash table from disk instead of loading it
    # fully into RAM. Slower (disk-bound) but avoids OOM on low-RAM hosts when the DB
    # (hash.k2d) is large relative to available memory.
    kraken_memory_mapping: bool = False

    # Docker image override
    docker_image: str = ""  # Override default image selection (e.g., "stamina-biome-tools-sr:dev")

    # Host depletion (remove human reads before classification)
    host_depletion: bool = False  # Enable host read removal (sr_meta, lr_meta)
    human_index: str = ""  # Path to human genome minimap2 index (.mmi file)
    minimap2_split_index: bool = False  # Use split-prefix for low-RAM machines

    # Quality filtering (NanoFilt for long-read, fastp for short-read)
    min_qscore: int = 10  # Minimum quality score for filtering (default: 10)
    no_qfilter: bool = False  # Disable quality filtering

    # Dorado basecalling (for FAST5/POD5 input)
    dorado_model: str = ""  # e.g., "dna_r10.4.1_e8.2_400bps_hac@v5.2.0"
    dorado_bin: str = ""  # Absolute path to Dorado binary
    dorado_models_dir: str = ""  # Absolute path to directory containing Dorado models

    # QC reports in final directory
    qc_in_final: bool = True  # Copy FastQC/MultiQC reports to final/qc/

    extra_params: Dict[str, Any] = field(default_factory=dict)

    @property
    def input_path(self) -> str:
        """Return first input path for backward compatibility."""
        return self.input_paths[0] if self.input_paths else ""

    @property
    def is_multi_file(self) -> bool:
        """Check if multiple input files were provided."""
        if len(self.input_paths) > 1:
            return True
        if len(self.input_paths) == 1:
            p = Path(self.input_paths[0])
            return p.is_dir()
        return False


class RunnerError(Exception):
    """Error during pipeline execution."""

    pass


def detect_input_style(input_paths: List[str], pipeline: str) -> str:
    """Auto-detect input style based on paths and pipeline type."""
    if not input_paths:
        return "FASTQ_SINGLE"

    # Exactly 2 files - likely paired-end for short-read
    if len(input_paths) == 2 and pipeline.startswith("sr_"):
        names = [Path(p).name for p in input_paths]
        # Check for R1/R2 or _1/_2 patterns
        has_r1 = any("_R1" in n or "_1.fastq" in n or "_1.fq" in n for n in names)
        has_r2 = any("_R2" in n or "_2.fastq" in n or "_2.fq" in n for n in names)
        if has_r1 and has_r2:
            return "FASTQ_PAIRED"
        # Even without patterns, 2 files for sr_ is likely paired
        return "FASTQ_PAIRED"

    # Multiple files from glob expansion
    if len(input_paths) > 1:
        # Check file types
        extensions = {Path(p).suffix.lower() for p in input_paths}
        names = [Path(p).name for p in input_paths]

        if ".fast5" in extensions or any(n.endswith(".fast5") for n in names):
            return "FAST5_DIR"

        if ".bam" in extensions or any(n.endswith(".bam") for n in names):
            return "BAM"

        # Multiple FASTQ files
        if pipeline.startswith("lr_"):
            return "FASTQ_SINGLE"  # Long-read: treat as single-end batch

        # Check for paired patterns
        has_r1 = any("_R1" in n or "_1.fastq" in n or "_1.fq" in n for n in names)
        has_r2 = any("_R2" in n or "_2.fastq" in n or "_2.fq" in n for n in names)
        if has_r1 and has_r2:
            return "FASTQ_PAIRED"
        return "FASTQ_SINGLE"

    # Single path
    path = Path(input_paths[0])

    if path.is_dir():
        # Check directory contents
        files = list(path.iterdir())
        extensions = {f.suffix.lower() for f in files if f.is_file()}

        if ".fast5" in extensions or any(f.name.endswith(".fast5") for f in files):
            return "FAST5_DIR"

        if ".bam" in extensions or any(f.name.endswith(".bam") for f in files):
            return "BAM"

        # Check for FASTQ files
        fastq_exts = {".fastq", ".fq", ".gz"}
        if fastq_exts & extensions:
            # Long-read pipelines use single-end
            if pipeline.startswith("lr_"):
                return "FASTQ_SINGLE"
            # Check for paired patterns in filenames
            names = [f.name for f in files]
            has_r1 = any("_R1" in n or "_1.fastq" in n or "_1.fq" in n for n in names)
            has_r2 = any("_R2" in n or "_2.fastq" in n or "_2.fq" in n for n in names)
            if has_r1 and has_r2:
                return "FASTQ_PAIRED"
            return "FASTQ_SINGLE"

    elif path.is_file():
        name = path.name.lower()

        # FAST5 files (single file)
        if name.endswith(".fast5"):
            return "FAST5_DIR"

        # FAST5 archives
        if name.endswith((".fast5.tar.gz", ".fast5.zip")):
            return "FAST5_ARCHIVE"

        # BAM files (basecalled reads)
        if name.endswith(".bam"):
            return "BAM"

        # Single file provided = FASTQ_SINGLE
        # Do NOT auto-detect paired when user explicitly provides only 1 file
        # User must provide both R1 and R2 explicitly for paired-end
        return "FASTQ_SINGLE"

    return "FASTQ_SINGLE"  # Default fallback


def find_paired_reads(files: List[str]) -> Tuple[List[Tuple[str, str]], List[str]]:
    """
    Find paired-end reads from a list of files.

    Returns:
        Tuple of (paired_files, unmatched_files)
        paired_files: List of (R1, R2) tuples
        unmatched_files: List of files that couldn't be paired
    """
    # Common patterns for R1/R2 naming
    r1_patterns = [
        (r'_R1_001\.', '_R2_001.'),
        (r'_R1\.', '_R2.'),
        (r'_1\.fastq', '_2.fastq'),
        (r'_1\.fq', '_2.fq'),
        (r'\.R1\.', '.R2.'),
        (r'\.1\.fastq', '.2.fastq'),
    ]

    paired = []
    unmatched = []
    used = set()

    file_map = {Path(f).name: f for f in files}

    for f in files:
        if f in used:
            continue

        name = Path(f).name
        found_pair = False

        for r1_pat, r2_rep in r1_patterns:
            if re.search(r1_pat, name):
                # This looks like an R1 file
                r2_name = re.sub(r1_pat, r2_rep, name)
                if r2_name in file_map:
                    r2_file = file_map[r2_name]
                    if r2_file not in used:
                        paired.append((f, r2_file))
                        used.add(f)
                        used.add(r2_file)
                        found_pair = True
                        break

        if not found_pair and f not in used:
            # Check if this is an R2 file (will be matched by its R1)
            is_r2 = False
            for r1_pat, r2_rep in r1_patterns:
                r2_pat = r2_rep.replace('.', r'\.')
                if re.search(r2_pat, name):
                    is_r2 = True
                    break

            if not is_r2:
                unmatched.append(f)
                used.add(f)

    return paired, unmatched


def detect_input_style_detailed(
    input_paths: List[str],
    pipeline: str,
) -> Tuple[str, Dict[str, Any]]:
    """
    Detailed input style detection with metadata.

    Returns:
        Tuple of (input_style, details_dict)
        details_dict contains: file_count, pair_count, unmatched, r1_files, r2_files, etc.
    """
    details: Dict[str, Any] = {
        "file_count": 0,
        "pair_count": 0,
        "unmatched": [],
        "r1_files": [],
        "r2_files": [],
        "all_files": [],
        "is_directory": False,
        "fast5_count": 0,
    }

    if not input_paths:
        return "FASTQ_SINGLE", details

    # Collect all files
    all_files = []
    fast5_files = []
    fastq_files = []

    for p in input_paths:
        path = Path(p)
        if path.is_dir():
            details["is_directory"] = True
            # Scan directory for files
            for f in path.iterdir():
                if f.is_file():
                    if f.suffix.lower() == ".fast5":
                        fast5_files.append(str(f))
                    elif f.suffix.lower() in (".fastq", ".fq", ".gz"):
                        fastq_files.append(str(f))
                    elif f.name.endswith(".fastq.gz") or f.name.endswith(".fq.gz"):
                        fastq_files.append(str(f))
        elif path.is_file():
            if path.suffix.lower() == ".fast5":
                fast5_files.append(str(path))
            else:
                fastq_files.append(str(path))

    all_files = fastq_files + fast5_files
    details["all_files"] = all_files
    details["file_count"] = len(all_files)
    details["fast5_count"] = len(fast5_files)

    # FAST5 directory
    if fast5_files and not fastq_files:
        return "FAST5_DIR", details

    # For long-read pipelines, treat as single-end
    if pipeline.startswith("lr_"):
        details["file_count"] = len(fastq_files)
        return "FASTQ_SINGLE", details

    # For short-read pipelines, try to detect paired-end
    if fastq_files:
        # Only try pairing if we have more than 1 file
        if len(fastq_files) >= 2:
            paired, unmatched = find_paired_reads(fastq_files)
            details["pair_count"] = len(paired)
            details["unmatched"] = unmatched

            if paired:
                details["r1_files"] = [p[0] for p in paired]
                details["r2_files"] = [p[1] for p in paired]
                return "FASTQ_PAIRED", details

        # Single file or no pairs found - treat as single-end
        # Don't mark single files as "unmatched" since they're intentionally single-end
        details["file_count"] = len(fastq_files)
        details["unmatched"] = []  # Clear unmatched for single-file input
        return "FASTQ_SINGLE", details

    return "FASTQ_SINGLE", details


def get_common_parent(paths: List[str]) -> Path:
    """Find the common parent directory for a list of paths."""
    if not paths:
        return Path.cwd()
    if len(paths) == 1:
        p = Path(paths[0])
        return p if p.is_dir() else p.parent

    # Find common parent
    resolved = [Path(p).resolve() for p in paths]
    parts_list = [p.parts for p in resolved]
    common_parts = []

    for parts in zip(*parts_list):
        if len(set(parts)) == 1:
            common_parts.append(parts[0])
        else:
            break

    if common_parts:
        return Path(*common_parts)
    return Path.cwd()


def detect_technology(pipeline: str) -> str:
    """Detect technology based on pipeline type."""
    if pipeline.startswith("lr_"):
        return "ONT"  # Default to ONT for long-read
    return "ILLUMINA"  # Default to Illumina for short-read


def _apply_kraken_params(cfg: Dict[str, Any], config: "RunConfig") -> None:
    """Inject kraken_confidence / kraken_min_hit_groups into cfg["tools"]["kraken2"] if set."""
    if config.kraken_confidence is None and config.kraken_min_hit_groups is None:
        return
    kp: Dict[str, Any] = {}
    if config.kraken_confidence is not None:
        kp["confidence"] = config.kraken_confidence
    if config.kraken_min_hit_groups is not None:
        kp["minimum_hit_groups"] = config.kraken_min_hit_groups
    cfg.setdefault("tools", {}).setdefault("kraken2", {})
    cfg["tools"]["kraken2"]["vaginal"] = kp.copy()
    cfg["tools"]["kraken2"]["nonvaginal"] = kp.copy()


def _apply_emu_params(cfg: Dict[str, Any], config: "RunConfig") -> None:
    """Inject emu_min_pid into cfg["tools"]["emu"] if set (lr_amp only)."""
    if config.emu_min_pid is None or config.pipeline != "lr_amp":
        return
    cfg.setdefault("tools", {}).setdefault("emu", {})["min_pid"] = config.emu_min_pid


def _apply_bracken_params(cfg: Dict[str, Any], config: "RunConfig") -> None:
    """Inject bracken_readlen / no_bracken into cfg["tools"]["bracken"] if set."""
    if config.bracken_readlen is None and not config.no_bracken:
        return
    bp: Dict[str, Any] = {}
    if config.no_bracken:
        bp["enabled"] = 0
    if config.bracken_readlen is not None:
        bp["readlen"] = config.bracken_readlen
    cfg.setdefault("tools", {}).setdefault("bracken", {})
    cfg["tools"]["bracken"]["vaginal"] = bp.copy()
    cfg["tools"]["bracken"]["nonvaginal"] = bp.copy()


def _apply_kraken_memory_mapping(cfg: Dict[str, Any], config: "RunConfig") -> None:
    """Inject kraken_memory_mapping into cfg["params"]["kraken2"] if set."""
    if not config.kraken_memory_mapping:
        return
    cfg.setdefault("params", {}).setdefault("kraken2", {})["memory_mapping"] = 1


def build_config(config: RunConfig, repo_root: Optional[Path] = None) -> Dict[str, Any]:
    """Build a config dict from RunConfig."""
    if repo_root is None:
        repo_root = find_repo_root()

    outdir = Path(config.outdir).resolve()

    # Resolve all input paths
    resolved_inputs = [Path(p).resolve() for p in config.input_paths]

    # Auto-detect settings
    input_style = config.input_style or detect_input_style(config.input_paths, config.pipeline)
    technology = config.technology or detect_technology(config.pipeline)

    # Determine the input path/directory to use
    if len(resolved_inputs) == 1:
        primary_input = resolved_inputs[0]
        input_dir = primary_input if primary_input.is_dir() else primary_input.parent
    else:
        # Multiple files - use common parent directory
        input_dir = get_common_parent(config.input_paths)
        primary_input = input_dir

    # Generate run_id if not provided
    run_id = config.run_id
    if not run_id:
        import datetime

        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        run_id = f"{config.pipeline}_{timestamp}"

    # Compute run_dir = work_dir / run_id
    run_dir = outdir / run_id

    # Build base config
    cfg: Dict[str, Any] = {
        "pipeline_id": config.pipeline,
        "technology": technology,
        "sample_type": config.sample_type,
        "run": {
            "work_dir": str(outdir),
            "run_id": run_id,
            "run_dir": str(run_dir),  # REQUIRED by module scripts
            "force_overwrite": 1 if config.force_overwrite else 0,
        },
        "input": {
            "style": input_style,
            "sample_type": config.sample_type,  # Also set here for module compatibility
        },
        "resources": {
            "threads": config.threads,
        },
        "params": {
            "common": {
                "min_qscore": config.min_qscore,
                "remove_host": 1 if config.host_depletion else 0,
            }
        },
        "qfilter": {
            "enabled": 0 if config.no_qfilter else 1,
            "min_q": config.min_qscore,
        },
        "output": {
            "selected": ["default"],
            "finalize": 1 if config.finalize else 0,
            "qc_in_final": 1 if config.qc_in_final else 0,
        },
    }

    # Set input paths based on style and number of inputs
    # Handle FAST5 inputs first (before generic multi-file handling)
    if input_style == "FAST5_DIR":
        # FAST5 directory - use the parent directory of the FAST5 files
        if resolved_inputs:
            fast5_dir = resolved_inputs[0].parent
        else:
            fast5_dir = primary_input if primary_input.is_dir() else primary_input.parent
        cfg["input"]["fast5_dir"] = str(fast5_dir)
        cfg["input"]["files"] = [str(p) for p in resolved_inputs]
    elif input_style == "FAST5_ARCHIVE":
        cfg["input"]["fast5_archive"] = str(primary_input)
    elif input_style == "BAM":
        # BAM input - basecalled reads, skip basecalling
        cfg["input"]["bam"] = str(primary_input)
    elif input_style == "FASTQ_PAIRED" and len(resolved_inputs) == 2:
        # Explicitly provided paired-end files (2 files)
        # Sort to get R1 before R2
        sorted_inputs = sorted(resolved_inputs, key=lambda p: p.name)
        # Identify R1 and R2 by name patterns
        r1_file = None
        r2_file = None
        for p in resolved_inputs:
            name = p.name
            if "_R1" in name or "_1.fastq" in name or "_1.fq" in name:
                r1_file = p
            elif "_R2" in name or "_2.fastq" in name or "_2.fq" in name:
                r2_file = p
        # Fallback: first file is R1, second is R2
        if r1_file is None:
            r1_file = sorted_inputs[0]
        if r2_file is None:
            r2_file = sorted_inputs[1]
        cfg["input"]["fastq_r1"] = str(r1_file)
        cfg["input"]["fastq_r2"] = str(r2_file)
    elif len(resolved_inputs) > 2:
        # Multiple files from glob - use directory or file list
        cfg["input"]["fastq"] = str(input_dir)
        cfg["input"]["files"] = [str(p) for p in resolved_inputs]
    elif input_style in ("FASTQ_DIR_SINGLE", "FASTQ_DIR_PAIRED"):
        cfg["input"]["fastq_dir"] = str(primary_input)
    elif primary_input.is_dir():
        # Directory input - use fastq field (like lr_meta config format)
        cfg["input"]["fastq"] = str(primary_input)
    elif input_style == "FASTQ_SINGLE" and config.pipeline in ("sr_amp", "sr_meta"):
        # sr_amp and sr_meta expect fastq_r1 even for single-end reads
        # This matches the module script expectations (sr_meta.sh uses input.fastq_r1)
        cfg["input"]["fastq_r1"] = str(primary_input)
    else:  # FASTQ_SINGLE for other pipelines (lr_amp, lr_meta)
        cfg["input"]["fastq"] = str(primary_input)

    # Auto-enable Valencia for vaginal samples (unless explicitly disabled)
    # Valencia is enabled if:
    # - Explicitly requested via --valencia flag, OR
    # - sample_type is "vaginal" (auto-enable for vaginal microbiome)
    # But NOT if --no-valencia is set
    is_vaginal = config.sample_type.lower() in ("vaginal", "vaginal_swab", "vagina")
    valencia_enabled = (config.valencia or is_vaginal) and not config.no_valencia

    # Add postprocess config (uniform format across all pipelines)
    pp_enabled = 1 if config.postprocess else 0
    cfg["postprocess"] = {
        "enabled": pp_enabled,
        "rscript_bin": "Rscript",
        "steps": {
            "heatmap": pp_enabled,
            "piechart": pp_enabled,
            "relative_abundance": pp_enabled,
            "stacked_bar": pp_enabled,
            "results_csv": pp_enabled,
            "valencia": 1 if valencia_enabled else 0,
        },
    }

    # --- Sample sheet (barcode -> human sample name for demultiplexed runs) ---
    # Mirrors frontend/utils/config_generator.R's sample_map/sample_sheet wiring so the
    # same downstream apply_sample_map() in the R postprocess scripts picks it up
    # regardless of whether the run was launched from the GUI or the CLI.
    if config.sample_sheet:
        sample_sheet_src = Path(config.sample_sheet).resolve()
        if not sample_sheet_src.exists():
            raise RunnerError(f"Sample sheet not found: {sample_sheet_src}")

        import csv

        delimiter = "\t" if sample_sheet_src.suffix.lower() in (".tsv", ".txt") else ","
        sample_map: Dict[str, str] = {}
        try:
            with open(sample_sheet_src, newline="") as fh:
                reader = csv.DictReader(fh, delimiter=delimiter)
                for row in reader:
                    barcode = (row.get("barcode") or "").strip()
                    name = (row.get("sample_name") or "").strip()
                    if barcode and name:
                        sample_map[barcode] = name
        except Exception as exc:
            raise RunnerError(f"Could not parse sample sheet '{sample_sheet_src}': {exc}")

        if not sample_map:
            raise RunnerError(
                f"Sample sheet '{sample_sheet_src}' has no usable rows "
                "(expected columns: barcode, sample_name)"
            )

        # Written as a SIBLING of run_dir (like the config JSON itself), not inside it —
        # stamina_biome_run.sh does `rm -rf "${RUN_DIR}"` on force-overwrite, which would
        # otherwise delete a file pre-written inside the run directory.
        sample_sheet_out = outdir / f"sample_sheet_{run_id}.tsv"
        outdir.mkdir(parents=True, exist_ok=True)
        with open(sample_sheet_out, "w", newline="") as fh:
            writer = csv.writer(fh, delimiter="\t")
            writer.writerow(["barcode", "sample_name"])
            for barcode, name in sample_map.items():
                writer.writerow([barcode, name])

        cfg["sample_map"] = sample_map
        cfg["sample_sheet"] = str(sample_sheet_out)
        for step_name in ("heatmap", "piechart", "stacked_bar", "results_csv"):
            if cfg["postprocess"]["steps"].get(step_name):
                cfg["postprocess"]["steps"][step_name] = {
                    "enabled": 1,
                    "params": {"sample_sheet": str(sample_sheet_out)},
                }

    # Add pipeline-specific config
    if config.pipeline == "sr_amp":
        # sr_amp uses QIIME2 with DADA2 for amplicon sequencing - no Kraken2 needed
        # sr_amp spawns containers (QIIME2) so it always runs on host (Model A)
        # This means we always use host paths, not container paths
        use_host_paths = not config.use_container or pipeline_spawns_containers(config.pipeline)

        # Check for default classifier in multiple locations
        # For PyInstaller bundles, check both direct and _internal paths
        classifier_candidates = [
            repo_root / "main" / "data" / "reference" / "qiime2" / "silva-138-99-nb-classifier.qza",
        ]
        # For PyInstaller bundle, also check executable's sibling _internal paths
        if getattr(sys, 'frozen', False):
            bundle_base = Path(sys.executable).parent
            classifier_candidates.insert(0, bundle_base / "_internal" / "main" / "data" / "reference" / "qiime2" / "silva-138-99-nb-classifier.qza")
            classifier_candidates.insert(0, bundle_base / "main" / "data" / "reference" / "qiime2" / "silva-138-99-nb-classifier.qza")

        classifier_host_resolved = None
        for candidate in classifier_candidates:
            if candidate.exists():
                classifier_host_resolved = candidate
                break

        classifier_path = ""
        if classifier_host_resolved:
            if use_host_paths:
                classifier_path = str(classifier_host_resolved)
            else:
                classifier_path = "/work/data/reference/qiime2/silva-138-99-nb-classifier.qza"

        # Valencia centroids path - auto-detect from multiple locations
        # Check multiple locations for VALENCIA centroids:
        # 1. tools/VALENCIA/ (installed by setup in bundle)
        # 2. main/tools/VALENCIA/ (legacy/development location)
        # 3. Parent directory (edge case for bundle structure)
        valencia_centroids_candidates = [
            repo_root / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
            repo_root / "main" / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
            repo_root.parent / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
        ]
        # For PyInstaller bundle, also check executable's sibling _internal/tools
        if getattr(sys, 'frozen', False):
            bundle_base = Path(sys.executable).parent
            valencia_centroids_candidates.insert(0, bundle_base / "_internal" / "tools" / "VALENCIA" / "CST_centroids_012920.csv")
            valencia_centroids_candidates.insert(0, bundle_base / "tools" / "VALENCIA" / "CST_centroids_012920.csv")
        valencia_centroids_host_resolved = None
        for candidate in valencia_centroids_candidates:
            if candidate.exists():
                valencia_centroids_host_resolved = candidate
                break

        if config.valencia_centroids:
            # Convert relative paths to absolute
            user_centroids = Path(config.valencia_centroids)
            if not user_centroids.is_absolute():
                user_centroids = Path.cwd() / user_centroids
            valencia_centroids = str(user_centroids.resolve())
        elif valencia_centroids_host_resolved:
            if use_host_paths:
                valencia_centroids = str(valencia_centroids_host_resolved)
            else:
                valencia_centroids = "/work/tools/VALENCIA/CST_centroids_012920.csv"
        else:
            # Default path (may not exist)
            valencia_centroids_host = repo_root / "main" / "tools" / "VALENCIA" / "CST_centroids_012920.csv"
            if use_host_paths:
                valencia_centroids = str(valencia_centroids_host)
            else:
                valencia_centroids = "/work/tools/VALENCIA/CST_centroids_012920.csv"

        cfg["qiime2"] = {
            "sample_id": config.sample_id,
            "primers": {"forward": config.primer_f, "reverse": config.primer_r},
            "classifier": {
                "qza": classifier_path  # Empty if not available - sr_amp.sh will skip taxonomy
            },
            "dada2": {
                "trim_left_f": 0,
                "trim_left_r": 0,
                "trunc_len_f": 233,
                "trunc_len_r": 228,
                "n_threads": 0,  # 0 means use all available
            },
            "diversity": {
                "sampling_depth": 0,
                "metadata_tsv": "",
            },
        }
        cfg["valencia"] = {
            "enabled": 1 if valencia_enabled else 0,
            "mode": "auto",
            "centroids_csv": valencia_centroids,
        }

        # QC tools configuration - use Docker wrappers if not on PATH
        fastqc_wrapper = repo_root / "main" / "tools" / "wrappers" / "fastqc"
        multiqc_wrapper = repo_root / "main" / "tools" / "wrappers" / "multiqc"

        # Check if tools are on PATH
        fastqc_on_path = subprocess.run(["which", "fastqc"], capture_output=True).returncode == 0
        multiqc_on_path = subprocess.run(["which", "multiqc"], capture_output=True).returncode == 0

        cfg["tools"] = {
            "fastqc_bin": "" if fastqc_on_path else (str(fastqc_wrapper) if fastqc_wrapper.exists() else ""),
            "multiqc_bin": "" if multiqc_on_path else (str(multiqc_wrapper) if multiqc_wrapper.exists() else ""),
        }

    elif config.pipeline == "sr_meta":
        # Auto-detect human reference if not provided
        human_index_resolved = config.human_index
        if not human_index_resolved:
            # Check for downloaded human references (prefer split indexes for low RAM)
            human_ref_candidates = [
                repo_root / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.split2G.mmi",
                repo_root / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.split4G.mmi",
                repo_root / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.lowmem.mmi",
            ]
            # For PyInstaller bundle, also check _internal path
            if getattr(sys, 'frozen', False):
                bundle_base = Path(sys.executable).parent
                human_ref_candidates.insert(0, bundle_base / "_internal" / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.split2G.mmi")
                human_ref_candidates.insert(0, bundle_base / "_internal" / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.split4G.mmi")
                human_ref_candidates.insert(0, bundle_base / "_internal" / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.lowmem.mmi")

            for candidate in human_ref_candidates:
                if candidate.exists():
                    human_index_resolved = str(candidate)
                    break

        cfg["tools"] = {
            "kraken2": {
                "db": config.kraken2_db,  # Path to Kraken2 database (e.g., /data/kraken2/k2_standard_08gb)
            },
            "minimap2": {
                "human_mmi": human_index_resolved,  # Path to human genome .mmi index
                "split_prefix": 1 if config.minimap2_split_index else 0,  # Use split-prefix for low-RAM
            },
        }
        _apply_kraken_params(cfg, config)
        _apply_bracken_params(cfg, config)
        _apply_kraken_memory_mapping(cfg, config)
        # Valencia centroids path - auto-detect from multiple locations
        # Check multiple locations for VALENCIA centroids:
        # 1. tools/VALENCIA/ (installed by setup in bundle)
        # 2. main/tools/VALENCIA/ (legacy/development location)
        # 3. Parent directory (edge case for bundle structure)
        valencia_centroids_candidates = [
            repo_root / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
            repo_root / "main" / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
            repo_root.parent / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
        ]
        # For PyInstaller bundle, also check executable's sibling _internal/tools
        if getattr(sys, 'frozen', False):
            bundle_base = Path(sys.executable).parent
            valencia_centroids_candidates.insert(0, bundle_base / "_internal" / "tools" / "VALENCIA" / "CST_centroids_012920.csv")
            valencia_centroids_candidates.insert(0, bundle_base / "tools" / "VALENCIA" / "CST_centroids_012920.csv")

        valencia_centroids_host_resolved = None
        for candidate in valencia_centroids_candidates:
            if candidate.exists():
                valencia_centroids_host_resolved = candidate
                break

        # Store the host path for mounting later (needed for container mode)
        config._valencia_centroids_host = valencia_centroids_host_resolved

        if config.valencia_centroids:
            # Convert relative paths to absolute
            user_centroids = Path(config.valencia_centroids)
            if not user_centroids.is_absolute():
                user_centroids = Path.cwd() / user_centroids
            user_centroids = user_centroids.resolve()
            config._valencia_centroids_host = user_centroids
            if config.use_container:
                valencia_centroids = f"/valencia/{user_centroids.name}"
            else:
                valencia_centroids = str(user_centroids)
        elif valencia_centroids_host_resolved:
            if config.use_container:
                valencia_centroids = f"/valencia/{valencia_centroids_host_resolved.name}"
            else:
                valencia_centroids = str(valencia_centroids_host_resolved)
        else:
            # Default path (may not exist)
            valencia_centroids_host = repo_root / "main" / "tools" / "VALENCIA" / "CST_centroids_012920.csv"
            if config.use_container:
                valencia_centroids = "/valencia/CST_centroids_012920.csv"
            else:
                valencia_centroids = str(valencia_centroids_host)

        cfg["valencia"] = {
            "enabled": 1 if valencia_enabled else 0,
            "mode": "auto",
            "centroids_csv": valencia_centroids,
        }

    elif config.pipeline in ("lr_amp", "lr_meta"):
        # Emu database path - use CLI arg if provided, else auto-detect
        # Check multiple locations for the emu database:
        # 1. databases/emu-default/emu (installed by setup)
        # 2. databases/emu-default (in case files are directly here)
        # 3. reference/emu (legacy location)
        emu_db_candidates = [
            repo_root / "main" / "data" / "databases" / "emu-default" / "emu",
            repo_root / "main" / "data" / "databases" / "emu-default",
            repo_root / "main" / "data" / "reference" / "emu",
        ]
        emu_db_host_resolved = None
        for candidate in emu_db_candidates:
            if candidate.exists():
                # Check for species_taxid.fasta directly or in subdirectories
                if (candidate / "species_taxid.fasta").exists():
                    emu_db_host_resolved = candidate
                    break
                # Check subdirectories (some databases extract with nested structure)
                for subdir in candidate.iterdir():
                    if subdir.is_dir() and (subdir / "species_taxid.fasta").exists():
                        emu_db_host_resolved = subdir
                        break
                if emu_db_host_resolved:
                    break

        # Use CLI arg if provided, otherwise use resolved path
        if config.emu_db:
            emu_db_host_path = Path(config.emu_db)
            # Check if database files are directly in the path or in a subdirectory
            # Some Emu databases extract with a nested directory structure
            if not (emu_db_host_path / "species_taxid.fasta").exists():
                # Look for species_taxid.fasta in subdirectories
                for subdir in emu_db_host_path.iterdir():
                    if subdir.is_dir() and (subdir / "species_taxid.fasta").exists():
                        emu_db_host_path = subdir
                        if config.verbose:
                            print(f"[stamina-biome] Found Emu DB in subdirectory: {emu_db_host_path}")
                        break
        elif emu_db_host_resolved:
            emu_db_host_path = emu_db_host_resolved
        else:
            emu_db_host_path = emu_db_candidates[0]  # Default (may not exist)

        # For container mode, we'll mount the database and use container path
        if config.use_container:
            emu_db = "/db/emu"  # Container path - will be mounted
        else:
            emu_db = str(emu_db_host_path)

        # Store the host path for mounting later
        config._emu_db_host_path = emu_db_host_path

        # Valencia paths - auto-detect centroids file from multiple locations
        # Check multiple locations for VALENCIA centroids:
        # 1. tools/VALENCIA/ (installed by setup in bundle - PyInstaller)
        # 2. main/tools/VALENCIA/ (legacy/development location)
        # 3. Parent directory (edge case for bundle structure)
        valencia_centroids_candidates = [
            repo_root / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
            repo_root / "main" / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
            repo_root.parent / "tools" / "VALENCIA" / "CST_centroids_012920.csv",
        ]
        # For PyInstaller bundle, also check executable's sibling _internal/tools
        if getattr(sys, 'frozen', False):
            bundle_base = Path(sys.executable).parent
            valencia_centroids_candidates.insert(0, bundle_base / "_internal" / "tools" / "VALENCIA" / "CST_centroids_012920.csv")
            valencia_centroids_candidates.insert(0, bundle_base / "tools" / "VALENCIA" / "CST_centroids_012920.csv")

        valencia_centroids_host_resolved = None
        for candidate in valencia_centroids_candidates:
            if candidate.exists():
                valencia_centroids_host_resolved = candidate
                break

        # Store the host path for mounting later (needed if outside main/)
        config._valencia_centroids_host = valencia_centroids_host_resolved

        if config.verbose:
            if valencia_centroids_host_resolved:
                print(f"[stamina-biome] Found VALENCIA centroids: {valencia_centroids_host_resolved}")
            elif config.valencia or config.sample_type == "vaginal":
                print(f"[stamina-biome] Warning: VALENCIA centroids not found. Run 'stamina-biome setup' to download.")

        if config.use_container:
            valencia_root = "/work/tools/VALENCIA"
            # Default container path - use actual filename if resolved, otherwise fallback
            default_centroids = f"/valencia/{valencia_centroids_host_resolved.name}" if valencia_centroids_host_resolved else "/work/tools/VALENCIA/CST_centroids_012920.csv"
        else:
            valencia_root = str(repo_root / "main" / "tools" / "VALENCIA")
            default_centroids = str(valencia_centroids_host_resolved) if valencia_centroids_host_resolved else str(repo_root / "main" / "tools" / "VALENCIA" / "CST_centroids_012920.csv")

        if config.valencia_centroids:
            # Convert relative paths to absolute
            user_centroids = Path(config.valencia_centroids)
            if not user_centroids.is_absolute():
                user_centroids = Path.cwd() / user_centroids
            user_centroids = user_centroids.resolve()

            # For Docker, convert host path to container path if under main/
            if config.use_container:
                main_path = repo_root / "main"
                try:
                    rel_path = user_centroids.relative_to(main_path)
                    valencia_centroids = f"/work/{rel_path}"
                    config._valencia_centroids_host = None  # No extra mount needed
                except ValueError:
                    # File is outside main/, mount to container with actual filename
                    valencia_centroids = f"/valencia/{user_centroids.name}"
                    config._valencia_centroids_host = user_centroids
            else:
                valencia_centroids = str(user_centroids)
                config._valencia_centroids_host = None
        else:
            valencia_centroids = default_centroids

        # Auto-detect human reference if not provided
        human_index_resolved = config.human_index
        if not human_index_resolved:
            # Check for downloaded human references (prefer split indexes for low RAM)
            human_ref_candidates = [
                repo_root / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.split2G.mmi",
                repo_root / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.split4G.mmi",
                repo_root / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.lowmem.mmi",
            ]
            # For PyInstaller bundle, also check _internal path
            if getattr(sys, 'frozen', False):
                bundle_base = Path(sys.executable).parent
                human_ref_candidates.insert(0, bundle_base / "_internal" / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.split2G.mmi")
                human_ref_candidates.insert(0, bundle_base / "_internal" / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.split4G.mmi")
                human_ref_candidates.insert(0, bundle_base / "_internal" / "main" / "data" / "reference" / "human" / "grch38" / "GRCh38.primary_assembly.genome.lowmem.mmi")

            for candidate in human_ref_candidates:
                if candidate.exists():
                    human_index_resolved = str(candidate)
                    break

        cfg["tools"] = {
            "emu": {
                "db": emu_db,
            },
            "kraken2": {
                "db": config.kraken2_db,  # Use CLI arg if provided
            },
            "minimap2": {
                "human_mmi": human_index_resolved,  # Path to human genome .mmi index for host depletion
                "split_prefix": 1 if config.minimap2_split_index else 0,  # Use split-prefix for low-RAM
            },
            "dorado": {
                "model": config.dorado_model,  # e.g., "dna_r10.4.1_e8.2_400bps_hac@v4.1.0"
                "ligation_kit": config.ligation_kit,  # Default: SQK-LSK114
                "barcode_kit": config.barcode_kit,  # e.g., "EXP-PBC001", "SQK-NBD114-24" - empty means single sample
                "sequencing_kit": config.sequencing_kit or config.ligation_kit,  # Sequencing kit for trim (defaults to ligation_kit)
                "primer_fasta": "",  # Optional primer FASTA for trimming
            },
        }
        _apply_kraken_params(cfg, config)
        _apply_emu_params(cfg, config)
        _apply_bracken_params(cfg, config)
        _apply_kraken_memory_mapping(cfg, config)
        # Set full_length based on amplicon type (affects classifier choice: Emu vs Kraken2)
        # full-length (default) -> Emu classifier for complete 16S gene (~1500bp)
        # partial -> Kraken2 classifier for partial 16S (e.g., V3-V4 region)
        cfg["params"]["full_length"] = 1 if config.amplicon_type == "full-length" else 0

        # Set seq_type for Emu minimap2 preset (map-ont, map-pb, map-hifi, lr:hq)
        cfg["params"]["seq_type"] = config.seq_type

        # Add Valencia config for lr_amp/lr_meta (looked up by lr_amp.sh)
        # Valencia is auto-enabled for vaginal samples
        cfg["valencia"] = {
            "enabled": 1 if valencia_enabled else 0,
            "root": valencia_root,
            "centroids_csv": valencia_centroids,
        }

    # Merge extra params
    if config.extra_params:
        cfg = deep_merge(cfg, config.extra_params)

    return cfg


def find_paired_read(r1_path: Path) -> Optional[Path]:
    """Find the R2 file for a given R1 file."""
    name = r1_path.name
    replacements = [
        ("_R1", "_R2"),
        ("_1.fastq", "_2.fastq"),
        ("_1.fq", "_2.fq"),
        ("_R1_001", "_R2_001"),
    ]
    for old, new in replacements:
        if old in name:
            r2_name = name.replace(old, new)
            r2_path = r1_path.parent / r2_name
            if r2_path.exists():
                return r2_path
    return None


def deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    """Deep merge two dicts, with override taking precedence."""
    result = base.copy()
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def write_config(config_dict: Dict[str, Any], path: Path) -> None:
    """Write config dict to a JSON file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(config_dict, f, ensure_ascii=False, indent=2)


def check_qc_tools(config_dict: Dict[str, Any], repo_root: Path) -> Dict[str, Any]:
    """
    Check availability of QC tools (FastQC, MultiQC).
    Returns a dict with status for each tool.
    """
    result = {
        "fastqc": {"available": False, "path": "", "source": "", "reason": ""},
        "multiqc": {"available": False, "path": "", "source": "", "reason": ""},
    }

    # Check FastQC
    fastqc_bin = config_dict.get("tools", {}).get("fastqc_bin", "")
    if fastqc_bin:
        # Config specifies a path
        if fastqc_bin.startswith("docker ") or Path(fastqc_bin).exists() or subprocess.run(
            ["which", fastqc_bin.split()[0]], capture_output=True
        ).returncode == 0:
            result["fastqc"]["available"] = True
            result["fastqc"]["path"] = fastqc_bin
            result["fastqc"]["source"] = "config (tools.fastqc_bin)"
        else:
            result["fastqc"]["reason"] = f"Config path not found: {fastqc_bin}"
    else:
        # Check if on PATH
        which_result = subprocess.run(["which", "fastqc"], capture_output=True, text=True)
        if which_result.returncode == 0:
            result["fastqc"]["available"] = True
            result["fastqc"]["path"] = which_result.stdout.strip()
            result["fastqc"]["source"] = "PATH"
        else:
            # Check if Docker wrapper exists
            wrapper_path = repo_root / "main" / "tools" / "wrappers" / "fastqc"
            if wrapper_path.exists():
                result["fastqc"]["available"] = True
                result["fastqc"]["path"] = str(wrapper_path)
                result["fastqc"]["source"] = "Docker wrapper"
            else:
                result["fastqc"]["reason"] = "Not on PATH and no Docker wrapper configured"

    # Check MultiQC
    multiqc_bin = config_dict.get("tools", {}).get("multiqc_bin", "")
    if multiqc_bin:
        # Config specifies a path
        if multiqc_bin.startswith("docker ") or Path(multiqc_bin).exists() or subprocess.run(
            ["which", multiqc_bin.split()[0]], capture_output=True
        ).returncode == 0:
            result["multiqc"]["available"] = True
            result["multiqc"]["path"] = multiqc_bin
            result["multiqc"]["source"] = "config (tools.multiqc_bin)"
        else:
            result["multiqc"]["reason"] = f"Config path not found: {multiqc_bin}"
    else:
        # Check if on PATH
        which_result = subprocess.run(["which", "multiqc"], capture_output=True, text=True)
        if which_result.returncode == 0:
            result["multiqc"]["available"] = True
            result["multiqc"]["path"] = which_result.stdout.strip()
            result["multiqc"]["source"] = "PATH"
        else:
            # Check if Docker wrapper exists
            wrapper_path = repo_root / "main" / "tools" / "wrappers" / "multiqc"
            if wrapper_path.exists():
                result["multiqc"]["available"] = True
                result["multiqc"]["path"] = str(wrapper_path)
                result["multiqc"]["source"] = "Docker wrapper"
            else:
                result["multiqc"]["reason"] = "Not on PATH and no Docker wrapper configured"

    return result


def validate_preflight(pipeline: str, config_dict: Dict[str, Any], use_container: bool = True) -> List[str]:
    """
    Pre-flight validation to check required dependencies before running.
    Returns list of error messages (empty if all OK).

    Args:
        pipeline: Pipeline ID (e.g., "sr_meta", "lr_amp")
        config_dict: The configuration dictionary
        use_container: Whether running in container mode (tools available in container)
    """
    errors = []

    # Pipeline-specific validation
    if pipeline == "sr_amp":
        # sr_amp uses QIIME2 with a classifier QZA - no Kraken2 needed
        # Check if Valencia is enabled but classifier is missing
        classifier_qza = config_dict.get("qiime2", {}).get("classifier", {}).get("qza", "")
        valencia_enabled = config_dict.get("valencia", {}).get("enabled", 0) == 1

        if valencia_enabled and not classifier_qza:
            errors.append(
                "Valencia CST analysis requires a QIIME2 taxonomy classifier."
            )
            errors.append(
                "Download SILVA classifier: https://docs.qiime2.org/2024.10/data-resources/"
            )
            errors.append(
                "Place it at: main/data/reference/qiime2/silva-138-99-nb-classifier.qza"
            )
            errors.append(
                "Or disable Valencia with --no-valencia flag."
            )

    elif pipeline == "sr_meta":
        # sr_meta requires Kraken2 database
        kraken_db = config_dict.get("tools", {}).get("kraken2", {}).get("db", "")
        if not kraken_db:
            errors.append(
                f"Kraken2 database not configured. "
                f"Set tools.kraken2.db in config."
            )
            errors.append(
                f"Download a database from: https://benlangmead.github.io/aws-indexes/k2"
            )

        # sr_meta requires fastp for read trimming (only check if not using container)
        if not use_container:
            fastp_check = subprocess.run(["which", "fastp"], capture_output=True)
            if fastp_check.returncode != 0:
                errors.append(
                    "fastp not found on PATH (required for sr_meta read trimming)."
                )
                errors.append(
                    "Install with: conda install -c bioconda fastp"
                )
                errors.append(
                    "Or run with container mode (remove --no-container flag)."
                )

    elif pipeline == "lr_meta":
        # lr_meta requires Kraken2 database
        kraken_db = config_dict.get("tools", {}).get("kraken2", {}).get("db", "")
        if not kraken_db:
            errors.append(
                f"Kraken2 database not configured. "
                f"Set tools.kraken2.db in config."
            )

    elif pipeline == "lr_amp":
        # lr_amp uses Emu for full-length 16S, Kraken2 for partial 16S
        full_length = config_dict.get("params", {}).get("full_length", 1)
        emu_db = config_dict.get("tools", {}).get("emu", {}).get("db", "")
        kraken_db = config_dict.get("tools", {}).get("kraken2", {}).get("db", "")

        if full_length == 1:
            # Full-length mode uses Emu - check if Emu DB is available
            # Emu has a default DB location, so only warn if it's explicitly empty
            # The pipeline will handle missing Emu DB gracefully
            pass  # No hard requirement - Emu DB has default location
        else:
            # Partial mode requires Kraken2 database
            if not kraken_db:
                errors.append(
                    f"Kraken2 database not configured for partial 16S classification. "
                    f"Use --db PATH to specify the Kraken2 database."
                )
                errors.append(
                    f"Download a database from: https://benlangmead.github.io/aws-indexes/k2"
                )

    return errors


def run_pipeline(
    config: RunConfig,
    dry_run: bool = False,
    repo_root: Optional[Path] = None,
) -> int:
    """
    Run a pipeline with the given configuration.

    Returns the exit code (0 for success).
    """
    if repo_root is None:
        repo_root = find_repo_root()

    # Validate pipeline
    if not validate_pipeline_id(config.pipeline, repo_root):
        available = ", ".join(list_pipeline_ids(repo_root))
        raise RunnerError(
            f"Unknown pipeline: {config.pipeline}\nAvailable: {available}"
        )

    # Validate inputs
    if not config.input_paths:
        raise RunnerError("No input paths provided")

    for input_path in config.input_paths:
        if not Path(input_path).exists():
            raise RunnerError(f"Input path does not exist: {input_path}")

    # Detailed input detection
    input_style, input_details = detect_input_style_detailed(config.input_paths, config.pipeline)

    # Print input detection summary
    detection_msg = format_input_detection(
        input_style,
        file_count=input_details.get("file_count", 0),
        pair_count=input_details.get("pair_count", 0),
        unmatched=input_details.get("unmatched", []),
    )
    print(f"\n{detection_msg}")

    # Warn about unmatched files
    if input_details.get("unmatched") and config.verbose:
        print(Colors.yellow_bold("  Note: Unmatched files will be processed as single-end"))

    # Ensure output directory can be created
    outdir = Path(config.outdir).resolve()
    try:
        outdir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        raise RunnerError(f"Cannot create output directory: {outdir}\n{e}")

    # Build config
    config_dict = build_config(config, repo_root)

    # Pre-flight validation: check required dependencies before running
    # Pass use_container flag so we only check for local tools when not using container
    preflight_errors = validate_preflight(config.pipeline, config_dict, config.use_container)
    if preflight_errors:
        print(f"\n{Colors.red_bold('ERROR')}: Pre-flight validation failed for {config.pipeline}")
        print()
        for error in preflight_errors:
            print(f"  {Colors.dim('•')} {error}")
        print()
        print(f"Fix these issues before running the pipeline.")
        return 1

    if dry_run:
        # Even in dry-run, create log directory and write plan log
        run_id = config_dict["run"]["run_id"]
        run_dir = outdir / run_id
        logs_dir = run_dir / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)

        # Write config for reference
        config_path = run_dir / "effective_config.json"
        write_config(config_dict, config_path)

        # Write plan log
        plan_log_path = logs_dir / "dry_run_plan.log"
        with open(plan_log_path, "w") as f:
            import datetime
            f.write(f"# STAMINA-BIOME Dry-Run Plan Log\n")
            f.write(f"# Generated: {datetime.datetime.now().isoformat()}\n")
            f.write(f"# Pipeline: {config.pipeline}\n")
            f.write(f"# Run ID: {run_id}\n")
            f.write(f"\n")

            # QC tools status
            qc_status = check_qc_tools(config_dict, repo_root)
            f.write("## QC Tools Status\n")
            for tool_name, tool_info in qc_status.items():
                if tool_info["available"]:
                    f.write(f"{tool_name}: FOUND at {tool_info['path']} (source: {tool_info['source']})\n")
                else:
                    f.write(f"{tool_name}: MISSING - {tool_info['reason']}\n")
            f.write("\n")

            # Planned commands
            f.write("## Planned Commands\n")
            runner_script = get_runner_script(repo_root, config.pipeline)
            f.write(f"Main: {runner_script} --config {config_path}\n")
            f.write("\n")

            # Config snapshot
            f.write("## Config (JSON)\n")
            f.write(json.dumps(config_dict, indent=2))
            f.write("\n")

        print_dry_run(config, config_dict, repo_root)

        # Show log file paths
        print()
        print("=" * 70)
        print("LOG FILES CREATED (dry-run)")
        print("=" * 70)
        print(f"  Logs directory:   {logs_dir}")
        print(f"  Plan log:         {plan_log_path}")
        print(f"  Config file:      {config_path}")
        print("=" * 70)

        return 0

    # Write config to run_dir (not just outdir) for better organization
    run_id = config_dict["run"]["run_id"]
    run_dir = outdir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    config_path = run_dir / "effective_config.json"
    write_config(config_dict, config_path)

    # Print styled pipeline header
    print()
    print(Colors.dim("─" * 60))
    print(f"  {Colors.cyan_bold('Pipeline')}:    {config.pipeline}")
    print(f"  {Colors.cyan_bold('Run ID')}:      {run_id}")
    print(f"  {Colors.cyan_bold('Output')}:      {run_dir}")
    print(f"  {Colors.cyan_bold('Sample type')}: {config.sample_type}")
    print(f"  {Colors.cyan_bold('Inputs')}:      {len(config.input_paths)} file(s)")

    if config.verbose:
        for p in config.input_paths[:5]:
            print(f"    {Colors.dim('•')} {p}")
        if len(config.input_paths) > 5:
            print(f"    {Colors.dim('... and')} {len(config.input_paths) - 5} {Colors.dim('more')}")

    print(Colors.dim("─" * 60))
    print()

    # Only print full config if --debug-config is passed
    if config.debug_config:
        print(f"Config file: {config_path}")
        print(f"Config contents:")
        print(json.dumps(config_dict, indent=2))

    # Run the pipeline
    runner_script = get_runner_script(repo_root, config.pipeline)
    if not runner_script.exists():
        raise RunnerError(f"Runner script not found: {runner_script}")

    # Execute
    env = os.environ.copy()

    # Model A: Pipelines that spawn external containers (e.g., sr_amp -> QIIME2)
    # MUST run on the host so they can access the Docker daemon.
    # We override use_container=False for these pipelines.
    use_container = config.use_container
    if pipeline_spawns_containers(config.pipeline):
        if use_container:
            container_images = get_pipeline_container_images(config.pipeline)
            print(f"[stamina-biome] Pipeline '{config.pipeline}' spawns external containers: {container_images}")
            print(f"[stamina-biome] Using Model A: Running on host to allow Docker access")
            use_container = False
        else:
            container_images = get_pipeline_container_images(config.pipeline)
            print(f"[stamina-biome] Pipeline '{config.pipeline}' will spawn: {container_images}")

    if use_container:
        # Check if Docker is available first
        docker_check = subprocess.run(
            ["docker", "info"], capture_output=True, timeout=10
        )
        if docker_check.returncode != 0:
            raise RunnerError(
                "Docker is not available. Either start Docker or use --no-container flag."
            )

        # Select Docker image with smart fallback (prevents registry pull attempts)
        docker_image, selection_reason = select_docker_image(
            pipeline=config.pipeline,
            override_image=config.docker_image,
            verbose=config.verbose,
        )
        print(f"{Colors.cyan_bold('Docker image')}: {docker_image} ({selection_reason})")

        # Build Docker command with volume mounts
        # Mount repo root at /work
        # Mount input files directory
        # Mount output directory
        input_parent = Path(config.input_paths[0]).resolve().parent

        # Convert paths to container paths
        container_repo = "/work"
        container_config = f"/work/outputs/{config.pipeline}_cli.json"
        container_script = f"{container_repo}/pipelines/modules/{config.pipeline}.sh"

        # Create a container-specific config with mapped paths
        container_config_dict = config_dict.copy()
        # Deep copy the run dict to avoid mutating the original
        container_config_dict["run"] = config_dict["run"].copy()
        container_config_dict["run"]["work_dir"] = f"{container_repo}/outputs"
        # run_dir = work_dir / run_id inside container
        container_run_id = config_dict["run"]["run_id"]
        container_config_dict["run"]["run_dir"] = f"{container_repo}/outputs/{container_run_id}"

        # run_dir already created above when we wrote effective_config.json
        # Just verify it exists
        host_run_dir = run_dir  # Already set above
        if not host_run_dir.exists():
            host_run_dir.mkdir(parents=True, exist_ok=True)

        # Deep copy input dict and map paths for container
        container_config_dict["input"] = config_dict.get("input", {}).copy()

        # Map input paths based on input style
        input_style = config_dict.get("input", {}).get("style", "FASTQ_SINGLE")

        # Check if we have multiple input files (from glob expansion)
        has_files_list = "files" in config_dict.get("input", {})
        input_files = config_dict.get("input", {}).get("files", [])

        if input_style == "FAST5_DIR":
            # FAST5 directory: map fast5_dir to /input
            container_config_dict["input"]["fast5_dir"] = "/input"
            # Map file list to container paths
            if has_files_list:
                container_files = [f"/input/{Path(f).name}" for f in input_files]
                container_config_dict["input"]["files"] = container_files
        elif input_style == "FAST5_ARCHIVE":
            # FAST5 archive: map to /input/{filename}
            if "fast5_archive" in config_dict.get("input", {}):
                archive_path = Path(config_dict["input"]["fast5_archive"])
                container_config_dict["input"]["fast5_archive"] = f"/input/{archive_path.name}"
        elif input_style == "BAM":
            # BAM file: map to /input/{filename}
            if "bam" in config_dict.get("input", {}):
                bam_path = Path(config_dict["input"]["bam"])
                container_config_dict["input"]["bam"] = f"/input/{bam_path.name}"
        elif input_style == "FASTQ_PAIRED":
            # Paired-end: map both R1 and R2
            if "fastq_r1" in config_dict.get("input", {}):
                r1_path = Path(config_dict["input"]["fastq_r1"])
                container_config_dict["input"]["fastq_r1"] = f"/input/{r1_path.name}"
            if "fastq_r2" in config_dict.get("input", {}):
                r2_path = Path(config_dict["input"]["fastq_r2"])
                container_config_dict["input"]["fastq_r2"] = f"/input/{r2_path.name}"
        elif has_files_list and len(input_files) > 1:
            # Multiple files from glob - map to container paths as an array
            # The files are mounted via their common parent directory at /input
            container_files = [f"/input/{Path(f).name}" for f in input_files]
            # Use .input.fastq as an array (supported by lr_meta.sh resolve_fastq_list)
            container_config_dict["input"]["fastq"] = container_files
            # Also set fastqs as alias for compatibility
            container_config_dict["input"]["fastqs"] = container_files
            # Remove the host files list (not needed in container)
            if "files" in container_config_dict["input"]:
                del container_config_dict["input"]["files"]
        else:
            # Single file or single-end batch
            if "fastq_r1" in config_dict.get("input", {}):
                r1_path = Path(config_dict["input"]["fastq_r1"])
                container_config_dict["input"]["fastq_r1"] = f"/input/{r1_path.name}"
            elif "fastq" in config_dict.get("input", {}):
                orig_fastq = config_dict["input"]["fastq"]
                orig_path = Path(orig_fastq)
                # If it's a directory that's being mounted at /input, use /input directly
                if orig_path.is_dir() and orig_path.resolve() == input_parent.resolve():
                    container_config_dict["input"]["fastq"] = "/input"
                else:
                    # Single file - map to /input/{filename}
                    container_config_dict["input"]["fastq"] = f"/input/{orig_path.name}"

        # Handle external database paths - mount them into the container
        extra_mounts = []  # List of (host_path, container_path) tuples

        # Mount Kraken2 database if specified
        kraken2_db_host = config.kraken2_db
        if kraken2_db_host and Path(kraken2_db_host).exists():
            kraken2_db_container = "/db/kraken2"
            extra_mounts.append((kraken2_db_host, kraken2_db_container))
            # Update container config to use container path
            if "tools" not in container_config_dict:
                container_config_dict["tools"] = {}
            if "kraken2" not in container_config_dict["tools"]:
                container_config_dict["tools"]["kraken2"] = {}
            container_config_dict["tools"]["kraken2"]["db"] = kraken2_db_container
            if config.verbose:
                print(f"[stamina-biome] Mounting Kraken2 DB: {kraken2_db_host} -> {kraken2_db_container}")

        # Mount Emu database (from CLI arg or auto-detected path)
        emu_db_host_path = getattr(config, '_emu_db_host_path', None)
        if emu_db_host_path and Path(emu_db_host_path).exists():
            emu_db_container = "/db/emu"
            extra_mounts.append((str(emu_db_host_path), emu_db_container))
            # Update container config to use container path
            if "tools" not in container_config_dict:
                container_config_dict["tools"] = {}
            if "emu" not in container_config_dict["tools"]:
                container_config_dict["tools"]["emu"] = {}
            container_config_dict["tools"]["emu"]["db"] = emu_db_container
            if config.verbose:
                print(f"[stamina-biome] Mounting Emu DB: {emu_db_host_path} -> {emu_db_container}")
        elif config.verbose and config.pipeline in ("lr_amp", "lr_meta"):
            print(f"[stamina-biome] Warning: Emu database not found at expected locations")

        # Mount patched Emu script (fixes taxonomy index type mismatch in v3.5.5)
        # The bug: Emu loads taxonomy.tsv with dtype=str, but parses SAM tax_ids as int
        # This patch keeps tax_ids as strings to match the taxonomy index
        patched_emu_path = repo_root / "main" / "pipelines" / "patches" / "emu_v3.5.5_patched.py"
        if patched_emu_path.exists():
            extra_mounts.append((str(patched_emu_path), "/usr/local/bin/emu"))
            if config.verbose:
                print(f"[stamina-biome] Mounting patched Emu: {patched_emu_path}")

        # Mount VALENCIA centroids file if it's external to the bundle
        valencia_centroids_host = getattr(config, '_valencia_centroids_host', None)
        if valencia_centroids_host and Path(valencia_centroids_host).exists():
            # Mount the file's directory and use the actual filename
            valencia_host_path = Path(valencia_centroids_host)
            valencia_filename = valencia_host_path.name  # e.g., CST_centroids_012920.csv
            valencia_dir = valencia_host_path.parent
            valencia_centroids_container = f"/valencia/{valencia_filename}"
            extra_mounts.append((str(valencia_dir), "/valencia"))
            # Update container config
            if "valencia" not in container_config_dict:
                container_config_dict["valencia"] = {}
            container_config_dict["valencia"]["centroids_csv"] = valencia_centroids_container
            if config.verbose:
                print(f"[stamina-biome] Mounting VALENCIA centroids: {valencia_centroids_host} -> {valencia_centroids_container}")

        # Mount human genome index if specified (for host depletion)
        human_index_host = config.human_index
        if human_index_host:
            # Resolve to absolute path
            human_index_path = Path(human_index_host).resolve()
            if human_index_path.exists():
                # Mount the directory containing the .mmi file
                human_index_dir = human_index_path.parent
                human_index_filename = human_index_path.name
                human_index_container_dir = "/db/human"
                human_index_container = f"{human_index_container_dir}/{human_index_filename}"
                extra_mounts.append((str(human_index_dir), human_index_container_dir))
                # Update container config to use container path
                if "tools" not in container_config_dict:
                    container_config_dict["tools"] = {}
                if "minimap2" not in container_config_dict["tools"]:
                    container_config_dict["tools"]["minimap2"] = {}
                container_config_dict["tools"]["minimap2"]["human_mmi"] = human_index_container
                if config.verbose:
                    print(f"[stamina-biome] Mounting human index: {human_index_path} -> {human_index_container}")
            else:
                print(f"{Colors.yellow_bold('Warning')}: Human index not found: {human_index_path}")
                print(f"         Host depletion will fail unless the file exists.")
                print(f"         Available .mmi files in reference/human/:")
                human_ref_dir = repo_root / "main" / "data" / "reference" / "human"
                if human_ref_dir.exists():
                    for mmi in human_ref_dir.rglob("*.mmi"):
                        print(f"           - {mmi.relative_to(repo_root)}")

        # Mount Dorado binary and models directory if specified (for FAST5 basecalling)
        # Auto-detect setup-installed Dorado if not provided by user
        # Skip if STAMINA_BIOME_SKIP_DORADO_MOUNT is set (container has built-in Dorado)
        skip_dorado_mount = os.environ.get('STAMINA_BIOME_SKIP_DORADO_MOUNT')

        dorado_bin_host = config.dorado_bin if not skip_dorado_mount else None
        dorado_models_dir_host = config.dorado_models_dir if not skip_dorado_mount else None

        if not skip_dorado_mount and (not dorado_bin_host or not dorado_models_dir_host):
            # Try to use setup-installed Dorado
            tools_dir = repo_root / "tools"

            # Try default location first (Dorado 1.3.1), then check for version-specific directories
            setup_dorado_bin = tools_dir / "dorado" / "bin" / "dorado"

            if not setup_dorado_bin.exists() or not os.access(setup_dorado_bin, os.X_OK):
                # Check for version-specific Dorado installations (e.g., dorado-0.9.6)
                # Skip -host directories as they contain macOS binaries, not Linux binaries for Docker
                for dorado_dir in sorted(tools_dir.glob("dorado-*"), reverse=True):
                    if dorado_dir.name.endswith("-host"):
                        continue  # Skip host binaries (macOS), we need Linux binaries for Docker
                    candidate_bin = dorado_dir / "bin" / "dorado"
                    if candidate_bin.exists() and os.access(candidate_bin, os.X_OK):
                        setup_dorado_bin = candidate_bin
                        break

            setup_models_dir = tools_dir / "models" / "dorado"

            if not dorado_bin_host and setup_dorado_bin.exists() and os.access(setup_dorado_bin, os.X_OK):
                dorado_bin_host = str(setup_dorado_bin)
                if config.verbose:
                    # Extract version from path if available
                    dorado_parent = setup_dorado_bin.parent.parent.name
                    version_info = f" ({dorado_parent})" if dorado_parent.startswith("dorado-") else ""
                    print(f"[stamina-biome] Auto-detected Dorado binary{version_info}: {dorado_bin_host}")

            if not dorado_models_dir_host and setup_models_dir.exists() and any(setup_models_dir.iterdir()):
                dorado_models_dir_host = str(setup_models_dir)
                if config.verbose:
                    print(f"[stamina-biome] Auto-detected Dorado models: {dorado_models_dir_host}")

        if dorado_bin_host and Path(dorado_bin_host).exists():
            # Mount the Dorado binary
            dorado_bin_path = Path(dorado_bin_host).resolve()
            if dorado_bin_path.is_file():
                # Mount the directory containing the binary
                dorado_bin_dir = dorado_bin_path.parent
                dorado_bin_filename = dorado_bin_path.name
                dorado_bin_container_dir = "/opt/dorado/bin"
                dorado_bin_container = f"{dorado_bin_container_dir}/{dorado_bin_filename}"
                extra_mounts.append((str(dorado_bin_dir), dorado_bin_container_dir))

                # Also mount the lib directory if it exists (for shared libraries)
                dorado_lib_dir = dorado_bin_dir.parent / "lib"
                if dorado_lib_dir.exists():
                    extra_mounts.append((str(dorado_lib_dir), "/opt/dorado/lib"))

                # Update container config to use container path
                if "tools" not in container_config_dict:
                    container_config_dict["tools"] = {}
                container_config_dict["tools"]["dorado_bin"] = dorado_bin_container

                if config.verbose:
                    print(f"[stamina-biome] Mounting Dorado binary: {dorado_bin_path} -> {dorado_bin_container}")
                    if dorado_lib_dir.exists():
                        print(f"[stamina-biome] Mounting Dorado lib: {dorado_lib_dir} -> /opt/dorado/lib")
            else:
                print(f"{Colors.yellow_bold('Warning')}: Dorado binary not found or not a file: {dorado_bin_path}")

        if dorado_models_dir_host and Path(dorado_models_dir_host).exists():
            # Mount the models directory
            dorado_models_path = Path(dorado_models_dir_host).resolve()
            if dorado_models_path.is_dir():
                dorado_models_container = "/dorado_models"
                extra_mounts.append((str(dorado_models_path), dorado_models_container))

                # Update container config to use container path
                if "tools" not in container_config_dict:
                    container_config_dict["tools"] = {}
                container_config_dict["tools"]["dorado_models_dir"] = dorado_models_container

                if config.verbose:
                    print(f"[stamina-biome] Mounting Dorado models: {dorado_models_path} -> {dorado_models_container}")
            else:
                print(f"{Colors.yellow_bold('Warning')}: Dorado models directory not found or not a directory: {dorado_models_path}")

        # Write container config into run_dir
        container_config_host = run_dir / "docker_config.json"
        write_config(container_config_dict, container_config_host)

        if config.verbose:
            print(f"[stamina-biome] Docker config: {container_config_host}")
            print(f"[stamina-biome] Docker run.run_dir: {container_config_dict['run']['run_dir']}")
            print(f"[stamina-biome] Input style: {input_style}")
            # Show mapped input files for multi-file input
            if has_files_list and len(input_files) > 1:
                # Check for FAST5 files first, then FASTQ
                container_input_files = container_config_dict.get("input", {}).get("files", [])
                container_input_fastq = container_config_dict.get("input", {}).get("fastq", [])
                files_to_show = container_input_files if container_input_files else container_input_fastq
                if isinstance(files_to_show, list) and files_to_show:
                    print(f"[stamina-biome] Input files: {len(files_to_show)} files mapped to container")
                    for cf in files_to_show[:3]:
                        print(f"[stamina-biome]   - {cf}")
                    if len(files_to_show) > 3:
                        print(f"[stamina-biome]   ... and {len(files_to_show) - 3} more")

        # Build Docker command with volume mounts
        cmd = [
            "docker", "run", "--rm",
            "-v", f"{repo_root / 'main'}:{container_repo}:rw",
            "-v", f"{input_parent}:/input:ro",
            "-v", f"{outdir}:{container_repo}/outputs:rw",
        ]

        # Add extra mounts for databases
        for host_path, container_path in extra_mounts:
            cmd.extend(["-v", f"{host_path}:{container_path}:ro"])

        cmd.extend([
            "-w", container_repo,
            docker_image,
            # Use stdbuf to force line-buffered output for real-time log streaming
            # This ensures all pipelines stream logs like lr_meta does
            "stdbuf", "-oL", "-eL",
            "bash", container_script,
            "--config", f"{container_repo}/outputs/{container_run_id}/docker_config.json"
        ])

        if config.verbose:
            print(f"Running in Docker container: {Colors.cyan_bold(docker_image)}")

        # Create logs directory for Docker output
        docker_log_dir = run_dir / "logs"
        docker_log_dir.mkdir(parents=True, exist_ok=True)
        docker_log_path = docker_log_dir / f"docker_{config.pipeline}.log"

        print(f"{Colors.dim('Log:')} {docker_log_path}")
        print()
        print(f"{Colors.yellow_bold('▶ Running pipeline...')}")
        print(Colors.dim("─" * 60))

        # Start watching the pipeline's internal logs directory for real-time streaming
        # This catches output from pipelines (like sr_amp) that redirect to log files
        pipeline_internal_logs = run_dir / config.pipeline / "logs"
        pipeline_internal_logs.mkdir(parents=True, exist_ok=True)
        log_watcher = LogDirectoryWatcher(
            pipeline_internal_logs,
            config.pipeline,
            verbose=config.verbose,
        )
        log_watcher.start()

        try:
            # Run with live streaming to both file and console
            # normalize_logs=True converts sr_meta/sr_amp style logs to lr_meta reference format
            exit_code = run_with_streaming(
                cmd,
                docker_log_path,
                env=env,
                verbose=config.verbose,
                prefix=f"[{config.pipeline}] ",
                pipeline=config.pipeline,
                normalize_logs=True,
            )
        finally:
            # Stop the log watcher
            log_watcher.stop()

        print(Colors.dim("─" * 60))
    else:
        # Run locally without container
        env["STAMINA_BIOME_SKIP_CONTAINER"] = "1"

        # Use stdbuf to force line-buffered output for real-time log streaming
        # This ensures all pipelines stream logs like lr_meta does
        base_cmd = [str(runner_script), "--config", str(config_path)]
        cmd = wrap_cmd_for_unbuffered(base_cmd)

        # Create logs directory for pipeline output
        pipeline_log_dir = run_dir / "logs"
        pipeline_log_dir.mkdir(parents=True, exist_ok=True)
        pipeline_log_path = pipeline_log_dir / f"{config.pipeline}.log"

        print(f"{Colors.dim('Log:')} {pipeline_log_path}")
        print()
        print(f"{Colors.yellow_bold('▶ Running pipeline...')}")
        print(Colors.dim("─" * 60))

        # Start watching the pipeline's internal logs directory for real-time streaming
        # This catches output from pipelines (like sr_amp) that redirect to log files
        pipeline_internal_logs = run_dir / config.pipeline / "logs"
        pipeline_internal_logs.mkdir(parents=True, exist_ok=True)
        log_watcher = LogDirectoryWatcher(
            pipeline_internal_logs,
            config.pipeline,
            verbose=config.verbose,
        )
        log_watcher.start()

        try:
            # Run with live streaming to both file and console
            # normalize_logs=True converts sr_meta/sr_amp style logs to lr_meta reference format
            exit_code = run_with_streaming(
                cmd,
                pipeline_log_path,
                env=env,
                cwd=str(repo_root / "main"),
                verbose=config.verbose,
                prefix=f"[{config.pipeline}] ",
                pipeline=config.pipeline,
                normalize_logs=True,
            )
        finally:
            # Stop the log watcher
            log_watcher.stop()

        print(Colors.dim("─" * 60))

    # Fail-fast: Check for expected outputs

    # Helper to print failure debug info
    def print_failure_info(reason: str) -> None:
        print()
        print(f"{Colors.red_bold('✗ ERROR')}: {reason}")
        print()
        print(f"{Colors.dim('Debug info:')}")
        print(f"  Run directory:  {run_dir}")
        print(f"  Pipeline log:   {run_dir}/logs/{config.pipeline}.log")
        print(f"  Module log:     {run_dir}/{config.pipeline}/logs/pipeline.log")
        print(f"  Config:         {config_path}")
        print()

        # Show tail of log if it exists
        pipeline_log = run_dir / "logs" / f"{config.pipeline}.log"
        if pipeline_log.exists():
            try:
                content = pipeline_log.read_text()
                lines = content.strip().split("\n")
                if lines:
                    print(f"{Colors.dim('Last 10 lines of log:')}")
                    for line in lines[-10:]:
                        print(f"  {Colors.dim(line)}")
            except Exception:
                pass

    if exit_code != 0:
        print_failure_info(f"Pipeline exited with code {exit_code}")
        return exit_code

    # Validate that module actually produced outputs
    module_dir = run_dir / config.pipeline
    logs_dir = module_dir / "logs"
    results_dir = module_dir / "results"

    # Check if module directory exists
    if not module_dir.exists():
        print_failure_info("Module directory not created - pipeline may have failed silently")
        return 1

    # Check for steps.json (modern) or pipeline.log (legacy)
    steps_json = module_dir / "steps.json"
    pipeline_log = logs_dir / "pipeline.log"

    if not steps_json.exists() and not pipeline_log.exists():
        print_failure_info(f"No steps.json or pipeline.log found - module may not have started")
        return 1

    # Check steps.json for failed steps if it exists
    if steps_json.exists():
        try:
            steps = json.loads(steps_json.read_text())
            failed_steps = [s for s in steps if s.get("status") == "failed"]
            if failed_steps:
                step_name = failed_steps[0].get("step", "unknown")
                step_msg = failed_steps[0].get("message", "no details")
                print_failure_info(f"Step '{step_name}' failed: {step_msg}")
                return 1
        except Exception as e:
            print(f"[stamina-biome] WARNING: Could not parse steps.json: {e}")

    # Pipeline-aware validation
    validation_result = validate_pipeline_outputs(config.pipeline, run_dir, module_dir)

    if not validation_result["success"]:
        print(f"[stamina-biome] ERROR: {validation_result['error']}")
        print(f"[stamina-biome]")
        if validation_result.get("steps_info"):
            # Check if all steps show OK but we still failed (output validation caught it)
            all_steps_ok = all("[OK]" in s or "[SKIPPED]" in s for s in validation_result["steps_info"])
            if all_steps_ok:
                print(f"[stamina-biome] NOTE: Module reported all steps succeeded, but output validation")
                print(f"[stamina-biome]       detected critical errors. Check logs for details.")
                print(f"[stamina-biome]")
            print(f"[stamina-biome] Steps status (from module):")
            for step_info in validation_result["steps_info"]:
                print(f"[stamina-biome]   {step_info}")
            print(f"[stamina-biome]")
        if validation_result.get("common_causes"):
            print(f"[stamina-biome] Common causes for {config.pipeline}:")
            for cause in validation_result["common_causes"]:
                print(f"[stamina-biome]   - {cause}")
            print(f"[stamina-biome]")

        # Show missing tools warnings even on failure
        if validation_result.get("warnings"):
            missing_tools = [w for w in validation_result["warnings"]
                           if "disabled" in w.lower() or "skipped" in w.lower() or "not available" in w.lower()]
            if missing_tools:
                print(f"[stamina-biome] Missing optional tools:")
                for warning in missing_tools:
                    print(f"[stamina-biome]   - {warning}")
                print(f"[stamina-biome]")

        print(f"[stamina-biome] Debug info:")
        print(f"[stamina-biome]   Run directory:  {run_dir}")
        print(f"[stamina-biome]   Module dir:     {module_dir}")
        print(f"[stamina-biome]   Pipeline log:   {pipeline_log}")
        return 1

    print()
    print(f"{Colors.green_bold('✓ Pipeline completed successfully')}")
    print(f"  {Colors.dim('Results:')} {run_dir}")
    if validation_result.get("output_files"):
        print(f"  {Colors.dim('Output files:')} {len(validation_result['output_files'])}")
    if validation_result.get("warnings"):
        for warning in validation_result["warnings"]:
            print(f"  {Colors.yellow_bold('Warning:')} {warning}")

    # Run postprocessing if enabled
    if config.postprocess:
        print()
        print(Colors.dim("─" * 60))
        print(f"{Colors.yellow_bold('▶ Postprocessing...')}")
        print(Colors.dim("─" * 60))

        postprocess_exit = run_postprocess(
            config.pipeline,
            run_dir,
            config_path,
            repo_root,
            verbose=config.verbose,
        )

        print(Colors.dim("─" * 60))

        if postprocess_exit != 0:
            print(f"{Colors.yellow_bold('⚠ Postprocessing completed with exit code')} {postprocess_exit}")
        else:
            print(f"{Colors.green_bold('✓ Postprocessing completed')}")

        # Check for results directory created by postprocess
        results_dir = run_dir / "results"
        if results_dir.exists():
            results_manifest = results_dir / "manifest.json"
            if results_manifest.exists():
                try:
                    manifest = json.loads(results_manifest.read_text())
                    summary = manifest.get("summary", {})
                    plots = summary.get('plots_count', 0)
                    tables = summary.get('tables_count', 0)
                    valencia = summary.get('valencia_count', 0)
                    qc = summary.get('qc_count', 0)
                    output_parts = [f"{plots} plots", f"{tables} tables", f"{valencia} valencia"]
                    if qc > 0:
                        output_parts.append(f"{qc} qc")
                    print(f"  {Colors.dim('Outputs:')} {', '.join(output_parts)}")
                except Exception:
                    pass

    # Show warnings summary if there were missing tools or other issues
    if validation_result.get("warnings"):
        missing_tool_warnings = [w for w in validation_result["warnings"] if "disabled" in w.lower() or "skipped" in w.lower()]
        if missing_tool_warnings:
            print()
            print(Colors.dim("─" * 60))
            print(f"{Colors.yellow_bold('⚠ Optional tools not configured:')}")
            for warning in missing_tool_warnings:
                print(f"  {Colors.dim('•')} {warning}")
            print(Colors.dim("─" * 60))

    # Final summary
    print()
    print(Colors.dim("═" * 60))
    print(f"{Colors.green_bold('✓ All done!')}")
    print(f"  {Colors.dim('Results directory:')} {run_dir}")
    print(Colors.dim("═" * 60))

    return exit_code


def validate_pipeline_outputs(pipeline: str, run_dir: Path, module_dir: Path) -> Dict[str, Any]:
    """
    Pipeline-aware output validation.
    Returns dict with: success, error, steps_info, common_causes, output_files, warnings
    """
    results_dir = module_dir / "results"
    final_dir = module_dir / "final"
    steps_json = module_dir / "steps.json"

    result: Dict[str, Any] = {
        "success": False,
        "error": "",
        "steps_info": [],
        "common_causes": [],
        "output_files": [],
        "warnings": [],
    }

    # Parse steps.json for status info
    steps = []
    if steps_json.exists():
        try:
            steps = json.loads(steps_json.read_text())
            for step in steps:
                status = step.get("status", "unknown")
                name = step.get("step", "unknown")
                msg = step.get("message", "")
                if status == "skipped":
                    result["steps_info"].append(f"[SKIPPED] {name}: {msg}")
                elif status == "failed":
                    result["steps_info"].append(f"[FAILED] {name}: {msg}")
                elif status == "succeeded":
                    result["steps_info"].append(f"[OK] {name}")
        except Exception:
            pass

    # Pipeline-specific validation
    if pipeline == "sr_amp":
        # sr_amp uses QIIME2 with DADA2 for amplicon sequencing
        # Check for QIIME2 output files (QZA/QZV artifacts)
        qiime2_dir = results_dir / "qiime2"
        qiime2_artifacts = []
        if qiime2_dir.exists():
            qiime2_artifacts = list(qiime2_dir.rglob("*.qza")) + list(qiime2_dir.rglob("*.qzv"))
        final_tables = list((final_dir / "tables").glob("*")) if (final_dir / "tables").exists() else []

        # Also check for any results files (MultiQC, etc.)
        multiqc_reports = list((results_dir / "multiqc").glob("*.html")) if (results_dir / "multiqc").exists() else []

        if qiime2_artifacts or final_tables:
            result["success"] = True
            result["output_files"] = [str(f.name) for f in qiime2_artifacts[:10] + final_tables]
        else:
            # Check steps for specific issues
            skipped_steps = [s for s in steps if s.get("status") == "skipped"]
            failed_steps = [s for s in steps if s.get("status") == "failed"]

            # Check if QIIME2 was skipped due to Docker-in-Docker issues
            qiime2_skipped = [s for s in skipped_steps if "qiime2" in s.get("step", "").lower()]
            docker_dind_issue = any("docker CLI not available" in s.get("message", "") for s in qiime2_skipped)

            if docker_dind_issue:
                result["error"] = "QIIME2 step skipped: Docker-in-Docker not available"
                result["common_causes"] = [
                    "sr_amp requires Docker socket access to run QIIME2 container",
                    "Run with Docker socket mount: -v /var/run/docker.sock:/var/run/docker.sock",
                    "Or run sr_amp outside container with --no-container flag",
                ]
                # If QC steps succeeded, show partial results
                if multiqc_reports:
                    result["warnings"] = [f"QC completed: {len(multiqc_reports)} MultiQC report(s) generated"]
            elif failed_steps:
                result["error"] = f"QIIME2 pipeline failed at step: {failed_steps[0].get('step', 'unknown')}"
                result["common_causes"] = [
                    f"Step failure: {failed_steps[0].get('message', 'no details')}",
                    "Check qiime2.log for detailed error messages",
                    "QIIME2 classifier may not be available at configured path",
                ]
            else:
                result["error"] = "No QIIME2 output files found"
                result["common_causes"] = [
                    "QIIME2 Docker image may have failed to run",
                    "Input FASTQ file not accessible inside container",
                    "Check logs/qiime2.log for errors",
                ]

    elif pipeline == "sr_meta":
        # sr_meta uses Kraken2/Bracken - check multiple output formats
        kreports = list(results_dir.rglob("*.kreport")) if results_dir.exists() else []
        breports = list(results_dir.rglob("*.breport")) if results_dir.exists() else []
        # Also check for .report.tsv and .kraken.tsv (alternate naming)
        report_tsvs = list(results_dir.rglob("*.report.tsv")) if results_dir.exists() else []
        kraken_tsvs = list(results_dir.rglob("*.kraken.tsv")) if results_dir.exists() else []

        all_outputs = kreports + breports + report_tsvs + kraken_tsvs

        # Check if kreports actually have data
        kreports_with_data = []
        total_sequences = 0
        for kreport in kreports + report_tsvs:
            has_data, seq_count = check_kreport_has_data(kreport)
            if has_data:
                kreports_with_data.append(kreport)
            total_sequences += seq_count

        # Scan log for critical errors
        docker_log = run_dir / "logs" / f"docker_{pipeline}.log"
        log_issues = scan_log_for_issues(docker_log)

        if log_issues["critical_errors"]:
            result["success"] = False
            first_error = log_issues["critical_errors"][0]
            result["error"] = f"Critical error during pipeline: {first_error[2]}"
            result["common_causes"] = [
                f"Log line {first_error[0]}: {first_error[1][:100]}",
                "Check logs for detailed error messages",
            ]
        elif all_outputs and kreports_with_data:
            result["success"] = True
            result["output_files"] = [str(f.name) for f in all_outputs]
            if total_sequences > 0:
                result["warnings"].append(f"Processed {total_sequences} sequences")
        elif all_outputs and not kreports_with_data:
            result["success"] = False
            result["error"] = "Kraken2 processed 0 sequences - output files are empty"
            result["common_causes"] = [
                "Host depletion may have removed all reads",
                "Input FASTQ files may be empty or inaccessible",
                "Check fastp/host_depletion step outputs",
            ]
        else:
            result["error"] = "No Kraken2/Bracken output files found"
            result["common_causes"] = [
                "Kraken2 database not configured (tools.kraken2.db)",
                "Bracken database not available",
                "Input files not accessible in container",
            ]

        # Add warnings for missing tools
        if log_issues["missing_tools"]:
            for tool_name, suggestion in log_issues["missing_tools"]:
                result["warnings"].append(f"{tool_name}: {suggestion}")

    elif pipeline == "lr_amp":
        # lr_amp uses Emu or Kraken2 - check multiple output formats
        emu_files = list(results_dir.rglob("*_rel-abundance.tsv")) if results_dir.exists() else []
        kreports = list(results_dir.rglob("*.kreport")) if results_dir.exists() else []
        report_tsvs = list(results_dir.rglob("*.report.tsv")) if results_dir.exists() else []

        all_outputs = emu_files + kreports + report_tsvs
        if all_outputs:
            result["success"] = True
            result["output_files"] = [str(f.name) for f in all_outputs]
        else:
            result["error"] = "No Emu or Kraken2 output files found"
            result["common_causes"] = [
                "Emu database not configured or accessible",
                "Kraken2 database not configured",
                "Input FASTQ not accessible in container",
            ]

    elif pipeline == "lr_meta":
        # lr_meta uses Kraken2 - check multiple output formats
        kreports = list(results_dir.rglob("*.kreport")) if results_dir.exists() else []
        report_tsvs = list(results_dir.rglob("*.report.tsv")) if results_dir.exists() else []
        kraken_tsvs = list(results_dir.rglob("*.kraken.tsv")) if results_dir.exists() else []

        all_outputs = kreports + report_tsvs + kraken_tsvs

        # Check if kreports actually have data (not just empty files from 0-sequence runs)
        kreports_with_data = []
        total_sequences = 0
        for kreport in kreports:
            has_data, seq_count = check_kreport_has_data(kreport)
            if has_data:
                kreports_with_data.append(kreport)
            total_sequences += seq_count

        # Check nonhuman fastq files - if all are empty, host depletion removed everything
        nonhuman_dir = results_dir / "nonhuman"
        nonhuman_fastqs = list(nonhuman_dir.rglob("*.fastq.gz")) if nonhuman_dir.exists() else []
        nonempty_nonhuman = [f for f in nonhuman_fastqs if check_fastq_gz_not_empty(f)]

        # Scan log for critical errors and missing tools
        logs_dir = module_dir / "logs"
        docker_log = run_dir / "logs" / f"docker_{pipeline}.log"
        log_issues = scan_log_for_issues(docker_log)

        # Check for critical errors in log
        if log_issues["critical_errors"]:
            # Even if files exist, critical errors mean failure
            result["success"] = False
            first_error = log_issues["critical_errors"][0]
            result["error"] = f"Critical error during pipeline: {first_error[2]}"
            result["common_causes"] = [
                f"Log line {first_error[0]}: {first_error[1][:100]}...",
                "Input files may not be accessible at expected paths inside container",
                "Check docker_config.json for correct path mappings",
            ]
            if log_issues["zero_read_steps"]:
                result["common_causes"].append(
                    f"Steps with 0 reads: {', '.join(log_issues['zero_read_steps'][:5])}"
                )
        elif all_outputs and kreports_with_data:
            # Files exist AND have data - true success
            result["success"] = True
            result["output_files"] = [str(f.name) for f in all_outputs]
            if total_sequences > 0:
                result["warnings"].append(f"Processed {total_sequences} sequences across all samples")
        elif all_outputs and not kreports_with_data:
            # Files exist but are empty - false success!
            result["success"] = False
            result["error"] = "Kraken2 processed 0 sequences - kreport files are empty"
            result["common_causes"] = [
                "Host depletion removed ALL reads (check nonhuman/*.fastq.gz sizes)",
                "Input FASTQ files may be in wrong format or location",
                "Check logs for 'ERROR: failed to open file' messages",
            ]
            if nonhuman_fastqs and not nonempty_nonhuman:
                result["common_causes"].insert(0,
                    f"All {len(nonhuman_fastqs)} nonhuman.fastq.gz files are empty (<50 bytes)")
        elif nonhuman_fastqs and not nonempty_nonhuman:
            # No kreports AND empty nonhuman fastqs
            result["success"] = False
            result["error"] = "Host depletion produced empty outputs - no reads survived"
            result["common_causes"] = [
                "All reads were classified as human and removed",
                "Input files may not have been accessible during alignment",
                "Check minimap2 alignment logs for 'ERROR: failed to open file'",
            ]
        else:
            result["error"] = "No Kraken2 output files found"
            result["common_causes"] = [
                "Kraken2 database not configured (tools.kraken2.db)",
                "Input files not accessible in container",
            ]

        # Add warnings for missing optional tools
        if log_issues["missing_tools"]:
            for tool_name, suggestion in log_issues["missing_tools"]:
                result["warnings"].append(f"{tool_name}: {suggestion}")

    else:
        # Generic validation for unknown pipelines
        all_files = list(results_dir.rglob("*")) if results_dir.exists() else []
        all_files = [f for f in all_files if f.is_file()]

        if all_files:
            result["success"] = True
            result["output_files"] = [str(f.name) for f in all_files[:10]]
        else:
            result["error"] = "No output files found in results directory"
            result["common_causes"] = [
                "Pipeline may have failed",
                "Check logs for errors",
            ]

    return result


def print_dry_run(
    config: RunConfig, config_dict: Dict[str, Any], repo_root: Path
) -> None:
    """Print what would be executed in dry-run mode."""
    print("=" * 70)
    print("DRY RUN - No pipeline will be executed")
    print("=" * 70)
    print()
    print("Resolved settings:")
    print(f"  Pipeline:       {config.pipeline}")

    # Display input(s)
    if len(config.input_paths) == 1:
        print(f"  Input:          {config.input_paths[0]}")
    else:
        print(f"  Input:          {len(config.input_paths)} files")
        for p in config.input_paths[:5]:
            print(f"                  - {p}")
        if len(config.input_paths) > 5:
            print(f"                  ... and {len(config.input_paths) - 5} more")

    print(f"  Output dir:     {config.outdir}")
    print(f"  Run ID:         {config_dict['run']['run_id']}")
    print(f"  Threads:        {config.threads}")
    print(f"  Technology:     {config_dict['technology']}")
    print(f"  Input style:    {config_dict['input']['style']}")
    print(f"  Sample type:    {config.sample_type}")
    print(f"  Postprocess:    {'enabled' if config.postprocess else 'disabled'}")
    print(f"  Finalize:       {'enabled' if config.finalize else 'disabled'}")
    print(f"  Container:      {'enabled' if config.use_container else 'disabled'}")
    print()
    print("Pipeline info:")
    info = get_pipeline_info(config.pipeline, repo_root)
    if info:
        print(f"  Label:          {info.get('label', 'N/A')}")
        print(f"  Read type:      {info.get('read_technology', 'N/A')}")
        print(f"  Approach:       {info.get('approach', 'N/A')}")

    # QC Tools Readiness Report
    print()
    print("=" * 70)
    print("QC TOOLS READINESS")
    print("=" * 70)

    qc_status = check_qc_tools(config_dict, repo_root)

    # FastQC status
    fastqc = qc_status["fastqc"]
    if fastqc["available"]:
        print(f"  FastQC:  FOUND")
        print(f"    Path:   {fastqc['path']}")
        print(f"    Source: {fastqc['source']}")
    else:
        print(f"  FastQC:  MISSING")
        print(f"    Reason: {fastqc['reason']}")
        print(f"    Fix:    Install fastqc, or set tools.fastqc_bin in config,")
        print(f"            or create Docker wrapper at main/tools/wrappers/fastqc")

    print()

    # MultiQC status
    multiqc = qc_status["multiqc"]
    if multiqc["available"]:
        print(f"  MultiQC: FOUND")
        print(f"    Path:   {multiqc['path']}")
        print(f"    Source: {multiqc['source']}")
    else:
        print(f"  MultiQC: MISSING")
        print(f"    Reason: {multiqc['reason']}")
        print(f"    Fix:    Install multiqc, or set tools.multiqc_bin in config,")
        print(f"            or create Docker wrapper at main/tools/wrappers/multiqc")

    # Pipeline-specific tool check for sr_meta (fastp)
    if config.pipeline == "sr_meta":
        print()
        print("  Pipeline-specific tools (sr_meta):")
        fastp_result = subprocess.run(["which", "fastp"], capture_output=True, text=True)
        if fastp_result.returncode == 0:
            print(f"  fastp:   FOUND at {fastp_result.stdout.strip()}")
        elif config.use_container:
            print(f"  fastp:   Will use container (stamina-biome-sr has fastp installed)")
        else:
            print(f"  fastp:   MISSING (required for sr_meta read trimming)")
            print(f"    Fix:    Install fastp: conda install -c bioconda fastp")
            print(f"            Or run with container mode (remove --no-container)")

    # Execution environment
    print()
    use_container = config.use_container

    # Check Docker image availability for container mode
    container_image = None
    image_status = ""
    if use_container and not pipeline_spawns_containers(config.pipeline):
        try:
            container_image, selection_reason = select_docker_image(
                pipeline=config.pipeline,
                override_image=config.docker_image,
                verbose=False,  # Don't print here, we'll show in the summary
            )
            image_status = f"FOUND ({selection_reason})"
        except RunnerError as e:
            # Image not found - show what's available
            pipeline_type = "sr" if config.pipeline.startswith("sr_") else "lr"
            default_image = DEFAULT_IMAGES[pipeline_type]
            container_image = default_image
            image_status = "NOT FOUND"

    if pipeline_spawns_containers(config.pipeline):
        print(f"  Execution: HOST (Model A - {config.pipeline} spawns containers)")
        print(f"    QC tools checked on: HOST environment")
    elif use_container:
        print(f"  Execution: CONTAINER")
        print(f"    Image: {container_image}")
        print(f"    Status: {image_status}")
        if "NOT FOUND" in image_status:
            pipeline_type = "sr" if config.pipeline.startswith("sr_") else "lr"
            local_alts = find_matching_local_images(pipeline_type)
            if local_alts:
                print(f"    Available alternatives:")
                for alt in local_alts[:5]:
                    print(f"      - {alt}")
                print(f"    Use --image <tag> to specify one")
            else:
                print(f"    No local {pipeline_type.upper()} images found.")
                print(f"    Build with: docker build -f main/pipelines/container/dockerfile.{pipeline_type} -t {container_image} main/pipelines/container/")
        print(f"    QC tools checked on: HOST environment (should be container)")
    else:
        print(f"  Execution: HOST (--no-container)")
        print(f"    QC tools checked on: HOST environment")

    # Planned QC commands
    print()
    print("  Planned QC Commands (early pipeline steps):")
    run_id = config_dict['run']['run_id']
    outdir = Path(config.outdir).resolve()
    run_dir = outdir / run_id

    input_style = config_dict.get("input", {}).get("style", "FASTQ_SINGLE")
    if input_style == "FASTQ_PAIRED":
        r1 = config_dict.get("input", {}).get("fastq_r1", "")
        r2 = config_dict.get("input", {}).get("fastq_r2", "")
        fastqc_cmd = f"fastqc -o {run_dir}/{config.pipeline}/results/fastqc {r1} {r2}"
    else:
        r1 = config_dict.get("input", {}).get("fastq_r1", config_dict.get("input", {}).get("fastq", ""))
        fastqc_cmd = f"fastqc -o {run_dir}/{config.pipeline}/results/fastqc {r1}"

    multiqc_cmd = f"multiqc -o {run_dir}/{config.pipeline}/results/multiqc {run_dir}/{config.pipeline}/results"

    if fastqc["available"]:
        print(f"    1. FastQC: {fastqc_cmd}")
    else:
        print(f"    1. FastQC: WILL BE SKIPPED (tool not available)")

    if multiqc["available"]:
        print(f"    2. MultiQC: {multiqc_cmd}")
    else:
        print(f"    2. MultiQC: WILL BE SKIPPED (tool not available)")

    print("=" * 70)

    # Valencia and Postprocess Plan
    print()
    print("Postprocess Plan:")
    print("-" * 70)
    pp_cfg = config_dict.get("postprocess", {})
    valencia_cfg = config_dict.get("valencia", {})
    is_vaginal = config.sample_type.lower() in ("vaginal", "vaginal_swab", "vagina")
    valencia_enabled = valencia_cfg.get("enabled", 0) == 1

    print(f"  Postprocess enabled: {'YES' if pp_cfg.get('enabled') else 'NO'}")
    print(f"  Sample type:         {config.sample_type} {'(vaginal - triggers Valencia)' if is_vaginal else ''}")
    print(f"  Valencia enabled:    {'YES' if valencia_enabled else 'NO'}")

    if valencia_enabled:
        print()
        print("  Valencia CST Analysis:")
        print(f"    - Will run:        YES (sample_type={config.sample_type})")
        print(f"    - Centroids file:  {valencia_cfg.get('centroids_csv', 'default')}")
        print()
        print("  Expected Valencia outputs:")
        outdir = Path(config.outdir).resolve()
        run_id = config_dict['run']['run_id']
        print(f"    - Tables:          {outdir}/{run_id}/final_results/valencia/cst_assignments.tsv")
        print(f"    - Plot:            {outdir}/{run_id}/final_results/valencia/valencia_cst.png")
    else:
        if not is_vaginal:
            print(f"  Valencia reason:     sample_type '{config.sample_type}' is not vaginal")
        else:
            print(f"  Valencia reason:     explicitly disabled")

    if pp_cfg.get("enabled"):
        print()
        print("  Expected standard outputs:")
        outdir = Path(config.outdir).resolve()
        run_id = config_dict['run']['run_id']
        print(f"    - Plots dir:       {outdir}/{run_id}/final_results/plots/")
        print(f"    - Tables dir:      {outdir}/{run_id}/final_results/tables/")
        print(f"    - Manifest:        {outdir}/{run_id}/final_results/run_manifest.json")
        print()
        print("  Plots to generate:")
        steps = pp_cfg.get("steps", {})
        for step in ["heatmap", "piechart", "relative_abundance", "stacked_bar"]:
            status = "YES" if steps.get(step) else "NO"
            print(f"    - {step}.png:  {status}")
        print()
        print("  Tables to generate:")
        print(f"    - primary_taxonomy.tsv:  YES (if taxonomy data available)")
        print(f"    - qc_summary.tsv:        {'YES' if steps.get('results_csv') else 'NO'}")
        print(f"    - concordance.tsv:       YES")

    print("-" * 70)
    print()
    print("Generated config (JSON):")
    print("-" * 70)
    print(json.dumps(config_dict, indent=2))
    print("-" * 70)
    print()
    print("Command that would run:")
    runner_script = get_runner_script(repo_root, config.pipeline)
    outdir = Path(config.outdir).resolve()
    config_path = outdir / "stamina_biome_configs" / f"{config.pipeline}_cli.json"
    cmd = f"{runner_script} --config {config_path}"
    if config.force_overwrite:
        cmd += " --force-overwrite"
    if config.verbose:
        cmd += " --debug"
    print(f"  {cmd}")
    print()
