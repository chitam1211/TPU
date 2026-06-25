param(
    [ValidateSet("all", "config", "ls", "misc", "ew", "mac", "system")]
    [string] $Only = "all",
    [switch] $Detailed
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Src = Join-Path $RepoRoot "rv32i-pipeline-processor\src"
$Rme = Join-Path $RepoRoot "rme_rtl"
$Sim = Join-Path $RepoRoot "sim"

Push-Location $RepoRoot
try {
New-Item -ItemType Directory -Force -Path $Sim | Out-Null

function Invoke-PythonScript {
    param([string] $Script)

    & python $Script
    if ($LASTEXITCODE -eq 0) {
        return
    }

    & py -3 $Script
    if ($LASTEXITCODE -ne 0) {
        throw "python failed for $Script"
    }
}

function Invoke-IverilogTest {
    param(
        [string] $Name,
        [string[]] $Sources
    )

    $out = Join-Path $Sim "$Name.vvp"
    $compileLog = Join-Path $Sim "$Name.iverilog.log"
    $runLog = Join-Path $Sim "$Name.vvp.log"
    Write-Host "== $Name =="

    $compileArgs = @("iverilog", "-g2012", "-I", $Sim, "-o", $out) + $Sources
    Invoke-LoggedCmd $compileArgs $compileLog
    $compileExit = $LASTEXITCODE
    $compileOutput = Get-Content -Path $compileLog
    Write-FilteredToolOutput $compileOutput $compileLog
    if ($compileExit -ne 0) {
        throw "iverilog failed for $Name"
    }

    $vvpArgs = @("vvp", $out)
    if ($Detailed) {
        $vvpArgs += "+VERBOSE"
    }
    Invoke-LoggedCmd $vvpArgs $runLog
    $runExit = $LASTEXITCODE
    $runOutput = Get-Content -Path $runLog
    Write-FilteredToolOutput $runOutput $runLog
    if ($runExit -ne 0) {
        throw "vvp failed for $Name"
    }
    if ($runOutput | Where-Object { $_ -like "*_TEST_FAIL*" }) {
        throw "testbench reported failure for $Name"
    }
    if (-not ($runOutput | Where-Object { $_ -like "*_TEST_PASS*" })) {
        throw "testbench did not report PASS for $Name"
    }
}

function Quote-CmdArg {
    param([string] $Arg)
    return '"' + ($Arg -replace '"', '\"') + '"'
}

function Invoke-LoggedCmd {
    param(
        [string[]] $CommandArgs,
        [string] $LogPath
    )

    Remove-Item -Force -ErrorAction SilentlyContinue -Path $LogPath

    $cmdLine = $CommandArgs[0]
    if ($CommandArgs.Count -gt 1) {
        $cmdLine = $cmdLine + " " + (($CommandArgs[1..($CommandArgs.Count - 1)] | ForEach-Object { Quote-CmdArg $_ }) -join " ")
    }
    $cmdLine = "$cmdLine > $(Quote-CmdArg $LogPath) 2>&1"
    & cmd.exe /d /c $cmdLine
}

function Test-BenignIcarusLine {
    param([string] $Line)

    return (
        $Line -like "*sorry: constant selects in always_* processes are not currently supported*" -or
        $Line -like "*vvp.tgt sorry: Case unique/unique0 qualities are ignored.*" -or
        $Line -like "VCD info:*" -or
        $Line -like "*`$finish called at*" -or
        $Line -eq "(all bits will be included)." -or
        $Line -eq "bits will be included)."
    )
}

function Write-FilteredToolOutput {
    param(
        [object[]] $Output,
        [string] $LogPath
    )

    $suppressed = 0
    foreach ($entry in $Output) {
        $line = [string] $entry
        if (Test-BenignIcarusLine $line) {
            $suppressed++
        } elseif ($line.Length -gt 0) {
            Write-Host $line
        }
    }

    $null = $suppressed
}

function Should-Run {
    param([string] $Name)
    return ($Only -eq "all" -or $Only -eq $Name)
}

function Write-InstructionCoverage {
    param([string] $Target)

    $asmReport = Join-Path $Sim "golden\generated_assembly.txt"
    if (-not (Test-Path $asmReport)) {
        return
    }

    $lines = Get-Content -Path $asmReport
    $groups = @("config", "ls", "misc", "ew", "mac")
    $currentGroup = ""
    $selected = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $lines) {
        $line = [string] $entry
        if ($line -match "^\[(.+)\]$") {
            $currentGroup = $Matches[1]
            continue
        }

        if ($line.Trim().Length -eq 0) {
            continue
        }
        if ($line -like "Expected files are generated*") {
            continue
        }

        if ($Target -eq "all") {
            if ($groups -contains $currentGroup) {
                $selected.Add("[$currentGroup] $line")
            }
        } elseif ($Target -eq $currentGroup) {
            $selected.Add("[$currentGroup] $line")
        }
    }

    if ($selected.Count -gt 0) {
        Write-Host "== matrix instruction coverage =="
        foreach ($line in $selected) {
            Write-Host $line
        }
        Write-Host "== total matrix instructions listed: $($selected.Count) =="
    } elseif ($Target -eq "system") {
        Write-Host "== matrix instruction coverage =="
        Write-Host "[system] smoke test only; run .\mt.cmd all to list all module-level instruction tests"
    }
}

$matrixCoreSources = @(
    (Join-Path $Rme "matrix_core_v2.sv"),
    (Join-Path $Rme "matrix_dispatch.sv"),
    (Join-Path $Rme "matrix_tile_ls.sv"),
    (Join-Path $Rme "matrix_mac_v2.sv"),
    (Join-Path $Rme "matrix_misc.sv"),
    (Join-Path $Rme "matrix_ew.sv"),
    (Join-Path $Rme "matrix_regfile.sv")
)

Invoke-PythonScript (Join-Path $RepoRoot "tools\generate_matrix_iss_golden.py")
Write-InstructionCoverage $Only

if (Should-Run "config") {
    Invoke-IverilogTest "tb_matrix_config_v2" ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_config_v2.sv")))
}
if (Should-Run "ls") {
    Invoke-IverilogTest "tb_matrix_load_store_v2" ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_load_store_v2.sv")))
}
if (Should-Run "misc") {
    Invoke-IverilogTest "tb_matrix_misc_v2" ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_misc_v2.sv")))
}
if (Should-Run "ew") {
    Invoke-IverilogTest "tb_matrix_ew_v2" ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_ew_v2.sv")))
}
if (Should-Run "mac") {
    Invoke-IverilogTest "tb_matrix_mac_v2" ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_mac_v2.sv")))
}

$systemSources = @(
    (Join-Path $Rme "core_matrix.v"),
    (Join-Path $Rme "control_decoder.v"),
    (Join-Path $Rme "memory_stage.v"),
    (Join-Path $Src "adder.v"),
    (Join-Path $Src "alu.v"),
    (Join-Path $Src "branch.v"),
    (Join-Path $Src "control_unit.v"),
    (Join-Path $Src "Decode.v"),
    (Join-Path $Src "Execute.v"),
    (Join-Path $Src "Fetch.v"),
    (Join-Path $Src "immediate_gen.v"),
    (Join-Path $Src "mux1_2.v"),
    (Join-Path $Src "mux2_4.v"),
    (Join-Path $Src "mux3_8.v"),
    (Join-Path $Src "program_counter.v"),
    (Join-Path $Src "register_file.v"),
    (Join-Path $Src "type_decoder.v"),
    (Join-Path $Src "wrapper_memory.v"),
    (Join-Path $Src "Write_back.v"),
    (Join-Path $Src "fetch_pipe.v"),
    (Join-Path $Src "decode_pipe.v"),
    (Join-Path $Src "execute_pipe.v"),
    (Join-Path $Src "memstage_pipe.v")
) + $matrixCoreSources + @((Join-Path $Sim "tb_rv32i_matrix_system.sv"))

if (Should-Run "system") {
    Invoke-IverilogTest "tb_rv32i_matrix_system" $systemSources
}
}
finally {
    Pop-Location
}
