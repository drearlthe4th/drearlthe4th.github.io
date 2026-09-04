/*=============================================================================
  DD_02_STATS.SAS
  (3) Descriptive statistics   (7) Outlier detection   (8) Feature distribution
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_NUMSTATS -- full descriptive statistics for every numeric variable.

  Implementation note: statistics are requested with OUTPUT ... / AUTONAME
  rather than STACKODSOUTPUT. AUTONAME builds column names from statistic
  keywords that this program supplies, so the reshape below cannot break when
  a SAS release renames an ODS column. The reshape splits <VAR>_<STAT> from
  the right, which is why variable names longer than 30 characters are
  excluded upstream (AUTONAME would truncate and collide).

  QMETHOD: on very large files PROC MEANS falls back to the P2 approximation
  for quantiles. Pass qmethod=OS to force exact order statistics, at the cost
  of memory. Leave blank to let SAS decide.
-----------------------------------------------------------------------------*/
%macro dd_numstats(lib=,mem=,out=dd_numstats,append=Y,qmethod=);
  %local numlist nnum;
  %dd_getvars(lib=&lib,mem=&mem,type=num,out=_DDNUM,maxlen=30);
  %let numlist=&_DDNUM; %let nnum=%dd_n(&numlist);
  %if &nnum=0 %then %do;
    %dd_warn(&lib..&mem has no numeric variables - statistics skipped.); %return;
  %end;

  proc means data=&lib..&mem noprint %if %length(&qmethod) %then qmethod=&qmethod;;
    var &numlist;
    output out=_dd_wide(drop=_type_ _freq_)
      n= nmiss= mean= std= median= min= max= sum=
      q1= q3= p1= p5= p95= p99= skew= kurt= cv= / autoname;
  run;

  proc transpose data=_dd_wide out=_dd_long(rename=(col1=value)); run;

  data _dd_long;
    set _dd_long;
    length varname $32 stat $12;
    stat    = scan(_name_,-1,'_');
    varname = substr(_name_,1,length(_name_)-length(stat)-1);
    keep varname stat value;
  run;

  proc sort data=_dd_long; by varname stat; run;
  proc transpose data=_dd_long out=_dd_stats(drop=_name_); by varname; id stat; var value; run;

  data _dd_stats;
    length dataset $41 varname $32;
    retain dataset "&lib..&mem";
    set _dd_stats;
    /* rename only where the name actually changes -- a case-only rename
       (Mean -> mean) is a no-op that some SAS releases reject               */
    rename N=n_nonmiss NMiss=n_miss StdDev=std Q1=p25 Q3=p75
           Skew=skewness Kurt=kurtosis;
  run;

  data _dd_stats;
    set _dd_stats;
    length shape $34 suggested_transform $34;
    iqr        = p75 - p25;
    range      = max - min;
    lower_fence_mild    = p25 - 1.5*iqr;
    upper_fence_mild    = p75 + 1.5*iqr;
    lower_fence_extreme = p25 - 3.0*iqr;
    upper_fence_extreme = p75 + 3.0*iqr;
    /* mean/median divergence is a faster read on skew than the moment itself */
    if median ne 0 then mean_median_ratio = mean/median;

    /* (8) FEATURE DISTRIBUTION -- shape classification and a transform hint */
    if      n_nonmiss <= 1         then shape='no variation';
    else if std = 0                then shape='CONSTANT';
    else if skewness > 2           then shape='severe right skew';
    else if skewness > 1           then shape='strong right skew';
    else if skewness > 0.5         then shape='moderate right skew';
    else if skewness < -2          then shape='severe left skew';
    else if skewness < -1          then shape='strong left skew';
    else if skewness < -0.5        then shape='moderate left skew';
    else                                shape='approximately symmetric';
    if kurtosis > 3 and shape='approximately symmetric'
       then shape='symmetric, heavy tailed';

    suggested_transform='none';
    if skewness > 1 and min >= 0 and max > 0 then do;
      if min = 0 then suggested_transform='log(x+1) or sqrt';
      else            suggested_transform='log(x)';
    end;
    else if skewness > 1 then suggested_transform='signed sqrt / Yeo-Johnson';
    else if skewness < -1 then suggested_transform='square or reflect+log';
    if std=0 then suggested_transform='drop - no information';
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_stats force; run;
  %end;
  %else %do; data &out; set _dd_stats; run; %end;

  /*---- visualization: skewness and spread ---------------------------------*/
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    data _dd_sk;
      set _dd_stats;
      where n_nonmiss > 0 and std > 0;
      length skewband $24;
      if      abs(skewness) > 2   then skewband='4: severe (>2)';
      else if abs(skewness) > 1   then skewband='3: strong (1-2)';
      else if abs(skewness) > 0.5 then skewband='2: moderate (0.5-1)';
      else                             skewband='1: near symmetric';
    run;
    %if %dd_nobs(_dd_sk) > 0 %then %do;
      title  "Feature distribution - skewness by variable (&lib..&mem)";
      title2 "Beyond +/-1, the mean stops describing the typical patient. Use the median.";
      proc sgplot data=_dd_sk;
        hbar varname / response=skewness group=skewband categoryorder=respdesc;
        refline -1 -0.5 0 0.5 1 / axis=x
                lineattrs=(pattern=shortdash color=gray);
        xaxis label='Skewness' grid;
        yaxis display=(nolabel) valueattrs=(size=7) fitpolicy=none;
        keylegend / title='Severity' position=bottom;
      run;

      title  "Feature distribution - coefficient of variation (&lib..&mem)";
      title2 "CV = std/mean. Above 1 the variable is dominated by its tail (typical of cost and utilization).";
      proc sgplot data=_dd_sk;
        hbar varname / response=cv categoryorder=respdesc
                       fillattrs=(color=cx55a868);
        refline 1 / axis=x lineattrs=(pattern=shortdash color=cxc44e52)
                    label='CV = 1' labelloc=inside;
        xaxis label='Coefficient of variation' grid;
        yaxis display=(nolabel) valueattrs=(size=7) fitpolicy=none;
      run;
      title;
    %end;
  %end;
%mend dd_numstats;

/*-----------------------------------------------------------------------------
  %DD_OUTLIERS -- one extra full pass that counts, per numeric variable:
      mild    : outside p25 - 1.5*IQR .. p75 + 1.5*IQR
      extreme : outside p25 - 3.0*IQR .. p75 + 3.0*IQR
      z3      : |x - mean| > 3*std
  IQR fences are reported first because the z-rule is computed from a mean and
  a standard deviation that the outliers themselves inflate; on a skewed cost
  variable the z-rule will find almost nothing while the IQR rule finds 8% of
  the file. Where the two disagree, believe the IQR.

  Requires DD_NUMSTATS to have run for this dataset.
-----------------------------------------------------------------------------*/
%macro dd_outliers(lib=,mem=,stats=dd_numstats,out=dd_outliers,append=Y);
  %local numlist nnum i v;
  %dd_getvars(lib=&lib,mem=&mem,type=num,out=_DDNUM,maxlen=30);
  %let numlist=&_DDNUM; %let nnum=%dd_n(&numlist);
  %if &nnum=0 %then %return;

  /* Fences for this dataset. They must be loaded in the SAME ORDER as the
     array &numlist (varnum order); dd_numstats stores them alphabetically,
     so an explicit position table is built and joined rather than trusting
     row order -- that mismatch is a silent wrong-answer bug, not an error.  */
  /* NODUPKEY guards against a second dd_numstats run having appended a
     duplicate row for this dataset, which would misalign the fence arrays */
  proc sort data=&stats(where=(dataset="&lib..&mem")) out=_dd_f0 nodupkey;
    by varname;
  run;
  %if %dd_nobs(_dd_f0)=0 %then %do;
    %dd_warn(No stats found for &lib..&mem - run %nrstr(%dd_numstats) first.); %return;
  %end;

  data _dd_ord;
    length varname $32;
    %do i=1 %to &nnum;
      varname="%scan(&numlist,&i,%str( ))"; pos=&i; output;
    %end;
  run;

  proc sql;
    create table _dd_fen as
    select o.pos, o.varname,
           s.lower_fence_mild, s.upper_fence_mild,
           s.lower_fence_extreme, s.upper_fence_extreme,
           s.mean as mu, s.std as sd
    from _dd_ord o left join _dd_f0 s
      on upcase(o.varname)=upcase(s.varname)
    order by o.pos;
  quit;

  data _dd_out(keep=dataset varname n_eval n_mild n_extreme n_z3
                    pct_mild pct_extreme pct_z3 min_outlier max_outlier);
    length dataset $41 varname $32;
    retain dataset "&lib..&mem";
    set &lib..&mem end=eof;
    array _v[*] &numlist;
    array _ne[&nnum] _temporary_;  array _n1[&nnum] _temporary_;
    array _n2[&nnum] _temporary_;  array _n3[&nnum] _temporary_;
    array _lo[&nnum] _temporary_;  array _hi[&nnum] _temporary_;
    array _flm[&nnum] _temporary_; array _fum[&nnum] _temporary_;
    array _fle[&nnum] _temporary_; array _fue[&nnum] _temporary_;
    array _fmu[&nnum] _temporary_; array _fsd[&nnum] _temporary_;
    if _n_=1 then do;
      do _p=1 to &nnum;
        set _dd_fen(keep=lower_fence_mild upper_fence_mild lower_fence_extreme
                         upper_fence_extreme mu sd) point=_p;
        _flm[_p]=lower_fence_mild; _fum[_p]=upper_fence_mild;
        _fle[_p]=lower_fence_extreme; _fue[_p]=upper_fence_extreme;
        _fmu[_p]=mu; _fsd[_p]=sd;
        _ne[_p]=0; _n1[_p]=0; _n2[_p]=0; _n3[_p]=0;
      end;
    end;
    do _i=1 to dim(_v);
      if not missing(_v[_i]) then do;
        _ne[_i]+1;
        if _v[_i] < _flm[_i] or _v[_i] > _fum[_i] then do;
          _n1[_i]+1;
          _lo[_i]=min(_lo[_i],_v[_i]); _hi[_i]=max(_hi[_i],_v[_i]);
        end;
        if _v[_i] < _fle[_i] or _v[_i] > _fue[_i] then _n2[_i]+1;
        if _fsd[_i] > 0 and abs(_v[_i]-_fmu[_i]) > 3*_fsd[_i] then _n3[_i]+1;
      end;
    end;
    if eof then do _i=1 to dim(_v);
      varname=vname(_v[_i]);
      n_eval=_ne[_i]; n_mild=_n1[_i]; n_extreme=_n2[_i]; n_z3=_n3[_i];
      pct_mild    = 100*n_mild   /max(n_eval,1);
      pct_extreme = 100*n_extreme/max(n_eval,1);
      pct_z3      = 100*n_z3     /max(n_eval,1);
      min_outlier=_lo[_i]; max_outlier=_hi[_i];
      output;
    end;
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_out force; run;
  %end;
  %else %do; data &out; set _dd_out; run; %end;

  /*---- visualization: outlier rate by variable ----------------------------*/
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    data _dd_outp; set _dd_out; where pct_mild > 0; run;
    %if %dd_nobs(_dd_outp) > 0 %then %do;
      title  "Outlier detection - IQR rule vs 3-sigma rule (&lib..&mem)";
      title2 "Blue = outside 1.5*IQR, dark = outside 3*IQR, marker = |z| > 3. A large gap means the distribution is skewed, not that the data are clean.";
      proc sgplot data=_dd_outp;
        hbarparm category=varname response=pct_mild / name='a'
                 legendlabel='Mild (1.5 x IQR)' fillattrs=(color=cx8fb4d9);
        hbarparm category=varname response=pct_extreme / name='b'
                 legendlabel='Extreme (3 x IQR)' fillattrs=(color=cx1f4e79)
                 barwidth=0.45;
        scatter y=varname x=pct_z3 / name='c' legendlabel='|z| > 3'
                 markerattrs=(symbol=diamondfilled color=cxc44e52 size=8);
        xaxis label='Percent of non-missing values flagged' grid;
        yaxis display=(nolabel) valueattrs=(size=7) fitpolicy=none;
        keylegend 'a' 'b' 'c' / position=bottom;
      run;
      title;
    %end;
  %end;
%mend dd_outliers;
