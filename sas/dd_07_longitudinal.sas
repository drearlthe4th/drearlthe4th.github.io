/*=============================================================================
  DD_07_LONGITUDINAL.SAS
  Event-history profiling for any person + date + event file.

  Written for the cannabis dispensing data, but nothing in here is
  cannabis-specific: a dispensation, a Medicaid claim, and a Part D fill are
  the same shape (one person, one date, one event, repeated), so all three
  use these macros.

  Three questions the variable-by-variable dictionary cannot answer:
    %DD_CALENDAR  When does this file actually start and stop, and are there
                  months missing in the middle?
    %DD_INTERVAL  How often does a person come back, and where are the gaps?
    %DD_RATES     Per-person totals normalized to a time denominator, so
                  people with different observation windows are comparable.
=============================================================================*/

/*-----------------------------------------------------------------------------
  %DD_CALENDAR -- events and distinct people per calendar month.

  This is the first plot to look at on any new extract. It exposes, in one
  picture, things no column-level statistic will show you:
    - the real start and end of the file, as opposed to the requested window
    - partial first and last months (never compare these to a full month)
    - a reporting lag at the tail, where recent months look like a decline
      but are just incomplete
    - months with zero rows in the middle of the panel
    - a program ramp-up, which for a registry-based file is real growth and
      not a data problem -- but you have to be able to tell them apart

  datefmt=SAS  the variable is a real SAS date
  datefmt=YMD  the variable is an unformatted YYYYMMDD integer
               (%DD_DATES tells you which one you have)
-----------------------------------------------------------------------------*/
%macro dd_calendar(lib=,mem=,datevar=,id=,interval=month,datefmt=SAS,
                   out=dd_calendar,append=Y);
  %local _ddfmt;
  %if %length(&datevar)=0 %then %return;
  %if %dd_varexist(&lib..&mem,&datevar)=0 %then %do;
    %dd_warn(&datevar not found in &lib..&mem - calendar profile skipped.); %return;
  %end;
  %if %upcase(&interval)=MONTH %then %let _ddfmt=monyy7.;
  %else %if %upcase(&interval)=YEAR %then %let _ddfmt=year4.;
  %else %let _ddfmt=date9.;

  data _dd_cal(keep=_period %if %length(&id) %then &id;);
    set &lib..&mem(keep=&datevar %if %length(&id) %then &id;);
    %if %upcase(&datefmt)=YMD %then %do;
      if missing(&datevar) then delete;
      _d = input(put(&datevar,8.),?? yymmdd8.);
    %end;
    %else %do;
      _d = &datevar;
    %end;
    if missing(_d) then delete;
    _period = intnx("&interval",_d,0,'b');
    format _period &_ddfmt;
  run;

  proc sql;
    create table _dd_calx as
    select _period,
           count(*) as n_events
           %if %length(&id) %then %do;
             ,count(distinct &id) as n_persons
             ,count(*)/max(count(distinct &id),1) as events_per_person
           %end;
    from _dd_cal
    group by _period
    order by _period;
  quit;

  /* Fill in periods that have no rows at all -- an absent month is invisible
     in a GROUP BY and is exactly what you are looking for.
     PUT() is required here: _period carries a MONYY7. format, and a bare
     INTO: would hand back the string 'JAN2020' instead of the date value.  */
  proc sql noprint;
    select put(min(_period),best12.), put(max(_period),best12.)
      into :_pmin trimmed, :_pmax trimmed
    from _dd_calx;
  quit;
  data _dd_spine;
    _period = &_pmin;
    do until (_period > &_pmax);
      output;
      _period = intnx("&interval",_period,1,'b');
    end;
    format _period &_ddfmt;
  run;

  data _dd_calf;
    length dataset $41 gap_flag $140;
    retain dataset "&lib..&mem";
    merge _dd_spine(in=s) _dd_calx(in=c);
    by _period;
    if s;
    if not c then do; n_events=0; gap_flag='NO ROWS IN THIS PERIOD'; end;
    else gap_flag='';
  run;

  /* flag the first and last period as structurally incomplete */
  data _dd_calf;
    set _dd_calf end=eof nobs=_np;
    if _n_=1 then gap_flag=catx('; ',gap_flag,'first period - may be partial');
    if eof   then gap_flag=catx('; ',gap_flag,
        'last period - may be partial or affected by reporting lag');
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_calf force; run;
  %end;
  %else %do; data &out; set _dd_calf; run; %end;

  %if %upcase(&DD_GRAPHS)=Y %then %do;
    title  "Volume over time - &lib..&mem";
    title2 "Check the first and last periods before reading any trend: both are usually incomplete.";
    proc sgplot data=_dd_calf;
      series x=_period y=n_events / lineattrs=(thickness=2 color=cx4c72b0)
             markers markerattrs=(size=4 symbol=circlefilled)
             legendlabel='Events';
      %if %length(&id) %then %do;
        series x=_period y=n_persons / y2axis lineattrs=(thickness=2
               pattern=shortdash color=cx55a868) legendlabel='Distinct people';
      %end;
      xaxis label='Period' grid;
      yaxis label='Events' grid;
      %if %length(&id) %then %do; y2axis label='Distinct people'; %end;
      keylegend / position=bottom;
    run;
    title;
  %end;
%mend dd_calendar;

/*-----------------------------------------------------------------------------
  %DD_INTERVAL -- time between consecutive events for the same person.

  For dispensing data this is the refill interval, and it carries most of the
  behavioral signal in the file: how often patients return, how long the
  typical supply lasts, who stops. It is also the cheapest way to find
  duplicate rows -- a gap of zero days means two events for one person on one
  date, which is either a real split transaction or a double-loaded file.

  gapdays= the threshold that counts as a break in continuous use. 90 is a
  common default; set it to whatever your supply length justifies.
-----------------------------------------------------------------------------*/
%macro dd_interval(lib=,mem=,id=,datevar=,datefmt=SAS,gapdays=90,
                   evout=dd_events,ptout=dd_interval_pt,out=dd_interval_summary,
                   append=Y);
  %if %length(&id)=0 or %length(&datevar)=0 %then %do;
    %dd_warn(dd_interval needs id= and datevar= - skipped.); %return;
  %end;
  %if %dd_varexist(&lib..&mem,&id)=0 or %dd_varexist(&lib..&mem,&datevar)=0
    %then %do;
      %dd_warn(&id or &datevar not found in &lib..&mem - intervals skipped.);
      %return;
    %end;

  data _dd_ev0(keep=&id _d);
    set &lib..&mem(keep=&id &datevar);
    if missing(&id) then delete;
    %if %upcase(&datefmt)=YMD %then %do;
      if missing(&datevar) then delete;
      _d = input(put(&datevar,8.),?? yymmdd8.);
    %end;
    %else %do;
      _d = &datevar;
    %end;
    if missing(_d) then delete;
    format _d date9.;
  run;

  proc sort data=_dd_ev0 out=&evout; by &id _d; run;

  data &evout;
    set &evout; by &id _d;
    retain _prev .;
    if first.&id then do; _prev=.; event_seq=0; end;
    event_seq+1;
    if not missing(_prev) then gap_days = _d - _prev;
    _prev = _d;
    same_day  = (gap_days = 0);
    long_gap  = (gap_days > &gapdays);
    label event_seq='Event number for this person'
          gap_days ='Days since this person''s previous event';
    drop _prev;
  run;

  /* person level */
  ods exclude all;
  proc means data=&evout noprint nway;
    class &id;
    var gap_days;
    output out=&ptout(drop=_type_ rename=(_freq_=n_events))
           n=n_gaps mean=mean_gap median=median_gap
           min=min_gap max=max_gap p25=p25_gap p75=p75_gap;
  run;
  ods exclude none;

  proc sql;
    create table _dd_ptj as
    select p.*,
           g.n_same_day, g.n_long_gaps,
           g.first_event format=date9., g.last_event format=date9.,
           g.last_event - g.first_event + 1 as observed_days
    from &ptout p
      left join (select &id,
                        sum(same_day) as n_same_day,
                        sum(long_gap) as n_long_gaps,
                        min(_d) as first_event,
                        max(_d) as last_event
                 from &evout group by &id) g
      on p.&id = g.&id;
  quit;
  data &ptout; set _dd_ptj; run;

  /* file level. PROC SQL has no MEDIAN aggregate, so the median of the
     person-level medians comes from PROC MEANS and is merged in.          */
  proc sql;
    create table _dd_ivs0 as
    select "&lib..&mem" as dataset length=41,
           "&id"        as id_var  length=32,
           count(*)                    as n_persons,
           sum(n_events)               as n_events,
           sum(n_gaps=0)               as n_single_event_persons,
           sum(n_same_day > 0)         as n_persons_with_same_day_events,
           sum(n_long_gaps > 0)        as n_persons_with_a_long_gap,
           mean(median_gap)            as mean_of_person_median_gap,
           mean(observed_days)         as mean_observed_days
    from &ptout;
  quit;

  ods exclude all;
  proc means data=&ptout noprint;
    var median_gap observed_days;
    output out=_dd_md(drop=_type_ _freq_)
           median=median_of_person_median_gap median_observed_days;
  run;
  ods exclude none;

  data _dd_ivs;
    merge _dd_ivs0 _dd_md;
    pct_single_event_persons = 100*n_single_event_persons/max(n_persons,1);
    label pct_single_event_persons=
      'Percent of people appearing exactly once - they have no interval at all';
  run;

  %if %upcase(&append)=Y and %dd_dsexist(&out) %then %do;
    proc append base=&out data=_dd_ivs force; run;
  %end;
  %else %do; data &out; set _dd_ivs; run; %end;

  %if %upcase(&DD_GRAPHS)=Y %then %do;
    title  "Interval between consecutive events - &lib..&mem";
    title2 "Zero-day gaps are same-day events: a split transaction, or a double-loaded file. Decide which before analyzing. Axis truncated at 365 days; longer gaps are still counted in the person-level table.";
    proc sgplot data=&evout(where=(gap_days ne .));
      histogram gap_days / scale=percent binwidth=7;
      refline &gapdays / axis=x lineattrs=(pattern=shortdash color=cxc44e52)
              label="&gapdays-day break" labelloc=inside;
      xaxis label='Days since previous event for the same person' grid
            max=365;
      yaxis label='Percent of intervals' grid;
    run;

    title  "Events per person - &lib..&mem";
    title2 "A large single-event group changes what a 'typical patient' means.";
    proc sgplot data=&ptout;
      histogram n_events / scale=count;
      xaxis label='Events per person' grid;
      yaxis label='People' grid;
    run;
    title;
  %end;
%mend dd_interval;

/*-----------------------------------------------------------------------------
  %DD_RATES -- turn per-person totals into per-person RATES.

  A raw count per person is not comparable across people observed for
  different lengths of time. Someone with three months in the data and two
  events has a higher rate than someone with twelve months and six. Every
  "average X per patient" number that gets quoted should be built here, not
  from a raw count.

  in=      a person-level rollup (from %DD_PATIENT or %DD_INTERVAL)
  vars=    the numeric totals to convert (n_records n_products sum_QTY ...)
  spanvar= the observation window in days for that person
  per=     rate denominator in days (30 = per month, 365.25 = per year)

  CAUTION: spanvar= defaults to the span between that person's first and last
  observed event, which is an OBSERVED window, not an ELIGIBLE one. It is
  censored at both ends and it makes a one-event person look like a zero-day
  observation. Where a true eligibility window exists -- Medicaid enrollment
  months, a registry certification period -- pass that instead. The macro
  cannot tell the difference and will happily compute a confident wrong
  number, so this is on you.
-----------------------------------------------------------------------------*/
%macro dd_rates(in=,out=,vars=,spanvar=observed_days,per=30,minspan=&per);
  %local i v;
  %if %length(&vars)=0 %then %do;
    %dd_warn(dd_rates needs vars= - skipped.); %return;
  %end;
  %if %dd_varexist(&in,&spanvar)=0 %then %do;
    %dd_warn(&spanvar not found in &in - rates skipped.); %return;
  %end;
  data &out;
    set &in;
    length rate_basis $60;
    _span = max(&spanvar,&minspan);
    _units = _span/&per;
    rate_basis = cats("per &per days of ","&spanvar");
    %do i=1 %to %dd_n(&vars);
      %let v=%scan(&vars,&i,%str( ));
      %if %length(&v) <= 26 %then %do;
        rate_&v = &v / _units;
        label rate_&v = "&v per &per days";
      %end;
      %else %dd_warn(&v is too long to build rate_&v - skipped.);
    %end;
    drop _span _units;
  run;
  %dd_note(Rates written to &out using &spanvar as the denominator.);
%mend dd_rates;
