# check_win_cluster.ps1 - Nagios/Icinga plugin per Windows Failover Cluster
# Eseguire direttamente sulla macchina Windows (via NSClient++ o manualmente)
# EXIT CODES: 0=OK  2=CRITICAL
#
# Uso: powershell -ExecutionPolicy Bypass -File check_win_cluster.ps1

# ===== VARIABILI - MODIFICA QUI =====
$Group        = "AHB-ONE01"    # Nome del gruppo cluster SQL da monitorare
$EventMinutes = 5              # Finestra temporale eventi failover (minuti)
# Gruppi da ignorare (normalmente Offline, non sono un problema)
$IgnoreGroups = @("Available Storage")
# =====================================

$exitCode = 0
$summaryParts = @()
$details = @()
$perfdata = @()

try {
    Import-Module FailoverClusters -ErrorAction Stop
} catch {
    Write-Host "CRITICAL - Impossibile caricare modulo FailoverClusters: $($_.Exception.Message)"
    [System.Environment]::Exit(2)
}

# ---- NODI ----
try {
    $nodes = @(Get-ClusterNode -ErrorAction Stop)
    $nodesUp = @($nodes | Where-Object { $_.State -eq 'Up' }).Count
    $totalNodes = $nodes.Count

    $summaryParts += "Cluster: $nodesUp/$totalNodes nodi up"
    $perfdata += "nodes_up=$nodesUp;;1;0;$totalNodes"

    foreach ($n in $nodes) {
        if ($n.State -ne 'Up') {
            $exitCode = 2
            $details += "  [CRIT] Nodo $($n.Name): $($n.State)"
        } else {
            $details += "  [OK]   Nodo $($n.Name): Up"
        }
    }
} catch {
    $exitCode = 2
    $summaryParts += "Nodi: ERRORE"
    $details += "  [CRIT] Errore lettura nodi: $($_.Exception.Message)"
}

# ---- GRUPPI ----
try {
    $groups = @(Get-ClusterGroup -ErrorAction Stop)
    $groupsOnline = @($groups | Where-Object { $_.State -eq 'Online' }).Count
    $perfdata += "groups_online=$groupsOnline"

    $sqlGroup = $groups | Where-Object { $_.Name -eq $Group }

    if (-not $sqlGroup) {
        $exitCode = 2
        $summaryParts += "SQL $Group NON TROVATO"
        $details += "  [CRIT] Gruppo '$Group' non trovato nel cluster"
        $details += "  [INFO] Gruppi disponibili: $(($groups | ForEach-Object { "$($_.Name)($($_.State))" }) -join ', ')"
    } elseif ($sqlGroup.State -ne 'Online') {
        $exitCode = 2
        $summaryParts += "SQL $Group $($sqlGroup.State) su $($sqlGroup.OwnerNode.Name)"
        $details += "  [CRIT] Gruppo $Group`: $($sqlGroup.State) (owner: $($sqlGroup.OwnerNode.Name))"
    } else {
        $summaryParts += "SQL $Group Online su $($sqlGroup.OwnerNode.Name)"
        $details += "  [OK]   Gruppo $Group`: Online su $($sqlGroup.OwnerNode.Name)"
    }

    # mostra tutti i gruppi (ignora quelli in $IgnoreGroups)
    foreach ($g in $groups) {
        if ($g.Name -ne $Group) {
            if ($g.Name -in $IgnoreGroups) {
                $details += "  [SKIP] Gruppo $($g.Name): $($g.State) su $($g.OwnerNode.Name) (ignorato)"
            } elseif ($g.State -eq 'Online') {
                $details += "  [OK]   Gruppo $($g.Name): Online su $($g.OwnerNode.Name)"
            } else {
                $exitCode = 2
                $details += "  [CRIT] Gruppo $($g.Name): $($g.State) su $($g.OwnerNode.Name)"
            }
        }
    }
} catch {
    $exitCode = 2
    $summaryParts += "Gruppi: ERRORE"
    $details += "  [CRIT] Errore lettura gruppi: $($_.Exception.Message)"
}

# ---- RISORSE DEL GRUPPO SQL ----
try {
    $resources = @(Get-ClusterResource -ErrorAction Stop)
    $sqlResources = @($resources | Where-Object { $_.OwnerGroup.Name -eq $Group })
    $sqlResOK = @($sqlResources | Where-Object { $_.State -eq 'Online' }).Count
    $sqlResTotal = $sqlResources.Count

    $summaryParts += "$sqlResOK/$sqlResTotal risorse OK"
    $perfdata += "sql_resources_ok=$sqlResOK"

    foreach ($r in $sqlResources) {
        if ($r.State -ne 'Online') {
            $exitCode = 2
            $details += "  [CRIT] Risorsa $($r.Name): $($r.State) (tipo: $($r.ResourceType.Name))"
        } else {
            $details += "  [OK]   Risorsa $($r.Name): Online (tipo: $($r.ResourceType.Name))"
        }
    }

    # risorse problematiche di ALTRI gruppi (esclusi gruppi ignorati)
    $otherFailed = @($resources | Where-Object { $_.OwnerGroup.Name -ne $Group -and $_.OwnerGroup.Name -notin $IgnoreGroups -and $_.State -ne 'Online' })
    foreach ($r in $otherFailed) {
        $details += "  [WARN] Risorsa $($r.Name): $($r.State) (gruppo: $($r.OwnerGroup.Name), tipo: $($r.ResourceType.Name))"
    }
} catch {
    $exitCode = 2
    $summaryParts += "Risorse: ERRORE"
    $details += "  [CRIT] Errore lettura risorse: $($_.Exception.Message)"
}

# ---- QUORUM ----
try {
    $quorum = Get-ClusterQuorum -ErrorAction Stop
    $quorumType = [string]$quorum.QuorumType
    $quorumRes = if ($quorum.QuorumResource) { $quorum.QuorumResource.Name } else { "N/A" }
    $summaryParts += "Quorum: $quorumType"
    $details += "  [INFO] Quorum: $quorumType (risorsa: $quorumRes)"
} catch {
    $details += "  [WARN] Errore lettura quorum: $($_.Exception.Message)"
}

# ---- NETWORK ----
try {
    $networks = @(Get-ClusterNetwork -ErrorAction Stop)
    foreach ($net in $networks) {
        if ($net.State -eq 'Up') {
            $details += "  [OK]   Rete $($net.Name): Up (ruolo: $($net.Role))"
        } else {
            $exitCode = 2
            $details += "  [CRIT] Rete $($net.Name): $($net.State) (ruolo: $($net.Role))"
        }
    }
} catch {
    $details += "  [WARN] Errore lettura reti: $($_.Exception.Message)"
}

# ---- EVENTI FAILOVER ----
$eventCount = 0
$switchDetected = 0
try {
    $events = @(Get-WinEvent -LogName 'Microsoft-Windows-FailoverClustering/Operational' -MaxEvents 100 -EA SilentlyContinue |
        Where-Object { $_.Id -in @(1641,1135,1079,1069,1077) -and $_.TimeCreated -gt (Get-Date).AddMinutes(-$EventMinutes) })

    $eventCount = $events.Count

    if ($eventCount -gt 0) {
        $exitCode = 2
        $eventIDs = ($events | Select-Object -ExpandProperty Id -Unique) -join ','
        $summaryParts += "$eventCount eventi failover"
        $details += "  [CRIT] Eventi failover negli ultimi $EventMinutes min: $eventCount (ID: $eventIDs)"

        # dettaglio ogni evento
        foreach ($evt in $events | Select-Object -First 10) {
            $details += "         $($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) ID=$($evt.Id): $($evt.Message.Split([char]10)[0].Trim())"
        }
        if ($eventCount -gt 10) {
            $details += "         ... e altri $($eventCount - 10) eventi"
        }
    }
} catch {
    $details += "  [WARN] Errore lettura eventi: $($_.Exception.Message)"
}

# ---- SWITCH NODO (confronto con stato precedente) ----
if ($sqlGroup -and $sqlGroup.OwnerNode) {
    $stateFile = "$env:TEMP\check_cluster_$($Group).owner"
    $currentOwner = $sqlGroup.OwnerNode.Name

    if (Test-Path $stateFile) {
        $prevOwner = (Get-Content $stateFile -ErrorAction SilentlyContinue).Trim()
        if ($prevOwner -and $prevOwner -ne $currentOwner) {
            $exitCode = 2
            $switchDetected = 1
            $summaryParts += "Switch: $prevOwner -> $currentOwner"
            $details += "  [CRIT] Switch nodo rilevato: $prevOwner -> $currentOwner"
        }
    }
    $currentOwner | Set-Content $stateFile -Force
}

$perfdata += "switch_detected=$switchDetected"
$perfdata += "failover_events=$eventCount"

# ---- CLUSTER INFO ----
try {
    $cluster = Get-Cluster -ErrorAction Stop
    $details += "  [INFO] Cluster: $($cluster.Name) (dominio: $($cluster.Domain))"
} catch {}

# ---- OUTPUT ----
$statusLabel = if ($exitCode -eq 0) { "OK" } else { "CRITICAL" }
$summary = "$statusLabel - $($summaryParts -join ' | ')"
$perfString = $perfdata -join ' '

Write-Host "$summary | $perfString"
if ($details.Count -gt 0) {
    Write-Host ($details -join "`n")
}

# Usa [System.Environment]::Exit() per forzare l'exit code corretto
# "exit 2" in PowerShell puo' essere rimappato da NSClient++, questo no
[System.Environment]::Exit($exitCode)
