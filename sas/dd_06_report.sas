/*=============================================================================
  DD_06_REPORT.SAS
  Assembles the one-row-per-variable master dictionary and exports everything.
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_ASSEMBLE -- join every component into DD_DICTIONARY, one row per
  variable per dataset. This is the sheet a collaborator actually reads.
-----------------------------------------------------------------------------*/
/* sort an optional component for the merge, or stand in an empty shell */
%macro _dd_opt(ds,keepvars);
  %if %dd_dsexist(&ds) %then %do;
    proc sort data=&ds(keep=&keepvars) out=_dd_j_&ds; by dataset varname; run;
  %end;
  %else %do;
    data _dd_j_&ds; length dataset $41 varname $32; stop; run;
  %end;
%mend _dd_opt;

%macro dd_assemble(out=dd_dictionary);
  %if %dd_dsexist(dd_columns)=0 %then %do;
    %dd_warn(dd_columns does not exist - run %nrstr(%dd_meta) first.); %return;
  %end;

  /* a compact "top 5 values" string per variable */
  %if %dd_dsexist(dd_values) %then %do;
    proc sort data=dd_values out=_dd_v5; by dataset varname value_rank; run;
    data _dd_v5;
      set _dd_v5; by dataset varname;
      where value_rank <= 5;
      length top_values $400;
      retain top_values;
      if first.varname then top_values='';
      top_values = catx(' | ',top_values,
                        cats(value,' (',put(pct,5.1),'%)'));
      if last.varname then output;
      keep dataset varname top_values;
    run;
  %end;
  %else %do; data _dd_v5; length dataset $41 varname $32 top_values $400; stop; run; %end;

  %_dd_opt(dd_missing,  dataset varname vartype nobs n_nonmiss n_miss pct_miss
                        pct_usable n_special n_zero n_negative n_blank
                        n_sentinel n_untrimmed n_mixedcase maxlen_used
                        declared_len quality_flag)
  %_dd_opt(dd_numstats, dataset varname n_nonmiss n_miss mean std median min max
                        sum p1 p5 p25 p75 p95 p99 cv skewness kurtosis iqr range
                        lower_fence_mild upper_fence_mild shape
                        suggested_transform mean_median_ratio)
  %_dd_opt(dd_outliers, dataset varname n_mild n_extreme n_z3 pct_mild
                        pct_extreme pct_z3 min_outlier max_outlier)
  %_dd_opt(dd_cardinality, dataset varname n_levels_est enumerate screen_note)
  %_dd_opt(dd_levelcount,  dataset varname n_levels_exact)
  %_dd_opt(dd_dates,       dataset varname storage_form min_as_date max_as_date
                           date_flagging)

  proc sort data=dd_columns out=_dd_base; by dataset varname; run;
  proc sort data=_dd_v5; by dataset varname; run;

  data &out;
    merge _dd_base(in=a)
          _dd_j_dd_missing (rename=(n_nonmiss=n_nonmiss_all n_miss=n_miss_all))
          _dd_j_dd_numstats
          _dd_j_dd_outliers
          _dd_j_dd_cardinality
          _dd_j_dd_levelcount
          _dd_j_dd_dates
          _dd_v5;
    by dataset varname;
    if a;
    length n_levels 8 dictionary_note $300;
    n_levels = coalesce(n_levels_exact, n_levels_est);

    /* one place a reader can look to see whether the variable is usable */
    dictionary_note = quality_flag;
    if n_levels = 1 then dictionary_note=catx('; ',dictionary_note,
       'CONSTANT - one value in the whole file');
    if enumerate = 0 then dictionary_note=catx('; ',dictionary_note,
       'high cardinality - values not enumerated (identifier or free text)');
    if not missing(date_flagging) then dictionary_note=catx('; ',dictionary_note,date_flagging);
    if not missing(pct_extreme) and pct_extreme > 1 then dictionary_note=catx('; ',dictionary_note,
       cats(put(pct_extreme,5.1),'% of values beyond 3 x IQR'));
    if not missing(shape) and shape ne 'approximately symmetric'
       then dictionary_note=catx('; ',dictionary_note,shape);

    label
      dataset='Dataset'  varname='Variable'  label='Variable label'
      vartype='Type'     length='Storage length'  format='Format'
      nobs='Rows in dataset'
      n_nonmiss_all='Non-missing rows' n_miss_all='Missing rows'
      pct_miss='% missing'  pct_usable='% usable (non-missing and not a sentinel)'
      n_levels='Distinct values'  top_values='Most frequent values'
      shape='Distribution shape'  suggested_transform='Suggested transform'
      dictionary_note='Notes / warnings';
  run;

  proc sort data=&out; by dataset varnum; run;
  %dd_note(DD_DICTIONARY assembled: %dd_nobs(&out) variable rows.);
%mend dd_assemble;

/*-----------------------------------------------------------------------------
  %DD_EXPORT -- one workbook, one sheet per section.
  export=VM     everything, unsuppressed, stays on the VM
  export=SHARE  small cells suppressed at &DD_MINCELL, safe to move
-----------------------------------------------------------------------------*/
%macro dd_export(file=,export=VM);
  %local suffix valueds;
  %if %length(&file)=0 %then %let file=&DD_PROJECT;
  %if %upcase(&export)=SHARE %then %do;
    %let suffix=_shareable;
    %if %dd_dsexist(dd_values) %then %do;
      %dd_suppress(in=dd_values,out=dd_values_share,
                   group=dataset varname,count=n,pct=pct);
      %let valueds=dd_values_share;
    %end;
  %end;
  %else %do;
    %let suffix=_full;
    %let valueds=dd_values;
  %end;

  ods excel file="&DD_OUT/&file&suffix..xlsx"
      options(sheet_interval='none' embedded_titles='yes'
              autofilter='all' frozen_headers='yes' frozen_rowheaders='2');

  ods excel options(sheet_name='1 Dictionary');
  title "Data dictionary - &DD_PROJECT";
  proc print data=dd_dictionary noobs label; run;

  ods excel options(sheet_name='2 Datasets');
  title "Dataset overview";
  proc print data=dd_tables noobs label; run;

  ods excel options(sheet_name='3 Missing');
  title "Missing values, sentinels and format hygiene";
  %if %dd_dsexist(dd_missing) %then %do; proc print data=dd_missing noobs label; run; %end;

  ods excel options(sheet_name='4 Statistics');
  title "Descriptive statistics";
  %if %dd_dsexist(dd_numstats) %then %do; proc print data=dd_numstats noobs label; run; %end;

  ods excel options(sheet_name='5 Outliers');
  title "Outlier detection";
  %if %dd_dsexist(dd_outliers) %then %do; proc print data=dd_outliers noobs label; run; %end;

  ods excel options(sheet_name='6 Values');
  title "Complete value catalog";
  title2 "Every distinct value present in the full dataset for every enumerated variable.";
  %if %dd_dsexist(&valueds) %then %do; proc print data=&valueds noobs label; run; %end;

  ods excel options(sheet_name='7 Correlations');
  %if %dd_dsexist(dd_corrpairs) %then %do;
    title "Correlated pairs (Pearson vs Spearman)";
    proc print data=dd_corrpairs noobs label; run;
  %end;

  ods excel options(sheet_name='8 Dates');
  %if %dd_dsexist(dd_dates) %then %do;
    title "Date variable storage form and plausibility";
    proc print data=dd_dates noobs label; run;
  %end;

  ods excel options(sheet_name='9 Patient level');
  %if %dd_dsexist(dd_patient_summary) %then %do;
    title "Patient-level rollup distributions";
    proc print data=dd_patient_summary noobs label; run;
  %end;
  %if %dd_dsexist(dd_patient_meta) %then %do;
    title "Patient-level headline metrics";
    proc print data=dd_patient_meta noobs label; run;
  %end;

  ods excel options(sheet_name='10 Linkage and keys');
  %if %dd_dsexist(dd_linkage) %then %do;
    title "Cross-dataset linkage"; proc print data=dd_linkage noobs label; run;
  %end;
  %if %dd_dsexist(dd_duplicates) %then %do;
    title "Key uniqueness"; proc print data=dd_duplicates noobs label; run;
  %end;

  ods excel close;
  title;
  %dd_note(Workbook written to &DD_OUT/&file&suffix..xlsx);
  %if %upcase(&export)=VM %then
    %dd_warn(This workbook is UNSUPPRESSED. Do not move it off the VM. Re-run with export=SHARE for a releasable copy.);
%mend dd_export;

/*-----------------------------------------------------------------------------
  %DD_PROFILE -- run the whole battery on one dataset.
-----------------------------------------------------------------------------*/
%macro dd_profile(lib=,mem=,
                  id=,claimid=,drugvar=,datevar=,sumvars=,catvars=,
                  target=,key=,force=,plotvars=,logscale=Y,graphs=&DD_GRAPHS);
  %local _g ptds;
  %let _g=&DD_GRAPHS; %let DD_GRAPHS=&graphs;
  %let ptds=dd_pt_%substr(&mem,1,%sysfunc(min(%length(&mem),25)));

  %if %dd_dsexist(&lib..&mem)=0 %then %do;
    %dd_warn(&lib..&mem does not exist - skipped.); %let DD_GRAPHS=&_g; %return;
  %end;
  %if %dd_nobs(&lib..&mem)=0 %then %do;
    %dd_warn(&lib..&mem has zero rows - skipped.); %let DD_GRAPHS=&_g; %return;
  %end;

  %put NOTE: ================ PROFILING &lib..&mem ================;

  /* structure and quality: full-file passes, no sampling */
  %dd_meta(    lib=&lib,mem=&mem);
  %dd_missing( lib=&lib,mem=&mem);
  %dd_numstats(lib=&lib,mem=&mem);
  %dd_outliers(lib=&lib,mem=&mem);
  %dd_dates(   lib=&lib,mem=&mem);
  %dd_card(    lib=&lib,mem=&mem);
  %dd_levels(  lib=&lib,mem=&mem,force=&force);
  %if %length(&key) %then %dd_dups(lib=&lib,mem=&mem,key=&key);;

  /* pictures: sample once, reuse for every plot */
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    %dd_odsopen(tag=&mem);
    %dd_sample(lib=&lib,mem=&mem);
    %dd_univar(lib=&lib,mem=&mem,vars=&plotvars,logscale=&logscale);
    %dd_bivar( lib=&lib,mem=&mem,vars=&plotvars,target=&target,catvars=&catvars);
    %dd_corr(  lib=&lib,mem=&mem,vars=&plotvars);
    %if %length(&id) %then
      %dd_patient(lib=&lib,mem=&mem,id=&id,claimid=&claimid,drugvar=&drugvar,
                  datevar=&datevar,sumvars=&sumvars,catvars=&catvars,
                  ptout=&ptds);;
    %dd_odsclose;
  %end;
  %else %do;
    %if %length(&id) %then
      %dd_patient(lib=&lib,mem=&mem,id=&id,claimid=&claimid,drugvar=&drugvar,
                  datevar=&datevar,sumvars=&sumvars,catvars=&catvars,
                  ptout=&ptds);;
  %end;

  %let DD_GRAPHS=&_g;
  %put NOTE: ================ DONE &lib..&mem ================;
%mend dd_profile;
