# Vivado 2022.2 build of the SoC block design (fpga/soc_xif/tcl/build_soc_xif.tcl): Zynq PS +
# SmartConnect + 2 AXI BRAM Controllers + 2 true dual-port BRAMs + rv32if_xif_soc (CV-X-IF core +
# matrix coprocessor). Every run gets its own folders, as with run_vivado_kv260.ps1:
#   reports/vivado/runs/<yyyyMMdd_HHmmss>_soc_xif_<mode>_<mhz>MHz/  soc_summary.txt, address_map.txt,
#                                                                   *.rpt, Vivado log, run_info.txt
#   build/vivado/runs/<same name>/                                  proj/ (Vivado project), out/ (.bit .bin .hwh .xsa)
# Mode: full (bitstream + board files, default), impl (route + reports, no bitstream),
#       bd (project + block design only, to open in the GUI).
#   .\scripts\run_vivado_soc_xif.ps1                    # 100 MHz, full
#   .\scripts\run_vivado_soc_xif.ps1 100 impl           # timing / utilization only
#   .\scripts\run_vivado_soc_xif.ps1 100 full -Board kv260 -Strategy Performance_Explore
param(
    [Parameter(Position=0)] [int]$ClockMHz = 100,
    [Parameter(Position=1)] [ValidateSet("full", "impl", "bd")] [string]$Mode = "full",
    [ValidateSet("kr260", "kv260")] [string]$Board = "kr260",
    [string]$Strategy = "default",
    [string]$VivadoBat = "D:\Xilinx\Vivado\2022.2\bin\vivado.bat"
)
$ErrorActionPreference = "Stop"
$kltnRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tclScript = Join-Path $kltnRoot "fpga\soc_xif\tcl\build_soc_xif.tcl"
if (-not (Test-Path -LiteralPath $VivadoBat)) { throw "Vivado launcher not found: $VivadoBat" }
if (-not (Test-Path -LiteralPath $tclScript)) { throw "Vivado Tcl script not found: $tclScript" }

$baseName = "{0}_soc_xif_{1}_{2}MHz" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $Mode, $ClockMHz
$runName = $baseName
for ($n = 2; Test-Path -LiteralPath (Join-Path $kltnRoot "reports\vivado\runs\$runName"); $n++) {
    $runName = "${baseName}_$n"
}
$reportDir = Join-Path $kltnRoot "reports\vivado\runs\$runName"
$runDir = Join-Path $kltnRoot "build\vivado\runs\$runName"
New-Item -ItemType Directory -Force $reportDir, $runDir | Out-Null
$summary = if ($Mode -eq "bd") { Join-Path $reportDir "address_map.txt" } else { Join-Path $reportDir "soc_summary.txt" }

$started = Get-Date
$info = @("design      : rv32if_xif_soc block design (fpga/soc_xif/tcl/build_soc_xif.tcl)",
          "mode        : $Mode", "board       : $Board", "pl_clk0     : $ClockMHz MHz", "impl        : $Strategy",
          "started     : $($started.ToString('yyyy-MM-dd HH:mm:ss'))", "vivado      : $VivadoBat",
          "reports+log : $reportDir", "build       : $runDir")
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

Write-Host "Running Vivado 2022.2 batch: SoC block design, mode $Mode, $ClockMHz MHz, board $Board"
Write-Host "Run folder : $reportDir"
Write-Host "Build files: $runDir"
$log = Join-Path $reportDir "vivado.log"
Write-Host "Log: $log"
Push-Location $runDir
try {
    & $VivadoBat -mode batch -source $tclScript -log $log -journal (Join-Path $reportDir "vivado.jou") `
        -tclargs $ClockMHz $Mode $reportDir $runDir $Board $Strategy | Out-Host
} finally {
    Pop-Location
}
$status = "completed"
if ($LASTEXITCODE -eq -1073741819) {
    $status = "FAILED: Vivado crashed with 0xC0000005 (access violation); check that D:\Xilinx is mounted"
} elseif ($LASTEXITCODE -ne 0) {
    $status = "FAILED: Vivado exited with code $LASTEXITCODE (see $log)"
} elseif (-not (Test-Path -LiteralPath $summary)) {
    $status = "FAILED: Vivado returned without producing $summary"
}
Add-Content -LiteralPath $infoPath -Encoding utf8 -Value @(
    "finished    : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  ($([int]((Get-Date) - $started).TotalMinutes) min)",
    "status      : $status")
if ($status -like "FAILED*") { throw "$status`nRun folder: $reportDir" }

Write-Host ""
Get-Content -LiteralPath $summary
Write-Host ""
Write-Host "Run folder (reports, logs, run_info.txt): $reportDir"
if ($Mode -eq "full") { Write-Host "Board files (.bit .bin .hwh .xsa): $(Join-Path $runDir 'out')" }
if ($Mode -eq "bd")   { Write-Host "Project: $(Join-Path $runDir 'proj\soc.xpr')" }
