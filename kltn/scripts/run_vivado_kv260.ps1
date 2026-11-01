# Vivado runs for the RV32IF core on the KV260 part. Every run gets its own folders, so no
# run overwrites another:
#   reports/vivado/runs/<yyyyMMdd_HHmmss>_<mode>_<clock>ns/  reports, Vivado logs, run_info.txt
#   build/vivado/runs/<same name>/                            checkpoints, netlist, Vivado temp files
# Mode: full (synthesis + implementation, default), synth (synthesis only),
#       netlist (synthesize `core` and write the functional netlist for xsim),
#       sweep (synthesis only, once per strategy in -Configs, each in its own Vivado session),
#       fullsweep (synthesis + implementation strategies, project mode, fpga/kv260/full_sweep.tcl).
# -Configs (sweep, fullsweep; one value for full/synth/netlist): "<directive>" or "<directive>+retiming", comma-separated (a string or,
#       as PowerShell turns a,b into, an array); empty = the default list below. fullsweep also
#       accepts synthesis strategy names (Flow_PerfOptimized_high, ...).
# -Impl (fullsweep): implementation strategies for stage 2; -Base: auto (best stage-1 synthesis),
#       top<n>, or synthesis configurations; -Jobs: Vivado runs in parallel (each needs ~4.5 GB).
# -Resume (fullsweep): an earlier fullsweep run folder name (e.g. 20261024_012046_fullsweep_6.5ns)
#       or its sweep.xpr; completed runs of that project are reused, the rest run again.
param(
    [Parameter(Position=0)] [double]$ClockNs = 10.0,
    [Parameter(Position=1)] [ValidateSet("full", "synth", "netlist", "sweep", "fullsweep")] [string]$Mode = "full",
    [Parameter(Position=2)] [string]$VivadoBat = "D:\Xilinx\Vivado\2022.2\bin\vivado.bat",
    [string[]]$Configs = @(),
    [string[]]$Impl = @(),
    [string[]]$Base = @("auto"),
    [int]$Jobs = 2,
    [string]$Resume = ""
)
# Every synth_design directive Vivado 2022.2 accepts (list_property_value
# STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE: 12 values; help synth_design describes the first 10),
# plus retiming on the default and the timing-driven directive.
$DefaultSweep = @("default", "runtimeoptimized", "AreaOptimized_high", "AreaOptimized_medium",
                  "AlternateRoutability", "AreaMapLargeShiftRegToBRAM", "AreaMultThresholdDSP",
                  "FewerCarryChains", "PerformanceOptimized", "LogicCompaction",
                  "PowerOptimized_high", "PowerOptimized_medium",
                  "default+retiming", "PerformanceOptimized+retiming")
# fullsweep stage 1: the 8 synthesis strategies of 2022.2 (UG901 "Vivado Preconfigured Strategies"),
# the directives no strategy uses, and retiming on the three timing-oriented choices.
$DefaultFullSynth = @("default", "Flow_PerfOptimized_high", "Flow_PerfThresholdCarry",
                      "Flow_AlternateRoutability", "Flow_AreaOptimized_high", "Flow_AreaOptimized_medium",
                      "Flow_AreaMultThresholdDSP", "Flow_RuntimeOptimized",
                      "PerformanceOptimized", "LogicCompaction", "AreaMapLargeShiftRegToBRAM",
                      "PowerOptimized_high", "PowerOptimized_medium",
                      "default+retiming", "PerformanceOptimized+retiming", "Flow_PerfOptimized_high+retiming")
# fullsweep stage 2: the 33 implementation strategies of 2022.2 (UG904) without the 6 for
# multi-die (SSI) devices, which the single-die KV260 part does not have.
$DefaultFullImpl = @("default",
                     "Performance_Explore", "Performance_ExplorePostRoutePhysOpt", "Performance_ExploreWithRemap",
                     "Performance_WLBlockPlacement", "Performance_WLBlockPlacementFanoutOpt",
                     "Performance_EarlyBlockPlacement", "Performance_NetDelay_high", "Performance_NetDelay_low",
                     "Performance_Retiming", "Performance_ExtraTimingOpt", "Performance_RefinePlacement",
                     "Performance_Auto_1", "Performance_Auto_2", "Performance_Auto_3",
                     "Congestion_SpreadLogic_high", "Congestion_SpreadLogic_medium", "Congestion_SpreadLogic_low",
                     "Area_Explore", "Area_ExploreSequential", "Area_ExploreWithRemap",
                     "Power_DefaultOpt", "Power_ExploreArea",
                     "Flow_RunPhysOpt", "Flow_RunPostRoutePhysOpt", "Flow_RuntimeOptimized", "Flow_Quick")

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kltnRoot = Split-Path -Parent $scriptDir
$tclName = @{ sweep = "synth_sweep.tcl"; fullsweep = "full_sweep.tcl" }[$Mode]
if (-not $tclName) { $tclName = "implement_core_if.tcl" }
$tclScript = Join-Path $kltnRoot "fpga\kv260\$tclName"
if (-not (Test-Path -LiteralPath $VivadoBat)) { throw "Vivado launcher not found: $VivadoBat" }
if (-not (Test-Path -LiteralPath $tclScript)) { throw "Vivado Tcl script not found: $tclScript" }

$clockArg = $ClockNs.ToString([System.Globalization.CultureInfo]::InvariantCulture)
$baseName = "{0}_{1}_{2}ns" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $Mode, $clockArg
# Two runs started in the same second with the same mode and clock get _2, _3, ...
$runName = $baseName
for ($n = 2; Test-Path -LiteralPath (Join-Path $kltnRoot "reports\vivado\runs\$runName"); $n++) {
    $runName = "${baseName}_$n"
}
$reportDir = Join-Path $kltnRoot "reports\vivado\runs\$runName"
$runDir = Join-Path $kltnRoot "build\vivado\runs\$runName"
New-Item -ItemType Directory -Force $reportDir, $runDir | Out-Null
$summary = switch ($Mode) {
    "full"    { Join-Path $reportDir "run_summary.txt" }
    "synth"   { Join-Path $reportDir "post_synth_summary.txt" }
    "netlist" { Join-Path $runDir "netlist\core_funcsim.v" }
    "sweep"   { Join-Path $reportDir "sweep_summary.txt" }
    "fullsweep" { Join-Path $reportDir "full_sweep_summary.txt" }
}
$list = @($Configs -join "," -split "[,\s]+" | Where-Object { $_ })
if ($Mode -eq "sweep" -and $list.Count -eq 0) { $list = $DefaultSweep }
if ($Mode -eq "fullsweep" -and $list.Count -eq 0) { $list = $DefaultFullSynth }
$implList = @($Impl -join "," -split "[,\s]+" | Where-Object { $_ })
if ($implList.Count -eq 0) { $implList = $DefaultFullImpl }

# What was built: mode, clock, strategies, and the RTL version (git commit + uncommitted files).
$started = Get-Date
$info = @("mode        : $Mode", "clock       : $clockArg ns", "started     : $($started.ToString('yyyy-MM-dd HH:mm:ss'))",
          "tcl         : $tclScript", "vivado      : $VivadoBat", "reports+log : $reportDir", "build       : $runDir")
if ($Mode -eq "sweep") { $info += "configs     : $($list -join ', ')" }
if ($Mode -eq "fullsweep") {
    $info += "synthesis   : $($list -join ', ')"
    $info += "impl        : $($implList -join ', ')"
    $info += "stage-2 base: $($Base -join ', ') ; parallel runs: $Jobs"
}
try {
    $commit = (& git -C $kltnRoot log -1 --format="%h %ad %s" --date=format:"%Y-%m-%d %H:%M" 2>$null)
    $dirty = @(& git -C $kltnRoot status --short -- rtl fpga 2>$null)
    $info += "git commit  : $commit"
    $info += "uncommitted : $(if ($dirty.Count) { "$($dirty.Count) file(s) in rtl/ fpga/ (listed below)" } else { 'none in rtl/ fpga/' })"
    $info += $dirty | ForEach-Object { "    $_" }
} catch {
    $info += "git         : not available"
}
$infoPath = Join-Path $reportDir "run_info.txt"
$info | Set-Content -LiteralPath $infoPath -Encoding utf8

$what = @{ full = "synthesis and implementation"; synth = "synthesis only";
           netlist = "synthesis of core + functional netlist for xsim";
           sweep = "synthesis sweep, one Vivado session per strategy";
           fullsweep = "synthesis + implementation strategy sweep (project mode)" }[$Mode]
Write-Host "Running Vivado 2022.2 batch: $what (mode $Mode), clock $clockArg ns"
Write-Host "Run folder : $reportDir"
Write-Host "Build files: $runDir"

# Run one Vivado batch session (cwd = build folder, which receives .Xil and crash dumps);
# its log and journal go to the report folder. Returns $null on success or an error message.
function Invoke-Vivado([string[]]$TclArgs, [string]$LogName) {
    $log = Join-Path $reportDir "$LogName.log"
    Write-Host "Log: $log"
    Push-Location $runDir
    try {
        # Out-Host: show Vivado's output instead of returning it from the function.
        & $VivadoBat -mode batch -source $tclScript -log $log `
            -journal (Join-Path $reportDir "$LogName.jou") -tclargs @TclArgs | Out-Host
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -eq -1073741819) {
        return "Vivado crashed with Windows exception 0xC0000005 (access violation). See hs_err_pid*.log/.dmp " +
               "in $runDir. This has happened when the removable drive holding Vivado was not mounted correctly; " +
               "check D:\Xilinx first."
    }
    if ($LASTEXITCODE -ne 0) { return "Vivado exited with code $LASTEXITCODE (see $log)" }
    return $null
}

$status = "completed"
if ($Mode -eq "sweep") {
    Write-Host "Configurations ($($list.Count)): $($list -join ', ')"
    $rows = Join-Path $reportDir "rows.csv"
    $failed = @()
    $i = 0
    foreach ($cfg in $list) {
        $i++
        Write-Host ""
        Write-Host "===== [$i/$($list.Count)] $cfg ====="
        $err = Invoke-Vivado @($clockArg, $cfg, $reportDir, $runDir) ("vivado_" + ($cfg -replace '\+', '_'))
        if ($err) { Write-Host "ERROR: $cfg : $err"; $failed += $cfg }
    }
    # Comparison table from the rows each session appended, best estimated WNS first.
    $header = "config,WNS_ns,TNS_ns,failing_endpoints,LUTs,FFs,CARRY8,DSPs,worst_path_levels,synth_seconds"
    $data = if (Test-Path -LiteralPath $rows) { @(Import-Csv -LiteralPath $rows -Header ($header -split ",")) } else { @() }
    $data | Export-Csv -LiteralPath (Join-Path $reportDir "sweep_summary.csv") -NoTypeInformation
    $fmt = "{0,-32} {1,8} {2,9} {3,6} {4,7} {5,6} {6,6} {7,4} {8,6} {9,7}"
    $out = @("Synthesis sweep: core_timing_wrap, xck26-sfvc784-2LV-c, clock $clockArg ns, Vivado 2022.2",
             "One Vivado session per configuration. Timing is the post-synthesis estimate (unplaced, wire",
             "delays from fanout). Use routed timing (mode full) for Fmax.", "",
             ($fmt -f "config", "WNS(ns)", "TNS(ns)", "fail", "LUTs", "FFs", "CARRY8", "DSP", "levels", "time(s)"))
    foreach ($r in ($data | Sort-Object { [double]$_.WNS_ns } -Descending)) {
        $out += $fmt -f $r.config, $r.WNS_ns, $r.TNS_ns, $r.failing_endpoints, $r.LUTs, $r.FFs, $r.CARRY8,
                        $r.DSPs, $r.worst_path_levels, $r.synth_seconds
    }
    foreach ($c in $failed) { $out += ("{0,-32} ERROR (see vivado_{1}.log)" -f $c, ($c -replace '\+', '_')) }
    $out += ""
    $out += "Per-configuration reports: $reportDir\<config>\"
    $out | Set-Content -LiteralPath $summary -Encoding utf8
    if ($failed.Count) { $status = "completed with $($failed.Count) failed configuration(s): $($failed -join ', ')" }
} elseif ($Mode -eq "fullsweep") {
    # The lists go through a plan file: cmd.exe would split them at commas on the command line.
    $plan = Join-Path $reportDir "plan.txt"
    $lines = @("jobs $Jobs", "base $($Base -join ',')") + ($list | ForEach-Object { "synth $_" }) + ($implList | ForEach-Object { "impl $_" })
    if ($Resume) {
        $xpr = if ($Resume -like "*.xpr") { $Resume } else {
            Join-Path $kltnRoot "build\vivado\runs\$(Split-Path -Leaf $Resume)\proj\sweep.xpr" }
        if (-not (Test-Path -LiteralPath $xpr)) { throw "Project to resume not found: $xpr" }
        Write-Host "Resuming project: $xpr"
        Add-Content -LiteralPath $infoPath -Encoding utf8 -Value "resumes     : $xpr"
        $lines += "resume $($xpr -replace '\\', '/')"
    }
    $lines | Set-Content -LiteralPath $plan -Encoding ascii
    $runs = $list.Count + $(if (($Base -join ",") -match '^(auto|top1)$') { $implList.Count - 1 } else { 0 })
    Write-Host "Synthesis configurations: $($list.Count); implementation strategies: $($implList.Count); about $runs routed runs, $Jobs at a time"
    $err = Invoke-Vivado @($clockArg, $plan, $reportDir, $runDir) "vivado"
    if ($err) { $status = "FAILED: $err" }
} else {
    # full / synth / netlist: -Configs may name one synthesis configuration ("<directive>[+retiming]").
    if ($list.Count -gt 1) { throw "Mode $Mode takes one -Configs value, got: $($list -join ', ')" }
    $tclArgs = @($clockArg, $Mode, $reportDir, $runDir) + $list
    if ($list.Count) { Add-Content -LiteralPath $infoPath -Encoding utf8 -Value "synthesis   : $($list[0])" }
    $err = Invoke-Vivado $tclArgs "vivado"
    if ($err) { $status = "FAILED: $err" }
}
if (-not $err -and -not (Test-Path -LiteralPath $summary)) {
    $status = "FAILED: Vivado returned without producing $summary"
}
Add-Content -LiteralPath $infoPath -Encoding utf8 -Value @(
    "finished    : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  ($([int]((Get-Date) - $started).TotalMinutes) min)",
    "status      : $status")
if ($status -like "FAILED*") { throw "$status`nRun folder: $reportDir" }

Write-Host ""
if ($Mode -eq "netlist") {
    Write-Host "Netlist: $summary"
    Write-Host "Simulate it (WSL): python3 scripts/run_act4_netlist.py   (uses the newest netlist run)"
} else {
    Get-Content -LiteralPath $summary
}
Write-Host ""
Write-Host "Run folder (reports, logs, run_info.txt): $reportDir"
