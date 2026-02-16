package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/masterzen/winrm"
)

const appVersion = "1.0.0"

// Nagios exit codes
const (
	nagOK       = 0
	nagWarning  = 1
	nagCritical = 2
	nagUnknown  = 3
)

var statusText = [4]string{"OK", "WARNING", "CRITICAL", "UNKNOWN"}

// ---------------------------------------------------------------------------
// Types - cluster data from PowerShell JSON
// ---------------------------------------------------------------------------

type ClusterData struct {
	Nodes     []NodeInfo     `json:"nodes"`
	Groups    []GroupInfo    `json:"groups"`
	Resources []ResourceInfo `json:"resources"`
	Quorum    QuorumInfo     `json:"quorum"`
	Events    []EventInfo    `json:"events"`
}

type NodeInfo struct {
	Name  string `json:"Name"`
	State string `json:"State"`
}

type GroupInfo struct {
	Name      string `json:"Name"`
	State     string `json:"State"`
	OwnerNode string `json:"OwnerNode"`
}

type ResourceInfo struct {
	Name       string `json:"Name"`
	State      string `json:"State"`
	OwnerGroup string `json:"OwnerGroup"`
}

type QuorumInfo struct {
	Type     string `json:"type"`
	Resource string `json:"resource"`
}

type EventInfo struct {
	Id   int    `json:"Id"`
	Time string `json:"Time"`
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func nagiosExit(code int, msg string) {
	fmt.Println(msg)
	os.Exit(code)
}

func mask(s, pw string) string {
	if pw == "" {
		return s
	}
	return strings.ReplaceAll(s, pw, "********")
}

func safeLabel(name string) string {
	r := strings.NewReplacer("'", "", "=", "_", " ", "_")
	return r.Replace(name)
}

// ---------------------------------------------------------------------------
// PowerShell script builder
// ---------------------------------------------------------------------------

func buildPSScript(eventMinutes int) string {
	return fmt.Sprintf(`Import-Module FailoverClusters;
$nodes = Get-ClusterNode | Select-Object Name, @{N='State';E={$_.State.ToString()}};
$groups = Get-ClusterGroup | Select-Object Name, @{N='State';E={$_.State.ToString()}}, @{N='OwnerNode';E={$_.OwnerNode.Name}};
$resources = Get-ClusterResource | Select-Object Name, @{N='State';E={$_.State.ToString()}}, @{N='OwnerGroup';E={$_.OwnerGroup.Name}};
$quorum = Get-ClusterQuorum;
$events = @(Get-WinEvent -LogName 'Microsoft-Windows-FailoverClustering/Operational' -MaxEvents 50 -EA SilentlyContinue |
  Where-Object { $_.Id -in @(1641,1135,1079) -and $_.TimeCreated -gt (Get-Date).AddMinutes(-%d) } |
  Select-Object Id, @{N='Time';E={$_.TimeCreated.ToString('o')}});
@{
  nodes = @($nodes);
  groups = @($groups);
  resources = @($resources);
  quorum = @{type=[string]$quorum.QuorumType; resource=$quorum.QuorumResource.Name};
  events = $events
} | ConvertTo-Json -Depth 3 -Compress`, eventMinutes)
}

// ---------------------------------------------------------------------------
// WinRM connection with retry
// ---------------------------------------------------------------------------

func connectWinRM(host string, port int, user, pw string, useHTTPS, insecureTLS bool, timeout time.Duration, retries int) (*winrm.Client, error) {
	endpoint := winrm.NewEndpoint(host, port, useHTTPS, insecureTLS, nil, nil, nil, timeout)

	params := winrm.NewParameters("PT"+fmt.Sprintf("%d", int(timeout.Seconds()))+"S", "en-US", 153600)

	var client *winrm.Client
	var lastErr error

	for attempt := 0; attempt <= retries; attempt++ {
		var err error
		client, err = winrm.NewClientWithParameters(endpoint, user, pw, params)
		if err != nil {
			lastErr = err
			if attempt < retries {
				time.Sleep(time.Duration(math.Pow(2, float64(attempt))) * time.Second)
			}
			continue
		}
		lastErr = nil
		break
	}

	return client, lastErr
}

// ---------------------------------------------------------------------------
// State file for node switch detection
// ---------------------------------------------------------------------------

func stateFilePath(stateDir, host, group string) string {
	safe := strings.ReplaceAll(strings.ReplaceAll(host, ".", "_"), ":", "_")
	safeGrp := strings.ReplaceAll(strings.ReplaceAll(group, " ", "_"), "/", "_")
	return filepath.Join(stateDir, fmt.Sprintf("check_cluster_%s_%s.owner", safe, safeGrp))
}

func readPreviousOwner(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func saveCurrentOwner(path, owner string) {
	_ = os.WriteFile(path, []byte(owner+"\n"), 0644)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	// ---- CLI flags ----
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, `check_win_cluster v%s — Nagios/Icinga plugin for Windows Failover Cluster

Monitors a Windows Failover Cluster via WinRM. Checks node status, cluster
group state, resource health, quorum info, and detects node switches using
a local state file and Windows failover events.

Runs on the monitoring satellite and connects to the Windows host via WinRM
(Basic auth, HTTP/HTTPS), eliminating NRPE/NSClient++ timeout issues.

EXIT CODES: 0=OK  2=CRITICAL  3=UNKNOWN

USAGE:
  %s [flags]

FLAGS:
`, appVersion, os.Args[0])
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, `
EXAMPLES:
  # Basic check:
  %[1]s -H 10.0.1.50 -U administrator -p 'S3cret!' -group AHB-ONE01

  # HTTPS with insecure TLS:
  %[1]s -H 10.0.1.50 -U administrator -p 'S3cret!' -group AHB-ONE01 -S -insecure

  # Custom timeout and state directory:
  %[1]s -H 10.0.1.50 -U administrator -p 'S3cret!' -group AHB-ONE01 -t 60 -state-dir /var/tmp
`, os.Args[0])
	}

	host := flag.String("H", "", "Hostname or IP of the Windows host (required)")
	user := flag.String("U", "", "WinRM username (required)")
	pw := flag.String("p", "", "WinRM password (required)")
	port := flag.Int("P", 5985, "WinRM port (5985=HTTP, 5986=HTTPS)")
	useHTTPS := flag.Bool("S", false, "Use HTTPS for WinRM connection")
	insecure := flag.Bool("insecure", false, "Skip TLS certificate verification")
	group := flag.String("group", "", "Name of the SQL cluster group to monitor (required)")
	timeout := flag.Int("t", 30, "Timeout in seconds")
	stateDir := flag.String("state-dir", "/tmp", "Directory for node switch state files")
	eventMinutes := flag.Int("event-minutes", 5, "Time window for failover events (minutes)")
	showVer := flag.Bool("V", false, "Show version and exit")
	flag.Parse()

	if *showVer {
		fmt.Printf("check_win_cluster %s (Go)\n", appVersion)
		os.Exit(nagOK)
	}

	// ---- validations ----
	if *host == "" || *user == "" || *pw == "" || *group == "" {
		nagiosExit(nagUnknown, "UNKNOWN - Required: -H <host> -U <user> -p <password> -group <name>")
	}

	timeoutDur := time.Duration(*timeout) * time.Second

	// ---- connect via WinRM ----
	client, err := connectWinRM(*host, *port, *user, *pw, *useHTTPS, *insecure, timeoutDur, 2)
	if err != nil {
		nagiosExit(nagUnknown, fmt.Sprintf("UNKNOWN - WinRM connection failed: %s", mask(err.Error(), *pw)))
	}

	// ---- execute PowerShell ----
	ctx, cancel := context.WithTimeout(context.Background(), timeoutDur)
	defer cancel()

	psScript := buildPSScript(*eventMinutes)

	// Wrap in powershell.exe invocation
	var stdout, stderr strings.Builder
	exitCodeWinRM, err := client.RunWithContext(ctx, winrm.Powershell(psScript), &stdout, &stderr)
	if err != nil {
		nagiosExit(nagUnknown, fmt.Sprintf("UNKNOWN - WinRM execution failed: %s", mask(err.Error(), *pw)))
	}
	if exitCodeWinRM != 0 {
		stderrStr := strings.TrimSpace(stderr.String())
		if stderrStr == "" {
			stderrStr = "(no stderr)"
		}
		nagiosExit(nagUnknown, fmt.Sprintf("UNKNOWN - PowerShell exited %d: %s", exitCodeWinRM, mask(stderrStr, *pw)))
	}

	// ---- parse JSON ----
	raw := strings.TrimSpace(stdout.String())
	if raw == "" {
		nagiosExit(nagUnknown, "UNKNOWN - Empty response from PowerShell")
	}

	var data ClusterData
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		// Show first 200 chars of output for debugging
		preview := raw
		if len(preview) > 200 {
			preview = preview[:200] + "..."
		}
		nagiosExit(nagUnknown, fmt.Sprintf("UNKNOWN - JSON parse error: %s\nRaw output: %s", err, preview))
	}

	// ---- evaluate ----
	exitCode := nagOK
	var summaryParts []string
	var details []string

	// 1. Nodes
	nodesUp := 0
	totalNodes := len(data.Nodes)
	for _, n := range data.Nodes {
		if strings.EqualFold(n.State, "Up") {
			nodesUp++
		} else {
			exitCode = nagCritical
			details = append(details, fmt.Sprintf("  [CRIT] Nodo %s: %s", n.Name, n.State))
		}
	}
	summaryParts = append(summaryParts, fmt.Sprintf("Cluster: %d/%d nodi up", nodesUp, totalNodes))

	// 2. SQL Group
	var sqlGroup *GroupInfo
	groupsOnline := 0
	for i, g := range data.Groups {
		if strings.EqualFold(g.State, "Online") {
			groupsOnline++
		}
		if strings.EqualFold(g.Name, *group) {
			sqlGroup = &data.Groups[i]
		}
	}

	if sqlGroup == nil {
		exitCode = nagCritical
		summaryParts = append(summaryParts, fmt.Sprintf("SQL %s NON TROVATO", *group))
		details = append(details, fmt.Sprintf("  [CRIT] Gruppo %s non trovato nel cluster", *group))
	} else if !strings.EqualFold(sqlGroup.State, "Online") {
		exitCode = nagCritical
		summaryParts = append(summaryParts, fmt.Sprintf("SQL %s %s su %s", sqlGroup.Name, sqlGroup.State, sqlGroup.OwnerNode))
		details = append(details, fmt.Sprintf("  [CRIT] Gruppo %s: %s (owner: %s)", sqlGroup.Name, sqlGroup.State, sqlGroup.OwnerNode))
	} else {
		summaryParts = append(summaryParts, fmt.Sprintf("SQL %s Online su %s", sqlGroup.Name, sqlGroup.OwnerNode))
	}

	// 3. SQL Resources
	sqlResOK := 0
	sqlResTotal := 0
	for _, r := range data.Resources {
		if strings.EqualFold(r.OwnerGroup, *group) {
			sqlResTotal++
			if strings.EqualFold(r.State, "Online") {
				sqlResOK++
			} else {
				exitCode = nagCritical
				details = append(details, fmt.Sprintf("  [CRIT] Risorsa %s: %s (gruppo %s)", r.Name, r.State, r.OwnerGroup))
			}
		}
	}
	summaryParts = append(summaryParts, fmt.Sprintf("%d/%d risorse OK", sqlResOK, sqlResTotal))

	// 4. Switch detection (state file)
	switchDetected := 0
	if sqlGroup != nil && sqlGroup.OwnerNode != "" {
		sfPath := stateFilePath(*stateDir, *host, *group)
		prevOwner := readPreviousOwner(sfPath)

		if prevOwner != "" && !strings.EqualFold(prevOwner, sqlGroup.OwnerNode) {
			exitCode = nagCritical
			switchDetected = 1
			summaryParts = append(summaryParts, fmt.Sprintf("Switch: da %s a %s", prevOwner, sqlGroup.OwnerNode))
			details = append(details, fmt.Sprintf("  [CRIT] Switch nodo: %s -> %s", prevOwner, sqlGroup.OwnerNode))
		}

		saveCurrentOwner(sfPath, sqlGroup.OwnerNode)
	}

	// 5. Failover events
	eventCount := len(data.Events)
	if eventCount > 0 {
		exitCode = nagCritical
		var eventIDs []string
		seen := make(map[int]bool)
		for _, e := range data.Events {
			if !seen[e.Id] {
				eventIDs = append(eventIDs, fmt.Sprintf("%d", e.Id))
				seen[e.Id] = true
			}
		}
		summaryParts = append(summaryParts, fmt.Sprintf("%d eventi failover", eventCount))
		details = append(details, fmt.Sprintf("  [CRIT] Eventi failover: %d (ID: %s) negli ultimi %d min",
			eventCount, strings.Join(eventIDs, ","), *eventMinutes))
	}

	// 6. Quorum (informative)
	quorumStr := data.Quorum.Type
	if data.Quorum.Resource != "" {
		quorumStr += " (" + data.Quorum.Resource + ")"
	}
	summaryParts = append(summaryParts, fmt.Sprintf("Quorum: %s", quorumStr))

	// ---- build output ----
	summary := fmt.Sprintf("%s - %s", statusText[exitCode], strings.Join(summaryParts, " | "))

	// perfdata
	perfdata := []string{
		fmt.Sprintf("nodes_up=%d;;1;0;%d", nodesUp, totalNodes),
		fmt.Sprintf("groups_online=%d", groupsOnline),
		fmt.Sprintf("sql_resources_ok=%d", sqlResOK),
		fmt.Sprintf("switch_detected=%d", switchDetected),
		fmt.Sprintf("failover_events=%d", eventCount),
	}

	output := summary + " | " + strings.Join(perfdata, " ")
	if len(details) > 0 {
		output += "\n" + strings.Join(details, "\n")
	}

	fmt.Println(output)
	os.Exit(exitCode)
}
