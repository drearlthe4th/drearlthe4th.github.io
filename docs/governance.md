# Governance

How a value set enters this repo, gets promoted, and gets cited.

- [Disclosure](#disclosure)
- [Branch and review model](#branch-and-review-model)
- [What CI enforces](#what-ci-enforces)
- [Releases and study pinning](#releases-and-study-pinning)
- [Citation](#citation)
- [What is committed and what is not](#what-is-committed-and-what-is-not)

---

## Disclosure

Everything in this repo comes from public vocabularies: NDC codes, RxNorm
ingredient RxCUIs, code descriptors, HCPCS J-codes, provenance, intent,
caveats. Publishing a list of SGLT2 inhibitor NDCs reveals nothing about any
beneficiary.

**No CMS-derived counts are stored here, by design.** Reconciliation against
observed PDE NDCs happens on the VM and its output stays there. What comes back
into the repo is prose in `caveats` — "products retired before 2014 are
under-represented" — not numbers computed on the extract.

That keeps the disclosure story simple, and it is worth preserving. If you
later want coverage statistics tracked over time, they belong in a VM-side file
or a private companion repo, not here. Once a count is in git history, deleting
the file does not remove it.

Still worth a conversation with whoever administers your DUA before making the
repo public — the analysis above is mine, not theirs. Starting private costs
nothing: private-to-public is a settings change, the reverse is not.

## Branch and review model

**Solo:** work on `main`, let CI be the reviewer. The gate is mechanical
anyway — it checks schema and provenance, not whether you agree with the codes.

**With a second reviewer:** branch per value set, PR into `main`. The PR diff
is the review artifact, and it is a good one: a value set change shows up as
added and removed NDC rows with dates, which is exactly what a reviewer needs
to see. Require the CI check to pass before merge.

Either way, a promotion to `status: reviewed` should be its own commit with
its own message. It is the moment the set becomes usable in a study, and you
want it findable in the log.

## What CI enforces

Schema, NDC normalization, ingredient-level definitions, provenance
completeness, and that `build/` matches `catalog/` so a consumer never gets
code lists that disagree with the definitions.

CI cannot check whether an NDC list matches your claims — that needs PDE data,
which is never here. Reconciliation stays a VM-side discipline. A scheduled
monthly run flags materializations older than 180 days as warnings; advisory
only, since RxNorm changing is not a reason to block a merge.

## Releases and study pinning

This is the argument for git that nothing else gives you.

**Tag every study.** When a manuscript's cohort is frozen:

```bash
git tag -a study-sglt2i-hf-2026 -m "Cohort frozen 2026-08-20; sglt2i@1.2.0, metformin@2.0.1"
git push --tags
```

Three years later a reviewer asks which NDCs were in the exposure. You check
out the tag and the answer is exact — not reconstructed, not approximate.
Without this, the honest answer is "roughly these, we think."

**Release on meaningful change.** A GitHub Release per library version, with
the changelog entries since the last one. Releases are what a citation points
at.

Semver carries meaning: **minor** = NDCs added, cohorts can only grow; **major**
= NDCs removed or intent changed, and anything already published against the
old version must be re-run or explicitly pinned.

## Citation

If this becomes public, connect the repo to Zenodo before the first release —
Zenodo mints a DOI per release automatically, and a versioned DOI is what makes
a value set citable in a methods section. `CITATION.cff` in the repo root gives
GitHub's "Cite this repository" button something to render.

Worth knowing: a well-curated, validated value set library is publishable in
its own right. `uncertainty_pct` per set is the kind of number that makes a
resource paper rather than a GitHub link.

## What is committed and what is not

**Committed** — `catalog/` and the `build/` outputs. Build artifacts go in deliberately, against
the usual instinct: this is a dataset, and a consumer should be able to clone
and use `build/all_codes.csv` or the SAS formats without installing R, Python,
or anything else. CI enforces that they match `catalog/`.

**Ignored** — `build/ndc-status/` and `build/ingredient-cache.jsonl` are
regenerable caches, tens of MB, and change constantly. `build/ingredients.csv`
is a judgment call: ~1 MB, rebuilt annually, useful to consumers. Commit it.

**Never** — anything that came off the VM. Not beneficiary-level data, not
suppressed counts, not reconciliation output. The rule is simply "no CMS-derived
data in this repo", which is easier to hold than a rule with exceptions.
