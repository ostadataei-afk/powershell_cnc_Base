# Stage 3: full OptiCut format integration tests. No Desktop A/B writes.
[CmdletBinding()]
param([string]$ScriptPath = (Join-Path $PSScriptRoot 'Build-Cnc-Dxf-OptiCut-Dual-Format-v4.ps1'))
$ErrorActionPreference = 'Stop'
# Preflight: the DXF fixtures must be next to THIS script, not merely on Desktop.
$requiredFixtures = @(
    'Legacy-One-Part.dxf', 'Legacy-Fifteen-Parts.dxf', 'Layered-Original.dxf',
    'Layered-Pair.dxf', 'Layered-Standalone.dxf', 'Mix-R-Legacy.dxf',
    'Mix-L-Layered.dxf', 'Layered-Missing-Panel.dxf',
    'Layered-Offcenter.dxf', 'Layered-MultiPanel.dxf'
)
$fixturesPath = Join-Path $PSScriptRoot 'TestFixtures'
$samplesPath = Join-Path $PSScriptRoot 'Sample_A_Valid'
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($name in $requiredFixtures) {
    $target = Join-Path $fixturesPath $name
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $missing.Add($target) }
}
if (-not (Test-Path -LiteralPath $samplesPath -PathType Container)) {
    $missing.Add($samplesPath)
} else {
    $sampleFiles = @(Get-ChildItem -LiteralPath $samplesPath -File -Filter '*.dxf')
    if ($sampleFiles.Count -ne 10) { $missing.Add("$samplesPath (expected 10 DXF files; found $($sampleFiles.Count))") }
}
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'TEST FILES MISSING - NO CNC TESTS HAVE RUN.' -ForegroundColor Red
    Write-Host 'Extract the ENTIRE ZIP with Windows Extract All, retaining these folders:' -ForegroundColor Yellow
    Write-Host '  TestFixtures (10 DXF files)' -ForegroundColor Yellow
    Write-Host '  Sample_A_Valid (10 DXF files)' -ForegroundColor Yellow
    Write-Host "They must be beside: $PSCommandPath" -ForegroundColor Yellow
    foreach ($path in $missing) { Write-Host "  Missing: $path" -ForegroundColor Red }
    throw 'Stage 3 test fixtures are missing. Extract the complete ZIP; do not copy only CMD/PS1 files.'
}
Write-Host 'Stage 3 fixture preflight: 10 TestFixtures and 10 Sample_A_Valid DXF files found.' -ForegroundColor Green
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$epsilon = 0.05
$sizeTolerance = 0.1
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) { foreach($err in $errors){Write-Host $err.Message -ForegroundColor Red}; throw "PowerShell parsing failed with $($errors.Count) errors" }
$functionNames=@('New-DxfPair','Add-DxfPair','Get-FirstValue','ConvertFrom-DxfNumber','ConvertTo-DxfNumber','Get-EntityVertices','Get-EntityBounds','Test-RectangleVertices',
 'Read-DxfDocument','Get-DimensionText','Parse-FeatureLabel','Get-TextRecords','Test-TextInsidePart','Get-OptiCutFormat','Test-TextAtPartCenter',
 'Get-Orientation','Get-SymmetryState','Get-TableNumber','Assert-ZNotchFitsPart','Get-TableRule','Get-LayerTableInfo','Test-LayerExists','Add-Layer2',
 'Get-NextHandle','Update-Handseed','Set-PolylineVertices','Get-NotchedVertices','New-SlotLineEntity','ConvertTo-DxfGridNumber','Assert-CncGeometry',
 'Build-DxfPlan','Get-FilenamePairRole','Resolve-GlobalPairs','Apply-DxfPlan','Test-GeneratedDxf')
foreach($name in $functionNames) {
 $node=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 if ($null -eq $node) {throw "Required function missing: $name"}
 . ([scriptblock]::Create($node.Extent.Text))
}
$passed=0; $failed=0
function Check([bool]$Condition,[string]$Message) {if (-not $Condition){throw $Message}}
function Get-Doc([string]$Name) {
 $path=Join-Path $PSScriptRoot "TestFixtures/$Name"
 return (Build-DxfPlan -Document (Read-DxfDocument -File (Get-Item -LiteralPath $path)))
}
function Invoke-Case([string]$Name,[scriptblock]$Body,[string]$ExpectedError='') {
 $errText=$null
 try { & $Body | Out-Null }
 catch {$errText=$_.Exception.Message}
 $good= if($ExpectedError -ne ''){$null -ne $errText -and $errText.Contains($ExpectedError)} else {$null -eq $errText}
 if($good){$script:passed++;Write-Host "PASS $Name" -ForegroundColor Green}
 else{$script:failed++;Write-Host "FAIL $Name :: $errText; expected '$ExpectedError'" -ForegroundColor Red}
}
function Verify-Output([object[]]$Docs) {
 Resolve-GlobalPairs -Documents $Docs
 Assert-CncGeometry -Documents $Docs
 $temp=Join-Path ([System.IO.Path]::GetTempPath()) ('cnc-stage3-'+[guid]::NewGuid().ToString('N'))
 [void](New-Item -ItemType Directory -Path $temp)
 try {
  foreach($doc in $Docs) {
   $plan=Apply-DxfPlan -Document $doc
   $p=Join-Path $temp $plan.OutputName
   [System.IO.File]::WriteAllLines($p,$plan.Lines,[System.Text.UTF8Encoding]::new($false))
   [void](Test-GeneratedDxf -File (Get-Item -LiteralPath $p) -Plan $plan)
  }
 } finally {Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue}
}
Invoke-Case 'Legacy one-part source, dimension + left-edge SH' {
 $d=Get-Doc 'Legacy-One-Part.dxf'
 Check ($d.OptiCutFormat -eq 'Legacy') 'wrong format'
 Check ($d.Parts.Count -eq 1 -and $d.Stats.DimensionCount -eq 1 -and $d.FeatureRecords.Count -eq 1) 'incorrect legacy assignments'
 Verify-Output @($d)
}
Invoke-Case 'Legacy real 15-part file; left-edge dimension matches and pairs' {
 $d=Get-Doc 'Legacy-Fifteen-Parts.dxf'
 Check ($d.OptiCutFormat -eq 'Legacy' -and $d.Parts.Count -eq 15 -and $d.Stats.DimensionCount -eq 15) 'incorrect legacy counts'
 Check ($d.FeatureRecords.Count -eq 15) 'incorrect legacy feature count'
 Verify-Output @($d)
}
Invoke-Case 'Layered real OptiCut DXF, 22 Parts, 11 Off-Cuts, 12 non-CNC labels' {
 $d=Get-Doc 'Layered-Original.dxf'
 Check ($d.OptiCutFormat -eq 'Layered') 'wrong format'
 Check ($d.Parts.Count -eq 22 -and $d.Stats.DimensionCount -eq 0 -and $d.FeatureRecords.Count -eq 0) 'unlabeled parts or offcuts incorrectly classified'
 Check ($d.StockSheet.Handle -eq '16') 'wrong Panel outline selected'
 Verify-Output @($d)
}
Invoke-Case 'Layered, two centered SH+Z labels on different-size Parts' {
 $d=Get-Doc 'Layered-Pair.dxf'
 Check ($d.FeatureRecords.Count -eq 2 -and $d.Parts.Count -eq 22) 'bad feature assignment'
 Check ($d.FeatureRecords[0].Shape.Handle -ne $d.FeatureRecords[1].Shape.Handle) 'both labels attached to same part'
 Verify-Output @($d)
}
Invoke-Case 'Layered standalone decimal SH on a 60mm wide part' {
 $d=Get-Doc 'Layered-Standalone.dxf'
 Check ($d.FeatureRecords.Count -eq 1) 'failed to parse small part or decimal offset'
 Check ([math]::Abs($d.FeatureRecords[0].GrooveOffset - 12.5) -lt 0.001) 'wrong decimal offset'
 Check ([math]::Abs($d.FeatureRecords[0].Shape.Width - 60) -lt 0.001) 'wrong part assignment'
 Verify-Output @($d)
}
Invoke-Case 'Global pair across Legacy-R and Layered-L files' {
 $a=Get-Doc 'Mix-R-Legacy.dxf'; $b=Get-Doc 'Mix-L-Layered.dxf'
 Check ($a.FeatureRecords.Count -eq 1 -and $b.FeatureRecords.Count -eq 1) 'incorrect number of labels'
 # Deliberately order L first: explicit filename markers must override order.
 Verify-Output @($b,$a)
 Check ($a.FeatureRecords[0].Role -eq 'R' -and $b.FeatureRecords[0].Role -eq 'L') 'file-name role precedence lost'
}
Invoke-Case 'Reject Panel missing despite Parts being present' { $null=Get-Doc 'Layered-Missing-Panel.dxf' } 'Incomplete layered OptiCut format'
Invoke-Case 'Reject feature label significantly away from part center' { $null=Get-Doc 'Layered-Offcenter.dxf' } 'matches 0 parts'
Invoke-Case 'Reject two Panel rectangles' { $null=Get-Doc 'Layered-MultiPanel.dxf' } 'exactly one rectangular Panel outline'
Invoke-Case 'All 10 baseline CNC files from stage 2 in a single validated batch' {
 $folder=Join-Path $PSScriptRoot 'Sample_A_Valid'
 $docs=[System.Collections.Generic.List[object]]::new()
 foreach($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.dxf' -File | Sort-Object Name)) {
  $docs.Add((Build-DxfPlan (Read-DxfDocument $file)))
 }
 Check ($docs.Count -eq 10) 'Expected 10 regression files'
 Verify-Output $docs.ToArray()
}
Write-Host "`nStage 3 integration tests: $passed passed, $failed failed." -ForegroundColor $(if($failed -eq 0){'Green'}else{'Red'})
if ($failed -gt 0) {throw 'Stage 3 tests FAILED'}
