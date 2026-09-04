/*=============================================================================
  DD_99_DRIVER_MEDICARE.SAS        VM 1 -- MEDICARE ONLY

  This VM holds Medicare and nothing else. There is no cannabis or Medicaid
  data here and no cross-VM linkage is possible or attempted. Run this file
  inside the Medicare enclave; its output stays in the Medicare enclave.

  EDIT THIS FILE. Everything it %includes is generic.
=============================================================================*/

/*---------------------------------------------------------------------------
  STEP 0.  Load the program.
---------------------------------------------------------------------------*/
%let DDPATH = /workspace/sas;               /* <-- folder holding dd_0*.sas */

%include "&DDPATH/dd_00_setup.sas";
%include "&DDPATH/dd_01_overview.sas";
%include "&DDPATH/dd_02_stats.sas";
%include "&DDPATH/dd_03_values.sas";
%include "&DDPATH/dd_04_graphics.sas";
%include "&DDPATH/dd_05_patient.sas";
%include "&DDPATH/dd_06_report.sas";
%include "&DDPATH/dd_07_longitudinal.sas";

%let DD_OUT       = /workspace/output/datadict;   /* <-- must already exist */
%let DD_PROJECT   = medicare;
%let DD_MINCELL   = 11;      /* CMS DUA minimum cell size                    */
%let DD_MAXLEVELS = 500;     /* raise for ICD/HCPCS fields you want in full   */
%let DD_GRAPHS    = Y;

libname MED "/data/medicare" access=readonly;     /* <-- EDIT */

/*---------------------------------------------------------------------------
  STEP 1.  Clear prior results so a re-run does not append to itself.
---------------------------------------------------------------------------*/
%macro dd_clear;
  proc datasets library=work nolist nowarn;
    delete dd_tables dd_columns dd_missing dd_numstats dd_outliers
           dd_cardinality dd_values dd_levelcount dd_corrpairs dd_dates
           dd_patient_summary dd_patient_meta dd_linkage dd_duplicates
           dd_calendar dd_interval_summary dd_dictionary;
  quit;
%mend dd_clear;
%dd_clear;

/*---------------------------------------------------------------------------
  STEP 2.  Structure first. This needs no knowledge of your variable names
           and is always safe to run. Read sheet "1 Dictionary" afterwards.
---------------------------------------------------------------------------*/
%dd_profile(lib=MED, mem=YOUR_CLAIMS_TABLE, graphs=N);   /* <-- EDIT name */
%dd_profile(lib=MED, mem=YOUR_MBSF_TABLE,   graphs=N);   /* <-- EDIT name */

/* Or sweep the whole library without naming anything:
proc sql noprint;
  select memname into :MEDTABLES separated by ' '
  from dictionary.tables where libname='MED' and memtype='DATA';
quit;
%macro dd_sweep(lib,list);
  %local i;
  %do i=1 %to %dd_n(&list);
    %dd_profile(lib=&lib, mem=%scan(&list,&i,%str( )), graphs=N);
  %end;
%mend dd_sweep;
%dd_sweep(MED,&MEDTABLES);
*/

/*---------------------------------------------------------------------------
  STEP 3.  The full battery, once the dictionary has told you the real names.

  NOTHING BELOW IS A LOOKUP. These are placeholders. This session had no
  access to the CoDES dictionary exports, so no variable name here has been
  verified against your extract. Confirm each one in sheet 1 before running.

  datefmt= matters: sheet "8 Dates" tells you whether a date variable is a
  real SAS date or an unformatted YYYYMMDD integer. Passing the wrong one
  produces a plausible, wrong answer with no error.
---------------------------------------------------------------------------*/
/*
%dd_profile(lib=MED, mem=YOUR_CLAIMS_TABLE,
            id       = BENE_ID,
            claimid  = CLM_ID,
            datevar  = CLM_FROM_DT,
            datefmt  = SAS,
            sumvars  = ,
            catvars  = ,
            target   = ,
            key      = BENE_ID CLM_ID,
            force    = ,
            interval = month,
            gapdays  = 90,
            logscale = Y);

%dd_profile(lib=MED, mem=YOUR_PDE_TABLE,
            id       = BENE_ID,
            claimid  = PDE_ID,
            drugvar  = PROD_SRVC_ID,
            datevar  = SRVC_DT,
            datefmt  = SAS,
            sumvars  = DAYS_SUPLY_NUM TOT_RX_CST_AMT,
            key      = PDE_ID,
            interval = month,
            gapdays  = 60,
            logscale = Y);
*/

/*---------------------------------------------------------------------------
  STEP 4.  Do two Medicare files in this VM join the way you think?
           (Both must be in this enclave. There is no cross-VM link.)
---------------------------------------------------------------------------*/
/*
%dd_link(liba=MED, mema=YOUR_CLAIMS_TABLE, ida=BENE_ID,
         libb=MED, memb=YOUR_MBSF_TABLE,   idb=BENE_ID);
*/

/*---------------------------------------------------------------------------
  STEP 5.  Assemble and export.
---------------------------------------------------------------------------*/
%dd_assemble;
%dd_export(export=VM);      /* full detail. STAYS IN THIS ENCLAVE.          */
%dd_export(export=SHARE);   /* cells < &DD_MINCELL suppressed.              */

/*---------------------------------------------------------------------------
  STEP 6.  Rates, with the right denominator.

  Fills per beneficiary is not comparable across people with different
  amounts of enrollment: three months and two fills is a HIGHER rate than
  twelve months and six. The denominator belongs to the MBSF, not the claim
  file. %DD_RATES will happily use the observed first-to-last span instead,
  and that is censored at both ends -- use it only when no eligibility file
  exists.
---------------------------------------------------------------------------*/
/*
proc sql;
  create table pt_denominator as
  select BENE_ID, sum(YOUR_ENROLLED_MONTHS_VAR) as enrolled_months
  from MED.YOUR_MBSF_TABLE
  group by BENE_ID;
quit;

data pt_pde_denom;
  merge dd_pt_YOUR_PDE_TABLE(in=a) pt_denominator(in=b);
  by BENE_ID;
  if a;
  enrolled_days = enrolled_months * 30.4375;
  if not b then enrolled_days = .;   * no enrollment record: do NOT impute ;
run;

%dd_rates(in=pt_pde_denom, out=pt_pde_rates,
          vars=n_records n_products sum_DAYS_SUPLY_NUM sum_TOT_RX_CST_AMT,
          spanvar=enrolled_days, per=365.25);
*/
