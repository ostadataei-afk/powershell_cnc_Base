# Stage 2 geometry validator tests. Does NOT touch Desktop\A or Desktop\B.
[CmdletBinding()]
param([string]$ScriptPath = (Join-Path $PSScriptRoot 'Build-Cnc-Dxf-Global-Pairs-Geometry-Safe-v3.1.ps1'))
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$epsilon = 0.05
$sizeTolerance = 0.1
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Missing CNC script: $ScriptPath" }
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) { foreach ($e in $errors) { Write-Host $e.Message -ForegroundColor Red }; throw "PowerShell syntax errors: $($errors.Count)" }
foreach ($name in @('New-DxfPair','Add-DxfPair','Get-FirstValue','ConvertFrom-DxfNumber','ConvertTo-DxfNumber','Get-NotchedVertices','New-SlotLineEntity','Get-TableRule','ConvertTo-DxfGridNumber','Assert-CncGeometry')) {
    $node = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if ($null -eq $node) { throw "Missing required function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function New-TestPart {
    param([string]$Handle,[double]$MinX,[double]$MinY,[double]$Width,[double]$Height)
    [pscustomobject]@{Handle=$Handle;MinX=$MinX;MaxX=($MinX+$Width);MinY=$MinY;MaxY=($MinY+$Height);Width=$Width;Height=$Height}
}
function New-TestRecord {
    param([object]$Shape,[string]$Label,[int]$Table=2,[string]$State='NN',[string]$Role='R',[double]$Offset=18,[double]$Long=66,[double]$Short=32,[bool]$WithZ=$true,[bool]$WithSH=$true)
    $rule = Get-TableRule -Table $Table -State $State -Role $Role
    [pscustomobject]@{Shape=$Shape;Label=$Label;Table=$Table;Corner=$rule.Corner;GrooveEdge=$rule.Groove;GrooveOffset=$Offset;NotchLongLength=$Long;NotchShortLength=$Short;HasZ=$WithZ;HasSH=$WithSH}
}
function New-TestDocument {
    param([object]$Sheet,[object[]]$Parts,[object[]]$Records,[string]$Name='geometry-test.dxf')
    [pscustomobject]@{File=[pscustomobject]@{Name=$Name};StockSheet=$Sheet;Parts=$Parts;FeatureRecords=$Records}
}
$passed = 0; $failed = 0
function Invoke-Test {
    param([string]$Name,[object]$Doc,[bool]$ShouldPass,[string]$ExpectedError='')
    if (-not $ShouldPass -and [string]::IsNullOrWhiteSpace($ExpectedError)) {
        throw "Negative test '$Name' must declare the specific error it expects."
    }
    $errorText = $null
    try { Assert-CncGeometry -Documents @($Doc) | Out-Null; $accepted = $true }
    catch { $accepted = $false; $errorText = $_.Exception.Message }
    # A negative test only passes when validation rejects the correct defect.
    # Rejecting a file for an unrelated bug (such as the wrong Z vertex count)
    # must NOT result in a passing test.
    $correctFailure = (-not $accepted) -and ($errorText -like ('*' + $ExpectedError + '*'))
    $success = if ($ShouldPass) { $accepted } else { $correctFailure }
    if ($success) { $script:passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    else {
        $script:failed++
        if ($accepted) { Write-Host "FAIL $Name :: unexpectedly accepted" -ForegroundColor Red }
        else { Write-Host "FAIL $Name :: expected '$ExpectedError'; actual '$errorText'" -ForegroundColor Red }
    }
}
$sheet = New-TestPart -Handle 'SHEET' -MinX 0 -MinY 0 -Width 2100 -Height 1400
$r = New-TestPart -Handle 'R' -MinX 100 -MinY 150 -Width 800 -Height 300
$l = New-TestPart -Handle 'L' -MinX 1050 -MinY 150 -Width 800 -Height 300
$normal = @((New-TestRecord -Shape $r -Label 'SH_Z' -Role 'R'),(New-TestRecord -Shape $l -Label 'SH_Z' -Role 'L'))
Invoke-Test 'Normal paired SH+Z' (New-TestDocument $sheet @($r,$l) $normal) $true
$single = New-TestPart -Handle 'ONE' -MinX 100 -MinY 150 -Width 800 -Height 300
Invoke-Test 'One part inside sheet' (New-TestDocument $sheet @($single) @((New-TestRecord -Shape $single -Label 'SH_Z'))) $true
$touch = New-TestPart -Handle 'TOUCH' -MinX 900 -MinY 150 -Width 800 -Height 300
Invoke-Test 'Two parts touch at edge' (New-TestDocument $sheet @($r,$touch) @((New-TestRecord -Shape $r -Label 'SH' -WithZ $false))) $true
$outside = New-TestPart -Handle 'OUTSIDE' -MinX 1900 -MinY 150 -Width 800 -Height 300
Invoke-Test 'Part outside presumed sheet' (New-TestDocument $sheet @($outside) @()) $false 'does not contain part handle'
$overlap = New-TestPart -Handle 'OVERLAP' -MinX 850 -MinY 150 -Width 800 -Height 300
Invoke-Test 'Part interiors overlap' (New-TestDocument $sheet @($r,$overlap) @()) $false 'overlapping part interiors'
$wrongSheet = New-TestPart -Handle 'WRONG' -MinX 100 -MinY 150 -Width 800 -Height 300
Invoke-Test 'First rectangle not a sheet' (New-TestDocument $wrongSheet @($sheet) @()) $false 'does not contain part handle'
$cross = New-TestRecord -Shape $r -Label 'SH18_66Z290' -Short 290
Invoke-Test 'SH crosses material removed by Z' (New-TestDocument $sheet @($r) @($cross)) $false 'crosses or touches the material removed by Z notch'
$boundary = New-TestRecord -Shape $r -Label 'SH18_66Z282' -Short 282
Invoke-Test 'SH touches Z cutout boundary' (New-TestDocument $sheet @($r) @($boundary)) $false 'crosses or touches the material removed by Z notch'
$microZ = New-TestRecord -Shape $r -Label 'SH_0.0001Z32' -Long 0.0001
Invoke-Test 'Micro Z rounds to zero' (New-TestDocument $sheet @($r) @($microZ)) $false 'degenerate or diagonal edge'
$microSH = New-TestRecord -Shape $r -Label 'SH0.0001' -Offset 0.0001 -WithZ $false
Invoke-Test 'Micro SH rounds onto border' (New-TestDocument $sheet @($r) @($microSH)) $false 'lies on/outside the original part border'
# Cover all table/state/role rows, in both rectangle orientations.
foreach ($table in 1,2) {
    foreach ($state in @('NN','N/Y','Y/N','Y/Y')) {
        foreach ($role in @('R','L')) {
            $orientation = if ($role -eq 'R') { if ($state -in @('NN','N/Y')) { 'N' } else { 'Y' } } else { if ($state -in @('NN','Y/N')) { 'N' } else { 'Y' } }
            $width = if ($orientation -eq 'N') { 800.0 } else { 300.0 }
            $height = if ($orientation -eq 'N') { 300.0 } else { 800.0 }
            $part = New-TestPart -Handle "$table-$state-$role" -MinX 100 -MinY 150 -Width $width -Height $height
            $record = New-TestRecord -Shape $part -Label "T$table-$state-$role" -Table $table -State $state -Role $role
            Invoke-Test "table $table state $state role $role" (New-TestDocument $sheet @($part) @($record)) $true
        }
    }
}
Write-Host "`nGeometry tests: $passed passed, $failed failed." -ForegroundColor $(if($failed -eq 0){'Green'}else{'Red'})
if ($failed -gt 0) { throw 'Stage 2 geometry tests failed.' }
