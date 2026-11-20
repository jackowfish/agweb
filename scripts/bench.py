#!/usr/bin/python3 -I
"""Times agweb's commands on big local pages, in an instance of its own, and compares with the last saved baseline.

Run by hand before a release (not in CI: timings need a quiet Mac, and the baseline is this Mac's):

    AGWEB_CLI=$(scripts/build.sh --test /tmp/agw-bench) scripts/bench.py [--save] [--playwright]

Each case runs 3 times; the table shows the median wall time, the CPU time agweb used (the app and the WebKit
processes macOS counts as its) and their peak resident memory. A case 25% and 0.1 s slower than the baseline is
flagged, and the exit status is the number of flagged cases. --save writes this run as the new baseline
(scripts/bench-baseline.json); --playwright also times playwright-cli's snapshot of the same page, headless.
"""
import ctypes, http.server, json, os, platform, shutil, socketserver, statistics, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "bench-baseline.json")
CLI = os.environ.get("AGWEB_CLI")
RUNS = 3

# Pages: like rapi-doc's API docs (nested shadow roots), rows of controls, a long article, a big table, a tiny page.
RAPIDOC = """<!doctype html><title>rapidoc</title><style>.op{margin:8px;border:1px solid #ccc;padding:4px} .p{cursor:pointer}</style>
<rapi-doc></rapi-doc><script>
const N = 5000;
customElements.define('api-request', class extends HTMLElement { constructor() { super(); this.attachShadow({mode:'open'}).innerHTML =
  `<div><table>${[0,1,2,3].map(i=>`<tr><td>param_${i}</td><td><input data-pname="param_${i}" placeholder="value ${i}"></td><td>string, required. Some description of the parameter number ${i}.</td></tr>`).join('')}</table><button>TRY</button><button>CLEAR</button><textarea>{}</textarea></div>`; } });
customElements.define('rapi-doc', class extends HTMLElement { constructor() { super();
  let h = '<nav>' + Array.from({length:N},(_,i)=>`<a href="#op${i}" class=p>Operation ${i}</a>`).join('') + '</nav><main>';
  for (let i=0;i<N;i++) h += `<section class=op id="op${i}"><h2>GET /api/v1/resource_${i}/</h2><p>Retrieve resource ${i}. Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p><div class=p tabindex=0>Expand ${i}</div><ul><li>200 OK</li><li>404 Not found</li></ul><api-request></api-request></section>`;
  this.attachShadow({mode:'open'}).innerHTML = h + '</main>'; } });
</script>"""
ROWS = "<!doctype html><title>rows</title><body>" + "".join(
    f'<div><input placeholder="field {i}"><button id=b{i}>Button {i}</button><input type=checkbox><span>row {i}</span><span>a</span><span>b</span><span>c</span><span>d</span></div>'
    for i in range(6000)) + "<label for=lab>Labelled</label><input id=lab></body>"
ARTICLE = "<!doctype html><title>article</title><body><article><h1>Article</h1>" + "".join(
    f"<h2>Part {i}</h2>" + "<p>" + ("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt. " * 20) + "</p>"
    for i in range(400)) + "</article></body>"
TABLE = "<!doctype html><title>table</title><body><table><tr><th>id</th><th>name</th><th>amount</th></tr>" + "".join(
    f"<tr><td>{i}</td><td>Customer {i}</td><td>{i * 7 % 1000}.00</td></tr>" for i in range(10000)) + "</table></body>"
TINY = "<!doctype html><title>tiny</title><body><p>Hello</p><button id=b onclick=\"this.textContent='done'\">Press</button><input id=f></body>"
PAGES = {"rapidoc": RAPIDOC, "rows": ROWS, "article": ARTICLE, "table": TABLE, "tiny": TINY}

# (case, page, agweb args). Each page is opened in its own workspace first.
CASES = [
    ("goto tiny", "tiny", ["goto", "{url}"]),
    ("click", "tiny", ["click", "#b"]),
    ("fill", "tiny", ["fill", "#f", "some text"]),
    ("press Tab", "tiny", ["press", "Tab"]),
    ("wait --text", "tiny", ["wait", "--text=Hello"]),
    ("eval", "tiny", ["eval", "1 + 1"]),
    ("screenshot", "tiny", ["screenshot", "--filename={dir}/tiny.png"]),
    ("snapshot", "rapidoc", ["snapshot"]),
    ("snapshot --filename (165k lines)", "rapidoc", ["snapshot", "--filename={dir}/rapidoc.txt"]),
    ("find TRY", "rapidoc", ["find", "TRY"]),
    ("find resource_4999/", "rapidoc", ["find", "resource_4999/"]),
    ("wait CSS in shadow root", "rapidoc", ["wait", 'input[data-pname="param_1"] >> nth=0']),
    ("snapshot #op77 (in shadow root)", "rapidoc", ["snapshot", "#op77"]),
    ("click role= with a name (54k)", "rows", ["click", 'role=textbox[name="field 5999"]']),
    ("hover role= with a name (54k)", "rows", ["hover", 'role=button[name="Button 5999"]']),
    ("click CSS (54k)", "rows", ["click", "#b0"]),
    ("text (54k)", "rows", ["text"]),
    ("text --all (54k)", "rows", ["text", "--all"]),
    ("screenshot --full-page (54k)", "rows", ["screenshot", "--full-page", "--filename={dir}/rows.png"]),
    ("eval outerHTML (2 MB)", "rows", ["eval", "document.body.outerHTML.length"]),
    ("text (article)", "article", ["text"]),
    ("pdf (article)", "article", ["pdf", "--filename={dir}/article.pdf"]),
    ("text --all (10k-row table)", "table", ["text", "--all"]),
    ("snapshot --filename (10k-row table)", "table", ["snapshot", "--filename={dir}/table.txt"]),
]

responsible = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
responsible.argtypes, responsible.restype = [ctypes.c_int], ctypes.c_int


def processes():
    """pid -> (ppid, resident KB, CPU seconds, command) for every process."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,time=,command="], capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        seconds = 0.0
        for chunk in parts[3].split(":"):
            seconds = seconds * 60 + float(chunk)
        table[int(parts[0])] = (int(parts[1]), int(parts[2]), seconds, parts[4])
    return table


def members(table, owner):
    """The pids of a tool: agweb's app pid and what macOS counts as its; or a playwright-cli daemon's process tree."""
    if isinstance(owner, int):
        return {pid for pid in table if pid == owner or responsible(pid) == owner}
    keep = {pid for pid, row in table.items() if "playwright" in row[3] and ("cli" in row[3] or "daemon" in row[3]) and "bench.py" not in row[3]}
    grew = True
    while grew:
        grew = False
        for pid, row in table.items():
            if row[0] in keep and pid not in keep:
                keep.add(pid)
                grew = True
    return keep


def measure(owner, command, env, cwd=None):
    """Runs `command` while sampling the tool's processes every 50 ms: (wall s, CPU s, peak MB, exit status)."""
    first = processes()
    cpu = {pid: first[pid][2] for pid in members(first, owner)}
    start_cpu = dict(cpu)
    peak = sum(first[pid][1] for pid in cpu) / 1024
    done = threading.Event()

    def sample():
        nonlocal peak
        while not done.is_set():
            table = processes()
            mine = members(table, owner)
            peak = max(peak, sum(table[pid][1] for pid in mine) / 1024)
            for pid in mine:
                cpu[pid] = table[pid][2]
            done.wait(0.05)

    sampler = threading.Thread(target=sample)
    sampler.start()
    began = time.time()
    status = subprocess.run(command, env=env, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    wall = time.time() - began
    done.set()
    sampler.join()
    last = processes()
    for pid in members(last, owner):
        cpu[pid] = last[pid][2]
    return wall, sum(cpu[pid] - start_cpu.get(pid, 0.0) for pid in cpu), peak, status


def median_of(owner, command, env, cwd=None):
    runs = [measure(owner, command, env, cwd) for _ in range(RUNS)]
    return {"s": round(statistics.median(r[0] for r in runs), 3), "cpu": round(statistics.median(r[1] for r in runs), 3),
            "mb": round(max(r[2] for r in runs)), "failed": any(r[3] != 0 for r in runs)}


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    save, with_playwright = "--save" in sys.argv, "--playwright" in sys.argv
    # A test build only: the person's app must never start a second instance of itself.
    plist = os.path.join(os.path.dirname(os.path.realpath(CLI or "/")), "..", "Info.plist")
    bundle = subprocess.run(["plutil", "-extract", "CFBundleIdentifier", "raw", plist], capture_output=True, text=True).stdout.strip()
    if not bundle.endswith(".test"):
        sys.exit("use a test build: AGWEB_CLI=$(scripts/build.sh --test /tmp/agw-bench) scripts/bench.py")
    work = tempfile.mkdtemp(prefix="agwb-", dir="/tmp")  # short: the socket path inside the root caps near 104 bytes
    root = os.path.join(work, "r")
    for name, html in PAGES.items():
        with open(os.path.join(work, name + ".html"), "w") as f:
            f.write(html)
    with open(os.path.join(work, "blocklist.txt"), "w") as f:
        f.write("||127.0.0.1^*blockapi\n")
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), lambda *a: Quiet(*a, directory=work))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    # Its own root; no network: a local filter list and no update check.
    env = dict(os.environ, AGWEB_ROOT=root, AGWEB_INSTANT="1", AGWEB_ADBLOCK_LISTS=base + "/blocklist.txt", AGWEB_UPDATE_FEED=base + "/none.json")
    env.pop("AGWEB_WORKSPACE", None)
    env.pop("AGWEB_PROFILE", None)
    suite = "agweb.root" + root.replace("/", "_")
    agweb = os.path.realpath(CLI)
    app = os.path.dirname(os.path.dirname(agweb))  # .../Agweb.app/Contents
    results = {}
    try:
        for page in PAGES:
            subprocess.run([agweb, "-w", page, "open", f"{base}/{page}.html"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
        found = subprocess.run(["pgrep", "-f", app + "/MacOS/"], capture_output=True, text=True).stdout.split()
        if not found:
            sys.exit(f"agweb did not start from {agweb}")
        pid = int(found[0])
        for case, page, args in CASES:
            args = [a.format(url=f"{base}/{page}.html?again", dir=work) for a in args]
            results[case] = median_of(pid, [agweb, "-w", page] + args, env)
            print(f"  {case}: {results[case]['s']:.2f} s", file=sys.stderr)
        if with_playwright:
            subprocess.run(["playwright-cli", "-s=agweb-bench", "open", f"{base}/rapidoc.html"], cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(2)
            results["playwright-cli snapshot (165k lines)"] = median_of("playwright", ["playwright-cli", "-s=agweb-bench", "snapshot"], os.environ, cwd=work)
            subprocess.run(["playwright-cli", "-s=agweb-bench", "close"], cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        subprocess.run([agweb, "quit"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        server.shutdown()
        subprocess.run(["defaults", "delete", suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        plist = os.path.expanduser(f"~/Library/Preferences/{suite}.plist")
        if os.path.exists(plist):
            os.remove(plist)
        shutil.rmtree(work, ignore_errors=True)

    baseline = {}
    if os.path.exists(BASELINE):
        with open(BASELINE) as f:
            baseline = json.load(f)
    old = baseline.get("cases", {})
    flagged = 0
    print("| Case | Time | CPU | Peak RAM | Baseline | |")
    print("|---|---|---|---|---|---|")
    for case, r in results.items():
        was = old.get(case, {}).get("s")
        slower = was is not None and r["s"] > was * 1.25 and r["s"] - was > 0.1
        flagged += slower
        mark = "FAILED" if r["failed"] else "SLOWER" if slower else ""
        print(f"| {case} | {r['s']:.2f} s | {r['cpu']:.2f} s | {r['mb']} MB | {f'{was:.2f} s' if was is not None else '-'} | {mark} |")
    if baseline:
        print(f"\nBaseline: {baseline.get('commit', '?')} on {baseline.get('date', '?')}, {baseline.get('machine', '?')}")
    if save:
        commit = subprocess.run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
        machine = f"{platform.machine()}, macOS {platform.mac_ver()[0]}"
        with open(BASELINE, "w") as f:
            json.dump({"commit": commit, "date": time.strftime("%Y-%m-%d"), "machine": machine, "cases": results}, f, indent=1)
            f.write("\n")
        print(f"saved as the baseline: {BASELINE}")
    sys.exit(flagged)


if __name__ == "__main__":
    main()
