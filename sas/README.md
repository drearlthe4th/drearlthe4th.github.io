# Medicare + Memory Data Dictionary & Profiling System (SAS)

A generic, metadata-driven profiling program. **No table name, variable name,
type or code value is hardcoded.** Everything is discovered at run time from
`DICTIONARY.TABLES` / `DICTIONARY.COLUMNS` and from the data itself, so the
same code runs unchanged on a Part D PDE file, an MBSF, a carrier line file,
and the memory/cognitive assessment data.

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
| `dd_98_selftest.sas` | Runs the whole battery on SASHELP tables. **Run this first.** |
| `dd_99_driver.sas` | The only file you edit. Libnames, variable roles, what to run. |

## How to run

1. Copy the folder to the VM and set `DDPATH`, `DD_OUT`, and the libnames in
   `dd_99_driver.sas`. `DD_OUT` must already exist.
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
top-values panels, patient-level distributions, and a utilization
concentration curve.

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

**2. Nothing that leaves the VM is safe by default.** Full value catalogs on
claims data contain cells of size 1. `%dd_export(export=SHARE)` applies
primary suppression at n < 11 *and* complementary suppression, and blanks the
percentages along with the counts — suppressing `n` while publishing `%` does
nothing, since the count is recoverable from the denominator.

**3. `NMISS` undercounts missing in CMS data.** Missing arrives as `''`, `~`,
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

**5. Correlation on claims variables is usually the wrong tool, so both
versions are produced.** Pearson answers "is this linear", Spearman answers
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
prescriptions per patient" is not comparable across people with different
amounts of enrollment: three months and two fills is a *higher* rate than
twelve months and six. The right denominator is enrollment months from the
MBSF, not the claim file. STEP 6 of the driver has the pattern; it needs your
MBSF table name to become real.

**8. Panel-year drift is invisible in a pooled dictionary.** If a code value
only exists from 2016, or a variable is dropped for two years and comes back,
a union of all years hides it. Run the profile per year (a `where=` on the
libname or dataset) and diff the value catalogs — that comparison is the
single most useful thing you can do with this output on a multi-year extract.
I did not build the year-by-year loop in because I couldn't see how your files
are split; tell me and I'll add it.

**9. The memory data has repeated measures the dictionary won't show.** How
many assessments per participant, how far apart, who drops out, and whether
scores hit a floor or ceiling are all participant-level questions.
`%dd_patient` plus STEP 6c covers the first three. Floor/ceiling detection is
worth adding once I know the instrument and its score range.

**10. Check the join before trusting any of it.** `%dd_link` reports how many
IDs are in the Medicare files, in the memory data, and in both. Unlinked
records on either side are the population your analysis will silently drop,
and that number is often the most important one in the whole workbook.

## Not verified against your extract

This session had **no access to the CoDES dictionary exports** (`mdd_*.csv`),
so no variable name, table name, or code value in these files has been checked
against your data. That is why nothing is hardcoded and why the driver's
variable names are commented-out placeholders. If you make the dictionary
exports available, the extract-specific issues — the 2019 table rename, the
`_K` suffix through 2018, known variable gaps mid-panel, type changes across
years that hard-error a `SET` — can be built into the driver as explicit
guards rather than left to you to remember.

## Not yet included

- Cramér's V / chi-square for categorical-vs-categorical association
- Median absolute deviation (MAD) outlier rule — the IQR rule already covers
  the same failure mode and MAD costs two extra full passes
- Missing-data *pattern* analysis (which variables go missing together)
- Automatic year-over-year value-catalog diffs
- Floor/ceiling detection for bounded instrument scores
