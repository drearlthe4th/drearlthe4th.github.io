/*=============================================================================
  DD_99_DRIVER.SAS  --  EDIT THIS FILE, RUN IT, READ THE WORKBOOK.

  Everything above this file is generic. This is where you say what your
  libraries are called and which variable plays which role.
=============================================================================*/

/*---------------------------------------------------------------------------
  STEP 0.  Load the program.
---------------------------------------------------------------------------*/
%let DDPATH = /workspace/sas;          /* <-- folder holding dd_0*.sas    */

%include "&DDPATH/dd_00_setup.sas";
%include "&DDPATH/dd_01_overview.sas";
%include "&DDPATH/dd_02_stats.sas";
%include "&DDPATH/dd_03_values.sas";
%include "&DDPATH/dd_04_graphics.sas";
%include "&DDPATH/dd_05_patient.sas";
%include "&DDPATH/dd_06_report.sas";

/* Override any global setting from dd_00_setup here */
%let DD_OUT       = /workspace/output/datadict;   /* <-- must already exist */
%let DD_PROJECT   = medicare_memory;
%let DD_MINCELL   = 11;      /* CMS DUA minimum cell size                   */
%let DD_MAXLEVELS = 500;     /* raise for NDC/ICD fields you want in full    */
%let DD_GRAPHS    = Y;

/*---------------------------------------------------------------------------
  STEP 1.  Point at the data.
---------------------------------------------------------------------------*/
libname MED   "/data/medicare"  access=readonly;   /* <-- EDIT */
libname MEM   "/data/memory"    access=readonly;   /* <-- EDIT */

/* Optional: profile a whole library without naming the tables.
   proc sql noprint;
     select memname into :MEDTABLES separated by ' '
     from dictionary.tables where libname='MED' and memtype='DATA';
   quit;
*/

/*---------------------------------------------------------------------------
  STEP 2.  Clear prior results so a re-run does not append to itself.
---------------------------------------------------------------------------*/
proc datasets library=work nolist nowarn;
  delete dd_tables dd_columns dd_missing dd_numstats dd_outliers
         dd_cardinality dd_values dd_levelcount dd_corrpairs dd_dates
         dd_patient_summary dd_patient_meta dd_linkage dd_duplicates
         dd_dictionary;
quit;

/*---------------------------------------------------------------------------
  STEP 3.  Profile each dataset.

  %dd_profile parameters
  ----------------------
    lib=      mem=        library and dataset
    id=       person key. Enables every patient-level rollup. On CMS files
              this is BENE_ID; on the memory data it is whatever the study ID
              is called. Confirm the name in the dictionary before assuming.
    claimid=  claim key -> claims per person
    drugvar=  product/procedure code -> distinct products per person
    datevar=  service or assessment date -> dates per person, follow-up span
    sumvars=  numeric variables to total per person (payments, days supply,
              scores). Space separated.
    catvars=  categorical variables to cross against target= and to count
              distinct levels per person
    target=   a numeric outcome for the bivariate panels (cognitive score,
              total spend). Leave blank to skip those panels.
    key=      the key you intend to MERGE on -> uniqueness check
    force=    variables to enumerate value-by-value even though the
              cardinality screen rejected them (e.g. an NDC or ICD field you
              genuinely want in full). Space separated.
    plotvars= restrict the plots to these numeric variables. Leave blank to
              let the program pick.
    logscale= Y adds a log10 histogram page. Leave Y for money and counts.
---------------------------------------------------------------------------*/

/*----- MEDICARE -----------------------------------------------------------*/
/*  EDIT the variable names below. They are placeholders, not lookups: this
    session had no access to the CoDES dictionary exports (mdd_*.csv), so no
    variable name in this file has been verified against your extract.
    Run STEP 3a first, read sheet "1 Dictionary", then fill these in.        */

/* STEP 3a -- structure only, no assumptions, always safe to run first */
%dd_profile(lib=MED, mem=YOUR_CLAIMS_TABLE, graphs=N);

/* STEP 3b -- the full battery, once you know the names */
/*
%dd_profile(lib=MED, mem=YOUR_CLAIMS_TABLE,
            id       = BENE_ID,
            claimid  = CLM_ID,
            drugvar  = ,
            datevar  = CLM_FROM_DT,
            sumvars  = ,
            catvars  = ,
            target   = ,
            key      = BENE_ID CLM_ID,
            force    = ,
            logscale = Y);
*/

/*----- MEMORY / COGNITIVE -------------------------------------------------*/
%dd_profile(lib=MEM, mem=YOUR_MEMORY_TABLE, graphs=N);

/*
%dd_profile(lib=MEM, mem=YOUR_MEMORY_TABLE,
            id       = STUDY_ID,
            datevar  = ASSESS_DT,
            sumvars  = ,
            catvars  = SEX RACE EDUC_CAT,
            target   = MEMORY_SCORE,
            key      = STUDY_ID ASSESS_DT,
            logscale = N);
*/

/*---------------------------------------------------------------------------
  STEP 4.  Can the two files actually be joined?
---------------------------------------------------------------------------*/
/*
%dd_link(liba=MED, mema=YOUR_CLAIMS_TABLE, ida=BENE_ID,
         libb=MEM, memb=YOUR_MEMORY_TABLE, idb=BENE_ID);
*/

/*---------------------------------------------------------------------------
  STEP 5.  Assemble and export.
---------------------------------------------------------------------------*/
%dd_assemble;

%dd_export(export=VM);      /* full detail. STAYS ON THE VM.               */
%dd_export(export=SHARE);   /* small cells suppressed. Safe to move.       */

/*---------------------------------------------------------------------------
  STEP 6.  Optional -- deeper patient-level questions.

  These are the questions the dictionary does not answer by itself. Uncomment
  the ones you want; each needs the real variable names.
---------------------------------------------------------------------------*/

/* 6a. Prescriptions and distinct drugs per beneficiary per year.
       A raw count per person is not comparable across people with different
       amounts of enrollment. Rate per person-year is.
%dd_patient(lib=MED, mem=YOUR_PDE_TABLE,
            id=BENE_ID, claimid=PDE_ID, drugvar=PROD_SRVC_ID,
            datevar=SRVC_DT, sumvars=DAYS_SUPLY_NUM TOT_RX_CST_AMT,
            ptout=pt_pde);

data pt_pde_rates;
  set pt_pde;
  person_years = max(followup_days,1)/365.25;
  fills_per_py    = n_records  / person_years;
  drugs_per_py    = n_products / person_years;
  spend_per_py    = sum_TOT_RX_CST_AMT / person_years;
  label fills_per_py='Fills per person-year';
run;
*/

/* 6b. Claims per beneficiary per year, from the enrollment file rather than
       from the claims themselves. The denominator belongs to the MBSF, not
       the claim file: a person with three months of coverage and two claims
       has a higher rate than a person with twelve months and six.
proc sql;
  create table pt_rate as
  select c.BENE_ID,
         count(*)                    as n_claims,
         sum(e.months_enrolled)/12   as person_years,
         calculated n_claims / max(calculated person_years,0.01) as claims_per_py
  from MED.YOUR_CLAIMS_TABLE c
       inner join MED.YOUR_MBSF e on c.BENE_ID=e.BENE_ID
  group by c.BENE_ID;
quit;
*/

/* 6c. Repeated measures in the memory data: how many assessments per person,
       how far apart, and who drops out.
proc sql;
  create table pt_visits as
  select STUDY_ID,
         count(*) as n_visits,
         min(ASSESS_DT) as first_visit format=date9.,
         max(ASSESS_DT) as last_visit  format=date9.,
         (max(ASSESS_DT)-min(ASSESS_DT))/365.25 as years_observed
  from MEM.YOUR_MEMORY_TABLE
  group by STUDY_ID;
quit;

title 'Visits per participant and attrition';
proc sgplot data=pt_visits;
  vbar n_visits / datalabel;
  xaxis label='Assessments per participant';
  yaxis label='Participants' grid;
run;
title;
*/
