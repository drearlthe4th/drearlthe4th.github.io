/*=============================================================================
  DD_01_OVERVIEW.SAS
  (1) Data overview: shape, columns, data types
  (2) Missing values analysis, including the kinds of "missing" that a plain
      NMISS count silently ignores.
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_META -- table shape and the column-level skeleton of the dictionary.
  Reads only the dictionary views: zero passes over the data.
-----------------------------------------------------------------------------*/
%macro dd_meta(lib=,mem=,outtab=dd_tables,outcol=dd_columns,append=Y);

  proc sql noprint;
    create table _dd_t as
    select libname, memname, memtype, nobs, nvar, obslen, crdate, modate,
           filesize, compress, encrypt, num_character, num_numeric,
           calculated nobs * calculated obslen as bytes_uncompressed format=sizekmg10.2
    from dictionary.tables
    where libname=%upcase("&lib") and memname=%upcase("&mem");

    create table _dd_c as
    select libname, memname, name as varname length=32, varnum, type, length,
           format, informat, label, npos, sortedby
    from dictionary.columns
    where libname=%upcase("&lib") and memname=%upcase("&mem")
    order by varnum;
  quit;

  data _dd_c;
    set _dd_c;
    length dataset $41 vartype $9 date_flag $12 id_flag $3 name_issue $60;
    dataset = catx('.',libname,memname);
    vartype = ifc(type='num','Numeric','Character');

    /* Date detection is two-sided on purpose. A CMS extract may carry a real
       SAS date with a DATE9. format, OR an unformatted numeric holding
       YYYYMMDD, OR a character string 'YYYY-MM-DD'. Only the first is a date
       to SAS; the other two silently behave as a number and a string.        */
    if prxmatch('/^(DATE|MMDDYY|DDMMYY|YYMMDD|JULIAN|MONYY|WORDDATE|B8601DA|E8601DA|IS8601DA|DTDATE|DATETIME|B8601DT|E8601DT)/i', strip(format)) then date_flag='FORMATTED';
    else if prxmatch('/(_DT$|_DATE$|DATE|_DAY$|^DOB|_DOB|ADMSN|DSCHRG|SRVC|FROM_DT|THRU_DT)/i',
                strip(varname)) then date_flag='NAME_ONLY';
    else date_flag='';

    id_flag = ifc(prxmatch("&DD_IDPATTERN",strip(varname)),'YES','NO');

    /* Names > 30 chars break PROC MEANS AUTONAME suffixes and the ODS
       "F_<name>" columns used by the value catalog. Flag, do not fail.       */
    name_issue='';
    if length(strip(varname)) > 30 then
        name_issue='NAME>30 CHARS - excluded from stats/value catalog';
    else if type='char' and length >= 200 then
        name_issue='Long character field - possible free text';
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&outtab) %then %do;
    proc append base=&outtab data=_dd_t force; run;
    proc append base=&outcol data=_dd_c force; run;
  %end;
  %else %do;
    data &outtab; set _dd_t; run;
    data &outcol; set _dd_c; run;
  %end;

  %dd_note(&lib..&mem: %dd_nobs(&lib..&mem) rows.);
%mend dd_meta;

/*-----------------------------------------------------------------------------
  %DD_MISSING -- one full pass, every flavor of missing.

  For NUMERIC variables:
      n_miss        . (ordinary missing)
      n_special     .A - .Z and ._  (CMS files use these; NMISS counts them
                                     as missing but you cannot tell which)
      n_zero        exact zeros -- for payment/cost variables a zero is a
                    real "no payment", not a missing, and treating the two
                    alike is the single most common cost-analysis error
      n_negative    negatives -- legitimate on adjustment claims, a red flag
                    almost anywhere else
  For CHARACTER variables:
      n_blank       '' or all-blank
      n_sentinel    values in &DD_SENTINELS -- present but semantically missing
      n_untrimmed   values with leading blanks (join killers)
      n_mixedcase   values that are neither all-upper nor all-lower
      maxlen_used   longest value actually stored; if it equals the declared
                    LENGTH the field is probably truncated
-----------------------------------------------------------------------------*/
%macro dd_missing(lib=,mem=,out=dd_missing,append=Y);
  %local nnum nchar numlist charlist i;

  %dd_getvars(lib=&lib,mem=&mem,type=num, out=_DDNUM, maxlen=32);
  %dd_getvars(lib=&lib,mem=&mem,type=char,out=_DDCHR, maxlen=32);
  %let numlist=&_DDNUM; %let charlist=&_DDCHR;
  %let nnum=%dd_n(&numlist); %let nchar=%dd_n(&charlist);

  %if &nnum=0 and &nchar=0 %then %do;
    %dd_warn(&lib..&mem has no columns - missing analysis skipped.); %return;
  %end;

  data _dd_miss(keep=dataset varname vartype nobs n_nonmiss n_miss n_special
                     n_zero n_negative n_blank n_sentinel n_untrimmed
                     n_mixedcase maxlen_used declared_len pct_miss pct_usable);
    length dataset $41 varname $32 vartype $9;
    retain dataset "&lib..&mem";
    set &lib..&mem end=_dd_eof nobs=_dd_nobs;

    %if &nnum>0 %then %do;
      array _n[*]   &numlist;
      array _nm[&nnum] _temporary_;
      array _ns[&nnum] _temporary_;
      array _nz[&nnum] _temporary_;
      array _ng[&nnum] _temporary_;
      if _n_=1 then do _i=1 to &nnum;
        _nm[_i]=0; _ns[_i]=0; _nz[_i]=0; _ng[_i]=0;
      end;
      do _i=1 to dim(_n);
        if missing(_n[_i]) then do;
          _nm[_i]+1;
          if _n[_i] ne . then _ns[_i]+1;   /* .A-.Z and ._ sort around . */
        end;
        else do;
          if _n[_i]=0 then _nz[_i]+1;
          else if _n[_i]<0 then _ng[_i]+1;
        end;
      end;
    %end;

    %if &nchar>0 %then %do;
      array _c[*] &charlist;
      array _cb[&nchar] _temporary_;
      array _cs[&nchar] _temporary_;
      array _cu[&nchar] _temporary_;
      array _cx[&nchar] _temporary_;
      array _cl[&nchar] _temporary_;
      if _n_=1 then do _j=1 to &nchar;
        _cb[_j]=0; _cs[_j]=0; _cu[_j]=0; _cx[_j]=0; _cl[_j]=0;
      end;
      do _j=1 to dim(_c);
        if missing(_c[_j]) then _cb[_j]+1;
        else do;
          if upcase(strip(_c[_j])) in (&DD_SENTINELS) then _cs[_j]+1;
          if _c[_j] ne left(_c[_j]) then _cu[_j]+1;
          if strip(_c[_j]) ne upcase(strip(_c[_j]))
             and strip(_c[_j]) ne lowcase(strip(_c[_j])) then _cx[_j]+1;
          _cl[_j]=max(_cl[_j],lengthn(_c[_j]));
        end;
      end;
    %end;

    if _dd_eof then do;
      nobs=_dd_nobs;
      %if &nnum>0 %then %do;
        do _i=1 to dim(_n);
          varname=vname(_n[_i]); vartype='Numeric';
          declared_len=vlength(_n[_i]);
          n_miss=_nm[_i]; n_special=_ns[_i]; n_zero=_nz[_i]; n_negative=_ng[_i];
          call missing(n_blank,n_sentinel,n_untrimmed,n_mixedcase,maxlen_used);
          n_nonmiss = nobs - n_miss;
          pct_miss   = 100*n_miss/max(nobs,1);
          pct_usable = 100*(n_nonmiss)/max(nobs,1);
          output;
        end;
      %end;
      %if &nchar>0 %then %do;
        do _j=1 to dim(_c);
          varname=vname(_c[_j]); vartype='Character';
          declared_len=vlength(_c[_j]);
          n_blank=_cb[_j]; n_sentinel=_cs[_j]; n_untrimmed=_cu[_j];
          n_mixedcase=_cx[_j]; maxlen_used=_cl[_j];
          call missing(n_special,n_zero,n_negative);
          n_miss    = n_blank;
          n_nonmiss = nobs - n_miss;
          /* usable strips the sentinel codes as well as the blanks */
          pct_miss   = 100*n_miss/max(nobs,1);
          pct_usable = 100*(nobs - n_blank - n_sentinel)/max(nobs,1);
          output;
        end;
      %end;
    end;
  run;

  data _dd_miss;
    set _dd_miss;
    length quality_flag $80;
    quality_flag='';
    if pct_miss >= 100                       then quality_flag='EMPTY - 100% missing';
    else if pct_miss >= 95                   then quality_flag='NEARLY EMPTY - >=95% missing';
    else if pct_miss >= 50                   then quality_flag='HEAVY MISSING - >=50%';
    if n_special > 0 then quality_flag=catx('; ',quality_flag,'has SAS special missing (.A-.Z)');
    if n_sentinel > 0 then quality_flag=catx('; ',quality_flag,'has text sentinels (NA/UNK/~)');
    if vartype='Character' and maxlen_used=declared_len and declared_len>1
       then quality_flag=catx('; ',quality_flag,'values reach declared length - possible truncation');
    if n_untrimmed > 0 then quality_flag=catx('; ',quality_flag,'leading blanks - will break joins');
    if n_mixedcase > 0 then quality_flag=catx('; ',quality_flag,'mixed case - will break exact matches');
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_miss force; run;
  %end;
  %else %do; data &out; set _dd_miss; run; %end;

  /*---- visualization: missing % by variable -------------------------------*/
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    proc sort data=_dd_miss out=_dd_missp; by descending pct_miss; run;
    data _dd_missp;
      set _dd_missp;
      if pct_miss > 0;              /* only variables that have a problem */
      if _n_ <= 60;                 /* worst 60 fit on a readable page    */
      length band $22;
      if      pct_miss >= 95 then band='4: >=95% (unusable)';
      else if pct_miss >= 50 then band='3: 50-95%';
      else if pct_miss >= 20 then band='2: 20-50%';
      else                        band='1: <20%';
    run;
    %if %dd_nobs(_dd_missp) > 0 %then %do;
      title  "Missing Values - &lib..&mem";
      title2 "Worst 60 variables. Variables with zero missing are omitted.";
      proc sgplot data=_dd_missp noautolegend;
        hbar varname / response=pct_miss group=band
                       categoryorder=respdesc datalabel datalabelfmt=5.1;
        refline 5 20 50 / axis=x lineattrs=(pattern=shortdash color=gray)
                          label=('5%' '20%' '50%') labelloc=inside;
        xaxis label='Percent missing' values=(0 to 100 by 10) grid;
        yaxis label='Variable' display=(nolabel)
              valueattrs=(size=7) fitpolicy=none;
        keylegend / title='Severity' position=bottomright location=inside across=1;
      run;
      title;
    %end;
    %else %dd_note(&lib..&mem: no missing values anywhere - chart skipped.);

    /*---- companion view: what fraction of each variable is actually usable */
    proc sort data=_dd_miss out=_dd_usable; by pct_usable; run;
    data _dd_usable; set _dd_usable; if _n_<=40; run;
    %if %dd_nobs(_dd_usable) > 0 %then %do;
      title  "Usable data by variable - &lib..&mem";
      title2 "Usable = non-missing AND not a text sentinel (NA/UNK/~). Where the two differ, NMISS understates the problem.";
      proc sgplot data=_dd_usable;
        hbarparm category=varname response=pct_usable / name='u'
                 legendlabel='Usable %' fillattrs=(color=cx4c72b0);
        scatter y=varname x=pct_miss / name='m' legendlabel='Missing %'
                 markerattrs=(symbol=circlefilled color=cxc44e52 size=7);
        xaxis label='Percent' values=(0 to 100 by 10) grid;
        yaxis display=(nolabel) valueattrs=(size=7) fitpolicy=none;
        keylegend 'u' 'm' / position=bottom;
      run;
      title;
    %end;
  %end;
%mend dd_missing;
