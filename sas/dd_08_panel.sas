/*=============================================================================
  DD_08_PANEL.SAS
  One folder per year: how to profile it, and what it breaks.

  THE TRAP, FIRST
  ---------------
  The obvious move is a concatenated libref:

      libname MED ("/data/med/2016" "/data/med/2017" "/data/med/2018");

  DO NOT DO THIS FOR PROFILING. On a READ, a concatenated library resolves a
  member name to the FIRST occurrence it finds and stops. MED.BCARRIER is
  2016's BCARRIER, not all three stacked. Every count, every value catalog,
  every date range you then produce describes 2016 and is labelled as though
  it described the panel. No error, no warning, no note. It is the single
  worst failure mode available in this setup, because the output looks
  entirely normal.

  (Concatenation is fine for a PROC APPEND-style stack you build yourself, and
  fine when you genuinely want "first match wins". It is wrong here.)

  WHAT TO DO INSTEAD
  ------------------
  One libref per year -- MED2016, MED2017, ... -- and profile each year as its
  own dataset. That is not a workaround, it is the better answer: it keeps the
  year attached to every row of output, so the panel questions become
  answerable instead of averaged away.

      %DD_LIBYEARS   assign one libref per year folder, and report the folders
                     that are not there
      %DD_INVENTORY  what tables exist in which years -- this is where you see
                     a mid-panel rename
      %DD_SWEEP      profile every table in every year, driven by what is
                     actually on disk rather than by a list you typed
      %DD_PANEL_VARS variable x year presence, plus type and length changes
                     across years
      %DD_PANEL_VALUES  code values by year: what appears when, and what
                     disappears
      %DD_PANEL_STATS   year-over-year shifts in numeric distributions
      %DD_STACKYEARS a guarded SET across years that refuses to run silently
                     when the years are not compatible
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_LIBYEARS -- one libref per year folder.

  pattern= the folder path with @YEAR@ standing in for the year, e.g.
             /data/medicare/@YEAR@
             /data/medicare/y@YEAR@
             /data/medicare/cms_@YEAR@/data
  years=   space separated, e.g. 2016 2017 2018 2019 2020

  A folder that is not there is reported, not skipped silently. A year that
  quietly vanishes from a sweep is the second worst failure mode here.
-----------------------------------------------------------------------------*/
%macro dd_libyears(pattern=,years=,prefix=MED,out=dd_libraries);
  %global DD_LIBLIST DD_YEARLIST;
  %local i y path;
  %let DD_LIBLIST=; %let DD_YEARLIST=;

  %do i=1 %to %dd_n(&years);
    %let y=%scan(&years,&i,%str( ));
    %let path=%sysfunc(tranwrd(&pattern,@YEAR@,&y));
    %global _ddpath&i _ddstat&i;
    %let _ddpath&i=&path;
    %if %sysfunc(fileexist(&path)) %then %do;
      libname &prefix.&y "&path" access=readonly;
      %if &syslibrc=0 %then %do;
        %let _ddstat&i=assigned;
        %let DD_LIBLIST=&DD_LIBLIST &prefix.&y;
        %let DD_YEARLIST=&DD_YEARLIST &y;
      %end;
      %else %do;
        %let _ddstat&i=LIBNAME FAILED (syslibrc=&syslibrc);
        %dd_warn(Could not assign &prefix.&y to &path);
      %end;
    %end;
    %else %do;
      %let _ddstat&i=FOLDER NOT FOUND;
      %dd_warn(Folder not found for &y: &path);
    %end;
  %end;

  data &out;
    length year 8 libref $8 path $400 status $60;
    %do i=1 %to %dd_n(&years);
      year=%scan(&years,&i,%str( ));
      libref="&prefix.%scan(&years,&i,%str( ))";
      path="&&_ddpath&i";
      status="&&_ddstat&i";
      output;
    %end;
  run;

  %dd_note(Assigned %dd_n(&DD_LIBLIST) of %dd_n(&years) year libraries: &DD_LIBLIST);
%mend dd_libyears;


/*-----------------------------------------------------------------------------
  %DD_ADDBASE -- attach LIBREF, YEAR and BASE_TABLE to anything carrying a
  "dataset" column of the form MED2016.BCARRIER.

  BASE_TABLE comes from your declarations in DD_TABLEMAP when the member name
  is declared there (%DD_MAPTABLE in dd_09_declare.sas), and from a guess
  otherwise: strip a trailing _K, strip a trailing year. BASE_SOURCE says
  which of the two happened, so %DD_SHOWMAP can list everything still being
  guessed at.

  A declaration always wins over the guess.
-----------------------------------------------------------------------------*/
%macro dd_addbase(in=,out=,map=dd_tablemap,varmap=dd_varmap);
  %if %dd_dsexist(&map)=0 %then %do;
    data &map; length member $32 base_table $32; stop; run;
  %end;

  proc sql;
    create table _dd_ab as
    select a.*, m.base_table as _declared_base
    from &in a
      left join &map m on upcase(scan(a.dataset,2,'.')) = m.member;
  quit;

  data &out;
    set _dd_ab;
    length libref $8 base_table $32 base_source $8;
    libref = scan(dataset,1,'.');
    year   = input(compress(libref,,'kd'),?? best12.);
    if not missing(_declared_base) then do;
      base_table  = _declared_base;
      base_source = 'declared';
    end;
    else do;
      base_table  = upcase(scan(dataset,2,'.'));
      base_table  = prxchange('s/_K$//',1,base_table);
      base_table  = prxchange('s/_?(19|20)\d\d$//',1,base_table);
      base_source = 'auto';
    end;
    drop _declared_base;
  run;

  /* apply declared variable renames, if this dataset has a varname column */
  %if %dd_dsexist(&varmap) and %dd_varexist(&out,varname) %then %do;
    proc sql;
      create table _dd_ab2 as
      select a.*,
             coalescec(v1.base_varname, v2.base_varname, a.varname)
               as _base_varname length=32
      from &out a
        left join &varmap v1
          on upcase(a.varname)=v1.varname and upcase(a.base_table)=v1.base_table
        left join &varmap v2
          on upcase(a.varname)=v2.varname and v2.base_table=' ';
    quit;
    data &out;
      set _dd_ab2;
      length original_varname $32;
      original_varname = varname;
      varname = _base_varname;
      drop _base_varname;
      label original_varname='Name in this year, before applying a declared rename';
    run;
  %end;
%mend dd_addbase;

/*-----------------------------------------------------------------------------
  %DD_INVENTORY -- which tables exist in which years.

  Read this before anything else. A table that is present 2016-2018 and absent
  from 2019 has almost certainly been renamed, not deleted, and a sweep that
  works from a hardcoded table list will simply not profile it after the
  rename -- again with no error.
-----------------------------------------------------------------------------*/
%macro dd_inventory(liblist=&DD_LIBLIST,out=dd_inventory,prefix=MED);
  %if %length(&liblist)=0 %then %do;
    %dd_warn(No year libraries assigned - run %nrstr(%dd_libyears) first.); %return;
  %end;

  proc sql;
    create table _dd_inv as
    select libname, memname, memtype, nobs, nvar, crdate, modate, filesize
    from dictionary.tables
    where libname in (%dd_qlist(&liblist)) and memtype='DATA'
    order by memname, libname;
  quit;

  /* BASE_TABLE comes from DD_TABLEMAP where you declared it, and from a
     guess otherwise. %DD_SHOWMAP lists everything still being guessed.     */
  data _dd_inv2;
    set _dd_inv;
    length dataset $41;
    dataset = catx('.',libname,memname);
  run;
  %dd_addbase(in=_dd_inv2,out=&out);

  /* presence matrix: base table x year */
  proc sql;
    create table _dd_pres as
    select base_table,
           count(distinct year) as n_years,
           min(year) as first_year, max(year) as last_year,
           count(distinct memname) as n_distinct_names,
           sum(nobs) as total_rows format=comma18.
    from &out group by base_table;
  quit;

  proc sql noprint;
    select count(distinct year) into :_nyr trimmed from &out;
  quit;

  data dd_inventory_summary;
    set _dd_pres;
    length inventory_flag $130;
    inventory_flag='';
    if n_years < &_nyr then inventory_flag=catx('; ',inventory_flag,
       cats('present in only ',n_years,' of ',"&_nyr",
            ' years - check for a rename before assuming it was dropped'));
    if n_distinct_names > 1 then inventory_flag=catx('; ',inventory_flag,
       cats('RENAMED: ',n_distinct_names,' different member names across years'));
  run;

  %if %upcase(&DD_GRAPHS)=Y %then %do;
    title  "Table inventory - which tables exist in which years";
    title2 "A gap in a row is a rename until you have proved otherwise.";
    proc sgplot data=&out;
      heatmapparm x=year y=base_table colorresponse=nobs /
           outline outlineattrs=(color=white)
           colormodel=(cxdeebf7 cx4c72b0 cx08306b);
      xaxis label='Year' grid type=discrete;
      yaxis display=(nolabel) valueattrs=(size=7) reverse;
      gradlegend / title='Rows';
    run;
    title;
  %end;

  %dd_note(Inventory written to &out and dd_inventory_summary.);
%mend dd_inventory;

/*-----------------------------------------------------------------------------
  %DD_SWEEP -- profile every table in every year library.

  Driven by DICTIONARY.TABLES, not by a list you typed, so a mid-panel rename
  cannot cause a table to be skipped.

  Run this with graphs=N. Twelve years times a dozen tables is a lot of full
  passes; get the dictionary first, then re-run the graphics on the specific
  table-years you care about.

  Because each year has its own libref, the "dataset" column of every output
  is already "MED2016.BCARRIER" -- the year is carried through the whole
  system with no extra parameter.
-----------------------------------------------------------------------------*/
%macro dd_sweep(liblist=&DD_LIBLIST,tables=,graphs=N,id=,claimid=,drugvar=,
                datevar=,datefmt=SAS,sumvars=,catvars=,key=,force=,
                interval=year,maxtables=0);
  %local i j lib nlib tabs n t;
  %if %length(&liblist)=0 %then %do;
    %dd_warn(No year libraries assigned - run %nrstr(%dd_libyears) first.); %return;
  %end;

  %do i=1 %to %dd_n(&liblist);
    %let lib=%scan(&liblist,&i,%str( ));
    %let tabs=;
    proc sql noprint;
      select memname into :tabs separated by ' '
      from dictionary.tables
      where libname=%upcase("&lib") and memtype='DATA'
        %if %length(&tables) %then and upcase(memname) in (%dd_qlist(&tables));
      order by memname;
    quit;

    %if %length(&tabs)=0 %then %do;
      %dd_warn(&lib contains no matching tables.);
    %end;
    %else %do;
      %let n=%dd_n(&tabs);
      %if &maxtables > 0 and &n > &maxtables %then %let n=&maxtables;
      %do j=1 %to &n;
        %let t=%scan(&tabs,&j,%str( ));
        %dd_profile(lib=&lib,mem=&t,graphs=&graphs,
                    id=&id,claimid=&claimid,drugvar=&drugvar,
                    datevar=&datevar,datefmt=&datefmt,
                    sumvars=&sumvars,catvars=&catvars,key=&key,force=&force,
                    interval=&interval);
      %end;
    %end;
  %end;
  %dd_note(Sweep complete across %dd_n(&liblist) year libraries.);
%mend dd_sweep;

/*-----------------------------------------------------------------------------
  %DD_PANEL_VARS -- the variable x year matrix, and the two changes that break
  a SET across years.

  TYPE CHANGE    a variable that is numeric in one year and character in
                 another is a hard ERROR on a SET. You will at least be told.
  LENGTH CHANGE  a character variable that is $12 in one year and $20 in
                 another is NOT an error. The SET takes its length from the
                 first dataset in the list, and every longer value in every
                 later year is silently truncated. %DD_STACKYEARS below
                 generates the LENGTH statements that prevent this.
  EMPTY YEARS    a variable can be structurally present and 100% missing for
                 part of the panel. It will pass every existence check you
                 write and contribute nothing.

  Reads DD_COLUMNS and DD_MISSING, so %DD_SWEEP must have run first.
-----------------------------------------------------------------------------*/
%macro dd_panel_vars(out=dd_panel_vars,cols=dd_columns,miss=dd_missing);
  %if %dd_dsexist(&cols)=0 %then %do;
    %dd_warn(&cols not found - run %nrstr(%dd_sweep) first.); %return;
  %end;

  /* BASE_TABLE and the declared variable renames are applied here, so a
     table or a variable you declared in dd_09_declare.sas lines up across
     years instead of looking like two half-present objects.               */
  %dd_addbase(in=&cols,out=_dd_pv0);
  data _dd_pv;
    set _dd_pv0;
    if not missing(year);
    keep dataset libref year base_table base_source varname vartype type
         length format label
         %if %dd_varexist(_dd_pv0,original_varname) %then original_varname;;
  run;

  /* years in which each TABLE exists -- the right denominator. A table that
     only starts in 2019 must not flag all of its variables as missing for
     2016-2018.                                                             */
  proc sql;
    create table _dd_tabyr as
      select distinct base_table, year from _dd_pv;
    create table _dd_varyr as
      select distinct base_table, varname, year from _dd_pv;

    create table _dd_gap as
      select t.base_table, v.varname, t.year
      from (select distinct base_table, varname from _dd_pv) v
           inner join _dd_tabyr t on v.base_table = t.base_table
      where not exists (select 1 from _dd_varyr p
                        where p.base_table = t.base_table
                          and p.varname    = v.varname
                          and p.year       = t.year);
  quit;

  proc sort data=_dd_gap; by base_table varname year; run;
  data _dd_gapstr;
    set _dd_gap; by base_table varname;
    length years_absent $200;
    retain years_absent;
    if first.varname then years_absent='';
    years_absent = catx(',',years_absent,put(year,4.));
    if last.varname then output;
    keep base_table varname years_absent;
  run;

  /* years in which the variable exists but is completely empty */
  %if %dd_dsexist(&miss) %then %do;
    %dd_addbase(in=&miss,out=_dd_mp0);
    data _dd_mp;
      set _dd_mp0;
      if not missing(year) and pct_miss >= 100;
      keep base_table varname year;
    run;
    proc sort data=_dd_mp; by base_table varname year; run;
    data _dd_emptystr;
      set _dd_mp; by base_table varname;
      length years_empty $200;
      retain years_empty;
      if first.varname then years_empty='';
      years_empty = catx(',',years_empty,put(year,4.));
      if last.varname then output;
      keep base_table varname years_empty;
    run;
  %end;
  %else %do;
    data _dd_emptystr; length base_table $32 varname $32 years_empty $200; stop; run;
  %end;

  proc sql;
    create table _dd_pvsum as
    select base_table, varname,
           count(distinct year)   as n_years_present,
           min(year)              as first_year,
           max(year)              as last_year,
           count(distinct type)   as n_types,
           count(distinct length) as n_lengths,
           min(length)            as min_length,
           max(length)            as max_length,
           count(distinct format) as n_formats
    from _dd_pv
    group by base_table, varname;
  quit;

  proc sort data=_dd_pvsum;    by base_table varname; run;
  proc sort data=_dd_gapstr;   by base_table varname; run;
  proc sort data=_dd_emptystr; by base_table varname; run;

  data &out;
    merge _dd_pvsum(in=a) _dd_gapstr _dd_emptystr;
    by base_table varname;
    if a;
    length panel_flag $220;
    panel_flag='';
    if n_types > 1 then panel_flag=catx('; ',panel_flag,
      'TYPE CHANGES ACROSS YEARS - a SET across these years is a hard ERROR');
    if n_lengths > 1 then panel_flag=catx('; ',panel_flag,
      cats('LENGTH CHANGES ',min_length,' to ',max_length,
           ' - a SET truncates silently unless LENGTH is declared first'));
    if not missing(years_absent) then panel_flag=catx('; ',panel_flag,
      cats('ABSENT in ',years_absent,' although the table exists there'));
    if not missing(years_empty) then panel_flag=catx('; ',panel_flag,
      cats('100% MISSING in ',years_empty,' - present but carries nothing'));
    if n_formats > 1 then panel_flag=catx('; ',panel_flag,
      'format differs across years - check the value catalog before pooling');
  run;

  proc sql noprint;
    select count(*) into :_ntype trimmed from &out where n_types  > 1;
    select count(*) into :_nlen  trimmed from &out where n_lengths > 1;
    select count(*) into :_ngap  trimmed from &out where not missing(years_absent);
  quit;
  %dd_note(Panel check: &_ntype type changes, &_nlen length changes, &_ngap mid-panel gaps.);

  %if %upcase(&DD_GRAPHS)=Y %then %do;
    proc sort data=_dd_varyr out=_dd_hm; by base_table varname year; run;
    data _dd_hm; set _dd_hm; present=1; run;
    title  "Variable presence by year";
    title2 "A hole in a row is a variable that disappears mid-panel. Guard for it or your SET drops it.";
    proc sgplot data=_dd_hm;
      by base_table;
      heatmapparm x=year y=varname colorresponse=present /
           outline outlineattrs=(color=white)
           colormodel=(cx4c72b0 cx4c72b0);
      xaxis label='Year' type=discrete grid;
      yaxis display=(nolabel) valueattrs=(size=6) reverse;
    run;
    title;
  %end;
%mend dd_panel_vars;

/*-----------------------------------------------------------------------------
  %DD_PANEL_VALUES -- code values by year.

  This answers the question a pooled dictionary cannot: does this code value
  exist in every year, or did it appear in 2018 and get backfilled nowhere?
  A union of all years shows the value and hides the fact that filtering on it
  drops your first two years entirely.

  Reads DD_VALUES, so %DD_SWEEP must have run first.
-----------------------------------------------------------------------------*/
%macro dd_panel_values(out=dd_panel_values,vals=dd_values,minpct=0);
  %if %dd_dsexist(&vals)=0 %then %do;
    %dd_warn(&vals not found - run %nrstr(%dd_sweep) first.); %return;
  %end;

  %dd_addbase(in=&vals,out=_dd_vy0);
  data _dd_vy;
    set _dd_vy0;
    if not missing(year) and pct >= &minpct;
  run;

  proc sql;
    create table _dd_vtab as
      select distinct base_table, varname, year from _dd_vy;

    create table _dd_vsum as
      select base_table, varname, value,
             count(distinct year) as n_years_seen,
             min(year)            as first_year_seen,
             max(year)            as last_year_seen,
             sum(n)               as n_total,
             mean(pct)            as mean_pct_within_year
      from _dd_vy
      group by base_table, varname, value;

    create table _dd_vden as
      select base_table, varname, count(distinct year) as n_years_var
      from _dd_vtab group by base_table, varname;
  quit;

  proc sort data=_dd_vsum; by base_table varname; run;
  proc sort data=_dd_vden; by base_table varname; run;

  data &out;
    merge _dd_vsum(in=a) _dd_vden;
    by base_table varname;
    if a;
    length value_flag $150;
    value_flag='';
    if n_years_seen < n_years_var then do;
      value_flag=cats('APPEARS IN ONLY ',n_years_seen,' OF ',n_years_var,
        ' YEARS (', first_year_seen,'-',last_year_seen,
        ') - filtering on it silently drops the other years');
    end;
  run;

  proc sql noprint;
    select count(*) into :_nvdrift trimmed from &out where not missing(value_flag);
  quit;
  %dd_note(&_nvdrift code values do not appear in every year of their variable.);
%mend dd_panel_values;

/*-----------------------------------------------------------------------------
  %DD_PANEL_STATS -- year-over-year shifts in numeric distributions.

  A payment field whose mean triples between two adjacent years has either a
  real story behind it or a units change, and you want to know which before
  you pool. Reads DD_NUMSTATS.
-----------------------------------------------------------------------------*/
%macro dd_panel_stats(out=dd_panel_stats,stats=dd_numstats,threshold=0.25);
  %if %dd_dsexist(&stats)=0 %then %do;
    %dd_warn(&stats not found - run %nrstr(%dd_sweep) first.); %return;
  %end;

  %dd_addbase(in=&stats,out=_dd_ps0);
  data _dd_ps;
    set _dd_ps0;
    if not missing(year);
  run;

  proc sql;
    create table &out as
    select base_table, varname,
           count(distinct year) as n_years,
           min(mean)   as min_year_mean,
           max(mean)   as max_year_mean,
           mean(mean)  as mean_of_year_means,
           std(mean)   as std_of_year_means,
           min(median) as min_year_median,
           max(median) as max_year_median
    from _dd_ps
    where n_nonmiss > 0
    group by base_table, varname
    having count(distinct year) > 1;
  quit;

  data &out;
    set &out;
    length stat_flag $150;
    if abs(mean_of_year_means) > 1e-12 then
      relative_swing = (max_year_mean - min_year_mean)/abs(mean_of_year_means);
    stat_flag='';
    if relative_swing > &threshold then stat_flag=
      cats('Year means swing by ',put(100*relative_swing,5.0),
           '% of the overall mean - real change, a units change, or a definition change. Resolve before pooling.');
    if min_year_mean = 0 and max_year_mean ne 0 then stat_flag=catx('; ',stat_flag,
      'mean is exactly zero in at least one year - the variable is probably not populated there');
  run;

  %if %upcase(&DD_GRAPHS)=Y %then %do;
    proc sort data=_dd_ps out=_dd_pspl; by base_table varname year; run;
    title  "Numeric means by year";
    title2 "A step between adjacent years is a definition or units change until proven otherwise.";
    proc sgpanel data=_dd_pspl;
      panelby varname / columns=3 rows=3 uniscale=none novarname headerattrs=(size=7);
      series x=year y=mean / markers lineattrs=(thickness=2);
      colaxis label='Year' grid;
      rowaxis label='Mean' grid;
    run;
    title;
  %end;
%mend dd_panel_stats;

/*-----------------------------------------------------------------------------
  %DD_STACKYEARS -- a SET across years that refuses to fail silently.

  Before generating anything it checks DD_PANEL_VARS and:
    - ABORTS on a type change, because the SET would error anyway and the
      message you get here is more useful than the one SAS gives you
    - GENERATES the LENGTH statements for every character variable whose
      length varies across years, which is the fix for the truncation that
      SAS will not warn you about
    - tags every row with its source dataset and year, so a pooled analysis
      can always be decomposed back to the year it came from

  table= the BASE table name as it appears in DD_INVENTORY, so a mid-panel
  rename is handled for you.
-----------------------------------------------------------------------------*/
%macro dd_stackyears(table=,out=,inv=dd_inventory,panel=dd_panel_vars,
                     keep=,where=,force=N);
  %local memlist lenstmts ntype;
  %if %dd_dsexist(&inv)=0 %then %do;
    %dd_warn(&inv not found - run %nrstr(%dd_inventory) first.); %return;
  %end;

  %let ntype=0;
  %if %dd_dsexist(&panel) %then %do;
    proc sql noprint;
      select count(*) into :ntype trimmed
      from &panel where upcase(base_table)=%upcase("&table") and n_types > 1;
    quit;
  %end;

  %if &ntype > 0 and %upcase(&force) ne Y %then %do;
    %dd_warn(&table has &ntype variable(s) whose TYPE changes across years.);
    %dd_warn(A SET would ERROR. Fix with an explicit PUT/INPUT per year, or rerun with force=Y to see the error.);
    proc print data=&panel noobs label;
      where upcase(base_table)=%upcase("&table") and n_types > 1;
      var varname first_year last_year n_types panel_flag;
      title "Type changes blocking the stack of &table";
    run;
    title;
    %return;
  %end;

  %let memlist=;
  proc sql noprint;
    select catx('.',libname,memname) into :memlist separated by ' '
    from &inv where upcase(base_table)=%upcase("&table")
    order by year;
  quit;
  %if %length(&memlist)=0 %then %do;
    %dd_warn(No members found for base table &table in &inv); %return;
  %end;

  /* the fix for silent truncation: declare the widest length seen */
  %let lenstmts=;
  %if %dd_dsexist(&panel) %then %do;
    proc sql noprint;
      select cats('length ',varname,' $',max_length,';')
        into :lenstmts separated by ' '
      from &panel
      where upcase(base_table)=%upcase("&table") and n_lengths > 1;
    quit;
  %end;

  /* KEEP is applied on OUTPUT, not as a dataset option on the SET list: a
     dataset option there would attach to the last member only, and the
     source-tracking variables do not exist in the inputs at all.           */
  data &out %if %length(&keep) %then (keep=&keep _source_dataset _source_year);;
    length _source_dataset $41 _source_year 8;
    &lenstmts
    set &memlist indsname=_dd_ds;
    _source_dataset = _dd_ds;
    _source_year    = input(compress(scan(_dd_ds,1,'.'),,'kd'),?? best12.);
    %if %length(&where) %then if &where;;
    label _source_dataset='Year library and member this row came from'
          _source_year   ='Year this row came from';
  run;

  %dd_note(Stacked %dd_n(&memlist) year members into &out: %dd_nobs(&out) rows.);
  %if %length(&lenstmts) %then
    %dd_note(LENGTH statements were generated to prevent truncation: &lenstmts);
%mend dd_stackyears;
