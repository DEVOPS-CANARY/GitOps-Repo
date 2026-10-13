# Seals a GHCR pull secret for one environment and writes it to the env folder.
# The token is read without echoing and never touches disk unencrypted.
#
# Usage (from the repo root, in your own PowerShell window):
#   .\scripts\seal-ghcr-pull.ps1 -Env uat
#
# Token: a GitHub *classic* personal access token with ONLY the read:packages
# scope (GHCR does not accept fine-grained tokens for pulls).
param(
    [Parameter(Mandatory = $true)][string]$Env,
    [string]$User = "princebabou",
    [string]$Kubeseal = "$HOME\bin\kubeseal.exe"
)
$ErrorActionPreference = "Stop"

$secure = Read-Host "GHCR token (read:packages only)" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $out = "apps\logistics\envs\$Env\ghcr-pull.sealed.yaml"
    $sealed = kubectl create secret docker-registry ghcr-pull -n $Env `
        --docker-server=ghcr.io --docker-username=$User --docker-password=$token `
        --dry-run=client -o yaml |
        & $Kubeseal --cert bootstrap\sealed-secrets\pub-cert.pem --format yaml
    if ($LASTEXITCODE -ne 0) { throw "kubeseal failed" }
    # ASCII, no BOM: the content is YAML + base64 ciphertext.
    $sealed | Set-Content -Encoding ascii $out
    Write-Host "Wrote $out"
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    Remove-Variable token -ErrorAction SilentlyContinue
}
