#!/usr/bin/env bash

# Name        - jamf_network_test.sh
# Author      - MDM Magic
# Description - ests network connectivity for Jamf Pro and (optionally) Apple services, then generates a self-contained HTML report.
# Version     - 1.0
# Date        - 2026-06-19

#
# Usage:
#   ./jamf_network_test.sh [--apple] [--output FILE] [--timeout SECS] [--verbose]
#
# --apple    Also run Apple platform network requirement tests
# --output   Path for the HTML report (default: jamf_network_report_<ts>.html)
# --timeout  Per-connection timeout in seconds (default: 5)
# --verbose  Print each result to stdout as it runs

# ── Bootstrap ─────────────────────────────────────────────────────────────────
INCLUDE_APPLE=false
OUTPUT_FILE="jamf_network_report_$(date +%Y%m%d_%H%M%S).html"
TIMEOUT=5
VERBOSE=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --apple)   INCLUDE_APPLE=true ;;
        --output)  OUTPUT_FILE="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        --verbose) VERBOSE=true ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --apple          Include Apple network requirement tests
  --output FILE    HTML report path (default: jamf_network_report_<timestamp>.html)
  --timeout SECS   Connection timeout per test (default: 5)
  --verbose        Print each result to stdout during the run
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

# ── Test: DNS resolution ──────────────────────────────────────────────────────
resolve_host() {
    local host="$1"
    # Strip wildcard prefix for resolution tests
    local test_host="${host/#\*./www.}"
    nslookup "$test_host" >/dev/null 2>&1 || host "$test_host" >/dev/null 2>&1
}

# ── Test: TCP port ────────────────────────────────────────────────────────────
test_tcp() {
    local host="$1" port="$2"
    local t0 t1
    t0=$(ms_now)
    if nc -z -w "$TIMEOUT" "$host" "$port" 2>/dev/null; then
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
    local test_host="${host/#\*./1-courier.}"
    # For *.push.apple.com use the courier form; for all others strip wildcard differently
    if [[ "$host" == "*.push.apple.com" ]]; then
        test_host="1-courier.push.apple.com"
    elif [[ "$host" == \*.* ]]; then
        test_host="${host/#\*./www.}"
    fi

    if ! resolve_host "$test_host" 2>/dev/null; then
        status="FAIL"; latency="-"; note="DNS resolution failed"
    elif [[ "$protocol" == "UDP" ]]; then
        latency=$(test_udp "$test_host" "$port")
        if [[ $? -eq 0 ]]; then
            status="WARN"; note="UDP: sent, no reply confirmation (expected for UDP)"
        else
            status="FAIL"; note="UDP: no response"
        fi
    else
        latency=$(test_tcp "$test_host" "$port")
        if [[ $? -eq 0 ]]; then
            status="PASS"
        else
            status="FAIL"; note="TCP connection refused or timed out after ${TIMEOUT}s"
        fi
    fi

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

# ── 1. Jamf Cloud Services ────────────────────────────────────────────────────
printf "${BLU}[1/10]${NC} Jamf Cloud Services\n"
run_test "Jamf Cloud Services"  "jamf.com"                 443 TCP "Jamf primary domain"
run_test "Jamf Cloud Services"  "experience.jamfcloud.com" 443 TCP "Jamf Cloud web UI"
run_test "Jamf Cloud Services"  "sentry.pub.jamf.build"    443 TCP "Jamf error reporting"
run_test "Jamf Cloud Services"  "resources.jamf.com"       443 TCP "Jamf resources"

# ── 2. Jamf Cloud Distribution Service (JCDS) ────────────────────────────────
printf "${BLU}[2/10]${NC} Jamf Cloud Distribution Service (JCDS)\n"
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

# ── 3. Apple Push Notification Service (APNs) — required by Jamf ─────────────
printf "${BLU}[3/10]${NC} Apple Push Notification Service (APNs)\n"
run_test "Apple Push Notification Service" "api.push.apple.com"         443  TCP "APNs HTTP/2 API (port 443)"
run_test "Apple Push Notification Service" "api.push.apple.com"         2197 TCP "APNs HTTP/2 Provider (port 2197)"
run_test "Apple Push Notification Service" "1-courier.push.apple.com"   443  TCP "APNs courier pool (port 443)"
run_test "Apple Push Notification Service" "1-courier.push.apple.com"   5223 TCP "APNs courier pool (port 5223)"
run_test "Apple Push Notification Service" "2-courier.push.apple.com"   443  TCP "APNs courier pool"
run_test "Apple Push Notification Service" "2-courier.push.apple.com"   5223 TCP "APNs courier pool"

# ── 4. Apple Device Enrollment (DEP / ABM) — required by Jamf ────────────────
printf "${BLU}[4/10]${NC} Apple Device Enrollment\n"
run_test "Apple Device Enrollment" "deviceenrollment.apple.com"        443 TCP "Device Enrollment Program (DEP/ABM)"
run_test "Apple Device Enrollment" "deviceservices-external.apple.com" 443 TCP "Device services"
run_test "Apple Device Enrollment" "mdmenrollment.apple.com"           443 TCP "MDM enrolment (HTTPS)"
run_test "Apple Device Enrollment" "mdmenrollment.apple.com"           80  TCP "MDM enrolment (HTTP)"
run_test "Apple Device Enrollment" "iprofiles.apple.com"               443 TCP "Enrolment profiles delivery"
run_test "Apple Device Enrollment" "gdmf.apple.com"                    443 TCP "Device management firmware"
run_test "Apple Device Enrollment" "albert.apple.com"                  443 TCP "Device activation"
run_test "Apple Device Enrollment" "identity.apple.com"                443 TCP "Identity services"

# ── 5. Jamf Protect ───────────────────────────────────────────────────────────
printf "${BLU}[5/10]${NC} Jamf Protect\n"
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
printf "${BLU}[6/10]${NC} Jamf Remote Assist\n"
run_test "Jamf Remote Assist" "download.jra.services.jamfcloud.com" 443  TCP "JRA downloads"
run_test "Jamf Remote Assist" "files.jra.services.jamfcloud.com"    443  TCP "JRA files"
run_test "Jamf Remote Assist" "us.jra.services.jamfcloud.com"       443  TCP "JRA US (HTTPS)"
run_test "Jamf Remote Assist" "us.jra.services.jamfcloud.com"       5555 UDP "JRA US (session)"
run_test "Jamf Remote Assist" "euro.jra.services.jamfcloud.com"     443  TCP "JRA EU (HTTPS)"
run_test "Jamf Remote Assist" "euro.jra.services.jamfcloud.com"     5555 UDP "JRA EU (session)"
run_test "Jamf Remote Assist" "asia.jra.services.jamfcloud.com"     443  TCP "JRA Asia (HTTPS)"
run_test "Jamf Remote Assist" "asia.jra.services.jamfcloud.com"     5555 UDP "JRA Asia (session)"

# ── 7. Jamf Executive Threat Protection ──────────────────────────────────────
printf "${BLU}[7/10]${NC} Jamf Executive Threat Protection\n"
run_test "Jamf Executive Threat Protection" "edrvpn1.zecops.com" 1320 TCP "ETP VPN endpoint"

# ── 8. Microsoft (Intune / Entra ID) ─────────────────────────────────────────
printf "${BLU}[8/10]${NC} Microsoft (Intune / Entra ID)\n"
run_test "Microsoft" "login.microsoftonline.com"       443 TCP "Microsoft Entra ID / Azure AD authentication"
run_test "Microsoft" "graph.microsoft.com"              443 TCP "Microsoft Graph API"
run_test "Microsoft" "enrollment.manage.microsoft.com"  443 TCP "Intune device enrollment (*.manage.microsoft.com)"

# ── 9. Jamf Connect & Additional Jamf Services ────────────────────────────────
printf "${BLU}[9/10]${NC} Jamf Connect & Additional Services\n"
run_test "Jamf Additional Services" "marketplace.jamf.com" 443 TCP "Jamf Marketplace"
run_test "Jamf Additional Services" "datajar.mobi"         443 TCP "DataJar (common Jamf companion)"

# ── 10. Optional: Full Apple network requirements ─────────────────────────────
if $INCLUDE_APPLE; then
    printf "${BLU}[10/10]${NC} Apple Network Requirements (--apple)\n"

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

else
    printf "${YLW}[10/10] Apple service tests skipped — re-run with --apple to include${NC}\n"
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

# ── Build category-grouped HTML rows ─────────────────────────────────────────
ROWS_HTML=""
PREV_CAT=""

for entry in "${RESULTS[@]}"; do
    IFS='|' read -r cat host port proto desc status latency note <<< "$entry"

    # Category header row
    if [[ "$cat" != "$PREV_CAT" ]]; then
        ROWS_HTML+="<tr class=\"cat-header\"><td colspan=\"7\">$cat</td></tr>"
        PREV_CAT="$cat"
    fi

    # Status badge
    case "$status" in
        PASS) badge="<span class=\"badge pass\">PASS</span>" ;;
        FAIL) badge="<span class=\"badge fail\">FAIL</span>" ;;
        WARN) badge="<span class=\"badge warn\">WARN</span>" ;;
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
    ROWS_HTML+="<tr class=\"row-${status_lc}\">
        <td class=\"host\"><code>$host</code></td>
        <td class=\"port\">$port</td>
        <td class=\"proto\">$proto</td>
        <td>$desc</td>
        <td>$badge</td>
        ${lat_cell}
        ${note_cell}
    </tr>"
done

# ── Failure recommendations ───────────────────────────────────────────────────
RECS_HTML=""
if [[ $FAIL -gt 0 ]]; then
    RECS_HTML='<section class="recs">
    <h2>Recommendations</h2>
    <ul>
      <li>Verify your firewall and proxy allow outbound TCP on ports <strong>443, 80, 5223, 2195, 2196, 2197, 8883, 1320</strong> and UDP on <strong>5555, 123</strong>.</li>
      <li>Ensure <strong>SSL/TLS inspection is disabled</strong> for Apple APNs hosts (<code>*.push.apple.com</code>). Apple pins certificates and will reject inspected connections.</li>
      <li>For Jamf Cloud, allow outbound access to <code>*.jamf.com</code>, <code>*.jamfcloud.com</code>, and <code>*.services.jamfcloud.com</code>.</li>
      <li>APNs requires <strong>port 5223</strong> in addition to 443 &mdash; many firewalls block this. Ensure <code>*.push.apple.com</code> on TCP 5223 is permitted.</li>
      <li>JCDS uses <code>*.services.jamfcloud.com</code> &mdash; ensure both the <code>jcds</code> and <code>jcdsdownloads</code> subdomains on TCP 443 are reachable for all required regions.</li>
      <li>Jamf Protect requires TCP <strong>8883</strong> (MQTT) to AWS IoT endpoints (<code>*.iot.*.amazonaws.com</code>) and TCP 443 to <code>*.s3.amazonaws.com</code>.</li>
      <li>Jamf Remote Assist requires UDP <strong>5555</strong> in addition to TCP 443 for session traffic.</li>
      <li>For Microsoft Intune / Entra ID, allow <code>login.microsoftonline.com</code>, <code>graph.microsoft.com</code>, and <code>*.manage.microsoft.com</code> on TCP 443.</li>
      <li>Reference: <a href="https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro">Jamf Pro Network Ports</a> &nbsp;|&nbsp;
          <a href="https://learn.jamf.com/r/en-US/jamf-ip-address-list/Permitting_InboundOutbound_Traffic_with_Jamf">Jamf IP Address List</a>
          '"$( $INCLUDE_APPLE && echo '&nbsp;|&nbsp;<a href="https://support.apple.com/en-gb/101555">Apple Network Requirements</a>' )"'
      </li>
    </ul>
  </section>'
fi

APPLE_BADGE=""
$INCLUDE_APPLE && APPLE_BADGE='<span class="apple-badge">+ Apple Tests</span>'

# ── Write HTML ────────────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Jamf Network Test Report &mdash; $RUN_DATE</title>
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
    tr.cat-header td {
      background: #f8f9fb;
      font-weight: 700;
      font-size: 0.78rem;
      text-transform: uppercase;
      letter-spacing: .06em;
      color: #4b5563;
      padding: .5rem 1rem;
      border-top: 2px solid #e5e7eb;
    }

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

    /* ── Recommendations ──────────────────────────────────────── */
    .recs {
      max-width: 1100px;
      margin: 0 auto 2rem;
      background: #fffbeb;
      border: 1px solid #fde68a;
      border-radius: 10px;
      padding: 1.5rem 2rem;
    }
    .recs h2 { font-size: 1rem; font-weight: 700; margin-bottom: .75rem; color: #92400e; }
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
    <h1>Jamf Network Test Report ${APPLE_BADGE}</h1>
    <div class="meta">Host: ${HOSTNAME_LOCAL} &nbsp;&middot;&nbsp; ${RUN_DATE} &nbsp;&middot;&nbsp; Timeout: ${TIMEOUT}s per test</div>
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

<div class="table-wrap">
  <table>
    <thead>
      <tr>
        <th>Host</th>
        <th>Port</th>
        <th>Proto</th>
        <th>Description</th>
        <th>Status</th>
        <th style="text-align:right">Latency</th>
        <th>Notes</th>
      </tr>
    </thead>
    <tbody>
${ROWS_HTML}
    </tbody>
  </table>
</div>

<footer>
  Generated by jamf_network_test.sh &nbsp;&middot;&nbsp;
  <a href="https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro">Jamf Network Ports Docs</a> &nbsp;·&nbsp;
  <a href="https://support.apple.com/en-gb/101555">Apple Network Requirements</a>
</footer>

</body>
</html>
HTML

printf "${GRN}Done!${NC} Report saved to: %s\n" "$OUTPUT_FILE"

# Attempt to open on macOS
if command -v open &>/dev/null; then
    open "$OUTPUT_FILE"
fi
