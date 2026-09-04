/*=============================================================================
  DD_00_SETUP.SAS
  Comprehensive Data Dictionary & Profiling System
  Targets: Medicare claims/enrollment extracts + memory (cognitive) study data

  DESIGN PRINCIPLE
  ----------------
  Nothing about your data is hardcoded. Every table name, variable name, type,
  length, format and code value is discovered at run time from
  DICTIONARY.TABLES / DICTIONARY.COLUMNS and from the data itself. The same
  program therefore runs unchanged against a Part D PDE file, an MBSF, a
  carrier line file, or a memory-clinic assessment table.

  WHAT IT PRODUCES
  ----------------
   1. Data overview .............. rows, columns, types, lengths, formats,
                                   labels, storage size, key structure
   2. Missing values ............. exact counts + % (numeric, character,
                                   SAS special missings .A-.Z, blank-only,
                                   sentinel codes such as 'NA'/'UNK'/'~',
                                   zero-vs-missing for money variables)
                                   + horizontal bar visualization
   3. Descriptive statistics ..... n, nmiss, mean, median, std, cv, min, max,
                                   p1 p5 q1 q3 p95 p99, IQR, range
   4. Univariate ................. histogram + kernel density panels,
                                   box plot panels
   5. Bivariate .................. scatter-plot matrix (pair plot),
                                   predictor-vs-target scatter + loess panels,
                                   target-by-category box panels
   6. Correlation ................ Pearson AND Spearman heat maps
                                   + ranked correlated-pair table
   7. Outliers ................... IQR fences (1.5x mild / 3.0x extreme),
                                   |z| > 3, standardized comparative box plot,
                                   per-variable outlier-rate bar chart
   8. Feature distribution ....... skewness, kurtosis, spread, zero-inflation,
                                   suggested transform, skewness bar chart
   9. Character value catalog .... EVERY distinct value in the FULL dataset
                                   for every variable below the cardinality
                                   ceiling, with n, %, and rank
  10. Date profiling ............. real ranges, SAS-date vs YYYYMMDD-integer
                                   detection, impossible/future dates
  11. Patient-level rollups ...... records / claims / drugs / dates / spend
                                   per person, concentration, follow-up span
  12. Cross-dataset linkage ...... ID overlap between Medicare and memory data
  13. Duplicate key diagnostics .. exact and key-level duplication
  14. Disclosure suppression ..... DUA cell suppression (default n < 11) with
                                   complementary suppression, applied to
                                   anything you export off the VM

  PASSES OVER THE DATA (cost control)
  -----------------------------------
    metadata           0 passes (dictionary views only)
    missing/quality    1 full pass
    numeric stats      1 full pass
    outlier counts     1 full pass
    cardinality screen 1 partial pass (&DD_SCREENOBS obs)
    value catalog      1 full pass
    graphics sample    1 full pass (sampling) then works on the sample
    patient rollup     1 full pass (+ sort for COUNT DISTINCT)
  On a large claims file, run with DD_GRAPHS=N first to get the dictionary,
  then re-run the graphics on the sample only.

  USAGE
  -----
    %include "/your/path/dd_00_setup.sas";
    ... (dd_01 .. dd_06) ...
    then edit and run dd_99_driver.sas

  Author: generated for the Medicare + memory profiling project.
=============================================================================*/

/*-----------------------------------------------------------------------------
  GLOBAL CONFIGURATION -- edit this block, nothing below it.
-----------------------------------------------------------------------------*/
%global
  DD_OUT            /* directory for XLSX / PDF / HTML output              */
  DD_PROJECT        /* label used in file names and titles                 */
  DD_MINCELL        /* DUA suppression threshold (CMS = 11)                */
  DD_MAXLEVELS      /* max distinct values before a var is "high card"     */
  DD_SCREENOBS      /* obs used to screen cardinality before the full pass */
  DD_SAMPLEOBS      /* target obs for plots (graphics sample)              */
  DD_MAXPANELVARS   /* max numeric vars drawn in panel graphics            */
  DD_MAXPAIRVARS    /* max vars in the scatter-plot matrix                 */
  DD_MAXCORRVARS    /* max vars in the correlation heat map                */
  DD_IDPATTERN      /* regex: names never enumerated / never plotted       */
  DD_SENTINELS      /* quoted list of "text codes that really mean missing"*/
  DD_SEED           /* sampling seed                                       */
  DD_GRAPHS         /* Y/N master switch for all visualizations            */
  DD_USEFORMATS     /* Y = catalog formatted labels, N = raw stored codes  */
;

%let DD_OUT          = /workspace/output/datadict;   /* <-- EDIT */
%let DD_PROJECT      = medicare_memory;              /* <-- EDIT */
%let DD_MINCELL      = 11;
%let DD_MAXLEVELS    = 500;
%let DD_SCREENOBS    = 250000;
%let DD_SAMPLEOBS    = 50000;
%let DD_MAXPANELVARS = 60;
%let DD_MAXPAIRVARS  = 8;
%let DD_MAXCORRVARS  = 40;
%let DD_SEED         = 20260904;
%let DD_GRAPHS       = Y;
%let DD_USEFORMATS   = N;

/* Variables matching this regex are never enumerated value-by-value and never
   plotted. They are direct identifiers or unbounded-cardinality keys. Keep
   BENE_ID out of the value catalog but still usable as the patient key.      */
%let DD_IDPATTERN = /(BENE_ID|CLM_ID|_ID$|^ID$|NPI|UPIN|CCN|HIC|MBI|SSN|TAX_NUM|PRVDR_NUM|CTRL_NUM|DOB|BIRTH|NAME|ADDR|ZIP5|ZIP9|EMAIL|PHONE)/i;

/* Text values that are structurally present but semantically missing.        */
%let DD_SENTINELS = 'NA','N/A','NULL','UNK','UNKN','UNKNOWN','MISSING','NONE','.','-','--','~','?','*','#','9999','99999';

options nofmterr mprint mlogic minoperator noquotelenmax;
ods graphics / reset=all width=900px height=620px imagemap noborder;

/*-----------------------------------------------------------------------------
  UTILITY MACROS
-----------------------------------------------------------------------------*/
%macro dd_note(txt); %put NOTE: [DD] &txt; %mend dd_note;
%macro dd_warn(txt); %put WARNING: [DD] &txt; %mend dd_warn;

%macro dd_dsexist(ds);
  %sysfunc(exist(&ds))
%mend dd_dsexist;

%macro dd_varexist(ds,var);
  %local dsid rc r; %let r=0;
  %let dsid=%sysfunc(open(&ds));
  %if &dsid %then %do;
    %if %sysfunc(varnum(&dsid,&var)) %then %let r=1;
    %let rc=%sysfunc(close(&dsid));
  %end;
  &r
%mend dd_varexist;

%macro dd_nobs(ds);
  %local dsid n rc; %let n=0;
  %let dsid=%sysfunc(open(&ds));
  %if &dsid %then %do;
    %let n=%sysfunc(attrn(&dsid,nlobs));
    %let rc=%sysfunc(close(&dsid));
  %end;
  &n
%mend dd_nobs;

%macro dd_n(list);
  %local i w; %let i=0;
  %do %while(%qscan(&list,&i+1,%str( )) ne %str());
    %let i=%eval(&i+1);
  %end;
  &i
%mend dd_n;

/* Truncate a space-delimited list to the first &keep words. */
%macro dd_first(list,keep);
  %local i out; %let out=;
  %do i=1 %to %sysfunc(min(&keep,%dd_n(&list)));
    %let out=&out %scan(&list,&i,%str( ));
  %end;
  &out
%mend dd_first;

/*  Populate a global macro variable with a variable list from DICTIONARY.COLUMNS.
    type    = num | char | all
    exclid  = Y drops anything matching &DD_IDPATTERN
    maxlen  = drop names longer than this (protects PROC MEANS AUTONAME and the
              ODS "F_<name>" columns, both of which cap at 32 characters)      */
%macro dd_getvars(lib=,mem=,type=all,out=DD_VARS,exclid=N,maxlen=30,extradrop=);
  %global &out;
  %local tfilter dfilter;
  %let &out=;
  %if %upcase(&type)=NUM  %then %let tfilter=%str(and type='num');
  %else %if %upcase(&type)=CHAR %then %let tfilter=%str(and type='char');
  %else %let tfilter=;
  %let dfilter=;
  %if %upcase(&exclid)=Y %then
      %let dfilter=%str(and not prxmatch("&DD_IDPATTERN",strip(name)));
  proc sql noprint;
    select strip(name) into :&out separated by ' '
    from dictionary.columns
    where libname=%upcase("&lib") and memname=%upcase("&mem")
      &tfilter &dfilter
      and length(strip(name)) <= &maxlen
      %if %length(&extradrop) %then %do;
        and upcase(strip(name)) not in (%dd_qlist(&extradrop))
      %end;
    order by varnum;
  quit;
%mend dd_getvars;

/*  Random sample for graphics. One pass; keeps the sample reproducible.       */
%macro dd_sample(lib=,mem=,out=dd_samp,n=&DD_SAMPLEOBS,keep=);
  %local nobs frac;
  %let nobs=%dd_nobs(&lib..&mem);
  %if &nobs<=0 %then %do;
    %dd_warn(&lib..&mem has no observations - sample skipped.);
    data &out; stop; run; %return;
  %end;
  %if &nobs<=&n %then %let frac=1;
  %else %let frac=%sysevalf(&n/&nobs);
  data &out;
    set &lib..&mem %if %length(&keep) %then (keep=&keep);;
    if &frac >= 1 then output;
    else do;
      if _n_=1 then call streaminit(&DD_SEED);
      if rand('uniform') <= &frac then output;
    end;
  run;
  %dd_note(Graphics sample: %dd_nobs(&out) of &nobs obs from &lib..&mem);
%mend dd_sample;

/*-----------------------------------------------------------------------------
  DISCLOSURE SUPPRESSION
  Applies CMS-style small-cell suppression to any frequency table before it
  leaves the VM. Primary rule: blank counts 1..(&DD_MINCELL-1). Complementary
  rule: if exactly one cell inside a group is suppressed, the next smallest
  cell is suppressed too, otherwise the hidden count is recoverable from the
  total. Percentages are blanked with the counts -- suppressing n while
  publishing % does nothing.
-----------------------------------------------------------------------------*/
/* 'A','B','C'  -- a quoted, comma-separated list for SQL IN() clauses */
%macro dd_qlist(list);
  %local i out w;
  %let out=; %let i=1;
  %do %while(%scan(&list,&i,%str( )) ne %str());
    %let w=%sysfunc(quote(%upcase(%scan(&list,&i,%str( )))));
    %if &i=1 %then %let out=&w;
    %else %let out=&out,&w;
    %let i=%eval(&i+1);
  %end;
  &out
%mend dd_qlist;

%macro dd_commas(list);
  %local i out w;
  %let out=;
  %let i=1;
  %do %while(%scan(&list,&i,%str( )) ne %str());
    %let w=%scan(&list,&i,%str( ));
    %if &i=1 %then %let out=&w;
    %else %let out=&out,&w;
    %let i=%eval(&i+1);
  %end;
  &out
%mend dd_commas;

%macro dd_suppress(in=,out=,group=dataset varname,count=n,pct=pct,min=&DD_MINCELL);
  %local glast gcomma;
  %let glast=%scan(&group,-1,%str( ));
  %let gcomma=%dd_commas(&group);
  proc sort data=&in out=_dd_sup; by &group &count; run;
  data _dd_sup;
    set _dd_sup;
    length dd_suppressed 8;
    dd_suppressed = (0 < &count < &min);
  run;
  proc sql noprint;
    create table _dd_supn as
      select &gcomma, sum(dd_suppressed) as _nsup
      from _dd_sup
      group by &gcomma
      order by &gcomma;
  quit;
  data &out;
    merge _dd_sup(in=a) _dd_supn;
    by &group;
    retain _bumped 0;
    if first.&glast then _bumped=0;
    /* complementary suppression: hide the smallest surviving cell so the
       primary-suppressed cell cannot be recovered by subtraction            */
    if _nsup=1 and dd_suppressed=0 and _bumped=0 then do;
      dd_suppressed=1; _bumped=1;
    end;
    length n_display $12 pct_display $8;
    if dd_suppressed then do;
      n_display="<&min"; pct_display='SUPP';
      call missing(&count %if %length(&pct) %then , &pct;);
    end;
    else do;
      n_display=strip(put(&count,comma16.));
      %if %length(&pct) %then pct_display=strip(put(&pct,6.2));;
    end;
    drop _nsup _bumped;
  run;
  %dd_note(Suppression applied at n < &min with complementary suppression.);
%mend dd_suppress;

/*-----------------------------------------------------------------------------
  ODS WRAPPERS
-----------------------------------------------------------------------------*/
%macro dd_odsopen(tag=);
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    ods listing close;
    ods pdf file="&DD_OUT/&DD_PROJECT._&tag._graphics.pdf"
            startpage=no style=htmlblue dpi=200;
    ods html5 path="&DD_OUT" (url=none)
            file="&DD_PROJECT._&tag._graphics.html" style=htmlblue;
    ods graphics on / reset=all width=900px height=620px;
  %end;
%mend dd_odsopen;

%macro dd_odsclose;
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    ods pdf close; ods html5 close; ods listing;
  %end;
%mend dd_odsclose;
