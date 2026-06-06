$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Src = Join-Path $RepoRoot "rv32i-pipeline-processor\src"
$Rme = Join-Path $RepoRoot "rme_rtl"
$Sim = Join-Path $RepoRoot "sim"

function Invoke-IverilogTest {
    param(
        [string] $Name,
        [string[]] $Sources
    )

    $out = Join-Path $Sim "$Name.vvp"
    Write-Host "== $Name =="
    & iverilog -g2012 -I $Sim -o $out @Sources
    if ($LASTEXITCODE -ne 0) {
        throw "iverilog failed for $Name"
    }
    & vvp $out
    if ($LASTEXITCODE -ne 0) {
        throw "vvp failed for $Name"
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

Invoke-IverilogTest "tb_matrix_config_v2"     ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_config_v2.sv")))
Invoke-IverilogTest "tb_matrix_load_store_v2" ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_load_store_v2.sv")))
Invoke-IverilogTest "tb_matrix_misc_v2"       ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_misc_v2.sv")))
Invoke-IverilogTest "tb_matrix_ew_v2"         ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_ew_v2.sv")))
Invoke-IverilogTest "tb_matrix_mac_v2"        ($matrixCoreSources + @((Join-Path $Sim "tb_matrix_mac_v2.sv")))

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

Invoke-IverilogTest "tb_rv32i_matrix_system" $systemSources
