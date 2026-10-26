# CAMISIM Mock Community Audit Report

**Scope:** Independent verification of the four CAMISIM validation communities (vaginal, gut, oral, skin) defined under `/Volumes/MyPassport/CAMISIM/camisim_configs/{site}/` and `/Volumes/MyPassport/CAMISIM/camisim_genomes/{site}/fasta/`. This audit checks whether the genome FASTA file assigned to each community member actually corresponds — per independent, live NCBI lookup — to the organism name and taxid declared for it in `genome_locations.tsv` / `meta_data.tsv`.

**Method:**
1. Read `genome_locations.tsv`, `meta_data.tsv`, `distribution_0.txt` for each site verbatim (no assumptions from filenames).
2. Extracted the FASTA header (`>` line) of every genome file referenced.
3. Where the file was accession-named (gut/oral/skin), queried the **NCBI Datasets API** (`https://api.ncbi.nlm.nih.gov/datasets/v2/genome/accession/...`) live for the accession's true `organism_name` / `tax_id`.
4. Where the file was named by strain label only (vaginal), located the original NCBI Datasets download package under `camisim_genomes/vaginal/extracted/<label>/ncbi_dataset/data/`, which embeds the `assembly_data_report.jsonl` captured at download time (i.e. NCBI's own record for whatever accession was actually fetched) — and cross-checked that against live NCBI where the finding was material.
5. Independently looked up the **correct, current NCBI taxid** for every *declared* species name via `NCBI eutils esearch` (`db=taxonomy`), and compared it to the value stored in `meta_data.tsv`.
6. No new genomes were downloaded and nothing was modified — this is a read-only audit, per instruction.

**Headline result: this is a severe, systemic data-integrity failure affecting all four communities, not just oral (which was already known to have issues).** Only **20 of 49** community genomes (~41%) are verified correct — i.e. the FASTA content genuinely matches the declared organism. **29 of 49 (~59%) are mislabeled**, several catastrophically (wrong genus, wrong domain, or a taxid pointing to an insect).

| Site | Members | Verified correct | Wrong genome | Taxid also wrong |
|---|---|---|---|---|
| Vaginal | 17 | 6 (35%) | 11 | 0 (taxid column is internally correct for the *declared* label throughout; only the genome file is wrong) |
| Gut | 12 | 6 (50%)* | 5 | 4 |
| Oral | 11 | 4 (36%) | 7 | 6 |
| Skin | 9 | 4 (44%) | 5 | 5 |
| **Total** | **49** | **20 (41%)** | **28** | **15** |

\* Gut also has one additional entry (`P_copri`) whose genome and taxid are both scientifically correct but whose label uses an obsolete genus name — see note below.

---

## Root-cause pattern

Two distinct failure signatures were identified:

**Pattern A — genome and taxid are self-consistent, but both are wrong** (dominant in gut/oral/skin): the `NCBI_ID` in `meta_data.tsv` is not a data-entry typo — it is the *actual* taxid of whatever organism was really downloaded (confirmed live against NCBI, e.g. `Genome_S_mitis`'s taxid 1303 is genuinely *Streptococcus oralis*'s species taxid, matching the wrongly-fetched genome exactly). This means metadata generation copied the taxid from the fetched assembly's real NCBI record rather than from an independently defined species→taxid mapping — i.e. **the wrong accession was selected/fetched in the first place**, upstream of metadata generation.

**Pattern B — genome, taxid, and label are all mutually inconsistent** (a smaller number of especially severe cases): e.g. skin `Genome_C_acnes`'s taxid (1743460) resolves on NCBI to *Allopiophila luteata*, a fly — unrelated to both the declared species (*Cutibacterium acnes*, taxid 1747) **and** the actual genome content (*Geobacillus sp.* C56-T3). Oral `Genome_T_forsythia`'s taxid (224471) resolves to "*Burkholderiales genera incertae sedis*" (an unclassified higher-rank node), not a species. Oral `Genome_A_naeslundii`'s genome is genuinely correct (*Actinomyces naeslundii*), but its taxid (1760) resolves to the *class* Actinomycetes — three-way incoherent metadata.

For vaginal, the picture is different again: the original NCBI Datasets zip archives downloaded into `camisim_genomes/vaginal/extracted/` already contain the wrong organism at the point of download (confirmed from the NCBI-generated `assembly_data_report.jsonl` shipped inside each zip) — this is not a corruption introduced later when building `fasta/`. The `meta_data.tsv` taxid column for vaginal, however, is internally correct for the *declared* species throughout (all 17 checked exactly against live NCBI) — only the genome content itself is wrong. This means whoever assembled the vaginal accession list pulled the wrong accession for each species from the start, but hand-entered (or separately sourced) the taxid column correctly.

---

## VAGINAL — detailed findings

| Genome_ID (label) | Declared species | meta_data taxid | Verified via | **Actual organism (NCBI-confirmed)** | Status |
|---|---|---|---|---|---|
| Genome_Lcrispatus_CTV05 | *Lactobacillus crispatus* | 47770 (correct for label) | extracted zip → GCA_000091565.1 | **Erwinia amylovora CFBP1430** (plant pathogen, fire blight) | ❌ WRONG — different genus, different domain of host (plant vs. human pathogen) |
| Genome_Lcrispatus_JV_V01 | *Lactobacillus crispatus* | 47770 | extracted zip → GCA_000017865.1 | **Pseudothermotoga lettingae TMO** (thermophilic anaerobe) | ❌ WRONG |
| Genome_Lcrispatus_CO3 | *Lactobacillus crispatus* | 47770 | extracted zip → GCF_003795065.1 | *Lactobacillus crispatus* | ✅ Correct |
| Genome_Liners_KY | *Lactobacillus iners* | 147802 | extracted zip → GCF_010748955.1 | *Lactobacillus iners* | ✅ Correct |
| Genome_Liners_C0094A1 | *Lactobacillus iners* | 147802 | extracted zip → GCF_011058695.1 | *Lactobacillus iners* | ✅ Correct |
| Genome_Ljensenii | *Lactobacillus jensenii* | 109790 | extracted zip → GCA_000413095.1 | **Treponema denticola SP32** (oral spirochete, periodontal pathogen) | ❌ WRONG |
| Genome_Lgasseri | *Lactobacillus gasseri* | 1596 | extracted zip → GCA_000014425.1 | *Lactobacillus gasseri* ATCC 33323 | ✅ Correct |
| Genome_Lvaginalis | *Limosilactobacillus vaginalis* (current name; formerly *L. vaginalis*) | 1633 | extracted zip → GCA_000163135.1 | **Brucella sp. NVSL 07-0026** (zoonotic pathogen genus) | ❌ WRONG |
| Genome_Gardnerella_vaginalis | *Gardnerella vaginalis* | 2702 | extracted zip → GCA_000168195.1 | **Campylobacter jejuni subsp. jejuni 84-25** (foodborne gut pathogen) | ❌ WRONG |
| Genome_Gardnerella_leopoldii | *Gardnerella leopoldii* | 2792978 | extracted zip → GCF_900097085.1 | **Neisseria gonorrhoeae** | ❌ WRONG — reportable STI pathogen swapped in |
| Genome_Gardnerella_piotii | *Gardnerella piotii* | 2792977 | extracted zip → GCF_900113345.1 | **Phaeobacter italicus** (marine Rhodobacteraceae) | ❌ WRONG — ecologically alien |
| Genome_Fannyhessea_vaginae | *Fannyhessea vaginae* (formerly *Atopobium vaginae*) | 82135 | extracted zip → GCA_000154185.1 | **Francisella tularensis subsp. novicida GA99-3549** | ❌ WRONG — F. tularensis is a CDC Tier 1 Select Agent-adjacent organism; entirely inappropriate content regardless of intent |
| Genome_Prevotella_bivia | *Prevotella bivia* | 28125 | extracted zip → GCF_030219305.1 | *Prevotella bivia* | ✅ Correct |
| Genome_Mobiluncus_mulieris | *Mobiluncus mulieris* | 2052 | extracted zip → GCF_000147875.1 | **Methanolacinia petrolearia DSM 11571** (archaeon) | ❌ WRONG — wrong domain of life entirely |
| Genome_Streptococcus_agalactiae | *Streptococcus agalactiae* | 1311 | extracted zip → GCA_000007265.1 | *Streptococcus agalactiae* 2603V/R | ✅ Correct |
| Genome_Ureaplasma_urealyticum | *Ureaplasma urealyticum* | 2130 | extracted zip → GCA_000006625.1 | **Ureaplasma parvum** serovar 3 ATCC 700970 | ❌ WRONG SPECIES — *U. parvum* and *U. urealyticum* were split into distinct species in 2002; same genus, different species |
| Genome_Anaerococcus_prevotii | *Anaerococcus prevotii* | 33034 | extracted zip → GCA_000154325.1 | **[Eubacterium] siraeum DSM 15702** (gut-associated, not vaginal) | ❌ WRONG |

**11/17 wrong.** Note the taxid column is correct for the declared label in all 17 cases — the failure is isolated to the genome download step. Note also that the original zip archives under `extracted/` already contain the wrong content — this is not something introduced later when `fasta/` was built from them.

---

## GUT — detailed findings

| Genome_ID (label) | Declared species | meta_data taxid | Correct taxid | **Actual organism (NCBI Datasets-confirmed)** | Status |
|---|---|---|---|---|---|
| Genome_B_thetaiotaomicron | *Bacteroides thetaiotaomicron* | 818 | 818 ✓ | *Bacteroides thetaiotaomicron* DSM 2079 | ✅ Correct |
| Genome_F_prausnitzii | *Faecalibacterium prausnitzii* | 853 | 853 ✓ | *Faecalibacterium prausnitzii* M21/2 | ✅ Correct |
| Genome_B_longum | *Bifidobacterium longum* | **1678** | 216816 | **Bifidobacterium moraviense** DSM 109958 | ❌ WRONG genome **and** wrong taxid — 1678 is the *genus*-level Bifidobacterium node, not species-level *B. longum* (216816); genome is a different, much rarer species |
| Genome_A_muciniphila | *Akkermansia muciniphila* | 239935 | 239935 ✓ | *Akkermansia muciniphila* JCM 30893 | ✅ Correct |
| Genome_E_coli | *Escherichia coli* | 562 | 562 ✓ | *E. coli* **O157:H7 str. Sakai** (EHEC) | ⚠️ Species correct, but this is a virulent EHEC reference strain, not a benign commensal — a biological-realism concern, see Phase 6 note below |
| Genome_L_rhamnosus | *Lacticaseibacillus rhamnosus* | **1596** | 47715 | **Lactobacillus gasseri** ATCC 33323 | ❌ WRONG — 1596 is *L. gasseri*'s taxid, not *L. rhamnosus*'s (47715); genome and taxid are self-consistently *L. gasseri* |
| Genome_R_intestinalis | *Roseburia intestinalis* | **40520** | 166486 | **Blautia obeum** ATCC 29174 | ❌ WRONG — 40520 is *Blautia obeum*'s taxid; genome and taxid self-consistently *B. obeum* |
| Genome_C_difficile | *Clostridioides difficile* | **1502** | 1496 | **Clostridium perfringens** FDAARGOS_903 | ❌ WRONG — 1502 is *C. perfringens*'s taxid, not *C. difficile*'s (1496); genome and taxid self-consistently *C. perfringens* |
| Genome_B_fragilis | *Bacteroides fragilis* | 817 | 817 ✓ | *Bacteroides fragilis* NCTC 9343 | ✅ Correct |
| Genome_P_copri | *Prevotella copri* | 165179 | 165179 ✓ (current name: *Segatella copri*) | *Segatella copri* DSM 18205 | ✅ Genome and taxid correct; **label uses the obsolete pre-2023 genus name** (*Prevotella copri* → *Segatella copri*, per the 2023 Hitch et al. reclassification of Prevotellaceae) — cosmetic/nomenclature fix only |
| Genome_R_gnavus | *Mediterraneibacter gnavus* (formerly *Ruminococcus gnavus*) | **166486** | 33038 | **Roseburia intestinalis** L1-82 | ❌ WRONG — 166486 is *Roseburia intestinalis*'s taxid, not *R./M. gnavus*'s (33038); genome and taxid self-consistently *R. intestinalis* |
| Genome_H_pylori | *Helicobacter pylori* | 210 | 210 ✓ | *Helicobacter pylori* CHC155 | ✅ Correct |

**5/12 wrong genome, 4/12 also wrong taxid.** Note the striking **R_intestinalis ↔ R_gnavus cross-swap**: R_intestinalis's slot got R. gnavus's real taxid... no — more precisely, R_intestinalis's slot has *Blautia obeum*'s taxid (40520) and R_gnavus's slot has *Roseburia intestinalis*'s taxid (166486). This is not a clean two-way swap between the two declared species, but it does mean two of the four wrong-taxid entries in gut both involve genuinely-adjacent gut Lachnospiraceae/Ruminococcaceae taxa, consistent with an upstream taxid-lookup or accession-list alignment bug rather than pure random corruption.

---

## ORAL — detailed findings

(Consistent with, and much more extensive than, the previously known issue.)

| Genome_ID (label) | Declared species | meta_data taxid | Correct taxid | **Actual organism (NCBI Datasets-confirmed)** | Status |
|---|---|---|---|---|---|
| Genome_R_mucilaginosa | *Rothia mucilaginosa* | 43675 | 43675 ✓ | *Rothia mucilaginosa* DY-18 | ✅ Correct |
| Genome_S_salivarius | *Streptococcus salivarius* | **1318** | 1304 | **Streptococcus parasanguinis** ATCC 15912 | ❌ WRONG — 1318 is *S. parasanguinis*'s taxid; genome+taxid self-consistently *S. parasanguinis* |
| Genome_V_parvula | *Veillonella parvula* | 29466 | 29466 ✓ | *Veillonella parvula* NCTC11810 | ✅ Correct |
| Genome_P_melaninogenica | *Prevotella melaninogenica* | **838** | 28132 | **Prevotella marseillensis** Marseille-P8229 | ❌ WRONG — 838 is only the *genus*-level Prevotella node; genome is a different, obscure species |
| Genome_F_nucleatum | *Fusobacterium nucleatum* | 851 | 851 ✓ | *F. nucleatum* subsp. *nucleatum* ATCC 25586 | ✅ Correct |
| Genome_H_parainfluenzae | *Haemophilus parainfluenzae* | **732** | 729 | **Aggregatibacter aphrophilus** ATCC 33389 | ❌ WRONG — 732 is *A. aphrophilus*'s taxid; genome+taxid self-consistently *A. aphrophilus* (a related HACEK-group organism) |
| Genome_P_gingivalis | *Porphyromonas gingivalis* | **836** | 837 | **Porphyromonas asaccharolytica** DSM 20707 | ❌ WRONG — 836 is only *genus*-level Porphyromonas; the classic "red complex" periodontal pathogen *P. gingivalis* is **entirely absent** from this community despite being declared present |
| Genome_R_mucilaginosa | (see above) | | | | |
| Genome_N_subflava | *Neisseria subflava* | **483** | 28449 | **Neisseria cinerea** NCTC10294 | ❌ WRONG — 483 is *N. cinerea*'s taxid; genome+taxid self-consistently *N. cinerea* |
| Genome_T_forsythia | *Tannerella forsythia* | **224471** | 28112 | **Aquabacterium commune** DSM 11901 | ❌ WRONG, severely — 224471 resolves to "*Burkholderiales genera incertae sedis*" (an unclassified higher taxonomic node in the same order as *Aquabacterium*), not a species; the genome itself is a freshwater/environmental betaproteobacterium totally unrelated to the oral cavity. A second "red complex" periodontal pathogen is **entirely absent** |
| Genome_A_naeslundii | *Actinomyces naeslundii* | **1760** | 1655 | *Actinomyces naeslundii* FDAARGOS_1037 (genome is genuinely correct) | ⚠️ Genome correct, but taxid (1760) resolves to the **class** Actinomycetes, not the species — Kraken2/Bracken would misassign these reads at class rank |
| Genome_S_mitis | *Streptococcus mitis* | **1303** | 28037 | **Streptococcus oralis** ATCC 35037 | ❌ WRONG — 1303 is *S. oralis*'s taxid; genome+taxid self-consistently *S. oralis* |

**7/11 wrong genome, 6/11 also wrong/imprecise taxid.** Both red-complex periodontal pathogens explicitly declared for this community (*P. gingivalis*, *T. forsythia*) are absent from the actual sequence content — the single most biologically damaging finding for oral, since these are the organisms the community was presumably built to specifically validate detection of.

---

## SKIN — detailed findings

| Genome_ID (label) | Declared species | meta_data taxid | Correct taxid | **Actual organism (NCBI Datasets-confirmed)** | Status |
|---|---|---|---|---|---|
| Genome_S_epidermidis | *Staphylococcus epidermidis* | 1282 | 1282 ✓ | *S. epidermidis* ATCC 14990 | ✅ Correct |
| Genome_S_aureus | *Staphylococcus aureus* | 1280 | 1280 ✓ | *S. aureus* subsp. *aureus* NCTC 8325 | ✅ Correct |
| Genome_C_tuberculostearicum | *Corynebacterium tuberculostearicum* | **38301** | 38304 | **Corynebacterium minutissimum** NCTC10288 | ❌ WRONG — off-by-a-few-digits taxid (38301 vs. correct 38304) that happens to be *C. minutissimum*'s real taxid; genome+taxid self-consistently *C. minutissimum*. *C. tuberculostearicum* is one of the most abundant, ecologically important skin Corynebacteria (notably in moist sites) and is **entirely absent** |
| Genome_M_globosa | *Malassezia globosa* | **55193** | 76773 | **Malassezia japonica** | ❌ WRONG — 55193 resolves only to the *genus* Malassezia, not species-level; genome is a different, uncommon Malassezia species |
| Genome_M_restricta | *Malassezia restricta* | **76773** | 76775 | **Malassezia globosa** CBS 7966 | ❌ WRONG — 76773 is *M. globosa*'s real taxid; genome+taxid self-consistently *M. globosa*. Note the apparent cross-contamination with the M_globosa slot above: 76773 is used as the (wrong) taxid here but is the *correct* taxid for the *other* mislabeled entry — both Malassezia slots are wrong, in different ways |
| Genome_M_luteus | *Micrococcus luteus* | 1270 | 1270 ✓ | *Micrococcus luteus* NCTC 2665 | ✅ Correct |
| Genome_S_haemolyticus | *Staphylococcus haemolyticus* | 1283 | 1283 ✓ | *S. haemolyticus* ATCC 29970 | ✅ Correct |
| Genome_B_linens | *Brevibacterium linens* | **1697** | 1703 | **Corynebacterium ammoniagenes** DSM 20306 | ❌ WRONG — 1697 is *C. ammoniagenes*'s real taxid; genome+taxid self-consistently *C. ammoniagenes* |
| Genome_C_acnes | *Cutibacterium acnes* | **1743460** | 1747 | **Geobacillus sp. C56-T3** | ❌ WRONG, most severe finding in the entire audit — taxid 1743460 resolves on NCBI to ***Allopiophila luteata***, a fly (order Diptera). The taxid does not match the label, does not match the genome, and does not match any bacterium. *Cutibacterium acnes* is arguably **the single most important organism for a skin microbiome validation community** (dominant sebaceous-site commensal, acne-associated) and it is completely absent. |

**5/9 wrong genome, 5/9 also wrong/imprecise taxid.**

---

## Scope note

This audit covers the `fasta/` tier of `camisim_genomes/{site}/` — i.e. the genomes actually referenced by `genome_locations.tsv` and therefore the genomes CAMISIM actually simulates reads from. It does **not** cover `fasta_comprehensive/` (a much larger genome set, apparently a broader Kraken2-database backbone layer rather than CAMISIM community members) or the `custom_db/` Kraken2 databases themselves — those are separate audit scopes (Phase 3/4 of the overall project plan) and have not been touched here.

No files were modified, downloaded, or replaced as part of this initial audit, per instruction.

## Recommendation (as of initial audit)

Every mislabeled entry above needs a fresh, individually-verified NCBI accession before these communities can be considered valid ground truth for benchmarking STAMINA-BIOME. Given how large a fraction of each community is affected (35–59% per site) and that several of the substitute genomes are biologically nonsensical for the body site (an archaeon, a plant pathogen, a fly taxid, a select-agent-adjacent organism), regenerating the accession list from scratch with per-accession NCBI verification is safer than patching individual entries.

---

# CORRECTION PASS

All 29 mislabeled entries were corrected. For each, a replacement NCBI accession was independently sourced (not from memory) via the live **NCBI Datasets API** (`genome/taxon/{taxid}/dataset_report`, preferring `refseq_category=reference genome` at `Complete Genome` level; falling back to the best available RefSeq assembly where no complete-genome reference exists), downloaded, and installed in place of the wrong genome. `genome_locations.tsv` and `meta_data.tsv` were updated to match for all four sites. No fabricated or memory-derived accessions were used — every replacement was a live download whose FASTA header was independently re-confirmed against the intended organism before being kept.

## Replacement accessions used

| Site | Genome_ID | Old (wrong) accession | New (verified) accession | Notes |
|---|---|---|---|---|
| Vaginal | Genome_Lcrispatus_CTV05 | GCA_000091565.1 (*Erwinia amylovora*) | **GCF_000165885.1** | Genuine *L. crispatus* CTV-05 strain — the strain the label always intended |
| Vaginal | Genome_Lcrispatus_JV_V01 | GCA_000017865.1 (*Pseudothermotoga lettingae*) | **GCF_040428475.1** | Genuine *L. crispatus* JV-V01 strain |
| Vaginal | Genome_Ljensenii | GCA_000413095.1 (*Treponema denticola*) | **GCF_001936235.1** | *L. jensenii* strain SNUV360, RefSeq reference genome |
| Vaginal | Genome_Lvaginalis | GCA_000163135.1 (*Brucella sp.*) | **GCF_025311515.1** | *Limosilactobacillus vaginalis*, RefSeq reference genome |
| Vaginal | Genome_Gardnerella_vaginalis | GCA_000168195.1 (*Campylobacter jejuni*) | **GCF_001042655.1** | *G. vaginalis* ATCC 14018 = JCM 11026, RefSeq reference genome |
| Vaginal | Genome_Gardnerella_leopoldii | GCF_900097085.1 (*Neisseria gonorrhoeae*) | **GCF_003293675.1** | RefSeq reference genome (no complete-genome assembly exists for this species; Chromosome-level is the best available) |
| Vaginal | Genome_Gardnerella_piotii | GCF_900113345.1 (*Phaeobacter italicus*) | **GCF_049815665.1** | RefSeq reference genome |
| Vaginal | Genome_Fannyhessea_vaginae | GCA_000154185.1 (*Francisella tularensis*) | **GCF_016026575.1** | RefSeq reference genome |
| Vaginal | Genome_Mobiluncus_mulieris | GCF_000147875.1 (*Methanolacinia petrolearia*) | **GCF_014204735.1** | RefSeq reference genome (Contig-level is the best available for this species) |
| Vaginal | Genome_Ureaplasma_urealyticum | GCA_000006625.1 (*U. parvum*, wrong species) | **GCF_000169535.1** | Serovar 8 str. ATCC 27618 — genuine *U. urealyticum*, RefSeq reference genome |
| Vaginal | Genome_Anaerococcus_prevotii | GCA_000154325.1 (*[Eubacterium] siraeum*) | **GCF_000024105.1** | DSM 20548, RefSeq reference genome |
| Gut | Genome_B_longum | GCF_012932365.1 (*B. moraviense*) | **GCF_000196555.1** | subsp. *longum* JCM 1217, RefSeq reference genome; taxid also fixed 1678→216816 |
| Gut | Genome_L_rhamnosus | GCF_000014425.1 (*L. gasseri*) | **GCF_900636965.1** | RefSeq reference genome; taxid also fixed 1596→47715 |
| Gut | Genome_R_intestinalis | GCF_025147765.1 (*Blautia obeum*) | **GCF_900537995.1** (reused) | This is the genome that was sitting under the *R_gnavus* label — genuinely *R. intestinalis*; taxid fixed 40520→166486 |
| Gut | Genome_C_difficile | GCF_016027375.1 (*C. perfringens*) | **GCF_018885085.1** | RefSeq reference genome; taxid also fixed 1502→1496 |
| Gut | Genome_R_gnavus | GCF_900537995.1 (reassigned to R_intestinalis, see above) | **GCF_009831375.1** | *Mediterraneibacter gnavus* ATCC 29149, RefSeq reference genome; taxid also fixed 166486→33038 |
| Gut | Genome_P_copri → **renamed Genome_Segatella_copri** | GCF_020735445.1 (genome/taxid were already correct) | unchanged | Cosmetic-only fix: label updated to the current (2023) genus name; propagated to `distribution_0.txt` |
| Oral | Genome_S_salivarius | GCF_000164675.2 (*S. parasanguinis*) | **GCF_000253315.1** | JIM8777, RefSeq reference genome; taxid also fixed 1318→1304 |
| Oral | Genome_P_melaninogenica | GCF_900625065.1 (*P. marseillensis*) | **GCF_000144405.1** | ATCC 25845, RefSeq reference genome; taxid also fixed 838→28132 |
| Oral | Genome_H_parainfluenzae | GCF_900636915.1 (*Aggregatibacter aphrophilus*) | **GCF_016127215.1** | RefSeq reference genome; taxid also fixed 732→729 |
| Oral | Genome_P_gingivalis | GCF_000212375.1 (*P. asaccharolytica*) | **GCF_000010505.1** | ATCC 33277 — the classic *P. gingivalis* reference strain; taxid also fixed 836→837 |
| Oral | Genome_N_subflava | GCF_900475315.1 (*N. cinerea*) | **GCF_005221305.1** | ATCC 49275, RefSeq reference genome; taxid also fixed 483→28449 |
| Oral | Genome_T_forsythia | GCF_004362855.1 (*Aquabacterium commune*) | **GCF_000238215.1** | 92A2 — the classic *T. forsythia* reference strain; taxid also fixed 224471→28112 |
| Oral | Genome_S_mitis | GCF_900637025.1 (*S. oralis*) | **GCF_018603625.2** | RefSeq reference genome; taxid also fixed 1303→28037 |
| Oral | Genome_A_naeslundii | GCF_016127855.1 (genome was already correct) | unchanged | Taxid-only fix: 1760 (class Actinomycetes) → 1655 (species) |
| Skin | Genome_C_tuberculostearicum | GCF_900478045.1 (*C. minutissimum*) | **GCF_016728365.1** | RefSeq reference genome; taxid also fixed 38301→38304 |
| Skin | Genome_M_globosa | GCF_029542785.1 (*M. japonica*) | **GCF_000181695.2** (reused) | This is the genome that was sitting under the *M_restricta* label — genuinely *M. globosa* CBS 7966; taxid fixed 55193→76773 |
| Skin | Genome_M_restricta | GCF_000181695.2 (reassigned to M_globosa, see above) | **GCF_003290485.1** | RefSeq reference genome; taxid also fixed 76773→76775 |
| Skin | Genome_B_linens | GCF_001941425.1 (*C. ammoniagenes*) | **GCF_003999335.1** | ATCC 19391, RefSeq reference genome; taxid also fixed 1697→1703 |
| Skin | Genome_C_acnes | GCF_000092445.1 (*Geobacillus sp.*) | **GCF_006739385.1** | subsp. *acnes* NBRC 107605, RefSeq reference genome; taxid also fixed 1743460 (a fly)→1747 |

Two nice side-effects of the fix worth noting: the genuinely-correct genomes that were already sitting on disk under the *wrong* label (*R. intestinalis* mislabeled as *R_gnavus*; *M. globosa* mislabeled as *M_restricta*) were reused rather than re-downloaded — they just needed to be pointed at by the correct `Genome_ID`. And for the two vaginal *L. crispatus* replacement slots, the correct fix turned out to be the *exact* named HMP reference strains (CTV-05, JV-V01) the original labels were always meant to represent — those strain-specific assemblies exist on NCBI and were located and used, rather than substituting an arbitrary different *L. crispatus* genome.

## Reaudit (independent re-verification after correction)

Repeated the identical audit methodology from scratch on the corrected state — fresh header extraction from every genome file, plus a fresh, independent NCBI taxonomy lookup for every declared species (not reusing any cached result from the correction step):

- **49/49 genome FASTA headers** now match their declared species exactly (up from 20/49).
- **46/46 unique declared-species taxids** in `meta_data.tsv` independently confirmed against live NCBI taxonomy — zero mismatches.
- **Label consistency**: `genome_locations.tsv`, `meta_data.tsv`, and `distribution_0.txt` reference an identical set of `Genome_ID`s for all four sites (17 vaginal / 12 gut / 11 oral / 9 skin) — no orphaned or dangling labels after the `Genome_P_copri`→`Genome_Segatella_copri` rename.
- **File integrity**: every path in every `genome_locations.tsv` resolves to an existing file; no orphaned genome files left on disk from the swap/replace operations.
- **Abundance distributions**: `distribution_0.txt` still sums to 1.0000 for all four sites.

All four CAMISIM validation communities are now verified, self-consistent, and biologically correctly identified against live NCBI records.

## Scope carried forward

This correction only touched the `fasta/` tier (CAMISIM community members). `fasta_comprehensive/` (the broader Kraken2 backbone layer) and the `custom_db/` Kraken2 databases themselves have not been audited or touched, and CAMISIM has not yet been re-run to regenerate simulated reads from the corrected genomes — those remain open work (Phases 3/4 and 8/9 of the overall project plan).
