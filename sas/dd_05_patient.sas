/*=============================================================================
  DD_05_PATIENT.SAS
  (10) Date profiling
  (11) Patient-level rollups
  (12) Cross-dataset linkage (Medicare <-> memory)
  (13) Duplicate key diagnostics
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_DATES -- profile every candidate date variable.

  In CMS extracts the same calendar concept appears in three incompatible
  storage forms and only one of them is a date to SAS:
      a real SAS date         DATE9. formatted, days since 1960
      an integer YYYYMMDD     unformatted numeric, 20180314
      a character string      '2018-03-14' or '03/14/2018'
  Subtracting two of these, or comparing across two files that disagree, is a
  wrong answer that raises no error. This macro says which form each variable
  is actually in, and flags impossible and future values.
-----------------------------------------------------------------------------*/
%macro dd_dates(lib=,mem=,out=dd_dates,append=Y,cols=dd_columns);
  %local dvars nd _DDDT;
  %let _DDDT=;
  proc sql noprint;
    select strip(varname) into :_DDDT separated by ' '
    from &cols
    where dataset="&lib..&mem" and type='num' and date_flag ne ''
      and length(strip(varname)) <= 30;
  quit;
  %let dvars=&_DDDT; %let nd=%dd_n(&dvars);
  %if &nd=0 %then %do;
    %dd_note(&lib..&mem: no numeric date candidates found.); %return;
  %end;

  data _dd_dt(keep=dataset varname n nmiss vmin vmax storage_form
                   n_sas_plausible n_ymd_plausible n_future n_before1900
                   n_impossible_ymd pct_sas pct_ymd);
    length dataset $41 varname $32 storage_form $34;
    retain dataset "&lib..&mem";
    set &lib..&mem end=eof;
    array _d[*] &dvars;
    array _n[&nd] _temporary_;  array _m[&nd] _temporary_;
    array _lo[&nd] _temporary_; array _hi[&nd] _temporary_;
    array _sp[&nd] _temporary_; array _yp[&nd] _temporary_;
    array _fu[&nd] _temporary_; array _b1[&nd] _temporary_;
    array _im[&nd] _temporary_;
    if _n_=1 then do _i=1 to &nd;
      _n[_i]=0; _m[_i]=0; _sp[_i]=0; _yp[_i]=0; _fu[_i]=0; _b1[_i]=0; _im[_i]=0;
    end;
    do _i=1 to dim(_d);
      if missing(_d[_i]) then _m[_i]+1;
      else do;
        _n[_i]+1;
        _lo[_i]=min(_lo[_i],_d[_i]); _hi[_i]=max(_hi[_i],_d[_i]);
        /* plausible as a SAS date: 01JAN1900 .. 31DEC2040 */
        if -21915 <= _d[_i] <= 29585 then do;
          _sp[_i]+1;
          if _d[_i] > today() then _fu[_i]+1;
        end;
        else if _d[_i] < -21915 then _b1[_i]+1;
        /* plausible as YYYYMMDD */
        if 19000101 <= _d[_i] <= 20991231 then do;
          _yy=int(_d[_i]/10000);
          _mm=int(mod(_d[_i],10000)/100);
          _dd=mod(_d[_i],100);
          if 1<=_mm<=12 and 1<=_dd<=31 then do;
            _yp[_i]+1;
            if mdy(_mm,_dd,_yy) > today() then _fu[_i]+1;
          end;
          else _im[_i]+1;
        end;
      end;
    end;
    if eof then do _i=1 to dim(_d);
      varname=vname(_d[_i]);
      n=_n[_i]; nmiss=_m[_i]; vmin=_lo[_i]; vmax=_hi[_i];
      n_sas_plausible=_sp[_i]; n_ymd_plausible=_yp[_i];
      n_future=_fu[_i]; n_before1900=_b1[_i]; n_impossible_ymd=_im[_i];
      pct_sas = 100*n_sas_plausible/max(n,1);
      pct_ymd = 100*n_ymd_plausible/max(n,1);
      if      n=0                 then storage_form='ALL MISSING';
      else if pct_ymd >= 99       then storage_form='INTEGER YYYYMMDD - not a SAS date';
      else if pct_sas >= 99       then storage_form='SAS date (days since 1960)';
      else                             storage_form='MIXED / UNCLEAR - inspect before use';
      output;
    end;
  run;

  data _dd_dt;
    set _dd_dt;
    length date_flagging $110 min_as_date $11 max_as_date $11;
    if storage_form='SAS date (days since 1960)' then do;
      min_as_date=put(vmin,date9.); max_as_date=put(vmax,date9.);
    end;
    else if storage_form='INTEGER YYYYMMDD - not a SAS date' then do;
      min_as_date=put(vmin,z8.); max_as_date=put(vmax,z8.);
    end;
    date_flagging='';
    if n_future > 0 then date_flagging=catx('; ',date_flagging,
        cats(put(n_future,comma12.),' value(s) in the future'));
    if n_before1900 > 0 then date_flagging=catx('; ',date_flagging,
        cats(put(n_before1900,comma12.),' value(s) before 1900'));
    if n_impossible_ymd > 0 then date_flagging=catx('; ',date_flagging,
        cats(put(n_impossible_ymd,comma12.),' impossible YYYYMMDD value(s)'));
    if storage_form='MIXED / UNCLEAR - inspect before use' then
        date_flagging=catx('; ',date_flagging,
        'storage form is not consistent - do NOT subtract this from another date variable');
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_dt force; run;
  %end;
  %else %do; data &out; set _dd_dt; run; %end;
%mend dd_dates;

/*-----------------------------------------------------------------------------
  %DD_PATIENT -- patient-level rollups.

  A row in a claims file is a claim (or a claim line, or a fill), not a
  person. Every statistic above this line describes rows; every statistic
  below it describes people. They answer different questions and they
  routinely disagree -- mean spend per claim and mean spend per beneficiary
  are not the same number and neither is "average cost".

  Parameters (all optional except id=):
    id=        person key                       e.g. BENE_ID
    claimid=   claim key, for claims-per-person e.g. CLM_ID
    drugvar=   product code, for drugs-per-person e.g. the NDC/ingredient var
    datevar=   service/fill date, for span and dates-per-person
    sumvars=   numeric variables to total per person (payments, days supply)
    catvars=   categorical variables to count distinct levels per person
-----------------------------------------------------------------------------*/
%macro dd_patient(lib=,mem=,id=,claimid=,drugvar=,datevar=,sumvars=,catvars=,
                  ptout=dd_pt,sumout=dd_patient_summary,append=Y);
  %local i v nsum;
  %if %length(&id)=0 %then %do;
    %dd_warn(dd_patient requires id= - skipped.); %return;
  %end;
  /* SQL builds names like nmiss_<var>; a 32-character ceiling applies */
  %do i=1 %to %dd_n(&sumvars);
    %if %length(%scan(&sumvars,&i,%str( ))) > 26 %then
      %dd_warn(sumvars entry %scan(&sumvars,&i,%str( )) is too long - rollup names would exceed 32 chars.);
  %end;
  %do i=1 %to %dd_n(&catvars);
    %if %length(%scan(&catvars,&i,%str( ))) > 21 %then
      %dd_warn(catvars entry %scan(&catvars,&i,%str( )) is too long - rollup names would exceed 32 chars.);
  %end;
  %if %dd_varexist(&lib..&mem,&id)=0 %then %do;
    %dd_warn(&id not found in &lib..&mem - patient rollup skipped.); %return;
  %end;

  proc sql;
    create table &ptout as
    select &id,
           count(*) as n_records label='Rows for this person'
      %if %length(&claimid) %then %do;
           ,count(distinct &claimid) as n_claims label='Distinct claims'
      %end;
      %if %length(&drugvar) %then %do;
           ,count(distinct &drugvar) as n_products label='Distinct products/codes'
      %end;
      %if %length(&datevar) %then %do;
           ,count(distinct &datevar) as n_service_days label='Distinct service dates'
           ,min(&datevar) as first_date
           ,max(&datevar) as last_date
      %end;
      %if %length(&catvars) %then %do i=1 %to %dd_n(&catvars);
           %let v=%scan(&catvars,&i,%str( ));
           ,count(distinct &v) as n_distinct_&v
      %end;
      %if %length(&sumvars) %then %do i=1 %to %dd_n(&sumvars);
           %let v=%scan(&sumvars,&i,%str( ));
           ,sum(&v) as sum_&v
           ,mean(&v) as mean_&v
           ,nmiss(&v) as nmiss_&v
      %end;
    from &lib..&mem
    where not missing(&id)
    group by &id;
  quit;

  %if %length(&datevar) %then %do;
    data &ptout;
      set &ptout;
      followup_days = last_date - first_date + 1;
      label followup_days='Days from first to last observed record (inclusive)';
    run;
  %end;

  /*---- distribution of the person-level measures --------------------------*/
  %local ptvars;
  %let ptvars=;
  proc sql noprint;
    select strip(name) into :ptvars separated by ' '
    from dictionary.columns
    where libname='WORK' and upcase(memname)=%upcase("&ptout")
      and type='num' and upcase(name) ne %upcase("&id");
  quit;
  %if %length(&ptvars)=0 %then %do;
    %dd_warn(&ptout has no numeric rollups to summarize.); %return;
  %end;

  ods exclude all;
  proc means data=&ptout n nmiss mean std min p25 median p75 p95 p99 max sum
             stackodsoutput;
    var &ptvars;
    ods output summary=_dd_ptsum;
  run;
  ods exclude none;

  data _dd_ptsum;
    length dataset $41 id_var $32;
    retain dataset "&lib..&mem" id_var "&id";
    set _dd_ptsum;
    n_persons = %dd_nobs(&ptout);
  run;

  /*---- concentration: how much of the file is a handful of people? --------*/
  proc sort data=&ptout out=_dd_conc; by descending n_records; run;
  data _dd_conc;
    set _dd_conc nobs=_np;
    retain _cum 0;
    if _n_=1 then do;
      do _p=1 to _np; set &ptout(keep=n_records rename=(n_records=_r)) point=_p;
        _tot+_r; end;
    end;
    _cum+n_records;
    pct_persons = 100*_n_/_np;
    pct_records = 100*_cum/_tot;
    keep pct_persons pct_records;
  run;

  proc sql noprint;
    select max(pct_records) into :_c1  from _dd_conc where pct_persons <=  1;
    select max(pct_records) into :_c5  from _dd_conc where pct_persons <=  5;
    select max(pct_records) into :_c10 from _dd_conc where pct_persons <= 10;
  quit;

  data _dd_ptmeta;
    length dataset $41 metric $60 value 8 note $120;
    dataset="&lib..&mem";
    metric="Persons (distinct &id)";           value=%dd_nobs(&ptout);            note=''; output;
    metric='Rows';                              value=%dd_nobs(&lib..&mem);        note=''; output;
    metric='Rows per person (overall mean)';    value=%dd_nobs(&lib..&mem)/max(%dd_nobs(&ptout),1);
      note='Row-level means describe claims, not people'; output;
    metric='% of rows from the top 1% of persons';  value=&_c1;
      note='High concentration means row-level averages describe a few heavy utilizers'; output;
    metric='% of rows from the top 5% of persons';  value=&_c5;  note=''; output;
    metric='% of rows from the top 10% of persons'; value=&_c10; note=''; output;
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&sumout) %then %do;
    proc append base=&sumout data=_dd_ptsum force; run;
    proc append base=dd_patient_meta data=_dd_ptmeta force; run;
  %end;
  %else %do;
    data &sumout; set _dd_ptsum; run;
    data dd_patient_meta; set _dd_ptmeta; run;
  %end;

  /*---- visualization -------------------------------------------------------*/
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    data _dd_ptlong(keep=_name_ _value_);
      set &ptout;
      array _v[*] &ptvars;
      length _name_ $32;
      do _i=1 to dim(_v);
        _name_=vname(_v[_i]); _value_=_v[_i];
        if not missing(_value_) then output;
      end;
    run;
    title  "Patient-level distributions - &lib..&mem (key: &id)";
    title2 "One observation per person. These are the denominators every per-patient rate needs.";
    proc sgpanel data=_dd_ptlong;
      panelby _name_ / columns=3 rows=3 uniscale=none novarname headerattrs=(size=8);
      histogram _value_ / scale=percent;
      colaxis grid; rowaxis grid label='Percent of persons';
    run;

    title  "Utilization concentration - &lib..&mem";
    title2 "Diagonal = every person contributes equally. The further the curve bows, the less a row-level average means.";
    proc sgplot data=_dd_conc;
      series x=pct_persons y=pct_records / lineattrs=(thickness=2 color=cx4c72b0);
      lineparm x=0 y=0 slope=1 / lineattrs=(pattern=shortdash color=gray)
               legendlabel='Perfect equality';
      xaxis label='Cumulative % of persons (ranked by row count)' grid values=(0 to 100 by 10);
      yaxis label='Cumulative % of rows' grid values=(0 to 100 by 10);
    run;
    title;
  %end;
%mend dd_patient;

/*-----------------------------------------------------------------------------
  %DD_LINK -- do two datasets IN THE SAME ENCLAVE actually join?

  WITHIN ONE VM ONLY. The Medicare VM and the MEMORY/Medicaid VM are isolated
  from each other and their populations are not linkable; there is no code
  here that could join across them and there should not be. The live question
  this macro answers is MEMORY (cannabis dispensations) against Medicaid,
  both of which sit in VM 2.

  Run it before any analysis that assumes the join works. Unlinked records on
  either side are the population that analysis will silently drop, and in a
  registry-to-claims link that number is usually large and never random --
  cash-paying and commercially insured registry patients have no Medicaid
  record at all, so the linked subset is a selected population, not a sample.
-----------------------------------------------------------------------------*/
%macro dd_link(liba=,mema=,ida=,libb=,memb=,idb=,out=dd_linkage,append=Y);
  %if %dd_varexist(&liba..&mema,&ida)=0 or %dd_varexist(&libb..&memb,&idb)=0
    %then %do;
      %dd_warn(Linkage skipped: &ida or &idb not found.); %return;
    %end;

  proc sql;
    create table _dd_ia as select distinct &ida  as _id from &liba..&mema
      where not missing(&ida);
    create table _dd_ib as select distinct &idb  as _id from &libb..&memb
      where not missing(&idb);
    create table _dd_both as
      select a._id from _dd_ia a inner join _dd_ib b on a._id=b._id;
  quit;

  data _dd_link;
    length side $60 comparison $90;
    n_a    = %dd_nobs(_dd_ia);
    n_b    = %dd_nobs(_dd_ib);
    n_both = %dd_nobs(_dd_both);
    comparison = "&liba..&mema (&ida) vs &libb..&memb (&idb)";
    side='Distinct IDs in A';        n=n_a;          pct=100;                     output;
    side='Distinct IDs in B';        n=n_b;          pct=100;                     output;
    side='In both (linkable)';       n=n_both;       pct=100*n_both/max(n_a,1);   output;
    side='In A only (unlinked)';     n=n_a-n_both;   pct=100*(n_a-n_both)/max(n_a,1); output;
    side='In B only (unlinked)';     n=n_b-n_both;   pct=100*(n_b-n_both)/max(n_b,1); output;
    keep comparison side n pct;
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_link force; run;
  %end;
  %else %do; data &out; set _dd_link; run; %end;

  %if %upcase(&DD_GRAPHS)=Y %then %do;
    title  "Cross-dataset linkage";
    title2 "Unlinked records on either side are the population your analysis will silently drop.";
    proc sgplot data=_dd_link;
      hbarparm category=side response=n / datalabel
               fillattrs=(color=cx4c72b0);
      xaxis label='Distinct identifiers' grid;
      yaxis display=(nolabel);
    run;
    title;
  %end;
%mend dd_link;

/*-----------------------------------------------------------------------------
  %DD_DUPS -- is the key you think is unique actually unique?
  Pass the key you intend to merge on. This is the cheapest way to find out
  that a "one row per beneficiary" file has 1.03 rows per beneficiary.
-----------------------------------------------------------------------------*/
%macro dd_dups(lib=,mem=,key=,out=dd_duplicates,append=Y);
  %if %length(&key)=0 %then %return;
  proc sort data=&lib..&mem(keep=&key) out=_dd_k; by &key; run;
  data _dd_kd;
    set _dd_k; by &key;
    if not (first.%scan(&key,-1,%str( )) and last.%scan(&key,-1,%str( )));
  run;
  proc sql noprint;
    select count(*) into :_ndup trimmed from _dd_kd;
    select count(*) into :_nrow trimmed from _dd_k;
  quit;
  proc sort data=_dd_k out=_dd_ku nodupkey; by &key; run;

  data _dd_dup;
    length dataset $41 keyvars $200 verdict $80;
    dataset="&lib..&mem"; keyvars="&key";
    n_rows        = &_nrow;
    n_unique_keys = %dd_nobs(_dd_ku);
    n_dup_rows    = &_ndup;
    rows_per_key  = n_rows/max(n_unique_keys,1);
    pct_dup_rows  = 100*n_dup_rows/max(n_rows,1);
    if n_dup_rows=0 then verdict='UNIQUE - safe to merge one-to-one on this key';
    else verdict='NOT UNIQUE - a one-to-one merge on this key will silently drop or fan out rows';
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_dup force; run;
  %end;
  %else %do; data &out; set _dd_dup; run; %end;
%mend dd_dups;

/*-----------------------------------------------------------------------------
  %DD_XWALK -- linkage through a crosswalk table.

  Use this instead of %DD_LINK whenever the two files do not share an
  identifier and a crosswalk carries the mapping. In VM 2 that is MEMORY
  (registry patient id) -> crosswalk -> Medicaid (MSIS id).

  A crosswalk introduces three failure modes that a direct join does not, and
  all three are silent:

    COVERAGE   the crosswalk does not contain every id on either side. Ids
               missing from it are unlinkable, and they are not missing at
               random -- they are usually the people who were never matched.
    FAN-OUT    one registry patient mapping to several Medicaid ids (or the
               reverse) turns a one-to-one merge into a many-to-many one and
               silently multiplies rows. Every downstream count is then wrong
               in the same direction.
    STALENESS  the crosswalk contains ids that no longer appear in either
               source file. Harmless to the join, but it inflates any
               match-rate computed from the crosswalk alone rather than from
               the source files.

  This macro measures all three and computes the only match rate that means
  anything: end to end, source A -> crosswalk -> source B, counting only ids
  that exist at every step.

  liba/mema/ida  source A and its id           (e.g. MEMORY dispensing, PATIENT_ID)
  libb/memb/idb  source B and its id           (e.g. Medicaid eligibility, MSIS_ID)
  xlib/xmem      the crosswalk table
  xa / xb        the crosswalk's columns holding A's id and B's id
-----------------------------------------------------------------------------*/
%macro dd_xwalk(liba=,mema=,ida=, libb=,memb=,idb=,
                xlib=,xmem=,xa=,xb=, out=dd_linkage, append=Y);

  %if %dd_dsexist(&xlib..&xmem)=0 %then %do;
    %dd_warn(Crosswalk &xlib..&xmem not found - linkage skipped.); %return;
  %end;
  %if %dd_varexist(&xlib..&xmem,&xa)=0 or %dd_varexist(&xlib..&xmem,&xb)=0
    %then %do;
      %dd_warn(&xa or &xb not found in the crosswalk - linkage skipped.); %return;
    %end;
  %if %dd_varexist(&liba..&mema,&ida)=0 or %dd_varexist(&libb..&memb,&idb)=0
    %then %do;
      %dd_warn(&ida or &idb not found in its source file - linkage skipped.); %return;
    %end;

  proc sql;
    create table _dd_ia as
      select distinct &ida as id_a from &liba..&mema where not missing(&ida);
    create table _dd_ib as
      select distinct &idb as id_b from &libb..&memb where not missing(&idb);
    create table _dd_x as
      select distinct &xa as id_a, &xb as id_b
      from &xlib..&xmem
      where not missing(&xa) and not missing(&xb);
  quit;

  /* crosswalk shape: is it actually one to one? */
  proc sql;
    create table _dd_xfan as
      select id_a, count(distinct id_b) as n_b from _dd_x group by id_a;
    create table _dd_xfin as
      select id_b, count(distinct id_a) as n_a from _dd_x group by id_b;

    /* end to end: an id that exists in A, appears in the crosswalk, and whose
       partner actually exists in B                                          */
    create table _dd_e2e as
      select distinct a.id_a
      from _dd_ia a
        inner join _dd_x  x on a.id_a = x.id_a
        inner join _dd_ib b on x.id_b = b.id_b;

    create table _dd_e2eb as
      select distinct b.id_b
      from _dd_ib b
        inner join _dd_x  x on b.id_b = x.id_b
        inner join _dd_ia a on x.id_a = a.id_a;

    /* coverage of the crosswalk over each source */
    create table _dd_cova as
      select distinct a.id_a from _dd_ia a inner join _dd_x x on a.id_a=x.id_a;
    create table _dd_covb as
      select distinct b.id_b from _dd_ib b inner join _dd_x x on b.id_b=x.id_b;

    /* stale crosswalk rows: ids that appear in no source file */
    create table _dd_stalea as
      select distinct x.id_a from _dd_x x
      where x.id_a not in (select id_a from _dd_ia);
    create table _dd_staleb as
      select distinct x.id_b from _dd_x x
      where x.id_b not in (select id_b from _dd_ib);
  quit;

  proc sql noprint;
    select count(*) into :_fanout trimmed from _dd_xfan where n_b > 1;
    select count(*) into :_fanin  trimmed from _dd_xfin where n_a > 1;
    select max(n_b)  into :_maxb   trimmed from _dd_xfan;
    select max(n_a)  into :_maxa   trimmed from _dd_xfin;
  quit;

  data _dd_link;
    length comparison $150 side $62 note $130;
    comparison = "&liba..&mema (&ida) -> &xlib..&xmem -> &libb..&memb (&idb)";
    n_a    = %dd_nobs(_dd_ia);
    n_b    = %dd_nobs(_dd_ib);
    n_xa   = %dd_nobs(_dd_xfan);
    n_xb   = %dd_nobs(_dd_xfin);
    n_cova = %dd_nobs(_dd_cova);
    n_covb = %dd_nobs(_dd_covb);
    n_e2ea = %dd_nobs(_dd_e2e);
    n_e2eb = %dd_nobs(_dd_e2eb);

    side='A: distinct ids in source A';            n=n_a;    pct=100;
      note='denominator for the A-side match rate'; output;
    side='B: distinct ids in source B';            n=n_b;    pct=100;
      note='denominator for the B-side match rate'; output;

    side='A ids present in the crosswalk';         n=n_cova;
      pct=100*n_cova/max(n_a,1);
      note='crosswalk coverage of A; the rest are unlinkable'; output;
    side='B ids present in the crosswalk';         n=n_covb;
      pct=100*n_covb/max(n_b,1);
      note='crosswalk coverage of B'; output;

    side='A ids linked END TO END to a real B id'; n=n_e2ea;
      pct=100*n_e2ea/max(n_a,1);
      note='THE match rate. Everything else overstates it.'; output;
    side='B ids linked END TO END to a real A id'; n=n_e2eb;
      pct=100*n_e2eb/max(n_b,1);
      note='the same rate read from the other direction'; output;

    side='A ids with NO end-to-end link';          n=n_a-n_e2ea;
      pct=100*(n_a-n_e2ea)/max(n_a,1);
      note='the population a linked analysis silently drops'; output;

    side='A ids mapping to more than one B id';    n=&_fanout;
      pct=100*&_fanout/max(n_xa,1);
      note=cats('FAN-OUT. Worst case one A id maps to ',&_maxb,
                ' B ids. A one-to-one merge here multiplies rows.'); output;
    side='B ids mapping to more than one A id';    n=&_fanin;
      pct=100*&_fanin/max(n_xb,1);
      note=cats('FAN-IN. Worst case one B id maps to ',&_maxa,' A ids.'); output;

    side='Crosswalk A ids found in no source A';   n=%dd_nobs(_dd_stalea);
      pct=100*%dd_nobs(_dd_stalea)/max(n_xa,1);
      note='stale crosswalk rows; they inflate any match rate computed from the crosswalk alone'; output;
    side='Crosswalk B ids found in no source B';   n=%dd_nobs(_dd_staleb);
      pct=100*%dd_nobs(_dd_staleb)/max(n_xb,1);
      note='stale crosswalk rows'; output;

    keep comparison side n pct note;
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_link force; run;
  %end;
  %else %do; data &out; set _dd_link; run; %end;

  %if &_fanout > 0 or &_fanin > 0 %then %do;
    %dd_warn(Crosswalk is NOT one-to-one: &_fanout A ids fan out, &_fanin B ids fan in.);
    %dd_warn(Deduplicate or aggregate before merging, or row counts downstream will be inflated.);
  %end;
  %else %dd_note(Crosswalk is one-to-one on the ids that appear in it.);

  %if %upcase(&DD_GRAPHS)=Y %then %do;
    title  "Linkage through the crosswalk";
    title2 "Read the END TO END rows. Crosswalk coverage alone overstates the match rate, because a crosswalk row whose partner is not in the source file links nothing.";
    proc sgplot data=_dd_link(where=(index(side,'fan')=0 and index(side,'Crosswalk')=0));
      hbarparm category=side response=pct / datalabel datalabelfmt=5.1
               fillattrs=(color=cx4c72b0);
      xaxis label='Percent of that source''s distinct ids' grid values=(0 to 100 by 10);
      yaxis display=(nolabel) valueattrs=(size=8) fitpolicy=none;
    run;
    title;
  %end;
%mend dd_xwalk;
