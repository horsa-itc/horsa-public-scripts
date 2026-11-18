# 1. È iscritto a Intune? (nessun risultato = mai iscritto)
Get-ChildItem HKLM:\SOFTWARE\Microsoft\Enrollments | Get-ItemProperty |
  Where-Object ProviderID -eq 'MS DM Server' | Select-Object UPN, EnrollmentState

# 2. La GPO di auto-enrollment è arrivata? (atteso: AutoEnrollMDM = 1)
Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM -ErrorAction SilentlyContinue

# 3. Tentativi di iscrizione: evento 75 = riuscito, 76 = fallito (con codice d'errore)
Get-WinEvent -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin' -MaxEvents 50 |
  Where-Object Id -in 75,76 | Format-List TimeCreated, Id, Message
