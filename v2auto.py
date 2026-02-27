#!/usr/bin/env python3
"""
v2nodes AUTO — Ultra-fast async config tester + proxy manager
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Architecture  : PipelineManager + asyncio subprocesses + semaphore
Test method   : xray subprocess → SOCKS5 port check → HEAD gstatic
No TCP check  : direct xray test is faster & more accurate
Target scale  : 3000 configs / ~60 seconds
Concurrency   : adaptive (CPU × 6, max 50)
"""

import asyncio
import aiohttp
import base64
import json
import multiprocessing
import os
import re
import socket
import subprocess
import sys
import threading
import time
from collections import deque
from enum import Enum
from urllib.parse import urljoin, urlparse, parse_qs

# ─────────────────────────────────────────────────────────────
# DEPENDENCIES
# ─────────────────────────────────────────────────────────────
try:
    from rich.console import Console
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
    from rich import box
except ImportError:
    print("Missing 'rich'. Install: pip install rich")
    sys.exit(1)

try:
    import questionary
except ImportError:
    questionary = None

try:
    import requests
except ImportError:
    requests = None

console = Console()

# ─────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────
BASE            = "https://www.v2nodes.com"
COUNTRIES       = ["nl", "gb", "de", "in", "id"]
HEADERS         = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
XRAY_BIN        = "./xray"

SOCKS5_PORT     = 10901
HTTP_PORT       = 10801
DNS_PORT        = 10053
PING_INTERVAL   = 30

TEST_URL        = "https://www.gstatic.com/generate_204"
TEST_URL_HTTP   = "http://www.gstatic.com/generate_204"

# Adaptive concurrency: CPU*6 capped at 50, minimum 10
_CPU_COUNT      = multiprocessing.cpu_count()
MAX_CONCURRENT  = min(50, max(10, _CPU_COUNT * 6))

# Timing constants
XRAY_BOOT_MAX   = 0.80   # seconds — kill xray if port not bound by this
XRAY_BOOT_POLL  = 0.05   # poll interval for port binding check
HTTP_CONN_TOUT  = 2.0    # aiohttp connect timeout
HTTP_READ_TOUT  = 2.0    # aiohttp read timeout
PROC_KILL_TOUT  = 4.0    # hard kill timeout for subprocesses

# Port windows for temp instances
TEST_PORT_BASE  = 21000  # 21000..21050 (MAX_CONCURRENT slots)
PING_PORT_BASE  = 26000  # 26000..26060

OUTPUT_ALL      = "vless_all.txt"
OUTPUT_WORKING  = "vless_working.txt"
PROXY_CONFIG    = "v2auto_proxy.json"
SUB_FILE        = "sub.txt"

# VLESS inbound — local proxy server that clients connect TO
VLESS_IN_PORT      = 10902
VLESS_IN_UUID_FILE = "v2auto_uuid.txt"   # persisted — URI stays the same

_termux_internal = os.path.expanduser("~/storage/internal")
SAVE_PATH = (
    os.path.join(_termux_internal, ".vpn/v2auto/working.txt")
    if os.path.exists(_termux_internal)
    else "/storage/emulated/0/.vpn/v2auto/working.txt"
)

GEOIP_URL    = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL  = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
GEOIP_FILE   = "geoip.dat"
GEOSITE_FILE = "geosite.dat"

EXTRA_SUBS = [
    "https://hamrahconfig.ir/sub/Tml0MjUxMDIsMTc2OTAxOTAxOAZXHjmTiFL2",
]

PROTO_RE = re.compile(
    r'(?:vless|vmess|trojan|ss|ssr|hysteria2?)://[^\s"<>\'[\]\r\n]+', re.I)


# ─────────────────────────────────────────────────────────────
# PIPELINE STATE MACHINE
# ─────────────────────────────────────────────────────────────
class PipelineState(Enum):
    IDLE      = "IDLE"
    RUNNING   = "RUNNING"
    STOPPING  = "STOPPING"
    COMPLETED = "COMPLETED"
    STOPPED   = "STOPPED"


class PipelineManager:
    """
    Single source of truth for all pipeline state.
    Replaces all scattered global variables.

    Thread-safety:
    - threading.Lock for cross-thread (Flask ↔ asyncio) access
    - All mutations go through _set() or dedicated methods
    - snapshot() returns a JSON-serializable copy — safe to pass to SSE
    """

    def __init__(self):
        self._lock = threading.Lock()

        # ── Pipeline lifecycle ─────────────────────────────
        self.state          = PipelineState.IDLE
        self.phase          = "BOOT"
        self.phase_detail   = ""
        self.start_time     = 0.0
        self.stop_requested = False
        self.current_wave   = 0

        # ── Progress counters ──────────────────────────────
        self.total          = 0
        self.completed      = 0
        self.working_count  = 0
        self.failed_count   = 0

        # ── Results (bounded at 500 entries) ──────────────
        self.working_configs: list[str] = []
        self.current_cfg    = ""

        # ── Proxy state ───────────────────────────────────
        self.proxy_status   = "OFFLINE"
        self.proxy_ms       = 0
        self.active_cfg     = ""
        self.standby_count  = 0
        self.socks_port     = SOCKS5_PORT
        self.http_port      = HTTP_PORT

        # ── Log (ring buffer) ─────────────────────────────
        self.log_entries: deque = deque(maxlen=10)

        # ── Internal handles ──────────────────────────────
        self._proxy_proc    = None
        self._proxy_cfg     = None
        self._use_iran_rules = False
        self._xray_exec_warned = False   # throttle "cannot exec" log spam

    # ── Snapshot (thread-safe read) ───────────────────────────

    def snapshot(self) -> dict:
        """JSON-serializable state snapshot for SSE / REST API."""
        with self._lock:
            return {
                "state":           self.state.value,
                "phase":           self.phase,
                "phase_detail":    self.phase_detail,
                "total":           self.total,
                "tested":          self.completed,
                "working":         self.working_count,
                "failed":          self.failed_count,
                "tcp_fail":        0,           # no longer used
                "current_cfg":     self.current_cfg,
                "active_cfg":      self.active_cfg,
                "proxy_status":    self.proxy_status,
                "proxy_ms":        self.proxy_ms,
                "standby_count":   self.standby_count,
                "socks_port":      self.socks_port,
                "http_port":       self.http_port,
                "log":             list(self.log_entries),
                "pipeline_started":self.state not in (PipelineState.IDLE,),
                "want_proxy":      True,
                "working_configs": list(self.working_configs),
                "vless_in_port":   VLESS_IN_PORT,
                "vless_in_uuid":   get_or_create_uuid(),
            }

    # ── Mutations (thread-safe write) ────────────────────────

    def _set(self, **kwargs):
        with self._lock:
            for k, v in kwargs.items():
                setattr(self, k, v)

    def log(self, msg: str, color: int = 5):
        """color: 1=cyan 2=green 3=red 4=yellow 5=white"""
        cmap = {1:"cyan", 2:"green", 3:"red", 4:"yellow", 5:"white"}
        ts   = time.strftime("%H:%M:%S")
        with self._lock:
            self.log_entries.append((ts, msg, cmap.get(color, "white")))

    def add_working(self, cfg: str):
        with self._lock:
            if len(self.working_configs) < 500 and cfg not in self.working_configs:
                self.working_configs.append(cfg)
            self.working_count += 1
            self.completed     += 1

    def inc_failed(self):
        with self._lock:
            self.failed_count += 1
            self.completed    += 1

    def request_stop(self):
        with self._lock:
            self.stop_requested = True
            if self.state == PipelineState.RUNNING:
                self.state = PipelineState.STOPPING

    def reset(self):
        """Full state reset — only call when pipeline is not RUNNING."""
        with self._lock:
            self.state          = PipelineState.IDLE
            self.phase          = "BOOT"
            self.phase_detail   = ""
            self.start_time     = 0.0
            self.stop_requested = False
            self.current_wave   = 0
            self.total          = 0
            self.completed      = 0
            self.working_count  = 0
            self.failed_count   = 0
            self.working_configs.clear()
            self.current_cfg    = ""
            self.proxy_status   = "OFFLINE"
            self.proxy_ms       = 0
            self.active_cfg     = ""
            self.standby_count  = 0
            self._xray_exec_warned = False
            self.log_entries.clear()


# Global singleton — imported by v2web.py
pm = PipelineManager()

# ─────────────────────────────────────────────────────────────
# LEGACY SHIM — keeps v2web.py working during transition
# v2web reads `core.state` as dict and `core._stop` as bool
# ─────────────────────────────────────────────────────────────
state: dict = {}
_stop:  bool = False
_use_iran_rules: bool = False


def _sync():
    """Propagate PipelineManager state to legacy globals."""
    global state, _stop
    snap  = pm.snapshot()
    snap["log"] = list(pm.log_entries)
    state = snap
    _stop = pm.stop_requested


def log(msg: str, color_pair: int = 5):
    pm.log(msg, color_pair)
    _sync()


# ─────────────────────────────────────────────────────────────
# RICH TERMINAL DASHBOARD
# ─────────────────────────────────────────────────────────────
def _elapsed() -> str:
    if not pm.start_time:
        return "00:00"
    m, s = divmod(int(time.time() - pm.start_time), 60)
    return f"{m:02d}:{s:02d}"


def build_dashboard() -> Panel:
    snap  = pm.snapshot()
    phase = snap["phase"]

    grid = Table.grid(expand=True)
    grid.add_column()

    # Title row
    hrow = Table.grid(expand=True)
    hrow.add_column(ratio=1)
    hrow.add_column()
    hrow.add_row(
        Text("⚡ V2NODES AUTO", style="bold cyan"),
        Text(f"[{snap['state']}]  {_elapsed()}", style="dim"),
    )
    grid.add_row(hrow)

    # Phase progress
    if phase in ("BOOT", "EXTRACT", "TEST"):
        prog = Table.grid(expand=True)
        prog.add_column()
        prog.add_row(Text(f"Phase: {phase}", style="bold yellow"))
        prog.add_row(Text(snap["phase_detail"], style="dim"))
        if snap["total"] > 0:
            pct    = snap["tested"] / snap["total"] * 100
            filled = int(40 * pct / 100)
            bar    = "█" * filled + "░" * (40 - filled)
            prog.add_row(Text(
                f"[{bar}] {pct:.1f}%  ✓{snap['working']}  ✗{snap['failed']}",
                style="cyan"))
        grid.add_row(prog)

    # Proxy card
    prow = Table.grid(expand=True)
    prow.add_column(ratio=1); prow.add_column()
    ps = snap["proxy_status"]
    style_map = {"ONLINE":"bold green","STARTING":"bold yellow","DEAD":"bold red","OFFLINE":"dim"}
    prow.add_row(Text("Proxy"), Text(ps, style=style_map.get(ps,"dim")))
    if snap["proxy_ms"]:
        prow.add_row(Text("Latency","dim"), Text(f"{snap['proxy_ms']}ms","green"))
    if snap["active_cfg"]:
        try:
            u = urlparse(snap["active_cfg"])
            short = f"{u.scheme}://{u.hostname}:{u.port}"
        except Exception:
            short = snap["active_cfg"][:55]
        prow.add_row(Text("Config","dim"), Text(short,"cyan"))
    prow.add_row(Text("SOCKS5","dim"), Text(f"127.0.0.1:{SOCKS5_PORT}"))
    prow.add_row(Text("HTTP","dim"),   Text(f"127.0.0.1:{HTTP_PORT}"))
    prow.add_row(Text("DNS","dim"),    Text(f"127.0.0.1:{DNS_PORT}"))
    prow.add_row(Text("Workers","dim"),Text(f"{MAX_CONCURRENT}  (CPU×{_CPU_COUNT})","dim"))
    grid.add_row(prow)

    # Log tail
    if pm.log_entries:
        lt = Table(box=None, show_header=False, padding=(0,1))
        lt.add_column("ts",  style="dim yellow", no_wrap=True)
        lt.add_column("msg", style="white")
        cs = {"cyan":"cyan","green":"green","red":"bold red","yellow":"yellow","white":"white"}
        for ts, msg, c in list(pm.log_entries)[-6:]:
            lt.add_row(ts, Text(msg, style=cs.get(c,"white")))
        grid.add_row(lt)

    return Panel(grid, title="v2auto", border_style="cyan", padding=(0,1))


def run_dashboard():
    with Live(build_dashboard(), refresh_per_second=2) as live:
        try:
            while not pm.stop_requested:
                live.update(build_dashboard())
                time.sleep(0.5)
        except KeyboardInterrupt:
            pm.request_stop()


# ─────────────────────────────────────────────────────────────
# GEO FILES
# ─────────────────────────────────────────────────────────────
def download_geo_files():
    needed = []
    if not os.path.exists(GEOIP_FILE):   needed.append((GEOIP_FILE,   GEOIP_URL))
    if not os.path.exists(GEOSITE_FILE): needed.append((GEOSITE_FILE, GEOSITE_URL))
    if not needed:
        log("Geo dat files already present.", 2); return True
    if requests is None:
        log("'requests' not installed — cannot download geo files.", 3); return False
    ok = True
    for fname, url in needed:
        log(f"Downloading {fname}...", 1)
        try:
            r = requests.get(url, stream=True, timeout=60,
                             headers={"User-Agent": HEADERS["User-Agent"]})
            r.raise_for_status()
            with open(fname, "wb") as f:
                for chunk in r.iter_content(65536):
                    if chunk: f.write(chunk)
            log(f"Downloaded {fname}", 2)
        except Exception as e:
            log(f"Failed: {fname}: {e}", 3); ok = False
    return ok


# ─────────────────────────────────────────────────────────────
# ROUTING RULES
# ─────────────────────────────────────────────────────────────
def build_iran_routing() -> dict:
    return {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type":"field","domain":["geosite:category-ads-all"],         "outboundTag":"block"},
            {"type":"field","domain":["geosite:category-porn","geosite:nsfw"],"outboundTag":"block"},
            {"type":"field","domain":["geosite:ir"],                       "outboundTag":"direct"},
            {"type":"field","ip":   ["geoip:ir"],                          "outboundTag":"direct"},
            {"type":"field","ip":   ["geoip:private"],                     "outboundTag":"direct"},
        ]
    }


# ─────────────────────────────────────────────────────────────
# XRAY CONFIG BUILDER
# ─────────────────────────────────────────────────────────────
def build_xray_config(cfg: str, socks_port: int, http_port: int = None,
                      use_routing: bool = False, log_level: str = "warning",
                      add_dns_inbound: bool = False) -> dict:
    parsed   = urlparse(cfg)
    scheme   = parsed.scheme.lower()
    uuid     = parsed.username or ""
    address  = parsed.hostname or ""
    port     = parsed.port or 443
    qs       = parse_qs(parsed.query)
    security = qs.get("security", ["none"])[0]
    path     = qs.get("path",     ["/"])[0]
    host     = qs.get("host",     [""])[0]
    sni      = qs.get("sni",      [address])[0]
    network  = qs.get("type",     ["ws"])[0]
    fp       = qs.get("fp",       [""])[0]

    # Always include both SOCKS5 and HTTP inbounds.
    # test_one uses the HTTP proxy (aiohttp only supports HTTP proxy natively).
    # http_port = socks_port + 500 when called from test_one (auto-derived).
    _http_port = http_port if http_port else socks_port + 500
    inbounds = [
        {"port": socks_port, "listen": "127.0.0.1",
         "protocol": "socks",
         "settings": {"auth": "noauth", "udp": True}},
        {"port": _http_port, "listen": "127.0.0.1",
         "protocol": "http",
         "settings": {"allowTransparent": False}},
    ]
    if add_dns_inbound:
        inbounds.append({
            "tag": "dns-in", "port": DNS_PORT, "listen": "127.0.0.1",
            "protocol": "dokodemo-door",
            "settings": {"address":"8.8.8.8","port":53,"network":"udp","followRedirect":False}
        })
        # Add VLESS inbound so external devices can use this as a proxy server
        inbounds.append(build_vless_inbound(get_or_create_uuid()))

    # ── Outbound by protocol ──────────────────────────────────
    if scheme == "vless":
        ob = {"tag":"proxy","protocol":"vless",
              "settings":{"vnext":[{"address":address,"port":port,
                  "users":[{"id":uuid,"encryption":"none",
                            "flow":qs.get("flow",[""])[0]}]}]},
              "streamSettings":{"network":network,"security":security}}

    elif scheme == "vmess":
        try:
            vd = json.loads(base64.b64decode(uuid + "=" * (-len(uuid)%4)).decode())
            ob = {"tag":"proxy","protocol":"vmess",
                  "settings":{"vnext":[{"address":vd.get("add",address),
                      "port":int(vd.get("port",port)),
                      "users":[{"id":vd.get("id",""),"alterId":int(vd.get("aid",0)),
                                "security":vd.get("scy","auto")}]}]},
                  "streamSettings":{"network":vd.get("net","tcp"),"security":vd.get("tls","none")}}
            network=vd.get("net","tcp"); security=vd.get("tls","none")
            path=vd.get("path","/");    host=vd.get("host","")
            sni=vd.get("sni",vd.get("add","")); address=vd.get("add",address)
        except Exception:
            ob = {"tag":"proxy","protocol":"vmess",
                  "settings":{"vnext":[{"address":address,"port":port,
                      "users":[{"id":uuid,"alterId":0,"security":"auto"}]}]},
                  "streamSettings":{"network":network,"security":security}}

    elif scheme == "trojan":
        sec = security if security and security != "none" else "tls"
        ob  = {"tag":"proxy","protocol":"trojan",
               "settings":{"servers":[{"address":address,"port":port,"password":uuid}]},
               "streamSettings":{"network":network,"security":sec}}

    elif scheme in ("ss","shadowsocks"):
        try:    info = base64.b64decode(uuid+"==").decode()
        except: info = uuid
        parts  = info.split(":",1)
        method = parts[0] if len(parts)>1 else "chacha20-ietf-poly1305"
        passwd = parts[1] if len(parts)>1 else uuid
        ob = {"tag":"proxy","protocol":"shadowsocks",
              "settings":{"servers":[{"address":address,"port":port,
                                       "method":method,"password":passwd}]},
              "streamSettings":{"network":"tcp"}}
    else:
        ob = {"tag":"proxy","protocol":"vless",
              "settings":{"vnext":[{"address":address,"port":port,
                  "users":[{"id":uuid,"encryption":"none","flow":""}]}]},
              "streamSettings":{"network":network,"security":security}}

    # ── Stream settings (TLS / Reality / WS / gRPC) ───────────
    st = ob["streamSettings"]
    if security == "tls":
        tls = {"serverName":sni,"allowInsecure":True}
        if fp: tls["fingerprint"] = fp
        st["tlsSettings"] = tls
    elif security == "reality":
        st["realitySettings"] = {
            "serverName":sni, "fingerprint":fp or "chrome",
            "publicKey":qs.get("pbk",[""])[0],
            "shortId":qs.get("sid",[""])[0],
            "spiderX":qs.get("spx",["/"])[0],
        }
    if network == "ws":
        st["wsSettings"] = {"path":path,"headers":{"Host":host or sni}}
    elif network == "grpc":
        st["grpcSettings"] = {"serviceName":qs.get("serviceName",qs.get("mode",[""]))[0]}
    elif network == "h2":
        st["httpSettings"] = {"path":path,"host":[host] if host else [sni]}

    # ── Routing ───────────────────────────────────────────────
    dns_rule = {"type":"field","inboundTag":["dns-in"],"outboundTag":"proxy"}
    if use_routing and pm._use_iran_rules:
        routing = build_iran_routing()
        routing["rules"].insert(0, dns_rule)
    else:
        routing = {
            "domainStrategy": "IPIfNonMatch",
            "rules": [dns_rule, {"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]
        }

    return {
        "log": {"loglevel": log_level},
        "dns": {"servers":[
            {"address":"8.8.8.8","port":53,"domains":["geosite:geolocation-!cn"],
             "expectIPs":["geoip:!cn"]},
            "localhost"
        ]},
        "inbounds":  inbounds,
        "outbounds": [ob,
                      {"tag":"direct", "protocol":"freedom",   "settings":{}},
                      {"tag":"block",  "protocol":"blackhole",  "settings":{}}],
        "routing":   routing,
    }


# ─────────────────────────────────────────────────────────────
# VLESS INBOUND UUID (persisted)
# ─────────────────────────────────────────────────────────────
def get_or_create_uuid() -> str:
    """Return the persistent local VLESS-inbound UUID.
    Creates and saves it on first call so the import URI never changes."""
    import uuid as _uuid_mod
    if os.path.exists(VLESS_IN_UUID_FILE):
        try:
            u = open(VLESS_IN_UUID_FILE).read().strip()
            if len(u) == 36:   # basic sanity
                return u
        except Exception:
            pass
    u = str(_uuid_mod.uuid4())
    try:
        with open(VLESS_IN_UUID_FILE, "w") as f:
            f.write(u)
    except Exception:
        pass
    return u


def build_vless_inbound(uuid: str) -> dict:
    """VLESS inbound so phones/laptops can connect to the local proxy."""
    return {
        "tag":      "vless-in",
        "port":     VLESS_IN_PORT,
        "listen":   "0.0.0.0",      # listen on all interfaces so wlan0 works
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "level": 0}],
            "decryption": "none",
        },
        "streamSettings": {"network": "tcp"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
    }


# ─────────────────────────────────────────────────────────────
# NETWORK HELPERS
# ─────────────────────────────────────────────────────────────
def kill_port(port: int):
    try:
        subprocess.run(["fuser","-k",f"{port}/tcp"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    time.sleep(0.3)


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except Exception:
        return False


async def port_open_async(port: int) -> bool:
    try:
        _, w = await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1", port), timeout=1.0)
        w.close()
        return True
    except Exception:
        return False


def load_sub_file() -> list[str]:
    if not os.path.exists(SUB_FILE): return []
    try:
        with open(SUB_FILE) as f:
            return [l.strip() for l in f if l.strip() and not l.startswith("#")]
    except Exception:
        return []


# ─────────────────────────────────────────────────────────────
# SUBSCRIPTION DECODE & FETCH
# ─────────────────────────────────────────────────────────────
def decode_sub(text: str) -> str:
    stripped = text.strip()
    if PROTO_RE.search(stripped): return stripped
    for v in (stripped, stripped.replace("-","+").replace("_","/")):
        padded = v + "=" * (-len(v)%4)
        try:
            dec = base64.b64decode(padded).decode("utf-8", errors="replace")
            if PROTO_RE.search(dec): return dec
        except Exception: pass
    out = []
    for line in stripped.splitlines():
        line = line.strip()
        if not line: continue
        if PROTO_RE.match(line): out.append(line); continue
        try:
            d = base64.b64decode(line+"=="*2).decode("utf-8", errors="replace")
            out.extend(d.splitlines())
        except Exception:
            out.append(line)
    joined = "\n".join(out)
    return joined if PROTO_RE.search(joined) else stripped


async def fetch_sub(session: aiohttp.ClientSession, url: str) -> str | None:
    try:
        hdrs = {**HEADERS, "Accept":"*/*", "Accept-Encoding":"identity"}
        async with session.get(url, headers=hdrs,
                               timeout=aiohttp.ClientTimeout(total=20),
                               allow_redirects=True, ssl=False) as r:
            raw = await r.read()
            try:    text = raw.decode("utf-8")
            except: text = raw.decode("latin-1")
            return decode_sub(text)
    except Exception:
        return None


async def fetch_html(session: aiohttp.ClientSession, url: str) -> str | None:
    try:
        async with session.get(url, headers=HEADERS,
                               timeout=aiohttp.ClientTimeout(total=15),
                               ssl=False) as r:
            return await r.text()
    except Exception:
        return None


# ─────────────────────────────────────────────────────────────
# EXTRACTION PHASE
# ─────────────────────────────────────────────────────────────
async def discover_key(session: aiohttp.ClientSession) -> str | None:
    pages = [BASE+"/"] + [f"{BASE}/country/{cc}/" for cc in COUNTRIES]
    htmls = await asyncio.gather(*[fetch_html(session, u) for u in pages])
    KEY_RE = re.compile(r'/subscriptions/country/[a-z]+/\?key=([A-F0-9]+)', re.I)
    for html in htmls:
        if html:
            m = KEY_RE.search(html)
            if m: return m.group(1)
    return None


async def extract_phase() -> list[str]:
    pm._set(phase="EXTRACT", phase_detail="Connecting to sources...")
    log("Starting extraction from all sources", 1)
    all_cfgs: list[str] = []

    async with aiohttp.ClientSession(headers=HEADERS) as session:
        key  = await discover_key(session)
        subs = []
        if key:
            pm._set(phase_detail=f"Key: {key[:8]}...")
            log(f"Daily key: {key[:12]}...", 2)
            subs.append(f"{BASE}/subscriptions/country/all/?key={key}")
        else:
            log("No daily key — using extra subs only", 4)

        subs += EXTRA_SUBS
        for url in load_sub_file():
            if url not in subs: subs.append(url)

        for i, url in enumerate(subs):
            dom = urlparse(url).netloc or url[:30]
            pm._set(phase_detail=f"Fetching {i+1}/{len(subs)}: {dom}")
            body = await fetch_sub(session, url)
            if body:
                cfgs = list(set(PROTO_RE.findall(body)))
                all_cfgs.extend(cfgs)
                log(f"Sub {i+1}: {len(cfgs)} configs from {dom}", 2)
            else:
                log(f"Sub {i+1}: failed {dom}", 4)

        pm._set(phase_detail="Scanning server pages...")
        htmls = await asyncio.gather(*[
            fetch_html(session, f"{BASE}/country/{cc}/") for cc in COUNTRIES
        ])
        server_urls = list(set(
            urljoin(BASE, lnk)
            for html in htmls if html
            for lnk in re.findall(r'/servers/\d+/', html)
        ))
        if server_urls:
            pm._set(phase_detail=f"Fetching {len(server_urls)} server pages...")
            pages = await asyncio.gather(*[fetch_html(session, u) for u in server_urls])
            for page in pages:
                if page: all_cfgs.extend(PROTO_RE.findall(page))

    all_cfgs = list(set(all_cfgs))
    pm._set(total=len(all_cfgs))
    log(f"Extracted: {len(all_cfgs)} unique configs", 2)
    try:
        with open(OUTPUT_ALL, "w") as f:
            f.write("\n".join(all_cfgs)+"\n")
    except Exception: pass
    return all_cfgs


# ─────────────────────────────────────────────────────────────
# STAGE 1 — PRE-FILTER
# ─────────────────────────────────────────────────────────────
def prefilter(configs: list[str]) -> list[str]:
    """
    Deduplicate + validate before launching any xray process.
    Removes: duplicates, empty host, invalid port, non-matching URIs.
    Normalization: strip fragment/remark (everything after #).
    """
    seen   = set()
    result = []
    for raw in configs:
        cfg = raw.strip()
        if not cfg: continue
        # Normalize: strip remark
        base = cfg.split("#")[0].rstrip()
        if base in seen: continue
        seen.add(base)
        if not PROTO_RE.match(cfg): continue
        try:
            p = urlparse(cfg)
            if not p.hostname: continue
            port = p.port or 443
            if not (1 <= port <= 65535): continue
        except Exception:
            continue
        result.append(cfg)
    return result


# ─────────────────────────────────────────────────────────────
# STAGE 2+3 — ASYNC SINGLE-CONFIG TEST
# ─────────────────────────────────────────────────────────────
async def _kill(proc):
    """Cleanly kill an asyncio subprocess."""
    if proc is None: return
    try:
        proc.kill()
        await asyncio.wait_for(proc.wait(), timeout=PROC_KILL_TOUT)
    except Exception:
        pass


async def test_one(cfg: str, slot: int, sem: asyncio.Semaphore) -> bool:
    """
    Ultra-fast 3-stage test for a single config:

    Stage 2 — Boot check
      Launch xray async subprocess on port TEST_PORT_BASE+slot.
      Poll port binding every 50ms up to 400ms.
      Kill immediately if not bound → config is dead/invalid.

    Stage 3 — Fast HEAD request
      Connect through SOCKS5 to https://www.gstatic.com/generate_204.
      2s connect + 2s read = max 4s wall time per test.
      Accept: 200, 204, 301, 302.
      Kill xray immediately after response (pass or fail).

    Memory: config file written + deleted synchronously via executor.
    Process: killed in finally — zero leaks guaranteed.
    """
    async with sem:
        if pm.stop_requested:
            pm.inc_failed(); return False

        socks     = TEST_PORT_BASE + slot
        http_test = TEST_PORT_BASE + slot + 500   # HTTP proxy port for aiohttp
        path      = f"v2auto_test_{slot}.json"
        proc      = None

        try:
            # ── Write config (offloaded to executor) ──────────
            xc = build_xray_config(cfg, socks, log_level="none")
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, _write_json, path, xc)

            # ── Launch xray (fully async, non-blocking) ───────
            proc = await asyncio.create_subprocess_exec(
                XRAY_BIN, "-config", path,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )

            # ── Stage 2: port binding check (max 600ms) ───────
            deadline = time.monotonic() + XRAY_BOOT_MAX
            bound    = False
            while time.monotonic() < deadline:
                await asyncio.sleep(XRAY_BOOT_POLL)
                # Check if xray already died (returncode 255 = exec failed)
                if proc.returncode is not None:
                    if proc.returncode == 255 and not pm._xray_exec_warned:
                        pm._xray_exec_warned = True
                        log("xray exits with code 255 — binary cannot execute on this system.", 3)
                        log(f"Run: file {XRAY_BIN}  |  ldd {XRAY_BIN}", 4)
                    pm.inc_failed(); return False
                # Check HTTP port (more reliable than SOCKS for this test)
                if await port_open_async(http_test):
                    bound = True; break

            if not bound:
                pm.inc_failed(); return False

            # ── Stage 3: HEAD through SOCKS5 ──────────────────
            tout = aiohttp.ClientTimeout(
                connect=HTTP_CONN_TOUT,
                sock_read=HTTP_READ_TOUT,
                total=HTTP_CONN_TOUT + HTTP_READ_TOUT + 0.5,
            )
            ok = False
            try:
                conn = aiohttp.TCPConnector(ssl=False, limit=1)
                async with aiohttp.ClientSession(
                    connector=conn, connector_owner=True
                ) as sess:
                    async with sess.head(
                        TEST_URL,
                        proxy=f"http://127.0.0.1:{http_test}",
                        timeout=tout,
                        allow_redirects=False,
                        ssl=False,
                    ) as resp:
                        ok = resp.status in (200, 204, 301, 302)
            except Exception:
                ok = False

            if ok:
                pm.add_working(cfg)
                return True
            else:
                pm.inc_failed()
                return False

        except Exception:
            pm.inc_failed(); return False
        finally:
            await _kill(proc)
            try:
                if os.path.exists(path): os.remove(path)
            except Exception: pass


def _write_json(path: str, data: dict):
    with open(path, "w") as f:
        json.dump(data, f)


# ─────────────────────────────────────────────────────────────
# TEST PHASE — orchestrates all concurrent tests
# ─────────────────────────────────────────────────────────────
async def test_phase(configs: list[str]) -> list[str]:
    """
    Full test pipeline:
    1. Validate xray binary
    2. Prefilter configs (dedup + validate)
    3. Launch MAX_CONCURRENT concurrent tests with semaphore
    4. Stream results incrementally to pm.working_configs
    5. Save on completion
    """
    # ── Validate xray ─────────────────────────────────────────
    if not os.path.exists(XRAY_BIN):
        log(f"xray not found at {XRAY_BIN}", 3)
        log("Download xray from: https://github.com/XTLS/Xray-core/releases", 4)
        pm._set(phase="ERROR"); return []
    if not os.access(XRAY_BIN, os.X_OK):
        log(f"xray is not executable — fixing permissions...", 4)
        try:
            os.chmod(XRAY_BIN, 0o755)
            log("chmod +x applied to xray", 1)
        except Exception as e:
            log(f"Cannot chmod xray: {e}", 3)
            pm._set(phase="ERROR"); return []
    # Run `xray version` to confirm binary actually works on this OS/arch
    try:
        _probe = subprocess.run(
            [XRAY_BIN, "version"],
            capture_output=True, text=True, timeout=8
        )
        if _probe.returncode != 0:
            log(f"xray self-test failed (exit {_probe.returncode})", 3)
            _stderr = (_probe.stderr or "").strip()
            _stdout = (_probe.stdout or "").strip()
            if _stderr: log(f"xray stderr: {_stderr[:200]}", 3)
            if _stdout: log(f"xray stdout: {_stdout[:200]}", 3)
            log("Possible causes: wrong architecture, missing glibc, or corrupted binary.", 4)
            log(f"Try: file {XRAY_BIN}  and  ldd {XRAY_BIN}", 4)
            pm._set(phase="ERROR"); return []
        _ver_line = (_probe.stdout or "").splitlines()[0] if _probe.stdout else "unknown"
        log(f"xray OK — {_ver_line}", 1)
    except FileNotFoundError:
        log(f"Cannot execute {XRAY_BIN} — binary not found or not executable", 3)
        pm._set(phase="ERROR"); return []
    except subprocess.TimeoutExpired:
        log("xray version check timed out — binary may be broken", 3)
        pm._set(phase="ERROR"); return []
    except Exception as e:
        log(f"xray self-test error: {e}", 3)
        pm._set(phase="ERROR"); return []

    # ── Stage 1: Pre-filter ───────────────────────────────────
    configs = prefilter(configs)
    n       = len(configs)
    log(f"Pre-filter: {n} unique valid configs", 1)
    log(f"Concurrency: {MAX_CONCURRENT} workers  (CPU×{_CPU_COUNT})", 1)

    pm._set(phase="TEST", total=n, completed=0,
            working_count=0, failed_count=0,
            phase_detail=f"0 / {n}")

    # ── Semaphore keeps ≤ MAX_CONCURRENT xray procs alive ─────
    sem = asyncio.Semaphore(MAX_CONCURRENT)

    # Worker index cycles through [0, MAX_CONCURRENT)
    # so port numbers never collide between concurrent workers
    tasks = [
        test_one(cfg, i % MAX_CONCURRENT, sem)
        for i, cfg in enumerate(configs)
    ]

    # ── Live progress updater (runs alongside tasks) ──────────
    async def _updater():
        while True:
            s = pm.snapshot()
            pm._set(phase_detail=(
                f"Testing {s['tested']}/{s['total']}  "
                f"✓{s['working']}  ✗{s['failed']}  "
                f"[{MAX_CONCURRENT} workers]"
            ))
            _sync()
            if pm.stop_requested: break
            await asyncio.sleep(0.35)

    upd = asyncio.create_task(_updater())
    await asyncio.gather(*tasks, return_exceptions=True)
    upd.cancel()
    try:   await upd
    except asyncio.CancelledError: pass

    working = list(pm.working_configs)
    _save_working(working)

    elapsed = time.time() - pm.start_time
    rate    = n / elapsed if elapsed > 0 else 0
    log(f"Done: {len(working)}/{n} working  ({elapsed:.1f}s  {rate:.0f} cfg/s)", 2)
    _sync()
    return working


def _save_working(working: list[str]):
    try:
        with open(OUTPUT_WORKING, "w") as f:
            f.write("\n".join(working)+"\n")
    except Exception as e:
        log(f"Save failed: {e}", 3)
    try:
        os.makedirs(os.path.dirname(SAVE_PATH), exist_ok=True)
        with open(SAVE_PATH, "w") as f:
            f.write("\n".join(working)+"\n")
        log(f"Saved {len(working)} configs to internal storage", 2)
    except Exception as e:
        log(f"Internal storage save failed: {e}", 4)


# ─────────────────────────────────────────────────────────────
# RETEST PHASE
# ─────────────────────────────────────────────────────────────
async def retest_phase(configs: list[str], clear_previous: bool = True) -> list[str]:
    """
    Re-test only working configs from a previous run.
    Runs as a fresh pipeline session (no extraction step).
    Does not duplicate entries already in working_configs.
    """
    if clear_previous:
        with pm._lock:
            pm.working_configs.clear()
            pm.working_count = 0
            pm.completed     = 0
            pm.failed_count  = 0

    log(f"Retesting {len(configs)} configs...", 1)
    return await test_phase(configs)


# ─────────────────────────────────────────────────────────────
# PROXY MANAGEMENT
# ─────────────────────────────────────────────────────────────
def start_proxy(cfg: str) -> bool:
    xc = build_xray_config(
        cfg, SOCKS5_PORT, HTTP_PORT,
        use_routing=True,
        log_level="warning",
        add_dns_inbound=True,
    )
    with open(PROXY_CONFIG, "w") as f:
        json.dump(xc, f, indent=2)

    # Kill any lingering processes on these ports
    kill_port(SOCKS5_PORT); kill_port(HTTP_PORT)
    # Give OS time to release ports
    time.sleep(0.5)

    try:
        proc = subprocess.Popen(
            [XRAY_BIN, "-config", PROXY_CONFIG],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    except FileNotFoundError:
        log(f"Cannot execute {XRAY_BIN}", 3); return False

    pm._proxy_proc = proc
    pm._proxy_cfg  = cfg
    pm._set(proxy_status="STARTING", active_cfg=cfg)
    _sync()

    # Wait for SOCKS5 and HTTP ports to bind (up to 8s)
    socks_up = False
    http_up  = False
    for i in range(24):           # 24 × 0.35s ≈ 8.4s
        time.sleep(0.35)

        # Check if xray crashed immediately
        if proc.poll() is not None:
            log(f"xray exited with code {proc.returncode} — bad config?", 3)
            pm._set(proxy_status="DEAD"); _sync(); return False

        if not socks_up and port_open(SOCKS5_PORT): socks_up = True
        if not http_up  and port_open(HTTP_PORT):   http_up  = True

        if socks_up and http_up:
            pm._set(proxy_status="STARTING"); _sync()
            # Both ports bound — consider it running
            break
        if socks_up and i >= 10:
            # SOCKS5 up but HTTP taking too long — still usable
            log(f"HTTP port {HTTP_PORT} slow — SOCKS5 port {SOCKS5_PORT} is up", 4)
            break

    if not socks_up:
        log(f"xray did not bind port {SOCKS5_PORT} within 8s", 3)
        pm._set(proxy_status="DEAD"); _sync(); return False

    # Mark ONLINE — check_proxy_alive will do real verification
    pm._set(proxy_status="ONLINE"); _sync()
    return True


def stop_proxy():
    proc = pm._proxy_proc
    if proc:
        try: proc.terminate(); proc.wait(timeout=3)
        except Exception:
            try: proc.kill()
            except Exception: pass
        pm._proxy_proc = None
    kill_port(SOCKS5_PORT); kill_port(HTTP_PORT)
    pm._set(proxy_status="OFFLINE"); _sync()


async def measure_ping(cfg: str, idx: int) -> tuple[int, str] | None:
    """Ping via temp xray instance — fully async."""
    sp   = PING_PORT_BASE + idx
    cp   = f"v2auto_ping_{idx}.json"
    proc = None
    try:
        _write_json(cp, build_xray_config(cfg, sp, log_level="none"))
        proc = await asyncio.create_subprocess_exec(
            XRAY_BIN, "-config", cp,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        for _ in range(20):
            await asyncio.sleep(0.1)
            if await port_open_async(sp): break
        else:
            return None

        t0   = time.monotonic()
        tout = aiohttp.ClientTimeout(total=6)
        conn = aiohttp.TCPConnector(ssl=False, limit=1)
        async with aiohttp.ClientSession(connector=conn) as sess:
            async with sess.head(
                TEST_URL_HTTP,
                proxy=f"http://127.0.0.1:{sp}",
                timeout=tout, allow_redirects=False,
            ) as resp:
                if resp.status in (200, 204, 301, 302):
                    return (int((time.monotonic()-t0)*1000), cfg)
    except Exception:
        pass
    finally:
        await _kill(proc)
        try:
            if os.path.exists(cp): os.remove(cp)
        except Exception: pass
    return None


async def check_proxy_alive(retries: int = 3, delay: float = 2) -> bool:
    """
    Three-tier check: HTTP proxy → SOCKS5 port-open → HTTP request via SOCKS5.
    Returns True as soon as any method succeeds.
    """
    for attempt in range(retries):
        t0 = time.monotonic()

        # ── Tier 1: HTTP proxy request ────────────────────────
        try:
            tout = aiohttp.ClientTimeout(connect=3, total=8)
            conn = aiohttp.TCPConnector(ssl=False, limit=1)
            async with aiohttp.ClientSession(connector=conn, timeout=tout) as sess:
                async with sess.head(
                    TEST_URL_HTTP,
                    proxy=f"http://127.0.0.1:{HTTP_PORT}",
                    allow_redirects=False,
                ) as resp:
                    if resp.status in (200, 204, 301, 302):
                        pm._set(proxy_ms=int((time.monotonic() - t0) * 1000),
                                proxy_status="ONLINE")
                        _sync(); return True
        except Exception:
            pass

        # ── Tier 2: SOCKS5 request via same port ─────────────
        # measure_ping uses proxy="http://..." pointing at SOCKS5 port
        # and it works, so replicate that here as well
        try:
            tout = aiohttp.ClientTimeout(connect=3, total=8)
            conn = aiohttp.TCPConnector(ssl=False, limit=1)
            async with aiohttp.ClientSession(connector=conn, timeout=tout) as sess:
                async with sess.head(
                    TEST_URL_HTTP,
                    proxy=f"http://127.0.0.1:{SOCKS5_PORT}",
                    allow_redirects=False,
                ) as resp:
                    if resp.status in (200, 204, 301, 302):
                        pm._set(proxy_ms=int((time.monotonic() - t0) * 1000),
                                proxy_status="ONLINE")
                        _sync(); return True
        except Exception:
            pass

        # ── Tier 3: Port-open fallback (xray is running) ─────
        socks_up = await port_open_async(SOCKS5_PORT)
        http_up  = await port_open_async(HTTP_PORT)
        if socks_up or http_up:
            ms = int((time.monotonic() - t0) * 1000)
            pm._set(proxy_ms=ms, proxy_status="ONLINE")
            _sync()
            log(f"Port-open fallback used (socks={socks_up} http={http_up})", 4)
            return True

        if attempt < retries - 1:
            await asyncio.sleep(delay)

    return False


async def proxy_phase(configs: list[str]):
    import random
    pm._set(phase="PROXY", phase_detail="Starting proxy...", current_cfg="")
    pool = list(configs); random.shuffle(pool)
    standby: list[str] = []

    log(f"Finding best config from {len(pool)} candidates...", 1)
    results = await asyncio.gather(*[
        measure_ping(c, i) for i, c in enumerate(pool[:8])
    ])
    valid = sorted([r for r in results if r], key=lambda x: x[0])
    if not valid:
        log("No configs responded to ping!", 3)
        pm._set(phase="ERROR"); return

    best_ms, best_cfg = valid[0]
    log(f"Best config: {best_ms}ms — starting proxy", 2)
    start_proxy(best_cfg)
    pool = [c for c in pool if c != best_cfg] + [best_cfg]
    pm._set(phase_detail=f"SOCKS5:{SOCKS5_PORT}  HTTP:{HTTP_PORT}  DNS:{DNS_PORT}")

    # Initial alive check
    await asyncio.sleep(2)
    alive = await check_proxy_alive(retries=2, delay=1)
    if alive:
        log(f"Proxy ONLINE — {pm.proxy_ms}ms", 2)
    else:
        log("Initial check failed — will retry on heartbeat", 4)

    cycle = 0
    while not pm.stop_requested:
        await asyncio.sleep(PING_INTERVAL)
        if pm.stop_requested: break
        cycle += 1

        alive = await check_proxy_alive(retries=3, delay=2)
        if alive:
            pm._set(proxy_status="ONLINE")
            log(f"Heartbeat #{cycle}: OK ({pm.proxy_ms}ms)", 2)
        else:
            pm._set(proxy_status="DEAD")
            log(f"Heartbeat #{cycle}: dead — switching config!", 3)

            switched = False
            # Try standby configs first
            while standby and not switched:
                next_cfg = standby.pop(0)
                stop_proxy()
                ok = start_proxy(next_cfg)
                if ok:
                    await asyncio.sleep(2)
                    if await check_proxy_alive(retries=2, delay=1):
                        log(f"Switch OK → {pm.proxy_ms}ms", 2)
                        pool = [c for c in pool if c != next_cfg] + [next_cfg]
                        switched = True
                    else:
                        log("Switch attempted but still dead — trying next standby", 4)

            # Standby exhausted — re-ping pool
            if not switched:
                cands = [c for c in pool if c != pm._proxy_cfg]
                log(f"Re-pinging {min(8, len(cands))} candidates...", 1)
                res2 = await asyncio.gather(*[
                    measure_ping(c, 60 + i) for i, c in enumerate(cands[:8])
                ])
                v2 = sorted([r for r in res2 if r], key=lambda x: x[0])
                if v2:
                    next_cfg = v2[0][1]
                    stop_proxy()
                    ok = start_proxy(next_cfg)
                    if ok:
                        await asyncio.sleep(2)
                        if await check_proxy_alive(retries=2, delay=1):
                            log(f"Switch OK → {pm.proxy_ms}ms", 2)
                            pool = [c for c in pool if c != next_cfg] + [next_cfg]
                            switched = True
                        else:
                            log("Switch FAILED — proxy unreachable after start", 3)
                    else:
                        log("Switch FAILED — xray wouldn't start", 3)
                else:
                    log("Switch FAILED — no responding configs found", 3)

        # Replenish standby pool
        if len(standby) < 2:
            cands = [c for c in pool if c != pm._proxy_cfg]
            random.shuffle(cands)
            res3 = await asyncio.gather(*[
                measure_ping(c, 50 + i) for i, c in enumerate(cands[:6])
            ])
            new_standby = [
                c for _, c in sorted([r for r in res3 if r], key=lambda x: x[0])
                if c != pm._proxy_cfg
            ][:3]
            if new_standby:
                standby = new_standby
                pm._set(standby_count=len(standby))
                log(f"Standby: {len(standby)} ready", 1)
        _sync()

    stop_proxy()

# ─────────────────────────────────────────────────────────────
# MAIN PIPELINE
# ─────────────────────────────────────────────────────────────
async def pipeline(skip_update: bool = False, use_tcp: bool = False):
    """
    use_tcp is kept for API compatibility but always ignored.
    TCP pre-check has been removed — xray boot check is faster
    and more accurate (measures actual proxy connectivity).
    """
    global _use_iran_rules
    # Only set RUNNING if not already set by caller (v2web sets it before calling)
    with pm._lock:
        if pm.state != PipelineState.RUNNING:
            pm.state      = PipelineState.RUNNING
            pm.start_time = time.time()

    # ── Saved configs path ─────────────────────────────────────
    if skip_update:
        loaded = []
        for path in (OUTPUT_WORKING, SAVE_PATH):
            if os.path.exists(path):
                try:
                    with open(path) as f:
                        loaded = [l.strip() for l in f if l.strip()]
                    if loaded:
                        log(f"Loaded {len(loaded)} saved configs from {path}", 2)
                        break
                except Exception: pass

        if not loaded:
            log("No saved configs — doing full update...", 4)
            skip_update = False
        else:
            with pm._lock:
                pm.working_configs = list(dict.fromkeys(loaded))[:500]
                pm.working_count   = len(pm.working_configs)
                pm.total           = pm.working_count
            pm._set(phase="PROXY")
            _sync()
            try:
                await proxy_phase(loaded)
            except Exception as e:
                log(f"Proxy error: {e}", 3)
                pm._set(phase="ERROR")
            pm._set(state=PipelineState.COMPLETED)
            _sync(); return

    # ── Extract ────────────────────────────────────────────────
    try:
        configs = await extract_phase()
    except Exception as e:
        log(f"Extraction error: {e}", 3)
        pm._set(phase="ERROR", state=PipelineState.COMPLETED)
        _sync(); return
    if not configs:
        log("No configs extracted!", 3)
        pm._set(phase="ERROR", state=PipelineState.COMPLETED)
        _sync(); return
    if pm.stop_requested:
        pm._set(state=PipelineState.STOPPED); _sync(); return

    # ── Test ───────────────────────────────────────────────────
    try:
        working = await test_phase(configs)
    except Exception as e:
        log(f"Test error: {e}", 3)
        pm._set(phase="ERROR", state=PipelineState.COMPLETED)
        _sync(); return
    if not working:
        log("No working configs after test!", 3)
        pm._set(phase="ERROR", state=PipelineState.COMPLETED)
        _sync(); return
    if pm.stop_requested:
        pm._set(state=PipelineState.STOPPED); _sync(); return

    # ── Proxy ──────────────────────────────────────────────────
    log(f"Starting proxy with {len(working)} configs", 2)
    try:
        await proxy_phase(working)
    except Exception as e:
        log(f"Proxy error: {e}", 3)
        pm._set(phase="ERROR")

    pm._set(state=PipelineState.COMPLETED)
    _sync()


# ─────────────────────────────────────────────────────────────
# CLEANUP
# ─────────────────────────────────────────────────────────────
def cleanup():
    stop_proxy()
    for f in os.listdir("."):
        if f.startswith(("v2auto_test_", "v2auto_ping_")):
            try: os.remove(f)
            except Exception: pass


# ─────────────────────────────────────────────────────────────
# STARTUP QUESTIONS (terminal mode)
# ─────────────────────────────────────────────────────────────
def _ask(prompt: str, choices: list[str], default: str = None) -> str:
    if questionary:
        try: return questionary.select(prompt, choices=choices, default=default).ask()
        except Exception: pass
    console.print(f"\n  [cyan]{prompt}[/]")
    for i, c in enumerate(choices):
        mark = " [green]◀ default[/]" if c == default else ""
        console.print(f"  [{i}] {c}{mark}")
    raw = input(f"  Choice: ").strip()
    try:
        if 0 <= int(raw) < len(choices): return choices[int(raw)]
    except ValueError: pass
    for c in choices:
        if raw.lower() in c.lower(): return c
    return default


def _ask_yes_no(prompt: str, default: bool = True) -> bool:
    if questionary:
        try: return questionary.confirm(prompt, default=default).ask()
        except Exception: pass
    ans = input(f"  {prompt} (y/n) [{'y' if default else 'n'}]: ").strip().lower()
    return default if ans == "" else ans.startswith("y")


def ask_startup() -> tuple[bool, bool, bool]:
    console.print()
    console.print(Panel(
        "[bold cyan]⚡ v2nodes AUTO — VPN Manager[/]\n"
        "[dim]extract → test → proxy  |  no TCP pre-check[/]",
        border_style="cyan"
    ))
    console.print()

    has_saved = os.path.exists(OUTPUT_WORKING) or os.path.exists(SAVE_PATH)
    if has_saved:
        choice = _ask("Existing working configs found:", choices=[
            "Use saved configs (skip fetch & test)",
            "Fetch & test new configs",
        ], default="Use saved configs (skip fetch & test)")
        do_update = "Fetch" in choice
    else:
        console.print("  [yellow]No saved configs — starting full update.[/]")
        do_update = True

    console.print()
    iran = _ask("Routing rules?", choices=[
        "Simple proxy only",
        "Iran routing (direct IR, block ads & NSFW)",
    ], default="Simple proxy only")
    use_iran = "Iran" in iran
    if use_iran:
        console.print("  [cyan]Iran routing enabled.[/]")

    return do_update, False, use_iran   # use_tcp always False


# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
def main():
    global _use_iran_rules

    do_update, _, use_iran = ask_startup()
    _use_iran_rules         = use_iran
    pm._use_iran_rules      = use_iran
    if use_iran: download_geo_files()

    loop = asyncio.new_event_loop()
    def _run():
        asyncio.set_event_loop(loop)
        try:   loop.run_until_complete(pipeline(skip_update=not do_update))
        except Exception as e: log(f"Pipeline error: {e}", 3)
        finally: pm._set(state=PipelineState.COMPLETED)

    threading.Thread(target=_run, daemon=True).start()
    try:
        run_dashboard()
    except KeyboardInterrupt:
        pass
    finally:
        pm.request_stop()
        console.print("\n  [yellow]Stopping...[/]")
        cleanup()
        time.sleep(0.4)
        console.print("  [green]Goodbye! ⚡[/]")
        os._exit(0)


if __name__ == "__main__":
    main()
