# The selftest's proxies: SOCKS5 and an HTTP CONNECT proxy, each optionally asking for a
# username and password. Every connection is logged as "<kind> <host:port> <user or ->"; a name given with --map resolves
# only here, so a page on it loads only through the proxy.
#   proxy.py --socks PORT --http PORT --log FILE [--auth user:pass] [--map name=address]...
import argparse, base64, select, socket, struct, threading
from socketserver import StreamRequestHandler, ThreadingTCPServer

parser = argparse.ArgumentParser()
parser.add_argument("--socks", type=int)
parser.add_argument("--http", type=int)
parser.add_argument("--log", required=True)
parser.add_argument("--auth")
parser.add_argument("--map", action="append", default=[])
args = parser.parse_args()
names = dict(entry.split("=", 1) for entry in args.map)
lock = threading.Lock()


def log(line):
    with lock, open(args.log, "a") as f:
        f.write(line + "\n")


def connect(host, port):
    return socket.create_connection((names.get(host, host), port), timeout=10)


def pipe(a, b):
    a.settimeout(None)
    b.settimeout(None)
    sockets = [a, b]
    try:
        while True:
            ready, _, _ = select.select(sockets, [], [], 60)
            if not ready:
                return
            for s in ready:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        pass
    finally:
        for s in sockets:
            try:
                s.close()
            except OSError:
                pass


class Socks(StreamRequestHandler):
    def handle(self):
        r, w = self.rfile, self.wfile
        version, count = r.read(2)
        methods = r.read(count)
        user = "-"
        if args.auth:
            if 2 not in methods:
                log("socks5 refused: no username offered")
                return w.write(b"\x05\xff")
            w.write(b"\x05\x02")
            r.read(1)
            name = r.read(r.read(1)[0]).decode()
            password = r.read(r.read(1)[0]).decode()
            if f"{name}:{password}" != args.auth:
                log(f"socks5 refused: wrong credentials for {name}")
                return w.write(b"\x01\x01")
            w.write(b"\x01\x00")
            user = name
        else:
            w.write(b"\x05\x00")
        _, command, _, kind = r.read(4)
        if kind == 1:
            host = socket.inet_ntoa(r.read(4))
        elif kind == 3:
            host = r.read(r.read(1)[0]).decode()
        else:
            host = socket.inet_ntop(socket.AF_INET6, r.read(16))
        port = struct.unpack(">H", r.read(2))[0]
        log(f"socks5 {host}:{port} {user}")
        try:
            upstream = connect(host, port)
        except OSError:
            return w.write(b"\x05\x04\x00\x01\x00\x00\x00\x00\x00\x00")
        w.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        w.flush()
        pipe(self.connection, upstream)


class Http(StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline().decode("latin-1").strip()
        if not line:
            return
        headers = []
        while (header := self.rfile.readline().decode("latin-1")) not in ("\r\n", "\n", ""):
            headers.append(header.rstrip("\r\n"))
        user = "-"
        if args.auth:
            given = next((h.split(":", 1)[1].strip() for h in headers if h.lower().startswith("proxy-authorization:")), "")
            expected = "Basic " + base64.b64encode(args.auth.encode()).decode()
            if given != expected:
                log("http refused: " + ("wrong credentials" if given else "no credentials"))
                self.wfile.write(b'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="agweb"\r\n'
                                 b"Content-Length: 0\r\n\r\n")
                return
            user = args.auth.split(":", 1)[0]
        method, target, _ = line.split(" ", 2)
        # Network.framework's HTTP proxy tunnels every request, plain http:// on port 80 too.
        if method != "CONNECT":
            return self.wfile.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
        host, port = target.rsplit(":", 1)
        log(f"http {host}:{port} {user}")
        try:
            upstream = connect(host.strip("[]"), int(port))
        except OSError:
            return self.wfile.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        self.wfile.flush()
        pipe(self.connection, upstream)


ThreadingTCPServer.allow_reuse_address = True
ThreadingTCPServer.daemon_threads = True
servers = []
if args.socks:
    servers.append(ThreadingTCPServer(("127.0.0.1", args.socks), Socks))
if args.http:
    servers.append(ThreadingTCPServer(("127.0.0.1", args.http), Http))
for server in servers[1:]:
    threading.Thread(target=server.serve_forever, daemon=True).start()
log("ready")
servers[0].serve_forever()
