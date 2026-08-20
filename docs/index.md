# Value set library

Reusable, versioned code lists for claims research — NDC, RxNorm, ICD-9/10-CM,
ICD-9/10-PCS, CPT, HCPCS, revenue center, POS, DRG.

A definition is written once, reviewed once, and reused. The alternative — a
code list rebuilt from memory each study — is how two papers from the same lab
end up with different denominators for the same construct.

## Layout

```
catalog/<id>/meta.yaml    definition, provenance, validation, caveats
catalog/<id>/codes.csv    one row per code
build/                    GENERATED — never hand-edit, never commit conflicts here
scripts/                  new · validate · build · ndc refresh
```

## Workflow

`make` is the entry point. The scripts are machinery; the Makefile is the
process, so the order is not something you have to remember.

```bash
make                                   # what the targets are
make new ID=hf NAME="Heart failure" TYPE=condition
# fill in catalog/hf/meta.yaml and codes.csv
make check                             # validate
make build                             # compile to build/ and build/sas/
make review ID=hf                      # promote draft -> reviewed
```

Run `make ci` before anything that matters — strict mode, where warnings fail.
Wire it to a pre-commit hook or CI and the discipline stops depending on
memory.

Drugs get one extra step, because an NDC list is a dated snapshot rather than a
definition:

```bash
Rscript scripts/vs_new.R glp1ra --name "GLP-1 receptor agonists" --type drug
# add ingredient RxCUIs to meta.yaml concepts:
Rscript scripts/vs_ndc_refresh.R glp1ra --dry-run
Rscript scripts/vs_ndc_refresh.R glp1ra --write
```

Then reconcile against the NDCs actually present in PDE — export
`ndc,n_fills` from the VM and run:

```bash
Rscript scripts/vs_ndc_reconcile.R glp1ra --observed pde_ndcs.csv
```

RxNav's `getAllHistoricalNDCs` with `history=2` returns every NDC ever
associated with a concept, including retired ones, back to about 2007 — for
metformin 500 mg that is 2,014 NDC-periods against 488 in the current-only
view. openFDA has no historical coverage at all and is used only for marketing
dates on products still listed. Refresh builds; reconcile verifies.

Keep the bulk status cache current — it is what makes an unresolved NDC
diagnosable rather than merely missing:

```bash
make ndc-cache                                 # 1.49M NDCs, ~6 seconds
```

### Verifying against the claims

RxNav knows RxNorm; it does not know your data. Export observed PDE NDCs with
fill counts and check:

```bash
make reconcile ID=sglt2i OBS=pde_ndcs.csv
```

Unmatched NDCs are triaged into OBSOLETE (your build is at fault), ALIEN
(unreachable from RxNorm by any traversal), and ABSENT (check padding first).

This produces a **report, not a repo artifact**. Fill counts are CMS-derived
and stay on the VM. Where the reconciliation reveals a real limitation — a
large ALIEN share, an omitted route — write it into the value set's `caveats`
as prose. The repo therefore holds no derived counts at all.

## Conventions that matter

**Codes are stored as the claims store them.** ICD without decimals, NDC
11-digit undashed with leading zeros intact, revenue codes zero-padded to 4.
The validator enforces this. A decimal in an ICD code matches nothing and
raises no error.

**Retired codes keep their rows.** Set `valid_to`; do not delete. Old claims
still carry them, and the row is what tells a future reader the absence was
known rather than overlooked.

**Exclusions need a note.** An exclusion that overlaps no inclusion is a
validation error, because it nearly always means the hierarchy was misread.

**Warnings are dismissed explicitly.** `suppress_warnings: [ndc_without_hcpcs]`
in `meta.yaml`, alongside a caveat saying why. Dismissals show up in the
validator output, so a reviewer sees what was waved through.

## Validator

```bash
Rscript scripts/vs_validate.R            # whole catalog
Rscript scripts/vs_validate.R t2dm       # one set
Rscript scripts/vs_validate.R --strict   # warnings fail too (use in CI)
```

Beyond schema checks it looks for the errors that survive human review: a set
spanning October 2015 with only one ICD vocabulary; a procedure set with CPT
but no ICD-PCS; a drug set with NDCs but no ingredient RxCUIs; an exact match
on a 3-character ICD-10 category that is not billable; a prefix on a full
billable code; a stale materialization date.

`vs_build.R` refuses to run while errors exist. A format compiled from a
broken definition fails silently downstream, which is the entire thing this
library exists to prevent.

## Seed sets

Three worked examples, each covering a different shape:

| id | shape it demonstrates |
|---|---|
| `t2dm` | ICD-9/ICD-10 span; ICD-9 fifth digit carrying type, which a prefix would destroy |
| `sglt2i` | concept-level drug — RxNorm ingredients as the definition, NDCs as a dated materialization |
| `tka` | procedure needing CPT *and* ICD-PCS, because inpatient and outpatient code it differently |

All three are `status: draft` and `maintainer: TBD`. Review them against their
sources before promoting to `reviewed`.

## Related

`codes-medicare` skill — which CoDES table holds which variable in which year.
This library says *which codes*; that skill says *which column*. Use both.
