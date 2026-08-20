# drearlthe4th.github.io

Documentation site for the value set library — a static site served by GitHub
Pages at <https://drearlthe4th.github.io/>.

## Layout

```
docs/*.md      source documents — edit these
build.py       renders docs/ to HTML at the repo root
assets/        stylesheet + generated syntax-highlighting theme
*.html         GENERATED — do not hand-edit
.nojekyll      serve the files as-is; no Jekyll processing
```

The generated HTML is committed so GitHub Pages needs no build step.

## Editing

Edit the markdown under `docs/`, then rebuild and commit both:

```bash
pip install markdown pygments      # once
python3 build.py
```

Preview locally:

```bash
python3 -m http.server 8000        # then open http://localhost:8000
```

Adding a page means adding the file to `docs/` and a row to `PAGES` in
`build.py`; the nav is generated from that list.
