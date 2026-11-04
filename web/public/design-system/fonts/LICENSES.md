# Self-hosted web fonts (decision D-089, 2026-11-04)

The front door no longer loads fonts from Google (a visitor's IP address went to Google on every page view). The
files here are the same families and weights as before, in the form Google Fonts serves them: woff2, already cut
into subsets (latin, latin-ext, cyrillic, cyrillic-ext). The CSS picks a subset by `unicode-range`, so a page loads
only what its text needs. Greek, vietnamese, math and symbols subsets are left out on purpose.

| Family | Files | Weights | Licence | Source |
|---|---|---|---|---|
| Geologica | `geologica-<subset>.woff2` (variable) | 500, 600 | SIL OFL 1.1, `OFL-Geologica.txt` | https://github.com/monokromskriftforlag/geologisk ; served by Google Fonts (google/fonts, ofl/geologica) |
| Onest | `onest-<subset>.woff2` (variable) | 400 to 700 | SIL OFL 1.1, `OFL-Onest.txt` | https://github.com/googlefonts/onest ; google/fonts, ofl/onest |
| IBM Plex Mono | `ibm-plex-mono-<subset>-<weight>.woff2` | 400, 500 | SIL OFL 1.1, `OFL-IBM-Plex-Mono.txt` (Reserved Font Name "Plex") | https://github.com/IBM/plex ; google/fonts, ofl/ibmplexmono |

The OFL texts are copied from google/fonts (`ofl/<family>/OFL.txt`). The fonts are used unmodified, as distributed.

## Letters for Kazakh and Uzbek
- Kazakh Cyrillic extras: Ә (U+04D8), Ғ (U+0492), Қ (U+049A), Ң (U+04A2), Ө (U+04E8), Ұ (U+04B0), Ү (U+04AE),
  Һ (U+04BA), І (U+0406). Ұ and І are in the `cyrillic` subset, the others in `cyrillic-ext`.
- Uzbek Latin: the turned comma ʻ (U+02BB, oʻ and gʻ) is in the `latin` subset; Oʻ/Gʻ capitals use the same mark.
- Check by eye: `core/tools/shoot.sh` on a page with this text (done once for this commit, see the git log).

## Refresh
Fetch `https://fonts.googleapis.com/css2?family=Geologica:wght@500;600&family=Onest:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap`
with a modern browser User-Agent; it lists one woff2 URL per family, subset and weight. Download the files for the four
subsets, rename as above, and rewrite the `@font-face` block at the top of `front-door/css/letflow.css` (and its demo copy).
