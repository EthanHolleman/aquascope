/*
========================================================================================
    VALIDATE INPUTS
========================================================================================
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)


// Validate input parameters
WorkflowAquascope.initialise(params, log)

// TODO nf-core: Add all file path parameters for the pipeline to the list below
// Check input path parameters to see if they exist

def checkPathParamList = [ params.input, params.fasta, params.bedfile, params.freyja_barcodes, params.freyja_lineages_meta]

for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

// Check mandatory parameters

if (params.input) { ch_input = file(params.input) } else { exit 1, 'Input samplesheet not specified!' }

/*
========================================================================================
    CONFIG FILES
========================================================================================
*/

ch_multiqc_config        = file("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config) : Channel.empty()

/*
========================================================================================
    IMPORT MODULES/SUBWORKFLOWS
========================================================================================
*/

//
// SUBWORKFLOWS
//
include { INPUT_CHECK                           } from '../subworkflows/local/input_check'
include { TRIMMING   as IVAR_TRIMMING_SORTING   } from '../subworkflows/local/trimming.nf'
include { FREYJA_VARIANT_CALLING                } from '../subworkflows/local/bam_variant_demix_boot_freyja/main'
include { PANGOLIN_VARIANTESTIMATION            } from '../subworkflows/local/pangolin_variantestimation/main'

//
// MODULES
//
include { SAMTOOLS_FAIDX                        } from '../modules/local/samtools/faidx/main'
include { FASTQC     as FASTQC_RAW              } from '../modules/nf-core/modules/nf-core/fastqc/main'
include { FASTP                                 } from '../modules/nf-core/modules/nf-core/fastp/main'
include { FASTQC     as FASTQC_TRIMMED          } from '../modules/nf-core/modules/nf-core/fastqc/main'
include { MINIMAP2_ALIGN                        } from '../modules/nf-core/modules/nf-core/minimap2/align/main'
include { KRAKEN2_DB_PREPARATION                } from '../modules/local/kraken2_db_preparation'
include { KRAKEN2_KRAKEN2 as KRAKEN2            } from '../modules/nf-core/modules/nf-core/kraken2/kraken2/main'
include { IVAR_VARIANTS                         } from '../modules/nf-core/modules/nf-core/ivar/variants/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS           } from '../modules/nf-core/modules/nf-core/custom/dumpsoftwareversions/main'
// Include Pangolin DB BASED VC module ?
include { MULTIQC                               } from '../modules/nf-core/modules/nf-core/multiqc/main'


/*
========================================================================================
    RUN MAIN WORKFLOW
========================================================================================
*/

// Info required for completion email and summary

def multiqc_report = []
ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

workflow AQUASCOPE {

    // Initialize empty channels and set value channels from params
    ch_versions             = Channel.empty()
    ch_input                = file("${params.input}")
    ch_reads                = Channel.empty()
    ch_reads_minimap        = Channel.empty()
    ch_genome_fai           = Channel.empty()

    ch_genome               = params.fasta                ? Channel.value(file( "${params.fasta}" ))                : Channel.empty()        
    ch_kraken2db            = params.kraken2db            ? Channel.value(file( "${params.kraken2db}" ))            : Channel.empty()
    ch_bedfile              = params.bedfile              ? Channel.value(file( "${params.bedfile}" ))              : Channel.empty()
    
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    INPUT_CHECK (
        ch_input
    )
    ch_reads            = INPUT_CHECK.out.reads
    ch_versions         = ch_versions.mix(INPUT_CHECK.out.versions)

    
    // MODULE: Create Fasta Index file using samtools faidx
    SAMTOOLS_FAIDX (
        ch_genome 
    )
    ch_genome_fai       = SAMTOOLS_FAIDX.out.fai
    ch_versions         = ch_versions.mix(SAMTOOLS_FAIDX.out.versions)

    
    // MODULE: FastQC on raw data for initial quality checking
    FASTQC_RAW (
        ch_reads
    )
    ch_versions = ch_versions.mix(FASTQC_RAW.out.versions.first())

    // MODULE: Run FastP 
    ch_trimmed_reads = Channel.empty()
     FASTP (
        ch_reads, [], false, false
    )
    ch_trimmed_reads = ch_trimmed_reads.mix(FASTP.out.reads)
    //ch_reads_for_fastqc = ch_trimmed_reads
    ch_versions      = ch_versions.mix(FASTP.out.versions.first())

    // MODULE: FastQC for final quality checking
    FASTQC_TRIMMED (
        ch_trimmed_reads
    )
    ch_versions = ch_versions.mix(FASTQC_TRIMMED.out.versions.first())

    if(params.kraken2 != false){

    // MODULE: Stage the desired Kraken2 database (this is custom module)
    KRAKEN2_DB_PREPARATION (
        ch_kraken2db
    )
    
    // MODULE: Classify trimmed reads with Kraken2
    ch_kraken_report = Channel.empty()
    KRAKEN2 (
        ch_trimmed_reads, KRAKEN2_DB_PREPARATION.out.db, "", ""
    )
    ch_kraken_report        = ch_kraken_report.mix(KRAKEN2.out.report)
    ch_versions             = ch_versions.mix(KRAKEN2.out.versions.first())

    }

    // 
    // MODULE: Align reads against reference genome
    //

    ch_align_bam = Channel.empty()
    ch_align_bai = Channel.empty()
    MINIMAP2_ALIGN (
        ch_reads, ch_genome, true, false, false 
    )
    ch_align_bam            = MINIMAP2_ALIGN.out.bam
    ch_versions             = ch_versions.mix(MINIMAP2_ALIGN.out.versions.first())
    
    // 
    // MODULE: RUN IVAR_TRIM_SORT
    //

    ch_sort_bam = Channel.empty()
    ch_sort_bai = Channel.empty()
    IVAR_TRIMMING_SORTING(
        ch_align_bam
    )
    ch_sort_bam = ch_sort_bam.mix(IVAR_TRIMMING_SORTING.out.bam)
    ch_versions = ch_versions.mix(IVAR_TRIMMING_SORTING.out.versions)

    // 
    // MODULE: Identify variants with iVar
    //

    ch_ivar_vcf = Channel.empty()
    IVAR_VARIANTS(
        ch_sort_bam, 
        ch_genome,          // Assuming the reference and this are the same 
        ch_genome_fai,
        params.gff, 
        params.save_mpileup // default is false, change it to true in nextflow.config file
    )
    ch_ivar_vcf     = IVAR_VARIANTS.out.tsv
    ch_ivar_mpileup = IVAR_VARIANTS.out.mpileup
    ch_versions = ch_versions.mix(IVAR_VARIANTS.out.versions.first())


    //
    // MODULE: PANGOLIN_VARIANT_ESTIMATION
    //
    if(params.pangolin != false){
        ch_pangolin_csv = Channel.empty()
        PANGOLIN_VARIANTESTIMATION(
            ch_sort_bam,
            ch_genome
        )
        ch_pangolin_csv     = PANGOLIN_VARIANTESTIMATION.out.report
        ch_pangolin_stats   = PANGOLIN_VARIANTESTIMATION.out.stats
        ch_versions = ch_versions.mix(PANGOLIN_VARIANTESTIMATION.out.versions)
    }

    // 
    // MODULE: RUN FREYJA_VARIANT_CALLING
    //
    ch_freyja_variants      = Channel.empty()
    ch_freyja_depths        = Channel.empty()
    ch_freyja_demix         = Channel.empty()
    ch_freyja_lineages      = Channel.empty()
    ch_freyja_summarized    = Channel.empty()
    FREYJA_VARIANT_CALLING(
        ch_sort_bam, 
        ch_genome,
        params.freyja_repeats,
        params.freyja_db_name,
        params.freyja_barcodes,
        params.freyja_lineages_meta
    )
    ch_freyja_variants      = FREYJA_VARIANT_CALLING.out.variants
    ch_freyja_depths        = FREYJA_VARIANT_CALLING.out.depths
    ch_freyja_demix         = FREYJA_VARIANT_CALLING.out.demix
    ch_freyja_lineages      = FREYJA_VARIANT_CALLING.out.lineages
    ch_freyja_summarized    = FREYJA_VARIANT_CALLING.out.summarized
    ch_versions             = ch_versions.mix(FREYJA_VARIANT_CALLING.out.versions)

    // MODULE: Pipeline reporting
    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    // MODULE: MultiQC
    workflow_summary    = WorkflowAquascope.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)
    methods_description    = WorkflowAquascope.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC_RAW.out.zip.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(FASTP.out.json.collect{it[1]}.ifEmpty([]))
    if(params.pangolin != false){
    ch_multiqc_files = ch_multiqc_files.mix(ch_pangolin_csv.collect{it[1]}.ifEmpty([]))
    }
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC_TRIMMED.out.zip.collect{it[1]}.ifEmpty([]))
    if(params.kraken2 != false){
    ch_multiqc_files = ch_multiqc_files.mix(ch_kraken_report.collect{it[1]}.ifEmpty([]))
    }

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report       = MULTIQC.out.report.toList()
}

/*
========================================================================================
    COMPLETION EMAIL AND SUMMARY
========================================================================================
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}
/*
========================================================================================
    THE END
========================================================================================
*/
