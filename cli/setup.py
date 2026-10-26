"""Setup and environment validation for STAMINA-BIOME CLI."""

import os
import platform
import shutil
import ssl
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from cli.progress import Colors, is_tty


def build_minimap2_index(fasta_path: Path, output_dir: Path, interactive: bool = True) -> Optional[List[Tuple[str, str]]]:
    """
    Build minimap2 index from FASTA file with user-selected options.

    Returns list of (index_name, index_path) tuples for successful builds, or None if cancelled/failed.
    """
    import gzip

    # Check if minimap2 is available
    if not shutil.which("minimap2"):
        print(f"\n   {Colors.yellow_bold('Warning')}: minimap2 not found in PATH")
        print("   Cannot build indexes. Install minimap2 or provide pre-built .mmi files.")
        return None

    # Decompress if needed
    if fasta_path.suffix == '.gz':
        print(f"\n   Decompressing reference genome...")
        uncompressed = fasta_path.with_suffix('')
        if not uncompressed.exists():
            try:
                with gzip.open(fasta_path, 'rb') as f_in:
                    with open(uncompressed, 'wb') as f_out:
                        shutil.copyfileobj(f_in, f_out)
                print(f"   {Colors.green_bold('OK')} Decompressed to {uncompressed.name}")
            except Exception as e:
                print(f"   {Colors.red_bold('Error')}: Failed to decompress: {e}")
                return None
        fasta_path = uncompressed

    built_indexes = []

    if interactive:
        print(f"\n   {Colors.cyan_bold('Build minimap2 indexes?')}")
        print("   Choose which index types to build:")
        print()
        print("   1. Standard index (fastest, ~6-8GB RAM)")
        print("   2. Low-memory index (moderate, ~4GB RAM)")
        print("   3. Split index 2GB chunks (lowest RAM, use with --minimap2-split-index)")
        print("   4. Split index 4GB chunks (low RAM, use with --minimap2-split-index)")
        print("   5. Skip indexing (use FASTA directly)")
        print()

        choices = input("   Select options (e.g., '1,3' or 'all' or 'skip'): ").strip().lower()

        if choices in ['skip', '5', '']:
            return []

        if choices == 'all':
            choices = '1,2,3,4'

        selected = [c.strip() for c in choices.split(',')]

        index_configs = {
            '1': ('standard', 'GRCh38.primary_assembly.genome.mmi', []),
            '2': ('lowmem', 'GRCh38.primary_assembly.genome.lowmem.mmi', ['-I', '4G']),
            '3': ('split2G', 'GRCh38.primary_assembly.genome.split2G.mmi', ['-I', '2G']),
            '4': ('split4G', 'GRCh38.primary_assembly.genome.split4G.mmi', ['-I', '4G']),
        }

        for choice in selected:
            if choice not in index_configs:
                continue

            index_type, index_name, mm2_flags = index_configs[choice]
            index_path = output_dir / index_name

            print(f"\n   Building {index_type} index...")
            print(f"   Output: {index_path}")

            cmd = ['minimap2', '-x', 'map-ont', '-d', str(index_path)] + mm2_flags + [str(fasta_path)]

            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=3600  # 1 hour timeout
                )

                if result.returncode == 0 and index_path.exists():
                    print(f"   {Colors.green_bold('OK')} {index_type} index built successfully")
                    built_indexes.append((f"Human Reference ({index_type})", str(index_path)))
                else:
                    print(f"   {Colors.red_bold('Error')}: Failed to build {index_type} index")
                    if result.stderr:
                        print(f"   {result.stderr[:200]}")
            except subprocess.TimeoutExpired:
                print(f"   {Colors.red_bold('Error')}: Indexing timed out (>1 hour)")
            except Exception as e:
                print(f"   {Colors.red_bold('Error')}: {e}")

        return built_indexes if built_indexes else None
    else:
        # Non-interactive: build standard index only
        index_path = output_dir / 'GRCh38.primary_assembly.genome.mmi'
        print(f"\n   Building standard minimap2 index...")

        cmd = ['minimap2', '-x', 'map-ont', '-d', str(index_path), str(fasta_path)]

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
            if result.returncode == 0 and index_path.exists():
                print(f"   {Colors.green_bold('OK')} Index built: {index_path}")
                return [("Human Reference", str(index_path))]
            else:
                print(f"   {Colors.red_bold('Error')}: Failed to build index")
                return None
        except Exception as e:
            print(f"   {Colors.red_bold('Error')}: {e}")
            return None


# Database download URLs and sizes
# NOTE: Kraken2 Standard databases are subsampled and have LIMITED coverage.
# For comprehensive bacterial classification, the full Kraken2 Bacteria database
# (~200GB+) is recommended but requires manual installation due to size.
# See: https://benlangmead.github.io/aws-indexes/k2
DATABASES = {
    "kraken2-standard-8": {
        "name": "Kraken2 Standard-8 (8GB)",
        "description": "Subsampled database - LIMITED coverage, suitable for quick analysis",
        "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08gb_20240605.tar.gz",
        "size_gb": 8,
        "pipelines": ["sr_meta", "lr_meta"],
        "warning": "Limited species coverage. Full Bacteria database (200GB+) recommended for comprehensive analysis.",
    },
    "kraken2-standard-16": {
        "name": "Kraken2 Standard-16 (16GB)",
        "description": "Subsampled database - better than 8GB but still LIMITED coverage",
        "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_16gb_20240605.tar.gz",
        "size_gb": 16,
        "pipelines": ["sr_meta", "lr_meta"],
        "warning": "Limited species coverage. Full Bacteria database (200GB+) recommended for comprehensive analysis.",
    },
    "emu-default": {
        "name": "Emu Default (17K species)",
        "description": "Default Emu database - 17,555 species from rrnDB v5.6 + NCBI 16S RefSeq",
        "url": "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da8a656946a0023a7a54ef",  # emu.tar.gz
        "size_gb": 0.1,  # ~12 MB compressed, ~85 MB extracted
        "pipelines": ["lr_amp"],
        "warning": "Limited coverage. Consider emu-silva or emu-rdp for better results.",
    },
    "emu-silva": {
        "name": "Emu SILVA (100K+ species)",
        "description": "SILVA-based Emu database - broader bacterial and archaeal coverage",
        "url": "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da837c7d0187023fbc4993",  # silva_database.tar.gz
        "size_gb": 0.6,  # ~148 MB compressed, ~625 MB extracted
        "pipelines": ["lr_amp"],
    },
    "emu-rdp": {
        "name": "Emu RDP (280K+ species) - RECOMMENDED",
        "description": "RDP-based Emu database - most comprehensive coverage for 16S classification",
        "url": "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da84611e96860221b25460",  # rdp.tar.gz
        "size_gb": 1.3,  # ~110 MB compressed, ~1.2 GB extracted
        "pipelines": ["lr_amp"],
    },
    "qiime2-silva-138": {
        "name": "QIIME2 SILVA 138 Classifier (208MB)",
        "description": "SILVA 138 99% Naive Bayes classifier for QIIME2 2024.10 - REQUIRED for sr_amp",
        "url": "https://data.qiime2.org/classifiers/sklearn-1.4.2/silva/silva-138-99-nb-classifier.qza",
        "size_gb": 0.21,  # ~208 MB
        "pipelines": ["sr_amp"],
        "is_single_file": True,  # Not a tarball, just a single .qza file
        "dest_subdir": "reference/qiime2",  # Goes to main/data/reference/qiime2/
        "dest_filename": "silva-138-99-nb-classifier.qza",
    },
    "human-grch38": {
        "name": "Human GRCh38 Primary Assembly",
        "description": "GRCh38 primary assembly reference genome for host depletion (FASTA format)",
        "url": "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz",
        "size_gb": 0.9,  # ~900 MB compressed, ~3 GB uncompressed
        "pipelines": ["sr_meta", "lr_meta"],
        "is_single_file": True,
        "dest_subdir": "reference/human/grch38",
        "dest_filename": "GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz",
        "requires_indexing": True,  # Will prompt user to build minimap2 indexes
    },
}

# Analysis tools that can be downloaded
TOOLS = {
    "valencia": {
        "name": "VALENCIA",
        "description": "Vaginal community state type (CST) classification tool",
        "url": "https://github.com/ravel-lab/VALENCIA/archive/refs/heads/master.zip",
        "size_mb": 1,
        "sample_types": ["vaginal"],
    },
}

# Dorado basecalling models (compatible with Dorado 1.3.1)
DORADO_MODELS = {
    "dna_r10.4.1_e8.2_400bps_hac@v5.2.0": {
        "name": "DNA R10.4.1 HAC 400bps v5.2.0",
        "description": "High-accuracy model for R10.4.1 flow cells, 400bps, v5.2.0 - RECOMMENDED for modern 5kHz data",
        "model_id": "dna_r10.4.1_e8.2_400bps_hac@v5.2.0",
        "size_gb": 0.4,
        "pipelines": ["lr_amp", "lr_meta"],
    },
    "dna_r10.4.1_e8.2_400bps_sup@v5.2.0": {
        "name": "DNA R10.4.1 SUP 400bps v5.2.0",
        "description": "Super-accuracy model for R10.4.1 flow cells, 400bps, v5.2.0 (slower but more accurate)",
        "model_id": "dna_r10.4.1_e8.2_400bps_sup@v5.2.0",
        "size_gb": 0.4,
        "pipelines": ["lr_amp", "lr_meta"],
    },
    "dna_r10.4.1_e8.2_400bps_fast@v5.2.0": {
        "name": "DNA R10.4.1 FAST 400bps v5.2.0",
        "description": "Fast model for R10.4.1 flow cells, 400bps, v5.2.0 (faster but less accurate)",
        "model_id": "dna_r10.4.1_e8.2_400bps_fast@v5.2.0",
        "size_gb": 0.3,
        "pipelines": ["lr_amp", "lr_meta"],
    },
    "dna_r10.4.1_e8.2_400bps_hac@v3.5.2": {
        "name": "DNA R10.4.1 HAC 400bps v3.5.2 (Legacy 4kHz)",
        "description": "High-accuracy model for LEGACY 4kHz R10.4.1 E8.2 data - Working model for legacy sample rates",
        "model_id": "dna_r10.4.1_e8.2_400bps_hac@v3.5.2",
        "size_gb": 0.4,
        "pipelines": ["lr_amp", "lr_meta"],
    },
}

# Docker install instructions by platform
DOCKER_INSTALL = {
    "Darwin": {
        "name": "Docker Desktop for Mac",
        "url": "https://docs.docker.com/desktop/install/mac-install/",
        "command": None,  # Manual install required
        "brew": "brew install --cask docker",
    },
    "Linux": {
        "name": "Docker Engine",
        "url": "https://docs.docker.com/engine/install/",
        "command": "curl -fsSL https://get.docker.com | sh",
    },
}


def check_docker() -> Tuple[bool, str]:
    """Check if Docker is installed and running.

    Returns:
        Tuple of (is_available, message)
    """
    # Check if docker command exists
    docker_path = shutil.which("docker")
    if not docker_path:
        return False, "Docker not found in PATH"

    # Check if Docker daemon is running
    try:
        result = subprocess.run(
            ["docker", "info"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return True, "Docker is installed and running"
        else:
            return False, "Docker is installed but daemon is not running"
    except subprocess.TimeoutExpired:
        return False, "Docker command timed out - daemon may not be running"
    except Exception as e:
        return False, f"Error checking Docker: {e}"


def check_disk_space(path: Path, required_gb: float) -> Tuple[bool, float]:
    """Check if there's enough disk space.

    Returns:
        Tuple of (has_space, available_gb)
    """
    try:
        import shutil
        total, used, free = shutil.disk_usage(path)
        available_gb = free / (1024 ** 3)
        return available_gb >= required_gb, available_gb
    except Exception:
        return True, 0  # Assume OK if we can't check


def get_data_dir() -> Path:
    """Get the data directory for databases."""
    # Check if running as PyInstaller bundle
    if getattr(sys, 'frozen', False):
        base = Path(sys.executable).parent
        # PyInstaller 6.x puts data files in _internal/
        if (base / "_internal" / "main").exists():
            base = base / "_internal"
    else:
        from cli.discovery import find_repo_root
        base = find_repo_root()

    data_dir = base / "main" / "data" / "databases"
    data_dir.mkdir(parents=True, exist_ok=True)
    return data_dir


def get_tools_dir() -> Path:
    """Get the tools directory for analysis tools like VALENCIA."""
    # Check if running as PyInstaller bundle
    if getattr(sys, 'frozen', False):
        base = Path(sys.executable).parent
        # PyInstaller 6.x puts data files in _internal/
        if (base / "_internal" / "main").exists():
            base = base / "_internal"
    else:
        from cli.discovery import find_repo_root
        base = find_repo_root()

    tools_dir = base / "tools"
    tools_dir.mkdir(parents=True, exist_ok=True)
    return tools_dir


def get_models_dir() -> Path:
    """Get the models directory for basecalling models like Dorado."""
    tools_dir = get_tools_dir()
    models_dir = tools_dir / "models" / "dorado"
    models_dir.mkdir(parents=True, exist_ok=True)
    return models_dir


def _download_legacy_model_v352(models_dir: Path) -> bool:
    """
    Download the legacy v3.5.2 model using Dorado 0.9.6.

    Dorado 1.3.1+ no longer includes v3.5.2 in its model registry,
    so we need to use an older version (0.9.6) to download it.

    Args:
        models_dir: Directory where models should be saved

    Returns:
        True if successful, False otherwise
    """
    import tempfile
    import shutil

    print(f"   {Colors.yellow_bold('Note:')} Legacy v3.5.2 model requires Dorado 0.9.6 for download..." if is_tty() else "   [Note] Using Dorado 0.9.6 for legacy model")

    tools_dir = get_tools_dir()
    system = platform.system()
    machine = platform.machine()

    # Determine platform for Dorado 0.9.6
    if system == "Darwin":
        if machine == "arm64":
            platform_str = "osx-arm64"
        else:
            platform_str = "osx-x64"
        archive_ext = "zip"
    elif system == "Linux":
        if machine in ["x86_64", "amd64"]:
            platform_str = "linux-x64"
        else:
            platform_str = "linux-arm64"
        archive_ext = "tar.gz"
    else:
        print(f"   {Colors.red_bold('Error')} Unsupported platform for legacy model download" if is_tty() else "   [Error] Unsupported platform")
        return False

    version = "0.9.6"
    filename = f"dorado-{version}-{platform_str}.{archive_ext}"
    url = f"https://cdn.oxfordnanoportal.com/software/analysis/{filename}"

    # Create temporary directory
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)
        archive_path = temp_path / filename

        # Download Dorado 0.9.6
        print(f"   Downloading Dorado {version} (temporary, for legacy model download)...")
        if not download_with_progress(url, archive_path, f"   Dorado {version}"):
            return False

        # Extract
        print(f"   Extracting...")
        try:
            if archive_ext == "zip":
                import zipfile
                with zipfile.ZipFile(archive_path, 'r') as zip_ref:
                    zip_ref.extractall(temp_path)
            else:
                import tarfile
                with tarfile.open(archive_path, "r:gz") as tar:
                    tar.extractall(temp_path)

            # Find the dorado binary
            extracted_dir = temp_path / f"dorado-{version}-{platform_str}"
            dorado_bin = extracted_dir / "bin" / "dorado"

            if not dorado_bin.exists():
                print(f"   {Colors.red_bold('Error')} Dorado binary not found in archive" if is_tty() else "   [Error] Binary not found")
                return False

            # Make executable
            os.chmod(dorado_bin, 0o755)

            # Download the v3.5.2 model using Dorado 0.9.6
            print(f"   Downloading v3.5.2 model...")
            result = subprocess.run(
                [str(dorado_bin), "download", "--model", "dna_r10.4.1_e8.2_400bps_hac@v3.5.2", "--models-directory", str(models_dir)],
                capture_output=True,
                text=True,
                timeout=600,
                env={**os.environ, "DYLD_LIBRARY_PATH": str(extracted_dir / "lib")}  # Add lib path for macOS
            )

            if result.returncode == 0:
                model_path = models_dir / "dna_r10.4.1_e8.2_400bps_hac@v3.5.2"
                if model_path.exists():
                    print(f"   {Colors.green_bold('OK')} Legacy model downloaded successfully" if is_tty() else "   [OK] Legacy model downloaded")
                    return True
                else:
                    print(f"   {Colors.red_bold('Error')} Model directory not found after download" if is_tty() else "   [Error] Model not found")
                    return False
            else:
                error_msg = result.stderr.strip() if result.stderr else result.stdout.strip() if result.stdout else "Unknown error"
                print(f"   {Colors.red_bold('Error')} Download failed: {error_msg[:200]}" if is_tty() else f"   [Error] {error_msg[:200]}")
                return False

        except Exception as e:
            print(f"   {Colors.red_bold('Error')} {e}" if is_tty() else f"   [Error] {e}")
            return False


def get_dorado_binary(version: str = "1.3.1") -> Optional[Path]:
    """
    Download and setup Dorado binary for model downloads.

    On macOS, this downloads TWO binaries:
    1. Linux binary (tools/dorado/) - for Docker container mounting
    2. macOS binary (tools/dorado-host/) - for running model downloads on host

    On Linux, downloads one binary (tools/dorado/) used for both purposes.

    Args:
        version: Dorado version to download (e.g., "1.3.1" or "0.9.6")

    Returns path to HOST binary (for running dorado download commands), or None if unavailable.
    """
    tools_dir = get_tools_dir()

    system = platform.system()
    machine = platform.machine()

    # Determine what to download based on host platform
    if system == "Darwin":
        # macOS: Download Linux binary for Docker + macOS binary for host

        # 1. Download Linux binary for Docker container mounting
        if machine == "arm64":
            docker_platform = "linux-arm64"
        else:
            docker_platform = "linux-x64"

        # Use version-specific directory for Dorado binaries
        dorado_dir = tools_dir / f"dorado-{version}" if version != "1.3.1" else tools_dir / "dorado"
        dorado_bin_docker = dorado_dir / "bin" / "dorado"

        if not (dorado_bin_docker.exists() and os.access(dorado_bin_docker, os.X_OK)):
            print(f"   Downloading Dorado {version} for Docker (Linux {machine})...")
            if not _download_dorado_binary(version, docker_platform, dorado_dir):
                print(f"   {Colors.yellow_bold('Warning')}: Failed to download Linux Dorado binary for Docker" if is_tty() else "   [Warning] Failed to download Linux Dorado binary")
                print(f"   Docker containers may not be able to run Dorado")
        else:
            print(f"   {Colors.green_bold('OK')} Linux Dorado {version} binary already present for Docker" if is_tty() else f"   [OK] Linux Dorado {version} binary present")

        # 2. Download macOS binary for running model downloads on host
        host_platform = "osx-arm64" if machine == "arm64" else "osx-x64"
        dorado_host_dir = tools_dir / f"dorado-{version}-host" if version != "1.3.1" else tools_dir / "dorado-host"
        dorado_bin_host = dorado_host_dir / "bin" / "dorado"

        if not (dorado_bin_host.exists() and os.access(dorado_bin_host, os.X_OK)):
            print(f"   Downloading Dorado {version} for host (macOS)...")
            if not _download_dorado_binary(version, host_platform, dorado_host_dir):
                return None
        else:
            print(f"   {Colors.green_bold('OK')} macOS Dorado {version} binary already present for host" if is_tty() else f"   [OK] macOS Dorado {version} binary present")

        return dorado_bin_host

    elif system == "Linux":
        # Linux: Download one binary used for both Docker and host
        if machine in ["x86_64", "amd64"]:
            platform_str = "linux-x64"
        else:
            platform_str = "linux-arm64"

        # Use version-specific directory for Dorado binaries
        dorado_dir = tools_dir / f"dorado-{version}" if version != "1.3.1" else tools_dir / "dorado"
        dorado_bin = dorado_dir / "bin" / "dorado"

        if dorado_bin.exists() and os.access(dorado_bin, os.X_OK):
            return dorado_bin

        print(f"   Downloading Dorado {version} for Linux...")
        if _download_dorado_binary(version, platform_str, dorado_dir):
            return dorado_bin
        else:
            return None
    else:
        return None


def _download_dorado_binary(version: str, platform_str: str, dest_dir: Path) -> bool:
    """
    Helper function to download and extract a Dorado binary.

    Args:
        version: Dorado version (e.g., "1.3.1")
        platform_str: Platform string (e.g., "linux-arm64", "osx-arm64")
        dest_dir: Destination directory

    Returns:
        True if successful, False otherwise
    """
    archive_ext = "zip" if platform_str.startswith("osx") else "tar.gz"
    filename = f"dorado-{version}-{platform_str}.{archive_ext}"
    url = f"https://cdn.oxfordnanoportal.com/software/analysis/{filename}"

    archive_path = dest_dir / filename
    dest_dir.mkdir(parents=True, exist_ok=True)

    if not download_with_progress(url, archive_path, f"   Dorado {version} ({platform_str})"):
        return False

    # Extract archive
    print(f"   Extracting Dorado...")
    try:
        if archive_ext == "zip":
            import zipfile
            with zipfile.ZipFile(archive_path, 'r') as zip_ref:
                zip_ref.extractall(dest_dir)
        else:  # tar.gz
            import tarfile
            with tarfile.open(archive_path, "r:gz") as tar:
                tar.extractall(dest_dir)

        # The extracted directory is dorado-{version}-{platform_str}
        extracted_dir = dest_dir / f"dorado-{version}-{platform_str}"
        dorado_bin = dest_dir / "bin" / "dorado"

        # Move all contents (bin, lib, etc.) up one level if needed
        if extracted_dir.exists() and not dorado_bin.exists():
            import shutil
            # Move all items from extracted_dir to dest_dir
            for item in extracted_dir.iterdir():
                dest = dest_dir / item.name
                if dest.exists():
                    shutil.rmtree(dest) if dest.is_dir() else dest.unlink()
                shutil.move(str(item), str(dest))

            # Remove the now-empty extracted directory
            extracted_dir.rmdir()

        # Clean up archive
        archive_path.unlink()

        # Verify binary exists and make executable
        if dorado_bin.exists():
            os.chmod(dorado_bin, 0o755)
            return True
        else:
            print(f"   {Colors.red_bold('Error')}: Failed to find dorado binary after extraction")
            return False

    except Exception as e:
        print(f"   {Colors.red_bold('Error')}: Failed to extract Dorado: {e}")
        return False


def get_ssl_context() -> ssl.SSLContext:
    """Get an SSL context for HTTPS requests.

    PyInstaller bundles may not include system certificates, so we try
    multiple approaches to get a working SSL context.
    """
    # Try to use certifi if available (provides Mozilla's CA bundle)
    try:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
        return context
    except ImportError:
        pass

    # Try default context (works on most systems)
    try:
        context = ssl.create_default_context()
        # Test if it can verify a known good site
        return context
    except Exception:
        pass

    # Fallback: create unverified context with warning
    # This is less secure but allows downloads to work
    print("  Warning: Using unverified SSL (certificates not available)")
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


def download_with_progress(url: str, dest: Path, desc: str = "Downloading") -> bool:
    """Download a file with progress display."""
    try:
        ssl_context = get_ssl_context()

        # Create request with User-Agent header to avoid 403 errors
        req = urllib.request.Request(
            url,
            headers={'User-Agent': 'STAMINA-BIOME/1.0 (https://github.com/izzydavidson/STAMINA-BIOME)'}
        )

        # Get file size
        with urllib.request.urlopen(req, context=ssl_context) as response:
            total_size = int(response.headers.get('content-length', 0))

        # Download with progress
        downloaded = 0
        chunk_size = 1024 * 1024  # 1MB chunks

        req = urllib.request.Request(
            url,
            headers={'User-Agent': 'STAMINA-BIOME/1.0 (https://github.com/izzydavidson/STAMINA-BIOME)'}
        )
        with urllib.request.urlopen(req, context=ssl_context) as response:
            with open(dest, 'wb') as f:
                while True:
                    chunk = response.read(chunk_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)

                    if total_size > 0:
                        pct = (downloaded / total_size) * 100
                        downloaded_mb = downloaded / (1024 * 1024)
                        total_mb = total_size / (1024 * 1024)
                        print(f"\r  {desc}: {downloaded_mb:.1f}/{total_mb:.1f} MB ({pct:.1f}%)", end="", flush=True)
                    else:
                        downloaded_mb = downloaded / (1024 * 1024)
                        print(f"\r  {desc}: {downloaded_mb:.1f} MB", end="", flush=True)

        print()  # Newline after progress
        return True
    except Exception as e:
        print(f"\n  Error: {e}")
        return False


def extract_tarball(archive: Path, dest_dir: Path) -> bool:
    """Extract a tar archive (supports .tar, .tar.gz, .tgz)."""
    try:
        print(f"  Extracting to {dest_dir}...")
        # Determine compression mode based on filename
        name = archive.name.lower()
        if name.endswith('.tar.gz') or name.endswith('.tgz'):
            mode = "r:gz"
        elif name.endswith('.tar.bz2'):
            mode = "r:bz2"
        elif name.endswith('.tar'):
            mode = "r:"
        else:
            # Try auto-detection
            mode = "r:*"

        with tarfile.open(archive, mode) as tar:
            tar.extractall(path=dest_dir)
        return True
    except Exception as e:
        print(f"  Error extracting: {e}")
        return False


def extract_zip(archive: Path, dest_dir: Path, strip_top_dir: bool = True) -> bool:
    """Extract a zip archive.

    Args:
        archive: Path to the zip file
        dest_dir: Destination directory
        strip_top_dir: If True, strip the top-level directory from the archive
    """
    try:
        print(f"  Extracting to {dest_dir}...")
        dest_dir.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(archive, 'r') as zf:
            if strip_top_dir:
                # Get the top-level directory name
                top_dirs = set()
                for name in zf.namelist():
                    parts = name.split('/')
                    if parts[0]:
                        top_dirs.add(parts[0])

                # If there's exactly one top-level directory, strip it
                if len(top_dirs) == 1:
                    top_dir = top_dirs.pop()
                    for member in zf.namelist():
                        if member.startswith(top_dir + '/'):
                            # Strip the top directory
                            relative_path = member[len(top_dir) + 1:]
                            if relative_path:  # Skip empty paths
                                target_path = dest_dir / relative_path
                                if member.endswith('/'):
                                    target_path.mkdir(parents=True, exist_ok=True)
                                else:
                                    target_path.parent.mkdir(parents=True, exist_ok=True)
                                    with zf.open(member) as src, open(target_path, 'wb') as dst:
                                        dst.write(src.read())
                    return True

            # Default extraction
            zf.extractall(path=dest_dir)
        return True
    except Exception as e:
        print(f"  Error extracting: {e}")
        return False


def prompt_yes_no(question: str, default: bool = True) -> bool:
    """Prompt user for yes/no answer."""
    if default:
        prompt = f"{question} [Y/n]: "
    else:
        prompt = f"{question} [y/N]: "

    try:
        response = input(prompt).strip().lower()
        if not response:
            return default
        return response in ('y', 'yes')
    except (EOFError, KeyboardInterrupt):
        print()
        return False


def prompt_choice(question: str, options: List[str], default: int = 0) -> int:
    """Prompt user to choose from options."""
    print(question)
    for i, opt in enumerate(options):
        marker = "*" if i == default else " "
        print(f"  {marker} [{i + 1}] {opt}")

    try:
        response = input(f"Choice [1-{len(options)}] (default: {default + 1}): ").strip()
        if not response:
            return default
        choice = int(response) - 1
        if 0 <= choice < len(options):
            return choice
        return default
    except (ValueError, EOFError, KeyboardInterrupt):
        print()
        return default


def get_stamina_biome_bin_dir() -> Path:
    """Get the directory containing the stamina-biome executable."""
    if getattr(sys, 'frozen', False):
        # PyInstaller bundle - executable is in this directory
        # Use resolve() to get the actual path without symlinks
        return Path(sys.executable).resolve().parent
    else:
        # Development mode - find the repo root
        from cli.discovery import find_repo_root
        return find_repo_root()


def get_shell_config_file() -> Tuple[Optional[Path], str]:
    """Detect user's shell and return the appropriate config file.

    Returns:
        Tuple of (config_file_path, shell_name)
    """
    shell = os.environ.get("SHELL", "")
    home = Path.home()

    if "zsh" in shell:
        # zsh - prefer .zshrc
        zshrc = home / ".zshrc"
        return zshrc, "zsh"
    elif "bash" in shell:
        # bash - check for .bash_profile (macOS) or .bashrc (Linux)
        if platform.system() == "Darwin":
            # macOS uses .bash_profile for login shells
            bash_profile = home / ".bash_profile"
            if bash_profile.exists():
                return bash_profile, "bash"
            # Fall back to .bashrc
            return home / ".bashrc", "bash"
        else:
            # Linux typically uses .bashrc
            bashrc = home / ".bashrc"
            return bashrc, "bash"
    elif "fish" in shell:
        # fish shell
        fish_config = home / ".config" / "fish" / "config.fish"
        return fish_config, "fish"
    else:
        # Unknown shell - try common options
        for config in [".zshrc", ".bashrc", ".bash_profile", ".profile"]:
            path = home / config
            if path.exists():
                return path, "unknown"
        # Default to .profile
        return home / ".profile", "unknown"


def check_path_configured(bin_dir: Path) -> bool:
    """Check if stamina-biome is already in PATH."""
    # Check if stamina-biome command is available
    stamina_biome_path = shutil.which("stamina-biome")
    if stamina_biome_path:
        # Verify it's our stamina-biome
        return Path(stamina_biome_path).parent.resolve() == bin_dir.resolve()

    # Also check if the directory is in PATH
    path_dirs = os.environ.get("PATH", "").split(os.pathsep)
    return str(bin_dir) in path_dirs or str(bin_dir.resolve()) in path_dirs


def add_to_path(bin_dir: Path, shell_config: Path, shell_name: str) -> bool:
    """Add stamina-biome directory to PATH in shell config.

    Returns:
        True if successfully added, False otherwise
    """
    # Generate the export line based on shell
    if shell_name == "fish":
        export_line = f'set -gx PATH "{bin_dir}" $PATH'
        comment = "# Added by STAMINA-BIOME setup"
    else:
        export_line = f'export PATH="{bin_dir}:$PATH"'
        comment = "# Added by STAMINA-BIOME setup"

    full_addition = f"\n{comment}\n{export_line}\n"

    try:
        # Check if already added
        if shell_config.exists():
            content = shell_config.read_text()
            if str(bin_dir) in content:
                return True  # Already configured

        # Create parent directories if needed
        shell_config.parent.mkdir(parents=True, exist_ok=True)

        # Append to config file
        with open(shell_config, "a") as f:
            f.write(full_addition)

        return True
    except Exception as e:
        print(f"   Error writing to {shell_config}: {e}")
        return False


def run_setup(interactive: bool = True, install_docker: bool = False,
              databases: Optional[List[str]] = None, skip_path: bool = False) -> int:
    """Run the setup wizard.

    Args:
        interactive: If True, prompt for user input
        install_docker: If True, attempt to install Docker
        databases: List of database IDs to download
        skip_path: If True, skip PATH configuration

    Returns:
        Exit code (0 = success)
    """
    print()
    print(Colors.cyan_bold("STAMINA-BIOME Setup") if is_tty() else "=== STAMINA-BIOME Setup ===")
    print("=" * 40)
    print()

    issues = []
    needs_shell_restart = False
    downloaded_items = []  # Track downloaded databases and tools for final summary

    # Step 1: Add to PATH
    print(Colors.cyan_bold("1. Adding stamina-biome to PATH...") if is_tty() else "1. Adding stamina-biome to PATH...")

    bin_dir = get_stamina_biome_bin_dir()
    path_configured = check_path_configured(bin_dir)

    if path_configured:
        print(f"   {Colors.green_bold('OK')} stamina-biome is already in your PATH" if is_tty()
              else "   [OK] stamina-biome is already in your PATH")
    elif skip_path:
        print(f"   {Colors.yellow_bold('SKIPPED')} PATH configuration skipped" if is_tty()
              else "   [SKIPPED] PATH configuration skipped")
    else:
        shell_config, shell_name = get_shell_config_file()
        print(f"   Detected shell: {shell_name}")
        print(f"   Config file: {shell_config}")
        print(f"   STAMINA-BIOME directory: {bin_dir}")

        if interactive:
            if prompt_yes_no(f"   Add stamina-biome to your PATH?", default=True):
                if add_to_path(bin_dir, shell_config, shell_name):
                    print(f"   {Colors.green_bold('OK')} Added to {shell_config}" if is_tty()
                          else f"   [OK] Added to {shell_config}")
                    needs_shell_restart = True
                else:
                    print(f"   {Colors.red_bold('FAILED')} Could not update {shell_config}" if is_tty()
                          else f"   [FAILED] Could not update {shell_config}")
                    print(f"   You can manually add this line to your shell config:")
                    print(f'   export PATH="{bin_dir}:$PATH"')
            else:
                print(f"   {Colors.yellow_bold('SKIPPED')} You can run stamina-biome with: {bin_dir}/stamina-biome" if is_tty()
                      else f"   [SKIPPED] Run with: {bin_dir}/stamina-biome")
        else:
            # Non-interactive: add automatically
            if add_to_path(bin_dir, shell_config, shell_name):
                print(f"   {Colors.green_bold('OK')} Added to {shell_config}" if is_tty()
                      else f"   [OK] Added to {shell_config}")
                needs_shell_restart = True

    print()

    # Step 2: Check Docker
    print(Colors.cyan_bold("2. Checking Docker...") if is_tty() else "2. Checking Docker...")
    docker_ok, docker_msg = check_docker()

    if docker_ok:
        print(f"   {Colors.green_bold('OK')} {docker_msg}" if is_tty() else f"   [OK] {docker_msg}")
    else:
        print(f"   {Colors.red_bold('MISSING')} {docker_msg}" if is_tty() else f"   [MISSING] {docker_msg}")

        system = platform.system()
        install_info = DOCKER_INSTALL.get(system, {})

        if interactive:
            print()
            print(f"   Docker is required to run STAMINA-BIOME pipelines.")
            print(f"   Install instructions: {install_info.get('url', 'https://docs.docker.com/get-docker/')}")

            if system == "Darwin" and install_info.get("brew"):
                print(f"   Or with Homebrew: {install_info['brew']}")
            elif system == "Linux" and install_info.get("command"):
                if prompt_yes_no("   Would you like to install Docker now?"):
                    print(f"   Running: {install_info['command']}")
                    try:
                        subprocess.run(install_info['command'], shell=True, check=True)
                        docker_ok, docker_msg = check_docker()
                        if docker_ok:
                            print(f"   {Colors.green_bold('OK')} Docker installed successfully!" if is_tty() else "   [OK] Docker installed!")
                    except subprocess.CalledProcessError:
                        print(f"   Installation failed. Please install manually.")

        if not docker_ok:
            issues.append("Docker not available")

    # Check for required Docker images if Docker is available
    if docker_ok:
        print()
        print("   Checking Docker images...")

        # Map image names to their Dockerfiles
        required_images = {
            "stamina-biome-lr:latest": {
                "description": "Long-read pipelines (lr_amp, lr_meta)",
                "dockerfile": "dockerfile.lr",
            },
            "stamina-biome-sr:latest": {
                "description": "Short-read pipelines (sr_amp, sr_meta)",
                "dockerfile": "dockerfile.sr",
            },
        }
        missing_images = []

        for image, info in required_images.items():
            try:
                result = subprocess.run(
                    ["docker", "image", "inspect", image],
                    capture_output=True,
                    timeout=10
                )
                if result.returncode == 0:
                    print(f"   {Colors.green_bold('FOUND')} {image} - {info['description']}" if is_tty()
                          else f"   [FOUND] {image} - {info['description']}")
                else:
                    print(f"   {Colors.yellow_bold('MISSING')} {image} - {info['description']}" if is_tty()
                          else f"   [MISSING] {image} - {info['description']}")
                    missing_images.append((image, info))
            except Exception:
                missing_images.append((image, info))

        if missing_images and interactive:
            print()
            print("   Docker images need to be built from Dockerfiles included in this release.")
            print("   Building may take 5-10 minutes per image (downloads dependencies).")
            if prompt_yes_no("   Would you like to build missing images now?", default=True):
                # Find the container directory
                if getattr(sys, 'frozen', False):
                    base = Path(sys.executable).parent
                    if (base / "_internal" / "main").exists():
                        container_dir = base / "_internal" / "main" / "pipelines" / "container"
                    else:
                        container_dir = base / "main" / "pipelines" / "container"
                else:
                    from cli.discovery import find_repo_root
                    container_dir = find_repo_root() / "main" / "pipelines" / "container"

                for image, info in missing_images:
                    dockerfile = container_dir / info['dockerfile']
                    if not dockerfile.exists():
                        print(f"   {Colors.yellow_bold('WARN')} Dockerfile not found: {dockerfile}" if is_tty()
                              else f"   [WARN] Dockerfile not found: {dockerfile}")
                        continue

                    print(f"   Building {image} (this may take several minutes)...")
                    try:
                        # Build the image
                        result = subprocess.run(
                            ["docker", "build", "-t", image, "-f", str(dockerfile), str(container_dir)],
                            capture_output=False,  # Show build output
                            timeout=1800  # 30 min timeout for large builds
                        )
                        if result.returncode == 0:
                            print(f"   {Colors.green_bold('OK')} {image} built successfully!" if is_tty()
                                  else f"   [OK] {image} built!")
                        else:
                            print(f"   {Colors.yellow_bold('WARN')} Build failed for {image}" if is_tty()
                                  else f"   [WARN] Build failed for {image}")
                    except subprocess.TimeoutExpired:
                        print(f"   Timeout building {image}")
                    except Exception as e:
                        print(f"   Error building {image}: {e}")

    print()

    # Step 3: Check/Download databases
    print(Colors.cyan_bold("3. Reference Databases") if is_tty() else "3. Reference Databases")

    data_dir = get_data_dir()
    print(f"   Database directory: {data_dir}")
    print()

    # Check existing databases
    existing_dbs = []
    for db_id, db_info in DATABASES.items():
        # Handle single file databases (like QIIME2 classifier)
        if db_info.get('is_single_file'):
            dest_subdir = db_info.get('dest_subdir', '')
            dest_filename = db_info.get('dest_filename', '')
            db_path = data_dir.parent / dest_subdir / dest_filename  # Goes to main/data/reference/...
            if db_path.exists():
                existing_dbs.append(db_id)
                print(f"   {Colors.green_bold('FOUND')} {db_info['name']}" if is_tty() else f"   [FOUND] {db_info['name']}")
        else:
            db_path = data_dir / db_id
            if db_path.exists():
                existing_dbs.append(db_id)
                print(f"   {Colors.green_bold('FOUND')} {db_info['name']}" if is_tty() else f"   [FOUND] {db_info['name']}")

    missing_dbs = [db_id for db_id in DATABASES if db_id not in existing_dbs]

    if missing_dbs and interactive:
        print()
        print("   Available databases to download:")
        for db_id in missing_dbs:
            db_info = DATABASES[db_id]
            print(f"   - {db_info['name']}: {db_info['description']}")
            print(f"     Size: ~{db_info['size_gb']} GB, Used by: {', '.join(db_info['pipelines'])}")
            # Show warning if present
            if db_info.get('warning'):
                warning_text = db_info['warning']
                if is_tty():
                    print(f"     {Colors.yellow_bold('WARNING')}: {warning_text}")
                else:
                    print(f"     [WARNING]: {warning_text}")

        print()
        # Add note about comprehensive databases
        print("   " + "-" * 50)
        if is_tty():
            print(f"   {Colors.yellow_bold('NOTE')}: Database recommendations:")
        else:
            print("   [NOTE]: Database recommendations:")
        print("   - Emu RDP (280K species) - RECOMMENDED for 16S classification")
        print("   - Kraken2: Full Bacteria DB (200GB+) for metagenomics requires manual install")
        print("   " + "-" * 50)
        print()

        if prompt_yes_no("   Would you like to download any databases now?", default=False):
            # Let user choose which to download
            for db_id in missing_dbs:
                db_info = DATABASES[db_id]
                if prompt_yes_no(f"   Download {db_info['name']} (~{db_info['size_gb']} GB)?", default=False):
                    # Check disk space
                    has_space, available = check_disk_space(data_dir, db_info['size_gb'] * 1.5)
                    if not has_space:
                        print(f"   Warning: Only {available:.1f} GB available, need ~{db_info['size_gb'] * 1.5:.1f} GB")
                        if not prompt_yes_no("   Continue anyway?", default=False):
                            continue

                    # Handle single file downloads (like QIIME2 classifier)
                    if db_info.get('is_single_file'):
                        dest_subdir = db_info.get('dest_subdir', '')
                        dest_filename = db_info.get('dest_filename', '')
                        dest_dir = data_dir.parent / dest_subdir
                        dest_dir.mkdir(parents=True, exist_ok=True)
                        dest_path = dest_dir / dest_filename
                        print(f"   Downloading {db_info['name']}...")

                        if download_with_progress(db_info['url'], dest_path, "Downloading"):
                            print(f"   {Colors.green_bold('OK')} {db_info['name']} installed!" if is_tty() else f"   [OK] Installed!")
                            print()
                            print(f"   {Colors.cyan_bold('File path:')} " if is_tty() else "   File path:")
                            print(f"   {dest_path}")
                            if "qiime2" in db_id:
                                print(f"   (Auto-detected by sr_amp pipeline)")
                                downloaded_items.append(("QIIME2 Classifier", str(dest_path), "(auto-detected)"))
                            elif "human" in db_id:
                                # Check if this requires indexing
                                if db_info.get('requires_indexing', False):
                                    # Build minimap2 indexes
                                    indexes = build_minimap2_index(dest_path, dest_path.parent, interactive=True)
                                    if indexes:
                                        for idx_name, idx_path in indexes:
                                            print(f"   Index: {idx_path}")
                                            print(f"   Use with: --human-index {idx_path}")
                                            print(f"   (Auto-detected by sr_meta/lr_meta if not specified)")
                                            downloaded_items.append((idx_name, idx_path, "(auto-detected)"))
                                else:
                                    usage_hint = "--human-index" if "split" not in db_id else "--human-index (use with --minimap2-split-index)"
                                    print(f"   Use with: {usage_hint} {dest_path}")
                                    print(f"   (Auto-detected by sr_meta/lr_meta if not specified)")
                                    ref_name = db_info['name']
                                    downloaded_items.append((ref_name, str(dest_path), "(auto-detected)"))
                            print()
                        else:
                            print(f"   Failed to download classifier")
                    else:
                        # Download tarball - determine file extension from URL
                        url = db_info['url']
                        if url.endswith('.tar.gz') or url.endswith('.tgz'):
                            ext = '.tar.gz'
                        elif url.endswith('.tar'):
                            ext = '.tar'
                        else:
                            ext = '.tar.gz'  # Default
                        archive_path = data_dir / f"{db_id}{ext}"
                        print(f"   Downloading {db_info['name']}...")

                        if download_with_progress(db_info['url'], archive_path, "Downloading"):
                            if extract_tarball(archive_path, data_dir / db_id):
                                archive_path.unlink()  # Remove archive after extraction
                                db_path = data_dir / db_id
                                print(f"   {Colors.green_bold('OK')} {db_info['name']} installed!" if is_tty() else f"   [OK] Installed!")
                                print()
                                print(f"   {Colors.cyan_bold('Database path:')} " if is_tty() else "   Database path:")
                                print(f"   {db_path}")
                                # Print usage hint based on database type
                                if "emu" in db_id:
                                    emu_subdir = db_path / "emu" if (db_path / "emu").exists() else db_path
                                    print(f"   Use with: --emu-db {emu_subdir}")
                                    downloaded_items.append(("Emu Database", str(emu_subdir), f"--emu-db {emu_subdir}"))
                                elif "kraken2" in db_id:
                                    print(f"   Use with: --db {db_path}")
                                    downloaded_items.append(("Kraken2 Database", str(db_path), f"--db {db_path}"))
                                print()
                            else:
                                print(f"   Failed to extract database")
                        else:
                            print(f"   Failed to download database")

    elif databases:
        # Non-interactive mode with specific databases requested
        for db_id in databases:
            if db_id not in DATABASES:
                print(f"   Unknown database: {db_id}")
                continue
            if db_id in existing_dbs:
                print(f"   {db_id} already installed")
                continue

            db_info = DATABASES[db_id]

            # Handle single file downloads (like QIIME2 classifier)
            if db_info.get('is_single_file'):
                dest_subdir = db_info.get('dest_subdir', '')
                dest_filename = db_info.get('dest_filename', '')
                dest_dir = data_dir.parent / dest_subdir
                dest_dir.mkdir(parents=True, exist_ok=True)
                dest_path = dest_dir / dest_filename
                print(f"   Downloading {db_info['name']}...")

                if download_with_progress(db_info['url'], dest_path, "Downloading"):
                    print(f"   {Colors.green_bold('OK')} {db_info['name']} installed!" if is_tty() else f"   [OK] {db_info['name']} installed!")
                    print()
                    print(f"   {Colors.cyan_bold('File path:')} " if is_tty() else "   File path:")
                    print(f"   {dest_path}")
                    if "qiime2" in db_id:
                        print(f"   {Colors.cyan_bold('(Auto-detected by sr_amp pipeline)')} " if is_tty() else "   (Auto-detected by sr_amp pipeline)")
                        downloaded_items.append(("QIIME2 Classifier", str(dest_path), "(auto-detected)"))
                    elif "human" in db_id:
                        # Check if this requires indexing
                        if db_info.get('requires_indexing', False):
                            # Build minimap2 indexes (non-interactive: standard only)
                            indexes = build_minimap2_index(dest_path, dest_path.parent, interactive=False)
                            if indexes:
                                for idx_name, idx_path in indexes:
                                    print(f"   Index: {idx_path}")
                                    print(f"   Use with: --human-index {idx_path}")
                                    print(f"   {Colors.cyan_bold('(Auto-detected by sr_meta/lr_meta if not specified)')} " if is_tty() else "   (Auto-detected by sr_meta/lr_meta if not specified)")
                                    downloaded_items.append((idx_name, idx_path, "(auto-detected)"))
                        else:
                            usage_hint = "--human-index" if "split" not in db_id else "--human-index (use with --minimap2-split-index)"
                            print(f"   Use with: {usage_hint} {dest_path}")
                            print(f"   {Colors.cyan_bold('(Auto-detected by sr_meta/lr_meta if not specified)')} " if is_tty() else "   (Auto-detected by sr_meta/lr_meta if not specified)")
                            ref_name = "Human Reference (Split)" if "split" in db_id else "Human Reference (Low Memory)"
                            downloaded_items.append((ref_name, str(dest_path), "(auto-detected)"))
                    print()
            else:
                # Determine file extension from URL
                url = db_info['url']
                if url.endswith('.tar.gz') or url.endswith('.tgz'):
                    ext = '.tar.gz'
                elif url.endswith('.tar'):
                    ext = '.tar'
                else:
                    ext = '.tar.gz'
                archive_path = data_dir / f"{db_id}{ext}"
                print(f"   Downloading {db_info['name']}...")

                if download_with_progress(db_info['url'], archive_path, "Downloading"):
                    if extract_tarball(archive_path, data_dir / db_id):
                        archive_path.unlink()
                        db_path = data_dir / db_id
                        print(f"   Installed {db_info['name']}")
                        print(f"   Path: {db_path}")
                        if "emu" in db_id:
                            emu_subdir = db_path / "emu" if (db_path / "emu").exists() else db_path
                            downloaded_items.append(("Emu Database", str(emu_subdir), f"--emu-db {emu_subdir}"))
                        elif "kraken2" in db_id:
                            downloaded_items.append(("Kraken2 Database", str(db_path), f"--db {db_path}"))

    print()

    # Step 4: Analysis Tools (VALENCIA)
    print(Colors.cyan_bold("4. Analysis Tools") if is_tty() else "4. Analysis Tools")

    tools_dir = get_tools_dir()
    print(f"   Tools directory: {tools_dir}")
    print()

    # Check existing tools
    existing_tools = []
    for tool_id, tool_info in TOOLS.items():
        tool_path = tools_dir / tool_id.upper()
        if tool_path.exists() and any(tool_path.iterdir()):
            existing_tools.append(tool_id)
            print(f"   {Colors.green_bold('FOUND')} {tool_info['name']}" if is_tty() else f"   [FOUND] {tool_info['name']}")

    missing_tools = [tool_id for tool_id in TOOLS if tool_id not in existing_tools]

    if missing_tools and interactive:
        print()
        print("   Available tools to download:")
        for tool_id in missing_tools:
            tool_info = TOOLS[tool_id]
            print(f"   - {tool_info['name']}: {tool_info['description']}")
            print(f"     Size: ~{tool_info['size_mb']} MB, For sample types: {', '.join(tool_info['sample_types'])}")

        print()
        if prompt_yes_no("   Would you like to download analysis tools now?", default=True):
            for tool_id in missing_tools:
                tool_info = TOOLS[tool_id]
                if prompt_yes_no(f"   Download {tool_info['name']}?", default=True):
                    # Download
                    archive_path = tools_dir / f"{tool_id}.zip"
                    tool_dest = tools_dir / tool_id.upper()
                    print(f"   Downloading {tool_info['name']}...")

                    if download_with_progress(tool_info['url'], archive_path, "Downloading"):
                        if extract_zip(archive_path, tool_dest, strip_top_dir=True):
                            archive_path.unlink()  # Remove archive after extraction
                            print(f"   {Colors.green_bold('OK')} {tool_info['name']} installed!" if is_tty() else f"   [OK] Installed!")

                            # Print centroids path for VALENCIA
                            if tool_id == "valencia":
                                centroids_file = tool_dest / "CST_centroids_012920.csv"
                                if centroids_file.exists():
                                    print()
                                    print(f"   {Colors.cyan_bold('VALENCIA centroids path:')} " if is_tty() else "   VALENCIA centroids path:")
                                    print(f"   {centroids_file}")
                                    print()
                                    print("   Use with: --valencia-centroids " + str(centroids_file))
                                    print()
                                    downloaded_items.append(("VALENCIA Centroids", str(centroids_file), f"--valencia-centroids {centroids_file}"))
                        else:
                            print(f"   Failed to extract tool")
                    else:
                        print(f"   Failed to download tool")

    print()

    # Step 4.5: Dorado Basecalling Models
    print(Colors.cyan_bold("4.5. Dorado Basecalling Models") if is_tty() else "4.5. Dorado Basecalling Models")
    print()

    models_dir = get_models_dir()
    print(f"   Models directory: {models_dir}")
    print()

    # Check existing models
    existing_models = []
    for model_id, model_info in DORADO_MODELS.items():
        model_path = models_dir / model_id
        if model_path.exists() and any(model_path.iterdir()):
            existing_models.append(model_id)
            print(f"   {Colors.green_bold('FOUND')} {model_info['name']}" if is_tty() else f"   [FOUND] {model_info['name']}")

    missing_models = [model_id for model_id in DORADO_MODELS if model_id not in existing_models]

    if missing_models and interactive:
        print()
        print("   Available Dorado models to download:")
        for model_id in missing_models:
            model_info = DORADO_MODELS[model_id]
            print(f"   - {model_info['name']}: {model_info['description']}")
            print(f"     Size: ~{model_info['size_gb']} GB, Used by: {', '.join(model_info['pipelines'])}")

        print()
        if prompt_yes_no("   Would you like to download Dorado models now?", default=True):
            # Ask user which Dorado version to use
            print()
            print(f"   {Colors.cyan_bold('Dorado Version Selection')} " if is_tty() else "   Dorado Version Selection")
            print()
            print("   Which Dorado version do you want to use?")
            print()
            print("   1. Dorado 1.3.1 (latest, recommended for new data)")
            print("      - Supports v5.x models (dna_r10.4.1_e8.2_400bps_hac@v5.2.0)")
            print("      - Size: ~93MB")
            print("      - Does NOT support legacy v3.5.2 4kHz chemistry")
            print()
            print("   2. Dorado 0.9.6 (legacy, for older 4kHz data)")
            print("      - Supports v3.5.2 models (dna_r10.4.1_e8.2_400bps_hac@v3.5.2)")
            print("      - Required for R10.4.1 4kHz chemistry data")
            print("      - Size: ~93MB")
            print()

            dorado_version_choice = input("   Select version (1 or 2) [default: 1]: ").strip()

            if dorado_version_choice == "2":
                dorado_version = "0.9.6"
                print(f"   {Colors.cyan_bold('Selected:')} Dorado 0.9.6 (legacy)" if is_tty() else "   Selected: Dorado 0.9.6")
            else:
                dorado_version = "1.3.1"
                print(f"   {Colors.cyan_bold('Selected:')} Dorado 1.3.1 (latest)" if is_tty() else "   Selected: Dorado 1.3.1")

            print()

            # First, ensure we have the Dorado binary
            dorado_bin = get_dorado_binary(version=dorado_version)

            if not dorado_bin:
                print(f"   {Colors.red_bold('Error')} Failed to download Dorado binary" if is_tty() else "   [Error] Failed to download Dorado binary")
                print()
                print("   You can download models manually using Docker:")
                print("      docker run -v $(pwd)/models:/models ontresearch/dorado:latest \\")
                print("        dorado download --model dna_r10.4.1_e8.2_400bps_hac@v5.2.0 --models-directory /models")
                print()
            else:
                print(f"   {Colors.green_bold('OK')} Dorado {dorado_version} binary ready: {dorado_bin}" if is_tty() else f"   [OK] Dorado {dorado_version} binary ready")
                print()
                # Add to downloaded items for summary
                downloaded_items.append((f"Dorado Binary v{dorado_version}", str(dorado_bin.parent.parent), "Auto-detected by pipelines"))

                # Download selected models
                for model_id in missing_models:
                    model_info = DORADO_MODELS[model_id]
                    if prompt_yes_no(f"   Download {model_info['name']}?", default=(model_id == "dna_r10.4.1_e8.2_400bps_hac@v5.2.0")):
                        print(f"   Downloading {model_info['name']}...")

                        try:
                            # Special handling for legacy v3.5.2 model - requires Dorado 0.9.6
                            if model_id == "dna_r10.4.1_e8.2_400bps_hac@v3.5.2":
                                # If user selected Dorado 0.9.6, use it directly instead of re-downloading
                                if dorado_version == "0.9.6":
                                    print(f"   Using Dorado 0.9.6 to download v3.5.2 model...")
                                    result = subprocess.run(
                                        [str(dorado_bin), "download", "--model", model_id, "--models-directory", str(models_dir)],
                                        capture_output=True,
                                        text=True,
                                        timeout=600
                                    )
                                    success = (result.returncode == 0)
                                else:
                                    # User has Dorado 1.3.1, need to download 0.9.6 temporarily
                                    success = _download_legacy_model_v352(models_dir)

                                if success:
                                    model_path = models_dir / model_id
                                    print(f"   {Colors.green_bold('OK')} {model_info['name']} installed!" if is_tty() else f"   [OK] {model_info['name']} installed!")
                                    print()
                                    print(f"   {Colors.cyan_bold('Model path:')} " if is_tty() else "   Model path:")
                                    print(f"   {model_path}")
                                    print(f"   Use with: --dorado-model {model_id}")
                                    print(f"   (Auto-detected if only one model is downloaded)")
                                    print()
                                    downloaded_items.append((f"Dorado Model: {model_info['name']}", str(model_path), f"--dorado-model {model_id} (auto-detected)"))
                                else:
                                    print(f"   {Colors.red_bold('Error')} Failed to download legacy v3.5.2 model" if is_tty() else "   [Error] Failed to download legacy model")
                            else:
                                # Use Dorado to download the model
                                result = subprocess.run(
                                    [str(dorado_bin), "download", "--model", model_id, "--models-directory", str(models_dir)],
                                    capture_output=True,
                                    text=True,
                                    timeout=600  # 10 minute timeout
                                )

                                if result.returncode == 0:
                                    model_path = models_dir / model_id
                                    if model_path.exists():
                                        print(f"   {Colors.green_bold('OK')} {model_info['name']} installed!" if is_tty() else f"   [OK] {model_info['name']} installed!")
                                        print()
                                        print(f"   {Colors.cyan_bold('Model path:')} " if is_tty() else "   Model path:")
                                        print(f"   {model_path}")
                                        print(f"   Use with: --dorado-model {model_id}")
                                        print(f"   (Auto-detected if only one model is downloaded)")
                                        print()
                                        downloaded_items.append((f"Dorado Model: {model_info['name']}", str(model_path), f"--dorado-model {model_id} (auto-detected)"))
                                    else:
                                        print(f"   {Colors.red_bold('Error')} Model directory not found after download" if is_tty() else "   [Error] Model not found")
                                else:
                                    error_msg = result.stderr.strip() if result.stderr else result.stdout.strip() if result.stdout else "Unknown error"
                                    print(f"   {Colors.red_bold('Error')} Download failed: {error_msg[:200]}" if is_tty() else f"   [Error] Download failed: {error_msg[:200]}")

                        except subprocess.TimeoutExpired:
                            print(f"   {Colors.red_bold('Error')} Download timed out (>10 minutes)" if is_tty() else "   [Error] Download timed out")
                        except Exception as e:
                            print(f"   {Colors.red_bold('Error')} {e}" if is_tty() else f"   [Error] {e}")

    elif not existing_models and not interactive:
        print(f"   {Colors.yellow_bold('Note:')} No Dorado models found. Run 'stamina-biome setup' interactively to download." if is_tty() else "   [Note] No models found")

    print()

    # Step 5: Summary
    print(Colors.cyan_bold("5. Summary") if is_tty() else "5. Summary")
    print()

    # Print downloaded items summary
    if downloaded_items:
        print(f"   {Colors.cyan_bold('Downloaded Resources:')} " if is_tty() else "   Downloaded Resources:")
        print()
        for name, path, usage in downloaded_items:
            print(f"   {Colors.green_bold(name)}:" if is_tty() else f"   {name}:")
            print(f"     Path:  {path}")
            print(f"     Usage: {usage}")
            print()

    if not issues:
        print(f"   {Colors.green_bold('All checks passed!')} STAMINA-BIOME is ready to use." if is_tty()
              else "   [OK] All checks passed! STAMINA-BIOME is ready to use.")

        if needs_shell_restart:
            print()
            print(f"   {Colors.yellow_bold('ACTION REQUIRED:')} Restart your terminal or run:" if is_tty()
                  else "   [ACTION REQUIRED] Restart your terminal or run:")
            shell_config, _ = get_shell_config_file()
            print(f"     source {shell_config}")

        print()
        print(f"   {Colors.orange_bold('Quick start:')}" if is_tty() else "   Quick start:")
        print(f"     {Colors.green('stamina-biome list')}                       # List available pipelines" if is_tty()
              else "     stamina-biome list                       # List available pipelines")
        print(f"     {Colors.green('stamina-biome run -p sr_amp -i reads/')}    # Run a pipeline" if is_tty()
              else "     stamina-biome run -p sr_amp -i reads/    # Run a pipeline")
        print()
        return 0
    else:
        print(f"   {Colors.yellow_bold('Setup incomplete:')} " if is_tty() else "   [WARN] Setup incomplete:")
        for issue in issues:
            print(f"   - {issue}")

        if needs_shell_restart:
            print()
            print(f"   {Colors.yellow_bold('Note:')} Restart your terminal to use 'stamina-biome' command globally." if is_tty()
                  else "   [Note] Restart your terminal to use 'stamina-biome' command globally.")

        print()
        print("   Run 'stamina-biome setup' again after resolving these issues.")
        print()
        return 1


def run_doctor() -> int:
    """Run system diagnostics and report status.

    Returns:
        Exit code (0 = all OK, 1 = issues found)
    """
    print()
    print(Colors.cyan_bold("STAMINA-BIOME Doctor") if is_tty() else "=== STAMINA-BIOME Doctor ===")
    print("=" * 40)
    print()

    all_ok = True

    # Check PATH
    print("PATH Configuration:")
    bin_dir = get_stamina_biome_bin_dir()
    if check_path_configured(bin_dir):
        stamina_biome_path = shutil.which("stamina-biome")
        path_display = stamina_biome_path if stamina_biome_path else str(bin_dir / "stamina-biome") + " (dir in PATH)"
        print(f"  {Colors.green_bold('OK')} stamina-biome is in PATH: {path_display}" if is_tty()
              else f"  [OK] stamina-biome is in PATH: {path_display}")
    else:
        print(f"  {Colors.yellow_bold('NOT IN PATH')} Run 'stamina-biome setup' to add to PATH" if is_tty()
              else "  [NOT IN PATH] Run 'stamina-biome setup' to add to PATH")
        print(f"  Current location: {bin_dir}/stamina-biome")

    print()

    # Check Docker
    print("Docker:")
    docker_ok, docker_msg = check_docker()
    if docker_ok:
        print(f"  {Colors.green_bold('OK')} {docker_msg}" if is_tty() else f"  [OK] {docker_msg}")

        # Check for required images
        try:
            result = subprocess.run(
                ["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                capture_output=True, text=True, timeout=10
            )
            images = result.stdout.strip().split('\n') if result.stdout.strip() else []

            required_images = [
                "stamina-biome-tools-lr",
                "stamina-biome-tools-sr",
                "quay.io/qiime2/amplicon",
            ]

            for img in required_images:
                found = any(img in i for i in images)
                if found:
                    print(f"  {Colors.green_bold('OK')} Image: {img}" if is_tty() else f"  [OK] Image: {img}")
                else:
                    print(f"  {Colors.yellow_bold('MISSING')} Image: {img} (will be pulled on first run)" if is_tty()
                          else f"  [MISSING] Image: {img}")
        except Exception:
            pass
    else:
        print(f"  {Colors.red_bold('ERROR')} {docker_msg}" if is_tty() else f"  [ERROR] {docker_msg}")
        all_ok = False

    print()

    # Check databases
    print("Databases:")
    data_dir = get_data_dir()

    found_any = False
    for db_id, db_info in DATABASES.items():
        db_path = data_dir / db_id
        if db_path.exists():
            found_any = True
            print(f"  {Colors.green_bold('OK')} {db_info['name']}: {db_path}" if is_tty()
                  else f"  [OK] {db_info['name']}: {db_path}")

    if not found_any:
        print(f"  {Colors.yellow_bold('NONE')} No databases installed" if is_tty() else "  [NONE] No databases installed")
        print(f"  Run 'stamina-biome setup' to download databases")

    print()

    # Check analysis tools
    print("Analysis Tools:")
    tools_dir = get_tools_dir()

    found_any_tools = False
    for tool_id, tool_info in TOOLS.items():
        tool_path = tools_dir / tool_id.upper()
        if tool_path.exists() and any(tool_path.iterdir()):
            found_any_tools = True
            print(f"  {Colors.green_bold('OK')} {tool_info['name']}: {tool_path}" if is_tty()
                  else f"  [OK] {tool_info['name']}: {tool_path}")

    if not found_any_tools:
        print(f"  {Colors.yellow_bold('NONE')} No analysis tools installed" if is_tty() else "  [NONE] No analysis tools installed")
        print(f"  Run 'stamina-biome setup' to download tools (e.g., VALENCIA for vaginal samples)")

    print()

    # Check disk space
    print("Disk Space:")
    has_space, available = check_disk_space(data_dir, 10)
    if available >= 50:
        print(f"  {Colors.green_bold('OK')} {available:.1f} GB available" if is_tty() else f"  [OK] {available:.1f} GB available")
    elif available >= 10:
        print(f"  {Colors.yellow_bold('LOW')} {available:.1f} GB available" if is_tty() else f"  [LOW] {available:.1f} GB available")
    else:
        print(f"  {Colors.red_bold('CRITICAL')} Only {available:.1f} GB available" if is_tty() else f"  [CRITICAL] {available:.1f} GB available")
        all_ok = False

    print()

    # Check Python packages (for compare module)
    print("Python Environment:")
    missing_pkgs = []
    for pkg, label in [("pandas", "pandas"), ("numpy", "numpy")]:
        try:
            mod = __import__(pkg)
            ver = getattr(mod, "__version__", "")
            print(f"  {Colors.green_bold('OK')} {label} {ver}" if is_tty() else f"  [OK] {label} {ver}")
        except ImportError:
            print(f"  {Colors.yellow_bold('MISSING')} {label} (required for compare command)" if is_tty()
                  else f"  [MISSING] {label} (required for compare command)")
            missing_pkgs.append(pkg)

    if missing_pkgs:
        print()
        print(f"  {Colors.cyan_bold('compare') if is_tty() else 'compare'} command requires: {', '.join(missing_pkgs)}")
        if prompt_yes_no(f"  Install {', '.join(missing_pkgs)} now?", default=True):
            # Determine the pip executable to use
            pip_candidates = []
            if not getattr(sys, 'frozen', False):
                # Running from source — use the same Python that's running this
                pip_candidates = [[sys.executable, "-m", "pip", "install"] + missing_pkgs]
            # Always try system pip3/pip as a fallback (covers frozen binary case)
            for pip_bin in ["pip3", "pip"]:
                found = shutil.which(pip_bin)
                if found:
                    pip_candidates.append([found, "install"] + missing_pkgs)
            # Try python3 -m pip as final fallback
            py3 = shutil.which("python3")
            if py3 and py3 != sys.executable:
                pip_candidates.append([py3, "-m", "pip", "install"] + missing_pkgs)

            installed = False
            for cmd in pip_candidates:
                try:
                    print(f"  Running: {' '.join(cmd)}")
                    result = subprocess.run(cmd, timeout=120, capture_output=False)
                    if result.returncode == 0:
                        print(f"  {Colors.green_bold('OK') if is_tty() else '[OK]'} Installed {', '.join(missing_pkgs)}")
                        print("  Note: Restart stamina-biome for changes to take effect.")
                        installed = True
                        break
                    else:
                        print(f"  {Colors.yellow_bold('WARN') if is_tty() else '[WARN]'} pip returned non-zero — trying next method")
                except Exception as e:
                    print(f"  {Colors.yellow_bold('WARN') if is_tty() else '[WARN]'} {e} — trying next method")

            if not installed:
                print(f"  {Colors.yellow_bold('WARN') if is_tty() else '[WARN]'} Could not install automatically.")
                print(f"  Run manually: pip3 install {' '.join(missing_pkgs)}")

    print()

    if all_ok:
        print(Colors.green_bold("All systems operational!") if is_tty() else "[OK] All systems operational!")
        return 0
    else:
        print(Colors.yellow_bold("Some issues found. Run 'stamina-biome setup' to resolve.") if is_tty()
              else "[WARN] Some issues found.")
        return 1
