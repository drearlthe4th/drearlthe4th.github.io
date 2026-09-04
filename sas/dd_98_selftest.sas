/*=============================================================================
  DD_98_SELFTEST.SAS
  Run this FIRST, before pointing anything at the real data.

  It profiles two SASHELP tables that stand in for the two real ones:
      SASHELP.HEART  -> a person-level clinical file, like the memory data
                        (numeric scores, character status fields, missingness)
      SASHELP.PRICEDATA -> a repeated-measures panel, like a claims file
                        (many rows per unit, dates, money)
  If this produces a workbook and a graphics PDF without errors, the program
  is working and any later failure is about your data, not the code.
=============================================================================*/

%let DD_OUT = %sysfunc(pathname(work));   /* selftest writes to WORK */
%let DD_PROJECT = selftest;

/* clear anything from a previous run */
proc datasets library=work nolist nowarn;
  delete dd_tables dd_columns dd_missing dd_numstats dd_outliers
         dd_cardinality dd_values dd_levelcount dd_corrpairs dd_dates
         dd_patient_summary dd_patient_meta dd_linkage dd_duplicates
         dd_dictionary;
quit;

%dd_profile(lib=SASHELP, mem=HEART,
            target=Cholesterol,
            catvars=Sex Status Chol_Status,
            logscale=Y);

%dd_profile(lib=SASHELP, mem=PRICEDATA,
            id=regionName, claimid=productName, datevar=date,
            sumvars=sale price, catvars=regionName,
            key=regionName productName date,
            logscale=Y);

%dd_assemble;
%dd_export(export=VM);
%dd_export(export=SHARE);

%put NOTE: [DD] Selftest complete. Look in %sysfunc(pathname(work)) for the output.;
