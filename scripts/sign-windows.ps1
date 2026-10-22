param(
    [Parameter(Mandatory)][string]$File,
    [Parameter(Mandatory)][string]$CertificateThumbprint,
    [Parameter(Mandatory)][string]$SignTool,
    [Parameter(Mandatory)][uri]$TimestampUrl
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $File) -or !(Test-Path -LiteralPath $SignTool)) { throw 'File or Windows SDK signtool is missing.' }
if ($TimestampUrl.Scheme -notin @('https', 'http')) { throw 'Use the timestamp service provided by the certificate issuer.' }
$certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint"
if (!$certificate.HasPrivateKey) { throw 'Certificate has no available private key.' }
if (!($certificate.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.3')) { throw 'A code signing certificate is required.' }
$chain = New-Object Security.Cryptography.X509Certificates.X509Chain
try {
    if (!$chain.Build($certificate)) { throw 'Certificate does not have a valid trusted chain. Self-signed certificates do not establish publisher trust.' }
} finally { $chain.Dispose() }
& $SignTool sign /sha1 $certificate.Thumbprint /s My /fd SHA256 /tr $TimestampUrl.AbsoluteUri /td SHA256 $File
if ($LASTEXITCODE -ne 0) { throw 'Windows signing failed.' }
& $SignTool verify /pa /all /v $File
if ($LASTEXITCODE -ne 0) { throw 'Windows signature verification failed.' }
if ((Get-AuthenticodeSignature -LiteralPath $File).Status -ne 'Valid') { throw 'Authenticode signature is not valid.' }
