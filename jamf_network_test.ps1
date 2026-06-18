<#
jamf_network_test.ps1
Tests network connectivity for Jamf Pro and (optionally) Apple services on Windows,
then generates a self-contained HTML report. Windows counterpart of jamf_network_test.sh.

Usage:
  .\jamf_network_test.ps1 [-Apple] [-OutputFile <path>] [-TimeoutSec <int>] [-VerboseOutput]

-Apple          Also run Apple platform network requirement tests
-OutputFile     Path for the HTML report (default: jamf_network_report_<timestamp>.html)
-TimeoutSec     Per-connection timeout in seconds (default: 5)
-VerboseOutput  Print each result to the console as it runs
#>

param(
    [switch]$Apple,
    [string]$OutputFile = "jamf_network_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html",
    [int]$TimeoutSec = 5,
    [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'

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
    [PSCustomObject]@{ Apple=$true; Category='iCloud Services'; Host_='mask-api.icloud.com'; Port=443; Proto='UDP'; Desc='iCloud Private Relay API (UDP)' }
)

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
$Pass = 0; $Fail = 0; $Warn = 0

function Invoke-Test {
    param($TestDef)

    $category = $TestDef.Category
    $hostName = $TestDef.Host_
    $port = $TestDef.Port
    $proto = $TestDef.Proto
    $desc = $TestDef.Desc

    $status = ''; $latency = $null; $note = ''

    if (-not (Resolve-TestHost -HostName $hostName)) {
        $status = 'FAIL'; $note = 'DNS resolution failed'
    } elseif ($proto -eq 'UDP') {
        if (Test-UdpPort -HostName $hostName -Port $port -TimeoutSec $TimeoutSec) {
            $status = 'WARN'; $note = 'UDP: sent, no reply confirmation (expected for UDP)'
        } else {
            $status = 'FAIL'; $note = 'UDP: no response'
        }
    } else {
        $result = Test-TcpPort -HostName $hostName -Port $port -TimeoutSec $TimeoutSec
        if ($result.Success) {
            $status = 'PASS'; $latency = $result.LatencyMs
        } else {
            $status = 'FAIL'; $note = "TCP connection refused or timed out after ${TimeoutSec}s"
        }
    }

    $script:Results.Add([PSCustomObject]@{
        Category = $category; Host = $hostName; Port = $port; Proto = $proto
        Description = $desc; Status = $status; LatencyMs = $latency; Note = $note
    })

    switch ($status) {
        'PASS' {
            $script:Pass++
            if ($VerboseOutput) { Write-Host ("  [PASS] {0,-45} :{1,-5} ({2})  {3} ms" -f $hostName, $port, $proto, $latency) -ForegroundColor Green }
        }
        'FAIL' {
            $script:Fail++
            if ($VerboseOutput) { Write-Host ("  [FAIL] {0,-45} :{1,-5} ({2})  {3}" -f $hostName, $port, $proto, $note) -ForegroundColor Red }
        }
        'WARN' {
            $script:Warn++
            if ($VerboseOutput) { Write-Host ("  [WARN] {0,-45} :{1,-5} ({2})  {3}" -f $hostName, $port, $proto, $note) -ForegroundColor Yellow }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# RUN TESTS
# ══════════════════════════════════════════════════════════════════════════════
$HostnameLocal = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
$RunDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'

Write-Host "Jamf Network Connectivity Test" -ForegroundColor Blue
Write-Host "Host: $HostnameLocal   Time: $RunDate`n"

$TestsToRun = $AllTests | Where-Object { -not $_.Apple -or $Apple }

Write-Host "[1/2] Jamf Cloud + Apple core services" -ForegroundColor Blue
foreach ($t in ($TestsToRun | Where-Object { -not $_.Apple })) { Invoke-Test -TestDef $t }

if ($Apple) {
    Write-Host "[2/2] Apple Network Requirements (-Apple)" -ForegroundColor Blue
    foreach ($t in ($TestsToRun | Where-Object { $_.Apple })) { Invoke-Test -TestDef $t }
} else {
    Write-Host "[2/2] Apple service tests skipped - re-run with -Apple to include" -ForegroundColor Yellow
}

# ── Summary ───────────────────────────────────────────────────────────────────
$Total = $Pass + $Fail + $Warn
Write-Host "`n──────────────────────────────────────────"
Write-Host ("Total: {0}   Pass: {1}   Fail: {2}   Warn: {3}" -f $Total, $Pass, $Fail, $Warn)
Write-Host "──────────────────────────────────────────`n"

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

$RowsHtml = New-Object System.Text.StringBuilder
$PrevCat = ''
foreach ($r in $Results) {
    if ($r.Category -ne $PrevCat) {
        [void]$RowsHtml.Append("<tr class=`"cat-header`"><td colspan=`"7`">$(HtmlEncode $r.Category)</td></tr>")
        $PrevCat = $r.Category
    }

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

    [void]$RowsHtml.Append("<tr class=`"row-$statusLc`">
        <td class=`"host`"><code>$(HtmlEncode $r.Host)</code></td>
        <td class=`"port`">$($r.Port)</td>
        <td class=`"proto`">$($r.Proto)</td>
        <td>$(HtmlEncode $r.Description)</td>
        <td>$badge</td>
        $latCell
        $noteCell
    </tr>")
}

$RecsHtml = ''
if ($Fail -gt 0) {
    $appleLink = ''
    if ($Apple) { $appleLink = '&nbsp;|&nbsp;<a href="https://support.apple.com/en-gb/101555">Apple Network Requirements</a>' }
    $RecsHtml = @"
<section class="recs">
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
          $appleLink
      </li>
    </ul>
  </section>
"@
}

$AppleBadge = ''
if ($Apple) { $AppleBadge = '<span class="apple-badge">+ Apple Tests</span>' }

$Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Jamf Network Test Report &mdash; $RunDate</title>
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
    <h1>Jamf Network Test Report ${AppleBadge}</h1>
    <div class="meta">Host: ${HostnameLocal} &nbsp;&middot;&nbsp; ${RunDate} &nbsp;&middot;&nbsp; Timeout: ${TimeoutSec}s per test</div>
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
$($RowsHtml.ToString())
    </tbody>
  </table>
</div>

<footer>
  Generated by jamf_network_test.ps1 &nbsp;&middot;&nbsp;
  <a href="https://learn.jamf.com/r/en-US/technical-articles/Network_Ports_Used_by_Jamf_Pro">Jamf Network Ports Docs</a> &nbsp;&middot;&nbsp;
  <a href="https://support.apple.com/en-gb/101555">Apple Network Requirements</a>
</footer>

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
