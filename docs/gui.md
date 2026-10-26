# STAMINA-BIOME App Guide

The STAMINA-BIOME Shiny app lets you run microbiome analysis pipelines through a browser-based graphical interface — no command-line knowledge required after the initial installation.

---

## Requirements

Before launching the app, make sure you have:

| Requirement | How to get it | Check |
|-------------|---------------|-------|
| **R (version 4.0 or newer)** | [Download R](https://cran.r-project.org/) | Type `R --version` in a terminal |
| **Docker (running)** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) | Whale icon visible in menu bar |
| **STAMINA-BIOME setup completed** | Run `./stamina-biome setup` from the downloaded folder | Run `stamina-biome doctor` |

> R packages needed by the app (`shiny`, `bslib`, `jsonlite`, and others) are **installed automatically** on first launch — you don't need to install them manually.

---

## Launching the App

Open a terminal, navigate to the `frontend` folder inside the STAMINA-BIOME directory, and start the app:

```bash
cd /path/to/STAMINA-BIOME/frontend
R -e "shiny::runApp()"
```

Replace `/path/to/STAMINA-BIOME-...` with wherever you extracted the STAMINA-BIOME folder.

**Example** — if STAMINA-BIOME is on your Desktop:
```bash
cd ~/Desktop/STAMINA-BIOME/frontend
R -e "shiny::runApp()"
```

**What happens next:**
1. The STAMINA-BIOME banner appears in the terminal with a coloured border
2. Missing R packages are installed automatically (first launch only — may take 1–2 minutes)
3. The app prints a "Ready" message and your browser opens automatically

If your browser doesn't open, copy the URL from the terminal (it looks like `http://127.0.0.1:5859`) and paste it into your browser.

> **Keep the terminal open** while using the app — it is the "engine" running in the background. To stop the app, come back to the terminal and press `Ctrl+C`.

### From RStudio

If you prefer RStudio:
1. Open `frontend/app.R` in RStudio
2. Click the **Run App** button in the top-right corner of the editor

---

## First Launch — Setup Wizard

The first time you open the app, the Setup Wizard will appear. It guides you through:
- Locating the `stamina-biome` binary on your computer
- Setting your default output directory
- Confirming your database paths

Complete the wizard before running your first pipeline. You can return to it at any time from the dashboard.

---

## Pages

### Dashboard

The home page shows:
- A count of your completed, in-progress, and failed runs
- A table of your 10 most recent runs with their status and date
- A **Refresh** button to manually update the list

From here you can also return to the Setup Wizard if you need to change paths or settings.

---

### Long Read

Use this page for Oxford Nanopore or PacBio sequencing data.

**Supported pipelines:**
- `lr_meta` — Long-read shotgun metagenomics (Kraken2 + Bracken)
- `lr_amp` — Long-read 16S amplicon (Emu or Kraken2)

#### Step-by-step

**1. Set your input**

Click **File** to select a single FASTQ file, or **Folder** to select a directory of FASTQ files. You can also type a path directly into the text box, or drag and drop a file or folder from Finder onto the input area.

If your data is in FAST5 or POD5 format (raw signal), select **FAST5** or **POD5** from the format dropdown. Additional fields will appear for Dorado basecalling (see [Basecalling](#basecalling-fast5--pod5) below).

**2. Choose a pipeline**

Select `lr_meta` (metagenomics) or `lr_amp` (16S amplicon) from the Pipeline dropdown.

**3. Set your sample type**

Select the body site your sample is from. This automatically sets the best Kraken2 confidence and minimum hit group thresholds for that site:

| Sample type | Confidence | Min hit groups |
|-------------|-----------|----------------|
| Vaginal | 0.02 | 2 |
| Gut | 0.03 | 4 |
| Oral | 0.04 | 4 |
| Skin | 0.03 | 4 |
| Other | 0.05 | 2 |

You can adjust these manually if you need to.

**4. Set your Kraken2 database**

Click **Browse** next to the Kraken2 Database field and select the database directory. The folder should contain `hash.k2d`, `taxo.k2d`, and `opts.k2d` files.

**5. Set a Run ID (optional)**

Give your run a name — for example `patient_01_run1`. If you leave it blank, a timestamp will be used.

**6. Click Run**

The pipeline starts. Switch to the log panel to watch live output.

---

#### Basecalling (FAST5 / POD5)

If your input is in FAST5 or POD5 format, enable the **Basecalling** toggle. You will need:

- **Dorado binary** — the path to the Dorado executable (installed via `stamina-biome setup`)
- **Models directory** — the folder containing downloaded Dorado models
- **Model** — select from the models found in that directory

If you installed Dorado via the setup wizard, the paths are usually detected automatically. Click **Browse** next to each field if they are not filled in.

---

### Short Read

Use this page for Illumina (or compatible) sequencing data.

**Supported pipelines:**
- `sr_meta` — Short-read shotgun metagenomics (Kraken2 + Bracken)
- `sr_amp` — Short-read 16S amplicon (QIIME2 / DADA2)

#### Step-by-step

**1. Set your input**

For paired-end reads, point to the folder containing your R1 and R2 FASTQ files — STAMINA-BIOME finds the pairs automatically. For single-end reads, select the file or folder directly.

**2. Choose a pipeline**

Select `sr_meta` for metagenomics or `sr_amp` for amplicon sequencing.

**3. Set your sample type and database**

Same as the Long Read page. For `sr_amp`, the database field is replaced by a QIIME2 classifier selector.

**4. Primers (sr_amp only)**

For amplicon sequencing, enter your forward and reverse primer sequences. Common presets:

| Region | Forward primer | Reverse primer |
|--------|---------------|----------------|
| V3–V4 | `CCTACGGGNGGCWGCAG` | `GACTACHVGGGTATCTAATCC` |
| V4 | `GTGYCAGCMGCCGCGGTAA` | `GGACTACNVGGGTWTCTAAT` |

**5. Click Run**

---

### Compare

Compare microbiome profiles from two or more completed runs.

**Two input modes:**

**Mode 1 — Select from your runs:**
Use the dropdowns to select two completed runs from your outputs folder. This is the easiest method.

**Mode 2 — CSV files:**
Provide paths to `kraken_species_tidy.csv` files directly. Click Browse, type a path, or drag and drop the file onto the input field.

**Settings:**

| Setting | Description |
|---------|-------------|
| Taxonomic rank | Compare at species, genus, or family level |
| Top N taxa | How many taxa to show in plots (default: 20) |
| Normalisation | Relative abundance or CLR-transformed |

Click **Run Comparison** to generate the report. The output includes:
- A heatmap of species abundances across runs
- A stacked bar chart per run
- A Venn diagram of taxa overlap
- An HTML report you can save and share

---

### Setup Wizard

Accessible from the dashboard by clicking **Return to Setup Wizard**. Use this to:
- Update your `stamina-biome` binary path
- Change your default output directory
- Set or change your database paths
- Download additional databases or tools

---

## File Input — Three Ways

Every file and directory field in the app supports:

1. **Type a path** — paste or type a full absolute path (e.g. `/Users/yourname/data/sample.fastq`)
2. **Browse** — click to open a native file/folder picker
3. **Drag and drop** — drag a file or folder from Finder directly onto the input field

If you cancel the Browse dialog, the field stays unchanged.

---

## Log Panel

Once a pipeline starts, the log panel streams live output from the pipeline process:
- Read counts and classification progress
- Bracken re-estimation steps
- Output file paths as they are created
- Any errors or warnings

You can navigate to other pages while the pipeline runs — it continues in the background. Return to the log panel at any time to check progress.

---

## Where Are My Results?

Results are saved to your output directory (default: the `outputs/` folder inside the STAMINA-BIOME directory). Each run creates a subfolder named after your Run ID:

```
outputs/
└── patient_01_run1/
    ├── config.json              # settings used for this run
    ├── outputs.json             # list of all output files
    ├── logs/                    # full pipeline log
    └── results/
        └── tables/
            ├── results.csv                 # main results
            ├── kraken_species_tidy.csv     # species abundances
            ├── kraken_genus_tidy.csv       # genus-level abundances
            └── valencia_cst.csv            # CST type (vaginal only)
```

Open `kraken_species_tidy.csv` in Excel or R to see which species are present and in what proportions.

---

## Troubleshooting

### The browser doesn't open automatically

Copy the URL printed in the terminal (e.g. `http://127.0.0.1:5859`) and paste it into your browser.

### R packages fail to install on first launch

Check that R has permission to write to its library folder. On macOS, you may see a prompt asking which library to use — select your personal library (the option containing your username).

### "Docker not running" error when starting a pipeline

Open Docker Desktop and wait until the whale icon in your menu bar stops animating and shows "Docker Desktop is running". Then try again.

### Browse button doesn't open a picker

The Browse button opens a native macOS file picker. If nothing happens:
- Check **System Settings → Privacy & Security → Automation** — your terminal app may need permission to control the system
- As a workaround, type or paste the path directly into the text box

### Pipeline started but no output was created

Check the log panel for error messages. Common causes:
- The database path is wrong (the folder doesn't contain `hash.k2d`)
- Docker doesn't have enough memory — increase it in Docker Desktop settings (at least 8 GB recommended)
- The database is missing a Bracken kmer_distrib file — see the [Databases guide](databases.md)

### The app crashes or goes dark

A crash is usually caused by an unexpected error in one of the inputs. Restart the app:
```bash
R -e "shiny::runApp()"
```
Check `stamina-biome doctor` to make sure everything is still configured correctly.
