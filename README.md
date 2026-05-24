# Jamf Network Test

A shell script that tests TCP (and UDP) connectivity to every host required by Jamf Pro and Apple MDM, then generates a self-contained HTML report.

## Usage

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

The script writes a self-contained HTML report and opens it automatically on macOS. The report includes:

- Summary cards (total / pass / fail / warn)
- Connectivity score progress bar
- Per-host results table with latency, status badge, and failure notes
- Recommendations panel (appears when failures are detected)

Results are colour-coded: green for pass, red for fail, amber for warn (UDP tests).

## Requirements

- macOS or Linux
- `nc` (netcat) — available by default on macOS
- `nslookup` or `host` for DNS resolution checks
- `python3` — used as fallback for millisecond timing on macOS (standard on macOS 12+)

## Notes

**APNs legacy hosts** (`gateway.push.apple.com`, `feedback.push.apple.com`, `gateway.sandbox.push.apple.com`) are included in the test list but Apple retired the legacy binary APNs protocol in November 2020. These hosts no longer resolve — failures here are expected and not indicative of a network problem.

**SSL/TLS inspection** must be disabled for `*.push.apple.com`. Apple certificate-pins APNs connections; an intercepting proxy will cause MDM push to fail even if the TCP connection succeeds.

**UDP tests** return `WARN` rather than `PASS` or `FAIL` because UDP is connectionless — `nc` sends a packet but cannot confirm receipt.

## References

- [Jamf Pro Network Ports](https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro)
- [Jamf IP Address List](https://learn.jamf.com/r/en-US/jamf-ip-address-list/Permitting_InboundOutbound_Traffic_with_Jamf)
- [Apple Network Requirements for MDM](https://support.apple.com/en-gb/101555)
