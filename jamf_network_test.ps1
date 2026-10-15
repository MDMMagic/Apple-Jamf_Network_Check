<#

Name        - jamf_network_test.ps1
Author      - MDM Magic
Description - Tests network connectivity for Jamf Pro and (optionally) Apple services on Windows,
then generates a self-contained HTML report.
Version     - 1.0
Date        - 2026-06-19

Usage:
  .\jamf_network_test.ps1 [-Apple] [-Microsoft] [-Google] [-OutputFile <path>] [-TimeoutSec <int>] [-VerboseOutput]

-Apple          Also run Apple platform network requirement tests (hosts read live from support.apple.com/101555)
-Microsoft      Also test every Microsoft 365 / Intune endpoint (read live from endpoints.office.com)
-Google         Also test Google Workspace, Android Enterprise and Chrome Enterprise hosts
-OutputFile     Path for the HTML report (default: jamf_network_report_<timestamp>.html)
-TimeoutSec     Per-connection timeout in seconds (default: 5)
-VerboseOutput  Print each result to the console as it runs
#>

param(
    [switch]$Apple,
    [switch]$Microsoft,
    [switch]$Google,
    [string]$OutputFile = "jamf_network_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html",
    [int]$TimeoutSec = 5,
    [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1's download progress bar slows Invoke-WebRequest to a crawl
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 defaults to TLS 1.0, which the live list servers refuse
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Numerics
$BigInt = [System.Numerics.BigInteger]
$Dot = " $([char]0xB7) "   # middle dot, kept out of the source so 5.1 reads this file correctly without a BOM

# ── Test definitions (mirrors jamf_network_test.sh) ───────────────────────────
$AllTests = @(
    [PSCustomObject]@{ Apple=$false; Category='Jamf Cloud Services'; Host_='jamf.com'; Port=443; Proto='TCP'; Desc='Jamf primary domain' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Cloud Services'; Host_='experience.jamfcloud.com'; Port=443; Proto='TCP'; Desc='Jamf Cloud web UI' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Cloud Services'; Host_='sentry.pub.jamf.build'; Port=443; Proto='TCP'; Desc='Jamf error reporting' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Cloud Services'; Host_='resources.jamf.com'; Port=443; Proto='TCP'; Desc='Jamf resources' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='use1-jcds.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS US East 1' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='euw2-jcds.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS EU West 2' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='euc1-jcds.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS EU Central 1' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='apne1-jcds.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS AP Northeast 1' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='apse2-jcds.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS AP Southeast 2' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='use1-jcdsdownloads.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS Downloads US East 1' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='euw2-jcdsdownloads.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS Downloads EU West 2' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='euc1-jcdsdownloads.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS Downloads EU Central 1' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='apne1-jcdsdownloads.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS Downloads AP Northeast 1' },
    [PSCustomObject]@{ Apple=$false; Category='JCDS'; Host_='apse2-jcdsdownloads.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JCDS Downloads AP Southeast 2' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Push Notification Service'; Host_='api.push.apple.com'; Port=443; Proto='TCP'; Desc='APNs HTTP/2 API (port 443)' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Push Notification Service'; Host_='api.push.apple.com'; Port=2197; Proto='TCP'; Desc='APNs HTTP/2 Provider (port 2197)' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Push Notification Service'; Host_='1-courier.push.apple.com'; Port=443; Proto='TCP'; Desc='APNs courier pool (port 443)' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Push Notification Service'; Host_='1-courier.push.apple.com'; Port=5223; Proto='TCP'; Desc='APNs courier pool (port 5223)' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Push Notification Service'; Host_='2-courier.push.apple.com'; Port=443; Proto='TCP'; Desc='APNs courier pool' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Push Notification Service'; Host_='2-courier.push.apple.com'; Port=5223; Proto='TCP'; Desc='APNs courier pool' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Device Enrollment'; Host_='deviceenrollment.apple.com'; Port=443; Proto='TCP'; Desc='Device Enrollment Program (DEP/ABM)' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Device Enrollment'; Host_='deviceservices-external.apple.com'; Port=443; Proto='TCP'; Desc='Device services' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Device Enrollment'; Host_='mdmenrollment.apple.com'; Port=443; Proto='TCP'; Desc='MDM enrolment (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Device Enrollment'; Host_='mdmenrollment.apple.com'; Port=80; Proto='TCP'; Desc='MDM enrolment (HTTP)' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Device Enrollment'; Host_='iprofiles.apple.com'; Port=443; Proto='TCP'; Desc='Enrolment profiles delivery' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Device Enrollment'; Host_='gdmf.apple.com'; Port=443; Proto='TCP'; Desc='Device management firmware' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Device Enrollment'; Host_='albert.apple.com'; Port=443; Proto='TCP'; Desc='Device activation' },
    [PSCustomObject]@{ Apple=$false; Category='Apple Device Enrollment'; Host_='identity.apple.com'; Port=443; Proto='TCP'; Desc='Identity services' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.us-east-1.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect IoT US East 1 (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.us-east-1.amazonaws.com'; Port=8883; Proto='TCP'; Desc='Jamf Protect IoT US East 1 (MQTT)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.eu-west-2.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect IoT EU West 2 (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.eu-west-2.amazonaws.com'; Port=8883; Proto='TCP'; Desc='Jamf Protect IoT EU West 2 (MQTT)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.eu-central-1.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect IoT EU Central 1 (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.eu-central-1.amazonaws.com'; Port=8883; Proto='TCP'; Desc='Jamf Protect IoT EU Central 1 (MQTT)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.ap-northeast-1.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect IoT AP Northeast 1 (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.ap-northeast-1.amazonaws.com'; Port=8883; Proto='TCP'; Desc='Jamf Protect IoT AP Northeast 1 (MQTT)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='a3bwx220ks5p1x-ats.iot.ap-southeast-2.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect IoT AP Southeast 2 (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='prod-use1-jamf-jpt-configs.s3.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect configs S3 US East 1' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='prod-euw2-jamf-jpt-configs.s3.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect configs S3 EU West 2' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='prod-euc1-jamf-jpt-configs.s3.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect configs S3 EU Central 1' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='prod-apne1-jamf-jpt-configs.s3.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect configs S3 AP Northeast 1' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='prod-apse2-jamf-jpt-configs.s3.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect configs S3 AP Southeast 2' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Protect'; Host_='shared-jamf-jpt-generic-packages.s3.amazonaws.com'; Port=443; Proto='TCP'; Desc='Jamf Protect packages S3' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Remote Assist'; Host_='download.jra.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JRA downloads' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Remote Assist'; Host_='files.jra.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JRA files' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Remote Assist'; Host_='us.jra.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JRA US (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Remote Assist'; Host_='us.jra.services.jamfcloud.com'; Port=5555; Proto='UDP'; Desc='JRA US (session)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Remote Assist'; Host_='euro.jra.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JRA EU (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Remote Assist'; Host_='euro.jra.services.jamfcloud.com'; Port=5555; Proto='UDP'; Desc='JRA EU (session)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Remote Assist'; Host_='asia.jra.services.jamfcloud.com'; Port=443; Proto='TCP'; Desc='JRA Asia (HTTPS)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Remote Assist'; Host_='asia.jra.services.jamfcloud.com'; Port=5555; Proto='UDP'; Desc='JRA Asia (session)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Executive Threat Protection'; Host_='edrvpn1.zecops.com'; Port=1320; Proto='TCP'; Desc='ETP VPN endpoint' },
    [PSCustomObject]@{ Apple=$false; Category='Microsoft'; Host_='login.microsoftonline.com'; Port=443; Proto='TCP'; Desc='Microsoft Entra ID / Azure AD authentication' },
    [PSCustomObject]@{ Apple=$false; Category='Microsoft'; Host_='graph.microsoft.com'; Port=443; Proto='TCP'; Desc='Microsoft Graph API' },
    [PSCustomObject]@{ Apple=$false; Category='Microsoft'; Host_='enrollment.manage.microsoft.com'; Port=443; Proto='TCP'; Desc='Intune device enrollment (*.manage.microsoft.com)' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Additional Services'; Host_='marketplace.jamf.com'; Port=443; Proto='TCP'; Desc='Jamf Marketplace' },
    [PSCustomObject]@{ Apple=$false; Category='Jamf Additional Services'; Host_='datajar.mobi'; Port=443; Proto='TCP'; Desc='DataJar (common Jamf companion)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple APNs'; Host_='1-courier.push.apple.com'; Port=443; Proto='TCP'; Desc='APNs courier 1 (port 443)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple APNs'; Host_='1-courier.push.apple.com'; Port=5223; Proto='TCP'; Desc='APNs courier 1 (port 5223)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple APNs'; Host_='3-courier.push.apple.com'; Port=443; Proto='TCP'; Desc='APNs courier 3 (port 443)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple APNs'; Host_='3-courier.push.apple.com'; Port=5223; Proto='TCP'; Desc='APNs courier 3 (port 5223)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple APNs'; Host_='5-courier.push.apple.com'; Port=443; Proto='TCP'; Desc='APNs courier 5 (port 443)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple APNs'; Host_='5-courier.push.apple.com'; Port=5223; Proto='TCP'; Desc='APNs courier 5 (port 5223)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='audiocontentdownload.apple.com'; Port=443; Proto='TCP'; Desc='Audio content download (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='audiocontentdownload.apple.com'; Port=80; Proto='TCP'; Desc='Audio content download (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='devimages-cdn.apple.com'; Port=443; Proto='TCP'; Desc='Developer images CDN (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='devimages-cdn.apple.com'; Port=80; Proto='TCP'; Desc='Developer images CDN (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='download.developer.apple.com'; Port=443; Proto='TCP'; Desc='Developer downloads (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='download.developer.apple.com'; Port=80; Proto='TCP'; Desc='Developer downloads (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='sylvan.apple.com'; Port=443; Proto='TCP'; Desc='Sylvan content (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='sylvan.apple.com'; Port=80; Proto='TCP'; Desc='Sylvan content (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='playgrounds-cdn.apple.com'; Port=443; Proto='TCP'; Desc='Swift Playgrounds CDN' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Additional Content'; Host_='playgrounds-assets-cdn.apple.com'; Port=443; Proto='TCP'; Desc='Swift Playgrounds assets CDN' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Features'; Host_='api.apple-cloudkit.com'; Port=443; Proto='TCP'; Desc='CloudKit API' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Features'; Host_='register.appattest.apple.com'; Port=443; Proto='TCP'; Desc='App Attest registration' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Features'; Host_='data.appattest.apple.com'; Port=443; Proto='TCP'; Desc='App Attest data' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Features'; Host_='data-development.appattest.apple.com'; Port=443; Proto='TCP'; Desc='App Attest development data' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Features'; Host_='register-development.appattest.apple.com'; Port=443; Proto='TCP'; Desc='App Attest development registration' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='itunes.apple.com'; Port=443; Proto='TCP'; Desc='iTunes / App Store (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='itunes.apple.com'; Port=80; Proto='TCP'; Desc='iTunes / App Store (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='s.mzstatic.com'; Port=443; Proto='TCP'; Desc='App Store assets' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='apps.apple.com'; Port=443; Proto='TCP'; Desc='App Store' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='api.apps.apple.com'; Port=443; Proto='TCP'; Desc='App Store API' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='apps.mzstatic.com'; Port=443; Proto='TCP'; Desc='App Store (mzstatic)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='silverbullet.itunes.apple.com'; Port=443; Proto='TCP'; Desc='App Store silverbullet (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='silverbullet.itunes.apple.com'; Port=80; Proto='TCP'; Desc='App Store silverbullet (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple App Store'; Host_='ppq.apple.com'; Port=443; Proto='TCP'; Desc='App notarisation' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='business.apple.com'; Port=443; Proto='TCP'; Desc='Apple Business Manager (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='business.apple.com'; Port=80; Proto='TCP'; Desc='Apple Business Manager (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='school.apple.com'; Port=443; Proto='TCP'; Desc='Apple School Manager (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='school.apple.com'; Port=80; Proto='TCP'; Desc='Apple School Manager (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='api.ent.apple.com'; Port=443; Proto='TCP'; Desc='ABM enterprise API' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='api.edu.apple.com'; Port=443; Proto='TCP'; Desc='ASM education API' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='api.apple-mapkit.com'; Port=443; Proto='TCP'; Desc='MapKit API' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='axm-adm-scep.apple.com'; Port=443; Proto='TCP'; Desc='AxM SCEP' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='axm-adm-mdm.apple.com'; Port=443; Proto='TCP'; Desc='AxM MDM' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='axm-adm-enroll.apple.com'; Port=443; Proto='TCP'; Desc='AxM enrollment' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='icons.axm-usercontent-apple.com'; Port=443; Proto='TCP'; Desc='AxM user content icons' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='axm-app.apple.com'; Port=443; Proto='TCP'; Desc='AxM app' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='api.vertexsmb.com'; Port=443; Proto='TCP'; Desc='AxM SMB vertex API' },
    [PSCustomObject]@{ Apple=$true; Category='Apple AxM'; Host_='statici.icloud.com'; Port=443; Proto='TCP'; Desc='iCloud static content' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Diagnostics'; Host_='diagassets.apple.com'; Port=443; Proto='TCP'; Desc='Apple diagnostics assets' },
    [PSCustomObject]@{ Apple=$true; Category='Apple ID'; Host_='appleid.cdn-apple.com'; Port=443; Proto='TCP'; Desc='Apple ID CDN' },
    [PSCustomObject]@{ Apple=$true; Category='Apple ID'; Host_='idmsa.apple.com'; Port=443; Proto='TCP'; Desc='Apple ID authentication' },
    [PSCustomObject]@{ Apple=$true; Category='Apple ID'; Host_='appleid.apple.com'; Port=443; Proto='TCP'; Desc='Apple ID management' },
    [PSCustomObject]@{ Apple=$true; Category='Apple ID'; Host_='gsa.apple.com'; Port=443; Proto='TCP'; Desc='Apple authentication services' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Carrier Updates'; Host_='appldnld.apple.com'; Port=80; Proto='TCP'; Desc='Carrier update download' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Carrier Updates'; Host_='updates-http.cdn-apple.com'; Port=80; Proto='TCP'; Desc='Carrier updates CDN (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Carrier Updates'; Host_='itunes.apple.com'; Port=443; Proto='TCP'; Desc='Carrier updates via iTunes' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Carrier Updates'; Host_='appldnld.apple.com.edgesuite.net'; Port=80; Proto='TCP'; Desc='Carrier update CDN (Akamai)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Carrier Updates'; Host_='itunes.com'; Port=80; Proto='TCP'; Desc='iTunes carrier updates' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Carrier Updates'; Host_='updates.cdn-apple.com'; Port=443; Proto='TCP'; Desc='Carrier updates CDN (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='certs.apple.com'; Port=443; Proto='TCP'; Desc='Apple certificates (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='certs.apple.com'; Port=80; Proto='TCP'; Desc='Apple certificates (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='crl.apple.com'; Port=80; Proto='TCP'; Desc='Apple CRL' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='ocsp.apple.com'; Port=80; Proto='TCP'; Desc='Apple OCSP (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='ocsp2.apple.com'; Port=443; Proto='TCP'; Desc='Apple OCSP2 (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='valid.apple.com'; Port=443; Proto='TCP'; Desc='Apple certificate validation' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='crl3.digicert.com'; Port=80; Proto='TCP'; Desc='DigiCert CRL3' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='crl4.digicert.com'; Port=80; Proto='TCP'; Desc='DigiCert CRL4' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='ocsp.digicert.com'; Port=80; Proto='TCP'; Desc='DigiCert OCSP' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='ocsp.digicert.cn'; Port=80; Proto='TCP'; Desc='DigiCert OCSP (China)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='crl.entrust.net'; Port=80; Proto='TCP'; Desc='Entrust CRL' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Certificate Validation'; Host_='ocsp.entrust.net'; Port=80; Proto='TCP'; Desc='Entrust OCSP' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Classroom'; Host_='play.itunes.apple.com'; Port=443; Proto='TCP'; Desc='Classroom / Schoolwork play' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Classroom'; Host_='ws-ee-maidsvc.icloud.com'; Port=443; Proto='TCP'; Desc='Classroom iCloud service' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Classroom'; Host_='ws.school.apple.com'; Port=443; Proto='TCP'; Desc='Schoolwork web service' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Classroom'; Host_='pg-bootstrap.itunes.apple.com'; Port=443; Proto='TCP'; Desc='Playground bootstrap' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Classroom'; Host_='cls-iosclient.itunes.apple.com'; Port=443; Proto='TCP'; Desc='Classroom iOS client' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Classroom'; Host_='cls-ingest.itunes.apple.com'; Port=443; Proto='TCP'; Desc='Classroom ingest' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Content Caching'; Host_='suconfig.apple.com'; Port=80; Proto='TCP'; Desc='Software update config (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Content Caching'; Host_='xp-cdn.apple.com'; Port=443; Proto='TCP'; Desc='Content cache CDN' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Content Caching'; Host_='lcdn-locator.apple.com'; Port=443; Proto='TCP'; Desc='LCDN locator' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Content Caching'; Host_='lcdn-registration.apple.com'; Port=443; Proto='TCP'; Desc='LCDN registration' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Content Caching'; Host_='serverstatus.apple.com'; Port=443; Proto='TCP'; Desc='Server status' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Management'; Host_='mdmenrollment.apple.com'; Port=443; Proto='TCP'; Desc='MDM enrollment (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Management'; Host_='mdmenrollment.apple.com'; Port=80; Proto='TCP'; Desc='MDM enrollment (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Management'; Host_='gdmf.apple.com'; Port=443; Proto='TCP'; Desc='Device management firmware' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Management'; Host_='iprofiles.apple.com'; Port=443; Proto='TCP'; Desc='Enrollment profiles' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Management'; Host_='deviceenrollment.apple.com'; Port=443; Proto='TCP'; Desc='Device enrollment' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Management'; Host_='deviceservices-external.apple.com'; Port=443; Proto='TCP'; Desc='Device services' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Management'; Host_='identity.apple.com'; Port=443; Proto='TCP'; Desc='Identity services' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='time.apple.com'; Port=123; Proto='UDP'; Desc='NTP time sync (Apple)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='time-macos.apple.com'; Port=123; Proto='UDP'; Desc='NTP time sync (macOS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='time-ios.apple.com'; Port=123; Proto='UDP'; Desc='NTP time sync (iOS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='captive.apple.com'; Port=443; Proto='TCP'; Desc='Captive portal detection (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='captive.apple.com'; Port=80; Proto='TCP'; Desc='Captive portal detection (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='static.ips.apple.com'; Port=443; Proto='TCP'; Desc='Static IPs (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='static.ips.apple.com'; Port=80; Proto='TCP'; Desc='Static IPs (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='humb.apple.com'; Port=443; Proto='TCP'; Desc='Device humb' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='sq-device.apple.com'; Port=443; Proto='TCP'; Desc='Device sequencing' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='albert.apple.com'; Port=443; Proto='TCP'; Desc='Device activation' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='tbsc.apple.com'; Port=443; Proto='TCP'; Desc='TBSC' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Device Setup'; Host_='gs.apple.com'; Port=443; Proto='TCP'; Desc='Gateway services (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Feedback Assistant'; Host_='bpapi.apple.com'; Port=443; Proto='TCP'; Desc='Feedback API' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Feedback Assistant'; Host_='cssubmissions.apple.com'; Port=443; Proto='TCP'; Desc='Crash submissions' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Feedback Assistant'; Host_='fba.apple.com'; Port=443; Proto='TCP'; Desc='Feedback Assistant' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Private Cloud Compute'; Host_='apple-relay.cloudflare.com'; Port=443; Proto='TCP'; Desc='Private Cloud Compute (Cloudflare)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Private Cloud Compute'; Host_='cp4.cloudflare.com'; Port=443; Proto='TCP'; Desc='Private Cloud Compute (Cloudflare CP4)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Private Cloud Compute'; Host_='apple-relay.fastly-edge.com'; Port=443; Proto='TCP'; Desc='Private Cloud Compute (Fastly)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Siri'; Host_='guzzoni.apple.com'; Port=443; Proto='TCP'; Desc='Siri and dictation' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Siri'; Host_='api.smoot.apple.com'; Port=443; Proto='TCP'; Desc='Siri API / Spotlight' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='configuration.apple.com'; Port=443; Proto='TCP'; Desc='Software update configuration' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='appldnld.apple.com'; Port=80; Proto='TCP'; Desc='Software update downloads (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='mesu.apple.com'; Port=443; Proto='TCP'; Desc='macOS extended software update (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='mesu.apple.com'; Port=80; Proto='TCP'; Desc='macOS extended software update (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='oscdn.apple.com'; Port=443; Proto='TCP'; Desc='OS content CDN (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='oscdn.apple.com'; Port=80; Proto='TCP'; Desc='OS content CDN (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='gdmf.apple.com'; Port=443; Proto='TCP'; Desc='Device management firmware' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='gs.apple.com'; Port=443; Proto='TCP'; Desc='Gateway services (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='gs.apple.com'; Port=80; Proto='TCP'; Desc='Gateway services (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='gg.apple.com'; Port=443; Proto='TCP'; Desc='OS updates (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='gg.apple.com'; Port=80; Proto='TCP'; Desc='OS updates (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='ig.apple.com'; Port=443; Proto='TCP'; Desc='iOS updates' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='swdist.apple.com'; Port=443; Proto='TCP'; Desc='Software distribution' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='swcdn.apple.com'; Port=80; Proto='TCP'; Desc='Software Update CDN (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='xp.apple.com'; Port=443; Proto='TCP'; Desc='Xcode / platform updates' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='swscan.apple.com'; Port=443; Proto='TCP'; Desc='Software Update catalog scan' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='updates.cdn-apple.com'; Port=443; Proto='TCP'; Desc='Software distribution CDN (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='updates-http.cdn-apple.com'; Port=80; Proto='TCP'; Desc='Software distribution CDN (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='osrecovery.apple.com'; Port=443; Proto='TCP'; Desc='Internet Recovery (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='osrecovery.apple.com'; Port=80; Proto='TCP'; Desc='Internet Recovery (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='skl.apple.com'; Port=443; Proto='TCP'; Desc='Software content delivery' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='swdownload.apple.com'; Port=443; Proto='TCP'; Desc='Software download (HTTPS)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Software Updates'; Host_='swdownload.apple.com'; Port=80; Proto='TCP'; Desc='Software download (HTTP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Tap to Pay'; Host_='app-site-association.cdn-apple.com'; Port=443; Proto='TCP'; Desc='Tap to Pay app association (TCP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Tap to Pay'; Host_='app-site-association.cdn-apple.com'; Port=443; Proto='UDP'; Desc='Tap to Pay app association (UDP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Tap to Pay'; Host_='app-site-association.networking.apple'; Port=443; Proto='TCP'; Desc='Tap to Pay networking (TCP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Tap to Pay'; Host_='app-site-association.networking.apple'; Port=443; Proto='UDP'; Desc='Tap to Pay networking (UDP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Tap to Pay'; Host_='pos-device.apple.com'; Port=443; Proto='TCP'; Desc='POS device (TCP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Tap to Pay'; Host_='pos-device.apple.com'; Port=443; Proto='UDP'; Desc='POS device (UDP)' },
    [PSCustomObject]@{ Apple=$true; Category='Apple Tap to Pay'; Host_='humb.apple.com'; Port=443; Proto='TCP'; Desc='Tap to Pay humb' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='api.apple-cloudkit.com'; Port=443; Proto='TCP'; Desc='CloudKit API' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='appleid.cdn-apple.com'; Port=443; Proto='TCP'; Desc='Apple ID CDN' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='cdn.icloud-content.com'; Port=443; Proto='TCP'; Desc='iCloud content CDN' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='developer.icloud.com'; Port=443; Proto='TCP'; Desc='iCloud for Developers' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='developer.icloud.com.cn'; Port=443; Proto='TCP'; Desc='iCloud for Developers (China)' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='publish.iwork.apple.com'; Port=443; Proto='TCP'; Desc='iWork publishing' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='api.icloud.apple.com'; Port=443; Proto='TCP'; Desc='iCloud API' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='cdn.apple-livephotoskit.com'; Port=443; Proto='TCP'; Desc='Live Photos CDN' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='service.gc.apple.com'; Port=443; Proto='TCP'; Desc='iCloud GC service' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='idmsaapz-mdn.apzones.com'; Port=443; Proto='TCP'; Desc='iCloud identity service' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='setup.apple-cloudkit.com'; Port=443; Proto='TCP'; Desc='CloudKit setup' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='mask.icloud.com'; Port=443; Proto='UDP'; Desc='iCloud Private Relay (UDP)' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='mask-h2.icloud.com'; Port=443; Proto='UDP'; Desc='iCloud Private Relay H2 (UDP)' },
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='mask-api.icloud.com'; Port=443; Proto='UDP'; Desc='iCloud Private Relay API (UDP)' },
    # Google (-Google). Google doesn't publish its hostnames as a feed, so these come from its allowlist articles:
    #   Workspace: https://knowledge.workspace.google.com/admin/getting-started/set-up-a-google-workspace-host-name-allowlist
    #   Meet:      https://knowledge.workspace.google.com/admin/meet/prepare-your-network-for-meet-meetings-and-live-streams
    #   Android:   https://support.google.com/work/android/answer/10513641
    #   Chrome:    https://support.google.com/chrome/a/answer/6334001
    # FCM's TCP 5228-5230 is tested on the mtalk and XMPP connection hosts (the googleapis.com API hosts only answer on 443); Meet media (UDP 3478, 19302-19309) on its TURN servers
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='accounts.google.com'; Port=443; Proto='TCP'; Desc='Authentication' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='oauth2.googleapis.com'; Port=443; Proto='TCP'; Desc='Authentication' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='www.googleapis.com'; Port=443; Proto='TCP'; Desc='Authentication' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='*.googleapis.com'; Port=443; Proto='TCP'; Desc='Main API entry point' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='gemini.google.com'; Port=443; Proto='TCP'; Desc='Generative AI' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='notebook.google.com'; Port=443; Proto='TCP'; Desc='Generative AI' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='aistudio.google.com'; Port=443; Proto='TCP'; Desc='Generative AI' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='drive.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='docs.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='sheets.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='slides.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='sites.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='meet.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='calendar.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='keep.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='script.google.com'; Port=443; Proto='TCP'; Desc='User-facing services' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='mail.google.com'; Port=443; Proto='TCP'; Desc='Gmail' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='chat.google.com'; Port=443; Proto='TCP'; Desc='Google Chat' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='www.google.com'; Port=443; Proto='TCP'; Desc='Contacts, GAL and account sign-in' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='apps-apis.google.com'; Port=443; Proto='TCP'; Desc='Admin Settings API' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='classroom.googleapis.com'; Port=443; Proto='TCP'; Desc='Workspace APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='sheets.googleapis.com'; Port=443; Proto='TCP'; Desc='Workspace APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='slides.googleapis.com'; Port=443; Proto='TCP'; Desc='Workspace APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='people.googleapis.com'; Port=443; Proto='TCP'; Desc='Workspace APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='accounts.youtube.com'; Port=443; Proto='TCP'; Desc='Additional authentication' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='fonts.gstatic.com'; Port=443; Proto='TCP'; Desc='Static content' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='ssl.gstatic.com'; Port=443; Proto='TCP'; Desc='Static content' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='www.gstatic.com'; Port=443; Proto='TCP'; Desc='Static content' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='*.googleusercontent.com'; Port=443; Proto='TCP'; Desc='User content' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='scf.usercontent.goog'; Port=443; Proto='TCP'; Desc='User content' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='www.youtubeeducation.com'; Port=443; Proto='TCP'; Desc='YouTube in Education' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='meetings.googleapis.com'; Port=443; Proto='TCP'; Desc='Google Meet APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='hangouts.googleapis.com'; Port=443; Proto='TCP'; Desc='Google Meet APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='apis.google.com'; Port=443; Proto='TCP'; Desc='Google Meet APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='apps.google.com'; Port=443; Proto='TCP'; Desc='Google Meet APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='clients2.google.com'; Port=443; Proto='TCP'; Desc='Google Meet static resources' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='clients4.google.com'; Port=443; Proto='TCP'; Desc='Google Meet static resources' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='clients6.google.com'; Port=443; Proto='TCP'; Desc='Google Meet static resources' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='*.clients6.google.com'; Port=443; Proto='TCP'; Desc='Google Meet static resources' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='lh3.googleusercontent.com'; Port=443; Proto='TCP'; Desc='Google Meet static resources' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='stream.meet.google.com'; Port=443; Proto='TCP'; Desc='Google Meet live streaming' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='feedback.googleusercontent.com'; Port=443; Proto='TCP'; Desc='Google Meet feedback and logging' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='play.google.com'; Port=443; Proto='TCP'; Desc='Google Meet feedback and logging' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='*.googlevideo.com'; Port=443; Proto='TCP'; Desc='Google Meet media content' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='*.youtube-nocookie.com'; Port=443; Proto='TCP'; Desc='Google Meet media content' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='*.ytimg.com'; Port=443; Proto='TCP'; Desc='Google Meet media content' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='meet.google.com'; Port=443; Proto='UDP'; Desc='Google Meet web traffic (QUIC)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=3478; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=19302; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=19303; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=19304; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=19305; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=19306; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=19307; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=19308; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='workspace.turns.goog'; Port=19309; Proto='UDP'; Desc='Google Meet audio and video' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='crl.pki.goog'; Port=80; Proto='TCP'; Desc='Certificate revocation (CRL)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='c.pki.goog'; Port=80; Proto='TCP'; Desc='Certificate revocation (CRL)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Workspace'; Host_='ocsp.pki.goog'; Port=80; Proto='TCP'; Desc='Certificate status (OCSP)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='play.google.com'; Port=443; Proto='TCP'; Desc='Google Play and updates' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='android.com'; Port=443; Proto='TCP'; Desc='Google Play and updates' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='google-analytics.com'; Port=443; Proto='TCP'; Desc='Google Play and updates' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='*.gstatic.com'; Port=443; Proto='TCP'; Desc='Google Play and updates' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='googleusercontent.com'; Port=443; Proto='TCP'; Desc='User-generated content such as app icons' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='*.gvt1.com'; Port=443; Proto='TCP'; Desc='App downloads, updates and Play Store APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='*.ggpht.com'; Port=443; Proto='TCP'; Desc='App downloads, updates and Play Store APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='dl.google.com'; Port=443; Proto='TCP'; Desc='App downloads, updates and Play Store APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='dl-ssl.google.com'; Port=443; Proto='TCP'; Desc='App downloads, updates and Play Store APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='android.apis.google.com'; Port=443; Proto='TCP'; Desc='Play Store APIs and device policy downloads' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='*.gvt2.com'; Port=443; Proto='TCP'; Desc='Play connectivity monitoring and diagnostics' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='*.gvt3.com'; Port=443; Proto='TCP'; Desc='Play connectivity monitoring and diagnostics' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='*.googleapis.com'; Port=443; Proto='TCP'; Desc='EMM, Play EMM and Android Management APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='m.google.com'; Port=443; Proto='TCP'; Desc='EMM, Play EMM and Android Management APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='www.googleapis.com'; Port=443; Proto='TCP'; Desc='EMM, Play EMM and Android Management APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='androidmanagement.googleapis.com'; Port=443; Proto='TCP'; Desc='Android Management API' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='accounts.google.com'; Port=443; Proto='TCP'; Desc='Authentication' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='accounts.youtube.com'; Port=443; Proto='TCP'; Desc='Authentication' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='gcm-http.googleapis.com'; Port=443; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='gcm-xmpp.googleapis.com'; Port=443; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='gcm-xmpp.googleapis.com'; Port=5228; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='gcm-xmpp.googleapis.com'; Port=5229; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='gcm-xmpp.googleapis.com'; Port=5230; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='android.googleapis.com'; Port=443; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='fcm.googleapis.com'; Port=443; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='fcm-xmpp.googleapis.com'; Port=443; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='fcm-xmpp.googleapis.com'; Port=5228; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='fcm-xmpp.googleapis.com'; Port=5229; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='fcm-xmpp.googleapis.com'; Port=5230; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='firebaseinstallations.googleapis.com'; Port=443; Proto='TCP'; Desc='Firebase / Google Cloud Messaging (EMM console to device)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='fcm-xmpp.googleapis.com'; Port=5235; Proto='TCP'; Desc='FCM / GCM persistent XMPP connection' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='fcm-xmpp.googleapis.com'; Port=5236; Proto='TCP'; Desc='FCM / GCM persistent XMPP connection' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='gcm-xmpp.googleapis.com'; Port=5235; Proto='TCP'; Desc='FCM / GCM persistent XMPP connection' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='gcm-xmpp.googleapis.com'; Port=5236; Proto='TCP'; Desc='FCM / GCM persistent XMPP connection' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='firebaselogging.googleapis.com'; Port=443; Proto='TCP'; Desc='AMAPI SDK logging and metrics' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='pki.google.com'; Port=443; Proto='TCP'; Desc='Certificate revocation checks' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='clients1.google.com'; Port=443; Proto='TCP'; Desc='Certificate revocation checks' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='crl.pki.goog'; Port=443; Proto='TCP'; Desc='Certificate validation' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='ocsp.pki.goog'; Port=443; Proto='TCP'; Desc='Certificate validation' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='clients2.google.com'; Port=443; Proto='TCP'; Desc='Crash reporting, bookmark sync, time sync' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='clients3.google.com'; Port=443; Proto='TCP'; Desc='Crash reporting, bookmark sync, time sync' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='clients4.google.com'; Port=443; Proto='TCP'; Desc='Crash reporting, bookmark sync, time sync' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='clients5.google.com'; Port=443; Proto='TCP'; Desc='Crash reporting, bookmark sync, time sync' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='clients6.google.com'; Port=443; Proto='TCP'; Desc='Crash reporting, bookmark sync, time sync' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='chromiumdash.appspot.com'; Port=443; Proto='TCP'; Desc='Chrome updates' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='connectivitycheck.android.com'; Port=443; Proto='TCP'; Desc='Connectivity checks' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='connectivitycheck.gstatic.com'; Port=443; Proto='TCP'; Desc='Connectivity checks' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='www.google.com'; Port=443; Proto='TCP'; Desc='Connectivity checks' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='ota.googlezip.net'; Port=443; Proto='TCP'; Desc='Over-the-air (GOTA) updates' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='ota-cache1.googlezip.net'; Port=443; Proto='TCP'; Desc='Over-the-air (GOTA) updates' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='ota-cache3.googlezip.net'; Port=443; Proto='TCP'; Desc='Over-the-air (GOTA) updates' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk4.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk4.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk4.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk4.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk-staging.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk-staging.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk-staging.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk-staging.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk-dev.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk-dev.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk-dev.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='mtalk-dev.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt1-mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt1-mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt1-mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt1-mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt2-mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt2-mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt2-mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt2-mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt3-mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt3-mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt3-mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt3-mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt4-mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt4-mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt4-mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt4-mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt5-mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt5-mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt5-mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt5-mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt6-mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt6-mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt6-mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt6-mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt7-mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt7-mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt7-mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt7-mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt8-mtalk.google.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt8-mtalk.google.com'; Port=5228; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt8-mtalk.google.com'; Port=5229; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='alt8-mtalk.google.com'; Port=5230; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='device-provisioning.googleapis.com'; Port=443; Proto='TCP'; Desc='FCM connectivity behind firewalls' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='time.google.com'; Port=123; Proto='UDP'; Desc='NTP during provisioning' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='android-safebrowsing.google.com'; Port=443; Proto='TCP'; Desc='Google Play Protect (Safe Browsing)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='safebrowsing.google.com'; Port=443; Proto='TCP'; Desc='Google Play Protect (Safe Browsing)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='fonts.googleapis.com'; Port=443; Proto='TCP'; Desc='Console iFrame and fonts' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='apis.google.com'; Port=443; Proto='TCP'; Desc='Console iFrame and fonts' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='ajax.googleapis.com'; Port=443; Proto='TCP'; Desc='Console iFrame and fonts' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='payments.google.com'; Port=443; Proto='TCP'; Desc='Console app approval' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='google.com'; Port=443; Proto='TCP'; Desc='Console app approval' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='ogs.google.com'; Port=443; Proto='TCP'; Desc='Console UI and notifications' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='notifications.google.com'; Port=443; Proto='TCP'; Desc='Console UI and notifications' },
    [PSCustomObject]@{ Apple=$false; Category='Google Android Enterprise'; Host_='enterprise.google.com'; Port=443; Proto='TCP'; Desc='Zero-touch console' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='tools.google.com'; Port=443; Proto='TCP'; Desc='Update configuration (Omaha)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='edgedl.me.gvt1.com'; Port=443; Proto='TCP'; Desc='Update payload downloads' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='dl.google.com'; Port=443; Proto='TCP'; Desc='Update payload downloads' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='m.google.com'; Port=443; Proto='TCP'; Desc='Enrollment and policy fetches' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='clients3.google.com'; Port=443; Proto='TCP'; Desc='System clock sync' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='www.googleapis.com'; Port=443; Proto='TCP'; Desc='OAuth and Google APIs' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='accounts.google.com'; Port=443; Proto='TCP'; Desc='ChromeOS sign-in' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='www.google.com'; Port=443; Proto='TCP'; Desc='ChromeOS sign-in' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='www.gstatic.com'; Port=443; Proto='TCP'; Desc='Sign-in page content and enrollment status' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='ssl.gstatic.com'; Port=443; Proto='TCP'; Desc='Sign-in page content and enrollment status' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='chromeos-ca.gstatic.com'; Port=443; Proto='TCP'; Desc='Attestation CA (zero-touch / forced re-enrollment)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='connectivitycheck.gstatic.com'; Port=80; Proto='TCP'; Desc='Captive portal probe (HTTP)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='play.googleapis.com'; Port=80; Proto='TCP'; Desc='Captive portal probe (HTTP)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='www.gstatic.com'; Port=80; Proto='TCP'; Desc='Captive portal probe (HTTP)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='safebrowsing.google.com'; Port=80; Proto='TCP'; Desc='Captive portal probe (HTTP)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='www.googleapis.com'; Port=80; Proto='TCP'; Desc='Captive portal probe (HTTP)' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='*.1e100.net'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='accounts.gstatic.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='accounts.youtube.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='alkalichromeosflexhwis2-pa.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='aratea-pa.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='chromeosquirksserver-pa.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='chromereporting-pa.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='clients1.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='clients2.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='clients4.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='clients2.googleusercontent.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='cloudsearch.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='commondatastorage.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='cros-omahaproxy.appspot.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='dl-ssl.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='enterprise-safebrowsing.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='firebaseperusertopics-pa.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='*.googleusercontent.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='*.gvt1.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='gweb-gettingstartedguide.appspot.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='mtalk.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='oauthaccountmanager.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='omahaproxy.appspot.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='pack.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='policies.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='printerconfigurations.googleusercontent.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='safebrowsing-cache.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='safebrowsing.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='safebrowsing.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='sb-ssl.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='scone-pa.clients6.google.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='storage.googleapis.com'; Port=443; Proto='TCP'; Desc='Recommended ChromeOS allowlist' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='chrome.google.com'; Port=443; Proto='TCP'; Desc='Chrome Web Store extensions and apps' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='lh3.ggpht.com'; Port=443; Proto='TCP'; Desc='Chrome Web Store extensions and apps' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='lh4.ggpht.com'; Port=443; Proto='TCP'; Desc='Chrome Web Store extensions and apps' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='lh5.ggpht.com'; Port=443; Proto='TCP'; Desc='Chrome Web Store extensions and apps' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='lh6.ggpht.com'; Port=443; Proto='TCP'; Desc='Chrome Web Store extensions and apps' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='update.googleapis.com'; Port=443; Proto='TCP'; Desc='Chrome Web Store extensions and apps' },
    [PSCustomObject]@{ Apple=$false; Category='Google Chrome Enterprise'; Host_='youtubeeducation.com'; Port=443; Proto='TCP'; Desc='YouTube Player for Education' }
)

# ── Live list sources (fetched each run, same as jamf_network_test.sh) ─────────
# Source: https://learn.jamf.com/r/en-US/jamf-ip-address-list/Permitting_InboundOutbound_Traffic_with_Jamf
$JamfIpListUrl   = 'https://engineering.jamf.com/tc-docs-public-ip-lists/public-ips.json'
$AppleReqsUrl    = 'https://support.apple.com/en-us/101555'
$ApplePortsUrl   = 'https://support.apple.com/en-us/103229'
$GoogRangesUrl   = 'https://www.gstatic.com/ipranges/goog.json'
$GCloudRangesUrl = 'https://www.gstatic.com/ipranges/cloud.json'
# Source: https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges
$MsEndpointsUrl  = 'https://endpoints.office.com/endpoints/worldwide?ServiceAreas=Common,Exchange,SharePoint,Skype,MEM'
$MsVersionUrl    = 'https://endpoints.office.com/version/worldwide'
$AzureTagsUrl    = 'https://www.microsoft.com/en-us/download/details.aspx?id=56519'
# Microsoft republishes this under a new dated filename each week, so walk back from today
$AzureTagsBase   = 'https://download.microsoft.com/download/7/1/d/71d86715-5596-4529-9b13-da13a5de5b63/ServiceTags_Public_'

$JamfIpDate = '';  $JamfIpEntries = @()
$AppleHtml = '';   $AppleEntries = @(); $AppleSource = 'built-in list'
$AppleRanges = @('17.0.0.0/8')   # replaced by the CIDRs published on the page when it downloads
$GoogleDate = '';  $GoogleEntries = @()
$MsVersion = '';   $MsEntries = @()
$AzureTagsData = $null; $AzureTagsDate = ''

# ── Download helpers ──────────────────────────────────────────────────────────
# Always decode as UTF-8 (5.1 falls back to ISO-8859-1 when no charset is sent)
function Get-WebText([string]$Url, [int]$Timeout = ($TimeoutSec * 2)) {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $Timeout
    [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
}

function ConvertFrom-JsonText([string]$Json) {
    try {
        return ($Json | ConvertFrom-Json)
    } catch {
        # Windows PowerShell 5.1's ConvertFrom-Json rejects strings over 2 MB (e.g. the Azure service tags file)
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        return $ser.DeserializeObject($Json)
    }
}

# Field of a parsed JSON object, whichever parser produced it
function Get-Field($Object, [string]$Name) {
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $Object.$Name
}

# Run a fetch function; any download or parse error counts as "unavailable"
function Test-Fetch([scriptblock]$Fetch) {
    try { [bool](& $Fetch) } catch { $false }
}

# ── Jamf published IP / FQDN list ─────────────────────────────────────────────
function Get-JamfIpList {
    $d = ConvertFrom-JsonText (Get-WebText $JamfIpListUrl)
    $script:JamfIpDate = [string]$d.publish_date
    $script:JamfIpEntries = @(foreach ($e in $d.public_ips) {
        [PSCustomObject]@{
            Service = [string]$e.service; Traffic = [string]$e.traffic; Provider = [string]$e.provider; Region = [string]$e.region
            Ips = @($e.ip_prefixes | Where-Object { $_ }); Fqdns = @($e.fqdns | Where-Object { $_ })
        }
    })
    $script:JamfIpEntries.Count -gt 0
}

# Friendly names for the service keys used in the Jamf JSON
function Get-JamfServiceLabel([string]$Service) {
    switch ($Service) {
        'jamf_pro_cloud'                  { 'Jamf Pro (Cloud)' }
        'jamf_cloud_services'             { 'Jamf Cloud Services' }
        'jamf_cloud_distribution_service' { 'Jamf Cloud Distribution Service (JCDS)' }
        'jamf_ztna_endpoint'              { 'Jamf ZTNA Endpoint' }
        default                           { $Service }
    }
}

# ── Apple network requirements (parsed live from support.apple.com) ──────────
# Download Apple's network requirements page once; its CIDR ranges feed the IP checks
function Get-ApplePage {
    $script:AppleHtml = Get-WebText $AppleReqsUrl
    $ranges = @([regex]::Matches($script:AppleHtml, '[0-9]{1,3}(?:\.[0-9]{1,3}){3}/[0-9]{1,2}') |
        ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($ranges.Count -gt 0) { $script:AppleRanges = $ranges }
    $true
}

# Text of an HTML fragment: tags dropped, entities decoded, whitespace collapsed
function ConvertFrom-HtmlFragment([string]$Html) {
    $text = $Html -replace '(?i)<br\s*/?>', ' ' -replace '<[^>]*>', ''
    @([System.Net.WebUtility]::HtmlDecode($text) -split '\s+' | Where-Object { $_ }) -join ' '
}

# Pull every Hosts/Ports/Protocol table row from Apple's network requirements page
function Get-AppleRequirements {
    if (-not $AppleHtml) { return $false }
    $heading = ''
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($AppleHtml, '(?is)<(h[23])\b[^>]*>(.*?)</\1\s*>|<tr\b[^>]*>(.*?)</tr\s*>')) {
        if ($m.Groups[1].Success) { $heading = ConvertFrom-HtmlFragment $m.Groups[2].Value; continue }
        $cells = @([regex]::Matches($m.Groups[3].Value, '(?is)<t[dh]\b[^>]*>(.*?)</t[dh]\s*>') |
            ForEach-Object { (ConvertFrom-HtmlFragment $_.Groups[1].Value).Replace('|', '/') })
        # Hosts | Ports | Protocol | OS | Description | ...
        if ($cells.Count -lt 5 -or $cells[1] -notmatch '^[0-9][0-9, ]*\z') { continue }
        foreach ($h in ($cells[0].Replace(',', ' ') -split '\s+')) {
            if ($h -cmatch '^[*\w.-]+\.[a-z]+\z') {
                $entries.Add([PSCustomObject]@{ Heading = $heading; Host = $h; Ports = $cells[1]; Protos = $cells[2]; Desc = $cells[4] })
            }
        }
    }
    $script:AppleEntries = $entries.ToArray()
    if ($entries.Count -gt 0) { $script:AppleSource = 'live from support.apple.com/101555' }
    $entries.Count -gt 0
}

# Run one test per host / port / protocol from the live Apple list (duplicates skipped)
function Invoke-AppleLive {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $prev = $null
    foreach ($e in $AppleEntries) {
        $category = if ($e.Heading -clike 'Apple*') { $e.Heading } else { "Apple $($e.Heading)" }
        if ($e.Heading -cne $prev) { Write-Host "      $($e.Heading)"; $prev = $e.Heading }
        foreach ($port in ($e.Ports -split '[,\s]+' | Where-Object { $_ })) {
            foreach ($proto in ($e.Protos -split '[,/\s]+' | Where-Object { $_ })) {
                if ($proto -cne 'UDP') { $proto = 'TCP' }   # "SSH", "and", etc. are TCP
                if ($seen.Add("$($e.Host):$port/$proto")) { Invoke-Test $category $e.Host $port $proto $e.Desc }
            }
        }
    }
}

# Built-in fallback, used when support.apple.com/101555 can't be fetched or parsed
function Invoke-AppleBuiltin {
    $prev = $null
    foreach ($t in $AllTests) {
        if (-not $t.Apple) { continue }
        if ($t.Category -cne $prev) { Write-Host "      $($t.Category)"; $prev = $t.Category }
        Invoke-Test $t.Category $t.Host_ $t.Port $t.Proto $t.Desc
    }
}

# ── Wildcard hosts ────────────────────────────────────────────────────────────
# Concrete host to test for a wildcard entry: a known-good example, else the base domain
$WildcardExamples = @{
    '*.push.apple.com'          = '1-courier.push.apple.com'
    '*.apple-cloudkit.com'      = 'api.apple-cloudkit.com'
    '*.gc.apple.com'            = 'service.gc.apple.com'
    '*.appattest.apple.com'     = 'register.appattest.apple.com'
    '*.apple-mapkit.com'        = 'api.apple-mapkit.com'
    '*.apple-livephotoskit.com' = 'cdn.apple-livephotoskit.com'
    '*.apzones.com'             = 'idmsaapz-mdn.apzones.com'
    '*.cdn-apple.com'           = 'appleid.cdn-apple.com'
    '*.icloud.apple.com'        = 'api.icloud.apple.com'
    '*.iwork.apple.com'         = 'publish.iwork.apple.com'
    '*.smoot.apple.com'         = 'api.smoot.apple.com'
    '*.manage.microsoft.com'    = 'enrollment.manage.microsoft.com'
    '*.microsoftonline.com'     = 'login.microsoftonline.com'
    '*.googleapis.com'          = 'www.googleapis.com'
    '*.gstatic.com'             = 'www.gstatic.com'
    '*.googleusercontent.com'   = 'lh3.googleusercontent.com'
    '*.gvt1.com'                = 'edgedl.me.gvt1.com'
    '*.gvt2.com'                = 'beacons.gvt2.com'
    '*.ggpht.com'               = 'lh3.ggpht.com'
    '*.googlevideo.com'         = 'redirector.googlevideo.com'
    '*.youtube-nocookie.com'    = 'www.youtube-nocookie.com'
    '*.ytimg.com'               = 'i.ytimg.com'
}

function Get-WildcardTestHost([string]$HostName, [int]$Port) {
    if ($HostName -eq '*.push.apple.com' -and $Port -eq 2197) { return 'api.push.apple.com' }
    if ($WildcardExamples.ContainsKey($HostName)) { return $WildcardExamples[$HostName] }
    if ($HostName.Contains('*')) { return Get-WildcardBase $HostName }
    $HostName
}

# Domain under a wildcard: "*.example.com", "*cdn.example.com", "autodiscover.*.example.com"
#   -> "example.com", "cdn.example.com", "example.com"
function Get-WildcardBase([string]$HostName) {
    $base = $HostName.Substring($HostName.IndexOf('*') + 1)
    if ($base.StartsWith('.')) { $base = $base.Substring(1) }
    $base
}

# ── Google published IP ranges (report reference + IP matching) ──────────────
# Network as start/end integers, so IPv4 and IPv6 share the same maths
function ConvertTo-IpNet([string]$Prefix) {
    $addr, $len = $Prefix.Trim().Split('/')
    $bytes = [System.Net.IPAddress]::Parse($addr).GetAddressBytes()
    $bits = $bytes.Length * 8
    [array]::Reverse($bytes)
    $n = $BigInt::new([byte[]]($bytes + [byte]0))   # trailing 0 byte keeps it unsigned
    $len = if ($len) { [int]$len } else { $bits }
    $size = $BigInt::Pow(2, $bits - $len)
    $start = $n - ($n % $size)   # normalise to the network address
    [PSCustomObject]@{ Bits = $bits; Len = $len; Start = $start; End = $start + $size - 1 }
}

function Format-IpNet($Net) {
    $le = $Net.Start.ToByteArray()   # little-endian, may carry an extra sign byte
    $bytes = New-Object byte[] ($Net.Bits / 8)
    [array]::Copy($le, $bytes, [math]::Min($le.Length, $bytes.Length))
    [array]::Reverse($bytes)
    "$([System.Net.IPAddress]::new($bytes))/$($Net.Len)"
}

# The parts of $Net left after cutting out $Hole (which lies inside it)
function Remove-IpNet($Net, $Hole) {
    while ($Net.Len -lt $Hole.Len) {
        $half = $BigInt::Pow(2, $Net.Bits - $Net.Len - 1)
        $lo = [PSCustomObject]@{ Bits = $Net.Bits; Len = $Net.Len + 1; Start = $Net.Start; End = $Net.Start + $half - 1 }
        $hi = [PSCustomObject]@{ Bits = $Net.Bits; Len = $Net.Len + 1; Start = $Net.Start + $half; End = $Net.End }
        if ($Hole.Start -le $lo.End) { $hi; $Net = $lo } else { $lo; $Net = $hi }
    }
}

# Smallest equivalent list of networks (drops contained ones, joins adjacent halves)
function Merge-IpNets($Nets) {
    $stack = New-Object System.Collections.Generic.List[object]
    foreach ($n in @($Nets | Sort-Object Start, Len)) {
        if ($stack.Count -and $n.End -le $stack[$stack.Count - 1].End) { continue }
        $stack.Add($n)
        while ($stack.Count -ge 2) {
            $a = $stack[$stack.Count - 2]; $b = $stack[$stack.Count - 1]
            $size = $b.End - $b.Start + 1
            if ($a.Len -ne $b.Len -or $a.End + 1 -ne $b.Start -or -not ($a.Start % ($size * 2)).IsZero) { break }
            $stack.RemoveRange($stack.Count - 2, 2)
            $stack.Add([PSCustomObject]@{ Bits = $a.Bits; Len = $a.Len - 1; Start = $a.Start; End = $b.End })
        }
    }
    $stack
}

function Get-PrefixText($Entry) {
    if ($Entry.ipv4Prefix) { $Entry.ipv4Prefix } else { $Entry.ipv6Prefix }
}

# Google's guidance: Google services = goog.json minus cloud.json (cloud ranges belong to Cloud customers)
function Get-GoogleRanges {
    $goog = ConvertFrom-JsonText (Get-WebText $GoogRangesUrl)
    $cloud = ConvertFrom-JsonText (Get-WebText $GCloudRangesUrl)
    $cloudNets = @($cloud.prefixes | ForEach-Object { ConvertTo-IpNet (Get-PrefixText $_) })
    $services = foreach ($n in @($goog.prefixes | ForEach-Object { ConvertTo-IpNet (Get-PrefixText $_) })) {
        $parts = @($n)
        foreach ($c in $cloudNets) {
            if ($c.Bits -ne $n.Bits -or $c.End -lt $n.Start -or $c.Start -gt $n.End) { continue }
            $parts = @(foreach ($p in $parts) {
                if ($c.Start -ge $p.Start -and $c.End -le $p.End) { Remove-IpNet $p $c }
                elseif (-not ($p.Start -ge $c.Start -and $p.End -le $c.End)) { $p }
            })
        }
        $parts
    }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($v in @(@(32, 'IPv4'), @(128, 'IPv6'))) {
        $nets = Merge-IpNets @($services | Where-Object { $_.Bits -eq $v[0] })
        $entries.Add([PSCustomObject]@{ Kind = 'services'; Scope = $v[1]; Prefixes = @($nets | ForEach-Object { Format-IpNet $_ }) })
    }
    foreach ($g in ($cloud.prefixes | Group-Object scope | Sort-Object Name)) {
        $entries.Add([PSCustomObject]@{ Kind = 'cloud'; Scope = $g.Name; Prefixes = @($g.Group | ForEach-Object { Get-PrefixText $_ }) })
    }
    # PowerShell 7's ConvertFrom-Json turns ISO timestamps into dates; show it as published
    $created = $goog.creationTime
    if ($created -is [datetime]) { $created = $created.ToString('yyyy-MM-ddTHH:mm:ss.FFFFFF') }
    $script:GoogleDate = [string]$created
    $script:GoogleEntries = $entries.ToArray()
    $entries.Count -gt 0
}

# ── Microsoft 365 / Intune endpoints (live from the Microsoft endpoints web service) ──
function Get-MsEndpoints {
    $req = [guid]::NewGuid().ToString()
    $data = ConvertFrom-JsonText (Get-WebText "$MsEndpointsUrl&clientrequestid=$req")
    try { $script:MsVersion = [string](ConvertFrom-JsonText (Get-WebText "$($MsVersionUrl)?clientrequestid=$req")).latest } catch { }
    $entries = foreach ($e in $data) {
        [PSCustomObject]@{
            Id = [string]$e.id; Area = [string]$e.serviceAreaDisplayName; Category = [string]$e.category; Required = [bool]$e.required
            Tcp = [string]$e.tcpPorts; Udp = [string]$e.udpPorts
            Urls = @($e.urls | Where-Object { $_ }); Ips = @($e.ips | Where-Object { $_ })
        }
    }
    # Group by service area, keeping Microsoft's order within each
    $script:MsEntries = @($entries | Group-Object Area | Sort-Object Name | ForEach-Object { $_.Group })
    $script:MsEntries.Count -gt 0
}

# Run one test per URL / port from the live Microsoft list (duplicates skipped)
function Invoke-MsLive {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $prev = $null
    foreach ($e in $MsEntries) {
        if ($e.Urls.Count -eq 0) { continue }
        if ($e.Area -cne $prev) { Write-Host "      $($e.Area)"; $prev = $e.Area }
        $desc = "Endpoint #$($e.Id)$Dot$($e.Category)$Dot$(if ($e.Required) { 'required' } else { 'optional' })"
        foreach ($url in $e.Urls) {
            foreach ($pp in @(@('TCP', $e.Tcp), @('UDP', $e.Udp))) {
                foreach ($port in ($pp[1] -split '[,\s]+' | Where-Object { $_ })) {
                    $port = ($port -split '-')[0]   # a port range is tested on its first port
                    if ($seen.Add("${url}:$port/$($pp[0])")) { Invoke-Test "Microsoft $($e.Area)" $url $port $pp[0] $desc }
                }
            }
        }
    }
}

# ── Azure IP Ranges and Service Tags (weekly file; newest one found by date) ──
function Get-AzureTags {
    for ($i = 0; $i -lt 28; $i++) {
        $d = (Get-Date).AddDays(-$i).ToString('yyyyMMdd')
        try { $text = Get-WebText "$AzureTagsBase$d.json" 60 } catch { continue }
        $script:AzureTagsData = ConvertFrom-JsonText $text
        $script:AzureTagsDate = $d
        return $true
    }
    $false
}

# ── IP address checks: resolve each tested host, connect to every IPv4 address,
#    and match it against the published Jamf / Apple / Microsoft / Azure / Google ranges ──
$RangeTable = @{}   # prefix length -> @{ network (long) -> list of @(source, label, prefix) }

function ConvertTo-IPv4Long([string]$Ip) {
    $o = $Ip.Split('.')
    ([long]$o[0] -shl 24) + ([long]$o[1] -shl 16) + ([long]$o[2] -shl 8) + [long]$o[3]
}

function Format-IPv4([long]$X) {
    '{0}.{1}.{2}.{3}' -f (($X -shr 24) -band 255), (($X -shr 16) -band 255), (($X -shr 8) -band 255), ($X -band 255)
}

function Get-IPv4Mask([int]$Len) {
    ([long]4294967295 -shl (32 - $Len)) -band [long]4294967295
}

# Only IPv4 prefixes are kept: the checks connect to IPv4 addresses
function Add-Range([string]$Source, [string]$Label, [string]$Prefix) {
    $addr, $len = $Prefix.Trim().Split('/')
    if ($addr -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return }
    $len = if ($len) { [int]$len } else { 32 }
    $net = (ConvertTo-IPv4Long $addr) -band (Get-IPv4Mask $len)
    if (-not $RangeTable.ContainsKey($len)) { $RangeTable[$len] = @{} }
    $t = $RangeTable[$len]
    if (-not $t.ContainsKey($net)) { $t[$net] = New-Object System.Collections.Generic.List[object] }
    $t[$net].Add(@($Source, $Label, "$(Format-IPv4 $net)/$len"))
}

function Initialize-IpRanges {
    foreach ($e in $JamfIpEntries) {
        $label = "$(Get-JamfServiceLabel $e.Service) $($e.Region)"
        foreach ($p in $e.Ips) { Add-Range 'Jamf' $label $p }
    }
    foreach ($p in $AppleRanges) { Add-Range 'Apple' 'Apple network' $p }
    foreach ($e in $MsEntries) { foreach ($p in $e.Ips) { Add-Range 'Microsoft 365' "#$($e.Id) $($e.Area)" $p } }
    foreach ($e in $GoogleEntries) {
        $label = if ($e.Kind -eq 'services') { 'Google services' } else { "Google Cloud $($e.Scope)" }
        foreach ($p in $e.Prefixes) { Add-Range 'Google' $label $p }
    }
    if ($AzureTagsData) {
        try {
            foreach ($tag in (Get-Field $AzureTagsData 'values')) {
                $name = [string](Get-Field $tag 'name')
                foreach ($p in (Get-Field (Get-Field $tag 'properties') 'addressPrefixes')) {
                    if ($p.IndexOf(':') -lt 0) { Add-Range 'Azure' $name $p }
                }
            }
        } catch { }
    }
}

# Most specific prefix per source; prefer a named service tag over the generic AzureCloud ones
function Find-Ranges([long]$Ip) {
    $best = @{}
    foreach ($len in $RangeTable.Keys) {
        $hits = $RangeTable[$len][$Ip -band (Get-IPv4Mask $len)]
        foreach ($h in $hits) {
            $source, $label, $prefix = $h
            $rank = @($len, [int](-not $label.StartsWith('AzureCloud')), -$label.Length)
            $better = -not $best.ContainsKey($source)
            if (-not $better) {
                $old = $best[$source].Rank
                for ($i = 0; $i -lt 3; $i++) {
                    if ($rank[$i] -ne $old[$i]) { $better = $rank[$i] -gt $old[$i]; break }
                }
            }
            if ($better) { $best[$source] = @{ Rank = $rank; Label = $label; Prefix = $prefix } }
        }
    }
    @($best.Keys | Sort-Object | ForEach-Object { "${_}: $($best[$_].Label) ($($best[$_].Prefix))" }) -join '; '
}

# Private, loopback, CGNAT, documentation and reserved ranges aren't reachable on the internet
$NonGlobalIPv4 = @('0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12',
    '192.0.0.0/24', '192.0.2.0/24', '192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '240.0.0.0/4')

function Test-GlobalIPv4([long]$Ip) {
    foreach ($r in $NonGlobalIPv4) {
        $addr, $len = $r.Split('/')
        $mask = Get-IPv4Mask ([int]$len)
        if (($Ip -band $mask) -eq (ConvertTo-IPv4Long $addr)) { return $false }
    }
    $true
}

function Invoke-IpChecks {
    # Resolve every tested host to its IPv4 addresses, all lookups in flight at once
    $hostNames = @($IpTargets | ForEach-Object { $_.Host } | Select-Object -Unique)
    $lookups = @{}
    foreach ($h in $hostNames) { $lookups[$h] = [System.Net.Dns]::GetHostAddressesAsync($h) }
    $addrs = @{}
    foreach ($h in $hostNames) {
        $task = $lookups[$h]
        try { [void]$task.Wait($TimeoutSec * 1000) } catch { }
        $addrs[$h] = @()
        if ($task.Status -eq 'RanToCompletion') {
            $addrs[$h] = @($task.Result | Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                ForEach-Object { $_.IPAddressToString } | Select-Object -Unique)
        }
    }

    $jobs = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in $IpTargets) {
        foreach ($ip in $addrs[$t.Host]) {
            if ($seen.Add("${ip}:$($t.Port)")) {
                $jobs.Add([PSCustomObject]@{ Category = $t.Category; Host = $t.Host; Ip = $ip; Port = [int]$t.Port; State = 'timeout'; Latency = $null })
            }
        }
    }

    # Connect in batches of 64; poll the batch so each connection gets its own latency
    for ($i = 0; $i -lt $jobs.Count; $i += 64) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $batch = @(foreach ($j in $jobs.GetRange($i, [math]::Min(64, $jobs.Count - $i))) {
            $client = New-Object System.Net.Sockets.TcpClient
            @{ Job = $j; Client = $client; Task = $client.ConnectAsync([System.Net.IPAddress]::Parse($j.Ip), $j.Port) }
        })
        $pending = $batch
        while ($pending.Count -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $pending = @(foreach ($p in $pending) {
                if (-not $p.Task.IsCompleted) { $p; continue }
                if ($p.Task.Status -eq 'RanToCompletion') {
                    $p.Job.State = 'open'; $p.Job.Latency = [math]::Round($sw.Elapsed.TotalMilliseconds)
                } elseif ($p.Task.Exception.InnerException -is [System.Net.Sockets.SocketException] -and
                          $p.Task.Exception.InnerException.SocketErrorCode -eq 'ConnectionRefused') {
                    $p.Job.State = 'refused'
                }
            })
            if ($pending.Count) { Start-Sleep -Milliseconds 10 }
        }
        foreach ($p in $batch) { $p.Client.Close() }
    }

    $script:IpChecked = 0; $script:IpUnlisted = 0
    foreach ($j in $jobs) {
        $x = ConvertTo-IPv4Long $j.Ip
        $ranges = Find-Ranges $x
        if (-not $ranges) { $ranges = 'Not in any published Jamf, Apple, Microsoft, Azure or Google range (allow by hostname)' }
        if (-not (Test-GlobalIPv4 $x)) { $ranges = 'DNS returned a non-public address (DNS filtering or sinkhole?)' }
        if ($ranges.StartsWith('Not in any published')) { $script:IpUnlisted++ }
        switch ($j.State) {
            'open'    { $status = 'PASS'; $note = $ranges }
            'refused' { $status = 'FAIL'; $note = "Connection refused; $ranges" }
            default   { $status = 'FAIL'; $note = "Timed out after ${TimeoutSec}s; $ranges" }
        }
        Add-Result "IP Checks: $($j.Category)" $j.Ip $j.Port 'TCP' "IPv4 address of $($j.Host)" $status $j.Latency $note
        $script:IpChecked++
    }
}

# ── Helpers ────────────────────────────────────────────────────────────────────
function Resolve-TestHost {
    param([string]$HostName)
    try {
        [void][System.Net.Dns]::GetHostEntry($HostName)
        return $true
    } catch {
        return $false
    }
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutSec)
    $client = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if ($task.Wait($TimeoutSec * 1000) -and $client.Connected) {
            $sw.Stop()
            return @{ Success = $true; LatencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds) }
        }
        return @{ Success = $false; LatencyMs = $null }
    } catch {
        return @{ Success = $false; LatencyMs = $null }
    } finally {
        $client.Close()
    }
}

function Test-UdpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutSec)
    $client = New-Object System.Net.Sockets.UdpClient
    try {
        $client.Client.SendTimeout = $TimeoutSec * 1000
        $client.Connect($HostName, $Port)
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("ping")
        [void]$client.Send($bytes, $bytes.Length)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

$Results = New-Object System.Collections.Generic.List[object]
$IpTargets = New-Object System.Collections.Generic.List[object]   # every TCP test whose host resolved (input to the IP checks)
$Pass = 0; $Fail = 0; $Warn = 0

# ── Record a single test result ───────────────────────────────────────────────
function Add-Result {
    param([string]$Category, [string]$HostName, $Port, [string]$Proto, [string]$Desc, [string]$Status, $LatencyMs, [string]$Note)

    $script:Results.Add([PSCustomObject]@{
        Category = $Category; Host = $HostName; Port = $Port; Proto = $Proto
        Description = $Desc; Status = $Status; LatencyMs = $LatencyMs; Note = $Note
    })

    switch ($Status) {
        'PASS' {
            $script:Pass++
            if ($VerboseOutput) { Write-Host ("  [PASS] {0,-45} :{1,-5} ({2})  {3} ms" -f $HostName, $Port, $Proto, $LatencyMs) -ForegroundColor Green }
        }
        'FAIL' {
            $script:Fail++
            if ($VerboseOutput) { Write-Host ("  [FAIL] {0,-45} :{1,-5} ({2})  {3}" -f $HostName, $Port, $Proto, $Note) -ForegroundColor Red }
        }
        'WARN' {
            $script:Warn++
            if ($VerboseOutput) { Write-Host ("  [WARN] {0,-45} :{1,-5} ({2})  {3}" -f $HostName, $Port, $Proto, $Note) -ForegroundColor Yellow }
        }
    }
}

function Invoke-Test {
    param([string]$Category, [string]$HostName, [int]$Port, [string]$Proto = 'TCP', [string]$Desc)

    # Resolve wildcard-prefixed hosts to a concrete name to connect to
    $testHost = Get-WildcardTestHost $HostName $Port
    $isWildcard = $HostName.Contains('*')
    # Only the bare base domain was available to test, so a failure there isn't conclusive
    $baseOnly = $isWildcard -and $testHost -eq (Get-WildcardBase $HostName)

    $status = ''; $latency = $null; $note = ''

    if (-not (Resolve-TestHost -HostName $testHost)) {
        if ($isWildcard) {
            $status = 'WARN'; $note = "Wildcard domain: no resolvable example host (tried $testHost)"
        } else {
            $status = 'FAIL'; $note = 'DNS resolution failed'
        }
    } elseif ($Proto -eq 'UDP') {
        if (Test-UdpPort -HostName $testHost -Port $Port -TimeoutSec $TimeoutSec) {
            $status = 'WARN'; $note = 'UDP: sent, no reply confirmation (expected for UDP)'
        } else {
            $status = 'FAIL'; $note = 'UDP: no response'
        }
    } else {
        # Skip bare base domains standing in for wildcards; they aren't real endpoints
        if (-not $baseOnly) { $script:IpTargets.Add([PSCustomObject]@{ Category = $Category; Host = $testHost; Port = $Port }) }
        $result = Test-TcpPort -HostName $testHost -Port $Port -TimeoutSec $TimeoutSec
        if ($result.Success) {
            $status = 'PASS'; $latency = $result.LatencyMs
        } else {
            $status = 'FAIL'; $note = "TCP connection refused or timed out after ${TimeoutSec}s"
        }
    }
    if ($baseOnly -and $status -eq 'FAIL') {
        $status = 'WARN'; $note = "Wildcard domain: no known example host; base domain $testHost not reachable"
    }
    if ($isWildcard -and -not $note.StartsWith('Wildcard')) {
        $note = "Tested $testHost$(if ($note) { "; $note" })"
    }

    Add-Result $Category $HostName $Port $Proto $Desc $status $latency $note
}

# Static (non -Apple) tests for one category, in list order
function Invoke-Category([string]$Category) {
    foreach ($t in $AllTests) {
        if (-not $t.Apple -and $t.Category -eq $Category) { Invoke-Test $t.Category $t.Host_ $t.Port $t.Proto $t.Desc }
    }
}

function Write-Step([string]$Step, [string]$Title) {
    Write-Host "[$Step] " -ForegroundColor Blue -NoNewline
    Write-Host $Title
}

# Coloured outcome followed by plain text, ending the line
function Write-Outcome([string]$Text, [string]$Color, [string]$Rest = '') {
    Write-Host $Text -ForegroundColor $Color -NoNewline
    Write-Host $Rest
}

# ══════════════════════════════════════════════════════════════════════════════
# RUN TESTS
# ══════════════════════════════════════════════════════════════════════════════
$HostnameLocal = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
$RunDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'

Write-Host "Jamf Network Connectivity Test" -ForegroundColor Blue
Write-Host "Host: $HostnameLocal   Time: $RunDate`n"

Write-Host 'Fetching Jamf published IP list... ' -NoNewline
if (Test-Fetch { Get-JamfIpList }) {
    Write-Outcome "$($JamfIpEntries.Count) entries" Green " (published $(if ($JamfIpDate) { $JamfIpDate } else { 'unknown' }))"
} else {
    Write-Outcome 'unavailable' Yellow ' - dynamic JCDS endpoints will be skipped'
}

Write-Host 'Fetching Google published IP ranges... ' -NoNewline
if (Test-Fetch { Get-GoogleRanges }) {
    Write-Outcome "$($GoogleEntries.Count) range sets" Green " (created $(if ($GoogleDate) { $GoogleDate } else { 'unknown' }))"
} else {
    Write-Outcome 'unavailable' Yellow ' - Google ranges will be left out of the report'
}

Write-Host 'Fetching Microsoft 365 / Intune endpoint list... ' -NoNewline
if (Test-Fetch { Get-MsEndpoints }) {
    Write-Outcome "$($MsEntries.Count) entries" Green " (version $(if ($MsVersion) { $MsVersion } else { 'unknown' }))"
} else {
    Write-Outcome 'unavailable' Yellow
}

Write-Host 'Fetching Azure IP Ranges and Service Tags... ' -NoNewline
if (Test-Fetch { Get-AzureTags }) {
    Write-Outcome 'ok' Green " (ServiceTags_Public_$AzureTagsDate.json)"
} else {
    Write-Outcome 'unavailable' Yellow " - Azure ranges won't be matched"
}

Write-Host 'Fetching Apple network requirements page... ' -NoNewline
if (Test-Fetch { Get-ApplePage }) {
    Write-Outcome 'ok' Green " (ranges: $($AppleRanges -join ' '))`n"
} else {
    Write-Outcome 'unavailable' Yellow " - using built-in range $($AppleRanges -join ' ')`n"
}

# ── 1. Jamf Cloud Services ────────────────────────────────────────────────────
Write-Step '1/11' 'Jamf Cloud Services'
Invoke-Category 'Jamf Cloud Services'

# ── 2. Jamf Cloud Distribution Service (JCDS) ────────────────────────────────
Write-Step '2/11' 'Jamf Cloud Distribution Service (JCDS)'
Invoke-Category 'JCDS'

# JCDS endpoints from the live Jamf IP list
if ($JamfIpEntries.Count -gt 0) {
    foreach ($e in $JamfIpEntries) {
        if ($e.Service -ne 'jamf_cloud_distribution_service') { continue }
        foreach ($fqdn in $e.Fqdns) { Invoke-Test 'JCDS' $fqdn 443 'TCP' "JCDS $($e.Region) (Jamf published list)" }
    }
} else {
    Add-Result 'JCDS' 'engineering.jamf.com' 443 'TCP' 'Jamf published IP list' 'WARN' $null "Could not download $JamfIpListUrl; published JCDS endpoints not tested"
}

# ── 3. Apple Push Notification Service (APNs) — required by Jamf ─────────────
Write-Step '3/11' 'Apple Push Notification Service (APNs)'
Invoke-Category 'Apple Push Notification Service'

# ── 4. Apple Device Enrollment (DEP / ABM) — required by Jamf ────────────────
Write-Step '4/11' 'Apple Device Enrollment'
Invoke-Category 'Apple Device Enrollment'

# ── 5. Jamf Protect ───────────────────────────────────────────────────────────
Write-Step '5/11' 'Jamf Protect'
Invoke-Category 'Jamf Protect'

# ── 6. Jamf Remote Assist ─────────────────────────────────────────────────────
Write-Step '6/11' 'Jamf Remote Assist'
Invoke-Category 'Jamf Remote Assist'

# ── 7. Jamf Executive Threat Protection ──────────────────────────────────────
Write-Step '7/11' 'Jamf Executive Threat Protection'
Invoke-Category 'Jamf Executive Threat Protection'

# ── 8. Microsoft (Intune / Entra ID) ─────────────────────────────────────────
Write-Step '8/11' 'Microsoft (Intune / Entra ID)'
Invoke-Category 'Microsoft'

if ($Microsoft) {
    if ($MsEntries.Count -gt 0) {
        Invoke-MsLive
    } else {
        Write-Host '      Microsoft 365 endpoint list unavailable' -ForegroundColor Yellow
        Add-Result 'Microsoft' 'endpoints.office.com' 443 'TCP' 'Microsoft 365 endpoint list' 'WARN' $null 'Could not download the Microsoft 365 endpoint list; full Microsoft tests skipped'
    }
} else {
    Write-Host '      Full Microsoft 365 / Intune endpoint tests skipped - re-run with -Microsoft to include' -ForegroundColor Yellow
}

# ── 9. Jamf Connect & Additional Jamf Services ────────────────────────────────
Write-Step '9/11' 'Jamf Connect & Additional Services'
Invoke-Category 'Jamf Additional Services'

# ── 10. Optional: Google Workspace, Android Enterprise and Chrome Enterprise ───
if ($Google) {
    Write-Step '10/11' 'Google (-Google)'
    foreach ($section in 'Google Workspace', 'Google Android Enterprise', 'Google Chrome Enterprise') {
        Write-Host "      $($section -replace '^Google ', '')"
        Invoke-Category $section
    }
} else {
    Write-Host '[10/11] Google service tests skipped - re-run with -Google to include' -ForegroundColor Yellow
}

# ── 11. Optional: Full Apple network requirements ─────────────────────────────
if ($Apple) {
    Write-Step '11/11' 'Apple Network Requirements (-Apple)'
    Write-Host "      Reading host tables from $AppleReqsUrl... " -NoNewline
    if (Test-Fetch { Get-AppleRequirements }) {
        Write-Outcome "$($AppleEntries.Count) host entries" Green
        Invoke-AppleLive
    } else {
        Write-Outcome 'unavailable' Yellow ' - using built-in list'
        Add-Result 'Apple Network Requirements' 'support.apple.com' 443 'TCP' 'Apple network requirements page' 'WARN' $null "Could not download or parse $AppleReqsUrl; built-in host list used"
        Invoke-AppleBuiltin
    }
} else {
    Write-Host '[11/11] Apple service tests skipped - re-run with -Apple to include' -ForegroundColor Yellow
}

# ── IP address checks ─────────────────────────────────────────────────────────
Write-Step 'IP' 'IP address checks (every IPv4 address of each tested host, matched to published ranges)'
if ($IpTargets.Count -gt 0) {
    Initialize-IpRanges
    Invoke-IpChecks
    Write-Host ("      {0} address/port checks; {1} addresses aren't in any published range (allow those by hostname)" -f $IpChecked, $IpUnlisted)
}

# ── Summary ───────────────────────────────────────────────────────────────────
$Total = $Pass + $Fail + $Warn
# Box-drawing rule built from its code point: 5.1 reads this file as ANSI, where the raw character breaks the string
$Rule = [string][char]0x2500 * 42
Write-Host "`n$Rule"
Write-Host ("Total: {0}   Pass: {1}   Fail: {2}   Warn: {3}" -f $Total, $Pass, $Fail, $Warn)
Write-Host "$Rule`n"

# ══════════════════════════════════════════════════════════════════════════════
# HTML REPORT GENERATION
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "Generating report: $OutputFile"

$PassPct = 0
if ($Total -gt 0) { $PassPct = [math]::Round(($Pass * 100) / $Total) }

$BarColor = '#22c55e'
if ($Fail -gt 0) { $BarColor = '#ef4444' }
elseif ($Warn -gt 0) { $BarColor = '#f59e0b' }

function HtmlEncode([string]$s) {
    if ($null -eq $s) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

# ── Build one collapsible section per category ───────────────────────────────
$SectionsHtml = New-Object System.Text.StringBuilder
$SecRows = New-Object System.Text.StringBuilder
$SecCat = $null; $SecCounts = @{ PASS = 0; FAIL = 0; WARN = 0 }

# Close the current category as a <details> block (collapsed), with its counts in the summary line
function Close-Section {
    if ($SecRows.Length -eq 0) { return }
    $counts = -join @(foreach ($st in 'PASS', 'FAIL', 'WARN') {
        if ($SecCounts[$st] -gt 0) { "<span class=`"badge $($st.ToLower())`">$($SecCounts[$st]) $st</span>" }
    })
    [void]$SectionsHtml.Append(@"
<details class="table-wrap ip-list section">
  <summary>$(HtmlEncode $SecCat) <span class="sec-counts">$counts</span></summary>
  <table>
    <thead>
      <tr><th>Host</th><th>Port</th><th>Proto</th><th>Description</th><th>Status</th><th style="text-align:right">Latency</th><th>Notes</th></tr>
    </thead>
    <tbody>
$($SecRows.ToString())
    </tbody>
  </table>
</details>

"@)
    [void]$SecRows.Clear()
    foreach ($st in 'PASS', 'FAIL', 'WARN') { $SecCounts[$st] = 0 }
}

foreach ($r in $Results) {
    # New category: close the previous section
    if ($r.Category -cne $SecCat) {
        Close-Section
        $SecCat = $r.Category
    }
    if ($SecCounts.ContainsKey($r.Status)) { $SecCounts[$r.Status]++ }

    $badge = switch ($r.Status) {
        'PASS' { '<span class="badge pass">PASS</span>' }
        'FAIL' { '<span class="badge fail">FAIL</span>' }
        'WARN' { '<span class="badge warn">WARN</span>' }
        default { "<span class=`"badge`">$($r.Status)</span>" }
    }

    if ($null -eq $r.LatencyMs) {
        $latCell = '<td class="latency">&mdash;</td>'
    } else {
        $latCell = "<td class=`"latency`">$($r.LatencyMs) ms</td>"
    }

    $noteCell = "<td class=`"note`">$(HtmlEncode $r.Note)</td>"
    $statusLc = $r.Status.ToLower()

    [void]$SecRows.Append("<tr class=`"row-$statusLc`">
        <td class=`"host`"><code>$(HtmlEncode $r.Host)</code></td>
        <td class=`"port`">$($r.Port)</td>
        <td class=`"proto`">$($r.Proto)</td>
        <td>$(HtmlEncode $r.Description)</td>
        <td>$badge</td>
        $latCell
        $noteCell
    </tr>")
}
Close-Section

$RecsHtml = ''
if ($Fail -gt 0) {
    $appleLink = ''
    $googleRec = ''
    if ($Google) { $googleRec = '<li>For Google, allow TCP 443 and 80 to <code>*.google.com</code>, <code>*.googleapis.com</code> and <code>*.gstatic.com</code>; Android Enterprise also needs TCP <strong>5228-5230</strong> (Firebase Cloud Messaging) and Google Meet needs UDP <strong>3478, 19302-19309</strong>. Full lists: <a href="https://knowledge.workspace.google.com/admin/getting-started/set-up-a-google-workspace-host-name-allowlist">Google Workspace</a> &nbsp;|&nbsp; <a href="https://support.google.com/work/android/answer/10513641">Android Enterprise</a> &nbsp;|&nbsp; <a href="https://support.google.com/chrome/a/answer/6334001">Chrome Enterprise</a></li>' }
    if ($Apple) { $appleLink = '&nbsp;|&nbsp;<a href="https://support.apple.com/en-us/101555">Apple Network Requirements</a> &nbsp;|&nbsp;<a href="https://support.apple.com/en-us/103229">Apple TCP/UDP Ports</a>' }
    $RecsHtml = @"
<details class="recs">
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
      $googleRec
      <li>Reference: <a href="https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro">Jamf Pro Network Ports</a> &nbsp;|&nbsp;
          <a href="https://learn.jamf.com/r/en-US/jamf-ip-address-list/Permitting_InboundOutbound_Traffic_with_Jamf">Jamf IP Address List</a>
          $appleLink
      </li>
    </ul>
  </details>
"@
}

# ── Jamf published IP ranges (reference for firewall allow-lists) ────────────
function Format-Addrs($List) {
    -join @(foreach ($a in $List) { "<code>$(HtmlEncode $a)</code> " })
}

$IpHtml = ''
if ($JamfIpEntries.Count -gt 0) {
    $ipRows = New-Object System.Text.StringBuilder
    foreach ($e in $JamfIpEntries) {
        if ($e.Traffic -eq 'outbound') {
            $dir = 'Jamf &rarr; your network <small>(allow as source)</small>'
        } else {
            $dir = 'Your devices &rarr; Jamf <small>(allow as destination)</small>'
        }
        [void]$ipRows.Append("<tr>
        <td>$(HtmlEncode (Get-JamfServiceLabel $e.Service))</td>
        <td>$dir</td>
        <td class=`"proto`">$(HtmlEncode $e.Provider)</td>
        <td><code>$(HtmlEncode $e.Region)</code></td>
        <td class=`"addrs`">$(Format-Addrs ($e.Ips + $e.Fqdns))</td>
    </tr>")
    }
    $IpHtml = @"
<details class="table-wrap ip-list">
  <summary>Jamf Published IP Ranges &amp; Endpoints &mdash; $($JamfIpEntries.Count) entries, published $(if ($JamfIpDate) { HtmlEncode $JamfIpDate } else { 'unknown' })</summary>
  <table>
    <thead>
      <tr><th>Service</th><th>Direction</th><th>Provider</th><th>Region</th><th>IP Prefixes / FQDNs</th></tr>
    </thead>
    <tbody>
$($ipRows.ToString())
    </tbody>
  </table>
  <p class="ip-src">Fetched live from <a href="$JamfIpListUrl">$JamfIpListUrl</a></p>
</details>
"@
}

# ── Microsoft published IP ranges (reference for firewall allow-lists) ───────
$MsIpHtml = ''
if ($MsEntries.Count -gt 0) {
    $msRows = New-Object System.Text.StringBuilder
    foreach ($e in $MsEntries) {
        if ($e.Ips.Count -eq 0) { continue }
        $ports = @($(if ($e.Tcp) { "TCP $($e.Tcp)" }), $(if ($e.Udp) { "UDP $($e.Udp)" }) | Where-Object { $_ }) -join ' '
        [void]$msRows.Append("<tr>
        <td>#$(HtmlEncode $e.Id)</td>
        <td>$(HtmlEncode $e.Area)</td>
        <td>$(HtmlEncode $e.Category)$(if ($e.Required) { ' &middot; required' })</td>
        <td class=`"port`">$(HtmlEncode $ports)</td>
        <td class=`"addrs`">$(Format-Addrs $e.Ips)</td>
    </tr>")
    }
    $MsIpHtml = @"
<details class="table-wrap ip-list">
  <summary>Microsoft 365 / Intune Published IP Ranges &mdash; version $(if ($MsVersion) { HtmlEncode $MsVersion } else { 'unknown' })</summary>
  <table>
    <thead>
      <tr><th>Endpoint</th><th>Service Area</th><th>Category</th><th>Ports</th><th>IP Ranges</th></tr>
    </thead>
    <tbody>
$($msRows.ToString())
    </tbody>
  </table>
  <p class="ip-src">Fetched live from <a href="https://endpoints.office.com/endpoints/worldwide">endpoints.office.com</a>.
    Azure-hosted services publish their ranges separately (weekly, IP ranges only) in
    <a href="$AzureTagsUrl">Azure IP Ranges and Service Tags &ndash; Public Cloud</a>.</p>
</details>
"@
}

# ── Google published IP ranges (reference for firewall allow-lists) ──────────
$GoogleHtml = ''
if ($GoogleEntries.Count -gt 0) {
    $gRows = New-Object System.Text.StringBuilder
    foreach ($e in $GoogleEntries) {
        if ($e.Kind -eq 'services') {
            $label = 'Google services <small>(goog.json minus cloud.json)</small>'
        } else {
            $label = 'Google Cloud <small>(customer ranges)</small>'
        }
        [void]$gRows.Append("<tr>
        <td>$label</td>
        <td><code>$(HtmlEncode $e.Scope)</code></td>
        <td class=`"addrs`">$(Format-Addrs $e.Prefixes)</td>
    </tr>")
    }
    $GoogleHtml = @"
<details class="table-wrap ip-list">
  <summary>Google Published IP Ranges &mdash; created $(if ($GoogleDate) { HtmlEncode $GoogleDate } else { 'unknown' })</summary>
  <table>
    <thead>
      <tr><th>Range Set</th><th>Scope</th><th>IP Prefixes</th></tr>
    </thead>
    <tbody>
$($gRows.ToString())
    </tbody>
  </table>
  <p class="ip-src">Fetched live from <a href="$GoogRangesUrl">goog.json</a> and
    <a href="$GCloudRangesUrl">cloud.json</a>. Allow-list the Google services ranges for Google APIs and Workspace;
    the Google Cloud ranges are used by any Google Cloud customer.</p>
</details>
"@
}

$MetaExtra = ''
if ($Apple) { $MetaExtra += " &nbsp;&middot;&nbsp; Apple hosts: $AppleSource" }
if ($MsVersion) { $MetaExtra += " &nbsp;&middot;&nbsp; Microsoft list: v$(HtmlEncode $MsVersion)" }

$AppleBadge = ''
if ($Apple) { $AppleBadge = '<span class="apple-badge">+ Apple Tests</span>' }
if ($Google) { $AppleBadge += '<span class="apple-badge">+ Google Tests</span>' }

$Html = @"
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
      background: $BarColor;
      width: ${PassPct}%;
      transition: width 1s ease;
    }

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


    .row-pass:hover { background: #f0fdf4; }
    .row-fail { background: #fff5f5; }
    .row-fail:hover { background: #fee2e2; }
    .row-warn { background: #fffbeb; }
    .row-warn:hover { background: #fef3c7; }

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

    .host code {
      font-family: "SF Mono", "Fira Code", Menlo, monospace;
      font-size: 0.82rem;
      color: #1a1a2e;
    }
    .port { font-family: monospace; color: #6366f1; font-weight: 600; }
    .proto { font-size: 0.75rem; color: #6b7280; font-weight: 600; text-transform: uppercase; }
    .latency { font-family: monospace; color: #6b7280; text-align: right; }
    .note { color: #6b7280; font-size: 0.78rem; font-style: italic; }

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
    <h1>Network Test ${AppleBadge}</h1>
    <div class="meta">Host: ${HostnameLocal} &nbsp;&middot;&nbsp; ${RunDate} &nbsp;&middot;&nbsp; Timeout: ${TimeoutSec}s per test${MetaExtra}</div>
  </div>
</header>

<div class="summary">
  <div class="card total"><div class="num">${Total}</div><div class="lbl">Total Tests</div></div>
  <div class="card pass"><div class="num">${Pass}</div><div class="lbl">Pass</div></div>
  <div class="card fail"><div class="num">${Fail}</div><div class="lbl">Fail</div></div>
  <div class="card warn"><div class="num">${Warn}</div><div class="lbl">Warn</div></div>
</div>

<div class="progress-wrap">
  <div class="progress-label">
    <span>Connectivity Score</span>
    <span>${PassPct}%</span>
  </div>
  <div class="progress-bar-bg">
    <div class="progress-bar-fill"></div>
  </div>
</div>

$RecsHtml

<div class="section-tools">
  <button type="button" onclick="toggleAll(true)">Expand all</button>
  <button type="button" onclick="toggleAll(false)">Collapse all</button>
</div>

$($SectionsHtml.ToString())

$IpHtml

$MsIpHtml

$GoogleHtml

<footer>
  Generated by jamf_network_test.ps1 &nbsp;&middot;&nbsp;
  <a href="https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro">Jamf Network Ports Docs</a> &nbsp;&middot;&nbsp;
  <a href="https://support.apple.com/en-us/101555">Apple Network Requirements</a> &nbsp;&middot;&nbsp;
  <a href="https://support.apple.com/en-us/103229">Apple TCP/UDP Ports</a> &nbsp;&middot;&nbsp;
  <a href="https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges">Microsoft 365 Endpoints</a> &nbsp;&middot;&nbsp;
  <a href="https://www.microsoft.com/en-us/download/details.aspx?id=56519">Azure IP Ranges</a> &nbsp;&middot;&nbsp;
  <a href="https://www.gstatic.com/ipranges/goog.json">Google IP Ranges</a>
</footer>

<script>
  // Sections start collapsed; expand everything for printing so nothing is hidden on paper
  function toggleAll(open) { document.querySelectorAll('details').forEach(function (d) { d.open = open; }); }
  window.addEventListener('beforeprint', function () { toggleAll(true); });
</script>

</body>
</html>
"@

Set-Content -Path $OutputFile -Value $Html -Encoding UTF8

Write-Host "Done! Report saved to: $OutputFile" -ForegroundColor Green

try {
    Invoke-Item $OutputFile
} catch {
    # No default browser association available - ignore
}
