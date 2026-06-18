# Jamf Network Test

Scripts that test TCP (and UDP) connectivity to every host required by Jamf Pro and Apple MDM, then generate a self-contained HTML report. `jamf_network_test.sh` is for macOS/Linux; `jamf_network_test.ps1` is the Windows PowerShell equivalent. Both run the exact same set of host/port checks and produce the same report layout, so results from a Mac and a Windows PC can be compared directly.

## Usage (macOS / Linux)

```bash
./jamf_network_test.sh [OPTIONS]
```

| Option | Default | Description |
|---|---|---|
| `--apple` | off | Also run full Apple network requirement tests |
| `--output FILE` | `jamf_network_report_<timestamp>.html` | Path for the HTML report |
| `--timeout SECS` | `5` | Per-connection timeout |
| `--verbose` | off | Print each result to stdout as it runs |

### Examples

```bash
# Standard Jamf connectivity check
./jamf_network_test.sh

# Include full Apple platform tests with verbose output
./jamf_network_test.sh --apple --verbose

# Custom timeout and output path
./jamf_network_test.sh --timeout 10 --output /tmp/network-report.html
```

## Usage (Windows / PowerShell)

```powershell
.\jamf_network_test.ps1 [OPTIONS]
```

| Option | Default | Description |
|---|---|---|
| `-Apple` | off | Also run full Apple network requirement tests |
| `-OutputFile <path>` | `jamf_network_report_<timestamp>.html` | Path for the HTML report |
| `-TimeoutSec <int>` | `5` | Per-connection timeout |
| `-VerboseOutput` | off | Print each result to the console as it runs |

### Examples

```powershell
# Standard Jamf connectivity check
.\jamf_network_test.ps1

# Include full Apple platform tests with verbose output
.\jamf_network_test.ps1 -Apple -VerboseOutput

# Custom timeout and output path
.\jamf_network_test.ps1 -TimeoutSec 10 -OutputFile C:\Temp\network-report.html
```

If running fails with a script-execution policy error, either run PowerShell as Administrator and execute `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`, or right-click the script and choose "Run with PowerShell". The script requires Windows PowerShell 5.1+ or PowerShell 7+ — no third-party modules needed (it uses .NET's `TcpClient`/`UdpClient` and `System.Net.Dns` directly, so there's no dependency on `nc`/`nslookup`).

## What it tests

### Default (35 tests)

| Section | Hosts |
|---|---|
| **Jamf Cloud Services** | `jamf.com`, `cloud.jamf.com`, `api.jamf.com`, `assets.jamf.com`, `resources.jamf.com`, `updates.jamf.com`, `enrollment.jamf.com`, `rec.jamfcloud.com` |
| **JCDS** | 5 regional `*.inf.jamf.one` endpoints, 2 CloudFront CDN nodes, 2 S3 buckets |
| **Apple Push Notification Service** | `api.push.apple.com` and courier pool hosts on ports 443 and 5223; legacy gateway hosts (retired Nov 2020 — expected to fail) |
| **Apple Device Enrollment** | `deviceenrollment.apple.com`, `mdmenrollment.apple.com`, `iprofiles.apple.com`, `albert.apple.com`, `identity.apple.com` |
| **Jamf Additional Services** | `connect.jamf.com`, `protect.jamf.com`, `school.jamf.com`, `marketplace.jamf.com`, `datajar.mobi` |

### With `--apple` (adds ~35 more tests)

| Section | Hosts |
|---|---|
| **Software Updates** | `swscan.apple.com`, `swdownload.apple.com`, `swcdn.apple.com`, `gg.apple.com`, `updates.cdn-apple.com`, `appldnld.apple.com`, `oscdn.apple.com`, `osrecovery.apple.com` |
| **Authentication & Apple ID** | `idmsa.apple.com`, `appleid.apple.com`, `account.apple.com`, `gsa.apple.com` |
| **Device Services** | `captive.apple.com`, `time.apple.com` (UDP/NTP), `ocsp.apple.com`, `ocsp2.apple.com`, `crl.apple.com`, `valid.apple.com` |
| **App Store & Content** | `apps.apple.com`, `itunes.apple.com`, `ppq.apple.com`, `bag.itunes.apple.com`, `p-cdn.apple.com` |
| **iCloud** | `icloud.com`, `setup.icloud.com`, `gateway.icloud.com`, `mask.icloud.com` |
| **Apple Intelligence & Siri** | `guzzoni.apple.com`, `api.siri.apple.com`, `smoot.apple.com` |

## Output

Both scripts write the same self-contained HTML report and attempt to open it automatically (macOS via `open`, Windows via `Invoke-Item`). The report includes:

- Summary cards (total / pass / fail / warn)
- Connectivity score progress bar
- Per-host results table with latency, status badge, and failure notes
- Recommendations panel (appears when failures are detected)

Results are colour-coded: green for pass, red for fail, amber for warn (UDP tests).

### How to read the report

- **PASS (green)** — the TCP connection succeeded within the timeout. The latency column shows how long the handshake took; this is a basic reachability check, not a guarantee that the higher-level service (e.g. APNs push, JCDS upload) is fully functional.
- **FAIL (red)** — either DNS resolution failed for the host, or the TCP connection was refused/timed out. Check the **Notes** column for which one. A DNS failure usually means the host can't even be looked up (sometimes expected for retired Apple endpoints); a TCP failure usually means a firewall, proxy, or outbound rule is blocking the port.
- **WARN (amber)** — only used for UDP tests. UDP is connectionless, so the script can confirm a packet was *sent* but not that it was *received*. A WARN does not necessarily mean a problem — look at it alongside any related TCP test on the same host (e.g. Jamf Remote Assist's UDP 5555 alongside its TCP 443 test).
- **Recommendations panel** — only appears when there's at least one FAIL. It lists the specific ports/hosts commonly responsible for each Jamf/Apple service and links to Jamf's and Apple's official network documentation.
- Rows are grouped by **Category** (e.g. "JCDS", "Apple Push Notification Service") matching the structure of Jamf's own network requirements documentation, so failures can be mapped directly back to the affected feature.

If you see failures, compare reports from a Mac and a Windows PC on the same network — since both scripts test identical hosts/ports, a host that fails on one platform but passes on the other usually points to a platform-specific proxy/firewall rule rather than a general network block.

## Requirements

**macOS / Linux** (`jamf_network_test.sh`)
- `nc` (netcat) — available by default on macOS
- `nslookup` or `host` for DNS resolution checks
- `python3` — used as fallback for millisecond timing on macOS (standard on macOS 12+)

**Windows** (`jamf_network_test.ps1`)
- Windows PowerShell 5.1+ or PowerShell 7+
- No third-party modules — uses .NET's `TcpClient`/`UdpClient` and `System.Net.Dns` directly

## Notes

**APNs legacy hosts** (`gateway.push.apple.com`, `feedback.push.apple.com`, `gateway.sandbox.push.apple.com`) are included in the test list but Apple retired the legacy binary APNs protocol in November 2020. These hosts no longer resolve — failures here are expected and not indicative of a network problem.

**SSL/TLS inspection** must be disabled for `*.push.apple.com`. Apple certificate-pins APNs connections; an intercepting proxy will cause MDM push to fail even if the TCP connection succeeds.

**UDP tests** return `WARN` rather than `PASS` or `FAIL` because UDP is connectionless — neither script's UDP send can confirm receipt.

## References

- [Jamf Pro Network Ports](https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro)
- [Jamf IP Address List](https://learn.jamf.com/r/en-US/jamf-ip-address-list/Permitting_InboundOutbound_Traffic_with_Jamf)
- [Apple Network Requirements for MDM](https://support.apple.com/en-gb/101555)
