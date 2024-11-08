#!/bin/bash
if [ $# -eq 1 ]; then
    fastq_path=$1

    #Keep reads in fastq.gz in the specified folder and get rid of fastq
    rm -rf work
    rm .nextflow.log
    export K2_STD_DB_PATH=$PWD

    # For ONT
    # ./startWorkflow.nf --platform n --in ${fastq_path} --out point_loma

    # For single-end Illumina
    ./startWorkflow.nf --platform s --in ${fastq_path} --out point_loma

    bam_file=$(find work -name resorted.bam | head -n 1)

    # Copy bam to Freyja
    cp ${bam_file} ${fastq_path}/../src/Freyja/
    cp ${bam_file} ${fastq_path}


    #convert sam to fastq
    #samtools sort -n aligned.sam -o sorted_aligned.sam
    #samtools fastq sorted_aligned.sam > my_vcf_reads.fastq
fi
