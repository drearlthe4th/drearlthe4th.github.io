/*=============================================================================
  DD_09_DECLARE.SAS
  Things the data does not say about itself, that you have to declare.

  Two of them:

    A. Numeric values stored in character columns.
       %DD_NUMLIKE   finds them and tells you which are safe to convert
       %DD_FORCENUM  converts the ones you declare, into NEW variables

    B. Datasets that are the same logical file across years despite carrying
       different member names.
       %DD_MAPTABLE  declares "these member names are the same table"
       %DD_MAPVAR    the same thing for a variable renamed across years
       %DD_SHOWMAP   prints what you declared and what was guessed

  Declarations live in DD_TABLEMAP and DD_VARMAP and are picked up
  automatically by everything in dd_08_panel.sas.
=============================================================================*/

/*=============================================================================
  A.  NUMERIC-IN-CHARACTER
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_NUMLIKE -- which character variables are really numbers?

  One pass over the character columns. For each one it reports how many values
  would parse as a number, and then three reasons NOT to convert even when
  they all would:

    LEADING ZEROS   The single most expensive mistake available here. ZIP
                    codes, ICD codes, NDC codes, HCPCS codes, county and
                    state FIPS, provider numbers -- all of these are digit
                    strings where the leading zero is part of the value.
                    '01234' converted to numeric is 1234, and it will not
                    join back to anything. If a variable has ANY value
                    starting 0 followed by a digit, this macro refuses to
                    call it a safe candidate.

    TOO MANY DIGITS A SAS numeric holds about 15 significant digits exactly.
                    A 17-digit claim id converted to numeric is silently
                    rounded, and two different claims can become the same
                    number. Flagged at 15.

    PARTIAL PARSE   If 3% of the values do not parse, converting turns those
                    3% into missing. That may be exactly right (they were
                    'UNK') or exactly wrong (they were '1,234'). The macro
                    counts them and %DD_FORCENUM lists them so you can look.

  obs= limits the scan for a quick look; leave it blank for exact counts.
-----------------------------------------------------------------------------*/
%macro dd_numlike(lib=,mem=,out=dd_numlike,append=Y,obs=);
  %global DD_NUMCAND;
  %local charlist nchar dsopt;
  %dd_getvars(lib=&lib,mem=&mem,type=char,out=_DDCHR,maxlen=30);
  %let charlist=&_DDCHR; %let nchar=%dd_n(&charlist);
  %if &nchar=0 %then %do;
    %dd_note(&lib..&mem has no character variables to test.); %return;
  %end;
  %if %length(&obs) %then %let dsopt=(obs=&obs); %else %let dsopt=;

  data _dd_nl(keep=dataset varname n_nonblank n_parses n_all_digits
                   n_leading_zero n_has_comma n_has_currency n_has_space
                   max_digits parsed_min parsed_max pct_parses scanned_obs);
    length dataset $41 varname $32;
    retain dataset "&lib..&mem";
    set &lib..&mem&dsopt end=_eof nobs=_nobs;

    array _c[*] &charlist;
    array _nb[&nchar] _temporary_;  array _np[&nchar] _temporary_;
    array _nd[&nchar] _temporary_;  array _lz[&nchar] _temporary_;
    array _cm[&nchar] _temporary_;  array _cu[&nchar] _temporary_;
    array _sp[&nchar] _temporary_;  array _md[&nchar] _temporary_;
    array _mn[&nchar] _temporary_;  array _mx[&nchar] _temporary_;

    retain _rxnum _rxdig _rxlz;
    if _n_=1 then do;
      /* optional sign, digits with optional decimal, optional exponent */
      _rxnum = prxparse('/^[+-]?(\d+\.?\d*|\.\d+)([eEdD][+-]?\d+)?$/');
      _rxdig = prxparse('/^\d+$/');
      _rxlz  = prxparse('/^0\d/');
      do _i=1 to &nchar;
        _nb[_i]=0; _np[_i]=0; _nd[_i]=0; _lz[_i]=0;
        _cm[_i]=0; _cu[_i]=0; _sp[_i]=0; _md[_i]=0;
      end;
    end;

    length _s $256;
    do _i=1 to dim(_c);
      if not missing(_c[_i]) then do;
        _nb[_i]+1;
        _s = strip(_c[_i]);
        if prxmatch(_rxnum,_s) then do;
          _np[_i]+1;
          _v = input(_s,?? best32.);
          _mn[_i]=min(_mn[_i],_v); _mx[_i]=max(_mx[_i],_v);
        end;
        if prxmatch(_rxdig,_s) then do;
          _nd[_i]+1;
          _md[_i]=max(_md[_i],lengthn(_s));
        end;
        if prxmatch(_rxlz,_s)          then _lz[_i]+1;
        if index(_s,',')               then _cm[_i]+1;
        if indexc(_s,'$()')            then _cu[_i]+1;
        if index(strip(_s),' ')        then _sp[_i]+1;
      end;
    end;

    if _eof then do _i=1 to dim(_c);
      varname=vname(_c[_i]);
      scanned_obs=_nobs;
      n_nonblank=_nb[_i]; n_parses=_np[_i]; n_all_digits=_nd[_i];
      n_leading_zero=_lz[_i]; n_has_comma=_cm[_i]; n_has_currency=_cu[_i];
      n_has_space=_sp[_i]; max_digits=_md[_i];
      parsed_min=_mn[_i]; parsed_max=_mx[_i];
      pct_parses = 100*n_parses/max(n_nonblank,1);
      output;
    end;
  run;

  data _dd_nl;
    set _dd_nl;
    length verdict $60 suggested_informat $12 conversion_note $300;
    n_fails = n_nonblank - n_parses;

    /* the informat that would actually read these values */
    if      n_has_currency > 0 then suggested_informat='dollar32.';
    else if n_has_comma    > 0 then suggested_informat='comma32.';
    else                            suggested_informat='best32.';

    if n_nonblank = 0 then do;
      verdict='ALL BLANK - nothing to convert';
    end;
    else if n_leading_zero > 0 then do;
      verdict='DO NOT CONVERT - leading zeros';
      conversion_note=cats(put(n_leading_zero,comma16.),
        ' value(s) start with 0 followed by a digit. The zero is part of the'
        ||' value (ZIP, ICD, NDC, HCPCS, FIPS, provider number). Converting'
        ||' loses it and the variable will no longer join.');
    end;
    else if max_digits > 15 then do;
      verdict='DO NOT CONVERT - too many digits';
      conversion_note=cats('Longest digit string is ',max_digits,
        ' characters. A SAS numeric is exact to about 15 digits, so distinct'
        ||' values can silently collapse onto the same number.');
    end;
    else if pct_parses >= 99.9 then do;
      verdict='SAFE CANDIDATE - numeric stored as character';
      conversion_note='Every non-blank value parses. Convert with %dd_forcenum.';
    end;
    else if pct_parses >= 50 then do;
      verdict='MOSTLY NUMERIC - check the failures first';
      conversion_note=cats(put(n_fails,comma16.),' non-blank value(s) would'
        ||' become missing. Run %dd_forcenum and read its failures dataset'
        ||' before accepting that.');
    end;
    else verdict='NOT NUMERIC - leave as character';

    if n_has_space > 0 and index(verdict,'SAFE') then
      conversion_note=catx(' ',conversion_note,
        'Some values contain an embedded space - check they are not two fields in one.');
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_nl force; run;
  %end;
  %else %do; data &out; set _dd_nl; run; %end;

  /* a ready-to-paste list for %dd_forcenum */
  %let DD_NUMCAND=;
  proc sql noprint;
    select strip(varname) into :DD_NUMCAND separated by ' '
    from _dd_nl where index(verdict,'SAFE CANDIDATE');
  quit;
  %dd_note(&lib..&mem safe conversion candidates: &DD_NUMCAND);
  %put NOTE: [DD] Paste that list into %nrstr(%dd_forcenum(vars= ...)).;

  %if %upcase(&DD_GRAPHS)=Y %then %do;
    data _dd_nlp; set _dd_nl; where n_nonblank > 0 and pct_parses > 0; run;
    %if %dd_nobs(_dd_nlp) > 0 %then %do;
      title  "Character variables that look numeric - &lib..&mem";
      title2 "Bar height is how much of the variable parses as a number. Colour is the verdict: a variable can be 100% numeric-looking and still be unsafe to convert.";
      proc sgplot data=_dd_nlp;
        hbar varname / response=pct_parses group=verdict categoryorder=respdesc;
        xaxis label='Percent of non-blank values that parse as a number' grid
              values=(0 to 100 by 10);
        yaxis display=(nolabel) valueattrs=(size=7) fitpolicy=none;
        keylegend / position=bottom title='Verdict';
      run;
      title;
    %end;
  %end;
%mend dd_numlike;

/*-----------------------------------------------------------------------------
  %DD_FORCENUM -- create numeric companions for the variables you declare.

  The original character variable is KEPT. The new one is <var><suffix>,
  default <var>_N. Nothing is overwritten, so a bad conversion is always
  recoverable and the two can be compared.

  vars=     space separated list of character variables to convert
  map=      per-variable informats where the default is wrong, as
            VAR:informat pairs, e.g.  map=TOT_PMT:dollar32. QTY:comma32.
  informat= the default informat for anything not in map= (best32.)
  suffix=   suffix for the new numeric variable (_N)
  view=     Y builds a VIEW instead of a physical copy. On a large claims
            file this is the difference between free and a second copy of the
            file on disk. Use Y unless you need the data materialized.
  strict=   Y refuses to convert a variable that %DD_NUMLIKE flagged for
            leading zeros or digit overflow. Set to N only deliberately.
  keep=     restrict the output to these columns (plus the new numerics)

  It also writes DD_FORCENUM_LOG (how many values converted and how many
  failed, per variable) and DD_FORCENUM_FAILURES (the distinct character
  values that would not parse, with counts, so you can see what they are).
-----------------------------------------------------------------------------*/
%macro dd_forcenum(lib=,mem=,out=,vars=,map=,informat=best32.,suffix=_N,
                   view=N,strict=Y,keep=,check=dd_numlike,
                   logout=dd_forcenum_log,failout=dd_forcenum_failures,
                   failcap=100000);
  %local i j v vi n blocked keeplist newvars;
  %if %length(&vars)=0 %then %do;
    %dd_warn(dd_forcenum needs vars= - skipped.); %return;
  %end;
  %if %length(&out)=0 %then %do;
    %dd_warn(dd_forcenum needs out= - skipped.); %return;
  %end;

  /* refuse the conversions %DD_NUMLIKE said not to make */
  %let blocked=;
  %if %upcase(&strict)=Y and %dd_dsexist(&check) %then %do;
    proc sql noprint;
      select strip(varname) into :blocked separated by ' '
      from &check
      where dataset="&lib..&mem" and index(verdict,'DO NOT CONVERT')
        and upcase(strip(varname)) in (%dd_qlist(&vars));
    quit;
    %if %length(&blocked) %then %do;
      %dd_warn(BLOCKED by %nrstr(%dd_numlike): &blocked);
      %dd_warn(These have leading zeros or more than 15 digits. Converting them is lossy. Pass strict=N only if you are sure.);
    %end;
  %end;

  /* build the surviving list and check the 32-character name ceiling */
  %let newvars=;
  %let keeplist=;
  %do i=1 %to %dd_n(&vars);
    %let v=%scan(&vars,&i,%str( ));
    /* space padding stops a short name matching inside a longer one */
    %if not %index(%str( )%upcase(&blocked)%str( ),%str( )%upcase(&v)%str( ))
      %then %do;
        %if %length(&v&suffix) > 32 %then
          %dd_warn(&v&suffix exceeds 32 characters - skipped.);
        %else %if %dd_varexist(&lib..&mem,&v)=0 %then
          %dd_warn(&v not found in &lib..&mem - skipped.);
        %else %let keeplist=&keeplist &v;
    %end;
  %end;
  %if %length(&keeplist)=0 %then %do;
    %dd_warn(Nothing left to convert.); %return;
  %end;

  data &out %if %upcase(&view)=Y %then / view=&out;;
    set &lib..&mem %if %length(&keep) %then (keep=&keep &keeplist);;
    %do i=1 %to %dd_n(&keeplist);
      %let v=%scan(&keeplist,&i,%str( ));
      /* per-variable informat from map=, else the default */
      %let vi=&informat;
      %do j=1 %to %dd_n(&map);
        %if %upcase(%scan(%scan(&map,&j,%str( )),1,%str(:)))=%upcase(&v) %then
          %let vi=%scan(%scan(&map,&j,%str( )),2,%str(:));
      %end;
      &v&suffix = input(strip(&v), ?? &vi);
      label &v&suffix = "&v converted to numeric with &vi";
    %end;
  run;

  /* conversion accounting, and the values that would not parse */
  data _dd_fnfail(keep=dataset varname value);
    length dataset $41 varname $32 value $256;
    retain dataset "&lib..&mem";
    set &lib..&mem end=_eof;
    array _cap[%dd_n(&keeplist)] _temporary_;
    %do i=1 %to %dd_n(&keeplist);
      %let v=%scan(&keeplist,&i,%str( ));
      %let vi=&informat;
      %do j=1 %to %dd_n(&map);
        %if %upcase(%scan(%scan(&map,&j,%str( )),1,%str(:)))=%upcase(&v) %then
          %let vi=%scan(%scan(&map,&j,%str( )),2,%str(:));
      %end;
      if not missing(&v) and missing(input(strip(&v), ?? &vi)) then do;
        _cap[&i] + 1;
        if _cap[&i] <= &failcap then do;
          varname="&v"; value=strip(&v); output;
        end;
      end;
    %end;
  run;

  ods exclude all;
  proc freq data=_dd_fnfail order=freq;
    tables varname*value / out=_dd_fnf(drop=percent);
  run;
  ods exclude none;

  data _dd_fnf;
    length dataset $41;
    retain dataset "&lib..&mem";
    set _dd_fnf;
    rename count=n_failed_rows;
    label value='Character value that would not parse'
          count='Rows carrying it (capped, see the log)';
  run;

  proc sql;
    create table _dd_fnlog as
    select "&lib..&mem" as dataset length=41,
           varname length=32,
           sum(n_failed_rows) as n_failed_values
    from _dd_fnf group by varname;
  quit;

  %if %dd_dsexist(&logout) %then %do;
    proc append base=&logout data=_dd_fnlog force; run;
    proc append base=&failout data=_dd_fnf force; run;
  %end;
  %else %do;
    data &logout;  set _dd_fnlog; run;
    data &failout; set _dd_fnf;   run;
  %end;

  %dd_note(Created %dd_n(&keeplist) numeric companions in &out with suffix &suffix);
  %dd_note(Failures are listed in &failout - read them before trusting the conversion.);
  %dd_warn(&failout holds raw data values - run it through %nrstr(%dd_suppress) before any export.);
%mend dd_forcenum;

/*=============================================================================
  B.  EQUIVALENT FILES ACROSS YEARS

  dd_08_panel.sas guesses at this: it strips a trailing _K and a trailing
  year from the member name, so BCARRIER_K and BCARRIER line up on their own.
  That guess handles the common cases and it will be wrong sometimes -- and
  when it is wrong, the panel checks quietly compare two different tables, or
  fail to compare one table with itself.

  So declare the ones you know. A declaration always beats the guess, and
  %DD_SHOWMAP prints which members were declared and which were guessed, so
  you can see what you have not pinned down yet.
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_MAPTABLE -- declare that several member names are one logical table.

    %dd_maptable(base=CARRIER,  members=BCARRIER BCARRIER_K BCARRIER_2019);
    %dd_maptable(base=MBSF_ABCD,members=MBSF_ABCD_SUMMARY MBSF_ABCD);

  base=    the name you want the table to be called in every panel report
  members= every member name it appears under, in any year
  reset=Y  start the map over

  A member declared twice under different bases is an error you want to see,
  so the macro reports it rather than picking one.
-----------------------------------------------------------------------------*/
%macro dd_maptable(base=,members=,reset=N,map=dd_tablemap);
  %local i;
  %if %upcase(&reset)=Y or %dd_dsexist(&map)=0 %then %do;
    data &map; length member $32 base_table $32; stop; run;
  %end;
  %if %length(&base)=0 or %length(&members)=0 %then %do;
    %dd_warn(dd_maptable needs base= and members= - nothing declared.); %return;
  %end;

  data _dd_mt;
    length member $32 base_table $32;
    %do i=1 %to %dd_n(&members);
      member    = upcase("%scan(&members,&i,%str( ))");
      base_table= upcase("&base");
      output;
    %end;
  run;
  proc append base=&map data=_dd_mt force; run;

  /* one member cannot belong to two tables */
  proc sort data=&map; by member base_table; run;
  proc sql noprint;
    create table _dd_mtdup as
      select member, count(distinct base_table) as n_bases
      from &map group by member having calculated n_bases > 1;
    select count(*) into :_ndup trimmed from _dd_mtdup;
  quit;
  %if &_ndup > 0 %then %do;
    %dd_warn(&_ndup member name(s) are declared under more than one base table.);
    proc print data=_dd_mtdup noobs;
      title 'Conflicting table declarations - fix these before running the panel checks';
    run;
    title;
  %end;
  proc sort data=&map nodupkey; by member; run;
  %dd_note(Declared &base = &members);
%mend dd_maptable;

/*-----------------------------------------------------------------------------
  %DD_MAPVAR -- the same thing for a variable renamed across years.

    %dd_mapvar(base=CLM_FROM_DT, names=CLM_FROM_DT FROM_DT CLM_FROM_DATE);
    %dd_mapvar(base=PAID_AMT,    names=PMT_AMT PAID_AMT, table=CARRIER);

  Without this, a variable renamed mid-panel shows up in %DD_PANEL_VARS as two
  variables each present in half the years, rather than as one variable that
  changed name. table= scopes the rename to one base table; leave it blank to
  apply everywhere.
-----------------------------------------------------------------------------*/
%macro dd_mapvar(base=,names=,table=,reset=N,map=dd_varmap);
  %local i;
  %if %upcase(&reset)=Y or %dd_dsexist(&map)=0 %then %do;
    data &map; length varname $32 base_varname $32 base_table $32; stop; run;
  %end;
  %if %length(&base)=0 or %length(&names)=0 %then %do;
    %dd_warn(dd_mapvar needs base= and names= - nothing declared.); %return;
  %end;

  data _dd_mv;
    length varname $32 base_varname $32 base_table $32;
    %do i=1 %to %dd_n(&names);
      varname      = upcase("%scan(&names,&i,%str( ))");
      base_varname = upcase("&base");
      base_table   = upcase("&table");
      output;
    %end;
  run;
  proc append base=&map data=_dd_mv force; run;
  proc sort data=&map nodupkey; by base_table varname; run;
  %dd_note(Declared variable &base = &names %if %length(&table) %then (in &table););
%mend dd_mapvar;

/*-----------------------------------------------------------------------------
  %DD_SHOWMAP -- what is declared, and what is still being guessed.

  Run this after %DD_INVENTORY. Every member listed as "auto" is one the
  program guessed at. If any of those guesses look wrong, declare them with
  %DD_MAPTABLE and re-run the inventory.
-----------------------------------------------------------------------------*/
%macro dd_showmap(inv=dd_inventory,map=dd_tablemap,varmap=dd_varmap);
  %if %dd_dsexist(&map) %then %do;
    proc print data=&map noobs label;
      title 'Declared table equivalences';
    run;
  %end;
  %else %put NOTE: [DD] No table declarations - every member name is being guessed.;

  %if %dd_dsexist(&varmap) %then %do;
    proc print data=&varmap noobs label;
      title 'Declared variable renames';
    run;
  %end;

  %if %dd_dsexist(&inv) %then %do;
    proc sql;
      create table dd_mapcheck as
      select distinct base_table, base_source, memname, libname
      from &inv order by base_source, base_table, libname;
    quit;
    proc print data=dd_mapcheck noobs label;
      where base_source='auto';
      title  'Member names the program GUESSED at';
      title2 'Check every row. If a guess is wrong, declare it with %dd_maptable and re-run %dd_inventory.';
    run;

    proc sql;
      create table dd_mapmulti as
      select base_table, count(distinct memname) as n_member_names,
             count(distinct libname) as n_years
      from &inv group by base_table having calculated n_member_names > 1;
    quit;
    proc print data=dd_mapmulti noobs label;
      title 'Tables whose member name changes across years';
    run;
  %end;
  title;
%mend dd_showmap;
