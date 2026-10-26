#!/usr/bin/env python3
"""Progress tracking and stage display utilities for STAMINA-BIOME CLI."""

import json
import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, TextIO


def is_tty() -> bool:
    """Check if stdout is a TTY."""
    return hasattr(sys.stdout, 'isatty') and sys.stdout.isatty()


# ANSI color codes
class Colors:
    """ANSI color codes for terminal output."""

    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"

    # Colors
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    PURPLE = "\033[35m"
    CYAN = "\033[36m"
    WHITE = "\033[37m"

    # Bright colors
    BRIGHT_RED = "\033[91m"
    BRIGHT_GREEN = "\033[92m"
    BRIGHT_YELLOW = "\033[93m"
    BRIGHT_BLUE = "\033[94m"
    BRIGHT_PURPLE = "\033[95m"
    BRIGHT_CYAN = "\033[96m"

    # 256-color orange (color 208)
    ORANGE = "\033[38;5;208m"

    @classmethod
    def colorize(cls, text: str, *codes: str) -> str:
        """Apply color codes to text if TTY, otherwise return plain text."""
        if not is_tty():
            return text
        return f"{''.join(codes)}{text}{cls.RESET}"

    @classmethod
    def purple_bold(cls, text: str) -> str:
        return cls.colorize(text, cls.BOLD, cls.BRIGHT_PURPLE)

    @classmethod
    def red_bold(cls, text: str) -> str:
        return cls.colorize(text, cls.BOLD, cls.BRIGHT_RED)

    @classmethod
    def green_bold(cls, text: str) -> str:
        return cls.colorize(text, cls.BOLD, cls.BRIGHT_GREEN)

    @classmethod
    def yellow_bold(cls, text: str) -> str:
        return cls.colorize(text, cls.BOLD, cls.BRIGHT_YELLOW)

    @classmethod
    def cyan_bold(cls, text: str) -> str:
        return cls.colorize(text, cls.BOLD, cls.BRIGHT_CYAN)

    @classmethod
    def orange_bold(cls, text: str) -> str:
        return cls.colorize(text, cls.BOLD, cls.ORANGE)

    @classmethod
    def green(cls, text: str) -> str:
        return cls.colorize(text, cls.GREEN)

    @classmethod
    def dim(cls, text: str) -> str:
        return cls.colorize(text, cls.DIM)


def print_banner():
    """Print the STAMINA-BIOME ASCII banner."""
    border = "#" * 50
    def line(text="", styled=None):
        styled = styled if styled is not None else text
        return "#" + styled + " " * (48 - len(text)) + "#"

    if is_tty():
        # Purple bold banner for TTY
        print()
        print(Colors.purple_bold(border))
        t1 = "    STAMINA-BIOME"
        t2 = " — Pipeline CLI"
        print(Colors.purple_bold("#") + Colors.purple_bold(t1) + Colors.dim(t2) + " " * (48 - len(t1) - len(t2)) + Colors.purple_bold("#"))
        for s in ("    Standardised, Technology-Agnostic Framework", "    for Microbiome Investigation and Analysis"):
            print(Colors.purple_bold("#") + Colors.dim(s) + " " * (48 - len(s)) + Colors.purple_bold("#"))
        print(Colors.purple_bold(border))
        print()
    else:
        # Plain text banner for non-TTY
        print()
        print(border)
        print(line("    STAMINA-BIOME -- Pipeline CLI"))
        print(line("    Standardised, Technology-Agnostic Framework"))
        print(line("    for Microbiome Investigation and Analysis"))
        print(border)
        print()


@dataclass
class Stage:
    """Represents a pipeline stage."""
    name: str
    label: str
    status: str = "pending"  # pending, running, succeeded, failed, skipped
    message: str = ""
    started_at: Optional[datetime] = None
    ended_at: Optional[datetime] = None


@dataclass
class ProgressTracker:
    """Tracks pipeline progress and displays stage updates."""

    pipeline: str
    run_dir: Path
    verbose: bool = False
    stages: List[Stage] = field(default_factory=list)
    current_stage_idx: int = -1
    log_file: Optional[TextIO] = None
    _lock: threading.Lock = field(default_factory=threading.Lock)

    # Known stages per pipeline
    PIPELINE_STAGES = {
        "sr_amp": [
            ("fastqc", "FastQC"),
            ("multiqc", "MultiQC"),
            ("qiime2_import", "QIIME2 Import"),
            ("qiime2_demux_summarize", "QIIME2 Demux"),
            ("qiime2_cutadapt", "Cutadapt Trim"),
            ("qiime2_dada2", "DADA2 Denoise"),
            ("qiime2_taxonomy", "Taxonomy"),
            ("qiime2_diversity", "Diversity"),
            ("qiime2_exports", "Export Results"),
            ("valencia", "Valencia CST"),
            ("postprocess", "Postprocess"),
        ],
        "sr_meta": [
            ("fastqc", "FastQC"),
            ("multiqc", "MultiQC"),
            ("kraken2", "Kraken2"),
            ("bracken", "Bracken"),
            ("valencia", "Valencia CST"),
            ("postprocess", "Postprocess"),
        ],
        "lr_amp": [
            ("basecall", "Basecalling"),
            ("demux", "Demultiplex"),
            ("qc", "Quality Control"),
            ("emu", "Emu Taxonomy"),
            ("valencia", "Valencia CST"),
            ("postprocess", "Postprocess"),
        ],
        "lr_meta": [
            ("basecall", "Basecalling"),
            ("demux", "Demultiplex"),
            ("qc", "Quality Control"),
            ("kraken2", "Kraken2"),
            ("bracken", "Bracken"),
            ("valencia", "Valencia CST"),
            ("postprocess", "Postprocess"),
        ],
    }

    def __post_init__(self):
        """Initialize stages from pipeline definition."""
        stage_defs = self.PIPELINE_STAGES.get(self.pipeline, [])
        self.stages = [Stage(name=name, label=label) for name, label in stage_defs]

    def _format_status_icon(self, status: str) -> str:
        """Get status icon for a stage."""
        icons = {
            "pending": Colors.dim("○"),
            "running": Colors.yellow_bold("●"),
            "succeeded": Colors.green_bold("✓"),
            "failed": Colors.red_bold("✗"),
            "skipped": Colors.dim("−"),
        }
        return icons.get(status, "?")

    def _format_progress_bar(self) -> str:
        """Format a progress bar showing completed stages."""
        total = len(self.stages)
        if total == 0:
            return ""

        completed = sum(1 for s in self.stages if s.status in ("succeeded", "skipped"))
        current = self.current_stage_idx + 1 if self.current_stage_idx >= 0 else 0

        if is_tty():
            bar_width = 20
            filled = int((completed / total) * bar_width)
            bar = Colors.green_bold("█" * filled) + Colors.dim("░" * (bar_width - filled))
            return f"[{bar}] {completed}/{total}"
        else:
            return f"[{completed}/{total}]"

    def print_header(self):
        """Print pipeline header with progress bar."""
        header = f"Pipeline: {Colors.cyan_bold(self.pipeline)}"
        progress = self._format_progress_bar()
        print(f"\n{header}  {progress}")
        print(Colors.dim("─" * 50))

    def print_stage_line(self, stage: Stage, is_current: bool = False):
        """Print a single stage line."""
        icon = self._format_status_icon(stage.status)
        label = stage.label

        if is_current and stage.status == "running":
            label = Colors.yellow_bold(label)
        elif stage.status == "succeeded":
            label = Colors.green_bold(label)
        elif stage.status == "failed":
            label = Colors.red_bold(label)
        elif stage.status == "skipped":
            label = Colors.dim(label)

        line = f"  {icon} {label}"

        if stage.message:
            line += f" {Colors.dim('— ' + stage.message)}"

        print(line)

    def print_all_stages(self):
        """Print all stages with current status."""
        for i, stage in enumerate(self.stages):
            is_current = (i == self.current_stage_idx)
            self.print_stage_line(stage, is_current)

    def start_stage(self, stage_name: str, message: str = ""):
        """Mark a stage as started."""
        with self._lock:
            for i, stage in enumerate(self.stages):
                if stage.name == stage_name:
                    stage.status = "running"
                    stage.message = message
                    stage.started_at = datetime.now()
                    self.current_stage_idx = i

                    if self.verbose:
                        icon = self._format_status_icon("running")
                        print(f"  {icon} {Colors.yellow_bold(stage.label)} {Colors.dim('— ' + message) if message else ''}")
                    break

    def complete_stage(self, stage_name: str, status: str = "succeeded", message: str = ""):
        """Mark a stage as completed."""
        with self._lock:
            for stage in self.stages:
                if stage.name == stage_name:
                    stage.status = status
                    stage.message = message
                    stage.ended_at = datetime.now()

                    if self.verbose:
                        icon = self._format_status_icon(status)
                        label = stage.label
                        if status == "succeeded":
                            label = Colors.green_bold(label)
                        elif status == "failed":
                            label = Colors.red_bold(label)
                        elif status == "skipped":
                            label = Colors.dim(label)
                        print(f"  {icon} {label} {Colors.dim('— ' + message) if message else ''}")
                    break

    def update_from_steps_json(self, steps_json_path: Path):
        """Update stages from steps.json file."""
        if not steps_json_path.exists():
            return

        try:
            with open(steps_json_path, "r") as f:
                steps = json.load(f)

            for step in steps:
                step_name = step.get("step", "")
                status = step.get("status", "")
                message = step.get("message", "")

                # Map steps.json status to our status
                status_map = {
                    "succeeded": "succeeded",
                    "failed": "failed",
                    "skipped": "skipped",
                    "running": "running",
                }

                mapped_status = status_map.get(status, "pending")

                # Find matching stage
                for stage in self.stages:
                    if stage.name == step_name or step_name.startswith(stage.name):
                        if stage.status != mapped_status:
                            stage.status = mapped_status
                            stage.message = message
        except Exception:
            pass

    def log(self, message: str, stage_prefix: str = ""):
        """Log a message to both console and log file."""
        timestamp = datetime.now().strftime("%H:%M:%S")

        if stage_prefix:
            prefix = f"[{timestamp}] [{stage_prefix}] "
        else:
            prefix = f"[{timestamp}] "

        formatted = f"{prefix}{message}"

        # Write to log file if available
        if self.log_file:
            self.log_file.write(formatted + "\n")
            self.log_file.flush()

        # Print to console if verbose
        if self.verbose:
            print(Colors.dim(formatted))


class StageRunner:
    """Runs pipeline stages with progress tracking and log streaming."""

    def __init__(
        self,
        tracker: ProgressTracker,
        log_path: Path,
        verbose: bool = True,
    ):
        self.tracker = tracker
        self.log_path = log_path
        self.verbose = verbose
        self.log_file: Optional[TextIO] = None

    def __enter__(self):
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_file = open(self.log_path, "w", encoding="utf-8")
        self.tracker.log_file = self.log_file
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.log_file:
            self.log_file.close()
            self.tracker.log_file = None

    def run_command(
        self,
        cmd: List[str],
        stage_name: str = "",
        stage_label: str = "",
        env: Optional[Dict[str, str]] = None,
        cwd: Optional[str] = None,
    ) -> int:
        """Run a command with log streaming and progress updates."""

        if stage_name:
            self.tracker.start_stage(stage_name, f"Running {stage_label or stage_name}...")

        # Start process
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=cwd,
            text=True,
            bufsize=1,
        )

        # Stream output
        prefix = f"[{stage_label or stage_name}] " if stage_name else ""

        def stream_output():
            try:
                for line in iter(proc.stdout.readline, ''):
                    if not line:
                        break

                    timestamp = datetime.now().strftime("%H:%M:%S")
                    log_line = f"[{timestamp}] {prefix}{line.rstrip()}"

                    # Write to log file
                    if self.log_file:
                        self.log_file.write(log_line + "\n")
                        self.log_file.flush()

                    # Print to console
                    if self.verbose:
                        if is_tty():
                            print(Colors.dim(log_line))
                        else:
                            print(log_line)
            except Exception:
                pass
            finally:
                if proc.stdout:
                    proc.stdout.close()

        # Run streaming in thread
        stream_thread = threading.Thread(target=stream_output, daemon=True)
        stream_thread.start()

        # Wait for process
        proc.wait()
        stream_thread.join(timeout=5.0)

        # Update stage status
        if stage_name:
            if proc.returncode == 0:
                self.tracker.complete_stage(stage_name, "succeeded", "Completed")
            else:
                self.tracker.complete_stage(stage_name, "failed", f"Exit code {proc.returncode}")

        return proc.returncode


def format_input_detection(
    input_style: str,
    file_count: int = 0,
    pair_count: int = 0,
    unmatched: List[str] = None,
) -> str:
    """Format input detection message for display."""
    unmatched = unmatched or []

    if input_style == "FASTQ_PAIRED":
        msg = f"Detected: {Colors.cyan_bold('FASTQ_PAIRED')} ({pair_count} pair{'s' if pair_count != 1 else ''})"
    elif input_style == "FASTQ_SINGLE":
        msg = f"Detected: {Colors.cyan_bold('FASTQ_SINGLE')} ({file_count} file{'s' if file_count != 1 else ''})"
    elif input_style == "FAST5_DIR":
        msg = f"Detected: {Colors.cyan_bold('FAST5_DIR')} ({file_count} FAST5 file{'s' if file_count != 1 else ''})"
    elif input_style == "FASTQ_DIR":
        msg = f"Detected: {Colors.cyan_bold('FASTQ_DIR')} ({file_count} file{'s' if file_count != 1 else ''})"
    else:
        msg = f"Detected: {Colors.cyan_bold(input_style)}"

    if unmatched:
        msg += f"\n  {Colors.yellow_bold('Warning')}: {len(unmatched)} unmatched file(s) will be skipped"
        for f in unmatched[:3]:
            msg += f"\n    - {f}"
        if len(unmatched) > 3:
            msg += f"\n    ... and {len(unmatched) - 3} more"

    return msg


def print_stage_summary(stages: List[Stage]):
    """Print a summary of stage results."""
    succeeded = sum(1 for s in stages if s.status == "succeeded")
    failed = sum(1 for s in stages if s.status == "failed")
    skipped = sum(1 for s in stages if s.status == "skipped")

    print()
    print(Colors.dim("─" * 50))

    summary = f"Summary: {Colors.green_bold(str(succeeded))} succeeded"
    if skipped:
        summary += f", {Colors.dim(str(skipped))} skipped"
    if failed:
        summary += f", {Colors.red_bold(str(failed))} failed"

    print(summary)
