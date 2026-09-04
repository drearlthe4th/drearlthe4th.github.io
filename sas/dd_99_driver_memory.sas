/*=============================================================================
  DD_99_DRIVER_MEMORY.SAS     VM 2 -- MEMORY (MEDICAL CANNABIS) + MEDICAID

  This VM holds the MEMORY medical cannabis dispensing data and Medicaid.
  There is no Medicare here and no cross-VM linkage is possible or attempted.
  Run this file inside this enclave; its output stays in this enclave.

  MEMORY <-> Medicaid, on the other hand, is a real and answerable question,
  and STEP 4 is where you ask it.

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
%let DD_PROJECT   = memory_medicaid;

/*  CONFIRM THIS NUMBER. 11 is the CMS minimum and it is the right default
    for the Medicaid files. The cannabis registry data is governed by a
    different agreement and may require a different (often stricter)
    threshold, and a registry population is small enough that a permissive
    threshold is genuinely re-identifying. Check both DUAs and set this to
    the stricter of the two, since one workbook covers both.                */
%let DD_MINCELL   = 11;

/*  Cannabis dispensing files are code-heavy: product names, forms, strains,
    qualifying conditions. Raise the ceiling so those are catalogued in full
    rather than skipped as high-cardinality.                                */
%let DD_MAXLEVELS = 2000;
%let DD_GRAPHS    = Y;

libname MEMORY "/data/memory"   access=readonly;  /* <-- EDIT: cannabis     */
libname MCAID  "/data/medicaid" access=readonly;  /* <-- EDIT: Medicaid     */

/*---------------------------------------------------------------------------
  STEP 1.  Clear prior results so a re-run does not append to itself.
---------------------------------------------------------------------------*/
proc datasets library=work nolist nowarn;
  delete dd_tables dd_columns dd_missing dd_numstats dd_outliers
         dd_cardinality dd_values dd_levelcount dd_corrpairs dd_dates
         dd_patient_summary dd_patient_meta dd_linkage dd_duplicates
         dd_calendar dd_interval_summary dd_dictionary;
quit;

/*---------------------------------------------------------------------------
  STEP 2.  Structure first. Needs no knowledge of your variable names.
           Read sheet "1 Dictionary" afterwards, then fill in STEP 3.
---------------------------------------------------------------------------*/
%dd_profile(lib=MEMORY, mem=YOUR_DISPENSING_TABLE, graphs=N);  /* <-- EDIT */
%dd_profile(lib=MEMORY, mem=YOUR_PATIENT_TABLE,    graphs=N);  /* <-- EDIT */
%dd_profile(lib=MCAID,  mem=YOUR_MEDICAID_CLAIMS,  graphs=N);  /* <-- EDIT */
%dd_profile(lib=MCAID,  mem=YOUR_MEDICAID_ELIG,    graphs=N);  /* <-- EDIT */

/*---------------------------------------------------------------------------
  STEP 3.  The full battery.

  NOTHING BELOW IS A LOOKUP -- these are placeholders. Confirm every name in
  sheet 1 first, and check sheet "8 Dates" for whether each date variable is
  a real SAS date or an unformatted YYYYMMDD integer before setting datefmt=.

  ROLE MAPPING FOR DISPENSING DATA
  --------------------------------
    id=       the registry patient identifier (one row per dispensation, many
              rows per patient -- confirm this in sheet "11 Linkage and keys"
              with key=, do not assume it)
    claimid=  the transaction / dispensation identifier, if there is one
    drugvar=  the product identifier. Whichever level you pick is the level
              your "distinct products per patient" number is about: product
              name, product form, and strain are three different questions
              and will give three different answers.
    datevar=  the dispensation date
    sumvars=  the quantity and potency columns -- grams/units dispensed,
              THC mg, CBD mg, price paid. These are what make per-patient
              totals meaningful.
    catvars=  product form, qualifying condition, dispensary, county
    gapdays=  what counts as a break in continuous use. 90 is a starting
              point; set it from your typical supply length, which the
              interval histogram will show you.
---------------------------------------------------------------------------*/
/*
%dd_profile(lib=MEMORY, mem=YOUR_DISPENSING_TABLE,
            id       = PATIENT_ID,
            claimid  = TRANSACTION_ID,
            drugvar  = PRODUCT_NAME,
            datevar  = DISPENSE_DT,
            datefmt  = SAS,
            sumvars  = QUANTITY THC_MG CBD_MG PRICE_PAID,
            catvars  = PRODUCT_FORM QUALIFYING_CONDITION DISPENSARY_COUNTY,
            target   = THC_MG,
            key      = TRANSACTION_ID,
            interval = month,
            gapdays  = 90,
            logscale = Y);

%dd_profile(lib=MCAID, mem=YOUR_MEDICAID_CLAIMS,
            id       = MSIS_ID,
            claimid  = CLAIM_ID,
            datevar  = SRVC_BGN_DT,
            datefmt  = SAS,
            key      = CLAIM_ID,
            interval = month,
            logscale = Y);
*/

/*---------------------------------------------------------------------------
  STEP 4.  Does MEMORY join to Medicaid? Both are in THIS VM, so this is a
           real question rather than a prohibited one.

  Read the result carefully. The unlinked share is not noise: registry
  patients who pay cash or carry commercial insurance have no Medicaid
  record at all, so the linked subset is a SELECTED population, not a
  sample of registry patients. Whatever that percentage is, it belongs in
  the limitations paragraph of anything you write.

  If the two files carry different identifier systems, %DD_LINK will report
  0% overlap. That is a finding about the identifiers, not about the people,
  and it means you need the crosswalk before going further.
---------------------------------------------------------------------------*/
/*
%dd_link(liba=MEMORY, mema=YOUR_DISPENSING_TABLE, ida=PATIENT_ID,
         libb=MCAID,  memb=YOUR_MEDICAID_ELIG,    idb=MSIS_ID);
*/

/*---------------------------------------------------------------------------
  STEP 5.  Assemble and export.
---------------------------------------------------------------------------*/
%dd_assemble;
%dd_export(export=VM);      /* full detail. STAYS IN THIS ENCLAVE.          */
%dd_export(export=SHARE);   /* cells < &DD_MINCELL suppressed.              */

/*---------------------------------------------------------------------------
  STEP 6.  Patient-level questions specific to dispensing data.
---------------------------------------------------------------------------*/

/* 6a. Per-patient dispensing rates.
       Raw counts per patient are not comparable across patients with
       different amounts of time in the registry. Use a certification or
       enrollment window if the patient table carries one; the observed
       first-to-last span is censored at both ends and makes a one-time
       patient look like a zero-day observation.
%dd_rates(in=dd_pt_YOUR_DISPENSING_TABLE,
          out=pt_rates,
          vars=n_records n_products sum_QUANTITY sum_THC_MG,
          spanvar=observed_days,     * <-- replace with a certification span ;
          per=30);

proc means data=pt_rates n mean median p25 p75 p95 maxdec=2;
  var rate_n_records rate_sum_THC_MG;
run;
*/

/* 6b. Potency per dispensation over time. A rising average is either a
       change in what patients buy or a change in what the market sells, and
       the product mix is what separates the two.
proc sql;
  create table potency_trend as
  select intnx('month',DISPENSE_DT,0,'b') as ym format=monyy7.,
         count(*)         as n_dispensations,
         mean(THC_MG)     as mean_thc_mg,
         median(QUANTITY) as median_quantity
  from MEMORY.YOUR_DISPENSING_TABLE
  where not missing(DISPENSE_DT)
  group by calculated ym;
quit;
*/

/* 6c. Concentration by dispensary. If a handful of dispensaries account for
       most rows, dispensary is a confounder in anything geographic.
proc freq data=MEMORY.YOUR_DISPENSING_TABLE order=freq;
  tables DISPENSARY_COUNTY / out=disp_conc;
run;
*/

/* 6d. Does the same patient appear more than once on the same day?
       %DD_INTERVAL already counts these as zero-day gaps. Look at them
       before deciding whether they are split transactions or a double load.
proc sql;
  select count(*) as n_same_day_events
  from dd_ev_YOUR_DISPENSING_TABLE
  where gap_days = 0;
quit;
*/
