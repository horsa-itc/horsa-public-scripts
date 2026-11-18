
# Horsa - Diagnostica registrazione Microsoft Entra ID
# Versione 1.0

$ErrorActionPreference = "Continue"

$Desktop = [Environment]::GetFolderPath("Desktop")
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportPath = Join-Path $Desktop "Horsa-Diagnostica-$Timestamp.txt"

$Report = New-Object System.Collections.Generic.List[string]

function Add-Report {
    param([string]$Text)
    $Report.Add($Text)
}

Add-Report "HORSA - DIAGNOSTICA DISPOSITIVO"
Add-Report "Data: $(Get-Date)"
Add-Report "Computer: $env:COMPUTERNAME"
Add-Report "Utente: $env:USERDOMAIN\$env:USERNAME"
Add-Report ""

# Informazioni Windows
Add-Report "=== SISTEMA OPERATIVO ==="

$OS = Get-CimInstance Win32_OperatingSystem

Add-Report "Windows: $($OS.Caption)"
Add-Report "Versione: $($OS.Version)"
Add-Report "Build: $($OS.BuildNumber)"
Add-Report ""

# Stato dominio
Add-Report "=== STATO DOMINIO ==="

$Computer = Get-CimInstance Win32_ComputerSystem

Add-Report "DomainJoined: $($Computer.PartOfDomain)"
Add-Report "Domain: $($Computer.Domain)"
Add-Report ""

# Stato Microsoft Entra
Add-Report "=== MICROSOFT ENTRA ID ==="

$DSReg = dsregcmd /status 2>&1 | Out-String

$Fields = @(
    "AzureAdJoined",
    "EnterpriseJoined",
    "DomainJoined",
    "DomainName",
    "DeviceId",
    "TenantId",
    "DeviceAuthStatus",
    "WorkplaceJoined",
    "WamDefaultSet",
    "AzureAdPrt"
)

foreach ($Field in $Fields) {
    $Match = [regex]::Match(
        $DSReg,
        "(?m)^\s*$Field\s*:\s*(.*?)\s*$"
    )

    if ($Match.Success) {
        Add-Report "$Field : $($Match.Groups[1].Value)"
    }
    else {
        Add-Report "$Field : Non disponibile"
    }
}

Add-Report ""
Add-Report "=== DIAGNOSTICA COMPLETA DSREGCMD ==="
Add-Report $DSReg

# Salvataggio
$Report | Out-File -FilePath $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "Diagnostica completata." -ForegroundColor Green
Write-Host ""
Write-Host "Report salvato sul Desktop:"
Write-Host $ReportPath
Write-Host ""
Write-Host "Invia il file al supporto IT Horsa."
Write-Host ""

Start-Process notepad.exe -ArgumentList "`"$ReportPath`""

Read-Host "Premi INVIO per chiudere"
