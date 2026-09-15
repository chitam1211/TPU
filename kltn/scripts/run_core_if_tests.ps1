param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $projectRoot 'sim/build'
$logDir = Join-Path $projectRoot 'reports/step3b_20260913'
New-Item -ItemType Directory -Force -Path $buildDir, $logDir | Out-Null
$rtlDir = Join-Path $projectRoot 'rtl/core_if'
$tbDir = Join-Path $projectRoot 'tb/core_if'
$allRtl = @(Get-ChildItem -LiteralPath $rtlDir -Filter '*.v' | ForEach-Object { $_.FullName })
$decoderRtl = @('type_decoder.v','control_decoder.v','control_unit.v') | ForEach-Object { Join-Path $rtlDir $_ }
$cases = @(
    @{ Name='register_file'; Top='tb_register_file'; Sources=@((Join-Path $rtlDir 'register_file.v')); Marker='REGISTER_FILE_TEST_PASS' },
    @{ Name='fp_register_file'; Top='tb_fp_register_file'; Sources=@((Join-Path $rtlDir 'fp_register_file.v')); Marker='FP_REGISTER_FILE_TEST_PASS' },
    @{ Name='alu'; Top='tb_alu'; Sources=@((Join-Path $rtlDir 'alu.v')); Marker='ALU_TEST_PASS' },
    @{ Name='fp_mem_decode'; Top='tb_fp_mem_decode'; Sources=$decoderRtl; Marker='FP_MEM_DECODE_TEST_PASS' },
    @{ Name='fp_mem_e2e'; Top='tb_fp_mem_e2e'; Sources=$allRtl; Marker='FP_MEM_E2E_TEST_PASS' },
    @{ Name='fp_mem_e2e_delayed'; Top='tb_fp_mem_e2e'; Sources=$allRtl; Marker='FP_MEM_E2E_DELAYED_TEST_PASS'; Define='DELAYED_MEMORY' }
)
foreach ($case in $cases) {
    $binary = Join-Path $buildDir ('tb_' + $case.Name)
    $arguments = @('-g2012','-Wall','-Wno-timescale','-s',$case.Top,'-o',$binary)
    if ($case.Define) { $arguments += ('-D' + $case.Define) }
    $arguments += $case.Sources
    $arguments += Join-Path $tbDir ($case.Top + '.v')
    $compileOutput = & iverilog @arguments 2>&1
    $compileExit = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $logDir ($case.Name + '.compile.log')) -Value ($compileOutput -join "`n")
    if ($compileExit -ne 0) { throw "Compile failed: $($case.Name)`n$compileOutput" }
    $runOutput = & vvp $binary 2>&1
    $runExit = $LASTEXITCODE
    $runOutput | Set-Content -LiteralPath (Join-Path $logDir ($case.Name + '.run.log'))
    $outputText = $runOutput -join "`n"
    if ($runExit -ne 0 -or $outputText -notmatch $case.Marker -or $outputText -match '\[FAIL\]|TEST_FAIL|FATAL:') {
        throw "Simulation failed: $($case.Name)`n$outputText"
    }
    Write-Output "$($case.Name): PASS"
}
Write-Output 'CORE_IF_STEP3B_TESTS_PASS (6/6)'
