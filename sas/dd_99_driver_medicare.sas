/*=============================================================================
  DD_99_DRIVER_MEDICARE.SAS        VM 1 -- MEDICARE ONLY
                                   ONE FOLDER PER YEAR

  This VM holds Medicare and nothing else. There is no cannabis or Medicaid
  data here and no cross-VM linkage is possible or attempted.

  READ THIS BEFORE YOU CHANGE THE LIBNAMES
  ----------------------------------------
  Your data is one folder per year. The obvious move is a concatenated
  libref:

      libname MED ("/data/med/2016" "/data/med/2017" "/data/med/2018");

  Do not do that here. On a READ, a concatenated library resolves a member
  name to the FIRST occurrence it finds and stops. MED.BCARRIER would be
  2016's BCARRIER, not the three years stacked. Every count, every value
  catalog and every date range you then produced would describe 2016 while
  being labelled as the panel -- with no error, no warning and no note.

  This driver assigns ONE LIBREF PER YEAR instead. That is not a workaround.
  It keeps the year attached to every row of output, which is what makes the
  panel questions answerable at all: which years does this table exist in,
  which years does this variable exist in, which years does this code value
  exist in, and did anything change type or length in between.

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
%include "&DDPATH/dd_08_panel.sas";

%let DD_OUT       = /workspace/output/datadict;   /* <-- must already exist */
%let DD_PROJECT   = medicare;
%let DD_MINCELL   = 11;      /* CMS DUA minimum cell size, confirmed         */
%let DD_MAXLEVELS = 500;     /* raise for ICD/HCPCS fields you want in full   */
%let DD_GRAPHS    = Y;

/*---------------------------------------------------------------------------
  STEP 1.  Assign one libref per year.

  pattern= is the folder path with @YEAR@ standing in for the year. Match it
  to how your folders are actually named:
      /data/medicare/@YEAR@
      /data/medicare/y@YEAR@
      /data/medicare/cms_@YEAR@/data
  A folder that is not there is REPORTED, not skipped silently -- check
  DD_LIBRARIES after this runs.
---------------------------------------------------------------------------*/
%dd_libyears(pattern = /data/medicare/@YEAR@,          /* <-- EDIT */
             years   = 2016 2017 2018 2019 2020,       /* <-- EDIT */
             prefix  = MED);

proc print data=dd_libraries noobs label;
  title 'Year libraries: check every row says "assigned" before going on';
run;
title;

/*---------------------------------------------------------------------------
  STEP 2.  Clear prior results so a re-run does not append to itself.
---------------------------------------------------------------------------*/
proc datasets library=work nolist nowarn;
  delete dd_tables dd_columns dd_missing dd_numstats dd_outliers
         dd_cardinality dd_values dd_levelcount dd_corrpairs dd_dates
         dd_patient_summary dd_patient_meta dd_linkage dd_duplicates
         dd_calendar dd_interval_summary dd_dictionary
         dd_inventory dd_inventory_summary dd_panel_vars dd_panel_values
         dd_panel_stats;
quit;

/*---------------------------------------------------------------------------
  STEP 3.  What tables exist in which years?

  Read this first. A table present 2016-2018 and absent from 2019 has almost
  certainly been renamed, not deleted, and a sweep driven by a table list you
  typed would simply not profile it after the rename.
---------------------------------------------------------------------------*/
%dd_inventory;

proc print data=dd_inventory_summary noobs label;
  title 'Table inventory: anything flagged RENAMED needs a decision before pooling';
run;
title;

/*---------------------------------------------------------------------------
  STEP 4.  Sweep every table in every year.

  Driven by DICTIONARY.TABLES rather than by a list, so a mid-panel rename
  cannot cause a table to be skipped. Because each year has its own libref,
  the "dataset" column of every output is already MED2016.BCARRIER -- the
  year is carried through the whole system with no extra parameter.

  Run this with graphs=N. Five years times a dozen tables is a lot of full
  passes; get the dictionary first, then re-run graphics on the specific
  table-years you care about.

  Start with maxtables= to try it on a couple of tables per year before
  committing to the whole sweep.
---------------------------------------------------------------------------*/
%dd_sweep(graphs=N, maxtables=2);         /* smoke test: 2 tables per year */

/* then the real thing:
%dd_sweep(graphs=N);
*/

/* or restrict to the tables you actually need:
%dd_sweep(graphs=N, tables=BCARRIER BCARRIER_LINE MBSF_ABCD);
*/

/*---------------------------------------------------------------------------
  STEP 5.  The panel checks. This is the part a pooled dictionary cannot do.
---------------------------------------------------------------------------*/
%dd_panel_vars;      /* variable x year presence; type and length changes  */
%dd_panel_values;    /* code values by year: what appears when             */
%dd_panel_stats;     /* year-over-year shifts in numeric distributions     */

/* The three questions to take away from these, in order of how badly they
   bite:                                                                    */
proc print data=dd_panel_vars noobs label;
  where n_types > 1;
  title 'TYPE CHANGES -- a SET across these years is a hard ERROR';
run;

proc print data=dd_panel_vars noobs label;
  where n_lengths > 1;
  title 'LENGTH CHANGES -- a SET truncates these silently unless LENGTH is declared first';
run;

proc print data=dd_panel_vars noobs label;
  where not missing(years_absent) or not missing(years_empty);
  var base_table varname first_year last_year years_absent years_empty;
  title 'MID-PANEL GAPS -- present in some years, absent or empty in others';
run;
title;

/*---------------------------------------------------------------------------
  STEP 6.  Full battery on the table-years you care about.

  NOTHING BELOW IS A LOOKUP. These are placeholders. This session had no
  access to the CoDES dictionary exports, so no variable name here has been
  verified against your extract. Confirm each one in sheet 1 first, and check
  sheet "8 Dates" for whether a date variable is a real SAS date or an
  unformatted YYYYMMDD integer before setting datefmt=.
---------------------------------------------------------------------------*/
/*
%dd_profile(lib=MED2019, mem=YOUR_CLAIMS_TABLE,
            id       = BENE_ID,
            claimid  = CLM_ID,
            datevar  = CLM_FROM_DT,
            datefmt  = SAS,
            key      = BENE_ID CLM_ID,
            interval = month,
            gapdays  = 90,
            logscale = Y);
*/

/*---------------------------------------------------------------------------
  STEP 7.  Assemble and export.
---------------------------------------------------------------------------*/
%dd_assemble;
%dd_export(export=VM);      /* full detail. STAYS IN THIS ENCLAVE.          */
%dd_export(export=SHARE);   /* cells < 11 suppressed. Safe to move.         */

/*---------------------------------------------------------------------------
  STEP 8.  Stacking years, once you know it is safe.

  %DD_STACKYEARS reads the panel checks before it generates anything. It
  aborts on a type change rather than letting SAS throw a less useful error,
  it generates the LENGTH statements that prevent the silent truncation a
  length change would otherwise cause, and it tags every row with the year it
  came from so a pooled result can always be decomposed back.

  table= is the BASE table name from DD_INVENTORY, so a mid-panel rename is
  handled for you.
---------------------------------------------------------------------------*/
/*
%dd_stackyears(table=BCARRIER, out=carrier_all,
               keep=BENE_ID CLM_ID CLM_FROM_DT,
               where=%str(not missing(BENE_ID)));

proc freq data=carrier_all;
  tables _source_year / nocum;
  title 'Rows contributed by each year -- confirm every year is represented';
run;
title;
*/

/*---------------------------------------------------------------------------
  STEP 9.  Rates, with the right denominator.

  Fills per beneficiary is not comparable across people with different
  amounts of enrollment: three months and two fills is a HIGHER rate than
  twelve months and six. The denominator belongs to the MBSF, not the claim
  file. %DD_RATES will use the observed first-to-last span if you let it, and
  that is censored at both ends -- use it only when no eligibility file
  exists. With one folder per year, enrollment has to be summed ACROSS the
  year libraries first, which is what %DD_STACKYEARS is for.
---------------------------------------------------------------------------*/
/*
%dd_stackyears(table=YOUR_MBSF_TABLE, out=mbsf_all,
               keep=BENE_ID YOUR_ENROLLED_MONTHS_VAR);

proc sql;
  create table pt_denominator as
  select BENE_ID, sum(YOUR_ENROLLED_MONTHS_VAR) as enrolled_months
  from mbsf_all
  group by BENE_ID;
quit;

data pt_with_denom;
  merge dd_pt_YOUR_PDE_TABLE(in=a) pt_denominator(in=b);
  by BENE_ID;
  if a;
  enrolled_days = enrolled_months * 30.4375;
  if not b then enrolled_days = .;   * no enrollment record: do NOT impute ;
run;

%dd_rates(in=pt_with_denom, out=pt_rates,
          vars=n_records n_products sum_DAYS_SUPLY_NUM sum_TOT_RX_CST_AMT,
          spanvar=enrolled_days, per=365.25);
*/
