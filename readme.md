# CFSAN Wastewater Analysis Pipeline 
## C-WAP

| **Made the following changes:
1. Commented out a few stages of the pipeline to make it faster.
2. Replaced bowtie with minimap2 even for Illumina data.
3. Performing ivar trimming with low quality threshold for all types of sequencing data.** |
|:------ |

| **Given the [project timeline](https://www.fda.gov/food/whole-genome-sequencing-wgs-program/wastewater-surveillance-sars-cov-2-variants), C-WAP will no longer be under active development or maintenance come June 30, 2023. Please refer to the C-WAP successor [Aquascope](https://github.com/CDCgov/aquascope) for an actively supported workflow. [Freyja](https://github.com/andersen-lab/Freyja) or [Kallisto](https://github.com/pachterlab/kallisto) (two of the tools C-WAP incorporates) may also be of interest. Thank you for joining us on our analytic journey.**  | 
|:------ |

## Introduction

The CFSAN Wastewater Analysis Pipeline (C-WAP) uses a reference-based alignment to create a matrix of SNPs for a given set of samples and estimate the percentage of SARS-CoV-2 variants in the sample. 

The process includes the following:
1. Designating a reference and NGS data in fastq format
2. Alignment of reads to the reference via Bowtie2
3. Taxonomy check via Kraken2
4. Processing of alignment results via Samtools
5. Detection of variant positions with iVar
6. Determine composition of variants via Kallisto, Linear Regression, Kraken2/Bracken and Freyja
7. Generate an HTML and PDF formatted summary of results

C-WAP is a Nextflow, Python, and Bash-based bioinformatics pipeline for the analysis of either long-read (Oxford Nanopore Technologies or PacBio) or short-read (Illumina) whole genome sequencing data of DNA extracted from wastewater. It was developed for SARS-CoV-2 and its variants.

C-WAP was developed by the United States Food and Drug Administration, Center for Food Safety and Applied Nutrition.

## Installation

Install [Nextflow](https://github.com/nextflow-io/nextflow/releases/tag/v21.12.1-edge), [Conda](https://docs.conda.io/en/latest/miniconda.html), and [Micromamba](https://github.com/mamba-org/micromamba-docker/releases/tag/v1.0.0). Afterwards, download c-wap repository and save. In addition, also obtain a copy of the Kraken2 standard DB (~50GB). You can either download a copy from here: https://benlangmead.github.io/aws-indexes/k2 or you can compile your own version following the instructions under the "Standard Kraken2 Database" section here: https://github.com/DerrickWood/kraken2/blob/master/docs/MANUAL.markdown

Afterwards, set `$K2_STD_DB_PATH` to your download location.

### Dependencies

User provided:
* [Conda3](https://docs.conda.io/en/latest/miniconda.html)
* [Micromamba v1.0.0](https://github.com/mamba-org/micromamba-docker/releases/tag/v1.0.0)
* [NextFlow v21.12.1](https://github.com/nextflow-io/nextflow/releases/tag/v21.12.1-edge)

Auto-fetched by C-WAP:
* [Bowtie2 v2.4.5](http://bowtie-bio.sourceforge.net/bowtie2/manual.shtml)
* [Minimap2 v2.24](https://github.com/lh3/minimap2)
* [iVar v1.3.1](https://github.com/andersen-lab/ivar)
* [Samtools v1.15](https://github.com/samtools/)
* [Kraken2 v2.1.2 ](https://github.com/DerrickWood/kraken2)
* [Bracken v2.7](https://github.com/jenniferlu717/Bracken)
* [Python v3.8.1](https://www.python.org/)
* [Bcftools v1.15](https://github.com/samtools/bcftools)
* [Pangolin v4.1.2](https://github.com/cov-lineages/pangolin)
* [Kallisto v0.48](https://github.com/pachterlab/kallisto)
* [Entrez-direct v16.2](https://www.ncbi.nlm.nih.gov/books/NBK179288/)
* [Freyja v1.4.4](https://github.com/andersen-lab/Freyja)
* [Wkhtmltopdf v0.12.4](https://github.com/wkhtmltopdf)
* [Ghostscript v9.54](https://www.ghostscript.com)

`./startWorkflow.nf` assumes that Conda, Micromamba, Nextflow and Ghostscript executables are available in the search path. All other dependencies are imported via Conda, with the exception of Freyja, which is imported via Micromamba. To trigger this installation, execute `c-wap/prepare_envs.sh` (no root privileges needed). The series of acquisition of the dependencies and creating of the environments might take a substantially long time (potentially hours). Subsequent analysis calls to C-WAP will make use of the cached environments stored under the `c-wap/conda` subdirectory and are expected to finish substantially faster. To update the dependencies (more often required for tools with a biological DB) delete the respective environment folder `c-wap/conda/env-<toolName>` and re-execute `c-wap/prepare_envs.sh`.

## Usage 

The driver script is `startWorkflow.nf` and a standard execution with paired-end Illumina reads would be:  
`startWorkflow.nf --platform i --primers path/to/bed --in path/to/fastq/ --out path/to/outputDir`

Note that the input files need to be compressed `fastq.gz` formats only, and `.sam`, `.bam` or uncompressed `.fastq` files result in a fatal runtime error.

## Output

C-WAP produces a number of files from the various processing steps.  

`report` - Standalone directory containing html and pdf summary report  
`absCounts.csv` - Absolute counts table of uncovered and undercovered genes  
`breadthVcov.csv` - Table of coverage depth and breadth  
`consensus.fa` - Consensus fasta file generated by iVar  
`crdSNPs.csv` - Table of common, rare, and diverse SNP coverages  
`freyja.demix` - Lineage abundance estimate generated by Freyja  
`freyja_boot_lineages.csv` - Freyja generated bootstraps  
`k2-majorCovid.out` - Covid-specific kraken2 output with major lineages identified, against majorCovid DB  
`k2-majorCovid_bracken.out` - Bracken lineage abundance estimates, against majorCovid DB  
`k2-std.out` - Kraken2 output with standard database  
`kallisto.out` - Python-parsed summary of the kallisto lineage abundance estimates  
`kallisto_abundance.tsv` - Kallisto estimates of variant composition  
`lineage_report.csv` - Pangolin lineage prediction for the consensus sequence  
`linearDeconvolution_abundance.csv` - Linear deconvolution estimates of variant composition  
`mutationTable.csv` - Lineage defining mutations  
`pos-coverage-quality.tsv` - QC metrics on coverage and quality obtained from the pileup file  
`primer_hit_counts.tsv` - Number of reads per primer  
`qc-flags` - Suggested QC flags  
`resorted.stats` - Samtools stats output from aligned and trimmed reads  
`scaledCounts.csv` - Scaled counts table of uncovered and undercovered genes  
`seqSummary.csv` - Average read quality, length, and coverage passing filter  
`sorted.stats` - Samtools stats output from aligned but untrimmed reads  


### Note about variant composition

Variant composition analyses should be interpreted with caution where they should be treated as suspect if there are substantial gaps in coverage across the reference genome and/or a lack of sequencing depth.  The Linear Deconvolution and Kraken2/Bracken COVID methods are internally developed methods and under testing and validation.  

## Citing C-WAP

| **Kayikcioglu T, Amirzadegan J, Rand H, Tesfaldet B, Timme RE, Pettengill JB. [Performance of methods for SARS-CoV-2 variant detection and abundance estimation within mixed population samples.](https://pubmed.ncbi.nlm.nih.gov/36721781/) ***PeerJ. 2023 Jan 26;11:e14596.*** doi: 10.7717/peerj.14596. PMID: 36721781; PMCID: PMC9884472.** | 
|:------ | 

### GISAID citation

We gratefully acknowledge all data contributors, i.e., the Authors and their Originating laboratories responsible for obtaining the specimens, and their Submitting laboratories for generating the genetic sequence and metadata and sharing via the GISAID Initiative, some of which this research utlizes.

Khare, S., et al (2021) GISAID’s Role in Pandemic Response. China CDC Weekly, 3(49): 1049-1051. doi: 10.46234/ccdcw2021.255 PMCID: 8668406

## License

See the `LICENSE.txt` file included in the C-WAP Pipeline distribution.
