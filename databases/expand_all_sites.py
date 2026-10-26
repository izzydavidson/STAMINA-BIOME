#!/usr/bin/env python3
"""
expand_all_sites.py — STAMINA-BIOME v6 comprehensive database expansion
Covers all four body sites: vaginal, gut, oral, skin

For each body site this script:
  1. Looks up the best RefSeq genome for each taxid via the NCBI Datasets API
  2. Downloads and decompresses the genome from the NCBI FTP
  3. Rewrites FASTA headers to kraken:taxid format
  4. Places the file in db/library/added/ ready for kraken2-build --build
  5. Appends new entries to the site's genome_list.tsv

Prerequisites:
  - Internet access to NCBI
  - kraken2-build accessible (run standalone or inside the stamina-biome-tools-lr
    Docker image following the same pattern as databases/vaginal/build.sh)

Usage — single site:
    python3 expand_all_sites.py \\
        --site vaginal \\
        --db /path/to/stamina-biome-vaginal \\
        --genome-list /path/to/STAMINA-BIOME/databases/vaginal/genome_list.tsv \\
        [--threads 8] [--dry-run]

Usage — all four sites (db-base must contain gut/ oral/ skin/ vaginal/ subdirs):
    python3 expand_all_sites.py \\
        --site all \\
        --db-base /Volumes/MyPassport/custom_db \\
        --repo-root /path/to/STAMINA-BIOME \\
        [--threads 8] [--dry-run]

After running, rebuild the affected database(s):
    kraken2-build --build --db /path/to/db --threads 8
    for len in 500 750 1000 1200 1500 2000; do
        bracken-build -d /path/to/db -l $len -k 35 -t 8
    done
"""

import argparse
import csv
import gzip
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# NCBI helpers
# ─────────────────────────────────────────────────────────────────────────────

NCBI_DATASETS_API = (
    "https://api.ncbi.nlm.nih.gov/datasets/v2/genome/taxon/"
    "{taxid}/dataset_report?filters.assembly_source=refseq"
    "&filters.exclude_atypical=true&page_size=20"
)
NCBI_FTP_BASE = "https://ftp.ncbi.nlm.nih.gov/genomes/all"
API_SLEEP = 0.4   # seconds between NCBI API calls (polite rate limit)


def _request(url: str, timeout: int = 30):
    req = urllib.request.Request(
        url, headers={"User-Agent": "STAMINA-BIOME-expand/2.0 (research)"}
    )
    return urllib.request.urlopen(req, timeout=timeout)


def resolve_best_accession(taxid: int) -> str | None:
    """Return the best RefSeq GCF accession for a taxid (reference > representative > complete)."""
    url = NCBI_DATASETS_API.format(taxid=taxid)
    try:
        with _request(url) as r:
            data = json.load(r)
    except Exception as e:
        print(f"    [API ERROR] taxid={taxid}: {e}")
        return None

    reports = data.get("reports", [])
    if not reports:
        return None

    RANK  = {"reference genome": 0, "representative genome": 1}
    LEVEL = {"Complete Genome": 0, "Chromosome": 1, "Scaffold": 2, "Contig": 3}

    best_acc, best_rank, best_level = None, 99, 99
    for rep in reports:
        acc = rep.get("accession", "")
        if not acc.startswith("GCF_"):
            continue
        ainfo    = rep.get("assembly_info", {})
        refcat   = ainfo.get("refseq_category", "").lower()
        level    = ainfo.get("assembly_level", "Contig")
        r_rank   = RANK.get(refcat, 2)
        r_level  = LEVEL.get(level, 3)
        if (r_rank < best_rank) or (r_rank == best_rank and r_level < best_level):
            best_acc, best_rank, best_level = acc, r_rank, r_level

    return best_acc


def _acc_to_ftp_dir(acc: str) -> str:
    """GCF_014131755.1  →  GCF/014/131/755"""
    prefix, rest = acc.split("_", 1)
    digits = rest.split(".")[0]
    return f"{prefix}/{digits[0:3]}/{digits[3:6]}/{digits[6:9]}"


def resolve_ftp_path(acc: str) -> str | None:
    """Resolve a GCF accession to the full NCBI FTP folder URL."""
    ftp_dir = f"{NCBI_FTP_BASE}/{_acc_to_ftp_dir(acc)}/"
    try:
        with _request(ftp_dir) as r:
            html = r.read().decode()
    except Exception as e:
        print(f"    [FTP ERROR] {acc}: {e}")
        return None

    folders = re.findall(rf'href="({re.escape(acc)}[^"]+)/"', html)
    if not folders:
        return None
    return f"{ftp_dir}{folders[0].rstrip('/')}/"


def download_genome(taxid: int, species: str, ftp_base: str, out_dir: Path) -> Path | None:
    """
    Download <acc>_genomic.fna.gz, rewrite headers to kraken:taxid format,
    write to out_dir.  Returns the output path on success, None on failure.
    """
    ftp_base  = ftp_base.rstrip("/")
    basename  = ftp_base.split("/")[-1]
    fna_url   = f"{ftp_base}/{basename}_genomic.fna.gz"
    out_file  = out_dir / f"{taxid}_{basename}_genomic.fna"

    if out_file.exists():
        print(f"  [SKIP] {species} — already downloaded: {out_file.name}")
        return out_file

    try:
        with _request(fna_url, timeout=180) as r:
            gz_data = r.read()
    except Exception as e:
        print(f"  [DL ERROR] {species} (taxid={taxid}): {e}")
        return None

    seq_count = 0
    try:
        with gzip.open(io.BytesIO(gz_data), "rt") as fin, open(out_file, "w") as fout:
            for line in fin:
                if line.startswith(">"):
                    seq_id = line[1:].split()[0].strip()
                    fout.write(f">kraken:taxid|{taxid}|{seq_id}\n")
                    seq_count += 1
                else:
                    fout.write(line)
    except Exception as e:
        print(f"  [WRITE ERROR] {species}: {e}")
        out_file.unlink(missing_ok=True)
        return None

    print(f"  [OK] {species} (taxid={taxid}) — {seq_count} sequences → {out_file.name}")
    return out_file


# ─────────────────────────────────────────────────────────────────────────────
# genome_list.tsv helpers
# ─────────────────────────────────────────────────────────────────────────────

def load_genome_list_taxids(tsv_path: Path) -> set[int]:
    """Return the set of taxids already recorded in genome_list.tsv."""
    if not tsv_path.exists():
        return set()
    seen = set()
    with open(tsv_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("accession"):
                continue
            parts = line.split("\t")
            if len(parts) >= 3:
                try:
                    seen.add(int(parts[2]))
                except ValueError:
                    pass
    return seen


def append_genome_list(tsv_path: Path, acc: str, species: str, taxid: int, notes: str):
    """Append a new row to genome_list.tsv."""
    today = date.today().isoformat()
    row = f"{acc}\t{species}\t{taxid}\tncbi_expand_{today}\t{notes}\n"
    with open(tsv_path, "a") as f:
        f.write(row)


# ─────────────────────────────────────────────────────────────────────────────
# SPECIES LISTS
# ─────────────────────────────────────────────────────────────────────────────
# Format: taxid → (display_name, category, notes)
# Sources per site are cited in the section headers.
# ─────────────────────────────────────────────────────────────────────────────

# ── VAGINAL ───────────────────────────────────────────────────────────────────
# Sources: Ravel et al. (2011) PNAS (CSTs), Muzny & Schwebke (2014) Trends Microbiol,
#          Hardy et al. (2017) Front Microbiol, Lennard et al. (2020) Microbiome,
#          HMP vaginal body site data, HOMD vaginal section
VAGINAL_TAXA = {
    # ── Core Lactobacillus — CST-defining ────────────────────────────────────
    47770:   ("Lactobacillus crispatus",          "core",     "CST I dominant; multiple strains needed"),
    147802:  ("Lactobacillus iners",              "core",     "CST III dominant; multiple strains"),
    109790:  ("Lactobacillus jensenii",           "core",     "CST V"),
    1596:    ("Lactobacillus gasseri",            "core",     "CST II"),
    1633:    ("Limosilactobacillus vaginalis",    "core",     "CST IV adjacent"),
    1579:    ("Lactobacillus acidophilus",        "core",     "Common vaginal coloniser"),
    1613:    ("Limosilactobacillus fermentum",    "core",     "Occasional vaginal isolate"),
    2508708: ("Lactobacillus mulieris",           "core",     "Vaginal-specific Lactobacillus; Wittouck et al. 2019"),

    # ── Gardnerella ───────────────────────────────────────────────────────────
    2702:    ("Gardnerella vaginalis",            "core",     "Primary BV pathogen; multiple strains"),
    2792977: ("Gardnerella piotii",               "core",     "Recently reclassified from G. vaginalis"),
    2792978: ("Gardnerella leopoldii",            "core",     "Recently reclassified from G. vaginalis"),
    2914925: ("Gardnerella greenwoodii",          "core",     "4th Gardnerella species; Robinson et al. 2019"),

    # ── BV-associated anaerobes ───────────────────────────────────────────────
    82135:   ("Fannyhessea vaginae",              "core",     "Atopobium vaginae; key BV marker"),
    40543:   ("Sneathia sanguinegens",            "core",     "Strong BV association; often missed"),
    187101:  ("Sneathia vaginalis",               "core",     "Strong BV association; preterm birth"),
    1000568: ("Megasphaera lornae",               "core",     "CST IV BV marker"),
    2051:    ("Mobiluncus curtisii",              "core",     "BV curved rod; smaller than M. mulieris"),
    419005:  ("Prevotella amnii",                 "core",     "BV-specific Prevotella"),
    386414:  ("Hoylesella timonensis",            "core",     "Vaginal Prevotella-related sp.; reclassified"),
    28125:   ("Prevotella bivia",                 "core",     "In CAMISIM; BV-associated"),
    309120:  ("Dialister micraerophilus",         "core",     "CST IV BV marker"),
    33036:   ("Anaerococcus tetradius",           "core",     "BV-associated anaerobic coccus"),
    33037:   ("Anaerococcus vaginalis",           "core",     "BV-associated anaerobic coccus"),
    33034:   ("Anaerococcus prevotii",            "core",     "BV-associated; in vaginal CAMISIM simulation genomes"),
    33032:   ("Anaerococcus lactolyticus",        "core",     "BV-associated vaginal anaerobe"),
    1260:  ("Finegoldia magna",                 "core",     "Opportunistic anaerobe; BV/PID"),
    54005:  ("Peptoniphilus harei",              "core",     "BV-associated anaerobic coccus"),
    33031:   ("Peptoniphilus lacrimalis",         "core",     "BV-associated"),
    1258:    ("Peptoniphilus asaccharolyticus",   "core",     "BV-associated anaerobic coccus; HMP vaginal isolate"),
    1261:    ("Peptostreptococcus anaerobius",    "core",     "Anaerobic streptococcus; BV/PID"),
    33033:   ("Parvimonas micra",                 "core",     "Vaginal anaerobe; BV/PID"),
    177972:  ("Shuttleworthella satelles",         "core",     "BVAB2; high BV specificity"),
    851:     ("Fusobacterium nucleatum",          "core",     "Preterm birth association"),

    # ── Sexually transmitted infections ───────────────────────────────────────
    813:     ("Chlamydia trachomatis",            "pathogen", "Most common bacterial STI; multiple serovars"),
    485:     ("Neisseria gonorrhoeae",            "pathogen", "Gonorrhoea; drug-resistant strains critical"),
    160:     ("Treponema pallidum",               "pathogen", "Syphilis; primary/secondary/latent"),
    2097:    ("Mycoplasmoides genitalium",         "pathogen", "Emerging STI; macrolide resistance rising; reclassified from Mycoplasma genitalium"),
    2098:    ("Metamycoplasma hominis",           "pathogen", "BV/PID association; tetracycline resistance; reclassified from Mycoplasma hominis"),
    134821:  ("Ureaplasma parvum",               "pathogen", "Urogenital mycoplasma; preterm birth"),
    730:     ("Haemophilus ducreyi",              "pathogen", "Chancroid causative agent"),
    2130:    ("Ureaplasma urealyticum",           "pathogen", "In CAMISIM; additional strains needed"),
    5722:    ("Trichomonas vaginalis",            "pathogen", "Most common non-viral STI globally; protozoan parasite"),

    # ── Fungal pathogens (vulvovaginal candidiasis) ───────────────────────────
    5476:    ("Candida albicans",                 "pathogen", "VVC; most common (70-90% of cases)"),
    5478:    ("Nakaseomyces glabratus",           "pathogen", "Was Candida glabrata; fluconazole-resistant VVC; reclassified"),
    5482:    ("Candida tropicalis",               "pathogen", "VVC; emerging azole resistance"),
    4909:    ("Pichia kudriavzevii",              "pathogen", "Candida krusei; intrinsically fluconazole-resistant"),
    5480:    ("Lodderomyces parapsilosis",         "pathogen", "VVC; biofilm former; neonatal risk; reclassified from Candida parapsilosis"),
    42374:   ("Candida dubliniensis",             "pathogen", "VVC; morphologically similar to C. albicans"),

    # ── Other reproductive tract bacteria ─────────────────────────────────────
    1311:    ("Streptococcus agalactiae",         "pathogen", "GBS; in CAMISIM; neonatal sepsis risk"),
    1280:    ("Staphylococcus aureus",            "pathogen", "Toxic shock; occasional vaginal pathogen"),
    1282:    ("Staphylococcus epidermidis",       "commensal","Vaginal commensal"),
    1351:    ("Enterococcus faecalis",            "commensal","Common vaginal commensal"),
    87541:   ("Aerococcus christensenii",         "rare",     "Vaginal isolate; urinary tract association"),
    1376:    ("Aerococcus urinae",                "rare",     "Urogenital Aerococcus; UTI and vaginal isolate; NCBI taxid 1376"),

    # ── Additional BV-associated anaerobes ───────────────────────────────────
    2052:    ("Mobiluncus mulieris",              "core",     "BV-associated curved rod; CAMISIM simulation genome"),
    28130:   ("Prevotella disiens",               "core",     "BV-associated Prevotella; vaginal anaerobe"),
    28127:   ("Hoylesella buccalis",              "core",     "Was Prevotella buccalis; BV-associated vaginal anaerobe"),
    33029:   ("Anaerococcus hydrogenalis",        "core",     "BV-associated anaerobic coccus; vaginal isolate"),
    411577:  ("Anaerococcus murdochii",           "core",     "BV-associated anaerobic coccus; vaginal isolate"),
    28123:   ("Porphyromonas asaccharolytica",    "core",     "BV-associated Porphyromonas; vaginal anaerobe"),
    33030:   ("Peptoniphilus indolicus",          "core",     "BV-associated Peptoniphilus; vaginal anaerobe"),

    # ── Rare vaginal isolates ─────────────────────────────────────────────────
    116089:  ("Lactobacillus psittaci",           "rare",     "Rare vaginal Lactobacillus; NCBI taxid 116089 confirmed"),
    242750:  ("Hallella bergensis",               "rare",     "Vaginal Bacteroidota; rare isolate"),
    54006:   ("Aedoeadaptatus ivorii",            "rare",     "Vaginal Prevotellaceae; rare isolate"),
}

# ── GUT ───────────────────────────────────────────────────────────────────────
# Sources: Qin et al. (2010) Nature (MetaHIT), HMP gut, Sonnenburg lab,
#          Turnbaugh et al. (2009), Backhed et al. (2005), UHGG v2 (2021),
#          Forster et al. (2019) Nat Biotechnol
GUT_TAXA = {
    # ── Bacteroides (dominant phylum: Bacteroidota) ───────────────────────────
    818:     ("Bacteroides thetaiotaomicron",     "core",     "In CAMISIM; polysaccharide utilisation"),
    820:     ("Bacteroides uniformis",            "core",     "Major gut symbiont; fibre fermentation"),
    28116:   ("Bacteroides ovatus",               "core",     "Major gut symbiont; hemicellulose"),
    821:     ("Phocaeicola vulgatus",             "core",     "Was Bacteroides vulgatus; reclassified 2020; one of most abundant gut bacteria"),
    47678:   ("Bacteroides caccae",               "core",     "Common gut Bacteroides"),
    46506:   ("Bacteroides stercoris",            "core",     "Common gut Bacteroides"),
    817:     ("Bacteroides fragilis",             "core",     "In CAMISIM; commensal + opportunistic"),
    28111:   ("Bacteroides eggerthii",            "core",     "Common gut Bacteroides"),
    823:     ("Parabacteroides distasonis",       "core",     "Gut commensal; bile resistance"),
    46503:   ("Parabacteroides merdae",           "core",     "Gut commensal"),
    28117:    ("Alistipes putredinis",             "core",     "Gut commensal; amino acid fermentation"),
    214856:  ("Alistipes finegoldii",             "core",     "Gut commensal"),
    328814:  ("Alistipes shahii",                 "core",     "Gut commensal"),
    239935:  ("Akkermansia muciniphila",          "core",     "In CAMISIM; mucin degrader; metabolic health"),

    # ── Butyrate producers (Firmicutes/Bacillota) ─────────────────────────────
    853:     ("Faecalibacterium prausnitzii",     "core",     "In CAMISIM; most abundant butyrate producer"),
    40518:   ("Ruminococcus bromii",              "core",     "Key resistant starch degrader; 'keystone'"),
    33039:   ("Mediterraneibacter torques",       "core",     "Was Ruminococcus torques; mucin degrader; reclassified 2020"),
    39491:   ("Agathobacter rectalis",            "core",     "Was Eubacterium rectale; major butyrate producer; 5-10% gut bacteria"),
    39488:   ("Anaerobutyricum hallii",           "core",     "Was Eubacterium hallii; butyrate producer; acetate crossfeeder"),
    39496:   ("Eubacterium ventriosum",           "core",     "Gut commensal"),
    116085:  ("Pseudocoprococcus catus",          "core",     "Was Coprococcus catus; reclassified 2020; butyrate producer; mental health link"),
    88431:   ("Dorea longicatena",                "core",     "Common gut commensal"),
    39486:   ("Dorea formicigenerans",            "core",     "Gut commensal"),
    166486:   ("Roseburia intestinalis",           "core",     "In CAMISIM; butyrate producer"),
    301301:  ("Roseburia hominis",                "core",     "Butyrate producer; motile"),
    360807:  ("Roseburia inulinivorans",          "core",     "Inulin/starch fermentation"),
    418240:  ("Blautia wexlerae",                 "core",     "Positively associated with gut health"),
    1260:  ("Finegoldia magna",                 "core",     "Obligate anaerobe; gut commensal"),

    # ── Bifidobacterium ───────────────────────────────────────────────────────
    216816:    ("Bifidobacterium longum",           "core",     "In CAMISIM; dominant adult probiotic sp."),
    1680:    ("Bifidobacterium adolescentis",     "core",     "Dominant adult Bifidobacterium"),
    1685:    ("Bifidobacterium breve",            "core",     "Dominant infant gut; probiotic"),
    1681:    ("Bifidobacterium bifidum",          "core",     "HMO degrader; infant gut"),
    28025:   ("Bifidobacterium animalis",         "core",     "Commercial probiotic; ssp. lactis"),
    1683:    ("Bifidobacterium angulatum",        "core",     "Adult gut commensal"),

    # ── Lactobacillus / related ────────────────────────────────────────────────
    47715:   ("Lacticaseibacillus rhamnosus",    "core",     "In CAMISIM; widely used probiotic"),
    1590:    ("Lactiplantibacillus plantarum",   "core",     "Fermented foods; gut health"),

    # ── Archaea ───────────────────────────────────────────────────────────────
    2173:  ("Methanobrevibacter smithii",      "core",     "Dominant gut archaeon; H2 consumption"),
    2317:    ("Methanosphaera stadtmanae",       "core",     "Gut archaeon; methanol utilisation"),

    # ── Prevotella ────────────────────────────────────────────────────────────
    165179:  ("Prevotella copri",                "core",     "In CAMISIM; plant-based diet marker; RA link"),
    712965:  ("Prevotella stercorea",            "core",     "Common gut Prevotella"),

    # ── Enteropathogens ───────────────────────────────────────────────────────
    210:     ("Helicobacter pylori",             "pathogen", "In CAMISIM; peptic ulcer; gastric cancer"),
    28901:   ("Salmonella enterica",             "pathogen", "Non-typhoidal salmonellosis; food poisoning"),
    54736:   ("Salmonella bongori",              "pathogen", "Non-typhoidal Salmonella; poultry-associated"),
    623:     ("Shigella flexneri",               "pathogen", "Dysentery; faecal-oral transmission"),
    624:     ("Shigella sonnei",                 "pathogen", "Most common Shigella in developed countries"),
    622:     ("Shigella dysenteriae",            "pathogen", "Severe dysentery; Shiga toxin"),
    197:     ("Campylobacter jejuni",            "pathogen", "Most common bacterial food poisoning globally"),
    195:     ("Campylobacter coli",              "pathogen", "Foodborne illness; poultry-associated"),
    1491:    ("Clostridium botulinum",           "pathogen", "Botulism toxin; food/wound/infant"),
    1496:    ("Clostridioides difficile",        "pathogen", "In CAMISIM; CDI; major nosocomial pathogen"),
    1502:    ("Clostridium perfringens",         "pathogen", "Gas gangrene; food poisoning Type A/C"),
    1351:    ("Enterococcus faecalis",           "pathogen", "VRE risk; gut commensal + opportunistic"),
    1352:    ("Enterococcus faecium",            "pathogen", "VRE — most clinically resistant Enterococcus"),
    630:     ("Yersinia enterocolitica",         "pathogen", "Yersiniosis; cold-chain foodborne"),
    633:     ("Yersinia pseudotuberculosis",     "pathogen", "Foodborne illness; Far East scarlet fever"),
    666:     ("Vibrio cholerae",                 "pathogen", "Cholera; pandemic risk"),
    670:     ("Vibrio parahaemolyticus",         "pathogen", "Seafood-associated gastroenteritis"),
    1639:    ("Listeria monocytogenes",          "pathogen", "Listeriosis; fatal in pregnancy/immunocomp"),
    562:     ("Escherichia coli",               "pathogen", "In CAMISIM; commensal + multiple pathotypes"),
    1045010:   ("Escherichia coli O157",           "pathogen", "EHEC; Shiga toxin; haemolytic uremic syndrome"),
    851:     ("Fusobacterium nucleatum",         "pathogen", "Colorectal cancer; gut coloniser"),
    644:     ("Aeromonas hydrophila",            "pathogen", "Waterborne gastroenteritis; wound infections"),
    573:     ("Klebsiella pneumoniae",           "pathogen", "Gut opportunist; ESKAPE pathogen"),
    287:     ("Pseudomonas aeruginosa",          "pathogen", "Gut opportunist in ICU/immunocomp"),
    28197:   ("Arcobacter butzleri",             "pathogen", "Emerging enteropathogen; water/poultry"),
    648:     ("Aeromonas caviae",                "pathogen", "Gastroenteritis; especially in children"),

    # ── Reclassified Ruminococcus ─────────────────────────────────────────────
    33038:   ("Mediterraneibacter gnavus",       "core",     "Was Ruminococcus gnavus; mucin degrader; IBS biomarker"),

    # ── Additional butyrate producers ────────────────────────────────────────
    649756:  ("Anaerostipes hadrus",             "core",     "Major butyrate/lactate crossfeeder; abundant in HMP"),
    105841:  ("Anaerostipes caccae",             "core",     "Butyrate producer from lactate; Lachnospiraceae"),
    214851:  ("Subdoligranulum variabile",        "core",     "Butyrate producer; abundant HMP Clostridiales"),
    2093857: ("Dysosmobacter welbionis",          "core",     "Potent butyrate producer; described 2020; gut health biomarker"),
    89152:   ("Peptacetobacter hiranonis",        "core",     "Was Clostridium hiranonis; key 7α-dehydroxylation secondary bile acid producer"),
    33035:   ("Blautia producta",                "core",     "Major H2-consuming acetogen; common Lachnospiraceae"),
    53443:   ("Blautia hydrogenotrophica",        "core",     "H2-consuming acetogen; gut commensal"),
    301302:  ("Roseburia faecis",                "core",     "Butyrate producer; Roseburia sp.; flagellated motility"),
    351091:  ("Oscillibacter valericigenes",      "core",     "Valerate and butyrate producer; common HMP gut isolate"),
    501571:  ("Butyricicoccus pullicaecorum",     "core",     "Butyrate producer; human and poultry gut"),
    169435:  ("Anaerotruncus colihominis",        "core",     "Butyrate producer; DSM 17322 type strain"),

    # ── Additional Bacteroidota ───────────────────────────────────────────────
    328813:  ("Alistipes onderdonkii",            "core",     "Common gut Alistipes; amino acid fermentation"),
    246787:  ("Bacteroides cellulosilyticus",     "core",     "Major cellulose/hemicellulose degrader; WH2 reference"),
    329854:  ("Bacteroides intestinalis",         "core",     "Common gut Bacteroides; HMP isolate"),

    # ── Lachnospiraceae / Ruminococcaceae ────────────────────────────────────
    154046:  ("Hungatella hathewayi",             "core",     "Lachnospiraceae; common gut commensal; CDI association"),
    1150298: ("Fusicatenibacter saccharivorans",  "core",     "Lachnospiraceae; highly abundant in healthy adult gut"),
    69825:   ("Lacrimispora indolis",             "core",     "Was Clostridium clostridioforme complex; common gut isolate"),
    745368:  ("Gemmiger formicilis",              "core",     "Ruminococcaceae; gut commensal; HMP abundant"),
    28051:   ("Lachnospira multipara",            "core",     "Pectin-fermenting Lachnospiraceae; infant gut"),

    # ── Actinobacteria and other commensals ──────────────────────────────────
    74426:   ("Collinsella aerofaciens",          "core",     "Most abundant gut Coriobacteriia; bile acid + H2 metabolism"),
    84112:   ("Eggerthella lenta",                "core",     "Cardiac glycoside (digoxin) inactivation; common gut isolate"),
    292800:  ("Flavonifractor plautii",           "core",     "Flavonoid/polyphenol catabolism; gut commensal"),
    626937:  ("Christensenella minuta",           "core",     "Highly heritable; leanness biomarker; BMI association"),
    33025:   ("Phascolarctobacterium faecium",    "core",     "Propionate producer; Veillonellaceae; succinate-utilising"),
    218538:  ("Dialister invisus",                "core",     "Gut Veillonellaceae; common in HMP and UHGG"),

    # ── Lactobacillus / Bifidobacterium (probiotic / transient gut) ──────────
    1579:    ("Lactobacillus acidophilus",        "core",     "Classic probiotic; NCBI taxid 1579; acid-tolerant; yoghurt"),
    1596:    ("Lactobacillus gasseri",            "core",     "Gut Lactobacillus; NCBI taxid 1596; also in ncbi_additional genomes"),
    33959:   ("Lactobacillus johnsonii",          "core",     "Gut mucosal Lactobacillus; NCC533 reference genome"),
    1582:    ("Lacticaseibacillus casei",         "core",     "Probiotic; widely in gut; NCBI taxid 1582"),
    1597:    ("Lacticaseibacillus paracasei",     "core",     "Gut commensal; probiotic strains; NCBI taxid 1597"),
    1686:    ("Bifidobacterium catenulatum",      "core",     "Adult gut Bifidobacterium; NCBI taxid 1686"),
    28026:   ("Bifidobacterium pseudocatenulatum","core",     "Common adult gut Bifidobacterium; butyrate crossfeeder"),
    1689:    ("Bifidobacterium dentium",          "rare",     "Oral-origin Bifidobacterium; rare in healthy gut"),

    # ── Clostridiales / bile acid metabolism ─────────────────────────────────
    29347:   ("Clostridium scindens",             "core",     "Secondary bile acid producer; 7α-dehydroxylation; CDI resistance"),
    1547:    ("Thomasclavelia ramosa",             "core",     "Was Ruminococcus gnavus complex; NCBI taxid 1547"),
    1522:    ("Clostridium innocuum",             "core",     "Gut Clostridiales; enriched in IBD and CDI patients"),
    261299:  ("Intestinibacter bartlettii",       "core",     "Gut Peptostreptococcaceae; CDI-associated; NCBI taxid 261299"),

    # ── Veillonellaceae ───────────────────────────────────────────────────────
    29466:   ("Veillonella parvula",              "core",     "Gut Veillonella; lactate consumer; propionate producer"),
    39777:   ("Veillonella atypica",              "core",     "Gut Veillonella; common HMP isolate; lactate crossfeeder"),
    487173:  ("Dialister succinatiphilus",        "core",     "Gut Veillonellaceae; succinate-consuming; HMP isolate"),
    626940:  ("Phascolarctobacterium succinatutens","core",   "Succinate-to-propionate; gut Veillonellaceae; HMP"),

    # ── Lachnospiraceae additions ─────────────────────────────────────────────
    39485:   ("Lachnospira eligens",              "core",     "Pectin-fermenting Lachnospiraceae; infant and adult gut"),
    105843:  ("Anaerobutyricum soehngenii",       "core",     "Was Eubacterium soehngenii; butyrate producer; NCBI taxid 105843"),
    831:     ("Butyrivibrio fibrisolvens",        "core",     "Fibrolytic butyrate producer; ruminant and human gut"),
    1735:    ("Holdemanella biformis",            "core",     "Lachnospiraceae; gut commensal; HMP isolate"),

    # ── Ruminococcaceae additions ─────────────────────────────────────────────
    1161942: ("Ruminococcus champanellensis",     "core",     "Crystalline cellulose degrader; NCBI taxid 1161942"),
    100884:  ("Coprobacillus cateniformis",       "core",     "Gut Erysipelotrichaceae; common HMP isolate; NCBI taxid 100884"),
    106588:  ("Pseudoflavonifractor capillosus",  "core",     "Was Ruminococcus capillosus; gut commensal"),

    # ── Eubacterium additions ─────────────────────────────────────────────────
    40520:   ("Blautia obeum",                    "core",     "Was Ruminococcus obeum; gut Blautia; acetate/ethanol from H2"),
    1736:    ("Eubacterium limosum",              "core",     "Acetogen; methanol/CO2 utiliser; gut anaerobe"),

    # ── Coriobacteriia ────────────────────────────────────────────────────────
    446660:  ("Adlercreutzia equolifaciens",      "core",     "Equol producer from daidzein; Coriobacteriia; gut commensal"),
    147206:  ("Collinsella stercoris",            "core",     "Gut Coriobacteriia; bile acid transformation"),

    # ── Bacteroidota additions ────────────────────────────────────────────────
    154288:  ("Turicibacter sanguinis",           "core",     "Gut Erysipelotrichaceae; serotonin and bile acid metabolism"),
    487175:  ("Parasutterella excrementihominis", "core",     "Gut Burkholderiaceae; NCBI taxid 487175; common HMP commensal"),
    487174:  ("Barnesiella intestinihominis",     "core",     "Gut Bacteroidota; NCBI taxid 487174; HMP isolate"),
    291645:  ("Bacteroides nordii",               "core",     "Gut Bacteroides; NCBI taxid 291645; HMP isolate"),
    387661:  ("Parabacteroides johnsonii",        "core",     "Gut Parabacteroides; NCBI taxid 387661; HMP isolate"),
    328812:  ("Parabacteroides goldsteinii",      "core",     "Gut Parabacteroides; NCBI taxid 328812; HMP isolate"),
    626932:  ("Alistipes indistinctus",           "core",     "Gut Alistipes; NCBI taxid 626932; UHGG abundant"),

    # ── Archaea ───────────────────────────────────────────────────────────────
    1080712: ("Methanomassiliicoccus luminyensis","core",     "Gut methanogen; H2-using; NCBI taxid 1080712"),

    # ── Akkermansia ───────────────────────────────────────────────────────────
    1679444: ("Akkermansia glycaniphila",         "rare",     "Mucin-degrading Akkermansia; distinct from A. muciniphila"),

    # ── Bifidobacterium rare ──────────────────────────────────────────────────
    158787:  ("Bifidobacterium scardovii",        "rare",     "Rare gut Bifidobacterium; occasionally isolated from human feces"),
}

# ── ORAL ──────────────────────────────────────────────────────────────────────
# Sources: Dewhirst et al. (2010) J Bacteriol (HOMD), Zarco et al. (2012),
#          Hajishengallis (2015) Nat Rev Microbiol, Paster et al. (2001) J Bacteriol,
#          Human Oral Microbiome Database v3 (homd.org)
# Taxids NCBI-verified 2026-07-09 via eutils esearch + efetch XML.
# NOTE on genome_list.tsv discrepancies: several taxids in genome_list.tsv
# are wrong (point to genus-level nodes, wrong species, or higher taxonomy):
#   - 1303 in genome_list.tsv = Streptococcus oralis (not S. mitis; correct = 28037)
#   - 838  = Prevotella genus (correct species taxid = 28132)
#   - 836  = Porphyromonas genus (correct species taxid = 837)
#   - 224471 = Burkholderiales genera incertae sedis (correct T. forsythia = 28112)
#   - 1760 = Actinomycetes class (correct A. naeslundii = 1655)
#   - 732  = Aggregatibacter aphrophilus (correct H. parainfluenzae = 729)
#   - 483  = Neisseria cinerea (correct N. subflava = 28449)
# All ORAL_TAXA taxids below are correct per NCBI 2026-07-09.
ORAL_TAXA = {
    # ── Streptococcus ─────────────────────────────────────────────────────────
    28037:   ("Streptococcus mitis",              "core",     "In CAMISIM; dominant oral commensal (30-60%); NCBI taxid 28037"),
    1303:    ("Streptococcus oralis",             "core",     "Early coloniser; genome_list.tsv mistakenly used this taxid for S. mitis"),
    1305:    ("Streptococcus sanguinis",          "core",     "Pioneer coloniser; dental plaque biofilm initiator; HOMD core species"),
    1304:    ("Streptococcus salivarius",         "core",     "In CAMISIM; dominant early coloniser; tongue dorsum"),
    1302:    ("Streptococcus gordonii",           "core",     "Pioneer coloniser; inter-species signalling"),
    1309:    ("Streptococcus mutans",             "core",     "Primary dental caries pathogen"),
    1318:    ("Streptococcus parasanguinis",      "core",     "Early oral biofilm coloniser; coaggregation"),
    45634:   ("Streptococcus cristatus",          "core",     "Oral commensal; formerly S. crista; plaque"),
    1328:    ("Streptococcus anginosus",          "core",     "Milleri group; liver/brain abscess"),
    1338:    ("Streptococcus intermedius",        "core",     "Milleri group; abscess former"),
    76860:   ("Streptococcus constellatus",       "core",     "Milleri group; abscess former"),
    1310:    ("Streptococcus sobrinus",           "core",     "Dental caries; second only to S. mutans"),
    1313:    ("Streptococcus pneumoniae",         "pathogen", "Pharyngeal pathogen; pneumonia; oral coloniser"),
    1314:    ("Streptococcus pyogenes",           "pathogen", "GAS; pharyngitis; tonsillitis; scarlet fever"),

    # ── Veillonella ───────────────────────────────────────────────────────────
    29466:   ("Veillonella parvula",              "core",     "In CAMISIM; dominant oral anaerobe"),
    39777:   ("Veillonella atypica",              "core",     "Common oral Veillonella"),
    39778:   ("Veillonella dispar",               "core",     "Common oral Veillonella"),
    423477:  ("Veillonella rogosae",              "core",     "Oral Veillonella"),

    # ── Actinomyces / Schaalia ────────────────────────────────────────────────
    1655:    ("Actinomyces naeslundii",           "core",     "In CAMISIM; dental plaque pioneer coloniser; taxid 1760 in genome_list.tsv is wrong (Actinomycetes class)"),
    1656:    ("Actinomyces viscosus",             "core",     "Dental plaque; caries-associated"),
    1659:    ("Actinomyces israelii",             "pathogen", "Actinomycosis; head and neck infection"),
    544580:  ("Actinomyces oris",                 "core",     "Dominant early oral coloniser; coaggregation"),
    52769:   ("Actinomyces gerencseriae",         "core",     "Dental plaque; previously A. israelii serotype II"),
    1660:    ("Schaalia odontolytica",            "core",     "Dental plaque; formerly Actinomyces odontolyticus; NCBI current name Schaalia odontolytica"),

    # ── Rothia ────────────────────────────────────────────────────────────────
    43675:   ("Rothia mucilaginosa",              "core",     "In CAMISIM; common oral commensal"),
    2047:    ("Rothia dentocariosa",              "core",     "Dental caries; calculus"),
    172042:  ("Rothia aeria",                     "core",     "Oral commensal; lung infection risk"),

    # ── Prevotella / reclassified Prevotella ──────────────────────────────────
    28132:   ("Prevotella melaninogenica",        "core",     "In CAMISIM; dominant black-pigmented Prevotella; genome_list.tsv taxid 838 is genus-level only"),
    28131:   ("Prevotella intermedia",            "pathogen", "Periodontitis; pregnancy gingivitis"),
    28133:   ("Prevotella nigrescens",            "pathogen", "Periodontitis association"),
    28129:   ("Prevotella denticola",             "core",     "Dental plaque Prevotella"),
    60133:   ("Prevotella pallens",               "core",     "Oral Prevotella; HOMD listed species"),
    228604:  ("Segatella salivae",               "core",     "Oral Prevotella-related; formerly Prevotella salivae; reclassified 2020"),
    840:     ("Hoylesella loescheii",            "core",     "Oral anaerobe; formerly Prevotella loescheii; reclassified 2020"),

    # ── Fusobacterium ─────────────────────────────────────────────────────────
    851:     ("Fusobacterium nucleatum",          "core",     "In CAMISIM; key bridging coloniser in plaque"),
    860:     ("Fusobacterium periodonticum",      "core",     "Periodontitis; plaque bridge organism"),

    # ── Red complex periodontal pathogens ─────────────────────────────────────
    837:     ("Porphyromonas gingivalis",         "pathogen", "In CAMISIM; keystone periodontal pathogen; genome_list.tsv taxid 836 is genus-level only"),
    28112:   ("Tannerella forsythia",             "pathogen", "In CAMISIM; red complex; periodontitis; genome_list.tsv taxid 224471 is Burkholderiales incertae sedis"),
    158:     ("Treponema denticola",              "pathogen", "Red complex; deep periodontal pockets"),
    58231:   ("Treponema medium",                 "pathogen", "Periodontal Treponema"),
    69710:   ("Treponema vincentii",              "pathogen", "Periodontal Treponema; HOMD listed"),

    # ── Orange complex / accessory periodontal pathogens ──────────────────────
    714:     ("Aggregatibacter actinomycetemcomitans", "pathogen", "Aggressive periodontitis; HACEK endocarditis"),
    739:     ("Aggregatibacter segnis",           "pathogen", "Formerly Haemophilus segnis; oral commensal; HACEK group"),
    539:     ("Eikenella corrodens",              "pathogen", "Periodontal pathogen; bite wound infection"),
    143361:  ("Filifactor alocis",                "pathogen", "Emerging periodontal pathogen; difficult to culture"),
    33033:   ("Parvimonas micra",                 "pathogen", "Periodontal pathogen; abscess former"),
    203:     ("Campylobacter rectus",             "pathogen", "Periodontal pathogen"),
    204:     ("Campylobacter showae",             "pathogen", "Periodontal pathogen"),

    # ── Capnocytophaga ────────────────────────────────────────────────────────
    1017:    ("Capnocytophaga gingivalis",        "core",     "Oral commensal; immunocomp infection risk"),
    1019:    ("Capnocytophaga sputigena",         "core",     "Oral commensal; periodontal disease"),
    1018:    ("Capnocytophaga ochracea",          "core",     "Oral commensal; abscesses"),
    28188:   ("Capnocytophaga canimorsus",        "pathogen", "Dog bite septicaemia; fatal in asplenic patients"),

    # ── Haemophilus ───────────────────────────────────────────────────────────
    729:     ("Haemophilus parainfluenzae",       "core",     "In CAMISIM; common oral commensal; genome_list.tsv taxid 732 = Aggregatibacter aphrophilus (wrong species)"),
    727:     ("Haemophilus influenzae",           "pathogen", "Respiratory pathogen; oral pharyngeal carriage"),

    # ── Leptotrichia ─────────────────────────────────────────────────────────
    40542:   ("Leptotrichia buccalis",            "core",     "Dominant in some oral communities"),
    109328:  ("Leptotrichia trevisanii",          "core",     "Oral commensal"),
    157687:  ("Leptotrichia wadei",               "core",     "Oral commensal; HOMD listed species"),

    # ── Neisseria ─────────────────────────────────────────────────────────────
    28449:   ("Neisseria subflava",               "core",     "In CAMISIM; commensal oral Neisseria; genome_list.tsv taxid 483 = Neisseria cinerea (wrong species)"),
    488:     ("Neisseria mucosa",                 "core",     "Common oral commensal Neisseria"),
    490:     ("Neisseria sicca",                  "core",     "Common oral commensal Neisseria"),
    485:     ("Neisseria gonorrhoeae",            "pathogen", "Pharyngeal gonorrhoea; increasing prevalence"),

    # ── HACEK group / endocarditis-associated oral organisms ──────────────────
    2718:    ("Cardiobacterium hominis",          "pathogen", "HACEK group; subacute endocarditis; oral origin"),
    504:     ("Kingella kingae",                  "pathogen", "HACEK group; paediatric septic arthritis; oral coloniser"),
    46124:   ("Granulicatella adiacens",          "pathogen", "Nutritionally variant streptococcus; subacute endocarditis"),
    46125:   ("Abiotrophia defectiva",            "pathogen", "Nutritionally variant streptococcus; subacute endocarditis"),

    # ── Other oral bacteria ───────────────────────────────────────────────────
    480:     ("Moraxella catarrhalis",            "pathogen", "Upper respiratory pathogen; oral reservoir"),
    69823:   ("Selenomonas sputigena",            "core",     "Dental plaque anaerobe; crescent-shaped"),
    1379:    ("Gemella haemolysans",              "core",     "Oral commensal; endocarditis risk"),
    29391:   ("Gemella morbillorum",              "core",     "Oral commensal; endocarditis risk"),
    39950:   ("Dialister pneumosintes",           "core",     "Oral/pulmonary anaerobe; periodontitis"),
    218538:  ("Dialister invisus",                "core",     "Oral anaerobe; periodontitis; previously uncultured"),
    1260:    ("Finegoldia magna",                 "core",     "Oral anaerobe; abscess former"),
    1280:    ("Staphylococcus aureus",            "pathogen", "Oral carriage; post-dental infection"),

    # ── Fungi ─────────────────────────────────────────────────────────────────
    5476:    ("Candida albicans",                 "pathogen", "Oral candidiasis (thrush); oropharyngeal"),
    5482:    ("Candida tropicalis",               "pathogen", "Oral candidiasis; azole resistance emerging"),
    5478:    ("Nakaseomyces glabratus",           "pathogen", "Oral candidiasis; fluconazole-resistant; NCBI current name Nakaseomyces glabratus (formerly Candida glabrata); taxid 5478 confirmed"),
    42374:   ("Candida dubliniensis",             "pathogen", "Oral candidiasis; morphologically similar to C. albicans; NCBI taxid 42374"),
    4909:    ("Pichia kudriavzevii",              "pathogen", "Was Candida krusei; intrinsically fluconazole-resistant; oral isolate; NCBI taxid 4909"),

    # ── Additional Prevotella / Porphyromonas ────────────────────────────────
    470565:  ("Prevotella histicola",             "core",     "Oral Prevotella; common in HMP oral sites; NCBI taxid 470565"),
    28124:   ("Porphyromonas endodontalis",       "pathogen", "Endodontic infections; apical periodontitis"),
    28127:   ("Hoylesella buccalis",              "core",     "Was Prevotella buccalis; oral anaerobe; periodontal sulcus"),
    41976:   ("Porphyromonas catoniae",           "core",     "Oral Porphyromonas; periodontal pocket; NCBI taxid 41976"),

    # ── Additional Streptococcus ──────────────────────────────────────────────
    113107:  ("Streptococcus australis",          "core",     "Oral commensal; mitis group; HOMD core species; NCBI taxid 113107"),
    68892:   ("Streptococcus infantis",           "core",     "Oral mitis-group streptococcus; early biofilm coloniser; NCBI taxid 68892"),

    # ── Actinomyces / Schaalia ────────────────────────────────────────────────
    52773:   ("Schaalia meyeri",                  "core",     "Was Actinomyces meyeri; oral actinomycete; dental plaque"),
    131111:  ("Schaalia turicensis",              "core",     "Was Actinomyces turicensis; oral actinomycete; NCBI taxid 131111"),
    52768:   ("Schaalia georgiae",                "core",     "Was Actinomyces georgiae; oral commensal; NCBI taxid 52768"),
    111015:  ("Actinomyces radicidentis",         "core",     "Oral actinomycete; root caries and endodontic infections"),
    55565:   ("Actinomyces graevenitzii",         "core",     "Oral actinomycete; HMP oral sites; NCBI taxid 55565"),

    # ── Olsenella / Lachnoanaerobaculum ──────────────────────────────────────
    133926:  ("Olsenella uli",                    "core",     "Oral Coriobacteriia; periodontal and root canal"),
    617123:  ("Lachnoanaerobaculum umeaense",     "core",     "Oral Lachnospiraceae; NCBI taxid 617123; oral mucosa"),
    467210:  ("Lachnoanaerobaculum saburreum",    "core",     "Oral Lachnospiraceae; supragingival plaque; NCBI taxid 467210"),

    # ── Desulfobulbus ─────────────────────────────────────────────────────────
    1986146: ("Desulfobulbus oralis",             "pathogen", "Oral sulphate-reducer; severe periodontitis; NCBI taxid 1986146"),

    # ── Rothia ────────────────────────────────────────────────────────────────
    37923:   ("Rothia kristinae",                 "core",     "Was Kocuria kristinae; reclassified to Rothia 2022; oral/skin commensal"),

    # ── Treponema ─────────────────────────────────────────────────────────────
    53419:   ("Treponema socranskii",             "core",     "Oral spirochaete; periodontal disease; NCBI taxid 53419"),
    53418:   ("Treponema lecithinolyticum",       "core",     "Oral spirochaete; periodontitis; NCBI taxid 53418"),
    51160:   ("Treponema maltophilum",            "core",     "Oral spirochaete; periodontal pocket; NCBI taxid 51160"),

    # ── Leptotrichia ─────────────────────────────────────────────────────────
    157691:  ("Leptotrichia shahii",              "core",     "Oral Leptotrichia; HMP oral sites; NCBI taxid 157691"),
    157688:  ("Leptotrichia hofstadii",           "core",     "Oral Leptotrichia; plaque and gingival sulcus; NCBI taxid 157688"),

    # ── Campylobacter (oral) ──────────────────────────────────────────────────
    824:     ("Campylobacter gracilis",           "core",     "Oral Campylobacter; subgingival plaque; periodontal disease"),
    199:     ("Campylobacter concisus",           "core",     "Oral Campylobacter; subgingival; also GI"),
    827:     ("Campylobacter ureolyticus",        "core",     "Oral Campylobacter; was Bacteroides ureolyticus; NCBI taxid 827"),

    # ── Aggregatibacter / Neisseria ───────────────────────────────────────────
    732:     ("Aggregatibacter aphrophilus",      "pathogen", "Oral Aggregatibacter; HACEK endocarditis; NCBI taxid 732"),
    484:     ("Neisseria flavescens",             "core",     "Oral Neisseria commensal; NCBI taxid 484"),
    495:     ("Neisseria elongata",               "core",     "Oral Neisseria; NCBI taxid 495; rare endocarditis"),

    # ── Capnocytophaga ────────────────────────────────────────────────────────
    45243:   ("Capnocytophaga haemolytica",       "core",     "Oral gliding bacterium; periodontal sulcus; NCBI taxid 45243"),
    45242:   ("Capnocytophaga granulosa",         "core",     "Oral gliding bacterium; dental plaque; NCBI taxid 45242"),

    # ── Granulicatella ────────────────────────────────────────────────────────
    137732:  ("Granulicatella elegans",           "core",     "Nutritionally variant streptococcus; oral/blood; NCBI taxid 137732"),

    # ── Slackia / Dialister ───────────────────────────────────────────────────
    84109:   ("Slackia exigua",                   "core",     "Oral Coriobacteriia; root canal and endodontic infections"),
    309120:  ("Dialister micraerophilus",         "core",     "Oral Veillonellaceae; periodontal pocket; NCBI taxid 309120"),

    # ── Veillonella additions ─────────────────────────────────────────────────
    1110546: ("Veillonella tobetsuensis",         "core",     "Oral Veillonella; HMP oral sites; NCBI taxid 1110546"),
    419208:  ("Veillonella denticariosi",         "core",     "Oral Veillonella; dental caries associated; NCBI taxid 419208"),
    1911679: ("Veillonella infantium",            "core",     "Oral Veillonella; infant oral microbiome; NCBI taxid 1911679"),

    # ── Gemella ───────────────────────────────────────────────────────────────
    84135:   ("Gemella sanguinis",                "core",     "Oral Gemella; HMP oral sites; endocarditis risk; NCBI taxid 84135"),
    84136:   ("Gemella bergeri",                  "core",     "Oral Gemella; gingival sulcus; NCBI taxid 84136"),
}

# ── SKIN ──────────────────────────────────────────────────────────────────────
# Sources: Grice & Segre (2011) Nat Rev Microbiol, Byrd et al. (2018),
#          Findley et al. (2013) Nature, HMP skin body sites,
#          Meisel et al. (2016) Cell Host Microbe
# NOTE: The skin database already has a v5 expansion (expand_skin_db.py).
#       This list adds species missing from that expansion, focussing on
#       pathogens and recently documented commensals.
SKIN_TAXA = {
    # ── Staphylococcus (comprehensive) ───────────────────────────────────────
    1280:    ("Staphylococcus aureus",           "core",     "In CAMISIM; dominant skin pathogen; MRSA"),
    1281:    ("Staphylococcus carnosus",         "core",     "Skin commensal"),
    1282:    ("Staphylococcus epidermidis",      "core",     "In CAMISIM; dominant skin commensal"),
    1283:    ("Staphylococcus haemolyticus",     "core",     "In CAMISIM; nosocomial pathogen"),
    1290:    ("Staphylococcus hominis",          "core",     "Common skin commensal"),
    28035:    ("Staphylococcus lugdunensis",      "pathogen", "Aggressive skin infections; endocarditis"),
    29385:    ("Staphylococcus saprophyticus",    "pathogen", "Skin commensal; UTI pathogen"),
    29382:    ("Staphylococcus cohnii",           "core",     "Skin commensal"),
    1288:    ("Staphylococcus xylosus",          "core",     "Skin commensal"),
    29380:    ("Staphylococcus caprae",           "core",     "Skin commensal"),
    1295:    ("Staphylococcus schleiferi",       "core",     "Skin commensal; otitis externa"),
    1296:    ("Mammaliicoccus sciuri",            "core",     "Was Staphylococcus sciuri; genus reclassified 2022; skin commensal; zoonotic"),
    71237:   ("Mammaliicoccus vitulinus",        "core",     "Was Staphylococcus vitulinus; genus reclassified 2022; skin commensal"),
    1292:    ("Staphylococcus warneri",          "core",     "Common skin commensal; endocarditis risk"),
    29388:   ("Staphylococcus capitis",          "core",     "Scalp/forehead commensal"),
    45972:   ("Staphylococcus pasteuri",         "core",     "Skin commensal"),
    246432:  ("Staphylococcus equorum",          "core",     "Skin commensal"),
    170573:  ("Staphylococcus pettenkoferi",     "core",     "Skin commensal; rare infections"),

    # ── Corynebacterium (comprehensive) ──────────────────────────────────────
    1717:    ("Corynebacterium diphtheriae",     "pathogen", "Diphtheria; cutaneous form important"),
    1725:    ("Corynebacterium xerosis",         "core",     "Common skin Corynebacterium"),
    37637:    ("Corynebacterium pseudodiphtheriticum", "core","Common skin/respiratory commensal"),
    36808:    ("Corynebacterium bovis",           "core",     "Skin commensal"),
    38301:   ("Corynebacterium minutissimum",    "pathogen", "Erythrasma causative agent"),
    134034:   ("Corynebacterium freneyi",         "core",     "Skin commensal"),
    38284:   ("Corynebacterium accolens",        "core",     "Nose/skin commensal"),
    39791:   ("Corynebacterium glucuronolyticum","core",     "Genitourinary tract commensal"),
    43769:   ("Corynebacterium propinquum",      "core",     "Skin/respiratory commensal"),
    38304:   ("Corynebacterium tuberculostearicum","core",   "In CAMISIM; dominant axillary commensal"),
    43771:   ("Corynebacterium urealyticum",     "core",     "Skin commensal; urinary infections"),
    38289:   ("Corynebacterium jeikeium",        "pathogen", "Multiresistant nosocomial skin pathogen"),
    43765:   ("Corynebacterium amycolatum",      "core",     "Common skin Corynebacterium"),
    43770:   ("Corynebacterium striatum",        "pathogen", "Emerging nosocomial pathogen; skin wounds"),
    71254:   ("Corynebacterium confusum",        "core",     "Skin commensal"),
    38286:   ("Corynebacterium afermentans",     "core",     "Skin commensal"),
    161879:  ("Corynebacterium kroppenstedtii",  "core",     "Highly lipophilic; breast tissue"),
    258224:  ("Corynebacterium resistens",       "core",     "Skin commensal; multidrug resistant"),

    # ── Cutibacterium / Propionibacterium ─────────────────────────────────────
    1747:    ("Cutibacterium acnes",             "core",     "In CAMISIM; dominant sebaceous skin"),
    33011:    ("Cutibacterium granulosum",        "core",     "Sebaceous skin commensal"),
    33010:   ("Cutibacterium avidum",            "core",     "Moist skin areas; axilla"),

    # ── Malassezia (comprehensive — all skin-relevant species) ────────────────
    76773:   ("Malassezia globosa",              "core",     "In CAMISIM; dominant; dandruff/seborrhoea"),
    76775:   ("Malassezia restricta",            "core",     "In CAMISIM; atopic dermatitis"),
    55194:   ("Malassezia furfur",               "core",     "Pityriasis versicolor; seborrhoeic derm"),
    76777:   ("Malassezia sympodialis",          "core",     "Atopic eczema IgE sensitisation"),
    169489:  ("Malassezia dermatis",             "core",     "Atopic dermatitis-associated"),
    180528: ("Malassezia nana",                 "core",     "Animal and human skin"),
    77020:   ("Malassezia pachydermatis",        "core",     "Zoonotic; canine otitis; neonatal sepsis"),
    76776: ("Malassezia slooffiae",            "core",     "Skin commensal"),

    # ── Micrococcus ───────────────────────────────────────────────────────────
    1270:    ("Micrococcus luteus",              "core",     "In CAMISIM; ubiquitous skin commensal"),
    86171:    ("Micrococcus antarcticus",         "core",     "Skin commensal"),
    566027:    ("Micrococcus yunnanensis",         "core",     "Skin commensal"),
    1273:    ("Micrococcus lylae",               "core",     "Skin commensal; taxid 1273 = M. lylae per NCBI; no valid taxid exists for M. flavescens"),

    # ── Brevibacterium ────────────────────────────────────────────────────────
    1703:    ("Brevibacterium linens",           "core",     "In CAMISIM; foot odour (methanethiol)"),
    33889:   ("Brevibacterium casei",            "core",     "Skin commensal"),
    273384:   ("Brevibacterium aurantiacum",      "core",     "Orange-pigmented skin commensal"),
    31943:   ("Brevibacterium iodinum",          "core",     "Skin commensal"),

    # ── Gram-negative skin bacteria ───────────────────────────────────────────
    470:     ("Acinetobacter baumannii",         "pathogen", "ESKAPE; wound/burn infections; CRAB"),
    28090:     ("Acinetobacter lwoffii",           "core",     "Skin commensal; opportunist"),
    471:     ("Acinetobacter calcoaceticus",     "core",     "Skin commensal"),
    48296:  ("Acinetobacter pittii",            "pathogen", "Nosocomial wound infections"),
    106654:  ("Acinetobacter nosocomialis",      "pathogen", "Nosocomial wound infections"),
    40214:   ("Acinetobacter johnsonii",         "core",     "Skin commensal"),
    106648:  ("Acinetobacter bereziniae",        "core",     "Skin commensal"),
    480:     ("Moraxella catarrhalis",           "pathogen", "Upper resp pathogen; skin carriage"),
    287:     ("Pseudomonas aeruginosa",          "pathogen", "Burn/wound infections; eczema; ESKAPE"),
    303:     ("Pseudomonas putida",              "core",     "Skin commensal"),
    615:    ("Serratia marcescens",             "pathogen", "Wound infections; opportunistic; red pigment"),
    584:     ("Proteus mirabilis",               "pathogen", "Wound infections; swarming bacterium"),

    # ── Streptococcus ─────────────────────────────────────────────────────────
    1314:    ("Streptococcus pyogenes",          "pathogen", "GAS; impetigo; cellulitis; necrotising fasciitis"),
    1311:    ("Streptococcus agalactiae",        "pathogen", "GBS; neonatal + wound infections"),
    28037:    ("Streptococcus mitis",             "core",     "Skin isolate"),

    # ── Kocuria ───────────────────────────────────────────────────────────────
    1275:   ("Kocuria rosea",                   "core",     "Skin commensal; urinary tract infections"),
    37923:   ("Rothia kristinae",                "core",     "Was Kocuria kristinae; reclassified to Rothia 2022; skin commensal; peritonitis risk"),
    1272:   ("Kocuria varians",                 "core",     "Skin commensal"),

    # ── Enterococcus ──────────────────────────────────────────────────────────
    1351:    ("Enterococcus faecalis",           "pathogen", "Wound infections; VRE risk"),
    1352:    ("Enterococcus faecium",            "pathogen", "VRE; skin wound nosocomial"),

    # ── Fungi ─────────────────────────────────────────────────────────────────
    5476:    ("Candida albicans",                "pathogen", "Cutaneous candidiasis; diaper rash"),
    5480:    ("Lodderomyces parapsilosis",        "pathogen", "Was Candida parapsilosis; nail/skin candidiasis; neonatal risk; reclassified"),
    5482:    ("Candida tropicalis",              "pathogen", "Cutaneous candidiasis"),

    # ── Opportunistic / nosocomial ────────────────────────────────────────────
    562:     ("Escherichia coli",               "pathogen", "Wound infections; cellulitis"),
    573:     ("Klebsiella pneumoniae",           "pathogen", "Wound infections; ESKAPE pathogen"),
    546:     ("Citrobacter freundii",            "pathogen", "Opportunistic wound infections"),
    37915:   ("Dietzia maris",                   "core",     "Lipophilic skin actinobacterium"),
    53458:   ("Janibacter limosus",              "core",     "Skin commensal"),
    36740:   ("Dermabacter hominis",             "core",     "Skin commensal; folliculitis"),
    257708:  ("Roseomonas gilardii",             "core",     "Pink-pigmented commensal; rare infections"),
    40324:   ("Stenotrophomonas maltophilia",    "pathogen", "Wound infections; intrinsic multidrug resistance"),

    # ── Anaerobes (moist/occluded skin sites) ─────────────────────────────────
    1260:  ("Finegoldia magna",                "core",     "Skin abscess; chronic wounds"),
    54005:  ("Peptoniphilus harei",             "core",     "Chronic wound anaerobe"),
    1258:    ("Peptoniphilus asaccharolyticus",  "core",     "Chronic wound anaerobe"),
    33031:   ("Peptoniphilus lacrimalis",        "core",     "Skin anaerobe"),
    33034:   ("Anaerococcus prevotii",           "core",     "Skin anaerobe; abscesses"),
    33037:   ("Anaerococcus vaginalis",          "core",     "Skin anaerobe"),
    33036:   ("Anaerococcus tetradius",          "core",     "Skin wound anaerobe"),
    33029:   ("Anaerococcus hydrogenalis",       "core",     "Skin wound anaerobe"),
    33032:   ("Anaerococcus lactolyticus",       "core",     "Skin wound anaerobe"),
    411577:  ("Anaerococcus murdochii",          "core",     "Skin wound anaerobe"),
    837:     ("Porphyromonas gingivalis",        "core",     "Skin wound anaerobe"),
    322095:   ("Porphyromonas somerae",           "core",     "Skin chronic wound anaerobe"),
    28123:   ("Porphyromonas asaccharolytica",    "core",     "Wound anaerobe; also vaginal; NCBI taxid 28123"),
    54007:   ("Anaerococcus octavius",            "core",     "Skin wound anaerobe; NCBI taxid 54007"),

    # ── Critical emerging fungal pathogen ─────────────────────────────────────
    498019:  ("Candidozyma auris",                "pathogen", "Was Candida auris; multidrug-resistant; WHO critical priority; NCBI taxid 498019"),

    # ── Dermatophytes ─────────────────────────────────────────────────────────
    5551:    ("Trichophyton rubrum",              "pathogen", "Most common dermatophyte; tinea pedis, onychomycosis"),
    523103:  ("Trichophyton mentagrophytes",      "pathogen", "Dermatophyte; tinea corporis/pedis; zoonotic; NCBI taxid 523103"),
    63405:   ("Microsporum canis",               "pathogen", "Dermatophyte; tinea capitis; zoonotic from cats/dogs"),

    # ── Aspergillus ───────────────────────────────────────────────────────────
    746128:  ("Aspergillus fumigatus",            "pathogen", "Cutaneous aspergillosis; immunocompromised host; NCBI taxid 746128"),
    5061:    ("Aspergillus niger",               "pathogen", "Otomycosis; onychomycosis; skin saprophyte"),
    5059:    ("Aspergillus flavus",              "pathogen", "Cutaneous aspergillosis; aflatoxin producer"),

    # ── Additional skin fungi ─────────────────────────────────────────────────
    4929:    ("Meyerozyma guilliermondii",        "pathogen", "Was Candida guilliermondii; skin/nail candidiasis; NCBI taxid 4929"),
    4959:    ("Debaryomyces hansenii",            "core",     "Salt-tolerant skin yeast; common in dry skin sites; NCBI taxid 4959"),
    36911:   ("Clavispora lusitaniae",            "pathogen", "Was Candida lusitaniae; skin/nail candidiasis; amphotericin B resistance"),
    36914:   ("Lodderomyces elongisporus",        "pathogen", "Was Candida elongisposa; skin candidiasis; NCBI taxid 36914"),
    223818:  ("Malassezia japonica",             "core",     "Lipophilic skin yeast; seborrheic sites; NCBI taxid 223818"),

    # ── Additional Staphylococcus ─────────────────────────────────────────────
    1286:    ("Staphylococcus simulans",          "core",     "Skin commensal; coagulase-negative; NCBI taxid 1286"),
    283734:  ("Staphylococcus pseudintermedius",  "pathogen", "Zoonotic; dog skin; human wounds via pet contact"),
    1293:    ("Staphylococcus gallinarum",        "core",     "Avian-origin skin commensal; NCBI taxid 1293"),
    53344:   ("Staphylococcus delphini",          "core",     "Dolphin-origin; rare zoonotic skin isolate; NCBI taxid 53344"),
    1284:    ("Staphylococcus hyicus",            "core",     "Porcine; zoonotic skin pathogen; exfoliative disease"),
    1285:    ("Staphylococcus intermedius",       "core",     "Zoonotic; dog/cat skin; human wound infections"),
    46127:   ("Staphylococcus felis",             "core",     "Feline skin commensal; rare zoonotic; NCBI taxid 46127"),
    1294:    ("Staphylococcus muscae",            "core",     "Fly-associated; occasional skin/wound isolate; NCBI taxid 1294"),

    # ── Additional Corynebacterium ────────────────────────────────────────────
    146827:  ("Corynebacterium simulans",         "core",     "Skin Corynebacterium; axilla and groin; NCBI taxid 146827"),
    99807:   ("Corynebacterium auriscanis",       "core",     "Aural/skin Corynebacterium; dog-origin; zoonotic"),
    401472:  ("Corynebacterium ureicelerivorans", "core",     "Skin Corynebacterium; axillary; NCBI taxid 401472"),
    441501:  ("Corynebacterium massiliense",      "core",     "Skin Corynebacterium; HMP isolate; NCBI taxid 441501"),
    53374:   ("Corynebacterium coyleae",          "core",     "Urogenital/skin Corynebacterium; NCBI taxid 53374"),

    # ── Cutibacterium / Propionibacteriales ──────────────────────────────────
    1574624: ("Cutibacterium namnetense",         "core",     "Skin Propionibacteriales; sebaceous sites; NCBI taxid 1574624"),
    33012:   ("Propionimicrobium lymphophilum",   "core",     "Skin lymph-node isolate; NCBI taxid 33012"),

    # ── Gram-negative opportunists ────────────────────────────────────────────
    582:     ("Morganella morganii",              "pathogen", "Wound infections; enterobacterial; intrinsic ampicillin resistance"),
    550:     ("Enterobacter cloacae",             "pathogen", "Wound/burn infections; ESKAPE pathogen"),
    585:     ("Proteus vulgaris",                 "pathogen", "Wound infections; urease producer; alkaline urine"),
    102862:  ("Proteus penneri",                  "pathogen", "Wound infections; urease; NCBI taxid 102862"),
    548:     ("Klebsiella aerogenes",             "pathogen", "Was Enterobacter aerogenes; wound infections; ESKAPE"),
    545:     ("Citrobacter koseri",               "pathogen", "Wound infections; neonatal meningitis risk"),
    614:     ("Serratia liquefaciens",            "pathogen", "Wound infections; metalloprotease; NCBI taxid 614"),
    294:     ("Pseudomonas fluorescens",          "pathogen", "Environmental wound pathogen; fluorescent siderophore"),
    316:     ("Stutzerimonas stutzeri",           "core",     "Was Pseudomonas stutzeri; skin/wound isolate; denitrifier"),

    # ── Acinetobacter additions ───────────────────────────────────────────────
    40216:   ("Acinetobacter radioresistens",     "core",     "Skin Acinetobacter; radiation-resistant; NCBI taxid 40216"),
    108980:  ("Acinetobacter ursingii",           "pathogen", "Skin/wound Acinetobacter; nosocomial; NCBI taxid 108980"),
    108981:  ("Acinetobacter schindleri",         "core",     "Skin Acinetobacter; HMP isolate; NCBI taxid 108981"),
    106649:  ("Acinetobacter guillouiae",         "core",     "Skin Acinetobacter; NCBI taxid 106649"),
    40215:   ("Acinetobacter junii",              "core",     "Skin Acinetobacter; dry skin sites; NCBI taxid 40215"),

    # ── Actinobacteria (skin) ─────────────────────────────────────────────────
    2054:    ("Gordonia bronchialis",             "core",     "Soil/skin actinomycete; sternotomy wound infections"),
    37326:   ("Nocardia brasiliensis",            "pathogen", "Cutaneous nocardiosis; tropical; NCBI taxid 37326"),
    1833:    ("Rhodococcus erythropolis",         "core",     "Skin/environment Rhodococcus; lipid degrader; NCBI taxid 1833"),
    499555:  ("Dietzia timorensis",               "core",     "Skin lipophilic actinobacterium; NCBI taxid 499555"),
    161920:  ("Dietzia natronolimnaea",           "core",     "Skin/environment Dietzia; NCBI taxid 161920"),
    103817:  ("Janibacter terrae",               "core",     "Skin/soil actinobacterium; NCBI taxid 103817"),
    366888:  ("Brevibacterium samyangense",       "core",     "Skin Brevibacterium; cheese/skin rind; NCBI taxid 366888"),
    234835:  ("Brevibacterium antiquum",          "core",     "Skin Brevibacterium; body odour association; NCBI taxid 234835"),
    1698:    ("Brevibacterium epidermidis",        "core",     "Classic skin Brevibacterium; foot odour; NCBI taxid 1698"),

    # ── Micrococcus ───────────────────────────────────────────────────────────
    455343:  ("Micrococcus endophyticus",         "core",     "Skin/plant endophyte Micrococcus; NCBI taxid 455343"),

    # ── Roseomonas ────────────────────────────────────────────────────────────
    207340:  ("Roseomonas mucosa",                "core",     "Pink-pigmented skin bacterium; atopic dermatitis benefit; NCBI taxid 207340"),
}

ALL_TAXA = {
    "vaginal": VAGINAL_TAXA,
    "gut":     GUT_TAXA,
    "oral":    ORAL_TAXA,
    "skin":    SKIN_TAXA,
}

# ─────────────────────────────────────────────────────────────────────────────
# Core expansion logic
# ─────────────────────────────────────────────────────────────────────────────

def expand_site(
    site: str,
    db_path: Path,
    genome_list_path: Path | None,
    threads: int,
    dry_run: bool,
) -> dict:
    """Run the full expansion for one body site. Returns a result summary dict."""
    taxa = ALL_TAXA[site]

    print(f"\n{'='*64}")
    print(f"  STAMINA-BIOME DB expansion — {site.upper()}")
    print(f"  DB:          {db_path}")
    print(f"  Targets:     {len(taxa)} species")
    if dry_run:
        print("  Mode:        DRY RUN — nothing will be downloaded")
    print(f"{'='*64}")

    # Prepare output directory
    out_dir = db_path / "library" / "added"
    if not dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)

    # Load what's already recorded in genome_list.tsv (skip if no file)
    already_listed: set[int] = set()
    if genome_list_path and genome_list_path.exists():
        already_listed = load_genome_list_taxids(genome_list_path)
        print(f"\n  Already in genome_list.tsv: {len(already_listed)} taxids")

    to_fetch = {
        taxid: info for taxid, info in taxa.items()
        if taxid not in already_listed
    }
    print(f"  New taxids to process:      {len(to_fetch)}")

    if dry_run:
        print("\n  Would add:")
        for taxid, (name, cat, notes) in sorted(to_fetch.items(), key=lambda x: x[1][0]):
            print(f"    [{cat:9s}] {name:45s}  (taxid={taxid})")
        return {"site": site, "targeted": len(to_fetch), "ok": 0, "fail": 0, "missing": 0}

    # ── Phase 1: Resolve GCF accessions via NCBI Datasets API ─────────────────
    print(f"\n  Phase 1 — Resolving NCBI accessions ({len(to_fetch)} taxids)…")
    tasks   = []
    missing = []
    for taxid, (species, cat, notes) in to_fetch.items():
        acc = resolve_best_accession(taxid)
        time.sleep(API_SLEEP)
        if not acc:
            print(f"    [MISS ] {species} (taxid={taxid}) — not in RefSeq")
            missing.append((taxid, species, notes))
            continue
        ftp = resolve_ftp_path(acc)
        time.sleep(API_SLEEP)
        if not ftp:
            print(f"    [MISS ] {species} (taxid={taxid}) — FTP path not found for {acc}")
            missing.append((taxid, species, notes))
            continue
        tasks.append((taxid, species, cat, notes, acc, ftp))
        print(f"    [FOUND] {species} (taxid={taxid}) → {acc}")

    print(f"\n  Resolved: {len(tasks)} | Not in RefSeq: {len(missing)}")

    # ── Phase 2: Download in parallel ─────────────────────────────────────────
    print(f"\n  Phase 2 — Downloading {len(tasks)} genomes ({threads} threads)…")
    ok_results   = []
    fail_results = []

    with ThreadPoolExecutor(max_workers=threads) as pool:
        futures = {
            pool.submit(download_genome, taxid, species, ftp, out_dir): (taxid, species, cat, notes, acc)
            for taxid, species, cat, notes, acc, ftp in tasks
        }
        for future in as_completed(futures):
            taxid, species, cat, notes, acc = futures[future]
            try:
                result = future.result()
                if result:
                    ok_results.append((taxid, species, cat, notes, acc))
                else:
                    fail_results.append((taxid, species))
            except Exception as e:
                print(f"  [EXCEPT] {species}: {e}")
                fail_results.append((taxid, species))
            time.sleep(0.1)

    # ── Phase 3: Update genome_list.tsv ───────────────────────────────────────
    if genome_list_path and ok_results:
        print(f"\n  Phase 3 — Updating genome_list.tsv ({len(ok_results)} entries)…")
        today = date.today().isoformat()
        with open(genome_list_path, "a") as f:
            f.write(f"\n# ── expand_all_sites.py additions ({today}) ─────────────────────────────────\n")
            for taxid, species, cat, notes, acc in ok_results:
                f.write(f"{acc}\t{species}\t{taxid}\tncbi_expand\t{notes}\n")
        print(f"  Appended {len(ok_results)} rows to {genome_list_path}")

    if missing:
        print(f"\n  ── Taxa not found in RefSeq (may need GenBank / manual add) ──────────────")
        for taxid, species, notes in missing:
            print(f"    taxid={taxid:<10}  {species:<45}  # {notes}")

    print(f"\n  ── {site.upper()} SUMMARY ─────────────────────────────────────────────────────")
    print(f"    Downloaded OK : {len(ok_results)}")
    print(f"    Download fail : {len(fail_results)}")
    print(f"    Not in RefSeq : {len(missing)}")

    return {
        "site":    site,
        "targeted": len(to_fetch),
        "ok":      len(ok_results),
        "fail":    len(fail_results),
        "missing": len(missing),
    }


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="STAMINA-BIOME comprehensive database expansion for all body sites",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Prerequisites:")[0].strip(),
    )
    parser.add_argument(
        "--site", required=True,
        choices=["vaginal", "gut", "oral", "skin", "all"],
        help="Body site to expand, or 'all' for all four sites",
    )
    parser.add_argument(
        "--db",
        help="Path to Kraken2 DB directory (required for single-site mode)",
    )
    parser.add_argument(
        "--db-base",
        help="Base directory containing gut/ oral/ skin/ vaginal/ subdirs (required for --site all)",
    )
    parser.add_argument(
        "--genome-list",
        help="Path to genome_list.tsv for this site (auto-detected when using --db-base + repo-root)",
    )
    parser.add_argument(
        "--repo-root",
        help="Path to the STAMINA-BIOME repo root (used to auto-locate genome_list.tsv files with --site all)",
    )
    parser.add_argument(
        "--threads", type=int, default=4,
        help="Parallel download threads (default: 4)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print what would be downloaded without downloading anything",
    )
    args = parser.parse_args()

    sites_to_run: list[str]
    if args.site == "all":
        sites_to_run = ["vaginal", "gut", "oral", "skin"]
        if not args.db_base:
            parser.error("--db-base is required when --site all")
    else:
        sites_to_run = [args.site]
        if not args.db and not args.dry_run:
            parser.error("--db is required for single-site mode (or add --dry-run)")

    all_results = []
    for site in sites_to_run:
        # Resolve DB path
        if args.site == "all":
            db_path = Path(args.db_base) / site
        else:
            db_path = Path(args.db) if args.db else Path(f"/tmp/dry-run-{site}")

        if not args.dry_run and not db_path.exists():
            print(f"[ERROR] DB path not found: {db_path}")
            if args.site == "all":
                print(f"  Skipping {site}")
                continue
            else:
                sys.exit(1)

        # Resolve genome_list.tsv path
        genome_list_path: Path | None = None
        if args.genome_list:
            genome_list_path = Path(args.genome_list)
        elif args.repo_root:
            genome_list_path = (
                Path(args.repo_root) / "databases" / site / "genome_list.tsv"
            )
        # If neither given, skip genome_list.tsv update (still downloads genomes)

        result = expand_site(
            site=site,
            db_path=db_path,
            genome_list_path=genome_list_path,
            threads=args.threads,
            dry_run=args.dry_run,
        )
        all_results.append(result)

    # ── Final summary across all sites ────────────────────────────────────────
    if len(all_results) > 1:
        print(f"\n{'='*64}")
        print("  OVERALL SUMMARY")
        print(f"{'='*64}")
        total_ok = total_fail = total_miss = 0
        for r in all_results:
            print(
                f"  {r['site']:8s}  targeted={r['targeted']:3d}  "
                f"ok={r['ok']:3d}  fail={r['fail']:3d}  not-in-RefSeq={r['missing']:3d}"
            )
            total_ok   += r["ok"]
            total_fail += r["fail"]
            total_miss += r["missing"]
        print(f"{'─'*64}")
        print(f"  TOTAL     targeted={sum(r['targeted'] for r in all_results):3d}  "
              f"ok={total_ok:3d}  fail={total_fail:3d}  not-in-RefSeq={total_miss:3d}")

    if not args.dry_run:
        print("\n  ── Next steps ──────────────────────────────────────────────────────────────")
        for site in sites_to_run:
            db = (Path(args.db_base) / site) if args.site == "all" else Path(args.db or "")
            print(f"\n  {site.upper()}:")
            print(f"    kraken2-build --build --db {db} --threads {args.threads}")
            for length in [500, 750, 1000, 1200, 1500, 2000]:
                print(f"    bracken-build -d {db} -l {length} -k 35 -t {args.threads}")

    print()


if __name__ == "__main__":
    main()
