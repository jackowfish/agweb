# Benchmarks

`scripts/bench.py` reruns the main cases against `scripts/bench-baseline.json` (see its header); run it before a release. The tables below are how the numbers were first found.

Measured 2026-11-20 on Paul's Mac (macOS 27.2), in throwaway test instances (`scripts/build.sh --test`, own `AGWEB_ROOT`), nothing else running. Times are wall clock per CLI call, median of 3. CPU is the CPU time the whole tool used during the call; RAM is the peak resident memory of its whole process tree (agweb: the app and the WebKit processes macOS counts as its; Playwright: playwright-cli's daemon and Chrome). playwright-cli 0.1.11, headless.

## Snapshot and find on a huge page

A page like rapi-doc's API docs: nested open shadow roots, N operations, each with a heading, text, a clickable div, a list, a 4-row table of text fields and TRY/CLEAR buttons. N=1500 gives a 49,500-line snapshot, N=5000 165,000 lines (the rapi-doc page an agent reported was 180,000).

```html
<!doctype html><title>big</title>
<style>.op{margin:8px;border:1px solid #ccc;padding:4px} .p{cursor:pointer}</style>
<rapi-doc id=rd></rapi-doc>
<script>
const N = Number(new URLSearchParams(location.search).get('n') || 1500);
customElements.define('api-request', class extends HTMLElement {
  constructor() { super(); const r = this.attachShadow({mode:'open'});
    r.innerHTML = `<div class=req><table>${[0,1,2,3].map(i=>`<tr><td>param_${i}</td><td><input data-pname="param_${i}" placeholder="value ${i}"></td><td>string, required. Some description of the parameter number ${i}.</td></tr>`).join('')}</table><button>TRY</button><button>CLEAR</button><textarea>{}</textarea></div>`; }
});
customElements.define('rapi-doc', class extends HTMLElement {
  constructor() { super(); const r = this.attachShadow({mode:'open'});
    let h = '<nav>' + Array.from({length:N},(_,i)=>`<a href="#op${i}" class=p>Operation ${i}</a>`).join('') + '</nav><main>';
    for (let i=0;i<N;i++) h += `<section class=op id="op${i}"><h2>GET /api/v1/resource_${i}/</h2><p>Retrieve resource ${i}. Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p><div class=p tabindex=0>Expand ${i}</div><ul><li>200 OK</li><li>404 Not found</li></ul><api-request></api-request></section>`;
    r.innerHTML = h + '</main>'; }
});
</script>
```

"before" is 2240b92 (v0.5.0 plus the popup wait fix), "now" is ec9b605. ✗: the old `find` searched only the snapshot's first 2000 lines, so it answered "nothing matches" here.

| N=1500 (50k lines) | before | now | playwright-cli |
|---|---|---|---|
| snapshot (2000 lines) | 0.41 s | 0.03 s | (no cap) |
| full snapshot (`--filename`) | 9.65 s | 0.24 s | 0.82 s |
| `find TRY` | 0.42 s ✗ | 0.28 s | (no find) |
| CPU, full snapshot | 9.7 s | 0.31 s | 0.87 s |
| RAM, peak | 0.62 GB | 0.65 GB | 2.9 GB |

| N=5000 (165k lines) | before | now | playwright-cli |
|---|---|---|---|
| snapshot (2000 lines) | 0.40 s | 0.03 s | (no cap) |
| full snapshot (`--filename`) | 32.1 s | 0.80 s | 2.76 s |
| `find TRY` | 0.42 s ✗ | 0.91 s | (no find) |
| CPU, full snapshot | 32.4 s | 0.90 s | 3.8 s |
| RAM, peak | 1.45 GB | 1.54 GB | 3.7 GB |

Where a full snapshot's time went at N=5000, before → now: page script 0.7 s → 0.7 s; parsing the reply 0.04 + 0.1 s → 0.03 s (JSONSerialization gave an NSString that Swift walked through the bridge; JSONDecoder gives a native String); ref labels 9 s (a Swift Regex per line) → 0.09 s (a byte scanner); line splitting by grapheme → by newline byte; the CLI's section split, join and Foundation trim 0.12 s → 0.02 s. `find` also lowercases the tree once instead of a Foundation case-insensitive search per line (0.8 s → 0.25 s), and collects each match's enclosing lines in one pass (1500 matches: 39 s → 1 s).

## App Nap

macOS naps agweb in the background, which stretches every timer a command waits on. `goto` of a tiny local page after 20 s idle, 5 runs:

| Build | goto |
|---|---|
| no activity | 0.72–0.88 s |
| activity in `execute`, `.userInitiatedAllowingIdleSystemSleep` | 0.52–0.76 s |
| activity in `handle`, plus `.latencyCritical` (shipped) | 0.37–0.38 s |
| `NSAppSleepDisabled` (App Nap off entirely) | 0.37–0.38 s |

## Other commands

Measured by a Fable agent on 06887a1's code, before the final App Nap fix and the fixes below, `AGWEB_INSTANT=1`, median of 3; "54k" is a page of 54,000 elements (1.9 MB of HTML). Each time includes about 0.04 s of harness.

| Command | Page | Time |
|---|---|---|
| `goto` / `open` | tiny | 0.65 / 0.70 s (0.37 s with the App Nap fix) |
| `goto` | 54k | 0.89 s |
| `snapshot` (capped) / `--diff` | 54k | 0.19 / 0.19 s |
| `text` / `text --all` / `text #last` | 54k | 3.17 / 0.53 / 0.05 s |
| `text` / `text --all` | 10k-row table | 1.86 / 1.21 s |
| `click` by CSS, no snapshot before / after one | 54k | 0.21 / 0.32 s |
| `fill` / `type` / `hover` by CSS | 54k | 0.20 / 0.05 / 0.05 s |
| `press Tab` / `check` | 54k | 0.51 / 0.38 s |
| `click role=textbox[name=…]` | 54k | 4.48 s |
| `hover role=textbox[name=…]` | 54k / 22k / 5k | 5.03 / 0.49 / 0.05 s |
| `wait role=textbox[name=…]` | 54k | 1.70 s |
| `click role=checkbox >> nth=-1` | 54k | 0.31 s |
| `click text=` / `wait text=` | 54k | 0.57 / 0.07 s |
| `wait #last` / `--text` / `--load` | 54k | 0.05 / 0.05 / 0.62 s |
| `select` on 10k options | | 0.07 s |
| `eval` returning outerHTML (2 MB) | 54k | 0.19 s |
| `screenshot` / `--full-page` png / jpg | 54k | 0.06 / 0.86 / 0.52 s |
| `pdf` / `pdf --single-page` | 54k | 6.28 / 2.16 s |
| `requests` (500 of 2k) / `console` (500 of 10k) | | 0.05 / 0.05 s |
| `cookie-list` (150) / `state-save` (2 MB) | | 0.04 / 0.05 s |
| `tab-list` / `list` / `tab-new` | 60 tabs | 0.05 / 0.04 / 0.68 s |
| `dashboard --filename` | 63 tabs | 2.18 s |

Causes found: `role=…[name=…]` read `el.labels` for every candidate, which scans the document each time, and an action resolves its target about three times; `text` spends about 2.6 s in Defuddle's parse on a huge DOM; `pdf` is WebKit's print view drawing on the main thread; `screenshot --full-page` encodes PNG through a TIFF round trip; `dashboard --filename` sleeps a fixed 2 s.

## After the fixes for those (95d597c)

A page of 6000 rows, each an input with a placeholder, a button, a checkbox and five spans (54,000 elements), plus one `<label for>`; `AGWEB_INSTANT=1`, median of 3.

| Command | before | after |
|---|---|---|
| `click role=textbox[name="field 5999"]` | 8.52 s | 0.29 s |
| `hover role=button[name="Button 5999"]` | 6.07 s | 0.13 s |
| `wait role=textbox[name="Labelled"]` | 2.04 s | 0.06 s |
| `screenshot --full-page` png / jpg (2160×32768 px) | 1.21 / 0.75 s | 1.08 / 0.55 s |
| `dashboard --filename`, 6 tabs | 2.16 s | 0.47 s |
