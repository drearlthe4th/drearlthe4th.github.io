# Data Dictionary & Profiling System (SAS)

A generic, metadata-driven profiling program. **No table name, variable name,
type or code value is hardcoded.** Everything is discovered at run time from
`DICTIONARY.TABLES` / `DICTIONARY.COLUMNS` and from the data itself, so the
same code runs unchanged on a Part D PDE file, an MBSF, a carrier line file,
a Medicaid claim file, or a cannabis dispensation table.

## Two isolated enclaves

| | VM 1 | VM 2 |
|---|---|---|
| Contents | Medicare claims / enrollment | MEMORY medical cannabis dispensing + Medicaid |
| Driver | `dd_99_driver_medicare.sas` | `dd_99_driver_memory.sas` |
| Linkage | between Medicare files only | MEMORY ↔ crosswalk ↔ Medicaid |

The VMs do not talk to each other and the populations are **not linkable
across them**. Copy this folder into each VM and run it there with its own
driver. There is no code here that could join across enclaves and there
should not be — the two have separate data use agreements, and a joined
output would be a disclosure event rather than an analysis. Don't merge the
two workbooks either.

Inside VM 2, MEMORY ↔ Medicaid *is* a real question. The two files don't share
an identifier, so `%dd_xwalk` runs the join through the crosswalk and measures
what a crosswalk breaks (see item 10 below for how to read the answer).

## Files

| File | Contents |
|---|---|
| `dd_00_setup.sas` | Configuration block, utility macros, sampling, DUA cell suppression, ODS wrappers |
| `dd_01_overview.sas` | Data overview (shape/columns/types); missing-value analysis + charts |
| `dd_02_stats.sas` | Descriptive statistics; outlier detection; distribution shape (skewness/kurtosis/CV) |
| `dd_03_values.sas` | Complete character value catalog (every value in the full dataset) |
| `dd_04_graphics.sas` | Histograms, box plots, pair plot, target panels, Pearson + Spearman heat maps |
| `dd_05_patient.sas` | Date profiling, patient-level rollups, cross-dataset linkage, key uniqueness |
| `dd_06_report.sas` | Master dictionary assembly, Excel/PDF export, `%dd_profile` one-call wrapper |
| `dd_07_longitudinal.sas` | Volume by calendar period, inter-event intervals, per-person rates |
| `dd_98_selftest.sas` | Runs the whole battery on SASHELP tables. **Run this first.** |
| `dd_99_driver_medicare.sas` | VM 1 driver. Edit this one inside the Medicare enclave. |
| `dd_99_driver_memory.sas` | VM 2 driver. Edit this one inside the cannabis/Medicaid enclave. |

## How to run

1. Copy the folder into the VM and set `DDPATH`, `DD_OUT`, `DD_MINCELL` and
   the libnames in that VM's driver. `DD_OUT` must already exist.
2. Run `dd_98_selftest.sas`. If it produces a workbook and a graphics PDF with
   no errors, the program works and any later failure is about your data.
3. Run STEP 3a in the driver (`graphs=N`) on each real dataset. This needs no
   knowledge of your variable names and is always safe.
4. Read sheet **1 Dictionary**, fill in the real variable names in STEP 3b,
   and re-run.

## What it produces

**`<project>_full.xlsx`** — ten sheets: master dictionary (one row per
variable), dataset overview, missing/sentinel/hygiene, descriptive statistics,
outliers, the complete value catalog, correlated pairs, date diagnostics,
patient-level rollups, and linkage/key checks.

**`<project>_shareable.xlsx`** — the same thing with cells below
`DD_MINCELL` (default 11) suppressed, including complementary suppression.

**`<project>_<table>_graphics.pdf` / `.html`** — missing-value bars, histogram
and density panels, box-plot panels, a standardized all-variable box plot,
the pair plot, target panels, both correlation heat maps, cardinality profile,
top-values panels, patient-level distributions, a utilization concentration
curve, a volume-over-time series, and an inter-event interval histogram.

## Design decisions you should know about

**Counts are exact; pictures are sampled.** Every number in the dictionary is
computed on the full file. Only the plots use a sample (`DD_SAMPLEOBS`,
default 50,000). A histogram of 50,000 randomly drawn rows and a histogram of
400 million rows look the same; only the render time differs.

**Character values are captured raw, not formatted.** A dictionary documents
what is stored, not what a format catalog happens to display today. Set
`DD_USEFORMATS=Y` to catalog the formatted labels instead.

**"Every value in the full dataset" is enforced in two stages.** A cheap
cardinality screen on the first `DD_SCREENOBS` rows decides which variables
are safe to enumerate; then a single full-data `PROC FREQ` captures *every*
value of those variables — all rows, all years, missing included as its own
level. Variables that fail the screen are still listed by name with their
estimated cardinality and the reason they were skipped. Nothing disappears
silently. Raise `DD_MAXLEVELS` or pass `force=` to enumerate one anyway.

## Things worth flagging about the request

**1. "Every value present" and identifiers are in conflict.** `BENE_ID` has
one value per beneficiary and `CLM_ID` one per claim. Enumerating them builds
a hash table the size of the file and produces a listing that *is* the
identifier file — a disclosure problem, not a dictionary. Identifier-shaped
names (`DD_IDPATTERN`) are excluded by name, and everything else by measured
cardinality. That is a deliberate departure from "every variable" and the two
knobs to change it are documented above.

**2. Nothing that leaves an enclave is safe by default.** Full value catalogs
on claims or registry data contain cells of size 1. `%dd_export(export=SHARE)` applies
primary suppression at n < 11 *and* complementary suppression, and blanks the
percentages along with the counts — suppressing `n` while publishing `%` does
nothing, since the count is recoverable from the denominator.

**3. `NMISS` undercounts missing in administrative data.** Missing arrives as `''`, `~`,
`U`, `UNK`, `NA`, a special missing `.A`–`.Z`, or a sentinel like `9999`. And
in payment fields a `0` is a real "no payment", not a missing — treating the
two alike is the most common cost-analysis error. The program counts all of
these separately and reports `pct_usable` alongside `pct_miss`.

**4. Dates are stored three incompatible ways.** A real SAS date, an
unformatted integer `YYYYMMDD`, and a character `'2018-03-14'` all look like
"a date". Subtracting two of the first, or comparing across two files that
disagree, is a wrong answer with no error message. `%dd_dates` reports which
form each variable is actually in, plus future dates, pre-1900 dates, and
impossible `YYYYMMDD` values.

**5. Correlation on claims and dispensing variables is usually the wrong tool,
so both versions are produced.** Pearson answers "is this linear", Spearman answers
"is this monotone". On skewed, zero-inflated cost variables they routinely
disagree, and the disagreement is the finding, so the pair table reports both
and flags gaps over 0.2. Note that neither measures association between two
*categorical* variables — for that you want Cramér's V, which is not in here
yet. Say the word and I'll add it.

**6. Row-level statistics are not patient-level statistics.** A row in a
claims file is a claim, a claim line, or a fill — not a person. Mean spend per
claim and mean spend per beneficiary are different numbers and neither is
"average cost". Everything above `%dd_patient` describes rows; everything
inside it describes people, and the concentration curve shows how badly the
two diverge.

**7. Counts per patient need a denominator you don't have yet.** "Average
prescriptions per patient" and "average dispensations per patient" are not
comparable across people observed for different lengths of time: three months
and two events is a *higher* rate than twelve months and six. In VM 1 the
denominator is enrollment months from the MBSF, not the claim file. In VM 2
it's a registry certification window or Medicaid eligibility months.
`%dd_rates` defaults to the observed first-to-last span, which is censored at
both ends and makes a one-time patient look like a zero-day observation —
pass a real eligibility window whenever one exists. STEP 6 of each driver has
the pattern; both need your table names to become real.

**8. Panel drift is invisible in a pooled dictionary.** If a code value only
exists from 2016, or a variable is dropped for two years and comes back, a
union of all years hides it. Run the profile per year (a `where=` on the
dataset) and diff the value catalogs — on a multi-year extract that comparison
is the single most useful thing you can do with this output. `%dd_calendar`
now catches the crudest version of this (periods with no rows at all), but not
value-level drift. I didn't build the year-by-year loop because I can't see
how your files are split; tell me and I'll add it.

**9. The dispensing data is an event history, and that needs its own module.**
`dd_07` adds three things the column-by-column dictionary can't show:
`%dd_calendar` (volume and distinct people per month — this is the first plot
to look at, because it exposes the file's real start and end, partial first
and last months, a reporting lag at the tail that looks like a decline, and
any month with zero rows in the middle of the panel); `%dd_interval` (days
between a patient's consecutive dispensations — the refill interval, which
carries most of the behavioral signal, and where a zero-day gap tells you
about same-day events that are either split transactions or a double-loaded
file); and `%dd_rates` (per-person totals normalized to a time denominator).

**10. A crosswalk breaks three things a direct join doesn't, all silently.**
`%dd_xwalk` measures each: **coverage** (ids the crosswalk simply doesn't
contain — unlinkable, and not missing at random), **fan-out** (one registry
patient mapped to several MSIS ids, which turns a one-to-one merge into a
many-to-many one and silently multiplies rows), and **staleness** (crosswalk
ids present in neither source file, which inflate any match rate computed
from the crosswalk alone). Report the **end-to-end** rows and ignore the
rest: crosswalk coverage overstates the match rate, because a crosswalk row
whose partner isn't actually in the source file links nothing.

Then remember what the unlinked share means. Registry patients who pay cash
or carry commercial insurance have no Medicaid record at all, so the linked
subset is a **selected population**, not a sample of registry patients. That
percentage belongs in your limitations paragraph.

**11. `DD_MINCELL` = 11, confirmed for all three data estates.** Primary
suppression blanks cells of 1–10; complementary suppression then blanks the
next smallest cell in the same variable, so a single suppressed cell can't be
recovered by subtraction from the total. Percentages are blanked with the
counts.

**12. `PRODUCT_NAME` gives an estimate, and the code says so.** Product names
are free-text trade names with no controlled vocabulary, so distinct-product
counts from that field are an **upper bound** — re-branded, re-spelled and
re-cased versions of one product each count separately. Two things follow.
`%dd_annotate` writes that caveat into the dictionary itself so it ships with
the deliverable rather than living in an email. And STEP 6e measures the size
of the error: it counts distinct names raw, counts them again after
collapsing case, punctuation and whitespace, and lists the specific names
that collapse together. Report that gap alongside the count.

## Not verified against your data

This session had **no access to the CoDES dictionary exports** (`mdd_*.csv`)
and none to the cannabis or Medicaid schemas, so no variable name, table name,
or code value in these files has been checked against anything. That is why
nothing is hardcoded and why every variable name in both drivers is a
commented-out placeholder. Run STEP 2 (`graphs=N`) first — it needs no names
at all — then fill in STEP 3 from sheet 1.

For the Medicare VM specifically: if you can share the dictionary exports, the
extract's known quirks — the 2019 table rename, the `_K` suffix through 2018,
variable gaps mid-panel, type changes across years that hard-error a `SET` —
can be built into the driver as explicit guards rather than left for you to
remember.

## Not yet included

- Cramér's V / chi-square for categorical-vs-categorical association
- Median absolute deviation (MAD) outlier rule — the IQR rule already covers
  the same failure mode and MAD costs two extra full passes
- Missing-data *pattern* analysis (which variables go missing together)
- Automatic year-over-year value-catalog diffs
- Continuous-eligibility construction from the Medicaid eligibility file (the
  correct denominator for every per-patient rate in VM 2)
- Fuzzy product-name normalization beyond case/punctuation/whitespace
  (SPEDIS or a hand-built map); STEP 6e bounds the error but does not fix it
- Product-mix decomposition for the potency trend in `dd_07`
