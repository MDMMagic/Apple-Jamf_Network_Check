#!/usr/bin/env bash

# Name        - jamf_network_test.sh
# Author      - MDM Magic
# Description - ests network connectivity for Jamf Pro and (optionally) Apple services, then generates a self-contained HTML report.
# Version     - 1.0
# Date        - 2026-06-19

#
# Usage:
#   ./jamf_network_test.sh [--apple] [--microsoft] [--google] [--output FILE] [--timeout SECS] [--verbose] [--no-install]
#
# --apple    Also run Apple platform network requirement tests (hosts read live from support.apple.com/101555)
# --microsoft Also test every Microsoft 365 / Intune endpoint (read live from endpoints.office.com)
# --google   Also test Google Workspace, Android Enterprise and Chrome Enterprise hosts
# --output   Path for the HTML report (default: jamf_network_report_<ts>.html)
# --timeout  Per-connection timeout in seconds (default: 5)
# --verbose  Print each result to stdout as it runs
# --no-install Don't install Xcode Command Line Tools (python3) when they're missing on macOS

# ── Bootstrap ─────────────────────────────────────────────────────────────────
INCLUDE_APPLE=false
INCLUDE_MICROSOFT=false
INCLUDE_GOOGLE=false
OUTPUT_FILE="jamf_network_report_$(date +%Y%m%d_%H%M%S).html"
TIMEOUT=5
VERBOSE=false
INSTALL_DEV_TOOLS=true

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --apple)   INCLUDE_APPLE=true ;;
        --microsoft) INCLUDE_MICROSOFT=true ;;
        --google)  INCLUDE_GOOGLE=true ;;
        --output)  OUTPUT_FILE="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        --verbose) VERBOSE=true ;;
        --no-install) INSTALL_DEV_TOOLS=false ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --apple          Include Apple network requirement tests (live from support.apple.com/101555)
  --microsoft      Include all Microsoft 365 / Intune endpoints (live from endpoints.office.com)
  --google         Include Google Workspace, Android Enterprise and Chrome Enterprise hosts
  --output FILE    HTML report path (default: jamf_network_report_<timestamp>.html)
  --timeout SECS   Connection timeout per test (default: 5)
  --verbose        Print each result to stdout during the run
  --no-install     Don't install Xcode Command Line Tools (python3) if missing on macOS
  -h, --help       Show this help
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# ── Terminal colour helpers ───────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'

# ── Globals ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0
RESULTS=()   # "category|host|port|protocol|description|status|latency_ms|note"
IP_TARGETS=()   # "category|host|port" for every TCP test whose host resolved (input to the IP checks)
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/jamf_network_test.XXXXXX") || exit 1
trap '[[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"' EXIT
HOSTNAME_LOCAL=$(hostname 2>/dev/null || echo "unknown")
RUN_DATE=$(date "+%Y-%m-%d %H:%M:%S %Z")

# ── Millisecond timestamp (macOS + Linux compatible) ──────────────────────────
ms_now() {
    if date +%s%3N 2>/dev/null | grep -qE '^[0-9]{13}$'; then
        date +%s%3N
    else
        python3 -c "import time; print(int(time.time()*1000))"
    fi
}

# ── Jamf published IP / FQDN list (fetched live each run) ─────────────────────
# Source: https://learn.jamf.com/r/en-US/jamf-ip-address-list/Permitting_InboundOutbound_Traffic_with_Jamf
JAMF_IP_LIST_URL="https://engineering.jamf.com/tc-docs-public-ip-lists/public-ips.json"
JAMF_IP_DATE=""
JAMF_IP_ENTRIES=()   # "service|traffic|provider|region|ip prefixes (space-sep)|fqdns (space-sep)"

# Print one pipe-delimited line per entry, using jq if present, else python3
parse_jamf_ip_list() {
    local json="$1"
    if command -v jq &>/dev/null; then
        jq -r '"date|" + (.publish_date // ""),
               (.public_ips[] | ["entry", .service, .traffic, .provider, .region,
                 ((.ip_prefixes // []) | join(" ")), ((.fqdns // []) | join(" "))] | join("|"))' \
            <<< "$json"
    elif have_python; then
        python3 -c '
import json, sys
d = json.load(sys.stdin)
print("date|" + d.get("publish_date", ""))
for e in d.get("public_ips", []):
    print("|".join(["entry", e.get("service", ""), e.get("traffic", ""), e.get("provider", ""), e.get("region", ""),
                    " ".join(e.get("ip_prefixes", [])), " ".join(e.get("fqdns", []))]))
' <<< "$json"
    fi
}

fetch_jamf_ip_list() {
    local json line
    json=$(curl -fsSL --max-time "$(( TIMEOUT * 2 ))" "$JAMF_IP_LIST_URL" 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            date\|*)  JAMF_IP_DATE="${line#date|}" ;;
            entry\|*) JAMF_IP_ENTRIES+=("${line#entry|}") ;;
        esac
    done < <(parse_jamf_ip_list "$json" 2>/dev/null)
    [[ ${#JAMF_IP_ENTRIES[@]} -gt 0 ]]
}

# Friendly names for the service keys used in the Jamf JSON
jamf_service_label() {
    case "$1" in
        jamf_pro_cloud)                  echo "Jamf Pro (Cloud)" ;;
        jamf_cloud_services)             echo "Jamf Cloud Services" ;;
        jamf_cloud_distribution_service) echo "Jamf Cloud Distribution Service (JCDS)" ;;
        jamf_ztna_endpoint)              echo "Jamf ZTNA Endpoint" ;;
        *)                               echo "$1" ;;
    esac
}

# ── Apple network requirements (parsed live from support.apple.com) ──────────
APPLE_REQS_URL="https://support.apple.com/en-us/101555"
APPLE_PORTS_URL="https://support.apple.com/en-us/103229"
APPLE_ENTRIES=()   # "section|host|ports|protocols|description"
APPLE_SOURCE="built-in list"

# python3 is usable (on macOS, /usr/bin/python3 is only a stub until Command Line Tools are installed)
have_python() {
    command -v python3 &>/dev/null || return 1
    [[ "$(uname)" != "Darwin" || "$(command -v python3)" != "/usr/bin/python3" ]] || xcode-select -p &>/dev/null
}

# Install the Xcode Command Line Tools headlessly via softwareupdate (root needed: sudo is used when
# not already root, non-interactively when there's no terminal, e.g. under a Jamf policy)
install_dev_tools() {
    local marker="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    local label rc sudo_cmd=()
    if [[ $EUID -ne 0 ]]; then
        if [[ -t 0 ]]; then sudo_cmd=(sudo); else sudo_cmd=(sudo -n); fi
    fi
    "${sudo_cmd[@]}" touch "$marker" 2>/dev/null || return 1
    # The marker makes softwareupdate list the Command Line Tools; pick the newest one
    label=$(softwareupdate -l 2>/dev/null \
        | sed -nE 's/^[[:space:]]*\* (Label: )?(Command Line Tools.*)$/\2/p' | sort -V | tail -n1)
    if [[ -n "$label" ]]; then
        "${sudo_cmd[@]}" softwareupdate -i "$label" &>/dev/null
        rc=$?
    else
        rc=1
    fi
    "${sudo_cmd[@]}" rm -f "$marker" 2>/dev/null
    [[ $rc -eq 0 ]] && have_python
}

APPLE_RANGES="17.0.0.0/8"   # replaced by the CIDRs published on the page when it downloads
APPLE_RANGES_SOURCE="built-in"

# Download Apple's network requirements page once; its CIDR ranges feed the IP checks
fetch_apple_page() {
    local ranges
    curl -fsSL --max-time "$(( TIMEOUT * 2 ))" "$APPLE_REQS_URL" -o "$WORK_DIR/apple.html" 2>/dev/null || return 1
    ranges=$(grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}' "$WORK_DIR/apple.html" | sort -u | paste -sd ' ' -)
    if [[ -n "$ranges" ]]; then
        APPLE_RANGES="$ranges"
        APPLE_RANGES_SOURCE="support.apple.com/101555"
    fi
}

# Pull every Hosts/Ports/Protocol table row from Apple's network requirements page
load_apple_requirements() {
    local line
    have_python && [[ -s "$WORK_DIR/apple.html" ]] || return 1
    while IFS= read -r line; do
        APPLE_ENTRIES+=("$line")
    done < <(python3 -c '
import re, sys
from html.parser import HTMLParser

class Tables(HTMLParser):
    def __init__(self):
        super().__init__()
        self.heading = ""; self.h = None; self.row = None; self.cell = None
    def handle_starttag(self, tag, attrs):
        if tag in ("h2", "h3"): self.h = ""
        elif tag == "tr": self.row = []
        elif tag in ("td", "th") and self.row is not None: self.cell = ""
        elif tag == "br" and self.cell is not None: self.cell += " "
    def handle_endtag(self, tag):
        if tag in ("h2", "h3") and self.h is not None:
            self.heading = " ".join(self.h.split()); self.h = None
        elif tag in ("td", "th") and self.cell is not None:
            self.row.append(" ".join(self.cell.split()).replace("|", "/")); self.cell = None
        elif tag == "tr" and self.row is not None:
            r, self.row = self.row, None
            # Hosts | Ports | Protocol | OS | Description | ...
            if len(r) < 5 or not re.fullmatch(r"[0-9][0-9, ]*", r[1]): return
            for host in r[0].replace(",", " ").split():
                if re.fullmatch(r"[*\w.-]+\.[a-z]+", host):
                    print("|".join([self.heading, host, r[1], r[2], r[4]]))
    def handle_data(self, data):
        if self.cell is not None: self.cell += data
        if self.h is not None: self.h += data

Tables().feed(sys.stdin.read())
' < "$WORK_DIR/apple.html" 2>/dev/null)
    [[ ${#APPLE_ENTRIES[@]} -gt 0 ]] && APPLE_SOURCE="live from support.apple.com/101555"
    [[ ${#APPLE_ENTRIES[@]} -gt 0 ]]
}

# Run one test per host / port / protocol from the live Apple list (duplicates skipped)
run_apple_live() {
    local entry heading host ports protos desc category port proto key prev="" seen=" "
    for entry in "${APPLE_ENTRIES[@]}"; do
        IFS='|' read -r heading host ports protos desc <<< "$entry"
        category="$heading"
        [[ "$category" == Apple* ]] || category="Apple $category"
        if [[ "$heading" != "$prev" ]]; then
            printf "      %s\n" "$heading"
            prev="$heading"
        fi
        for port in ${ports//,/ }; do
            for proto in ${protos//[,\/]/ }; do
                [[ "$proto" == "UDP" ]] || proto="TCP"   # "SSH", "and", etc. are TCP
                key="${host}:${port}/${proto}"
                [[ "$seen" == *" $key "* ]] && continue
                seen+="$key "
                run_test "$category" "$host" "$port" "$proto" "$desc"
            done
        done
    done
}

# Concrete host to test for a wildcard entry: a known-good example, else the base domain
wildcard_test_host() {
    local host="$1" port="$2"
    [[ "$host" == "*.push.apple.com" && "$port" == "2197" ]] && { echo "api.push.apple.com"; return; }
    case "$host" in
        \*.push.apple.com)          echo "1-courier.push.apple.com" ;;
        \*.apple-cloudkit.com)      echo "api.apple-cloudkit.com" ;;
        \*.gc.apple.com)            echo "service.gc.apple.com" ;;
        \*.appattest.apple.com)     echo "register.appattest.apple.com" ;;
        \*.apple-mapkit.com)        echo "api.apple-mapkit.com" ;;
        \*.apple-livephotoskit.com) echo "cdn.apple-livephotoskit.com" ;;
        \*.apzones.com)             echo "idmsaapz-mdn.apzones.com" ;;
        \*.cdn-apple.com)           echo "appleid.cdn-apple.com" ;;
        \*.icloud.apple.com)        echo "api.icloud.apple.com" ;;
        \*.iwork.apple.com)         echo "publish.iwork.apple.com" ;;
        \*.smoot.apple.com)         echo "api.smoot.apple.com" ;;
        \*.manage.microsoft.com)    echo "enrollment.manage.microsoft.com" ;;
        \*.microsoftonline.com)     echo "login.microsoftonline.com" ;;
        \*.googleapis.com)          echo "www.googleapis.com" ;;
        \*.gstatic.com)             echo "www.gstatic.com" ;;
        \*.googleusercontent.com)   echo "lh3.googleusercontent.com" ;;
        \*.gvt1.com)                echo "edgedl.me.gvt1.com" ;;
        \*.gvt2.com)                echo "beacons.gvt2.com" ;;
        \*.ggpht.com)               echo "lh3.ggpht.com" ;;
        \*.googlevideo.com)         echo "redirector.googlevideo.com" ;;
        \*.youtube-nocookie.com)    echo "www.youtube-nocookie.com" ;;
        \*.ytimg.com)               echo "i.ytimg.com" ;;
        *\**)                       wildcard_base "$host" ;;
        *)                          echo "$host" ;;
    esac
}

# Domain under a wildcard: "*.example.com", "*cdn.example.com", "autodiscover.*.example.com"
#   -> "example.com", "cdn.example.com", "example.com"
wildcard_base() {
    local base="${1#*\*}"
    echo "${base#.}"
}

# ── Google published IP ranges (fetched live each run; report reference only) ──
GOOG_RANGES_URL="https://www.gstatic.com/ipranges/goog.json"
GCLOUD_RANGES_URL="https://www.gstatic.com/ipranges/cloud.json"
GOOGLE_DATE=""
GOOGLE_SERVICES_EXACT=false
GOOGLE_ENTRIES=()   # "services|IPv4 or IPv6|prefixes (space-sep)"  or  "cloud|scope|prefixes (space-sep)"

# Google's guidance: Google services = goog.json minus cloud.json (cloud ranges belong to Cloud customers)
fetch_google_ranges() {
    local goog cloud line
    goog=$(curl -fsSL --max-time "$(( TIMEOUT * 2 ))" "$GOOG_RANGES_URL" 2>/dev/null) || return 1
    cloud=$(curl -fsSL --max-time "$(( TIMEOUT * 2 ))" "$GCLOUD_RANGES_URL" 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            date\|*)  GOOGLE_DATE="${line#date|}" ;;
            exact\|*) GOOGLE_SERVICES_EXACT=true ;;
            *)        GOOGLE_ENTRIES+=("$line") ;;
        esac
    done < <(
        if have_python; then
            GOOG="$goog" CLOUD="$cloud" python3 -c '
import ipaddress, json, os
goog, cloud = json.loads(os.environ["GOOG"]), json.loads(os.environ["CLOUD"])
net = lambda p: ipaddress.ip_network(p.get("ipv4Prefix") or p.get("ipv6Prefix"))
cloud_nets = [net(p) for p in cloud["prefixes"]]
services = []
for n in map(net, goog["prefixes"]):
    parts = [n]
    for c in cloud_nets:
        if c.version != n.version: continue
        nxt = []
        for p in parts:
            if c.subnet_of(p): nxt += p.address_exclude(c)
            elif not p.subnet_of(c): nxt.append(p)
        parts = nxt
    services += parts
print("date|" + goog.get("creationTime", ""))
print("exact|true")
for v in (4, 6):
    print("services|IPv%d|%s" % (v, " ".join(map(str, ipaddress.collapse_addresses(n for n in services if n.version == v)))))
scopes = {}
for p in cloud["prefixes"]:
    scopes.setdefault(p.get("scope", ""), []).append(p.get("ipv4Prefix") or p.get("ipv6Prefix"))
for scope in sorted(scopes):
    print("cloud|%s|%s" % (scope, " ".join(scopes[scope])))
'
        elif command -v jq &>/dev/null; then
            jq -r '"date|" + (.creationTime // ""),
                   "services|IPv4|" + ([.prefixes[].ipv4Prefix // empty] | join(" ")),
                   "services|IPv6|" + ([.prefixes[].ipv6Prefix // empty] | join(" "))' <<< "$goog"
            jq -r '.prefixes | group_by(.scope)[] |
                   "cloud|" + .[0].scope + "|" + ([.[] | .ipv4Prefix // .ipv6Prefix] | join(" "))' <<< "$cloud"
        fi 2>/dev/null
    )
    [[ ${#GOOGLE_ENTRIES[@]} -gt 0 ]]
}

# ── Microsoft 365 / Intune endpoints (live from the Microsoft endpoints web service) ──
# Source: https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges
MS_ENDPOINTS_URL="https://endpoints.office.com/endpoints/worldwide?ServiceAreas=Common,Exchange,SharePoint,Skype,MEM"
MS_VERSION_URL="https://endpoints.office.com/version/worldwide"
AZURE_TAGS_URL="https://www.microsoft.com/en-us/download/details.aspx?id=56519"
MS_VERSION=""
MS_ENTRIES=()   # "id|service area|category|required|tcp ports|udp ports|urls (space-sep)|ips (space-sep)"

fetch_ms_endpoints() {
    local req json line
    req=$(uuidgen 2>/dev/null || echo "b10c5ed1-bad1-445f-b386-b919946339a7")
    json=$(curl -fsSL --max-time "$(( TIMEOUT * 2 ))" "${MS_ENDPOINTS_URL}&clientrequestid=${req}" 2>/dev/null) || return 1
    MS_VERSION=$(curl -fsSL --max-time "$(( TIMEOUT * 2 ))" "${MS_VERSION_URL}?clientrequestid=${req}" 2>/dev/null \
        | grep -o '"latest" *: *"[0-9]*"' | grep -o '[0-9]\{8,\}')
    while IFS= read -r line; do
        MS_ENTRIES+=("$line")
    done < <(
        { if command -v jq &>/dev/null; then
            jq -r '.[] | [(.id | tostring), .serviceAreaDisplayName, .category, (.required | tostring),
                          (.tcpPorts // ""), (.udpPorts // ""),
                          ((.urls // []) | join(" ")), ((.ips // []) | join(" "))] | join("|")' <<< "$json"
        elif have_python; then
            python3 -c '
import json, sys
for e in json.load(sys.stdin):
    print("|".join([str(e["id"]), e.get("serviceAreaDisplayName", ""), e.get("category", ""), str(e.get("required", "")).lower(),
                    e.get("tcpPorts", ""), e.get("udpPorts", ""), " ".join(e.get("urls", [])), " ".join(e.get("ips", []))]))
' <<< "$json"
        fi; } 2>/dev/null | sort -t'|' -k2,2 -s   # group by service area
    )
    [[ ${#MS_ENTRIES[@]} -gt 0 ]]
}

# Run one test per URL / port from the live Microsoft list (duplicates skipped)
run_ms_live() {
    local entry id area cat required tcp udp urls ips url port proto ports desc key prev="" seen=" "
    for entry in "${MS_ENTRIES[@]}"; do
        IFS='|' read -r id area cat required tcp udp urls ips <<< "$entry"
        [[ -n "$urls" ]] || continue
        if [[ "$area" != "$prev" ]]; then
            printf "      %s\n" "$area"
            prev="$area"
        fi
        desc="Endpoint #${id} &middot; ${cat}"
        [[ "$required" == "true" ]] && desc+=" &middot; required" || desc+=" &middot; optional"
        for url in $urls; do
            for proto in TCP UDP; do
                [[ "$proto" == "TCP" ]] && ports="$tcp" || ports="$udp"
                for port in ${ports//,/ }; do
                    key="${url}:${port}/${proto}"
                    [[ "$seen" == *" $key "* ]] && continue
                    seen+="$key "
                    run_test "Microsoft ${area}" "$url" "$port" "$proto" "$desc"
                done
            done
        done
    done
}

# ── Azure IP Ranges and Service Tags (weekly file; newest one found by date) ──
# Microsoft republishes this under a new dated filename each week, so walk back from today
AZURE_TAGS_BASE="https://download.microsoft.com/download/7/1/d/71d86715-5596-4529-9b13-da13a5de5b63/ServiceTags_Public_"
AZURE_TAGS_FILE=""
AZURE_TAGS_DATE=""

fetch_azure_tags() {
    local i d
    for (( i = 0; i < 28; i++ )); do
        d=$(date -v-"${i}"d +%Y%m%d 2>/dev/null || date -d "-${i} day" +%Y%m%d 2>/dev/null) || return 1
        if curl -fsSL --max-time 60 "${AZURE_TAGS_BASE}${d}.json" -o "$WORK_DIR/azure.json" 2>/dev/null; then
            AZURE_TAGS_FILE="$WORK_DIR/azure.json"
            AZURE_TAGS_DATE="$d"
            return 0
        fi
    done
    return 1
}

# ── IP address checks: resolve each tested host, connect to every IPv4 address,
#    and match it against the published Jamf / Apple / Microsoft / Azure / Google ranges ──
build_ip_ranges() {
    local entry svc traffic provider region ips fqdns id area cat required tcp udp urls kind scope prefixes label p
    {
        for entry in "${JAMF_IP_ENTRIES[@]}"; do
            IFS='|' read -r svc traffic provider region ips fqdns <<< "$entry"
            label="$(jamf_service_label "$svc") ${region}"
            for p in $ips; do echo "Jamf|${label}|${p}"; done
        done
        for p in $APPLE_RANGES; do echo "Apple|Apple network|${p}"; done
        for entry in "${MS_ENTRIES[@]}"; do
            IFS='|' read -r id area cat required tcp udp urls ips <<< "$entry"
            for p in $ips; do echo "Microsoft 365|#${id} ${area}|${p}"; done
        done
        for entry in "${GOOGLE_ENTRIES[@]}"; do
            IFS='|' read -r kind scope prefixes <<< "$entry"
            if [[ "$kind" == "services" ]]; then label="Google services"; else label="Google Cloud ${scope}"; fi
            for p in $prefixes; do echo "Google|${label}|${p}"; done
        done
    } > "$WORK_DIR/ranges.txt"
}

# Prints RESULTS-format lines. Args: targets file, ranges file, Azure JSON (may be empty), timeout
ip_checks_py() {
    python3 -c '
import ipaddress, json, socket, sys, time
from concurrent.futures import ThreadPoolExecutor

targets_file, ranges_file, azure_file, timeout = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])

# Prefix tables: version -> prefix length -> network int -> [(source, label, prefix)]
tables = {4: {}, 6: {}}
def add(source, label, prefix):
    try:
        n = ipaddress.ip_network(prefix.strip(), strict=False)
    except ValueError:
        return
    tables[n.version].setdefault(n.prefixlen, {}).setdefault(int(n.network_address), []).append((source, label, str(n)))

for line in open(ranges_file):
    parts = line.rstrip("\n").split("|")
    if len(parts) == 3:
        add(*parts)
if azure_file:
    try:
        for tag in json.load(open(azure_file))["values"]:
            for prefix in tag["properties"]["addressPrefixes"]:
                add("Azure", tag["name"], prefix)
    except Exception:
        pass

def match(ip):
    a = ipaddress.ip_address(ip)
    bits, x, best = a.max_prefixlen, int(a), {}
    for plen, nets in tables[a.version].items():
        for source, label, prefix in nets.get((x >> (bits - plen)) << (bits - plen), []):
            # Most specific prefix per source; prefer a named service tag over the generic AzureCloud ones
            rank = (plen, not label.startswith("AzureCloud"), -len(label))
            if source not in best or rank > best[source][0]:
                best[source] = (rank, label, prefix)
    return "; ".join("%s: %s (%s)" % (s, b[1], b[2]) for s, b in sorted(best.items()))

targets = [l.rstrip("\n").split("|") for l in open(targets_file) if l.count("|") == 2]

def resolve(host):
    try:
        return list(dict.fromkeys(ai[4][0] for ai in socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)))
    except OSError:
        return []

def probe(job):
    ip, port = job
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    t0 = time.time()
    try:
        s.connect((ip, int(port)))
        return "open", str(int((time.time() - t0) * 1000))
    except ConnectionRefusedError:
        return "refused", "-"
    except OSError:
        return "timeout", "-"
    finally:
        s.close()

with ThreadPoolExecutor(32) as pool:
    hosts = list(dict.fromkeys(t[1] for t in targets))
    addrs = dict(zip(hosts, pool.map(resolve, hosts)))
    jobs, seen = [], set()
    for category, host, port in targets:
        for ip in addrs[host]:
            if (ip, port) not in seen:
                seen.add((ip, port))
                jobs.append((category, host, ip, port))
    outcomes = pool.map(probe, [(ip, port) for _, _, ip, port in jobs])

for (category, host, ip, port), (state, latency) in zip(jobs, outcomes):
    ranges = match(ip) or "Not in any published Jamf, Apple, Microsoft, Azure or Google range (allow by hostname)"
    if not ipaddress.ip_address(ip).is_global:
        ranges = "DNS returned a non-public address (DNS filtering or sinkhole?)"
    if state == "open":
        status, note = "PASS", ranges
    else:
        status = "FAIL"
        note = ("Connection refused" if state == "refused" else "Timed out after %gs" % timeout) + "; " + ranges
    print("|".join(["IP Checks: " + category, ip, port, "TCP", "IPv4 address of " + host, status, latency, note.replace("|", "/")]))
' "$@"
}

# ── Test: DNS resolution ──────────────────────────────────────────────────────
resolve_host() {
    local host="$1"
    # Strip wildcard prefix for resolution tests
    local test_host="${host/#\*./www.}"
    nslookup "$test_host" >/dev/null 2>&1 || host "$test_host" >/dev/null 2>&1
}

# ── Test: TCP port ────────────────────────────────────────────────────────────
# macOS nc ignores -w while connecting (falls back to the ~75s OS default); -G sets the connect timeout
NC_CONNECT_OPTS=(-w "$TIMEOUT")
nc -h 2>&1 | grep -qE -- '^[[:space:]]*-G ' && NC_CONNECT_OPTS+=(-G "$TIMEOUT")

test_tcp() {
    local host="$1" port="$2"
    local t0 t1
    t0=$(ms_now)
    if nc -z "${NC_CONNECT_OPTS[@]}" "$host" "$port" 2>/dev/null; then
        t1=$(ms_now)
        echo $(( t1 - t0 ))
        return 0
    fi
    echo "-"
    return 1
}

# ── Test: UDP ─────────────────────────────────────────────────────────────────
test_udp() {
    local host="$1" port="$2"
    # UDP is connectionless; nc -uz returns immediately — treat success as WARN
    if nc -u -z -w "$TIMEOUT" "$host" "$port" 2>/dev/null; then
        echo "ok"
        return 0
    fi
    echo "-"
    return 1
}

# ── Record a single test result ───────────────────────────────────────────────
run_test() {
    local category="$1" host="$2" port="$3" protocol="${4:-TCP}" description="$5"
    local status latency note=""

    # Resolve wildcard-prefixed hosts to a concrete name for nc
    local test_host
    test_host=$(wildcard_test_host "$host" "$port")

    if ! resolve_host "$test_host" 2>/dev/null; then
        if [[ "$host" == *\** ]]; then
            status="WARN"; latency="-"; note="Wildcard domain: no resolvable example host (tried ${test_host})"
        else
            status="FAIL"; latency="-"; note="DNS resolution failed"
        fi
    elif [[ "$protocol" == "UDP" ]]; then
        latency=$(test_udp "$test_host" "$port")
        if [[ $? -eq 0 ]]; then
            status="WARN"; note="UDP: sent, no reply confirmation (expected for UDP)"
        else
            status="FAIL"; note="UDP: no response"
        fi
    else
        # Skip bare base domains standing in for wildcards; they aren't real endpoints
        [[ "$host" == *\** && "$test_host" == "$(wildcard_base "$host")" ]] || IP_TARGETS+=("${category}|${test_host}|${port}")
        latency=$(test_tcp "$test_host" "$port")
        if [[ $? -eq 0 ]]; then
            status="PASS"
        else
            status="FAIL"; note="TCP connection refused or timed out after ${TIMEOUT}s"
        fi
    fi
    # Only the bare base domain was available to test, so a failure there isn't conclusive
    if [[ "$host" == *\** && "$test_host" == "$(wildcard_base "$host")" && "$status" == "FAIL" ]]; then
        status="WARN"; note="Wildcard domain: no known example host; base domain ${test_host} not reachable"
    fi
    [[ "$host" == *\** && "$note" != Wildcard* ]] && note="Tested ${test_host}${note:+; $note}"

    RESULTS+=("${category}|${host}|${port}|${protocol}|${description}|${status}|${latency}|${note}")

    case "$status" in
        PASS) PASS=$(( PASS + 1 ))
              $VERBOSE && printf "  ${GRN}✓${NC} %-45s :%-5s (%s)  %s ms\n" "$host" "$port" "$protocol" "$latency" ;;
        FAIL) FAIL=$(( FAIL + 1 ))
              $VERBOSE && printf "  ${RED}✗${NC} %-45s :%-5s (%s)  %s\n" "$host" "$port" "$protocol" "$note" ;;
        WARN) WARN=$(( WARN + 1 ))
              $VERBOSE && printf "  ${YLW}⚠${NC} %-45s :%-5s (%s)  %s\n" "$host" "$port" "$protocol" "$note" ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST SUITES
# ══════════════════════════════════════════════════════════════════════════════

printf "${BLU}Jamf Network Connectivity Test${NC}\n"
printf "Host: %s   Time: %s\n\n" "$HOSTNAME_LOCAL" "$RUN_DATE"

if [[ "$(uname)" == "Darwin" ]] && ! have_python; then
    if $INSTALL_DEV_TOOLS; then
        printf "Xcode Command Line Tools (python3) not found — installing via softwareupdate, this can take several minutes...\n"
        if install_dev_tools; then
            printf "      ${GRN}installed${NC}\n\n"
        else
            # Fall back to Apple's install dialog when a logged-in user can respond to it
            xcode-select --install &>/dev/null
            printf "      ${YLW}install failed${NC} — python3-based checks will be skipped (re-run after the Command Line Tools finish installing)\n\n"
        fi
    else
        printf "${YLW}Xcode Command Line Tools (python3) not found — python3-based checks will be skipped${NC}\n\n"
    fi
fi

printf "Fetching Jamf published IP list... "
if fetch_jamf_ip_list; then
    printf "${GRN}%d entries${NC} (published %s)\n" "${#JAMF_IP_ENTRIES[@]}" "${JAMF_IP_DATE:-unknown}"
else
    printf "${YLW}unavailable${NC} — dynamic JCDS endpoints will be skipped\n"
fi

printf "Fetching Google published IP ranges... "
if fetch_google_ranges; then
    printf "${GRN}%d range sets${NC} (created %s)\n" "${#GOOGLE_ENTRIES[@]}" "${GOOGLE_DATE:-unknown}"
else
    printf "${YLW}unavailable${NC} — Google ranges will be left out of the report\n"
fi

printf "Fetching Microsoft 365 / Intune endpoint list... "
if fetch_ms_endpoints; then
    printf "${GRN}%d entries${NC} (version %s)\n" "${#MS_ENTRIES[@]}" "${MS_VERSION:-unknown}"
else
    printf "${YLW}unavailable${NC}\n"
fi

printf "Fetching Azure IP Ranges and Service Tags... "
if fetch_azure_tags; then
    printf "${GRN}ok${NC} (ServiceTags_Public_%s.json)\n" "$AZURE_TAGS_DATE"
else
    printf "${YLW}unavailable${NC} — Azure ranges won't be matched\n"
fi

printf "Fetching Apple network requirements page... "
if fetch_apple_page; then
    printf "${GRN}ok${NC} (ranges: %s)\n\n" "$APPLE_RANGES"
else
    printf "${YLW}unavailable${NC} — using built-in range %s\n\n" "$APPLE_RANGES"
fi

# ── 1. Jamf Cloud Services ────────────────────────────────────────────────────
printf "${BLU}[1/11]${NC} Jamf Cloud Services\n"
run_test "Jamf Cloud Services"  "jamf.com"                 443 TCP "Jamf primary domain"
run_test "Jamf Cloud Services"  "experience.jamfcloud.com" 443 TCP "Jamf Cloud web UI"
run_test "Jamf Cloud Services"  "sentry.pub.jamf.build"    443 TCP "Jamf error reporting"
run_test "Jamf Cloud Services"  "resources.jamf.com"       443 TCP "Jamf resources"

# ── 2. Jamf Cloud Distribution Service (JCDS) ────────────────────────────────
printf "${BLU}[2/11]${NC} Jamf Cloud Distribution Service (JCDS)\n"
run_test "JCDS" "use1-jcds.services.jamfcloud.com"           443 TCP "JCDS US East 1"
run_test "JCDS" "euw2-jcds.services.jamfcloud.com"           443 TCP "JCDS EU West 2"
run_test "JCDS" "euc1-jcds.services.jamfcloud.com"           443 TCP "JCDS EU Central 1"
run_test "JCDS" "apne1-jcds.services.jamfcloud.com"          443 TCP "JCDS AP Northeast 1"
run_test "JCDS" "apse2-jcds.services.jamfcloud.com"          443 TCP "JCDS AP Southeast 2"
run_test "JCDS" "use1-jcdsdownloads.services.jamfcloud.com"  443 TCP "JCDS Downloads US East 1"
run_test "JCDS" "euw2-jcdsdownloads.services.jamfcloud.com"  443 TCP "JCDS Downloads EU West 2"
run_test "JCDS" "euc1-jcdsdownloads.services.jamfcloud.com"  443 TCP "JCDS Downloads EU Central 1"
run_test "JCDS" "apne1-jcdsdownloads.services.jamfcloud.com" 443 TCP "JCDS Downloads AP Northeast 1"
run_test "JCDS" "apse2-jcdsdownloads.services.jamfcloud.com" 443 TCP "JCDS Downloads AP Southeast 2"

# JCDS endpoints from the live Jamf IP list
if [[ ${#JAMF_IP_ENTRIES[@]} -gt 0 ]]; then
    for entry in "${JAMF_IP_ENTRIES[@]}"; do
        IFS='|' read -r svc traffic provider region ips fqdns <<< "$entry"
        [[ "$svc" == "jamf_cloud_distribution_service" ]] || continue
        for fqdn in $fqdns; do
            run_test "JCDS" "$fqdn" 443 TCP "JCDS ${region} (Jamf published list)"
        done
    done
else
    RESULTS+=("JCDS|engineering.jamf.com|443|TCP|Jamf published IP list|WARN|-|Could not download ${JAMF_IP_LIST_URL}; published JCDS endpoints not tested")
    WARN=$(( WARN + 1 ))
fi

# ── 3. Apple Push Notification Service (APNs) — required by Jamf ─────────────
printf "${BLU}[3/11]${NC} Apple Push Notification Service (APNs)\n"
run_test "Apple Push Notification Service" "api.push.apple.com"         443  TCP "APNs HTTP/2 API (port 443)"
run_test "Apple Push Notification Service" "api.push.apple.com"         2197 TCP "APNs HTTP/2 Provider (port 2197)"
run_test "Apple Push Notification Service" "1-courier.push.apple.com"   443  TCP "APNs courier pool (port 443)"
run_test "Apple Push Notification Service" "1-courier.push.apple.com"   5223 TCP "APNs courier pool (port 5223)"
run_test "Apple Push Notification Service" "2-courier.push.apple.com"   443  TCP "APNs courier pool"
run_test "Apple Push Notification Service" "2-courier.push.apple.com"   5223 TCP "APNs courier pool"

# ── 4. Apple Device Enrollment (DEP / ABM) — required by Jamf ────────────────
printf "${BLU}[4/11]${NC} Apple Device Enrollment\n"
run_test "Apple Device Enrollment" "deviceenrollment.apple.com"        443 TCP "Device Enrollment Program (DEP/ABM)"
run_test "Apple Device Enrollment" "deviceservices-external.apple.com" 443 TCP "Device services"
run_test "Apple Device Enrollment" "mdmenrollment.apple.com"           443 TCP "MDM enrolment (HTTPS)"
run_test "Apple Device Enrollment" "mdmenrollment.apple.com"           80  TCP "MDM enrolment (HTTP)"
run_test "Apple Device Enrollment" "iprofiles.apple.com"               443 TCP "Enrolment profiles delivery"
run_test "Apple Device Enrollment" "gdmf.apple.com"                    443 TCP "Device management firmware"
run_test "Apple Device Enrollment" "albert.apple.com"                  443 TCP "Device activation"
run_test "Apple Device Enrollment" "identity.apple.com"                443 TCP "Identity services"

# ── 5. Jamf Protect ───────────────────────────────────────────────────────────
printf "${BLU}[5/11]${NC} Jamf Protect\n"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.us-east-1.amazonaws.com"      443  TCP "Jamf Protect IoT US East 1 (HTTPS)"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.us-east-1.amazonaws.com"      8883 TCP "Jamf Protect IoT US East 1 (MQTT)"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.eu-west-2.amazonaws.com"      443  TCP "Jamf Protect IoT EU West 2 (HTTPS)"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.eu-west-2.amazonaws.com"      8883 TCP "Jamf Protect IoT EU West 2 (MQTT)"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.eu-central-1.amazonaws.com"   443  TCP "Jamf Protect IoT EU Central 1 (HTTPS)"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.eu-central-1.amazonaws.com"   8883 TCP "Jamf Protect IoT EU Central 1 (MQTT)"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.ap-northeast-1.amazonaws.com" 443  TCP "Jamf Protect IoT AP Northeast 1 (HTTPS)"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.ap-northeast-1.amazonaws.com" 8883 TCP "Jamf Protect IoT AP Northeast 1 (MQTT)"
run_test "Jamf Protect" "a3bwx220ks5p1x-ats.iot.ap-southeast-2.amazonaws.com" 443  TCP "Jamf Protect IoT AP Southeast 2 (HTTPS)"
run_test "Jamf Protect" "prod-use1-jamf-jpt-configs.s3.amazonaws.com"          443  TCP "Jamf Protect configs S3 US East 1"
run_test "Jamf Protect" "prod-euw2-jamf-jpt-configs.s3.amazonaws.com"          443  TCP "Jamf Protect configs S3 EU West 2"
run_test "Jamf Protect" "prod-euc1-jamf-jpt-configs.s3.amazonaws.com"          443  TCP "Jamf Protect configs S3 EU Central 1"
run_test "Jamf Protect" "prod-apne1-jamf-jpt-configs.s3.amazonaws.com"         443  TCP "Jamf Protect configs S3 AP Northeast 1"
run_test "Jamf Protect" "prod-apse2-jamf-jpt-configs.s3.amazonaws.com"         443  TCP "Jamf Protect configs S3 AP Southeast 2"
run_test "Jamf Protect" "shared-jamf-jpt-generic-packages.s3.amazonaws.com"    443  TCP "Jamf Protect packages S3"

# ── 6. Jamf Remote Assist ─────────────────────────────────────────────────────
printf "${BLU}[6/11]${NC} Jamf Remote Assist\n"
run_test "Jamf Remote Assist" "download.jra.services.jamfcloud.com" 443  TCP "JRA downloads"
run_test "Jamf Remote Assist" "files.jra.services.jamfcloud.com"    443  TCP "JRA files"
run_test "Jamf Remote Assist" "us.jra.services.jamfcloud.com"       443  TCP "JRA US (HTTPS)"
run_test "Jamf Remote Assist" "us.jra.services.jamfcloud.com"       5555 UDP "JRA US (session)"
run_test "Jamf Remote Assist" "euro.jra.services.jamfcloud.com"     443  TCP "JRA EU (HTTPS)"
run_test "Jamf Remote Assist" "euro.jra.services.jamfcloud.com"     5555 UDP "JRA EU (session)"
run_test "Jamf Remote Assist" "asia.jra.services.jamfcloud.com"     443  TCP "JRA Asia (HTTPS)"
run_test "Jamf Remote Assist" "asia.jra.services.jamfcloud.com"     5555 UDP "JRA Asia (session)"

# ── 7. Jamf Executive Threat Protection ──────────────────────────────────────
printf "${BLU}[7/11]${NC} Jamf Executive Threat Protection\n"
run_test "Jamf Executive Threat Protection" "edrvpn1.zecops.com" 1320 TCP "ETP VPN endpoint"

# ── 8. Microsoft (Intune / Entra ID) ─────────────────────────────────────────
printf "${BLU}[8/11]${NC} Microsoft (Intune / Entra ID)\n"
run_test "Microsoft" "login.microsoftonline.com"       443 TCP "Microsoft Entra ID / Azure AD authentication"
run_test "Microsoft" "graph.microsoft.com"              443 TCP "Microsoft Graph API"
run_test "Microsoft" "enrollment.manage.microsoft.com"  443 TCP "Intune device enrollment (*.manage.microsoft.com)"

if $INCLUDE_MICROSOFT; then
    if [[ ${#MS_ENTRIES[@]} -gt 0 ]]; then
        run_ms_live
    else
        printf "      ${YLW}Microsoft 365 endpoint list unavailable${NC}\n"
        RESULTS+=("Microsoft|endpoints.office.com|443|TCP|Microsoft 365 endpoint list|WARN|-|Could not download the Microsoft 365 endpoint list; full Microsoft tests skipped")
        WARN=$(( WARN + 1 ))
    fi
else
    printf "      ${YLW}Full Microsoft 365 / Intune endpoint tests skipped — re-run with --microsoft to include${NC}\n"
fi

# ── 9. Jamf Connect & Additional Jamf Services ────────────────────────────────
printf "${BLU}[9/11]${NC} Jamf Connect & Additional Services\n"
run_test "Jamf Additional Services" "marketplace.jamf.com" 443 TCP "Jamf Marketplace"
run_test "Jamf Additional Services" "datajar.mobi"         443 TCP "DataJar (common Jamf companion)"

# ── 10. Optional: Google Workspace, Android Enterprise and Chrome Enterprise ───
# Google doesn't publish its hostnames as a feed, so these come from its allowlist articles:
#   Workspace: https://knowledge.workspace.google.com/admin/getting-started/set-up-a-google-workspace-host-name-allowlist
#   Meet:      https://knowledge.workspace.google.com/admin/meet/prepare-your-network-for-meet-meetings-and-live-streams
#   Android:   https://support.google.com/work/android/answer/10513641
#   Chrome:    https://support.google.com/chrome/a/answer/6334001
# FCM's TCP 5228-5230 is tested on the mtalk and XMPP connection hosts (the googleapis.com API hosts only answer on 443); Meet media (UDP 3478, 19302-19309) on its TURN servers
run_google() {
    printf "      Workspace\n"
    run_test "Google Workspace" "accounts.google.com" 443 TCP "Authentication"
    run_test "Google Workspace" "oauth2.googleapis.com" 443 TCP "Authentication"
    run_test "Google Workspace" "www.googleapis.com" 443 TCP "Authentication"
    run_test "Google Workspace" "*.googleapis.com" 443 TCP "Main API entry point"
    run_test "Google Workspace" "gemini.google.com" 443 TCP "Generative AI"
    run_test "Google Workspace" "notebook.google.com" 443 TCP "Generative AI"
    run_test "Google Workspace" "aistudio.google.com" 443 TCP "Generative AI"
    run_test "Google Workspace" "drive.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "docs.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "sheets.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "slides.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "sites.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "meet.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "calendar.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "keep.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "script.google.com" 443 TCP "User-facing services"
    run_test "Google Workspace" "mail.google.com" 443 TCP "Gmail"
    run_test "Google Workspace" "chat.google.com" 443 TCP "Google Chat"
    run_test "Google Workspace" "www.google.com" 443 TCP "Contacts, GAL and account sign-in"
    run_test "Google Workspace" "apps-apis.google.com" 443 TCP "Admin Settings API"
    run_test "Google Workspace" "classroom.googleapis.com" 443 TCP "Workspace APIs"
    run_test "Google Workspace" "sheets.googleapis.com" 443 TCP "Workspace APIs"
    run_test "Google Workspace" "slides.googleapis.com" 443 TCP "Workspace APIs"
    run_test "Google Workspace" "people.googleapis.com" 443 TCP "Workspace APIs"
    run_test "Google Workspace" "accounts.youtube.com" 443 TCP "Additional authentication"
    run_test "Google Workspace" "fonts.gstatic.com" 443 TCP "Static content"
    run_test "Google Workspace" "ssl.gstatic.com" 443 TCP "Static content"
    run_test "Google Workspace" "www.gstatic.com" 443 TCP "Static content"
    run_test "Google Workspace" "*.googleusercontent.com" 443 TCP "User content"
    run_test "Google Workspace" "scf.usercontent.goog" 443 TCP "User content"
    run_test "Google Workspace" "www.youtubeeducation.com" 443 TCP "YouTube in Education"
    run_test "Google Workspace" "meetings.googleapis.com" 443 TCP "Google Meet APIs"
    run_test "Google Workspace" "hangouts.googleapis.com" 443 TCP "Google Meet APIs"
    run_test "Google Workspace" "apis.google.com" 443 TCP "Google Meet APIs"
    run_test "Google Workspace" "apps.google.com" 443 TCP "Google Meet APIs"
    run_test "Google Workspace" "clients2.google.com" 443 TCP "Google Meet static resources"
    run_test "Google Workspace" "clients4.google.com" 443 TCP "Google Meet static resources"
    run_test "Google Workspace" "clients6.google.com" 443 TCP "Google Meet static resources"
    run_test "Google Workspace" "*.clients6.google.com" 443 TCP "Google Meet static resources"
    run_test "Google Workspace" "lh3.googleusercontent.com" 443 TCP "Google Meet static resources"
    run_test "Google Workspace" "stream.meet.google.com" 443 TCP "Google Meet live streaming"
    run_test "Google Workspace" "feedback.googleusercontent.com" 443 TCP "Google Meet feedback and logging"
    run_test "Google Workspace" "play.google.com" 443 TCP "Google Meet feedback and logging"
    run_test "Google Workspace" "*.googlevideo.com" 443 TCP "Google Meet media content"
    run_test "Google Workspace" "*.youtube-nocookie.com" 443 TCP "Google Meet media content"
    run_test "Google Workspace" "*.ytimg.com" 443 TCP "Google Meet media content"
    run_test "Google Workspace" "meet.google.com" 443 UDP "Google Meet web traffic (QUIC)"
    run_test "Google Workspace" "workspace.turns.goog" 3478 UDP "Google Meet audio and video"
    run_test "Google Workspace" "workspace.turns.goog" 19302 UDP "Google Meet audio and video"
    run_test "Google Workspace" "workspace.turns.goog" 19303 UDP "Google Meet audio and video"
    run_test "Google Workspace" "workspace.turns.goog" 19304 UDP "Google Meet audio and video"
    run_test "Google Workspace" "workspace.turns.goog" 19305 UDP "Google Meet audio and video"
    run_test "Google Workspace" "workspace.turns.goog" 19306 UDP "Google Meet audio and video"
    run_test "Google Workspace" "workspace.turns.goog" 19307 UDP "Google Meet audio and video"
    run_test "Google Workspace" "workspace.turns.goog" 19308 UDP "Google Meet audio and video"
    run_test "Google Workspace" "workspace.turns.goog" 19309 UDP "Google Meet audio and video"
    run_test "Google Workspace" "crl.pki.goog" 80 TCP "Certificate revocation (CRL)"
    run_test "Google Workspace" "c.pki.goog" 80 TCP "Certificate revocation (CRL)"
    run_test "Google Workspace" "ocsp.pki.goog" 80 TCP "Certificate status (OCSP)"
    printf "      Android Enterprise\n"
    run_test "Google Android Enterprise" "play.google.com" 443 TCP "Google Play and updates"
    run_test "Google Android Enterprise" "android.com" 443 TCP "Google Play and updates"
    run_test "Google Android Enterprise" "google-analytics.com" 443 TCP "Google Play and updates"
    run_test "Google Android Enterprise" "*.gstatic.com" 443 TCP "Google Play and updates"
    run_test "Google Android Enterprise" "googleusercontent.com" 443 TCP "User-generated content such as app icons"
    run_test "Google Android Enterprise" "*.gvt1.com" 443 TCP "App downloads, updates and Play Store APIs"
    run_test "Google Android Enterprise" "*.ggpht.com" 443 TCP "App downloads, updates and Play Store APIs"
    run_test "Google Android Enterprise" "dl.google.com" 443 TCP "App downloads, updates and Play Store APIs"
    run_test "Google Android Enterprise" "dl-ssl.google.com" 443 TCP "App downloads, updates and Play Store APIs"
    run_test "Google Android Enterprise" "android.apis.google.com" 443 TCP "Play Store APIs and device policy downloads"
    run_test "Google Android Enterprise" "*.gvt2.com" 443 TCP "Play connectivity monitoring and diagnostics"
    run_test "Google Android Enterprise" "*.gvt3.com" 443 TCP "Play connectivity monitoring and diagnostics"
    run_test "Google Android Enterprise" "*.googleapis.com" 443 TCP "EMM, Play EMM and Android Management APIs"
    run_test "Google Android Enterprise" "m.google.com" 443 TCP "EMM, Play EMM and Android Management APIs"
    run_test "Google Android Enterprise" "www.googleapis.com" 443 TCP "EMM, Play EMM and Android Management APIs"
    run_test "Google Android Enterprise" "androidmanagement.googleapis.com" 443 TCP "Android Management API"
    run_test "Google Android Enterprise" "accounts.google.com" 443 TCP "Authentication"
    run_test "Google Android Enterprise" "accounts.youtube.com" 443 TCP "Authentication"
    run_test "Google Android Enterprise" "gcm-http.googleapis.com" 443 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "gcm-xmpp.googleapis.com" 443 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "gcm-xmpp.googleapis.com" 5228 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "gcm-xmpp.googleapis.com" 5229 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "gcm-xmpp.googleapis.com" 5230 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "android.googleapis.com" 443 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "fcm.googleapis.com" 443 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "fcm-xmpp.googleapis.com" 443 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "fcm-xmpp.googleapis.com" 5228 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "fcm-xmpp.googleapis.com" 5229 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "fcm-xmpp.googleapis.com" 5230 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "firebaseinstallations.googleapis.com" 443 TCP "Firebase / Google Cloud Messaging (EMM console to device)"
    run_test "Google Android Enterprise" "fcm-xmpp.googleapis.com" 5235 TCP "FCM / GCM persistent XMPP connection"
    run_test "Google Android Enterprise" "fcm-xmpp.googleapis.com" 5236 TCP "FCM / GCM persistent XMPP connection"
    run_test "Google Android Enterprise" "gcm-xmpp.googleapis.com" 5235 TCP "FCM / GCM persistent XMPP connection"
    run_test "Google Android Enterprise" "gcm-xmpp.googleapis.com" 5236 TCP "FCM / GCM persistent XMPP connection"
    run_test "Google Android Enterprise" "firebaselogging.googleapis.com" 443 TCP "AMAPI SDK logging and metrics"
    run_test "Google Android Enterprise" "pki.google.com" 443 TCP "Certificate revocation checks"
    run_test "Google Android Enterprise" "clients1.google.com" 443 TCP "Certificate revocation checks"
    run_test "Google Android Enterprise" "crl.pki.goog" 443 TCP "Certificate validation"
    run_test "Google Android Enterprise" "ocsp.pki.goog" 443 TCP "Certificate validation"
    run_test "Google Android Enterprise" "clients2.google.com" 443 TCP "Crash reporting, bookmark sync, time sync"
    run_test "Google Android Enterprise" "clients3.google.com" 443 TCP "Crash reporting, bookmark sync, time sync"
    run_test "Google Android Enterprise" "clients4.google.com" 443 TCP "Crash reporting, bookmark sync, time sync"
    run_test "Google Android Enterprise" "clients5.google.com" 443 TCP "Crash reporting, bookmark sync, time sync"
    run_test "Google Android Enterprise" "clients6.google.com" 443 TCP "Crash reporting, bookmark sync, time sync"
    run_test "Google Android Enterprise" "chromiumdash.appspot.com" 443 TCP "Chrome updates"
    run_test "Google Android Enterprise" "connectivitycheck.android.com" 443 TCP "Connectivity checks"
    run_test "Google Android Enterprise" "connectivitycheck.gstatic.com" 443 TCP "Connectivity checks"
    run_test "Google Android Enterprise" "www.google.com" 443 TCP "Connectivity checks"
    run_test "Google Android Enterprise" "ota.googlezip.net" 443 TCP "Over-the-air (GOTA) updates"
    run_test "Google Android Enterprise" "ota-cache1.googlezip.net" 443 TCP "Over-the-air (GOTA) updates"
    run_test "Google Android Enterprise" "ota-cache3.googlezip.net" 443 TCP "Over-the-air (GOTA) updates"
    run_test "Google Android Enterprise" "mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk4.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk4.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk4.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk4.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk-staging.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk-staging.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk-staging.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk-staging.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk-dev.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk-dev.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk-dev.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "mtalk-dev.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt1-mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt1-mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt1-mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt1-mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt2-mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt2-mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt2-mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt2-mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt3-mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt3-mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt3-mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt3-mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt4-mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt4-mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt4-mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt4-mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt5-mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt5-mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt5-mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt5-mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt6-mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt6-mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt6-mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt6-mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt7-mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt7-mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt7-mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt7-mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt8-mtalk.google.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt8-mtalk.google.com" 5228 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt8-mtalk.google.com" 5229 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "alt8-mtalk.google.com" 5230 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "device-provisioning.googleapis.com" 443 TCP "FCM connectivity behind firewalls"
    run_test "Google Android Enterprise" "time.google.com" 123 UDP "NTP during provisioning"
    run_test "Google Android Enterprise" "android-safebrowsing.google.com" 443 TCP "Google Play Protect (Safe Browsing)"
    run_test "Google Android Enterprise" "safebrowsing.google.com" 443 TCP "Google Play Protect (Safe Browsing)"
    run_test "Google Android Enterprise" "fonts.googleapis.com" 443 TCP "Console iFrame and fonts"
    run_test "Google Android Enterprise" "apis.google.com" 443 TCP "Console iFrame and fonts"
    run_test "Google Android Enterprise" "ajax.googleapis.com" 443 TCP "Console iFrame and fonts"
    run_test "Google Android Enterprise" "payments.google.com" 443 TCP "Console app approval"
    run_test "Google Android Enterprise" "google.com" 443 TCP "Console app approval"
    run_test "Google Android Enterprise" "ogs.google.com" 443 TCP "Console UI and notifications"
    run_test "Google Android Enterprise" "notifications.google.com" 443 TCP "Console UI and notifications"
    run_test "Google Android Enterprise" "enterprise.google.com" 443 TCP "Zero-touch console"
    printf "      Chrome Enterprise\n"
    run_test "Google Chrome Enterprise" "tools.google.com" 443 TCP "Update configuration (Omaha)"
    run_test "Google Chrome Enterprise" "edgedl.me.gvt1.com" 443 TCP "Update payload downloads"
    run_test "Google Chrome Enterprise" "dl.google.com" 443 TCP "Update payload downloads"
    run_test "Google Chrome Enterprise" "m.google.com" 443 TCP "Enrollment and policy fetches"
    run_test "Google Chrome Enterprise" "clients3.google.com" 443 TCP "System clock sync"
    run_test "Google Chrome Enterprise" "www.googleapis.com" 443 TCP "OAuth and Google APIs"
    run_test "Google Chrome Enterprise" "accounts.google.com" 443 TCP "ChromeOS sign-in"
    run_test "Google Chrome Enterprise" "www.google.com" 443 TCP "ChromeOS sign-in"
    run_test "Google Chrome Enterprise" "www.gstatic.com" 443 TCP "Sign-in page content and enrollment status"
    run_test "Google Chrome Enterprise" "ssl.gstatic.com" 443 TCP "Sign-in page content and enrollment status"
    run_test "Google Chrome Enterprise" "chromeos-ca.gstatic.com" 443 TCP "Attestation CA (zero-touch / forced re-enrollment)"
    run_test "Google Chrome Enterprise" "connectivitycheck.gstatic.com" 80 TCP "Captive portal probe (HTTP)"
    run_test "Google Chrome Enterprise" "play.googleapis.com" 80 TCP "Captive portal probe (HTTP)"
    run_test "Google Chrome Enterprise" "www.gstatic.com" 80 TCP "Captive portal probe (HTTP)"
    run_test "Google Chrome Enterprise" "safebrowsing.google.com" 80 TCP "Captive portal probe (HTTP)"
    run_test "Google Chrome Enterprise" "www.googleapis.com" 80 TCP "Captive portal probe (HTTP)"
    run_test "Google Chrome Enterprise" "*.1e100.net" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "accounts.gstatic.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "accounts.youtube.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "alkalichromeosflexhwis2-pa.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "aratea-pa.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "chromeosquirksserver-pa.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "chromereporting-pa.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "clients1.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "clients2.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "clients4.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "clients2.googleusercontent.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "cloudsearch.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "commondatastorage.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "cros-omahaproxy.appspot.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "dl-ssl.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "enterprise-safebrowsing.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "firebaseperusertopics-pa.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "*.googleusercontent.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "*.gvt1.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "gweb-gettingstartedguide.appspot.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "mtalk.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "oauthaccountmanager.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "omahaproxy.appspot.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "pack.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "policies.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "printerconfigurations.googleusercontent.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "safebrowsing-cache.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "safebrowsing.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "safebrowsing.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "sb-ssl.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "scone-pa.clients6.google.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "storage.googleapis.com" 443 TCP "Recommended ChromeOS allowlist"
    run_test "Google Chrome Enterprise" "chrome.google.com" 443 TCP "Chrome Web Store extensions and apps"
    run_test "Google Chrome Enterprise" "lh3.ggpht.com" 443 TCP "Chrome Web Store extensions and apps"
    run_test "Google Chrome Enterprise" "lh4.ggpht.com" 443 TCP "Chrome Web Store extensions and apps"
    run_test "Google Chrome Enterprise" "lh5.ggpht.com" 443 TCP "Chrome Web Store extensions and apps"
    run_test "Google Chrome Enterprise" "lh6.ggpht.com" 443 TCP "Chrome Web Store extensions and apps"
    run_test "Google Chrome Enterprise" "update.googleapis.com" 443 TCP "Chrome Web Store extensions and apps"
    run_test "Google Chrome Enterprise" "youtubeeducation.com" 443 TCP "YouTube Player for Education"
}

if $INCLUDE_GOOGLE; then
    printf "${BLU}[10/11]${NC} Google (--google)\n"
    run_google
else
    printf "${YLW}[10/11] Google service tests skipped — re-run with --google to include${NC}\n"
fi

# ── 11. Optional: Full Apple network requirements ─────────────────────────────
# Built-in fallback, used when support.apple.com/101555 can't be fetched or parsed
run_apple_builtin() {
    printf "      APNs Courier Pool\n"
    run_test "Apple APNs" "1-courier.push.apple.com"  443  TCP "APNs courier 1 (port 443)"
    run_test "Apple APNs" "1-courier.push.apple.com"  5223 TCP "APNs courier 1 (port 5223)"
    run_test "Apple APNs" "3-courier.push.apple.com"  443  TCP "APNs courier 3 (port 443)"
    run_test "Apple APNs" "3-courier.push.apple.com"  5223 TCP "APNs courier 3 (port 5223)"
    run_test "Apple APNs" "5-courier.push.apple.com"  443  TCP "APNs courier 5 (port 443)"
    run_test "Apple APNs" "5-courier.push.apple.com"  5223 TCP "APNs courier 5 (port 5223)"

    printf "      Additional Content\n"
    run_test "Apple Additional Content" "audiocontentdownload.apple.com"   443 TCP "Audio content download (HTTPS)"
    run_test "Apple Additional Content" "audiocontentdownload.apple.com"   80  TCP "Audio content download (HTTP)"
    run_test "Apple Additional Content" "devimages-cdn.apple.com"          443 TCP "Developer images CDN (HTTPS)"
    run_test "Apple Additional Content" "devimages-cdn.apple.com"          80  TCP "Developer images CDN (HTTP)"
    run_test "Apple Additional Content" "download.developer.apple.com"     443 TCP "Developer downloads (HTTPS)"
    run_test "Apple Additional Content" "download.developer.apple.com"     80  TCP "Developer downloads (HTTP)"
    run_test "Apple Additional Content" "sylvan.apple.com"                 443 TCP "Sylvan content (HTTPS)"
    run_test "Apple Additional Content" "sylvan.apple.com"                 80  TCP "Sylvan content (HTTP)"
    run_test "Apple Additional Content" "playgrounds-cdn.apple.com"        443 TCP "Swift Playgrounds CDN"
    run_test "Apple Additional Content" "playgrounds-assets-cdn.apple.com" 443 TCP "Swift Playgrounds assets CDN"

    printf "      App Features\n"
    run_test "Apple App Features" "api.apple-cloudkit.com"                   443 TCP "CloudKit API"
    run_test "Apple App Features" "register.appattest.apple.com"             443 TCP "App Attest registration"
    run_test "Apple App Features" "data.appattest.apple.com"                 443 TCP "App Attest data"
    run_test "Apple App Features" "data-development.appattest.apple.com"     443 TCP "App Attest development data"
    run_test "Apple App Features" "register-development.appattest.apple.com" 443 TCP "App Attest development registration"

    printf "      App Store\n"
    run_test "Apple App Store" "itunes.apple.com"               443 TCP "iTunes / App Store (HTTPS)"
    run_test "Apple App Store" "itunes.apple.com"               80  TCP "iTunes / App Store (HTTP)"
    run_test "Apple App Store" "s.mzstatic.com"                 443 TCP "App Store assets"
    run_test "Apple App Store" "apps.apple.com"                 443 TCP "App Store"
    run_test "Apple App Store" "api.apps.apple.com"             443 TCP "App Store API"
    run_test "Apple App Store" "apps.mzstatic.com"              443 TCP "App Store (mzstatic)"
    run_test "Apple App Store" "silverbullet.itunes.apple.com"  443 TCP "App Store silverbullet (HTTPS)"
    run_test "Apple App Store" "silverbullet.itunes.apple.com"  80  TCP "App Store silverbullet (HTTP)"
    run_test "Apple App Store" "ppq.apple.com"                  443 TCP "App notarisation"

    printf "      Apple Business Manager / Apple School Manager (AxM)\n"
    run_test "Apple AxM" "business.apple.com"              443 TCP "Apple Business Manager (HTTPS)"
    run_test "Apple AxM" "business.apple.com"              80  TCP "Apple Business Manager (HTTP)"
    run_test "Apple AxM" "school.apple.com"                443 TCP "Apple School Manager (HTTPS)"
    run_test "Apple AxM" "school.apple.com"                80  TCP "Apple School Manager (HTTP)"
    run_test "Apple AxM" "api.ent.apple.com"               443 TCP "ABM enterprise API"
    run_test "Apple AxM" "api.edu.apple.com"               443 TCP "ASM education API"
    run_test "Apple AxM" "api.apple-mapkit.com"            443 TCP "MapKit API"
    run_test "Apple AxM" "axm-adm-scep.apple.com"          443 TCP "AxM SCEP"
    run_test "Apple AxM" "axm-adm-mdm.apple.com"           443 TCP "AxM MDM"
    run_test "Apple AxM" "axm-adm-enroll.apple.com"        443 TCP "AxM enrollment"
    run_test "Apple AxM" "icons.axm-usercontent-apple.com" 443 TCP "AxM user content icons"
    run_test "Apple AxM" "axm-app.apple.com"               443 TCP "AxM app"
    run_test "Apple AxM" "api.vertexsmb.com"               443 TCP "AxM SMB vertex API"
    run_test "Apple AxM" "statici.icloud.com"              443 TCP "iCloud static content"

    printf "      Apple Diagnostics\n"
    run_test "Apple Diagnostics" "diagassets.apple.com" 443 TCP "Apple diagnostics assets"

    printf "      AppleID\n"
    run_test "Apple ID" "appleid.cdn-apple.com" 443 TCP "Apple ID CDN"
    run_test "Apple ID" "idmsa.apple.com"        443 TCP "Apple ID authentication"
    run_test "Apple ID" "appleid.apple.com"      443 TCP "Apple ID management"
    run_test "Apple ID" "gsa.apple.com"          443 TCP "Apple authentication services"

    printf "      Carrier Updates\n"
    run_test "Apple Carrier Updates" "appldnld.apple.com"               80  TCP "Carrier update download"
    run_test "Apple Carrier Updates" "updates-http.cdn-apple.com"       80  TCP "Carrier updates CDN (HTTP)"
    run_test "Apple Carrier Updates" "itunes.apple.com"                 443 TCP "Carrier updates via iTunes"
    run_test "Apple Carrier Updates" "appldnld.apple.com.edgesuite.net" 80  TCP "Carrier update CDN (Akamai)"
    run_test "Apple Carrier Updates" "itunes.com"                       80  TCP "iTunes carrier updates"
    run_test "Apple Carrier Updates" "updates.cdn-apple.com"            443 TCP "Carrier updates CDN (HTTPS)"

    printf "      Certificate Validation\n"
    run_test "Apple Certificate Validation" "certs.apple.com"   443 TCP "Apple certificates (HTTPS)"
    run_test "Apple Certificate Validation" "certs.apple.com"   80  TCP "Apple certificates (HTTP)"
    run_test "Apple Certificate Validation" "crl.apple.com"     80  TCP "Apple CRL"
    run_test "Apple Certificate Validation" "ocsp.apple.com"    80  TCP "Apple OCSP (HTTP)"
    run_test "Apple Certificate Validation" "ocsp2.apple.com"   443 TCP "Apple OCSP2 (HTTPS)"
    run_test "Apple Certificate Validation" "valid.apple.com"   443 TCP "Apple certificate validation"
    run_test "Apple Certificate Validation" "crl3.digicert.com" 80  TCP "DigiCert CRL3"
    run_test "Apple Certificate Validation" "crl4.digicert.com" 80  TCP "DigiCert CRL4"
    run_test "Apple Certificate Validation" "ocsp.digicert.com" 80  TCP "DigiCert OCSP"
    run_test "Apple Certificate Validation" "ocsp.digicert.cn"  80  TCP "DigiCert OCSP (China)"
    run_test "Apple Certificate Validation" "crl.entrust.net"   80  TCP "Entrust CRL"
    run_test "Apple Certificate Validation" "ocsp.entrust.net"  80  TCP "Entrust OCSP"

    printf "      Classroom and Schoolwork\n"
    run_test "Apple Classroom" "play.itunes.apple.com"          443 TCP "Classroom / Schoolwork play"
    run_test "Apple Classroom" "ws-ee-maidsvc.icloud.com"       443 TCP "Classroom iCloud service"
    run_test "Apple Classroom" "ws.school.apple.com"            443 TCP "Schoolwork web service"
    run_test "Apple Classroom" "pg-bootstrap.itunes.apple.com"  443 TCP "Playground bootstrap"
    run_test "Apple Classroom" "cls-iosclient.itunes.apple.com" 443 TCP "Classroom iOS client"
    run_test "Apple Classroom" "cls-ingest.itunes.apple.com"    443 TCP "Classroom ingest"

    printf "      Content Caching\n"
    run_test "Apple Content Caching" "suconfig.apple.com"           80  TCP "Software update config (HTTP)"
    run_test "Apple Content Caching" "xp-cdn.apple.com"             443 TCP "Content cache CDN"
    run_test "Apple Content Caching" "lcdn-locator.apple.com"       443 TCP "LCDN locator"
    run_test "Apple Content Caching" "lcdn-registration.apple.com"  443 TCP "LCDN registration"
    run_test "Apple Content Caching" "serverstatus.apple.com"       443 TCP "Server status"

    printf "      Device Management and Enrollment\n"
    run_test "Apple Device Management" "mdmenrollment.apple.com"            443 TCP "MDM enrollment (HTTPS)"
    run_test "Apple Device Management" "mdmenrollment.apple.com"            80  TCP "MDM enrollment (HTTP)"
    run_test "Apple Device Management" "gdmf.apple.com"                    443 TCP "Device management firmware"
    run_test "Apple Device Management" "iprofiles.apple.com"               443 TCP "Enrollment profiles"
    run_test "Apple Device Management" "deviceenrollment.apple.com"        443 TCP "Device enrollment"
    run_test "Apple Device Management" "deviceservices-external.apple.com"  443 TCP "Device services"
    run_test "Apple Device Management" "identity.apple.com"                443 TCP "Identity services"

    printf "      Device Setup\n"
    run_test "Apple Device Setup" "time.apple.com"       123 UDP "NTP time sync (Apple)"
    run_test "Apple Device Setup" "time-macos.apple.com" 123 UDP "NTP time sync (macOS)"
    run_test "Apple Device Setup" "time-ios.apple.com"   123 UDP "NTP time sync (iOS)"
    run_test "Apple Device Setup" "captive.apple.com"    443 TCP "Captive portal detection (HTTPS)"
    run_test "Apple Device Setup" "captive.apple.com"    80  TCP "Captive portal detection (HTTP)"
    run_test "Apple Device Setup" "static.ips.apple.com" 443 TCP "Static IPs (HTTPS)"
    run_test "Apple Device Setup" "static.ips.apple.com" 80  TCP "Static IPs (HTTP)"
    run_test "Apple Device Setup" "humb.apple.com"       443 TCP "Device humb"
    run_test "Apple Device Setup" "sq-device.apple.com"  443 TCP "Device sequencing"
    run_test "Apple Device Setup" "albert.apple.com"     443 TCP "Device activation"
    run_test "Apple Device Setup" "tbsc.apple.com"       443 TCP "TBSC"
    run_test "Apple Device Setup" "gs.apple.com"         443 TCP "Gateway services (HTTPS)"

    printf "      Feedback Assistant\n"
    run_test "Apple Feedback Assistant" "bpapi.apple.com"         443 TCP "Feedback API"
    run_test "Apple Feedback Assistant" "cssubmissions.apple.com"  443 TCP "Crash submissions"
    run_test "Apple Feedback Assistant" "fba.apple.com"            443 TCP "Feedback Assistant"

    printf "      Private Cloud Compute\n"
    run_test "Apple Private Cloud Compute" "apple-relay.cloudflare.com"  443 TCP "Private Cloud Compute (Cloudflare)"
    run_test "Apple Private Cloud Compute" "cp4.cloudflare.com"          443 TCP "Private Cloud Compute (Cloudflare CP4)"
    run_test "Apple Private Cloud Compute" "apple-relay.fastly-edge.com" 443 TCP "Private Cloud Compute (Fastly)"

    printf "      Siri\n"
    run_test "Apple Siri" "guzzoni.apple.com"   443 TCP "Siri and dictation"
    run_test "Apple Siri" "api.smoot.apple.com" 443 TCP "Siri API / Spotlight"

    printf "      Software Updates\n"
    run_test "Apple Software Updates" "configuration.apple.com"     443 TCP "Software update configuration"
    run_test "Apple Software Updates" "appldnld.apple.com"          80  TCP "Software update downloads (HTTP)"
    run_test "Apple Software Updates" "mesu.apple.com"              443 TCP "macOS extended software update (HTTPS)"
    run_test "Apple Software Updates" "mesu.apple.com"              80  TCP "macOS extended software update (HTTP)"
    run_test "Apple Software Updates" "oscdn.apple.com"             443 TCP "OS content CDN (HTTPS)"
    run_test "Apple Software Updates" "oscdn.apple.com"             80  TCP "OS content CDN (HTTP)"
    run_test "Apple Software Updates" "gdmf.apple.com"              443 TCP "Device management firmware"
    run_test "Apple Software Updates" "gs.apple.com"                443 TCP "Gateway services (HTTPS)"
    run_test "Apple Software Updates" "gs.apple.com"                80  TCP "Gateway services (HTTP)"
    run_test "Apple Software Updates" "gg.apple.com"                443 TCP "OS updates (HTTPS)"
    run_test "Apple Software Updates" "gg.apple.com"                80  TCP "OS updates (HTTP)"
    run_test "Apple Software Updates" "ig.apple.com"                443 TCP "iOS updates"
    run_test "Apple Software Updates" "swdist.apple.com"            443 TCP "Software distribution"
    run_test "Apple Software Updates" "swcdn.apple.com"             80  TCP "Software Update CDN (HTTP)"
    run_test "Apple Software Updates" "xp.apple.com"                443 TCP "Xcode / platform updates"
    run_test "Apple Software Updates" "swscan.apple.com"            443 TCP "Software Update catalog scan"
    run_test "Apple Software Updates" "updates.cdn-apple.com"       443 TCP "Software distribution CDN (HTTPS)"
    run_test "Apple Software Updates" "updates-http.cdn-apple.com"  80  TCP "Software distribution CDN (HTTP)"
    run_test "Apple Software Updates" "osrecovery.apple.com"        443 TCP "Internet Recovery (HTTPS)"
    run_test "Apple Software Updates" "osrecovery.apple.com"        80  TCP "Internet Recovery (HTTP)"
    run_test "Apple Software Updates" "skl.apple.com"               443 TCP "Software content delivery"
    run_test "Apple Software Updates" "swdownload.apple.com"        443 TCP "Software download (HTTPS)"
    run_test "Apple Software Updates" "swdownload.apple.com"        80  TCP "Software download (HTTP)"

    printf "      Tap to Pay\n"
    run_test "Apple Tap to Pay" "app-site-association.cdn-apple.com"    443 TCP "Tap to Pay app association (TCP)"
    run_test "Apple Tap to Pay" "app-site-association.cdn-apple.com"    443 UDP "Tap to Pay app association (UDP)"
    run_test "Apple Tap to Pay" "app-site-association.networking.apple"  443 TCP "Tap to Pay networking (TCP)"
    run_test "Apple Tap to Pay" "app-site-association.networking.apple"  443 UDP "Tap to Pay networking (UDP)"
    run_test "Apple Tap to Pay" "pos-device.apple.com"                  443 TCP "POS device (TCP)"
    run_test "Apple Tap to Pay" "pos-device.apple.com"                  443 UDP "POS device (UDP)"
    run_test "Apple Tap to Pay" "humb.apple.com"                        443 TCP "Tap to Pay humb"

    printf "      iCloud\n"
    run_test "iCloud Services" "api.apple-cloudkit.com"      443 TCP "CloudKit API"
    run_test "iCloud Services" "appleid.cdn-apple.com"       443 TCP "Apple ID CDN"
    run_test "iCloud Services" "cdn.icloud-content.com"      443 TCP "iCloud content CDN"
    run_test "iCloud Services" "developer.icloud.com"        443 TCP "iCloud for Developers"
    run_test "iCloud Services" "developer.icloud.com.cn"     443 TCP "iCloud for Developers (China)"
    run_test "iCloud Services" "publish.iwork.apple.com"     443 TCP "iWork publishing"
    run_test "iCloud Services" "api.icloud.apple.com"        443 TCP "iCloud API"
    run_test "iCloud Services" "cdn.apple-livephotoskit.com" 443 TCP "Live Photos CDN"
    run_test "iCloud Services" "service.gc.apple.com"        443 TCP "iCloud GC service"
    run_test "iCloud Services" "idmsaapz-mdn.apzones.com"    443 TCP "iCloud identity service"
    run_test "iCloud Services" "setup.apple-cloudkit.com"    443 TCP "CloudKit setup"
    run_test "iCloud Services" "mask.icloud.com"             443 UDP "iCloud Private Relay (UDP)"
    run_test "iCloud Services" "mask-h2.icloud.com"          443 UDP "iCloud Private Relay H2 (UDP)"
    run_test "iCloud Services" "mask-api.icloud.com"         443 UDP "iCloud Private Relay API (UDP)"
}

if $INCLUDE_APPLE; then
    printf "${BLU}[11/11]${NC} Apple Network Requirements (--apple)\n"
    printf "      Reading host tables from %s... " "$APPLE_REQS_URL"
    if load_apple_requirements; then
        printf "${GRN}%d host entries${NC}\n" "${#APPLE_ENTRIES[@]}"
        run_apple_live
    else
        printf "${YLW}unavailable${NC} — using built-in list\n"
        RESULTS+=("Apple Network Requirements|support.apple.com|443|TCP|Apple network requirements page|WARN|-|Could not download or parse ${APPLE_REQS_URL}; built-in host list used")
        WARN=$(( WARN + 1 ))
        run_apple_builtin
    fi
else
    printf "${YLW}[11/11] Apple service tests skipped — re-run with --apple to include${NC}\n"
fi

# ── IP address checks ─────────────────────────────────────────────────────────
printf "${BLU}[IP]${NC} IP address checks (every IPv4 address of each tested host, matched to published ranges)\n"
if ! have_python; then
    printf "      ${YLW}Skipped — python3 is needed to resolve and match IP ranges${NC}\n"
elif [[ ${#IP_TARGETS[@]} -gt 0 ]]; then
    build_ip_ranges
    printf '%s\n' "${IP_TARGETS[@]}" > "$WORK_DIR/targets.txt"
    IP_CHECKED=0; IP_UNLISTED=0
    while IFS= read -r line; do
        RESULTS+=("$line")
        IFS='|' read -r _ _ _ _ _ status _ note <<< "$line"
        case "$status" in
            PASS) PASS=$(( PASS + 1 )) ;;
            FAIL) FAIL=$(( FAIL + 1 )) ;;
        esac
        IP_CHECKED=$(( IP_CHECKED + 1 ))
        [[ "$note" == *"Not in any published"* ]] && IP_UNLISTED=$(( IP_UNLISTED + 1 ))
    done < <(ip_checks_py "$WORK_DIR/targets.txt" "$WORK_DIR/ranges.txt" "$AZURE_TAGS_FILE" "$TIMEOUT" 2>/dev/null)
    printf "      %d address/port checks; %d addresses aren't in any published range (allow those by hostname)\n" \
        "$IP_CHECKED" "$IP_UNLISTED"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$(( PASS + FAIL + WARN ))
printf "\n%s\n" "──────────────────────────────────────────"
printf "Total: %d   ${GRN}Pass: %d${NC}   ${RED}Fail: %d${NC}   ${YLW}Warn: %d${NC}\n" \
    "$TOTAL" "$PASS" "$FAIL" "$WARN"
printf "%s\n\n" "──────────────────────────────────────────"

# ══════════════════════════════════════════════════════════════════════════════
# HTML REPORT GENERATION
# ══════════════════════════════════════════════════════════════════════════════
printf "Generating report: %s\n" "$OUTPUT_FILE"

PASS_PCT=0
[[ $TOTAL -gt 0 ]] && PASS_PCT=$(( (PASS * 100) / TOTAL ))

# Determine overall status colour for the progress bar
BAR_COLOR="#22c55e"
[[ $FAIL -gt 0 ]] && BAR_COLOR="#ef4444"
[[ $FAIL -eq 0 && $WARN -gt 0 ]] && BAR_COLOR="#f59e0b"

# ── Build one collapsible section per category ───────────────────────────────
SECTIONS_HTML=""
SEC_CAT=""; SEC_ROWS=""; SEC_PASS=0; SEC_FAIL=0; SEC_WARN=0

# Close the current category as a <details> block (collapsed), with its counts in the summary line
flush_section() {
    local counts=""
    [[ -n "$SEC_ROWS" ]] || return
    [[ $SEC_PASS -gt 0 ]] && counts+="<span class=\"badge pass\">${SEC_PASS} PASS</span>"
    [[ $SEC_FAIL -gt 0 ]] && counts+="<span class=\"badge fail\">${SEC_FAIL} FAIL</span>"
    [[ $SEC_WARN -gt 0 ]] && counts+="<span class=\"badge warn\">${SEC_WARN} WARN</span>"
    SECTIONS_HTML+="<details class=\"table-wrap ip-list section\">
  <summary>${SEC_CAT} <span class=\"sec-counts\">${counts}</span></summary>
  <table>
    <thead>
      <tr><th>Host</th><th>Port</th><th>Proto</th><th>Description</th><th>Status</th><th style=\"text-align:right\">Latency</th><th>Notes</th></tr>
    </thead>
    <tbody>
${SEC_ROWS}
    </tbody>
  </table>
</details>
"
    SEC_ROWS=""; SEC_PASS=0; SEC_FAIL=0; SEC_WARN=0
}

for entry in "${RESULTS[@]}"; do
    IFS='|' read -r cat host port proto desc status latency note <<< "$entry"

    # New category: close the previous section
    if [[ "$cat" != "$SEC_CAT" ]]; then
        flush_section
        SEC_CAT="$cat"
    fi

    # Status badge
    case "$status" in
        PASS) badge="<span class=\"badge pass\">PASS</span>"; SEC_PASS=$(( SEC_PASS + 1 )) ;;
        FAIL) badge="<span class=\"badge fail\">FAIL</span>"; SEC_FAIL=$(( SEC_FAIL + 1 )) ;;
        WARN) badge="<span class=\"badge warn\">WARN</span>"; SEC_WARN=$(( SEC_WARN + 1 )) ;;
        *)    badge="<span class=\"badge\">$status</span>" ;;
    esac

    # Latency cell
    if [[ "$latency" == "-" ]]; then
        lat_cell="<td class=\"latency\">&mdash;</td>"
    else
        lat_cell="<td class=\"latency\">${latency} ms</td>"
    fi

    # Note cell
    note_cell="<td class=\"note\">${note}</td>"

    status_lc=$(echo "$status" | tr '[:upper:]' '[:lower:]')
    SEC_ROWS+="<tr class=\"row-${status_lc}\">
        <td class=\"host\"><code>$host</code></td>
        <td class=\"port\">$port</td>
        <td class=\"proto\">$proto</td>
        <td>$desc</td>
        <td>$badge</td>
        ${lat_cell}
        ${note_cell}
    </tr>"
done
flush_section

# ── Failure recommendations ───────────────────────────────────────────────────
RECS_HTML=""
if [[ $FAIL -gt 0 ]]; then
    RECS_HTML='<details class="recs">
    <summary>Recommendations</summary>
    <ul>
      <li>Verify your firewall and proxy allow outbound TCP on ports <strong>443, 80, 5223, 2195, 2196, 2197, 8883, 1320</strong> and UDP on <strong>5555, 123</strong>.</li>
      <li>Ensure <strong>SSL/TLS inspection is disabled</strong> for Apple APNs hosts (<code>*.push.apple.com</code>). Apple pins certificates and will reject inspected connections.</li>
      <li>For Jamf Cloud, allow outbound access to <code>*.jamf.com</code>, <code>*.jamfcloud.com</code>, and <code>*.services.jamfcloud.com</code>.</li>
      <li>APNs requires <strong>port 5223</strong> in addition to 443 &mdash; many firewalls block this. Ensure <code>*.push.apple.com</code> on TCP 5223 is permitted.</li>
      <li>JCDS uses <code>*.services.jamfcloud.com</code> &mdash; ensure both the <code>jcds</code> and <code>jcdsdownloads</code> subdomains on TCP 443 are reachable for all required regions.</li>
      <li>Jamf Protect requires TCP <strong>8883</strong> (MQTT) to AWS IoT endpoints (<code>*.iot.*.amazonaws.com</code>) and TCP 443 to <code>*.s3.amazonaws.com</code>.</li>
      <li>Jamf Remote Assist requires UDP <strong>5555</strong> in addition to TCP 443 for session traffic.</li>
      <li>For Microsoft Intune / Entra ID, allow <code>login.microsoftonline.com</code>, <code>graph.microsoft.com</code>, and <code>*.manage.microsoft.com</code> on TCP 443. Full lists: <a href="https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges">Microsoft 365 URLs and IP ranges</a> &nbsp;|&nbsp; <a href="https://www.microsoft.com/en-us/download/details.aspx?id=56519">Azure IP Ranges and Service Tags</a></li>
'"$( $INCLUDE_GOOGLE && echo '      <li>For Google, allow TCP 443 and 80 to <code>*.google.com</code>, <code>*.googleapis.com</code> and <code>*.gstatic.com</code>; Android Enterprise also needs TCP <strong>5228-5230</strong> (Firebase Cloud Messaging) and Google Meet needs UDP <strong>3478, 19302-19309</strong>. Full lists: <a href="https://knowledge.workspace.google.com/admin/getting-started/set-up-a-google-workspace-host-name-allowlist">Google Workspace</a> &nbsp;|&nbsp; <a href="https://support.google.com/work/android/answer/10513641">Android Enterprise</a> &nbsp;|&nbsp; <a href="https://support.google.com/chrome/a/answer/6334001">Chrome Enterprise</a></li>' )"'
      <li>Reference: <a href="https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro">Jamf Pro Network Ports</a> &nbsp;|&nbsp;
          <a href="https://learn.jamf.com/r/en-US/jamf-ip-address-list/Permitting_InboundOutbound_Traffic_with_Jamf">Jamf IP Address List</a>
          '"$( $INCLUDE_APPLE && echo '&nbsp;|&nbsp;<a href="https://support.apple.com/en-us/101555">Apple Network Requirements</a> &nbsp;|&nbsp;<a href="https://support.apple.com/en-us/103229">Apple TCP/UDP Ports</a>' )"'
      </li>
    </ul>
  </details>'
fi

# ── Jamf published IP ranges (reference for firewall allow-lists) ────────────
IP_HTML=""
if [[ ${#JAMF_IP_ENTRIES[@]} -gt 0 ]]; then
    IP_ROWS=""
    for entry in "${JAMF_IP_ENTRIES[@]}"; do
        IFS='|' read -r svc traffic provider region ips fqdns <<< "$entry"
        if [[ "$traffic" == "outbound" ]]; then
            dir="Jamf &rarr; your network <small>(allow as source)</small>"
        else
            dir="Your devices &rarr; Jamf <small>(allow as destination)</small>"
        fi
        addrs=""
        for a in $ips $fqdns; do addrs+="<code>$a</code> "; done
        IP_ROWS+="<tr>
        <td>$(jamf_service_label "$svc")</td>
        <td>$dir</td>
        <td class=\"proto\">$provider</td>
        <td><code>$region</code></td>
        <td class=\"addrs\">$addrs</td>
    </tr>"
    done
    IP_HTML="<details class=\"table-wrap ip-list\">
  <summary>Jamf Published IP Ranges &amp; Endpoints &mdash; ${#JAMF_IP_ENTRIES[@]} entries, published ${JAMF_IP_DATE:-unknown}</summary>
  <table>
    <thead>
      <tr><th>Service</th><th>Direction</th><th>Provider</th><th>Region</th><th>IP Prefixes / FQDNs</th></tr>
    </thead>
    <tbody>
${IP_ROWS}
    </tbody>
  </table>
  <p class=\"ip-src\">Fetched live from <a href=\"${JAMF_IP_LIST_URL}\">${JAMF_IP_LIST_URL}</a></p>
</details>"
fi

# ── Microsoft published IP ranges (reference for firewall allow-lists) ───────
MS_IP_HTML=""
if [[ ${#MS_ENTRIES[@]} -gt 0 ]]; then
    MS_IP_ROWS=""
    for entry in "${MS_ENTRIES[@]}"; do
        IFS='|' read -r id area cat required tcp udp urls ips <<< "$entry"
        [[ -n "$ips" ]] || continue
        addrs=""
        for a in $ips; do addrs+="<code>$a</code> "; done
        MS_IP_ROWS+="<tr>
        <td>#${id}</td>
        <td>${area}</td>
        <td>${cat}$( [[ "$required" == "true" ]] && echo " &middot; required" )</td>
        <td class=\"port\">${tcp:+TCP ${tcp}}${udp:+ UDP ${udp}}</td>
        <td class=\"addrs\">$addrs</td>
    </tr>"
    done
    MS_IP_HTML="<details class=\"table-wrap ip-list\">
  <summary>Microsoft 365 / Intune Published IP Ranges &mdash; version ${MS_VERSION:-unknown}</summary>
  <table>
    <thead>
      <tr><th>Endpoint</th><th>Service Area</th><th>Category</th><th>Ports</th><th>IP Ranges</th></tr>
    </thead>
    <tbody>
${MS_IP_ROWS}
    </tbody>
  </table>
  <p class=\"ip-src\">Fetched live from <a href=\"https://endpoints.office.com/endpoints/worldwide\">endpoints.office.com</a>.
    Azure-hosted services publish their ranges separately (weekly, IP ranges only) in
    <a href=\"${AZURE_TAGS_URL}\">Azure IP Ranges and Service Tags &ndash; Public Cloud</a>.</p>
</details>"
fi

# ── Google published IP ranges (reference for firewall allow-lists) ──────────
GOOGLE_HTML=""
if [[ ${#GOOGLE_ENTRIES[@]} -gt 0 ]]; then
    if $GOOGLE_SERVICES_EXACT; then
        svc_label="Google services <small>(goog.json minus cloud.json)</small>"
    else
        svc_label="Google services <small>(full goog.json &mdash; includes Cloud ranges; python3 needed to subtract)</small>"
    fi
    G_ROWS=""
    for entry in "${GOOGLE_ENTRIES[@]}"; do
        IFS='|' read -r kind scope prefixes <<< "$entry"
        addrs=""
        for a in $prefixes; do addrs+="<code>$a</code> "; done
        [[ "$kind" == "services" ]] && label="$svc_label" || label="Google Cloud <small>(customer ranges)</small>"
        G_ROWS+="<tr>
        <td>${label}</td>
        <td><code>${scope}</code></td>
        <td class=\"addrs\">$addrs</td>
    </tr>"
    done
    GOOGLE_HTML="<details class=\"table-wrap ip-list\">
  <summary>Google Published IP Ranges &mdash; created ${GOOGLE_DATE:-unknown}</summary>
  <table>
    <thead>
      <tr><th>Range Set</th><th>Scope</th><th>IP Prefixes</th></tr>
    </thead>
    <tbody>
${G_ROWS}
    </tbody>
  </table>
  <p class=\"ip-src\">Fetched live from <a href=\"${GOOG_RANGES_URL}\">goog.json</a> and
    <a href=\"${GCLOUD_RANGES_URL}\">cloud.json</a>. Allow-list the Google services ranges for Google APIs and Workspace;
    the Google Cloud ranges are used by any Google Cloud customer.</p>
</details>"
fi

APPLE_BADGE=""
$INCLUDE_APPLE && APPLE_BADGE='<span class="apple-badge">+ Apple Tests</span>'
$INCLUDE_GOOGLE && APPLE_BADGE+='<span class="apple-badge">+ Google Tests</span>'

# ── Write HTML ────────────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Network Test</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: #f0f2f5;
      color: #1a1a2e;
      line-height: 1.5;
      padding: 2rem 1rem;
    }

    /* ── Header ───────────────────────────────────────────────── */
    header {
      max-width: 1100px;
      margin: 0 auto 2rem;
      background: #1a1a2e;
      color: #fff;
      border-radius: 12px;
      padding: 2rem 2.5rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      flex-wrap: wrap;
    }
    header h1 { font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; }
    header .meta { font-size: 0.8rem; opacity: 0.65; margin-top: 0.3rem; }
    .apple-badge {
      background: #007aff;
      color: #fff;
      font-size: 0.7rem;
      font-weight: 600;
      padding: 0.25rem 0.6rem;
      border-radius: 20px;
      margin-left: 0.6rem;
      vertical-align: middle;
    }

    /* ── Summary cards ────────────────────────────────────────── */
    .summary {
      max-width: 1100px;
      margin: 0 auto 1.5rem;
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 1rem;
    }
    .card {
      background: #fff;
      border-radius: 10px;
      padding: 1.2rem 1.5rem;
      box-shadow: 0 1px 4px rgba(0,0,0,.08);
      text-align: center;
    }
    .card .num { font-size: 2.5rem; font-weight: 800; line-height: 1; }
    .card .lbl { font-size: 0.75rem; text-transform: uppercase; letter-spacing: .06em; opacity: .6; margin-top: .3rem; }
    .card.pass .num { color: #16a34a; }
    .card.fail .num { color: #dc2626; }
    .card.warn .num { color: #d97706; }
    .card.total .num { color: #1a1a2e; }

    /* ── Progress bar ─────────────────────────────────────────── */
    .progress-wrap {
      max-width: 1100px;
      margin: 0 auto 2rem;
      background: #fff;
      border-radius: 10px;
      padding: 1.2rem 1.5rem;
      box-shadow: 0 1px 4px rgba(0,0,0,.08);
    }
    .progress-label {
      display: flex;
      justify-content: space-between;
      font-size: 0.8rem;
      font-weight: 600;
      margin-bottom: .5rem;
      opacity: .7;
    }
    .progress-bar-bg {
      background: #e5e7eb;
      border-radius: 99px;
      height: 12px;
      overflow: hidden;
    }
    .progress-bar-fill {
      height: 100%;
      border-radius: 99px;
      background: $BAR_COLOR;
      width: ${PASS_PCT}%;
      transition: width 1s ease;
    }

    /* ── Results table ────────────────────────────────────────── */
    .table-wrap {
      max-width: 1100px;
      margin: 0 auto 2rem;
      background: #fff;
      border-radius: 10px;
      box-shadow: 0 1px 4px rgba(0,0,0,.08);
      overflow: hidden;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.85rem;
    }
    thead tr {
      background: #1a1a2e;
      color: #fff;
    }
    thead th {
      padding: .75rem 1rem;
      text-align: left;
      font-weight: 600;
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: .05em;
    }
    tbody tr { border-bottom: 1px solid #f0f2f5; }
    tbody tr:last-child { border-bottom: none; }
    tbody td { padding: .65rem 1rem; vertical-align: middle; }

    /* Category header */

    /* Row states */
    .row-pass:hover { background: #f0fdf4; }
    .row-fail { background: #fff5f5; }
    .row-fail:hover { background: #fee2e2; }
    .row-warn { background: #fffbeb; }
    .row-warn:hover { background: #fef3c7; }

    /* Badges */
    .badge {
      display: inline-block;
      padding: .2rem .55rem;
      border-radius: 5px;
      font-size: 0.7rem;
      font-weight: 700;
      letter-spacing: .04em;
    }
    .badge.pass { background: #dcfce7; color: #15803d; }
    .badge.fail { background: #fee2e2; color: #b91c1c; }
    .badge.warn { background: #fef3c7; color: #b45309; }

    /* Cells */
    .host code {
      font-family: "SF Mono", "Fira Code", Menlo, monospace;
      font-size: 0.82rem;
      color: #1a1a2e;
    }
    .port { font-family: monospace; color: #6366f1; font-weight: 600; }
    .proto { font-size: 0.75rem; color: #6b7280; font-weight: 600; text-transform: uppercase; }
    .latency { font-family: monospace; color: #6b7280; text-align: right; }
    .note { color: #6b7280; font-size: 0.78rem; font-style: italic; }

    /* ── Jamf published IP list ───────────────────────────────── */
    .ip-list summary {
      cursor: pointer;
      padding: 1rem 1.5rem;
      font-weight: 700;
      font-size: 0.9rem;
    }
    .ip-list[open] summary { border-bottom: 1px solid #e5e7eb; }
    .ip-list td { vertical-align: top; }
    .ip-list small { opacity: .6; }
    .addrs code {
      display: inline-block;
      font-family: "SF Mono", "Fira Code", Menlo, monospace;
      font-size: 0.75rem;
      background: #f3f4f6;
      border-radius: 4px;
      padding: .05rem .35rem;
      margin: 0 .2rem .25rem 0;
    }
    .ip-src { font-size: 0.75rem; color: #6b7280; padding: .75rem 1.5rem; }

    .section { margin-bottom: .75rem; }
    .sec-counts .badge { margin-left: .35rem; }
    .section-tools {
      max-width: 1100px;
      margin: 0 auto .75rem;
      display: flex;
      justify-content: flex-end;
      gap: .5rem;
    }
    .section-tools button {
      font: inherit;
      font-size: 0.8rem;
      padding: .35rem .8rem;
      border: 1px solid #d1d5db;
      border-radius: 6px;
      background: #fff;
      cursor: pointer;
    }

    /* ── Recommendations ──────────────────────────────────────── */
    .recs {
      max-width: 1100px;
      margin: 0 auto 2rem;
      background: #fffbeb;
      border: 1px solid #fde68a;
      border-radius: 10px;
      padding: 1.5rem 2rem;
    }
    .recs summary { font-size: 1rem; font-weight: 700; color: #92400e; cursor: pointer; }
    .recs[open] summary { margin-bottom: .75rem; }
    .recs ul { padding-left: 1.25rem; }
    .recs li { margin-bottom: .5rem; font-size: 0.85rem; color: #78350f; }
    .recs a { color: #1d4ed8; }

    /* ── Footer ───────────────────────────────────────────────── */
    footer {
      max-width: 1100px;
      margin: 0 auto;
      text-align: center;
      font-size: 0.75rem;
      color: #9ca3af;
      padding-bottom: 2rem;
    }

    @media print {
      body { background: #fff; padding: 0; }
      .table-wrap, .progress-wrap, .summary, header, .recs { box-shadow: none; }
      .row-pass:hover, .row-fail:hover, .row-warn:hover { background: inherit; }
    }
  </style>
</head>
<body>

<header>
  <div>
    <h1>Network Test ${APPLE_BADGE}</h1>
    <div class="meta">Host: ${HOSTNAME_LOCAL} &nbsp;&middot;&nbsp; ${RUN_DATE} &nbsp;&middot;&nbsp; Timeout: ${TIMEOUT}s per test$( $INCLUDE_APPLE && echo " &nbsp;&middot;&nbsp; Apple hosts: ${APPLE_SOURCE}" )$( [[ -n "$MS_VERSION" ]] && echo " &nbsp;&middot;&nbsp; Microsoft list: v${MS_VERSION}" )</div>
  </div>
</header>

<div class="summary">
  <div class="card total"><div class="num">${TOTAL}</div><div class="lbl">Total Tests</div></div>
  <div class="card pass"><div class="num">${PASS}</div><div class="lbl">Pass</div></div>
  <div class="card fail"><div class="num">${FAIL}</div><div class="lbl">Fail</div></div>
  <div class="card warn"><div class="num">${WARN}</div><div class="lbl">Warn</div></div>
</div>

<div class="progress-wrap">
  <div class="progress-label">
    <span>Connectivity Score</span>
    <span>${PASS_PCT}%</span>
  </div>
  <div class="progress-bar-bg">
    <div class="progress-bar-fill"></div>
  </div>
</div>

${RECS_HTML}

<div class="section-tools">
  <button type="button" onclick="toggleAll(true)">Expand all</button>
  <button type="button" onclick="toggleAll(false)">Collapse all</button>
</div>

${SECTIONS_HTML}

${IP_HTML}

${MS_IP_HTML}

${GOOGLE_HTML}

<footer>
  Generated by jamf_network_test.sh &nbsp;&middot;&nbsp;
  <a href="https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro">Jamf Network Ports Docs</a> &nbsp;·&nbsp;
  <a href="https://support.apple.com/en-us/101555">Apple Network Requirements</a> &nbsp;·&nbsp;
  <a href="https://support.apple.com/en-us/103229">Apple TCP/UDP Ports</a> &nbsp;·&nbsp;
  <a href="https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges">Microsoft 365 Endpoints</a> &nbsp;·&nbsp;
  <a href="https://www.microsoft.com/en-us/download/details.aspx?id=56519">Azure IP Ranges</a> &nbsp;·&nbsp;
  <a href="https://www.gstatic.com/ipranges/goog.json">Google IP Ranges</a>
</footer>

<script>
  // Sections start collapsed; expand everything for printing so nothing is hidden on paper
  function toggleAll(open) { document.querySelectorAll('details').forEach(function (d) { d.open = open; }); }
  window.addEventListener('beforeprint', function () { toggleAll(true); });
</script>

</body>
</html>
HTML

printf "${GRN}Done!${NC} Report saved to: %s\n" "$OUTPUT_FILE"

# Attempt to open on macOS
if command -v open &>/dev/null; then
    open "$OUTPUT_FILE"
fi
