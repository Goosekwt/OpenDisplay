[CmdletBinding()]
param(
    [string]$CertificateThumbprint,
    [string]$SignToolPath,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $projectRoot 'dist/windows'
& dotnet publish (Join-Path $PSScriptRoot 'OpenDisplay.Host/OpenDisplay.Host.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $destination --nologo
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
$application = Join-Path $destination 'OpenDisplay.Host.exe'
if (-not $CertificateThumbprint) {
    Write-Output "Created unsigned development build: $application"
    Write-Output 'Smart App Control can block this build. Supply a trusted code-signing identity before running on a PC that requires one.'
    exit 0
}
if ($CertificateThumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'Supply a certificate thumbprint of 40 hexadecimal characters.' }
$certificate = Get-Item -LiteralPath (Join-Path 'Cert:/CurrentUser/My' $CertificateThumbprint)
if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date)) { throw 'The selected certificate needs a private key and must not be expired.' }
if (-not $SignToolPath) { $SignToolPath = (Get-Command signtool.exe -ErrorAction Stop).Source }
if (-not (Test-Path -LiteralPath $SignToolPath)) { throw 'SignTool was not found. Install the Windows SDK signing tools.' }
& $SignToolPath sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $application
if ($LASTEXITCODE -ne 0) { throw 'Code signing failed.' }
& $SignToolPath verify /pa /all /v $application
if ($LASTEXITCODE -ne 0) { throw 'Signature verification failed.' }
Write-Output "Signed and verified: $application. Runtime testing under the target Windows policy is still required."
