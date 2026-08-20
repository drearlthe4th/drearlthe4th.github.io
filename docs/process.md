# Process — building an NDC value set

The standing procedure. Follow it in order; the order is load-bearing in two
places, noted where they occur.

- [The shape of a drug value set](#the-shape-of-a-drug-value-set)
- [1. Scope the construct](#1-scope-the-construct)
- [2. Resolve ingredients](#2-resolve-ingredients)
- [3. Build the NDC list](#3-build-the-ndc-list)
- [4. Verify against the claims](#4-verify-against-the-claims)
- [5. Resolve the unadjudicated](#5-resolve-the-unadjudicated)
- [6. Promote](#6-promote)
- [7. Use it in a study](#7-use-it-in-a-study)
- [Maintenance](#maintenance)
- [Thresholds](#thresholds)

---

## The shape of a drug value set

```
catalog/<id>/meta.yaml    definition, ingredients, provenance, caveats
catalog/<id>/codes.csv    materialized NDCs + J-codes, one row per code
```

`meta.yaml` holds the durable definition — ingredient RxCUIs. `codes.csv` is
derived and regenerable.

If you only remember one thing: **ingredients are the definition, NDCs are a
snapshot.** Reconciliation against the claims is what makes the snapshot
trustworthy, and it happens on the VM.

---

## 1. Scope the construct

Before touching a tool, write the `intent` — including what it excludes. Three
decisions have to be made explicitly, because each silently changes the cohort:

**Combinations in or out?** A fixed-dose SGLT2i/metformin product is SGLT2i
exposure and metformin exposure. For "metformin monotherapy" it is neither.
Decide, and say so in `intent`. Do not filter it out later in the analysis and
leave the value set ambiguous.

**Route.** Oral products are PDE dispensings. Injectables and infusions are
usually Part B J-codes and will not appear in PDE at all. If the agent has both
routes, the set needs both NDCs and J-codes, or an explicit statement that only
the oral route is in scope.

**Salt specificity.** Define at `IN`, not `PIN`, unless the salt is the point.
`PIN` does not generalize across formulations.

Then check the library for a near-duplicate before creating anything. Two sets
differing by three NDCs is how this degrades.

## 2. Resolve ingredients

```r
library(rxref)
ing <- find_ingredients("empagliflozin")
```

**Confirm each RxCUI has marketed products before committing to it.** Only 22.9%
of RxNorm ingredients do. `build/ingredients.csv` is the local inventory:

```r
readr::read_csv("build/ingredients.csv") |>
  dplyr::filter(grepl("gliflozin", name), has_products == 1)
```

Do not use RxNorm's prescribable subset as this filter. It includes constituents
that are never marketed alone — vaccine lipid excipients, for instance — and
would let you scaffold a set around something with no product.

Record each ingredient in `meta.yaml` under `concepts:` with `system: RXNORM`,
`tty: IN`, the RxCUI, and the name.

## 3. Build the NDC list

```r
Rscript scripts/vs_ndc_refresh.R <id>            # dry run first
Rscript scripts/vs_ndc_refresh.R <id> --write
```

Under the hood: `products_for_ingredients(concept_status =
"active_and_historical")` then `map_rxcui_to_ndc(history = "all")`.

**`active_and_historical` is not optional.** It recovers product concepts that
are Obsolete, Remapped, Quantified, or NotCurrent. Active-only traversal finds
retired NDCs hanging off live concepts but misses concepts retired outright —
and those are your early-study-year products.

Set `materialized_on`. Add any Part B J-codes by hand as `HCPCS` rows.

## 4. Verify against the claims

**This is the step that makes the set trustworthy, and the order matters: build
first, then verify.** Verifying against claims you used to build the list proves
nothing.

On the VM, export distinct PDE NDCs with fill counts for the study window:

```sas
proc sql;
  create table ndc_obs as
  select PROD_SRVC_ID as ndc, count(*) as n_fills
  from Y2012.PDE /* ... through Y2023 */
  group by PROD_SRVC_ID
  having count(*) >= 11;   /* DUA cell suppression */
quit;
```

Confirm the PDE product-identifier variable name and width for each year first —
that is a `codes-medicare` lookup, and a width mismatch truncates silently.

Then:

```bash
make reconcile ID=<id> OBS=ndc_obs.csv
```

This classifies every unmatched NDC and prints a report. Nothing is written
back to the repo — fill counts are CMS-derived and stay on the VM.

## 5. Resolve the unadjudicated

Every unmatched NDC lands in one of four buckets. Each has a different meaning
and a different fix:

| bucket | what it means | what to do |
|---|---|---|
| **OBSOLETE** | RxNorm knew it and dropped it | **Your build is at fault.** Re-run with `active_and_historical`; check the TTY set. |
| **ALIEN** | Never RxNorm-active | Unreachable by any RxNorm traversal. RED BOOK / First Databank / Medi-Span / CCW crosswalk — or document the omission. |
| **ABSENT** | Not in RxNav at all | Check 11-digit padding first. A mis-normalized NDC is indistinguishable from a missing one. |
| **out of scope** | Maps to a different ingredient | Nothing — this is the reconciler working. |

Work them in fill-count order. An unresolved NDC with 8,000 fills moves an
exposure prevalence more than most modelling choices; one with 3 does not.

ALIEN volume is a real property of the data, not a defect to hide. State it in
`caveats` as prose — "a material share of pre-2015 fills map to NDCs RxNorm
never carried" — rather than committing the count.

## 6. Promote

```bash
make review ID=<id>
```

Promotion is a human act, and the check it represents is yours: do not promote
a set you have not reconciled against real dispensings for a comparable window.
Nothing in the repo can enforce that, because the evidence lives on the VM —
which makes it a discipline rather than a gate. Note the reconciliation date
and window in the changelog entry so the claim is at least dated.

Bump the version and write a changelog line. Semver carries meaning here:
**minor** = NDCs added, cohorts can only grow; **major** = NDCs removed or
intent changed, anything already published must be re-run or pinned.

## 7. Use it in a study

Pin the version: `sglt2i@1.2.0`, never `sglt2i`.

NDC matching is exact — no prefix ranges, no format trickery. A generated
`PROC FORMAT` or a hash join both work:

```sas
if put(PROD_SRVC_ID, $vs_sglt2i_ndc_i.) = 'Y';
```

Re-reconcile if the study window differs from the last one you checked.
Coverage is window-specific; verifying against 2012–2018 says nothing about
2019–2023.

---

## Maintenance

| when | what |
|---|---|
| per study | reconcile every drug set against that study's window |
| monthly, after the RxNorm release | re-run refresh on active sets; diff the NDC list |
| every 6 months | review `materialized_on` dates; re-refresh anything stale |
| annually | rebuild `build/ingredients.csv` |
| before submission | every set `reviewed`, versions pinned, limitations stated in the methods |

## Thresholds

Judgment calls, not findings — revise once you have seen what your data does.
Compute these on the VM from the reconciliation report; do not commit them.

Let *unadjudicated share* mean unmatched fills over matched-plus-unmatched:

- **under 2%** — fine for a primary exposure.
- **2–5%** — usable; describe the dominant bucket in the methods.
- **over 5%** — resolve the largest bucket before using it as a primary
  exposure.
- **OBSOLETE present at all** — a build defect regardless of size. Fix the
  build rather than accepting it.
