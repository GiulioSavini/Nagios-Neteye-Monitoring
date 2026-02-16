# check_veeam_storage.ps1 - Nagios/Icinga plugin per Veeam Backup Repository
# Eseguire sulla macchina Veeam (via NSClient++ o manualmente)
# EXIT CODES: 0=OK  1=WARNING  2=CRITICAL
#
# Uso: powershell -ExecutionPolicy Bypass -File check_veeam_storage.ps1

# ===== VARIABILI - MODIFICA QUI =====
$WarnPct = 10            # WARNING se spazio libero < questo %
$CritPct = 5             # CRITICAL se spazio libero < questo %
$RepoName = "DO_NOT_USE" # Nome del repository da monitorare (solo questo)
# =====================================

$exitCode = 0
$summaryParts = @()
$details = @()
$perfdata = @()

# ---- Carica modulo Veeam ----
try {
    # Prova prima il modulo nuovo (v12+), poi il vecchio
    if (Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
        Import-Module Veeam.Backup.PowerShell -ErrorAction Stop -WarningAction SilentlyContinue
    } elseif (Get-PSSnapin -Registered -Name VeeamPSSnapIn -EA SilentlyContinue) {
        Add-PSSnapin VeeamPSSnapIn -ErrorAction Stop
    } else {
        Write-Host "CRITICAL - Modulo Veeam non trovato (ne Veeam.Backup.PowerShell ne VeeamPSSnapIn)"
        [System.Environment]::Exit(2)
    }
} catch {
    Write-Host "CRITICAL - Errore caricamento modulo Veeam: $($_.Exception.Message)"
    [System.Environment]::Exit(2)
}

# ---- Connessione a Veeam (localhost) ----
try {
    Connect-VBRServer -Server localhost -ErrorAction Stop
} catch {
    # Potrebbe gia' essere connesso o non serve connessione esplicita
    # Proviamo a proseguire
}

# ---- Leggi repository ----
try {
    $allRepos = @(Get-VBRBackupRepository -ErrorAction Stop)

    # Aggiungi anche i Scale-Out repository se presenti
    try {
        $sobrExtents = @(Get-VBRBackupRepository -ScaleOut -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Extent } |
            ForEach-Object { $_.Repository })
        if ($sobrExtents.Count -gt 0) {
            $allRepos += $sobrExtents
        }
    } catch {}

} catch {
    Write-Host "CRITICAL - Errore lettura repository: $($_.Exception.Message)"
    try { Disconnect-VBRServer -ErrorAction SilentlyContinue } catch {}
    [System.Environment]::Exit(2)
}

# Filtra solo il repository specificato
$repos = @($allRepos | Where-Object { $_.Name -eq $RepoName })

if ($repos.Count -eq 0) {
    $disponibili = ($allRepos | ForEach-Object { $_.Name }) -join ', '
    Write-Host "CRITICAL - Repository '$RepoName' non trovato. Disponibili: $disponibili"
    try { Disconnect-VBRServer -ErrorAction SilentlyContinue } catch {}
    [System.Environment]::Exit(2)
}

# ---- Valuta ogni repository ----
$critCount = 0
$warnCount = 0
$okCount = 0

foreach ($repo in $repos) {
    $repoName = $repo.Name

    try {
        # GetContainer() restituisce info sullo storage
        $container = $repo.GetContainer()
        $totalGB = [math]::Round($container.CachedTotalSpace.InGigabytes, 2)
        $freeGB  = [math]::Round($container.CachedFreeSpace.InGigabytes, 2)
        $usedGB  = [math]::Round($totalGB - $freeGB, 2)

        if ($totalGB -le 0) {
            $details += "  [WARN] $repoName`: impossibile leggere dimensione (totalGB=0)"
            continue
        }

        $freePct = [math]::Round(($freeGB / $totalGB) * 100, 1)
        $usedPct = [math]::Round(100 - $freePct, 1)

        # Perfdata
        $safeLabel = $repoName -replace "'",'' -replace '=','_' -replace ' ','_'
        $perfdata += "'${safeLabel}_free_pct'=${freePct}%;${WarnPct};${CritPct};0;100"
        $perfdata += "'${safeLabel}_free_gb'=${freeGB}GB;;;0;${totalGB}"
        $perfdata += "'${safeLabel}_total_gb'=${totalGB}GB;;;0;"

        # Valutazione
        if ($freePct -lt $CritPct) {
            $exitCode = 2
            $critCount++
            $details += "  [CRIT] $repoName`: ${freePct}% libero (${freeGB} GB / ${totalGB} GB) - sotto soglia ${CritPct}%"
        } elseif ($freePct -lt $WarnPct) {
            if ($exitCode -lt 1) { $exitCode = 1 }
            $warnCount++
            $details += "  [WARN] $repoName`: ${freePct}% libero (${freeGB} GB / ${totalGB} GB) - sotto soglia ${WarnPct}%"
        } else {
            $okCount++
            $details += "  [OK]   $repoName`: ${freePct}% libero (${freeGB} GB / ${totalGB} GB)"
        }
    } catch {
        $details += "  [WARN] $repoName`: errore lettura spazio - $($_.Exception.Message)"
    }
}

# ---- Summary ----
$totalRepos = $critCount + $warnCount + $okCount

if ($critCount -gt 0) {
    $summaryParts += "$critCount repo CRITICAL"
}
if ($warnCount -gt 0) {
    $summaryParts += "$warnCount repo WARNING"
}
if ($okCount -gt 0) {
    $summaryParts += "$okCount repo OK"
}
$summaryParts += "($totalRepos totali, soglie: w=${WarnPct}% c=${CritPct}%)"

# ---- Output ----
$statusLabel = switch ($exitCode) {
    0 { "OK" }
    1 { "WARNING" }
    2 { "CRITICAL" }
}
$summary = "$statusLabel - $($summaryParts -join ' | ')"
$perfString = $perfdata -join ' '

Write-Host "$summary | $perfString"
if ($details.Count -gt 0) {
    Write-Host ($details -join "`n")
}

# ---- Disconnetti ----
try { Disconnect-VBRServer -ErrorAction SilentlyContinue } catch {}

[System.Environment]::Exit($exitCode)
