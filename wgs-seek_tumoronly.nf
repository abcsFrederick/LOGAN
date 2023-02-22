#!/usr/bin/env nextflow
nextflow.enable.dsl=2

date = new Date().format( 'yyyyMMdd' )


results_dir=params.output
fastqinput=Channel.fromFilePairs(params.input)
intervalbedin = Channel.fromPath(params.intervals,checkIfExists: true,type: 'file')
sample_sheet=Channel.fromPath(params.sample_sheet, checkIfExists: true)
                       .ifEmpty { exit 1, "sample sheet not found" }
                       .splitCsv(header:true, sep: "\t")
                       .map { row -> tuple(
                        row.Tumor,
                       row.Normal
                       )
                                  }
//Final Workflow
    include {fastp; bwamem2; indelrealign; bqsr; 
    gatherbqsr; applybqsr; samtoolsindex} from './workflow/modules/trim_align.nf'

    include {mutect2; mutect2_tonly; mutect2filter; mutect2filter_tonly; 
    pileup_paired_t; 
    contamination_tumoronly;
    learnreadorientationmodel_tonly; 
    mergemut2stats_tonly;
    annotvep_tonly} from './workflow/modules/variant_calling.nf'

    include {splitinterval} from "./workflow/modules/splitbed.nf"


workflow {

    fastqinput.view()
    fastp(fastqinput)
    splitinterval(intervalbedin)
    
    bwamem2(fastp.out)
    indelrealign(bwamem2.out)

    indelbambyinterval=indelrealign.out.combine(splitinterval.out.flatten())

    //TEMP LINE
    //indelbambyinterval.view()
    
    bqsr(indelbambyinterval)
    bqsrs=bqsr.out.groupTuple()
        .map { samplename,beds -> tuple( samplename, 
        beds.toSorted{ it -> (it.name =~ /${samplename}_(.*?).recal_data.grp/)[0][1].toInteger() } )
        }
    gatherbqsr(bqsrs)

    tobqsr=indelrealign.out.combine(gatherbqsr.out,by:0)
    applybqsr(tobqsr) 
    samtoolsindex(applybqsr.out)
    
    bamwithsample=samtoolsindex.out.join(sample_sheet).map{it.swap(3,0)}.join(samtoolsindex.out).map{it.swap(3,0)}
    bambyinterval=bamwithsample.combine(splitinterval.out.flatten())


    //Tumor Only Calling
    pileup_paired_t(bambyinterval)
    pileup_paired_tout=pileup_paired_t.out.groupTuple()
    .map{samplename,pileups-> tuple( samplename,
    pileups.toSorted{ it -> (it.name =~ /${samplename}_(.*?).tumor.pileup.table/)[0][1].toInteger() } ,
    )}

    mutect2_tonly(bambyinterval)    
    
    //LOR     
    mut2tout_lor=mutect2_tonly.out.groupTuple()
    .map { samplename,vcfs,f1r2,stats -> tuple( samplename,
    f1r2.toSorted{ it -> (it.name =~ /${samplename}_(.*?).f1r2.tar.gz/)[0][1].toInteger() } 
    )}
    learnreadorientationmodel_tonly(mut2tout_lor)


    //Stats
    mut2tonly_mstats=mutect2_tonly.out.groupTuple()
    .map { samplename,vcfs,f1r2,stats -> tuple( samplename,
    stats.toSorted{ it -> (it.name =~ /${samplename}_(.*?).tonly.mut2.vcf.gz.stats/)[0][1].toInteger() } 
    )}
    mergemut2stats_tonly(mut2tonly_mstats)


    //Contamination
    contamination_tumoronly(pileup_paired_tout)

    
    //Final TUMOR ONLY FILTER
    allmut2tonly=mutect2_tonly.out.groupTuple()
    .map { samplename,vcfs,f1r2,stats -> tuple( samplename,
    vcfs.toSorted{ it -> (it.name =~ /${samplename}_(.*?).tonly.mut2.vcf.gz/)[0][1].toInteger() } 
    )}
    
    mut2tonly_filter=allmut2tonly
    .join(mergemut2stats_tonly.out)
    .join(learnreadorientationmodel_tonly.out)
    .join(contamination_tumoronly.out)

    mutect2filter_tonly(mut2tonly_filter)


        
    
    //#To implement
    //CNMOPs from the BAM BQSRs
    //##VCF2MAF TO


   annotvep_tonly(mutect2filter_tonly.out)

}

