# STAMINA-BIOME — Standardised, Technology-Agnostic Framework for Microbiome Investigation and Analysis

STAMINA-BIOME is a tool for analysing the microbiome — the community of microorganisms living in or on the human body. It takes raw sequencing data from a DNA sequencer and identifies which species are present and in what proportions.

It is designed to work with both **short-read** (Illumina) and **long-read** (Oxford Nanopore / PacBio) sequencing data, for both **16S amplicon** and **shotgun metagenomics** workflows. STAMINA-BIOME comes with a graphical app for everyday use and a command-line tool for scripted or HPC workflows.

---

## What Can It Do?

- Classify microbiome reads against reference databases (Kraken2, QIIME2, Emu)
- Re-estimate species-level abundances using Bracken
- Automatically classify vaginal samples into Community State Types (CSTs) using Valencia
- Compare microbiome profiles across multiple samples or runs
- Use body-site-specific databases tuned for vaginal, gut, oral, and skin microbiomes

---

## Before You Start

You will need two things installed on your computer before using STAMINA-BIOME:

| Requirement | Why | How to get it |
|-------------|-----|---------------|
| **Docker** | Runs all the bioinformatics tools inside containers so you don't have to install them individually | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| **R** (for the app only) | Runs the graphical interface | [Download R](https://cran.r-project.org/) or [RStudio](https://posit.co/download/rstudio-desktop/) (includes R) |

> **Important:** Docker must be **open and running** before you start a pipeline. On macOS you will see a small whale icon in your menu bar when it is running. On Windows it appears in the system tray.

> **New to the terminal?** On macOS, open the Terminal app by pressing `Cmd + Space`, typing "Terminal", and pressing Enter. On Windows, search for "Command Prompt" or "PowerShell" in the Start menu.

---

## Getting STAMINA-BIOME

Download the latest release for your computer from the [Releases page](https://github.com/izzydavidson/STAMINA-BIOME/releases):

| Your computer | File to download |
|---------------|-----------------|
| Mac (M1/M2/M3/M4 — Apple Silicon) | `stamina-biome-vX.X.X-macos-arm64.tar.gz` |
| Mac (older Intel) | `stamina-biome-vX.X.X-macos-x64.tar.gz` |
| Linux | `stamina-biome-vX.X.X-linux-x64.tar.gz` |

Not sure which Mac you have? Click the Apple menu → **About This Mac**. If it says "Apple M1" (or M2/M3/M4), download the Apple Silicon version. If it says "Intel", download the Intel version.

Once downloaded, you have two options to extract it:

- **Double-click** the downloaded `.tar.gz` file in Finder/Explorer — it will extract a folder automatically.
- **Or in a terminal:**

```bash
tar -xzf stamina-biome-vX.X.X-macos-arm64.tar.gz
```

This creates a folder called something like `stamina-biome-vX.X.X-macos-arm64`. Open a terminal and navigate into it:

```bash
cd ~/Downloads/stamina-biome-vX.X.X-macos-arm64
```

> **macOS security warning:** The first time you run STAMINA-BIOME, macOS may block it with a message like "cannot be opened because the developer cannot be verified". To allow it: open **System Settings → Privacy & Security**, scroll down, and click **Allow Anyway** next to the STAMINA-BIOME entry. Then try again.

---

## Setup (Run Once)

Run the setup wizard to install STAMINA-BIOME, check Docker, and download databases:

```bash
./stamina-biome setup
```

Follow the prompts. The wizard will:
1. Install `stamina-biome` so you can run it from any folder (not just this one)
2. Check that Docker is installed and help you install it if not
3. Offer to download reference databases
4. Offer to download VALENCIA for vaginal community state type analysis

When setup finishes, **close the terminal and open a new one**. This is important — it lets the terminal recognise the `stamina-biome` command. You only need to do this once.

Check everything is working:

```bash
stamina-biome doctor
```

You should see green `[OK]` next to Docker and your databases. If anything is red or yellow, the doctor will tell you what to do.

---

## Two Ways to Use STAMINA-BIOME

### Option 1 — Graphical App (recommended for most users)

The app gives you a point-and-click interface in your browser. No command-line knowledge required.

**To open the app:**

In a terminal, navigate to the `frontend` folder inside the STAMINA-BIOME directory, then start the app:

```bash
cd /path/to/STAMINA-BIOME/frontend
R -e "shiny::runApp()"
```

Replace `/path/to/STAMINA-BIOME-...` with the actual location on your computer. For example, if it is on your Desktop:

```bash
cd ~/Desktop/STAMINA-BIOME/frontend
R -e "shiny::runApp()"
```

Your browser will open automatically to the STAMINA-BIOME app. If it doesn't, look for a line in the terminal that says `Listening on http://127.0.0.1:XXXX` and paste that address into your browser.

> **The terminal window must stay open while you use the app** — it is the engine running in the background. To stop the app, click on the terminal and press `Ctrl+C`.

> **First launch:** R package dependencies are installed automatically the first time. This may take 1–2 minutes. You only need to wait for this once.

→ **Full app guide:** [docs/gui.md](docs/gui.md)

---

### Option 2 — Command Line

For users comfortable with the terminal, or for running STAMINA-BIOME on a server or HPC cluster.

```bash
# See all available pipelines
stamina-biome list

# Check your installation
stamina-biome doctor

# Run a pipeline (example: long-read metagenomics, vaginal sample)
stamina-biome run -p lr_meta \
  --input /path/to/reads.fastq \
  --sample-type vaginal \
  --db /path/to/stamina-biome-vaginal \
  --run-id my_sample_01

# Preview what would run without actually running it
stamina-biome run -p lr_meta --input /path/to/reads.fastq --db /path/to/db --dry-run
```

→ **Full CLI guide:** [docs/cli.md](docs/cli.md)

---

## Available Pipelines

| ID | Description | Input | Classifier |
|----|-------------|-------|------------|
| `lr_meta` | Long-read shotgun metagenomics | ONT / PacBio FASTQ, FAST5, POD5 | Kraken2 + Bracken |
| `lr_amp` | Long-read 16S amplicon | ONT / PacBio FASTQ, FAST5, POD5 | Emu or Kraken2 |
| `sr_meta` | Short-read shotgun metagenomics | Illumina FASTQ | Kraken2 + Bracken |
| `sr_amp` | Short-read 16S amplicon | Illumina FASTQ | QIIME2 / DADA2 |

---

## Databases

STAMINA-BIOME works with standard Kraken2 databases and ships body-site-specific databases tuned for each microbiome:

| Database | Body site | Includes |
|----------|-----------|----------|
| `stamina-biome-vaginal` | Vaginal | All CST-relevant *Lactobacillus* spp., *Gardnerella*, BV anaerobes, STI pathogens, vaginal fungi |
| `stamina-biome-gut` | Gut | Gut-relevant commensals and pathogens, validated against CAMISIM ground truth |
| `stamina-biome-oral` | Oral | Oral-relevant species including periodontal organisms |
| `stamina-biome-skin` | Skin | Skin-relevant species including *Staphylococcus*, *Cutibacterium*, *Malassezia* |

Generic Kraken2 databases (Standard-8, Standard-16, PlusPF) also work with all metagenomics pipelines.

**Download:** STAMINA-BIOME body-site databases are available on [Zenodo (DOI: 10.5281/zenodo.19617383)](https://doi.org/10.5281/zenodo.19617383) and via the setup wizard (`stamina-biome setup`). Build scripts for constructing or extending these databases are in the `validation/` directory of this repository.

→ **Database guide (including how to download and build custom databases):** [docs/databases.md](docs/databases.md)

---

## What Do I Get?

Each time you run a pipeline, STAMINA-BIOME creates a results folder named after your run ID (or a timestamp if you didn't set one):

```
outputs/
└── my_sample_01/
    ├── config.json                         ← exact settings used for this run
    ├── logs/                               ← full pipeline log if you need to troubleshoot
    └── results/
        └── tables/
            ├── kraken_species_tidy.csv     ← species-level abundances  ← open this first
            ├── kraken_genus_tidy.csv       ← genus-level abundances
            ├── summary_stats.csv           ← read counts and QC summary
            └── valencia_cst.csv            ← community state type (vaginal only)
```

The main file to look at is **`kraken_species_tidy.csv`** — it tells you which species are present and in what proportions. You can open it directly in Excel, R, or Python.

---

## Documentation

| Guide | Who it's for |
|-------|-------------|
| [App Guide](docs/gui.md) | First-time users, point-and-click interface |
| [CLI Guide](docs/cli.md) | Advanced users, scripting, HPC |
| [Databases](docs/databases.md) | Setting up and managing reference databases |

---

## Publication

[Citation pending — manuscript in preparation]

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Questions and Support

[Open an issue](https://github.com/izzydavidson/STAMINA-BIOME/issues) for bug reports, questions, or feature requests.
