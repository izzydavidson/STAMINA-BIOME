"""Discovery utilities for finding pipelines and repository structure."""

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


# Pipeline definitions with metadata
PIPELINE_INFO = {
    "sr_amp": {
        "label": "Short-Read Amplicon (16S)",
        "read_technology": "short",
        "approach": "amplicon",
        "description": "Illumina, IonTorrent and BGI systems amplicon sequencing pipeline using QIIME2/DADA2",
        # sr_amp spawns QIIME2 containers - must run on host to access Docker daemon
        "spawns_containers": True,
        "container_images": ["quay.io/qiime2/amplicon:2024.10"],
    },
    "sr_meta": {
        "label": "Short-Read Metagenomics",
        "read_technology": "short",
        "approach": "metagenomics",
        "description": "Illumina, IonTorrent and BGI systems shotgun metagenomics pipeline using Kraken2",
        "spawns_containers": False,
    },
    "lr_amp": {
        "label": "Long-Read Amplicon (Full-length 16S or Partial 16S)",
        "read_technology": "long",
        "approach": "amplicon",
        "description": "ONT/PacBio full-length 16S or Partial Amplicon sequencing module. Full-length ONT reads use Emu, PacBio and partial 16S utilises Kraken2",
        "spawns_containers": False,
    },
    "lr_meta": {
        "label": "Long-Read Metagenomics",
        "read_technology": "long",
        "approach": "metagenomics",
        "description": "ONT/PacBio shotgun metagenomics pipeline",
        "spawns_containers": False,
    },
}


def pipeline_spawns_containers(pipeline_id: str) -> bool:
    """Check if a pipeline spawns external containers (e.g., QIIME2)."""
    info = PIPELINE_INFO.get(pipeline_id, {})
    return info.get("spawns_containers", False)


def get_pipeline_container_images(pipeline_id: str) -> List[str]:
    """Get list of container images a pipeline may spawn."""
    info = PIPELINE_INFO.get(pipeline_id, {})
    return info.get("container_images", [])


def find_repo_root(start_path: Optional[Path] = None) -> Path:
    """
    Find the repository root directory by looking for marker files/directories.

    Searches upward from start_path (or cwd) for directories containing
    known project markers like 'main', 'cli', etc.

    For PyInstaller bundles, returns the directory containing the executable
    where bundled resources (pipelines, configs, etc.) are located.
    """
    # Check for environment variable override (used by wrapper scripts)
    import os
    if 'STAMINA_BIOME_REPO_ROOT' in os.environ:
        repo_root = Path(os.environ['STAMINA_BIOME_REPO_ROOT']).resolve()
        if repo_root.exists():
            return repo_root

    # Check if running as PyInstaller bundle
    if getattr(sys, 'frozen', False):
        # When frozen, sys.executable is the path to the binary
        # The binary and resources are in the same directory
        bundle_dir = Path(sys.executable).parent
        # Check if this looks like our bundle (has main/ with pipelines)
        if (bundle_dir / "main" / "pipelines").exists():
            return bundle_dir
        # PyInstaller 6.x puts data files in _internal/
        if (bundle_dir / "_internal" / "main" / "pipelines").exists():
            return bundle_dir / "_internal"
        # Also check if main is directly here (flat structure)
        if (bundle_dir / "pipelines").exists():
            # Return parent to simulate repo structure
            return bundle_dir

    if start_path is None:
        start_path = Path.cwd()

    start_path = Path(start_path).resolve()

    # If we're already in the repo root
    markers = ["main", "cli"]

    current = start_path
    for _ in range(10):  # Limit search depth
        # Check if this directory has the expected structure
        has_markers = all((current / m).exists() for m in markers)
        if has_markers:
            return current

        # Check if main is a subdirectory indicator
        if (current / "main").exists() and (current / "main" / "pipelines").exists():
            return current

        # Move up one directory
        parent = current.parent
        if parent == current:  # Reached filesystem root
            break
        current = parent

    # Fallback: try to infer from known paths
    # If we're somewhere in the cli directory
    if "cli" in str(start_path):
        parts = start_path.parts
        for i, part in enumerate(parts):
            if part == "cli":
                return Path(*parts[:i])

    # If we're somewhere in the main directory
    if "main" in str(start_path):
        parts = start_path.parts
        for i, part in enumerate(parts):
            if part == "main":
                return Path(*parts[:i])

    # Last resort: return current working directory
    return Path.cwd()


def get_main_root(repo_root: Optional[Path] = None) -> Path:
    """Get the main directory path."""
    if repo_root is None:
        repo_root = find_repo_root()
    return repo_root / "main"


def list_pipeline_ids(repo_root: Optional[Path] = None) -> List[str]:
    """List all available pipeline IDs."""
    return list(PIPELINE_INFO.keys())


def validate_pipeline_id(pipeline_id: str, repo_root: Optional[Path] = None) -> bool:
    """Check if a pipeline ID is valid."""
    return pipeline_id in PIPELINE_INFO


def get_pipeline_info(pipeline_id: str, repo_root: Optional[Path] = None) -> Optional[Dict[str, Any]]:
    """Get metadata for a pipeline."""
    return PIPELINE_INFO.get(pipeline_id)


def get_runner_script(repo_root: Optional[Path] = None, pipeline_id: str = "lr_amp") -> Path:
    """
    Get the path to the runner script for a specific pipeline.

    Returns the path to the pipeline module script for the specified pipeline.
    """
    if repo_root is None:
        repo_root = find_repo_root()

    # The runner script is the pipeline module itself
    return repo_root / "main" / "pipelines" / "modules" / f"{pipeline_id}.sh"


def get_pipeline_script(pipeline_id: str, repo_root: Optional[Path] = None) -> Optional[Path]:
    """Get the path to a specific pipeline's script."""
    if repo_root is None:
        repo_root = find_repo_root()

    if not validate_pipeline_id(pipeline_id):
        return None

    script_path = repo_root / "main" / "pipelines" / "modules" / f"{pipeline_id}.sh"
    if script_path.exists():
        return script_path
    return None


def get_config_dir(repo_root: Optional[Path] = None) -> Path:
    """Get the configs directory path."""
    if repo_root is None:
        repo_root = find_repo_root()
    return repo_root / "main" / "configs"


def get_data_dir(repo_root: Optional[Path] = None) -> Path:
    """Get the data directory path."""
    if repo_root is None:
        repo_root = find_repo_root()
    return repo_root / "main" / "data"


def get_tools_dir(repo_root: Optional[Path] = None) -> Path:
    """Get the tools directory path."""
    if repo_root is None:
        repo_root = find_repo_root()
    return repo_root / "main" / "tools"
