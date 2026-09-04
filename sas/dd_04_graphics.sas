/*=============================================================================
  DD_04_GRAPHICS.SAS
  (4) Univariate: histograms + box plots
  (5) Bivariate : scatter plots, pair plot, target panels, category box panels
  (6) Correlation: Pearson and Spearman heat maps + ranked pair table

  All of these run on the graphics SAMPLE, not the full file. A histogram of
  50,000 randomly drawn rows and a histogram of 400 million rows look the
  same; only the render time differs. Every COUNT in the dictionary is still
  computed on the full file -- sampling is confined to the pictures.
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_UNIVAR -- histogram + kernel density panels and box-plot panels.
  Variables are stacked into (name,value) long form so a single SGPANEL step
  renders any number of them, nine to a page, each with its own scale.
-----------------------------------------------------------------------------*/
%macro dd_univar(lib=,mem=,vars=,samp=dd_samp,maxvars=&DD_MAXPANELVARS,
                 logscale=N);
  %local numlist nnum;
  %if %length(&vars) %then %let numlist=&vars;
  %else %do;
    %dd_getvars(lib=&lib,mem=&mem,type=num,out=_DDNUM,exclid=Y,maxlen=30);
    %let numlist=&_DDNUM;
  %end;
  %let numlist=%dd_first(&numlist,&maxvars);
  %let nnum=%dd_n(&numlist);
  %if &nnum=0 %then %do;
    %dd_warn(&lib..&mem: no numeric variables to plot.); %return;
  %end;

  data _dd_ulong(keep=_name_ _value_ _logvalue_);
    set &samp;
    array _v[*] &numlist;
    length _name_ $32;
    do _i=1 to dim(_v);
      _name_=vname(_v[_i]); _value_=_v[_i];
      if not missing(_value_) then do;
        if _value_ > 0 then _logvalue_=log10(_value_);
        else _logvalue_=.;
        output;
      end;
    end;
  run;

  title  "Univariate distributions - &lib..&mem";
  title2 "Histogram with kernel density. Each panel has its own scale.";
  proc sgpanel data=_dd_ulong;
    panelby _name_ / columns=3 rows=3 uniscale=none novarname
                     headerattrs=(size=8);
    histogram _value_ / scale=percent;
    density   _value_ / type=kernel lineattrs=(color=cxc44e52 thickness=2);
    colaxis grid; rowaxis grid label='Percent';
  run;

  %if %upcase(&logscale)=Y %then %do;
    title2 "Log10 scale. Cost, utilization and count variables are readable here and unreadable above.";
    proc sgpanel data=_dd_ulong(where=(_logvalue_ ne .));
      panelby _name_ / columns=3 rows=3 uniscale=none novarname
                       headerattrs=(size=8);
      histogram _logvalue_ / scale=percent;
      density   _logvalue_ / type=kernel lineattrs=(color=cxc44e52 thickness=2);
      colaxis grid label='log10(value), positive values only';
      rowaxis grid label='Percent';
    run;
  %end;

  title  "Box plots - &lib..&mem";
  title2 "Whiskers at 1.5 x IQR; every marker beyond them is a flagged outlier.";
  proc sgpanel data=_dd_ulong;
    panelby _name_ / columns=4 rows=3 uniscale=none novarname
                     headerattrs=(size=8);
    hbox _value_ / extreme;
    colaxis grid;
  run;

  /*---- (7) comparative outlier view: everything on one standardized axis --*/
  proc sort data=_dd_ulong out=_dd_usort; by _name_; run;
  proc stdize data=_dd_usort out=_dd_ustd method=std;
    var _value_;
    by _name_;
  run;
  title  "Outlier detection - all variables on one standardized (z) axis";
  title2 "Anything past +/-3 is a 3-sigma outlier. Long one-sided tails are skew, not error.";
  proc sgplot data=_dd_ustd;
    hbox _value_ / category=_name_ extreme;
    refline -3 3 / axis=x lineattrs=(pattern=shortdash color=cxc44e52);
    /* the axis is deliberately not clipped: a truncated axis hides the very
       observations this panel exists to show                               */
    xaxis label='Standardized value (z)' grid;
    yaxis display=(nolabel) valueattrs=(size=7) fitpolicy=none;
  run;
  title;
%mend dd_univar;

/*-----------------------------------------------------------------------------
  %DD_BIVAR -- pair plot plus, when a target is supplied, predictor panels.
  target= a numeric outcome (e.g. a memory/cognition score, total spend).
-----------------------------------------------------------------------------*/
%macro dd_bivar(lib=,mem=,vars=,target=,samp=dd_samp,
                maxpair=&DD_MAXPAIRVARS,catvars=);
  %local numlist nnum plist;
  %if %length(&vars) %then %let numlist=&vars;
  %else %do;
    %dd_getvars(lib=&lib,mem=&mem,type=num,out=_DDNUM,exclid=Y,maxlen=30);
    %let numlist=&_DDNUM;
  %end;
  %let plist=%dd_first(&numlist,&maxpair);
  %if %dd_n(&plist) < 2 %then %do;
    %dd_warn(&lib..&mem: fewer than two numeric variables - bivariate skipped.);
    %return;
  %end;

  /*---- pair plot / scatter-plot matrix -----------------------------------*/
  title  "Pair plot (scatter-plot matrix) - &lib..&mem";
  title2 "First %dd_n(&plist) numeric variables. Diagonal shows each marginal distribution.";
  proc sgscatter data=&samp;
    matrix &plist / diagonal=(histogram kernel)
                    markerattrs=(size=4 symbol=circlefilled)
                    transparency=0.85;
  run;

  /*---- predictor vs target, one panel per predictor ----------------------*/
  %if %length(&target) %then %do;
    data _dd_blong(keep=_name_ _value_ _target_);
      set &samp;
      array _v[*] &numlist;
      length _name_ $32;
      _target_=&target;
      if missing(_target_) then delete;
      do _i=1 to dim(_v);
        if upcase(vname(_v[_i])) ne upcase("&target") then do;
          _name_=vname(_v[_i]); _value_=_v[_i];
          if not missing(_value_) then output;
        end;
      end;
    run;
    title  "Bivariate - each numeric variable against &target";
    title2 "Loess fit, not a regression line: it will show a threshold or a plateau that a straight line hides.";
    proc sgpanel data=_dd_blong;
      panelby _name_ / columns=3 rows=3 uniscale=row novarname
                       headerattrs=(size=8);
      scatter x=_value_ y=_target_ / markerattrs=(size=3 symbol=circlefilled)
                                     transparency=0.85;
      loess   x=_value_ y=_target_ / nomarkers lineattrs=(color=cxc44e52 thickness=2);
      colaxis grid; rowaxis grid label="&target";
    run;

    /*---- target by categorical level ------------------------------------*/
    %if %length(&catvars) %then %do;
      data _dd_clong(keep=_name_ _cvalue_ _target_);
        set &samp;
        array _c[*] &catvars;
        length _name_ $32 _cvalue_ $64;
        _target_=&target;
        if missing(_target_) then delete;
        do _i=1 to dim(_c);
          _name_=vname(_c[_i]);
          _cvalue_=strip(vvaluex(vname(_c[_i])));
          if _cvalue_='' then _cvalue_='(missing)';
          output;
        end;
      run;
      title  "Bivariate - &target by categorical level";
      title2 "Box per level. A level whose box barely overlaps the others is doing real work in a model.";
      proc sgpanel data=_dd_clong;
        panelby _name_ / columns=2 rows=2 uniscale=row novarname
                         headerattrs=(size=8);
        vbox _target_ / category=_cvalue_;
        colaxis display=(nolabel) valueattrs=(size=7) fitpolicy=rotate;
        rowaxis grid label="&target";
      run;
    %end;
  %end;
  title;
%mend dd_bivar;

/*-----------------------------------------------------------------------------
  %DD_CORR -- Pearson and Spearman heat maps.
  Both are produced on purpose. Pearson answers "is the relationship linear",
  Spearman answers "is it monotone". On skewed, zero-inflated claims variables
  they routinely disagree, and the disagreement is the finding.
-----------------------------------------------------------------------------*/
/* reshape a PROC CORR OUTP=/OUTS= matrix into (var1,var2,r) long form */
%macro _dd_cmelt(in=,method=,vars=,src=);
  data _dd_m_&method;
    set &in;
    where _type_='CORR';
    length dataset $41 var1 $32 var2 $32 method $10 rlabel $6;
    retain dataset "&src" method "&method";
    array _r[*] &vars;
    var1=_name_;
    do _i=1 to dim(_r);
      var2=vname(_r[_i]); r=_r[_i];
      rlabel=put(r,4.2);
      output;
    end;
    keep dataset method var1 var2 r rlabel;
  run;
%mend _dd_cmelt;

%macro dd_corr(lib=,mem=,vars=,samp=dd_samp,maxvars=&DD_MAXCORRVARS,
               out=dd_corrpairs,append=Y);
  %local numlist clist ncl;
  %if %length(&vars) %then %let numlist=&vars;
  %else %do;
    %dd_getvars(lib=&lib,mem=&mem,type=num,out=_DDNUM,exclid=Y,maxlen=30);
    %let numlist=&_DDNUM;
  %end;
  %let clist=%dd_first(&numlist,&maxvars);
  %let ncl=%dd_n(&clist);
  %if &ncl < 2 %then %do;
    %dd_warn(&lib..&mem: fewer than two numeric variables - correlation skipped.);
    %return;
  %end;

  ods exclude all;
  proc corr data=&samp pearson spearman
            outp=_dd_cp outs=_dd_cs;
    var &clist;
  run;
  ods exclude none;

  %_dd_cmelt(in=_dd_cp,method=Pearson, vars=&clist,src=&lib..&mem);
  %_dd_cmelt(in=_dd_cs,method=Spearman,vars=&clist,src=&lib..&mem);

  data _dd_corr; set _dd_m_Pearson _dd_m_Spearman; run;

  /*---- heat maps ----------------------------------------------------------*/
  %if %upcase(&DD_GRAPHS)=Y %then %do;
    %local m meth;
    %do m=1 %to 2;
      %let meth=%scan(Pearson Spearman,&m,%str( ));
      title  "Correlation heat map - &meth (&lib..&mem)";
      title2 "Blue = negative, red = positive. The diagonal anchors the scale at +1.";
      proc sgplot data=_dd_corr(where=(method="&meth"));
        heatmapparm x=var2 y=var1 colorresponse=r /
             outline outlineattrs=(color=white)
             colormodel=(cx2166ac cx67a9cf cxf7f7f7 cxef8a62 cxb2182b);
        %if &ncl <= 20 %then %do;
          text x=var2 y=var1 text=rlabel / textattrs=(size=6 color=black)
               strip;
        %end;
        xaxis display=(nolabel) valueattrs=(size=7) fitpolicy=rotatethin;
        yaxis display=(nolabel) valueattrs=(size=7) reverse;
        gradlegend / title='r';
      run;
      title;
    %end;
  %end;

  /*---- ranked pair table --------------------------------------------------*/
  proc sql;
    create table _dd_pairs as
    select a.dataset, a.var1, a.var2,
           a.r as r_pearson, b.r as r_spearman,
           abs(a.r) as abs_pearson,
           abs(a.r - b.r) as pearson_spearman_gap
    from _dd_m_Pearson a inner join _dd_m_Spearman b
      on a.var1=b.var1 and a.var2=b.var2
    where a.var1 < a.var2                 /* upper triangle only, no diagonal */
    order by calculated abs_pearson desc;
  quit;

  data _dd_pairs;
    set _dd_pairs;
    length interpretation $70;
    if abs_pearson >= 0.95 then
      interpretation='NEAR DUPLICATE - keep one, the pair will destabilize any model';
    else if abs_pearson >= 0.8 then interpretation='very strong';
    else if abs_pearson >= 0.6 then interpretation='strong';
    else if abs_pearson >= 0.3 then interpretation='moderate';
    else interpretation='weak';
    if pearson_spearman_gap >= 0.2 then
      interpretation=catx('; ',interpretation,
        'Pearson and Spearman disagree - relationship is monotone but not linear, or outlier-driven');
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_pairs force; run;
  %end;
  %else %do; data &out; set _dd_pairs; run; %end;
%mend dd_corr;
