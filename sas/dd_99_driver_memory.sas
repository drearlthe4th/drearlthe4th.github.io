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
%include "&DDPATH/dd_08_panel.sas";   /* only needed if any file is split by year */

%let DD_OUT       = /workspace/output/datadict;   /* <-- must already exist */
%let DD_PROJECT   = memory_medicaid;

/*  CONFIRMED: 11 applies to both the Medicaid and the registry data in this
    enclave. Primary suppression blanks any cell of 1-10; complementary
    suppression then blanks the next smallest cell in the same variable, so a
    single suppressed cell cannot be recovered by subtraction from the total.
    Percentages are blanked along with the counts.                          */
%let DD_MINCELL   = 11;

/*  Cannabis dispensing files are code-heavy: product names, forms, strains,
    qualifying conditions. Raise the ceiling so those are catalogued in full
    rather than skipped as high-cardinality.                                */
%let DD_MAXLEVELS = 2000;
%let DD_GRAPHS    = Y;

/*  Three sources in three folders is exactly the normal case: one libname
    each. Nothing special is required. (Contrast VM 1, where Medicare is one
    folder PER YEAR and needs dd_08_panel.sas -- see that driver's header for
    why a concatenated libref is the wrong answer there.)                    */
libname MEMORY "/data/memory"   access=readonly;  /* <-- EDIT: cannabis     */
libname MCAID  "/data/medicaid" access=readonly;  /* <-- EDIT: Medicaid     */
libname XWALK  "/data/xwalk"    access=readonly;  /* <-- EDIT: crosswalk    */

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
%dd_profile(lib=XWALK,  mem=YOUR_CROSSWALK_TABLE,  graphs=N);  /* <-- EDIT */
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
    drugvar=  PRODUCT_NAME. Note the consequence: product names are free-text
              trade names, not a controlled vocabulary, so "distinct products
              per patient" from this field is an ESTIMATE and almost certainly
              an over-count -- re-branded, re-spelled and re-cased versions of
              one product each count once more. STEP 3b records that caveat in
              the dictionary itself so it travels with the deliverable, and
              STEP 6e measures how bad the spelling drift is.
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
  STEP 4.  MEMORY -> crosswalk -> Medicaid.

  You have the crosswalk, so use %DD_XWALK rather than %DD_LINK. It measures
  the three things a crosswalk breaks that a direct join does not:

    COVERAGE   ids on either side that the crosswalk simply does not contain.
               They are unlinkable, and they are not missing at random.
    FAN-OUT    one registry patient mapped to several MSIS ids, or the
               reverse. A one-to-one merge on a fan-out crosswalk silently
               multiplies rows and every downstream count is then wrong in
               the same direction. The macro warns in the log if it finds any.
    STALENESS  crosswalk ids that appear in neither source file. Harmless to
               the join, but they inflate any match rate computed from the
               crosswalk alone.

  Read the END TO END rows of the output and ignore the rest for reporting
  purposes. Crosswalk coverage overstates the match rate, because a crosswalk
  row whose partner is not actually present in the source file links nothing.

  Then remember what the unlinked share means: registry patients who pay cash
  or carry commercial insurance have no Medicaid record at all. The linked
  subset is a SELECTED population, not a sample of registry patients, and
  that percentage belongs in your limitations paragraph.
---------------------------------------------------------------------------*/
/*
%dd_xwalk(liba=MEMORY, mema=YOUR_DISPENSING_TABLE, ida=PATIENT_ID,
          libb=MCAID,  memb=YOUR_MEDICAID_ELIG,    idb=MSIS_ID,
          xlib=XWALK,  xmem=YOUR_CROSSWALK_TABLE,
          xa=PATIENT_ID, xb=MSIS_ID);
*/

/* Check the crosswalk's own key uniqueness before trusting it. If either of
   these reports NOT UNIQUE, the crosswalk is many-to-many and you must decide
   how to collapse it BEFORE any merge -- not after the row counts look odd. */
/*
%dd_dups(lib=XWALK, mem=YOUR_CROSSWALK_TABLE, key=PATIENT_ID);
%dd_dups(lib=XWALK, mem=YOUR_CROSSWALK_TABLE, key=MSIS_ID);
*/

/*---------------------------------------------------------------------------
  STEP 5.  Assemble and export.
---------------------------------------------------------------------------*/
%dd_assemble;

/* STEP 3b -- record the caveats in the dictionary itself, so they travel
   with the deliverable instead of living in an email. Any note containing a
   comma must be wrapped in %str(), as below.                               */
/*
%dd_annotate(dataset=MEMORY.YOUR_DISPENSING_TABLE, varname=PRODUCT_NAME,
             note=%str(ESTIMATE ONLY. Free-text trade names with no controlled
                       vocabulary. Distinct-product counts derived from this
                       field are an upper bound: re-branded / re-spelled /
                       re-cased versions of one product each count separately.
                       Do not report as a product count without saying so.));

%dd_annotate(dataset=MEMORY.YOUR_DISPENSING_TABLE, varname=PATIENT_ID,
             note=%str(Links to Medicaid only through the crosswalk. See the
                       Linkage sheet: the linked subset is a selected
                       population, not a sample of registry patients.));
*/

%dd_export(export=VM);      /* full detail. STAYS IN THIS ENCLAVE.          */
%dd_export(export=SHARE);   /* cells < 11 suppressed. Safe to move.         */

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

/* 6e. HOW BAD IS THE PRODUCT_NAME ESTIMATE?
       Collapsing case, punctuation and whitespace gives a lower bound on the
       true number of distinct products. The gap between the raw count and the
       normalized count is the size of the error in every "distinct products
       per patient" figure. Report the gap, not just the count.
proc sql;
  create table product_drift as
  select count(distinct PRODUCT_NAME) as n_raw,
         count(distinct upcase(compress(PRODUCT_NAME,,'sp'))) as n_normalized,
         calculated n_raw - calculated n_normalized as n_collapsed,
         100*(calculated n_raw - calculated n_normalized)
             / max(calculated n_raw,1) as pct_overcount
  from MEMORY.YOUR_DISPENSING_TABLE
  where not missing(PRODUCT_NAME);
quit;

* the specific names that collapse together -- read this before trusting any
  product-level result ;
proc sql;
  create table product_collisions as
  select upcase(compress(PRODUCT_NAME,,'sp')) as normalized_name,
         count(distinct PRODUCT_NAME) as n_spellings,
         count(*) as n_dispensations
  from MEMORY.YOUR_DISPENSING_TABLE
  where not missing(PRODUCT_NAME)
  group by calculated normalized_name
  having calculated n_spellings > 1
  order by n_dispensations desc;
quit;
*/
