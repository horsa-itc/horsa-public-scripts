#!/usr/bin/env pwsh
<#
.VERSION
    2026-11-18.5 - FIX AUTOMATICO: se il PC e' hybrid joined, ha il PRT, non e' iscritto a
                   Intune e non ha MDM concorrenti, esegue deviceenroller.exe
                   /c /AutoEnrollMDM e verifica l'esito (fino a 3 minuti). Disattivabile
                   con -SoloDiagnosi. -Forza ora fa solo gpupdate prima dei controlli.
    2026-11-18.4 - il log va sul Desktop dell'utente collegato al PC anche quando
                   PowerShell e' elevato con un altro account amministrativo; tolti
                   i riferimenti al caso d'origine (script generico).
    2026-11-18.3 - il log si crea di default sul Desktop (prima C:\Temp\intune-diag).
    2026-11-18.2 - non segnala come MDM concorrenti le iscrizioni interne Microsoft
                   ("Microsoft Device Management", WMI_Bridge_SCCM_Server); ordine
                   dell'ESITO corretto (KO, ATTENZIONE, OK, INFO).
    2026-11-18.1 - prima versione.

.SYNOPSIS
    Diagnostica perche' un PC Windows hybrid joined (dominio horsa.local + Entra ID)
    non risulta iscritto a Intune e, se le condizioni lo permettono, lo iscrive
    (fix automatico con deviceenroller). Con -SoloDiagnosi non modifica nulla.

.DESCRIPTION
    Raccoglie in un unico log tutti i controlli della catena
    "GPO MDM_AutoEnroll -> attivita' pianificata -> iscrizione MDM -> Intune":

      1. Sistema, utente, privilegi
      2. Join: dsregcmd (AzureAdJoined, DomainJoined, PRT, OnPremTgt, DeviceAuthStatus)
      3. Raggiungibilita' del dominio: domain controller, canale sicuro, VPN
      4. Criteri di gruppo (gpresult XML, scope computer): MDM_AutoEnroll applicata,
         filtrata o assente; ultima elaborazione; errori GroupPolicy recenti
      5. Chiave di policy MDM nel registro (AutoEnrollMDM, tipo di credenziali)
      6. Iscrizioni MDM presenti (Intune "MS DM Server" o altri MDM in conflitto)
      7. Attivita' pianificate EnterpriseMgmt (auto-enrollment e sync Intune)
      8. Log DeviceManagement-Enterprise-Diagnostics-Provider: eventi 75 (ok) / 76 (ko)
         con decodifica indicativa dei codici d'errore piu' comuni
      9. Altri agenti di gestione (ConfigMgr, ManageEngine Desktop Central, Meraki)
     10. Connettivita' verso gli endpoint Microsoft di registrazione
     11. FIX AUTOMATICO: deviceenroller.exe /c /AutoEnrollMDM se il PC non e'
         iscritto ma ha i requisiti (hybrid joined, PRT, nessun altro MDM, admin);
         poi verifica iscrizione ed eventi 75/76 per al massimo 3 minuti
     12. ESITO: diagnosi sintetica e prossimo passo

    Modifiche al PC: solo il fix automatico (sezione 11) e, con -Forza, un
    `gpupdate /target:computer /force` prima dei controlli. Con -SoloDiagnosi lo
    script e' in sola lettura.

    Va lanciato sul PC dell'utente, in PowerShell COME AMMINISTRATORE, possibilmente
    con la VPN collegata (senza domain controller raggiungibile le GPO non si
    aggiornano). Nessun dato viene inviato all'esterno: il log resta sul PC.

.PARAMETER OutDir
    Cartella del log. Default: il Desktop dell'utente collegato al PC (sessione
    console), anche se PowerShell e' stato elevato con un altro account e anche
    se il Desktop e' reindirizzato su OneDrive. Se non si riesce a determinarlo,
    il Desktop dell'account che esegue lo script.

.PARAMETER Giorni
    Quanti giorni di eventi analizzare. Default 30.

.PARAMETER Forza
    Esegue gpupdate /target:computer /force prima dei controlli (utile se la GPO
    di auto-enrollment non e' ancora arrivata). Richiede il domain controller
    raggiungibile (VPN).

.PARAMETER SoloDiagnosi
    Non esegue il fix automatico: solo controlli, nessuna modifica.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\horsa-intune-diagnostic3.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\horsa-intune-diagnostic3.ps1 -Forza

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\horsa-intune-diagnostic3.ps1 -SoloDiagnosi

.NOTES
    Output: <Desktop>\<HOSTNAME>-intune-<yyyyMMdd-HHmm>.log (prima riga = versione).
    Compatibile Windows PowerShell 5.1. Solo caratteri ASCII.
    Repo: https://github.com/horsa-itc/horsa-public-scripts
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [int]$Giorni = 30,
    [switch]$Forza,
    [switch]$SoloDiagnosi
)

$ScriptVersion = '2026-11-18.5'
$GpoNome       = 'MDM_AutoEnroll'
$Dominio       = 'horsa.local'
$ErrorActionPreference = 'Continue'

# Desktop dell'utente collegato al PC (non dell'account usato per l'elevazione)
function Get-InteractiveDesktop {
    try {
        $u = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        if (-not $u) { return $null }
        $sid = (New-Object System.Security.Principal.NTAccount($u)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $prof = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop).LocalPath
        if (-not $prof) { return $null }
        $desk = $null
        $key = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        $raw = (Get-ItemProperty -Path $key -Name Desktop -ErrorAction SilentlyContinue).Desktop
        if ($raw) { $desk = $raw -replace '%USERPROFILE%', $prof }
        if (-not $desk -or $desk -match '%') { $desk = Join-Path $prof 'Desktop' }
        if (Test-Path $desk) { return $desk }
    } catch { }
    return $null
}
if (-not $OutDir) {
    $OutDir = Get-InteractiveDesktop
    if (-not $OutDir) { $OutDir = [Environment]::GetFolderPath('Desktop') }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LogFile = Join-Path $OutDir ("{0}-intune-{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
$Esito = New-Object System.Collections.Generic.List[string]
# Iscrizioni interne di Windows/Microsoft che NON sono un MDM concorrente
$ProviderMicrosoft = @('MS DM Server', 'Microsoft Device Management', 'WMI_Bridge_Server', 'WMI_Bridge_SCCM_Server', 'SCCM')

function Out-Log([string]$Testo = '') {
    Write-Host $Testo
    Add-Content -Path $LogFile -Value $Testo -Encoding UTF8
}
function Out-Section([string]$Titolo) {
    Out-Log ''
    Out-Log ('=' * 78)
    Out-Log "== $Titolo"
    Out-Log ('=' * 78)
}
function Add-Esito([string]$Livello, [string]$Testo) {
    $Esito.Add(("[{0}] {1}" -f $Livello, $Testo))
}
function Get-IntuneEnrollment {
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.ProviderID -eq 'MS DM Server' } | Select-Object -First 1
}

# Decodifica indicativa dei codici d'errore piu' frequenti nell'evento 76
$CodiciNoti = @{
    '0x80180003' = 'Utente non autorizzato a iscrivere: licenza Intune mancante o utente fuori dall''ambito MDM (Intune > Registrazione automatica).'
    '0x80180018' = 'Problema di licenza dell''utente (nessuna licenza Intune assegnata).'
    '0x80180014' = 'Dispositivo non supportato o bloccato da una restrizione di registrazione (piattaforma Windows o dispositivi personali bloccati).'
    '0x80180026' = 'Conflitto con il client Configuration Manager installato sul PC.'
    '0x8018002a' = 'Il dispositivo risulta gia'' iscritto (a Intune o a un altro MDM).'
    '0x8018002b' = 'UPN dell''utente con dominio non verificato o non instradabile, oppure ambito MDM.'
    '0x801c0003' = 'Utente non autorizzato a registrare dispositivi in Entra ID.'
    '0x80180005' = 'Errore lato server durante la registrazione: riprovare piu'' tardi.'
    '0x80192ee7' = 'Problema di rete/DNS verso gli endpoint Microsoft.'
    '0x80072efd' = 'Impossibile raggiungere il server (rete, proxy o firewall).'
}

# ---------------------------------------------------------------------------
Out-Log "horsa-intune-diagnostic3.ps1 versione $ScriptVersion"
Out-Section '1. SISTEMA'
$os = Get-CimInstance Win32_OperatingSystem
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Out-Log ("Data          : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Out-Log ("Computer      : {0}" -f $env:COMPUTERNAME)
Out-Log ("Utente        : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Out-Log ("UPN           : {0}" -f ((whoami /upn) 2>$null))
Out-Log ("Windows       : {0} {1} build {2}" -f $os.Caption, $os.Version, $os.BuildNumber)
Out-Log ("Ultimo avvio  : {0}" -f $os.LastBootUpTime)
Out-Log ("Amministratore: {0}" -f $isAdmin)
if (-not $isAdmin) {
    Add-Esito 'ATTENZIONE' 'Script non eseguito come amministratore: gpresult computer e alcuni controlli sono incompleti. Rilanciare da PowerShell "Esegui come amministratore".'
}
if ($os.Caption -match 'Windows 10') {
    Add-Esito 'INFO' 'Windows 10: fuori supporto Microsoft da ottobre 2025.'
}

# ---------------------------------------------------------------------------
if ($Forza) {
    Out-Section '0. AZIONI FORZATE (-Forza)'
    if (-not $isAdmin) {
        Out-Log 'Saltate: servono privilegi di amministratore.'
    } else {
        Out-Log '> gpupdate /target:computer /force'
        (gpupdate /target:computer /force 2>&1) | ForEach-Object { Out-Log "  $_" }
    }
}

# ---------------------------------------------------------------------------
Out-Section '2. JOIN (dsregcmd /status)'
$ds = (dsregcmd /status) 2>$null
$dsv = @{}
foreach ($l in $ds) {
    if ($l -match '^\s*([A-Za-z]+)\s*:\s*(.*)$') { if (-not $dsv.ContainsKey($Matches[1])) { $dsv[$Matches[1]] = $Matches[2].Trim() } }
}
foreach ($k in 'AzureAdJoined','DomainJoined','DomainName','EnterpriseJoined','WorkplaceJoined','DeviceId','TenantName','DeviceAuthStatus','AzureAdPrt','AzureAdPrtUpdateTime','OnPremTgt','CloudTgt','MdmUrl') {
    Out-Log ("{0,-22}: {1}" -f $k, $dsv[$k])
}
$hybrid = ($dsv['AzureAdJoined'] -eq 'YES' -and $dsv['DomainJoined'] -eq 'YES')
if (-not $hybrid) {
    Add-Esito 'KO' ("Il PC non e' hybrid joined (AzureAdJoined={0}, DomainJoined={1}): la GPO di auto-enrollment richiede il join ibrido." -f $dsv['AzureAdJoined'], $dsv['DomainJoined'])
}
if ($dsv['DeviceAuthStatus'] -and $dsv['DeviceAuthStatus'] -ne 'SUCCESS') {
    Add-Esito 'KO' ("DeviceAuthStatus={0}: l'oggetto dispositivo in Entra e' assente o disabilitato." -f $dsv['DeviceAuthStatus'])
}
if ($dsv['AzureAdPrt'] -ne 'YES') {
    Add-Esito 'KO' 'Nessun Primary Refresh Token (AzureAdPrt=NO): l''iscrizione con credenziali utente non puo'' partire.'
}

# ---------------------------------------------------------------------------
Out-Section '3. RAGGIUNGIBILITA'' DEL DOMINIO'
$dcOk = $false
$nl = (nltest /dsgetdc:$Dominio 2>&1)
$nl | Select-Object -First 6 | ForEach-Object { Out-Log "  $_" }
if ($LASTEXITCODE -eq 0) { $dcOk = $true }
if ($isAdmin) {
    try {
        $sc = Test-ComputerSecureChannel -ErrorAction Stop
        Out-Log ("Canale sicuro con il dominio: {0}" -f $sc)
        if (-not $sc) { Add-Esito 'KO' 'Canale sicuro con il dominio non valido (relazione di trust rotta).' }
    } catch { Out-Log ("Canale sicuro: verifica non riuscita ({0})" -f $_.Exception.Message) }
}
$vpn = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Fortinet|VPN|Virtual Private|TAP|WireGuard|Cisco AnyConnect' }
Out-Log ("Adattatori VPN attivi: {0}" -f ((($vpn | ForEach-Object { $_.InterfaceDescription }) -join '; ')))
if (-not $dcOk) {
    Add-Esito 'KO' 'Nessun domain controller raggiungibile ora: le GPO non si aggiornano. Collegare la VPN e rilanciare (anche con -Forza).'
}

# ---------------------------------------------------------------------------
Out-Section "4. CRITERI DI GRUPPO (gpresult, scope computer) - GPO '$GpoNome'"
$gpoTrovata = $null
if ($isAdmin) {
    $xmlPath = Join-Path $env:TEMP 'intune-diag-gpresult.xml'
    gpresult /scope computer /x $xmlPath /f 2>&1 | Out-Null
    if (Test-Path $xmlPath) {
        [xml]$gx = Get-Content $xmlPath -Raw
        $cr = $gx.Rsop.ComputerResults
        Out-Log ("Ultima lettura criteri : {0}" -f $cr.EventsDetails.SinglePassEventsDetails.ProcessingTime) 2>$null
        Out-Log ("Sito AD               : {0}" -f $cr.Site)
        Out-Log ("Lettura RSoP          : {0}" -f $gx.Rsop.ReadTime)
        Out-Log ''
        Out-Log 'GPO computer (Nome | Applicata | FiltroOK | AccessoNegato | Link):'
        foreach ($g in @($cr.GPO)) {
            $applied = ($g.FilterAllowed -eq 'true' -and $g.AccessDenied -ne 'true' -and $g.IsValid -eq 'true' -and $g.Enabled -eq 'true')
            $links = (@($g.Link) | ForEach-Object { $_.SOMPath }) -join ', '
            Out-Log ("  {0} | {1} | {2} | {3} | {4}" -f $g.Name, $applied, $g.FilterAllowed, $g.AccessDenied, $links)
            if ($g.Name -eq $GpoNome) { $gpoTrovata = $g; $gpoApplicata = $applied }
        }
        Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
        if (-not $gpoTrovata) {
            Add-Esito 'KO' "La GPO '$GpoNome' non compare tra le GPO computer: il PC non e' nella OU collegata oppure non ha mai elaborato i criteri da quando e' stata collegata."
        } elseif (-not $gpoApplicata) {
            Add-Esito 'KO' ("La GPO '$GpoNome' e' presente ma NON applicata (FilterAllowed={0}, AccessDenied={1}): controllare il filtro di sicurezza/WMI della GPO." -f $gpoTrovata.FilterAllowed, $gpoTrovata.AccessDenied)
        } else {
            Add-Esito 'OK' "La GPO '$GpoNome' e' applicata al computer."
        }
    } else {
        Out-Log 'gpresult non ha prodotto il report XML.'
    }
} else {
    Out-Log 'Saltato: serve amministratore.'
}
Out-Log ''
Out-Log "Eventi GroupPolicy (ultimi $Giorni giorni) - fine elaborazione ed errori:"
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-GroupPolicy/Operational'; StartTime = (Get-Date).AddDays(-$Giorni) } -ErrorAction Stop |
        Where-Object { ($_.Id -ge 8000 -and $_.Id -le 8007) -or $_.Level -le 2 } |
        Select-Object -First 15 |
        ForEach-Object { Out-Log ("  {0:yyyy-MM-dd HH:mm} id={1} lvl={2} {3}" -f $_.TimeCreated, $_.Id, $_.Level, (($_.Message -split "`n")[0]).Trim()) }
} catch { Out-Log "  nessun evento o log non leggibile ($($_.Exception.Message))" }

# ---------------------------------------------------------------------------
Out-Section '5. POLICY MDM NEL REGISTRO'
$polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM'
$pol = Get-ItemProperty -Path $polPath -ErrorAction SilentlyContinue
if ($pol) {
    Out-Log ("AutoEnrollMDM        : {0}" -f $pol.AutoEnrollMDM)
    $tipo = switch ($pol.UseAADCredentialType) { 1 { 'Credenziali utente' } 2 { 'Credenziali dispositivo' } default { "non impostato ($($pol.UseAADCredentialType))" } }
    Out-Log ("UseAADCredentialType : {0}" -f $tipo)
    if ($pol.AutoEnrollMDM -eq 1) { Add-Esito 'OK' "Policy di auto-enrollment presente nel registro ($tipo)." }
    else { Add-Esito 'KO' 'Chiave MDM presente ma AutoEnrollMDM diverso da 1.' }
} else {
    Out-Log "Chiave $polPath assente."
    Add-Esito 'KO' 'La policy di auto-enrollment non e'' arrivata sul PC (chiave MDM assente nel registro).'
}

# ---------------------------------------------------------------------------
Out-Section '6. ISCRIZIONI MDM PRESENTI'
$intune = $null
$altriMdm = @()
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.ProviderID -or $p.UPN) {
        Out-Log ("  {0}" -f $_.PSChildName)
        Out-Log ("     ProviderID={0} | UPN={1} | EnrollmentState={2} | EnrollmentType={3}" -f $p.ProviderID, $p.UPN, $p.EnrollmentState, $p.EnrollmentType)
        if ($p.DiscoveryServiceFullURL) { Out-Log ("     Discovery={0}" -f $p.DiscoveryServiceFullURL) }
        if ($p.ProviderID -eq 'MS DM Server') { $intune = $p }
        elseif ($p.ProviderID -and $p.ProviderID -notin $ProviderMicrosoft) { $altriMdm += $p.ProviderID }
    }
}
if ($intune) {
    if ($intune.EnrollmentState -eq 1) { Add-Esito 'OK' ("Il PC E' iscritto a Intune (UPN {0}). Se non compare nel portale: verificare con il Device ID in Intune > Dispositivi." -f $intune.UPN) }
    else { Add-Esito 'KO' ("Iscrizione Intune presente ma in stato {0} (non completata)." -f $intune.EnrollmentState) }
} else {
    Out-Log '  Nessuna iscrizione Intune (ProviderID "MS DM Server").'
    Add-Esito 'KO' 'Il PC NON e'' iscritto a Intune.'
}
if ($altriMdm) {
    Add-Esito 'KO' ("Iscrizione a un altro MDM ({0}): Windows ammette un solo MDM, va rimossa prima dell'iscrizione a Intune." -f ($altriMdm -join ', '))
}

# ---------------------------------------------------------------------------
Out-Section '7. ATTIVITA'' PIANIFICATE EnterpriseMgmt'
$tasks = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue
if ($tasks) {
    foreach ($t in $tasks) {
        $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        Out-Log ("  {0}{1} | stato={2} | ultima={3} | esito=0x{4:X8}" -f $t.TaskPath, $t.TaskName, $t.State, $i.LastRunTime, $i.LastTaskResult)
    }
    $auto = $tasks | Where-Object { $_.TaskName -match 'automatically enrolling|AutoEnroll' }
    if (-not $auto -and -not $intune) { Add-Esito 'KO' 'Manca l''attivita'' pianificata di auto-enrollment creata dalla GPO.' }
} else {
    Out-Log '  Nessuna attivita'' in \Microsoft\Windows\EnterpriseMgmt\'
    if (-not $intune) { Add-Esito 'KO' 'Nessuna attivita'' pianificata EnterpriseMgmt: la GPO non ha mai attivato l''auto-enrollment su questo PC.' }
}

# ---------------------------------------------------------------------------
Out-Section "8. EVENTI DI ISCRIZIONE MDM (ultimi $Giorni giorni)"
$ev = @()
try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'; StartTime = (Get-Date).AddDays(-$Giorni) } -ErrorAction Stop
} catch { Out-Log "  nessun evento nel periodo ($($_.Exception.Message))" }
$ev7576 = $ev | Where-Object { $_.Id -in 75, 76 }
foreach ($e in ($ev7576 | Select-Object -First 10)) {
    Out-Log ("  {0:yyyy-MM-dd HH:mm} id={1}" -f $e.TimeCreated, $e.Id)
    Out-Log ("     {0}" -f (($e.Message -replace '\s+', ' ').Trim()))
}
$altriErr = $ev | Where-Object { $_.Level -le 2 -and $_.Id -notin 75, 76 } | Select-Object -First 10
if ($altriErr) {
    Out-Log ''
    Out-Log '  Altri errori del provider MDM:'
    foreach ($e in $altriErr) { Out-Log ("  {0:yyyy-MM-dd HH:mm} id={1} {2}" -f $e.TimeCreated, $e.Id, (($e.Message -replace '\s+', ' ').Trim().Substring(0, [Math]::Min(220, (($e.Message -replace '\s+', ' ').Trim()).Length)))) }
}
$ultimo = $ev7576 | Select-Object -First 1
if ($ultimo -and $ultimo.Id -eq 76) {
    $codice = if ($ultimo.Message -match '0x[0-9A-Fa-f]{8}') { $Matches[0].ToLower() } else { 'n/d' }
    $spieg = if ($CodiciNoti.ContainsKey($codice)) { $CodiciNoti[$codice] } else { 'codice non in tabella: cercarlo nella documentazione Microsoft "Troubleshoot Windows device enrollment errors".' }
    Add-Esito 'KO' ("Ultimo tentativo di iscrizione FALLITO il {0:yyyy-MM-dd HH:mm}, codice {1}: {2}" -f $ultimo.TimeCreated, $codice, $spieg)
} elseif ($ultimo -and $ultimo.Id -eq 75) {
    Add-Esito 'OK' ("Ultimo tentativo di iscrizione RIUSCITO il {0:yyyy-MM-dd HH:mm}." -f $ultimo.TimeCreated)
} elseif (-not $intune) {
    Add-Esito 'KO' "Nessun tentativo di iscrizione negli ultimi $Giorni giorni (nessun evento 75/76)."
}

# ---------------------------------------------------------------------------
Out-Section '9. ALTRI AGENTI DI GESTIONE'
$svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'CcmExec' -or $_.DisplayName -match 'ManageEngine|Desktop Central|UEMS|Meraki|Systems Manager' }
if ($svc) {
    foreach ($s in $svc) { Out-Log ("  {0} ({1}) - {2}" -f $s.DisplayName, $s.Name, $s.Status) }
    if ($svc | Where-Object Name -eq 'CcmExec') { Add-Esito 'ATTENZIONE' 'Client Configuration Manager presente: possibile co-gestione o conflitto (errore 0x80180026).' }
    if ($svc | Where-Object { $_.DisplayName -match 'Meraki|Systems Manager' }) { Add-Esito 'ATTENZIONE' 'Agente Meraki Systems Manager presente: verificare che non sia iscritto come MDM.' }
} else {
    Out-Log '  Nessuno (ConfigMgr, ManageEngine Desktop Central, Meraki).'
}

# ---------------------------------------------------------------------------
Out-Section '10. CONNETTIVITA'' VERSO GLI ENDPOINT MICROSOFT'
foreach ($h in 'enrollment.manage.microsoft.com','login.microsoftonline.com','enterpriseregistration.windows.net','portal.manage.microsoft.com') {
    try {
        $ok = Test-NetConnection -ComputerName $h -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch { $ok = $false }
    Out-Log ("  {0,-40} 443/tcp : {1}" -f $h, $(if ($ok) { 'OK' } else { 'NON RAGGIUNGIBILE' }))
    if (-not $ok) { Add-Esito 'KO' "Endpoint $h non raggiungibile sulla 443." }
}

# ---------------------------------------------------------------------------
Out-Section '11. FIX AUTOMATICO (iscrizione a Intune)'
$intuneOra = Get-IntuneEnrollment
if ($SoloDiagnosi) {
    Out-Log 'Non eseguito: richiesto -SoloDiagnosi.'
} elseif ($intuneOra -and $intuneOra.EnrollmentState -eq 1) {
    Out-Log 'Non necessario: il PC e'' gia'' iscritto a Intune.'
} elseif (-not $isAdmin) {
    Out-Log 'Non eseguito: servono privilegi di amministratore.'
    Add-Esito 'ATTENZIONE' 'Fix automatico non eseguito: rilanciare lo script da PowerShell "Esegui come amministratore".'
} elseif (-not $hybrid -or $dsv['AzureAdPrt'] -ne 'YES') {
    Out-Log 'Non eseguito: il PC non e'' hybrid joined o manca il Primary Refresh Token (l''iscrizione fallirebbe).'
    Add-Esito 'ATTENZIONE' 'Fix automatico non eseguibile: risolvere prima join/PRT (vedi sezione 2).'
} elseif ($altriMdm) {
    Out-Log 'Non eseguito: il PC e'' iscritto a un altro MDM, che va rimosso prima.'
} else {
    $de = Join-Path $env:WINDIR 'System32\deviceenroller.exe'
    $t0 = Get-Date
    Out-Log ("{0:yyyy-MM-dd HH:mm:ss} > {1} /c /AutoEnrollMDM" -f $t0, $de)
    Start-Process -FilePath $de -ArgumentList '/c /AutoEnrollMDM' -Wait -NoNewWindow
    Out-Log 'Verifica dell''iscrizione (al massimo 3 minuti)...'
    $esitoFix = $null; $evFix = $null
    for ($i = 0; $i -lt 18; $i++) {
        Start-Sleep -Seconds 10
        $nuovo = Get-IntuneEnrollment
        if ($nuovo -and $nuovo.EnrollmentState -eq 1) { $esitoFix = 'OK'; break }
        $evFix = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'; StartTime = $t0; Id = 75, 76 } -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($evFix) { $esitoFix = if ($evFix.Id -eq 75) { 'OK' } else { 'KO' }; break }
    }
    if ($evFix) { Out-Log ("  evento {0}: {1}" -f $evFix.Id, (($evFix.Message -replace '\s+', ' ').Trim())) }
    if ($esitoFix -eq 'OK') {
        Out-Log '  Iscrizione a Intune RIUSCITA.'
        Add-Esito 'OK' 'FIX AUTOMATICO RIUSCITO: il PC e'' stato iscritto a Intune e comparira'' nel portale entro qualche minuto. Gli eventuali KO sopra descrivono lo stato PRIMA del fix.'
    } elseif ($esitoFix -eq 'KO') {
        $codice = if ($evFix.Message -match '0x[0-9A-Fa-f]{8}') { $Matches[0].ToLower() } else { 'n/d' }
        $spieg = if ($CodiciNoti.ContainsKey($codice)) { $CodiciNoti[$codice] } else { 'codice non in tabella.' }
        Out-Log "  Iscrizione FALLITA, codice $codice."
        Add-Esito 'KO' "FIX AUTOMATICO FALLITO, codice ${codice}: $spieg"
    } else {
        Out-Log '  Nessun esito entro 3 minuti.'
        Add-Esito 'ATTENZIONE' 'FIX AUTOMATICO eseguito ma senza esito entro 3 minuti: ricontrollare Intune tra qualche minuto o rilanciare lo script con -SoloDiagnosi.'
    }
}

# ---------------------------------------------------------------------------
Out-Section '12. ESITO'
$ordine = @{ '[KO]' = 0; '[ATTENZIONE]' = 1; '[OK]' = 2; '[INFO]' = 3 }
foreach ($r in ($Esito | Sort-Object { $ordine[$_.Substring(0, $_.IndexOf(']') + 1)] })) { Out-Log "  $r" }
Out-Log ''
Out-Log "Log salvato in: $LogFile"
Out-Log 'Inviare questo file a service.horsa@horsa.it'
