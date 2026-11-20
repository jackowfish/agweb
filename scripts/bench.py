#!/usr/bin/python3 -I
"""Times agweb's commands on big local pages, in an instance of its own, and compares with the saved baseline.

Run by hand before a release, on a quiet Mac (not in CI: timings need one, and the baseline is this Mac's):

    A=$(CC=/usr/bin/clang scripts/build.sh --test /tmp/agw-bench) && AGWEB_CLI=$A scripts/bench.py [--save] [--playwright]

Pages: like rapi-doc's API docs (nested shadow roots, a 165,000-line snapshot), 54,000 elements of form controls,
a long article, a 10,000-row table. Each page gets a fresh instance, quit after its cases, so a case's memory is
the instance with that one page open. Each case runs 3 times: the median wall time, the median CPU time of
the CLI call plus the app and the WebKit processes macOS counts as its, and their peak resident memory.
AGWEB_INSTANT=1: the pointer and typing don't move at a person's pace.

A case is flagged SLOWER past 125% of its baseline time plus 0.02 s, MORE RAM when the memory it adds (its peak over
the instance's size before it) is 100 MB over the baseline's, and FAILED when any run exits non-zero; the exit status
counts the flags. --save writes this run as the baseline
(scripts/bench-baseline.json), which a failed run can't be. --playwright also times playwright-cli's snapshot of the
rapi-doc page (its own session, headless), for comparison only: it is never flagged.
"""
import ctypes, http.server, json, os, platform, shutil, signal, socketserver, statistics, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "bench-baseline.json")
RUNS = 3
SESSION = "agweb-bench"
PLAYWRIGHT = "playwright-cli snapshot (rapidoc, 165k lines)"

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
ROWS = "<!doctype html><title>rows</title><body><button id=top>Top</button><input id=first>" + "".join(
    f'<div><input placeholder="field {i}"><button id=b{i}>Button {i}</button><input type=checkbox><span>row {i}</span><span>a</span><span>b</span><span>c</span><span>d</span></div>'
    for i in range(6000)) + "<label for=lab>Labelled</label><input id=lab></body>"
ARTICLE = "<!doctype html><title>article</title><body><article><h1>Article</h1>" + "".join(
    f"<h2>Part {i}</h2><p>" + "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt. " * 20 + "</p>"
    for i in range(400)) + "</article></body>"
TABLE = "<!doctype html><title>table</title><body><table><tr><th>id</th><th>name</th><th>amount</th></tr>" + "".join(
    f"<tr><td>{i}</td><td>Customer {i}</td><td>{i * 7 % 1000}.00</td></tr>" for i in range(10000)) + "</table></body>"
PAGES = {"rows": ROWS, "rapidoc": RAPIDOC, "article": ARTICLE, "table": TABLE}

# (case, page, agweb args; {run} is the run's number). Cases leave their page as they found it where they can, so
# the 3 runs do the same work.
CASES = [
    ("goto (54k)", "rows", ["goto", "{base}/rows.html?n={run}"]),
    ("snapshot (54k)", "rows", ["snapshot"]),
    ("click CSS (54k)", "rows", ["click", "#top"]),
    ("fill (54k)", "rows", ["fill", "#first", "text {run}"]),
    ("press (54k)", "rows", ["press", "End"]),
    ("click role= with a name (54k)", "rows", ["click", 'role=textbox[name="field 5999"]']),
    ("hover role= with a name (54k)", "rows", ["hover", 'role=button[name="Button 5999"]']),
    ("wait --text (54k)", "rows", ["wait", "--text=Labelled"]),
    ("text (54k)", "rows", ["text"]),
    ("text --all (54k)", "rows", ["text", "--all"]),
    ("eval returning 2 MB (54k)", "rows", ["eval", "document.body.outerHTML"]),
    ("screenshot (54k)", "rows", ["screenshot", "--filename={work}/rows.png"]),
    ("screenshot --full-page (54k)", "rows", ["screenshot", "--full-page", "--filename={work}/rows-full.png"]),
    ("snapshot (rapidoc)", "rapidoc", ["snapshot"]),
    ("snapshot --filename (rapidoc, 165k lines)", "rapidoc", ["snapshot", "--filename={work}/rapidoc.txt"]),
    ("find TRY (rapidoc)", "rapidoc", ["find", "TRY"]),
    ("find resource_4999/ (rapidoc)", "rapidoc", ["find", "resource_4999/"]),
    ("wait CSS in a shadow root (rapidoc)", "rapidoc", ["wait", 'input[data-pname="param_1"] >> nth=0']),
    ("snapshot #op77 in a shadow root (rapidoc)", "rapidoc", ["snapshot", "#op77"]),
    ("text (article)", "article", ["text"]),
    ("pdf (article)", "article", ["pdf", "--filename={work}/article.pdf"]),
    ("text --all (table)", "table", ["text", "--all"]),
    ("snapshot --filename (table)", "table", ["snapshot", "--filename={work}/table.txt"]),
]

responsible = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
responsible.argtypes, responsible.restype = [ctypes.c_int], ctypes.c_int


def processes(pids=None):
    """pid -> (ppid, resident KB, CPU seconds, command), for every process or only `pids`."""
    args = ["ps", "-o", "pid=,ppid=,rss=,time=,command="] + (["-p", ",".join(map(str, pids))] if pids else ["-ax"])
    table = {}
    for line in subprocess.run(args, capture_output=True, text=True).stdout.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        seconds = 0.0
        for chunk in parts[3].split(":"):
            seconds = seconds * 60 + float(chunk)
        table[int(parts[0])] = (int(parts[1]), int(parts[2]), seconds, parts[4])
    return table


def members(table, owner):
    """agweb (an app pid): the app and what macOS counts as its. Playwright: the daemon of our session and the
    browser under it. The CLI call itself is left out of both; its CPU comes from getrusage."""
    if isinstance(owner, int):
        return {pid for pid in table if pid == owner or responsible(pid) == owner}
    me = os.getpid()
    keep = {pid for pid, row in table.items() if SESSION in row[3] and row[0] != me and f"-s={SESSION}" not in row[3]}
    grew = True
    while grew:
        grew = False
        for pid, row in table.items():
            if row[0] in keep and pid not in keep:
                keep.add(pid)
                grew = True
    return keep


def measure(owner, command, env, cwd):
    """Runs `command`, sampling the tool's processes every 0.1 s: (wall s, CPU s, peak MB, MB added, error or None)."""
    table = processes()
    mine = members(table, owner)
    start = {pid: table[pid][2] for pid in mine}
    cpu, peak = dict(start), sum(table[pid][1] for pid in mine) / 1024
    before = peak
    done = threading.Event()

    def sample():
        nonlocal peak, mine
        rounds = 0
        while not done.is_set():
            rounds += 1
            if rounds % 10 == 0:  # WebKit processes started meanwhile, once a second
                mine = members(processes(), owner)
            now = processes(mine) if mine else {}
            peak = max(peak, sum(row[1] for row in now.values()) / 1024)
            for pid, row in now.items():
                cpu[pid] = row[2]
            done.wait(0.1)

    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    began = time.perf_counter()
    try:
        # The CLI's own CPU from wait4: RUSAGE_CHILDREN would count the sampler's ps calls too.
        with tempfile.TemporaryFile() as errors:
            child = subprocess.Popen(command, env=env, cwd=cwd, stdout=subprocess.DEVNULL, stderr=errors)
            try:
                _, status, usage = os.wait4(child.pid, 0)
            except BaseException:
                child.kill()  # stopped mid-case: the CLI call mustn't outlive the run
                raise
            child.returncode = os.waitstatus_to_exitcode(status)
            errors.seek(0)
            stderr = errors.read().decode(errors="replace")
    finally:
        wall = time.perf_counter() - began
        done.set()
        sampler.join()
    # A last sample, with processes started meanwhile: a short case may have had none, and growth at its end counts.
    mine = members(processes(), owner)
    now = processes(mine) if mine else {}
    peak = max(peak, sum(row[1] for row in now.values()) / 1024)
    for pid, row in now.items():
        cpu[pid] = row[2]
    cli = usage.ru_utime + usage.ru_stime
    error = None if child.returncode == 0 else (stderr.strip().splitlines() or [f"exit {child.returncode}"])[-1][:160]
    return wall, cli + sum(cpu[pid] - start.get(pid, 0.0) for pid in cpu), peak, peak - before, error


def case_result(owner, command_for_run, env, cwd):
    runs = [measure(owner, command_for_run(run), env, cwd) for run in range(RUNS)]
    errors = [r[4] for r in runs if r[4]]
    return {"s": round(statistics.median(r[0] for r in runs), 3), "cpu": round(statistics.median(r[1] for r in runs), 3),
            "mb": round(max(r[2] for r in runs)), "added": round(max(r[3] for r in runs)), "error": errors[0] if errors else None}


def quit_instance(agweb, root, ours):
    """Quits the instance on `root` and waits for the processes `ours()` lists to exit: the app exits a moment after
    answering, writing to the root and its settings meanwhile."""
    subprocess.run([agweb, "quit"], env={"AGWEB_ROOT": root, "PATH": os.environ.get("PATH", "")}, capture_output=True)
    for _ in range(50):
        if not ours():
            return
        time.sleep(0.1)
    left = sorted(ours())
    print(f"agweb (pid {', '.join(left)}) did not exit within 5 s; killed", file=sys.stderr)
    subprocess.run(["kill", "-9", *left], capture_output=True)  # only processes this run launched
    time.sleep(0.5)


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def stop(*_):
    raise KeyboardInterrupt  # SIGTERM or SIGHUP (a stopped background run): clean up as for Ctrl-C


def main():
    unknown = [a for a in sys.argv[1:] if a not in ("--save", "--playwright")]
    if unknown:
        sys.exit(f"unknown option {unknown[0]}; use --save, --playwright")
    save, with_playwright = "--save" in sys.argv, "--playwright" in sys.argv
    cli = os.environ.get("AGWEB_CLI", "")
    plist = os.path.join(os.path.dirname(os.path.realpath(cli or "/")), "..", "Info.plist")
    info = lambda key: subprocess.run(["plutil", "-extract", key, "raw", plist], capture_output=True, text=True).stdout.strip()
    # A test build only, launched from its own bundle (AGWEB_APP and every other AGWEB_ setting are dropped below):
    # the person's app must never start a second instance of itself.
    if not info("CFBundleIdentifier").endswith(".test"):
        sys.exit("use a test build: A=$(CC=/usr/bin/clang scripts/build.sh --test /tmp/agw-bench) && AGWEB_CLI=$A scripts/bench.py")
    if with_playwright and not shutil.which("playwright-cli"):
        sys.exit("--playwright needs playwright-cli on PATH")
    agweb = os.path.realpath(cli)
    binary = os.path.dirname(os.path.dirname(agweb)) + "/MacOS/"
    running = lambda: set(subprocess.run(["pgrep", "-f", binary], capture_output=True, text=True).stdout.split())
    already = running()
    ours = lambda: running() - already  # the instances this run launched
    work = tempfile.mkdtemp(prefix="agwb-", dir="/tmp")  # short: the socket path inside the root caps near 104 bytes
    root = os.path.join(work, "r")
    suite = "agweb.root" + root.replace("/", "_")  # Agweb.settingsSuite
    server, app, results, playwright_open = None, None, {}, False
    try:
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGHUP, stop)
        for name, html in PAGES.items():
            with open(os.path.join(work, name + ".html"), "w") as f:
                f.write(html)
        with open(os.path.join(work, "blocklist.txt"), "w") as f:
            f.write("||127.0.0.1^*blockapi\n")
        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), lambda *a: Quiet(*a, directory=work))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_address[1]}"
        # Its own root and nothing from the caller's AGWEB_ settings; no network: a local filter list, no update check.
        env = {k: v for k, v in os.environ.items() if not k.startswith("AGWEB_")}
        env.update(AGWEB_ROOT=root, AGWEB_INSTANT="1", AGWEB_ADBLOCK_LISTS=base + "/blocklist.txt", AGWEB_UPDATE_FEED=base + "/none.json")
        run = lambda *args: subprocess.run([agweb, *args], env=env, cwd=work, capture_output=True, text=True)
        for page in PAGES:
            # A fresh instance per page, so a case's memory is that page's, not what earlier pages left behind.
            before = running()
            opened = run("-w", page, "open", f"{base}/{page}.html")
            if opened.returncode != 0:
                raise SystemExit(f"could not open {page}: {(opened.stdout + opened.stderr).strip()}")
            new = running() - before
            if len(new) != 1:
                raise SystemExit(f"cannot tell which process is this instance: {sorted(new)}")
            app = int(new.pop())
            loaded = run("-w", page, "wait", "--load")
            if loaded.returncode != 0:
                raise SystemExit(f"{page} did not load: {(loaded.stdout + loaded.stderr).strip()}")
            time.sleep(1)  # the first layout and its background work, out of the first case
            for case, case_page, args in CASES:
                if case_page != page:
                    continue
                command = [agweb, "-w", page] + [a.format(base=base, work=work, run="{run}") for a in args]
                results[case] = case_result(app, lambda r, command=command: [a.replace("{run}", str(r)) for a in command], env, work)
                failed = results[case]["error"]
                print(f"  {case}: {results[case]['s']:.2f} s" + (f"  FAILED: {failed}" if failed else ""), file=sys.stderr)
            # Closed first: a workspace still open at quit is saved and reopened, loading, by the next page's instance.
            closed = run("-w", page, "close")
            if closed.returncode != 0:
                raise SystemExit(f"could not close {page}: {(closed.stdout + closed.stderr).strip()}")
            quit_instance(agweb, root, ours)
            app = None
        if with_playwright:
            playwright_open = True
            opened = subprocess.run(["playwright-cli", f"-s={SESSION}", "open", f"{base}/rapidoc.html"], cwd=work, capture_output=True, text=True)
            if opened.returncode != 0:  # comparison only: agweb's results still count
                results[PLAYWRIGHT] = {"s": 0, "cpu": 0, "mb": 0, "added": 0, "error": "could not open the page: " + (opened.stdout + opened.stderr).strip()[-200:]}
            else:
                time.sleep(2)
                results[PLAYWRIGHT] = case_result("playwright", lambda r: ["playwright-cli", f"-s={SESSION}", "snapshot"], dict(os.environ), work)
    except KeyboardInterrupt:
        results = None
    finally:
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):  # a second Ctrl-C mustn't cut the cleanup short
            signal.signal(sig, signal.SIG_IGN)
        if playwright_open:
            subprocess.run(["playwright-cli", f"-s={SESSION}", "close"], cwd=work, capture_output=True)
        quit_instance(agweb, root, ours)  # also when this run never found its instance
        if server:
            server.shutdown()
        subprocess.run(["defaults", "delete", suite], capture_output=True)
        prefs = os.path.expanduser(f"~/Library/Preferences/{suite}.plist")
        if os.path.exists(prefs):
            os.remove(prefs)
        shutil.rmtree(work, ignore_errors=True)
    if results is None:
        sys.exit("stopped; cleaned up")
    report(results, save, info("AgwebCommit"))


def report(results, save, commit):
    baseline = {}
    if os.path.exists(BASELINE):
        with open(BASELINE) as f:
            baseline = json.load(f)
    model = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()
    old, machine = baseline.get("cases", {}), f"{model} {platform.machine()}, macOS {platform.mac_ver()[0]}"
    flags = 0
    print("| Case | Time | CPU | Peak RAM (added) | Baseline time / RAM added | |")
    print("|---|---|---|---|---|---|")
    for case, r in results.items():
        was = old.get(case, {})
        marks = []
        if r["error"]:
            marks.append("FAILED: " + r["error"])
        if case != PLAYWRIGHT:  # for comparison only
            if "s" in was and r["s"] > was["s"] * 1.25 + 0.02:
                marks.append("SLOWER")
            if "added" in was and r["added"] > was["added"] + 100:
                marks.append("MORE RAM")
            flags += bool(marks)
        then = f"{was['s']:.2f} s / {was.get('added', '?')} MB" if "s" in was else "-"
        print(f"| {case} | {r['s']:.2f} s | {r['cpu']:.2f} s | {r['mb']} MB ({r['added']:+d}) | {then} | {', '.join(marks)} |")
    missing = [case for case in old if case not in results and case != PLAYWRIGHT]
    if missing:
        print(f"\nIn the baseline but not run: {', '.join(missing)}")
    if baseline:
        print(f"\nBaseline: {baseline.get('commit', '?')} on {baseline.get('date', '?')}, {baseline.get('machine', '?')}"
              + ("" if baseline.get("machine") == machine else f"; this Mac is {machine}, so compare with care"))
    if save:
        if any(r["error"] for case, r in results.items() if case != PLAYWRIGHT):
            sys.exit("not saved: a case failed")
        if not commit or commit.endswith("-dirty"):
            sys.exit(f"not saved: build from a committed tree (this build is {commit or 'unstamped'})")
        if (PLAYWRIGHT not in results or results[PLAYWRIGHT]["error"]) and PLAYWRIGHT in old:
            results[PLAYWRIGHT] = old[PLAYWRIGHT]
        results = {case: {k: v for k, v in r.items() if k != "error"} for case, r in results.items()}
        with open(BASELINE, "w") as f:
            json.dump({"commit": commit or "?", "date": time.strftime("%Y-%m-%d"), "machine": machine, "cases": results}, f, indent=1)
            f.write("\n")
        print(f"saved as the baseline: {BASELINE}")
    sys.exit(flags)


if __name__ == "__main__":
    main()
