#! /usr/bin/env nextflow


switch(params.platform) {
    case "i":
    case "Illumina":
        print("Paired end Illumina mode")
        platform = "Illumina"
        isPairedEnd = true
        break;
    case "s":
        print("Single read Illumina mode")
        platform = "Illumina"
        isPairedEnd = false
        break;
    case "n":
    case "ONT":
    case "nanopore":
        print("Nanopore mode")
        platform = "ONT"
        isPairedEnd = false
        break;
    case "p":
    case "pb":
    case "PB":
    case "pacbio":
    case "PacBio":
        print("PacBio mode")
        platform = "PacBio"
        isPairedEnd = false
        break;
    case "h":
        printUsage()
        return 0
    default:
        print("ERROR: unknown sequencing modality")
        printUsage()
        return 1
}


// Convert relative path to absolute path
if (params.primerBedFile[0]=='/' || params.primerBedFile[0]=='~')
    primerBedFile=params.primerBedFile
else
    primerBedFile="$launchDir/$params.primerBedFile"


def printUsage () {
    println("Example usage: ")
    println("\t./startWorkflow.nf --platform i --primers path/to/bed --in path/to/fastq/ --out path/to/outputDir")
    println()
    println("Run the C-WAP workflow that will import the fastq files, trim adaptors, apply quality trimming, call variants and generate a html and pdf report and quit. All fastq files in the provided directory will be processed.")
    println()
    
    println("Platform options:")
    println("\t-h\t\t: Show this help message and exit.")
    println("\t-i\t\t: Use parameters optimised for the Illumina platform, paired-end mode")
    println("\t-s\t\t: Use parameters optimised for the Illumina platform, single read mode")
    println("\t-n\t\t: Use parameters optimised for the ONT platform")
    println("\t-p\t\t: Use parameters optimised for PacBio platform")
}


// Given a file name, extracts a human readable sample name to be used in the output.
allSampleNames = []
def getSampleName(filename) {
    // Typical for most users using Illumina output as is
    // Ex: /path/to/dir/something_S1_L2_R1.fastq -> something
    sampleName = filename.name.split("/")[-1].split("\\.")[0].split("_")[0]
        
    // For complicated file names involving underscores that cannot be eliminated
    // Ex: /path/to/dir/some_thing_R1.fastq -> some-thing	
    // sampleName = filename.name.split("/")[-1].split("\\.")[0].split("_R")[0].replace('_','-')
    
    // If there are special fixed substrings available within all file names.
    // Ex: /path/to/dir/some_thing_1art_out_R1.fastq -> some-thing-1
    // sampleName = filename.name.split("/")[-1].split("\\.")[0].split("art_out")[0].replace('_','-')
    
    // PacBio Lima output pattern
    // some-name.bc1234.fastq.gz
    // sampleName = filename.name.split("/")[-1].split("\\.")[1].split("--")[0]

    
    // Check if there is name collision and immediately abort the execution if this is the case.
    if (allSampleNames.contains(sampleName)) {
        throw new IllegalArgumentException ('The sample name is not unique, please adjust the getSampleName function.')
    }
    else {
        allSampleNames += sampleName
        return sampleName
    }
}


// Import the list of files to process
if (isPairedEnd) {
    FQs = Channel
        .fromFilePairs("$params.in/*_R{1,2}*.fastq*", checkIfExists: true, flat:true)
        .map{ tuple(getSampleName(it[1]), it[1], it[2]) }
}
else {
    FQs = Channel
        .fromPath( "$params.in/*.fastq*", checkIfExists: true)
        .map{ tuple(getSampleName(it), it, null) }
}


FQs
    .view()
    .into{ input_fq_a; input_fq_b; input_fq_c; input_fq_d; input_fq_e }



//////////////////////////////////////////////////////////////////////////
// Read processing using common tools, QC etc.
//////////////////////////////////////////////////////////////////////////

// Align the reads to the reference sequence to obtain a sorted bam file
process referenceAlignment {
    label 'high_cpu'
    
    input:
        tuple val(sampleName), file('R1.fastq.gz'), file('R2.fastq.gz') from input_fq_a
    
    output:
        tuple val(sampleName), file('aligned.sam') into aligned_sam

    conda "$projectDir/conda/env-minimap2"
    
    shell:
    refSeqBasename = params.referenceSequence.replaceAll('.fa$', '')
    """
        if [[ -n \$SLURM_CPUS_ON_NODE ]]; then
            numThreads=\$SLURM_CPUS_ON_NODE
        else
            numThreads=\$(nproc)
        fi
        
        case $platform in
            Illumina)
                if $isPairedEnd; then
                    minimap2 -a --sam-hit-only -2 -x sr ${refSeqBasename}.mmi R1.fastq.gz R2.fastq.gz -t \$numThreads -o aligned.sam
                else
                    minimap2 -a --sam-hit-only -2 -x sr ${refSeqBasename}.mmi R1.fastq.gz -t \$numThreads -o aligned.sam
                fi
                ;;
            ONT)
                minimap2 -a --sam-hit-only -2 -x map-ont ${refSeqBasename}.mmi R1.fastq.gz -t \$numThreads -o aligned.sam
                ;;
            PacBio)
                minimap2 -a --sam-hit-only -2 -x map-hifi $projectDir/covidRefSequences/PacBioHiFi.mmi R1.fastq.gz -t \$numThreads -o aligned.sam
                ;;
        esac
    """
}


// Align the reads to the reference sequence to obtain a sorted bam file
process trimming {
    label 'high_cpu'
    
    input:
        tuple val(sampleName), file('aligned.sam') from aligned_sam
    
    output:
        tuple val(sampleName), env(numReads), path('resorted.bam') into resorted_bam_a, resorted_bam_b,  resorted_bam_c,  resorted_bam_d
        tuple val(sampleName), path('sorted.stats'), path('resorted.stats'), path('primer_hit_counts.tsv') into samtools_stats
    
    // An older version of samtools is automatically provided by ivar's dependency
    // Does one need to provide samtools=1.15 here? 
    // It is possible one does have to provide samtools=1.15 here JA 2022 12 08
    conda "$projectDir/conda/env-ivar"

    shell:
    """
        if [[ -n \$SLURM_CPUS_ON_NODE ]]; then
            numThreads=\$SLURM_CPUS_ON_NODE
        else
            numThreads=\$(nproc)
        fi
        
        # Generation of a sorted bam file from the alignment output
        samtools sort aligned.sam -o sorted.bam -@ \$numThreads
        
        # Nanopore has a much lower read quality, so the quality trimming should be much more lax.
        #ivar trim -e -b $primerBedFile -p trimmed -i sorted.bam -q 1 | tee ivar.stdout
        ivar trim -e -b $primerBedFile -p trimmed -i sorted.bam -q 10 -m 80 -x 3 | tee ivar.stdout
        
        # Generate a tsv file tabulating the number of reads vs trimmer primer name in the bed file
        cat ivar.stdout | grep -A 10000 "Primer Name" | head -n -5 > primer_hit_counts.tsv
        
        samtools sort trimmed.bam -o resorted.bam -@ \$numThreads
        
        # Evaluate read statistics
        samtools stats sorted.bam | grep ^SN | cut -f 2- > sorted.stats
        samtools stats resorted.bam | grep ^SN | cut -f 2- > resorted.stats
        numReads=\$(cat resorted.stats | grep "raw total sequences" | awk '{ print \$4 }')
        
        rm sorted.bam trimmed.bam
    """
}



process trimmedBam2Fastq {
    input:
        tuple val(sampleName), env(numReads), path('resorted.bam') from resorted_bam_a
    
    output:
        tuple val(sampleName), env(numReads), path('resorted.fastq.gz') into resorted_fastq_gz_a, resorted_fastq_gz_b, resorted_fastq_gz_c
    
    conda "$projectDir/conda/env-samtools"
    
    shell:
    """
        if [[ \$numReads -gt 1000000 ]]; then
            # A maximum of 1 000 000 reads are kept to limit the computation time of variant calling processes.
            echo Subsampling the dataset...
            retentionRatio=\$(echo 3k 1000000 \$numReads /p | dc)
            samtools view --threads 2 --subsample \$retentionRatio resorted.bam -o resorted.sam
        else
            samtools view --threads 2 resorted.bam -o resorted.sam
        fi
        
        $projectDir/sam2fastq.py resorted.sam resorted.fastq
        gzip resorted.fastq
        rm resorted.sam
    """
}


process generatePileup {
    input:
        tuple val(sampleName), env(numReads), path('resorted.bam') from resorted_bam_b
    
    output:
        tuple val(sampleName), path('pile.up') into pile_up_a, pile_up_b
    
    conda "$projectDir/conda/env-samtools"
    
    shell:
    """
        samtools mpileup -aa -A -d 10000 -B -Q 0 --reference $params.referenceSequence -o pile.up resorted.bam
    """
}



process variantCalling {
    input:
        tuple val(sampleName), path('pile.up') from pile_up_a
    
    output:
        tuple val(sampleName), path('rawVarCalls.tsv') into ivar_out
    
    conda "$projectDir/conda/env-ivar"
    
    shell:
    """
        cat pile.up | ivar variants -p rawVarCalls -g $projectDir/covidRefSequences/covidGenomeAnnotation-NCBI.gff \
        -r $params.referenceSequence -m 10
    """
}


// Kraken2-based taxonomic classification
process k2stdDB {
    memory '70 GB'
    label 'high_IO'
    
    input:
        tuple val(sampleName), file('R1.fastq.gz'), file('R2.fastq.gz') from input_fq_b
    
    output:
        tuple val(sampleName), path('k2-std.out') into k2_std_out
    
    conda "$projectDir/conda/env-kraken2"
    
    shell:
    """	
        if $isPairedEnd; then
            kraken2 --paired R1.fastq.gz R2.fastq.gz --db \$K2_STD_DB_PATH --threads 2 --report k2-std.out > /dev/null
        else
            kraken2 R1.fastq.gz --db \$K2_STD_DB_PATH --threads 2 --report k2-std.out > /dev/null
        fi	
    """
}


// The pileup file is parsed to calculate the positionwise quality and depth parameters.
// The result is stored as png files that are added to the html report
process QCplots {
    input:
        tuple val(sampleName), path('pile.up') from pile_up_b
    
    output:
        tuple val(sampleName), path('pos-coverage-quality.tsv'), path('coverage.png'), path('depthHistogram.png'), path('quality.png'), path('qualityHistogram.png'), path('discontinuitySignal.png'), path('genesVSuncovered_abscounts.png'), path('genesVSuncovered_scaled.png'), path('absCounts.csv'), path('scaledCounts.csv'), path('breadthVcov.csv'), path('breadthVSdepth.png') into QChists

    conda "$projectDir/conda/env-python"
    
    shell:
    """
        python3 $projectDir/plotQC.py pile.up $primerBedFile
    """
}


// Draw a histogram of all read lengths
process readLengthHist {
    input:
        tuple val(sampleName), file('R1.fastq.gz'), file('R2.fastq.gz') from input_fq_d
    
    output:
        tuple val(sampleName), path('readLengthHist.png') into readLengthHist_png
        tuple val(sampleName), path('readLengthHist.png'), path('timeVSreadcounts.png') into readLengthHist_out


    conda "$projectDir/conda/env-python"
    label 'high_IO'

    shell:
    """
        gzip -dc R1.fastq.gz > allreads.fastq
        if $isPairedEnd; then
            gzip -dc R2.fastq.gz >> allreads.fastq
        fi
        
        # Only up to 1 million reads will be considered for the length histogram
        head -n 4000000 allreads.fastq | awk 'NR%4==2' | awk "{print length}" | python3 $projectDir/plotLengthHist.py
        
        # If this is an ONT run with detailed headers, also plot read count w.r.t time to show if the data collection
        # was essentially complete.
        # An example ONT fastq entry header with a timestamp looks like this:
        # @b6a37669-02b7-4d48-bcff-ad7e2eb4fa06 runid=52014692ae58b6d24cb1dcd29fd35d118e5f6a42 read=16 ch=304 start_time=2022-06-29T15:57:00.583046-04:00 flow_cell_id=FAT09511 protocol_group_id=VSS_spikein_June22toJune28_062922 sample_id=no_sample barcode=barcode49 barcode_alias=barcode49 parent_read_id=b6a37669-02b7-4d48-bcff-ad7e2eb4fa06 basecall_model_version_id=2021-05-17_dna_r9.4.1_minion_96_29d8704b
           touch timeVSreadcounts.png
        if [[ $platform == ONT ]]; then
            cat allreads.fastq | grep start_time | cut -d ' ' -f 5 | awk -F 'start_time=' '{print \$2}' > timestamps
            if [[ -s timestamps ]]; then
                $projectDir/plotTimeVSreadcounts.py ./timestamps timeVSreadcounts.png
            fi
        fi
        
           rm allreads.fastq
    """
}



// ////////////////////////////////////////////
// VARIANT CALLING
// ////////////////////////////////////////////

process krakenVariantCaller {
    input:
        tuple val(sampleName), env(numReads), path('resorted.fastq.gz') from resorted_fastq_gz_a
    
    output:
        //tuple val(sampleName), path('k2-allCovid_bracken*.out'), path('k2-majorCovid_bracken*.out'), path('k2-allCovid.out'), path('k2-majorCovid.out') into k2_covid_out
        tuple val(sampleName), path('k2-majorCovid_bracken*.out'), path('k2-majorCovid.out') into k2_covid_out
    
    conda "$projectDir/conda/env-kraken2"
    
    shell:
    """
        if [[ -n \$SLURM_CPUS_ON_NODE ]]; then
            numThreads=\$SLURM_CPUS_ON_NODE
        else
            numThreads=\$(nproc)
        fi

        ## Check the number of reads. Ignore if there are too few reads
        kraken2 resorted.fastq.gz --db $projectDir/customDBs/majorCovidDB --threads \$numThreads --report k2-majorCovid.out > /dev/null
        num_class_hits=\$(cat k2-majorCovid.out | grep -w C | cut -f 2 | head -n 1)
        if [[ -z \${num_class_hits} || \${num_class_hits} -lt 10 ]]; then
            # There is a bug in bracken that throws a "no reads found" error, if there
            # are fewer hits in all target level taxons. We check that there are a minimum of 10 reads.
            echo 100.00\$'\t'0\$'\t'0\$'\t'R\$'\t'1\$'\t'root > k2-majorCovid_bracken.out
        else
            bracken -d $projectDir/customDBs/majorCovidDB -i k2-majorCovid.out -o majorCovid.bracken -l C
        fi
    """
}


// Calculation of the consensus sequence using bcftools
process consensusSequence {
    // label 'high_IO'
    
    input:
        tuple val(sampleName), env(numReads), path('resorted.bam') from resorted_bam_c
    
    output:
        tuple val(sampleName), path('consensus.fa') into consensus_fa
    
    conda "$projectDir/conda/env-bcftools"
    
    shell:
    """
        bcftools mpileup -d 10000 -Ou -f $params.referenceSequence resorted.bam | bcftools call --ploidy 1 -mv -Oz -o calls.vcf.gz
        bcftools index calls.vcf.gz
        cat $params.referenceSequence | bcftools consensus calls.vcf.gz > consensus.fa
    """
}



// Characterisation of the consensus sequence based on Pangolin output
// Calculation of the consensus sequence is used to determine the predominant lineage.
process pangolinVariantCaller {
    input:
        tuple val(sampleName), path('consensus.fa') from consensus_fa
    
    output:
        tuple val(sampleName), env(consensusLineage), path('lineage_report.csv'), path('consensus.fa') into pangolin_out
    
    conda "$projectDir/conda/env-pangolin"
    
    shell:
    """
        pangolin --alignment consensus.fa --threads 2 --outdir ./
        
        # Check the pangolin result to ensure the failure cases are handled properly
        # In non-convergence case, it either throws multiple options or throws "None"
        consensusLineage=\$(tail -n 1 lineage_report.csv | awk -F "," '{ print \$3 }')
        if [[ \$(echo \$consensusLineage | wc -w) -lt 1 || \$consensusLineage == "None" ]]; then
            consensusLineage=Unknown
        fi
    """
}



process linearDeconVariantCaller {
    input:
        tuple val(sampleName), path('rawVarCalls.tsv') from ivar_out
    
    output:
        tuple val(sampleName), path('linearDeconvolution_abundance.csv'), path('mutationTable.html'), path('VOC-VOIsupportTable.html'), path('mutationTable.csv'), env(mostAbundantVariantPct), env(mostAbundantVariantName), env(linRegressionR2) into linearDeconvolution_out

    conda "$projectDir/conda/env-python"
        
    shell:
    """
        deconvolutionOutput=\$($projectDir/deconvolveVariants.py rawVarCalls.tsv ./ $params.variantDBfile)
        
        mostAbundantVariantPct=\$(echo \$deconvolutionOutput | awk '{ print \$1 }')
        mostAbundantVariantName=\$(echo \$deconvolutionOutput |awk '{ print \$2 }')
        linRegressionR2=\$(echo \$deconvolutionOutput | awk '{ print \$3 }')
    """
}


process kallistoVariantCaller {
    input:
        tuple val(sampleName), env(numReads), path('resorted.fastq.gz') from resorted_fastq_gz_b

    output:
        tuple val(sampleName), path('abundance.tsv') into kallisto_out
        
    conda "$projectDir/conda/env-kallisto"
        
    shell:
    """
        # Check the number of reads. Ignore if there are too few reads
        if [[ $task.attempt -lt 2 ]] && [[ \$numReads -gt 10 ]]; then
            kallisto quant --index $projectDir/customDBs/variants.kalIdx --output-dir ./ \
                    --plaintext --threads 2 --single -l 300 -s 50 resorted.fastq.gz
        else
            echo target_id\$'\t'length\$'\t'eff_length\$'\t'est_counts tpm > abundance.tsv
            echo Error\$'\t'29903\$'\t'29903\$'\t'100\$'\t'100 >> abundance.tsv
        fi
    """
}



/////////////////////////////////REMOVE
//process freyjaVariantCaller {
//    memory {2.GB * task.attempt }
//    label 'high_cpu'
//
//    input:
//        tuple val(sampleName), env(numReads), path('resorted.bam') from resorted_bam_d
//        
//    output:
//        tuple val(sampleName), path('freyja.demix'), path('freyja_boot_lineages.csv'), path('freyja_bootstrap.png') into freyja_out
//
//    conda "$projectDir/conda/env-freyja"
//
//    shell:
//    """
//        if [[ \$numReads -lt 100 ]]; then
//            echo INSUFFICIENT DATA > freyja.demix
//            echo summarized\$'\t'"[('Undetermined', 1.00)]" >> freyja.demix
//            echo lineages\$'\t'Undetermined >> freyja.demix
//            echo abundances\$'\t'1.00 >> freyja.demix
//            echo resid\$'\t'-1 >> freyja.demix
//            echo coverage\$'\t'-1 >> freyja.demix
//            
//            echo "Undetermined" > freyja_boot_lineages.csv 
//            touch freyja_bootstrap.png
//        else 
//            if [[ $task.attempt -lt 4 ]]; then
//                echo Pileup generation for Freyja...
//                freyja variants resorted.bam --variants freyja.variants.tsv --depths freyja.depths.tsv --ref $params.referenceSequence
//                
//                echo Demixing variants by Freyja and bootstrapping
//                freyja demix freyja.variants.tsv freyja.depths.tsv --output freyja.demix --confirmedonly &
//                freyja boot freyja.variants.tsv freyja.depths.tsv --nt \$(nproc) --nb 1000 --output_base freyja_boot
//                wait
//                
//                echo Parsing bootstrapping output...
//                export PYTHONHASHSEED=0
//                python3 $projectDir/parseFreyjaBootstraps.py freyja.demix freyja_boot_lineages.csv freyja_bootstrap.png
//            else
//                # Due to a potential bug, some big fastqs result in a pandas error.
//                # Generate an empty file to circumvent such failure cases
//                echo FATAL ERROR > freyja.demix
//                echo summarized\$'\t'"[('Error', 1.00)]" >> freyja.demix
//                echo lineages\$'\t'Error >> freyja.demix
//                echo abundances\$'\t'1.00 >> freyja.demix
//                echo resid\$'\t'-1 >> freyja.demix
//                echo coverage\$'\t'-1 >> freyja.demix
//                
//                echo "ERROR" > freyja_boot_lineages.csv 
//                touch freyja_bootstrap.png
//            fi
//        fi
//    """
//}


// A metadata fetch attemp from NCBI via Entrez-Direct
// Only works if file names explicitly carries an SRR number.
process getNCBImetadata {
    // Allow access to this section only 1 thread at a time to avoid network congestion.
    executor = 'local'
    // queueSize = 1
    maxForks 1
    submitRateLimit = '3/1min'
    
    // NCBI bandwidth limit might cause lookup failures. If so, the next attempt should start with a time delay.
    // Wait some random time so that threads go out of sync.
    errorStrategy { sleep(1000 * Math.random() as long); return 'retry' }
    maxRetries = 105
    
    input:
        tuple val(sampleName), file('R1.fastq.gz'), file('R2.fastq.gz') from input_fq_c
        
    output:
        tuple val(sampleName), env(libraryProtocol), env(seqInstrument), env(isolate), env(collectionDate), env(collectedBy), env(sequencedBy), env(sampleLatitude), env(sampleLongitude), env(sampleLocation) into metadata
    
    conda "$projectDir/conda/env-entrez-direct"
    
    shell:
    """
    srrNumber=$sampleName
    if [[ $task.attempt -lt 100 ]] && [[ \${srrNumber:0:3} == 'SRR' ]]; then
        # The tool returns error: too many requests, bypassing by redirection of error		
        sraQueryResult=\$(esearch -db sra -query \$srrNumber 2>/dev/null)
        sleep 1
        
        if echo \$sraQueryResult | grep -q "<Count>1</Count>"; then
            # Get runinfo from SRA
            echo Downloading metadata for \$srrNumber...	
            SRRmetadata=\$(echo "\$sraQueryResult" | efetch -format runinfo 2>/dev/null | grep \$srrNumber)
            
            echo Parsing...
            libraryProtocol=\$(echo \$SRRmetadata | awk -F ',' '{print \$13}')
            seqInstrument=\$(echo \$SRRmetadata | awk -F ',' '{print \$20}')
            isolate=\$(echo \$SRRmetadata  | awk -F ',' '{print \$30}')	
            
            # Get metadata out of biosample db
            echo Fetching biosample data...
            SAMN=\$(echo \$SRRmetadata | awk -F ',' '{print \$26}')
            SAMNmetadata=\$(efetch -db biosample -id \$SAMN 2>/dev/null)
            
            echo Parsing...
            collectionDate=\$(echo "\$SAMNmetadata" | grep "collection date" | awk -F '"' '{print \$2}')
            collectedBy=\$(echo "\$SAMNmetadata" | grep "collected by" | awk -F '"' '{print \$2}')
            sequencedBy=\$(echo "\$SAMNmetadata" | grep SEQUENCED_BY | awk '{ \$1=""; print \$0 }')
            sampleLatitude=\$(echo "\$SAMNmetadata" | grep "latitude and longitude" | awk -F '"' '{print \$2}'\
                                | awk '{ print \$1\$2 }')
            sampleLongitude=\$(echo "\$SAMNmetadata" | grep "latitude and longitude" | awk -F '"' '{print \$2}'\
                                | awk '{ print \$3\$4 }')
            sampleLocation=\$(echo "\$SAMNmetadata" | grep "geographic location" | awk -F '"' '{print \$2}')
        fi
    fi
    
    if [[ -z \$SAMN ]]; then
        SAMN=Missing
    fi

    if [[ -z \$libraryProtocol ]]; then
        libraryProtocol=Missing
    fi

    if [[ -z \$seqInstrument ]]; then
        seqInstrument=Missing
    fi

    if [[ -z \$isolate ]]; then
        isolate=Missing
    fi

    if [[ -z \$collectionDate ]]; then
        collectionDate=Missing
    fi

    if [[ -z \$collectedBy ]]; then
        collectedBy=Missing
    fi

    if [[ -z \$sequencedBy ]]; then
        sequencedBy=Missing
    fi

    if [[ -z \$sampleLatitude ]]; then
        sampleLatitude="?"
    fi

    if [[ -z \$sampleLongitude ]]; then
        sampleLongitude="?"
    fi

    if [[ -z \$sampleLocation ]]; then
        sampleLocation=Missing
    fi
    """
}


/////////////////////////////////REMOVE
//// Computation is now mostly over. All threads need to synchronise here.
//// We will group based on the sample name and pass everything to the report
//// generation steps.
//reportInputCh = metadata.join(samtools_stats).join(k2_std_out).join(QChists)
//                        .join(readLengthHist_out).join(linearDeconvolution_out)
//                        .join(k2_covid_out).join(pangolin_out).join(kallisto_out)
//                        .join(freyja_out)
//
//
//
/////////////////////////////////////////////////
//// Report generation and final output
/////////////////////////////////////////////////
//
//// Generates a report based on the computation results generated by executeAnalysis.sh
//// One separate html report per each sample (i.e. per fastq/fastq pair)
//process generateReport {
//    input:
//        tuple val(sampleName), env(libraryProtocol), env(seqInstrument), env(isolate), env(collectionDate), env(collectedBy), env(sequencedBy), env(sampleLatitude), env(sampleLongitude), env(sampleLocation),
//        path('sorted.stats'), path('resorted.stats'), path('primer_hit_counts.tsv'),
//        path('k2-std.out'),
//        path('pos-coverage-quality.tsv'), path('coverage.png'), path('depthHistogram.png'), path('quality.png'), path('qualityHistogram.png'), path('discontinuitySignal.png'), path('genesVSuncovered_abscounts.png'), path('genesVSuncovered_scaled.png'), path('absCounts.csv'), path('scaledCounts.csv'), path('breadthVcov.csv'), path('breadthVSdepth.png'),
//        path('readLengthHist.png'), path('timeVSreadcounts.png'),
//        path('linearDeconvolution_abundance.csv'), path('mutationTable.html'), path('VOC-VOIsupportTable.html'), path('mutationTable.csv'), env(mostAbundantVariantPct), env(mostAbundantVariantName), env(linRegressionR2),
//        path('k2-majorCovid_bracken.out'), path('k2-majorCovid.out'),
//        env(consensusLineage), path('lineage_report.csv'), path('consensus.fa'),
//        path('kallisto_abundance.tsv'),
//        path('freyja.demix'), path('freyja_boot_lineages.csv'), path('freyja_bootstrap.png') from reportInputCh
//    
//    output:
//        file "outfolder" into reportCh
//        
//    conda "$projectDir/conda/env-python"
//    
//    shell:
//    """
//        echo Making pie charts...
//        export PYTHONHASHSEED=0
//        $projectDir/plotPieChartsforAbundance.py ./ $params.variantDBfile linearDeconvolution_abundance.csv kallisto_abundance.tsv k2-majorCovid_bracken.out freyja.demix
//        
//        export kallistoTopName=\$(cat kallisto.out | sort -k 2 -n | tail -n 1 | awk '{ print \$1 }')
//        
//        echo generating report.html...
//        $projectDir/generateReport.sh $sampleName $projectDir/htmlHeader.html $isPairedEnd $primerBedFile $projectDir
//    """
//}
//
//
//
//// The below process runs once per folder and generates a concise summary of all samples after all other
//// executions are over.
//process summaryPage {
//    input:
//        file 'report' from reportCh.collect()
//    
//    output:
//        file "analysisResults" into results_with_summary
//
//    conda "$projectDir/conda/env-python"
//    
//    shell:
//    """
//        $projectDir/generateSummary.sh $projectDir/htmlHeader.html $params.variantDBfile $projectDir
//    """
//}
//
//
//
//// OPTIONAL: convert html reports into pdf and then generate a combined pdf of all results.
//// Useful if need to share the result with external collaborators
//process html2pdf {
//    input:
//        file "analysisResults" from results_with_summary
//    
//    output:
//        file "analysisResults" into analysisResults
//
//    conda "$projectDir/conda/env-gs-wkhtmltopdf"
//    label 'high_cpu'
//    publishDir "$params.out", mode: 'copy', overwrite: true	
//    
//    shell:
//    if (params.make_pdfs) {
//    """
//        echo Generating report.pdf...
//        cd analysisResults
//        for sampleName in \$(ls */ -d | tr -d '/'); do
//            awk '1; /Detected mutations/{exit}' \$sampleName/\${sampleName}_report/report.html > \$sampleName/\${sampleName}_report/temp.html
//            echo "Excluded from this pdf version due to file size limitations." >> \$sampleName/\${sampleName}_report/temp.html
//            echo "<br>"\$'\n'"</body>"\$'\n'"</html>" >> \$sampleName/\${sampleName}_report/temp.html
//            
//            wkhtmltopdf --enable-local-file-access --page-size Letter --margin-top 10mm --margin-bottom 0 --margin-left 0 \
//                --margin-right 0 --print-media-type --title "Wastewater report" \$sampleName/\${sampleName}_report/temp.html \
//                \$sampleName/\${sampleName}_report/report.pdf &
//        done
//        
//        echo Generating summary.pdf...
//        wkhtmltopdf --enable-local-file-access --page-size Letter --margin-top 10mm --margin-bottom 0 \
//            --margin-left 0 --margin-right 0 --print-media-type --title "Wastewater report" summary.html summary.pdf &
//        
//        echo Waiting for the conversion processes to complete
//        wait
//        rm ./*/*/temp.html
//        
//        echo Merging PDFs...
//        gs -dNOPAUSE -dQUIET -dBATCH -sDEVICE=pdfwrite -dPreserveAnnots=false -sOUTPUTFILE=./consolidated.pdf ./summary.pdf ./*/*report/report.pdf
//    """
//    }
//    else {
//    """
//        echo make_pdfs was set to false, so skipped the pdf generation.
//    """
//    }
//}
//
//
//analysisResults.subscribe onComplete: {
//    println('Pipeline execution complete. Thank you for choosing C-WAP')
//}
