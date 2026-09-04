/*=============================================================================
  DD_98_SELFTEST.SAS
  Run this FIRST, before pointing anything at the real data.

  It profiles two SASHELP tables that stand in for the two real ones:
      SASHELP.HEART     -> a person-level clinical file
                           (numeric measures, character status, missingness)
      SASHELP.PRICEDATA -> a repeated-event panel, the shape of a claims file
                           or a dispensing file (many rows per unit, dates,
                           money)

  It is deliberately run against SASHELP rather than your data, so it is safe
  to run in either enclave.
  If this produces a workbook and a graphics PDF without errors, the program
  is working and any later failure is about your data, not the code.
=============================================================================*/

/*  HOW TO RUN IT
    Run STEP 0 of either driver (the %include block) and then this file, in a
    FRESH SAS SESSION. This file overwrites DD_OUT and DD_PROJECT so its
    output lands in WORK; running it in the middle of a real profiling session
    would redirect that session's output too.                                */
%let DD_OUT = %sysfunc(pathname(work));   /* selftest writes to WORK */
%let DD_PROJECT = selftest;

/* clear anything from a previous run */
proc datasets library=work nolist nowarn;
  delete dd_tables dd_columns dd_missing dd_numstats dd_outliers
         dd_cardinality dd_values dd_levelcount dd_corrpairs dd_dates
         dd_patient_summary dd_patient_meta dd_linkage dd_duplicates
         dd_calendar dd_interval_summary dd_dictionary
         dd_inventory dd_inventory_summary dd_panel_vars dd_panel_values
         dd_panel_stats;
quit;

%dd_profile(lib=SASHELP, mem=HEART,
            target=Cholesterol,
            catvars=Sex Status Chol_Status,
            logscale=Y);

%dd_profile(lib=SASHELP, mem=PRICEDATA,
            id=regionName, claimid=productName, datevar=date,
            datefmt=SAS, sumvars=sale price, catvars=regionName,
            key=regionName productName date,
            interval=month, gapdays=60,
            logscale=Y);

%dd_assemble;
%dd_export(export=VM);
%dd_export(export=SHARE);

%put NOTE: [DD] Selftest complete. Look in %sysfunc(pathname(work)) for the output.;
