# Standalone PowerShell 7 label parser tests. DOES NOT TOUCH Desktop\A or Desktop\B.
[CmdletBinding()]
param([string]$ScriptPath = (Join-Path $PSScriptRoot 'Build-Cnc-Dxf-Global-Pairs-Safe-Labels-v2.ps1'))
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$sizeTolerance = 0.1
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Script missing: $ScriptPath" }
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    foreach ($error in $errors) { Write-Host $error.Message -ForegroundColor Red }
    throw "PowerShell syntax errors: $($errors.Count)"
}
foreach ($functionName in @('Parse-FeatureLabel','Get-TableNumber','Assert-ZNotchFitsPart')) {
    $f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName }, $true)
    if ($null -eq $f) { throw "Cannot locate required function: $functionName" }
    . ([scriptblock]::Create($f.Extent.Text))
}
$cases = @(
    @{ L='SH'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L='Z'; O=$true; S=$false; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='sh'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32 }
    @{ L='z'; O=$true; S=$false; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='SH_Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='Z_SH'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='sh_Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='Z_sH'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='SH-Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='Z-SH'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32 }
    @{ L='01_SH100'; O=$true; S=$true; Z=$false; Offset=100; Long=66; Short=32 }
    @{ L='02_300SH100_Z'; O=$true; S=$true; Z=$true; Offset=100; Long=66; Short=32; Prefix=300 }
    @{ L='SH25_Z'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=32 }
    @{ L='SH25.5_Z'; O=$true; S=$true; Z=$true; Offset=25.5; Long=66; Short=32 }
    @{ L='SH25,5_Z'; O=$true; S=$true; Z=$true; Offset=25.5; Long=66; Short=32 }
    @{ L='300SH25.5_80.25Z40.75'; O=$true; S=$true; Z=$true; Offset=25.5; Long=80.25; Short=40.75; Prefix=300 }
    @{ L='80Z40_300SH25'; O=$true; S=$true; Z=$true; Offset=25; Long=80; Short=40; Prefix=300 }
    @{ L='Z40_SH25'; O=$true; S=$true; Z=$true; Offset=25; Long=66; Short=40 }
    @{ L='SH_80Z'; O=$true; S=$true; Z=$true; Offset=18; Long=80; Short=32 }
    @{ L='SH_Z40'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=40 }
    @{ L='SH_80Z40'; O=$true; S=$true; Z=$true; Offset=18; Long=80; Short=40 }
    @{ L='300SH25-80Z40'; O=$true; S=$true; Z=$true; Offset=25; Long=80; Short=40; Prefix=300 }
    @{ L='02_z40_sH25.25'; O=$true; S=$true; Z=$true; Offset=25.25; Long=66; Short=40 }
    @{ L='SH_0.5Z0.25'; O=$true; S=$true; Z=$true; Offset=18; Long=0.5; Short=0.25 }
    @{ L='300.5SH_Z'; O=$true; S=$true; Z=$true; Offset=18; Long=66; Short=32; Prefix=300.5 }
    @{ L='300SH'; O=$true; S=$true; Z=$false; Offset=18; Long=66; Short=32; Prefix=300 }
    @{ L='SH25._Z'; O=$false }
    @{ L='SH.5_Z'; O=$false }
    @{ L='SH-25_Z'; O=$false }
    @{ L='SH25.5.5_Z'; O=$false }
    @{ L='SH_Z0'; O=$false }
    @{ L='SH_0Z40'; O=$false }
    @{ L='Z0_SH'; O=$false }
    @{ L='SH0_Z'; O=$false }
    @{ L='0SH_Z'; O=$false }
    @{ L='SH_SH_Z'; O=$false }
    @{ L='Z_Z_SH'; O=$false }
    @{ L='Z_SH_300SH'; O=$false }
    @{ L='SH_Z_EXTRA'; O=$false }
    @{ L='SH__Z'; O=$false }
    @{ L='SHZ'; O=$false }
    @{ L='SHABC_Z'; O=$false }
    @{ L='WASH_Z'; O=$false }
    @{ L='SH_Z-'; O=$false }
    @{ L='SH_-Z'; O=$false }
    @{ L='-SH_Z'; O=$false }
    @{ L='SH_80Z0'; O=$false }
    @{ L='SH_80Z40_SH'; O=$false }
)
$passed = 0; $failed = 0
foreach ($c in $cases) {
    $errorText = $null; $got = $null
    try { $got = Parse-FeatureLabel -Label $c.L } catch { $errorText = $_.Exception.Message }
    $ok = ($c.O -eq ($null -ne $got))
    if ($ok -and $null -ne $got) {
        $ok = $got.HasSH -eq $c.S -and $got.HasZ -eq $c.Z
        $ok = $ok -and [math]::Abs($got.GrooveOffset - $c.Offset) -lt 0.00001
        $ok = $ok -and [math]::Abs($got.LongLength - $c.Long) -lt 0.00001
        $ok = $ok -and [math]::Abs($got.ShortLength - $c.Short) -lt 0.00001
        if ($c.ContainsKey('Prefix')) { $ok = $ok -and [math]::Abs($got.Prefix - $c.Prefix) -lt 0.00001 }
        else { $ok = $ok -and $null -eq $got.Prefix }
    }
    if ($ok) { $passed++ } else { $failed++; Write-Host "FAILED: $($c.L), expected valid=$($c.O), observed=$($null -ne $got), error=$errorText" -ForegroundColor Red }
}
$shape = [pscustomobject]@{ Width = 300.0; Height = 800.0 }
$zChecks = @(
    @{ Label='SH_799.99Z299.99'; Table=2; Long=799.99; Short=299.99; Accept=$true }
    @{ Label='SH_800Z40'; Table=2; Long=800; Short=40; Accept=$false }
    @{ Label='SH_799Z300'; Table=2; Long=799; Short=300; Accept=$false }
    @{ Label='300SH_299.99Z799.99'; Table=1; Long=299.99; Short=799.99; Accept=$true }
    @{ Label='300SH_300Z50'; Table=1; Long=300; Short=50; Accept=$false }
    @{ Label='300SH_200Z800'; Table=1; Long=200; Short=800; Accept=$false }
    @{ Label='SH_9999Z40'; Table=2; Long=9999; Short=40; Accept=$false }
)
foreach ($zcheck in $zChecks) {
    $accepted = $true
    $params = [pscustomobject]@{ LongLength = $zcheck.Long; ShortLength = $zcheck.Short }
    try { Assert-ZNotchFitsPart -Shape $shape -Label $zcheck.Label -ZParameters $params -Table $zcheck.Table }
    catch { $accepted = $false }
    if ($accepted -eq $zcheck.Accept) { $passed++ }
    else { $failed++; Write-Host "FAILED Z fit: $($zcheck.Label)" -ForegroundColor Red }
}
Write-Host "Parser tests: $passed passed, $failed failed. (Source syntax check passed.)" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) { throw 'Some label safety tests failed.' }
