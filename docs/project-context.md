# Project context — what to upload, and what not to

Project knowledge is loaded on every message in the project. Everything in it
costs context permanently, so the test for inclusion is: **would I have to
paste this into a conversation more than once a month?** If not, leave it out
and let me search or ask.

## Upload these

| file | why |
|---|---|
| `PROCESS.md` | The SOP. The thing you would otherwise re-explain every time. |
| `build/registry.csv` | One row per value set. Makes "do we already have a GLP-1 set?" answerable without you uploading anything. |
| `build/ingredients.csv` | 18,507 ingredient concepts with product counts. Turns "which RxCUI is bexagliflozin, and does it have products?" into a lookup instead of an API call. |
| One reviewed `meta.yaml` | A worked example is worth more than a schema description. Use your best set once you have one. |

That is it. Four files.

## Do not upload

**`build/all_codes.csv`** — thousands of NDC rows, almost never needed whole. If
a specific set's codes matter, paste that one `codes.csv`.

**The scripts.** I can read them when you paste one or ask about it. Loading
them permanently buys nothing and costs on every message.

**The skill.** `value-sets` is installed at the account level and loads on
demand. Uploading it duplicates it into context permanently — the opposite of
what a skill is for.

**Anything that came off the VM.** NDC lists are not disclosive; anything
computed on your extract is. Reconciliation output in particular stays on the
VM — do not paste the counts in to ask about them. Describe the shape of the
problem instead, which is all I need to help.

## Refresh cadence

Project knowledge is a snapshot, not a live link. Re-upload:

- `registry.csv` — whenever you add or promote a set
- `ingredients.csv` — annually, or after a rebuild
- `PROCESS.md` — when you change the process, which should be rare

If a session seems to be working from a stale registry, that is the cause.

## What lives where

Three layers, and putting something in the wrong one is the usual reason a
setup feels heavy:

**Project instructions** — always true, rarely changes. Who you are, the
ingredient-level rule, the established facts, cell suppression.

**Project knowledge** — reference material you would otherwise paste. The four
files above.

**The `value-sets` skill** — procedural knowledge that loads only when relevant.
Schema details, code-system traps, authoring guidance. Account-level, so it
works in this project, the general library project, and plain chats alike.

The skill stays as-is. It covers ICD and CPT too, which this project does not
use — that costs nothing, because skill content only loads when a task actually
calls for it. Scoping a second drugs-only skill would create two things to
maintain and a real chance they drift apart.

## A note on the first session

Start one conversation in the new project and ask for something small — "add a
GLP-1 receptor agonist value set." That tells you whether the instructions,
knowledge, and skill are pulling together before you have built anything on
top of them. Check specifically that it goes to the ingredient level unprompted
and asks about combination products; if it starts by producing NDCs, the
instructions did not land.
