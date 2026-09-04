/*=============================================================================
  DD_03_VALUES.SAS
  (9) COMPLETE VALUE CATALOG for character (and low-cardinality numeric)
      variables: every distinct value present in the FULL dataset, with its
      frequency, percent, and rank.

  HOW COMPLETENESS IS GUARANTEED, AND WHERE IT IS DELIBERATELY NOT
  ----------------------------------------------------------------
  "Every value in the full dataset" is the right goal for coded fields and the
  wrong goal for identifiers. BENE_ID has one value per beneficiary and CLM_ID
  one per claim; enumerating them would (a) build a hash table the size of the
  file, and (b) produce a listing that IS the identifier file, which is a
  disclosure problem, not a dictionary.

  So the catalog runs in two stages:

    STAGE 1  screen cardinality on &DD_SCREENOBS observations. Cheap, one
             partial pass. Its ONLY job is to decide which variables are safe
             to enumerate. Variables matching &DD_IDPATTERN are excluded here
             regardless of what the screen says.

    STAGE 2  a single full-data PROC FREQ over the surviving variables. Every
             value of those variables is captured -- all rows, all years, no
             sampling, missing included as its own level.

  Variables that fail the screen are still reported: name, estimated
  cardinality, why they were skipped. Nothing disappears silently. Raise
  DD_MAXLEVELS, or pass force= to enumerate a specific one anyway.

  Values are captured RAW (formats are removed inside PROC FREQ) because a
  data dictionary documents what is stored, not what a format catalog happens
  to display today. Set DD_USEFORMATS=Y to catalog the formatted labels
  instead.
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_CARD -- stage 1: cardinality screen.
-----------------------------------------------------------------------------*/
%macro dd_card(lib=,mem=,out=dd_cardinality,append=Y,
               screenobs=&DD_SCREENOBS,drop=);
  %global DD_LOWCARD DD_HIGHCARD;
  %local allvars nall fmtstmt nobs;
  %let DD_LOWCARD=; %let DD_HIGHCARD=;

  /* every variable except direct identifiers and over-long names */
  %dd_getvars(lib=&lib,mem=&mem,type=all,out=_DDALL,exclid=Y,maxlen=30,
              extradrop=&drop);
  %let allvars=&_DDALL; %let nall=%dd_n(&allvars);
  %if &nall=0 %then %do;
    %dd_warn(&lib..&mem: nothing eligible for a value catalog.); %return;
  %end;

  %let nobs=%dd_nobs(&lib..&mem);
  %if %upcase(&DD_USEFORMATS)=Y %then %let fmtstmt=;
  %else %let fmtstmt=%str(format &allvars;);

  /* NOPRINT on the TABLES statement suppresses the frequency tables but not
     the NLevels table, which is what this stage needs.                      */
  proc freq data=&lib..&mem(obs=&screenobs) nlevels;
    tables &allvars / noprint missing;
    &fmtstmt
    ods output nlevels=_dd_nlev;
  run;

  data _dd_card;
    length dataset $41 varname $32 screen_note $90;
    retain dataset "&lib..&mem";
    set _dd_nlev;
    varname       = TableVar;
    n_levels_est  = NLevels;
    screened_obs  = min(&screenobs,&nobs);
    full_obs      = &nobs;
    exhaustive    = (screened_obs >= full_obs);
    if exhaustive then screen_note='Screen covered the whole file: count is exact.';
    else screen_note=cats('Estimated from the first ',put(screened_obs,comma12.),
                          ' obs; the full-file pass reports the exact count.');
    enumerate = (n_levels_est <= &DD_MAXLEVELS);
    if not enumerate then screen_note=catx(' ',screen_note,
         cats('SKIPPED: >',put(&DD_MAXLEVELS,comma8.),' distinct values.'));
    drop TableVar;
  run;

  proc sql noprint;
    select strip(varname) into :DD_LOWCARD  separated by ' '
      from _dd_card where enumerate=1;
    select strip(varname) into :DD_HIGHCARD separated by ' '
      from _dd_card where enumerate=0;
  quit;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_card force; run;
  %end;
  %else %do; data &out; set _dd_card; run; %end;

  %dd_note(&lib..&mem: %dd_n(&DD_LOWCARD) variables will be enumerated in full.);
  %if %length(&DD_HIGHCARD) %then
    %dd_note(&lib..&mem: high-cardinality/identifier variables NOT enumerated: &DD_HIGHCARD);
%mend dd_card;

/*-----------------------------------------------------------------------------
  %DD_LEVELS -- stage 2: one full-data pass, every value of every eligible
  variable. force= adds variables the screen rejected (use with intent).
-----------------------------------------------------------------------------*/
%macro dd_levels(lib=,mem=,out=dd_values,append=Y,force=);
  %local vars fmtstmt nobs;
  %let vars=%cmpres(&DD_LOWCARD &force);
  %if %length(&vars)=0 %then %do;
    %dd_warn(&lib..&mem: no variables eligible for the value catalog.); %return;
  %end;
  %let nobs=%dd_nobs(&lib..&mem);
  %if %upcase(&DD_USEFORMATS)=Y %then %let fmtstmt=;
  %else %let fmtstmt=%str(format &vars;);

  /* The one-way tables must actually be generated for ODS OUTPUT to capture
     them, so NOPRINT cannot be used here. ODS EXCLUDE ALL suppresses the
     display (which would otherwise be thousands of pages) while ODS OUTPUT
     still builds the datasets.                                             */
  ods exclude all;
  proc freq data=&lib..&mem nlevels;
    tables &vars / missing nocum;
    &fmtstmt
    ods output OneWayFreqs=_dd_ows nlevels=_dd_nlev_full;
  run;
  ods exclude none;

  /* ODS stacks every one-way table into one wide dataset: the "Table" column
     names the variable and the value sits in the matching F_<var> column.
     VVALUEX pulls it by name, so the reshape does not care how many
     variables were requested or what they are called.                       */
  data _dd_lev;
    length dataset $41 varname $32 value $256;
    retain dataset "&lib..&mem";
    set _dd_ows;
    varname = scan(Table,-1,' ');
    value   = strip(vvaluex(cats('F_',varname)));
    if value='' then value='(missing)';
    n   = Frequency;
    pct = Percent;
    keep dataset varname value n pct;
  run;

  proc sort data=_dd_lev; by dataset varname descending n value; run;
  data _dd_lev;
    set _dd_lev; by dataset varname;
    retain value_rank 0 cum_n 0;
    if first.varname then do; value_rank=0; cum_n=0; end;
    value_rank+1; cum_n+n;
    cum_pct = 100*cum_n/max(&nobs,1);
    is_missing_level = (value='(missing)');
  run;

  /* exact full-file level counts, replacing the screened estimate */
  data _dd_nlev_full;
    length dataset $41 varname $32;
    retain dataset "&lib..&mem";
    set _dd_nlev_full;
    varname=TableVar; n_levels_exact=NLevels;
    keep dataset varname n_levels_exact;
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_lev force; run;
  %end;
  %else %do; data &out; set _dd_lev; run; %end;

  %if %upcase(&append)=Y and %dd_dsexist(dd_levelcount) %then %do;
    proc append base=dd_levelcount data=_dd_nlev_full force; run;
  %end;
  %else %do; data dd_levelcount; set _dd_nlev_full; run; %end;

  %dd_note(&lib..&mem: %dd_nobs(_dd_lev) distinct values catalogued across %dd_n(&vars) variables.);

  /*---- visualization: cardinality profile ---------------------------------*/
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    %if %dd_dsexist(dd_cardinality) %then %do;
      data _dd_cardp;
        set dd_cardinality;
        where dataset="&lib..&mem";
        length cardband $26;
        if      n_levels_est = 1                then cardband='1: constant (no signal)';
        else if n_levels_est = 2                then cardband='2: binary';
        else if n_levels_est <= 10              then cardband='3: 3-10 levels';
        else if n_levels_est <= 100             then cardband='4: 11-100 levels';
        else if n_levels_est <= &DD_MAXLEVELS   then cardband=cats('5: 101-',&DD_MAXLEVELS);
        else                                         cardband='6: high card (skipped)';
      run;
      title  "Cardinality profile - &lib..&mem";
      title2 "Constant variables carry no information; high-cardinality variables are identifiers or free text, not categories.";
      proc sgplot data=_dd_cardp;
        vbar cardband / group=cardband datalabel;
        xaxis display=(nolabel) valueattrs=(size=8);
        yaxis label='Number of variables' grid;
        keylegend / position=bottom title='Cardinality band';
      run;
      title;
    %end;

    /* the top values of each catalogued variable, one panel per variable */
    data _dd_top;
      set _dd_lev;
      where value_rank <= 12;
    run;
    %if %dd_nobs(_dd_top) > 0 %then %do;
      title  "Value distribution - top 12 levels per variable (&lib..&mem)";
      title2 "Percentages are of all rows, missing included as its own level.";
      proc sgpanel data=_dd_top;
        panelby varname / columns=3 rows=3 uniscale=none novarname
                          headerattrs=(size=8);
        hbarparm category=value response=pct / categoryorder=respdesc
                 fillattrs=(color=cx4c72b0);
        colaxis label='Percent of rows' grid;
        rowaxis display=(nolabel) valueattrs=(size=6) fitpolicy=none;
      run;
      title;
    %end;
  %end;
%mend dd_levels;
