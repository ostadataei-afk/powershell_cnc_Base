# Build-Cnc-Dxf.ps1
# Independent DXF marker generator with serialized-output round-trip verification.
# Source DXF files are never modified.
# PowerShell 7 recommended.
[CmdletBinding()]
param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$desktop = [Environment]::GetFolderPath('Desktop')
$sourceFolder = Join-Path $desktop 'A'
$outputFolder = Join-Path $desktop 'B'
$epsilon = 0.05
$sizeTolerance = 0.1

function New-DxfPair {
    param([int]$Code, [string]$Value)
    [pscustomobject]@{ Code = $Code; CodeText = ('{0,3}' -f $Code); Value = $Value }
}
function Add-DxfPair {
    param([System.Collections.Generic.List[object]]$List, [int]$Code, [string]$Value)
    $List.Add((New-DxfPair -Code $Code -Value $Value))
}
function Get-FirstValue {
    param([object]$Entity, [int]$Code)
    foreach ($pair in $Entity.Pairs) { if ($pair.Code -eq $Code) { return ([string]$pair.Value).Trim() } }
    return $null
}
function ConvertFrom-DxfNumber {
    param([string]$Value)
    return [double]::Parse($Value.Trim(), [System.Globalization.NumberStyles]::Float, $culture)
}
function ConvertTo-DxfNumber {
    param([double]$Value)
    return $Value.ToString('0.###', $culture)
}
function Get-EntityVertices {
    param([object]$Entity)
    $points = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Entity.Pairs.Count; $i++) {
        if ($Entity.Pairs[$i].Code -eq 10) {
            if (($i + 1) -ge $Entity.Pairs.Count -or $Entity.Pairs[$i + 1].Code -ne 20) {
                throw "LWPOLYLINE handle '$((Get-FirstValue $Entity 5))' has an invalid vertex coordinate pair (codes 10/20)."
            }
            $points.Add([pscustomobject]@{ X = (ConvertFrom-DxfNumber $Entity.Pairs[$i].Value); Y = (ConvertFrom-DxfNumber $Entity.Pairs[$i + 1].Value) })
            $i++
        }
    }
    return ,$points.ToArray()
}
function Get-EntityBounds {
    param([object[]]$Points)
    if ($Points.Count -lt 2) { throw 'A polyline has fewer than two readable vertices.' }
    $xs = @($Points | ForEach-Object { [double]$_.X })
    $ys = @($Points | ForEach-Object { [double]$_.Y })
    $minX = [double](($xs | Measure-Object -Minimum).Minimum)
    $maxX = [double](($xs | Measure-Object -Maximum).Maximum)
    $minY = [double](($ys | Measure-Object -Minimum).Minimum)
    $maxY = [double](($ys | Measure-Object -Maximum).Maximum)
    [pscustomobject]@{ MinX = $minX; MaxX = $maxX; MinY = $minY; MaxY = $maxY; Width = ($maxX - $minX); Height = ($maxY - $minY) }
}
function Test-RectangleVertices {
    param([object[]]$Points, [object]$Bounds)
    if ($Points.Count -ne 4) { return $false }
    $corners = @{}
    foreach ($point in $Points) {
        $atLeft = [math]::Abs([double]$point.X - $Bounds.MinX) -lt 0.001
        $atRight = [math]::Abs([double]$point.X - $Bounds.MaxX) -lt 0.001
        $atBottom = [math]::Abs([double]$point.Y - $Bounds.MinY) -lt 0.001
        $atTop = [math]::Abs([double]$point.Y - $Bounds.MaxY) -lt 0.001
        if (-not ($atLeft -or $atRight) -or -not ($atBottom -or $atTop)) { return $false }
        $key = ('{0}|{1}' -f $(if ($atLeft) {'L'} else {'R'}), $(if ($atBottom) {'B'} else {'T'}))
        if ($corners.ContainsKey($key)) { return $false }
        $corners[$key] = $true
    }
    for ($i = 0; $i -lt 4; $i++) {
        $a = $Points[$i]
        $b = $Points[($i + 1) % 4]
        $dx = [math]::Abs([double]$a.X - [double]$b.X)
        $dy = [math]::Abs([double]$a.Y - [double]$b.Y)
        if (($dx -lt 0.001 -and $dy -lt 0.001) -or ($dx -ge 0.001 -and $dy -ge 0.001)) { return $false }
    }
    return ($corners.Count -eq 4)
}
function Read-DxfDocument {
    param([System.IO.FileInfo]$File)
    $rawLines = [System.IO.File]::ReadAllLines($File.FullName, [System.Text.Encoding]::UTF8)
    if (($rawLines.Count % 2) -ne 0) { throw 'DXF has an odd number of group-code/value lines.' }
    $pairs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $rawLines.Count; $i += 2) {
        $code = 0
        if (-not [int]::TryParse($rawLines[$i].Trim(), [ref]$code)) { throw "Invalid DXF group code at line $($i + 1)." }
        $pairs.Add([pscustomobject]@{ Code = $code; CodeText = $rawLines[$i]; Value = $rawLines[$i + 1] })
    }
    $entityBodyStart = -1; $entityBodyEnd = -1
    for ($i = 0; $i -lt ($pairs.Count - 1); $i++) {
        if ($pairs[$i].Code -eq 0 -and $pairs[$i].Value.Trim() -eq 'SECTION' -and $pairs[$i + 1].Code -eq 2 -and $pairs[$i + 1].Value.Trim() -eq 'ENTITIES') {
            $entityBodyStart = $i + 2
            for ($j = $entityBodyStart; $j -lt $pairs.Count; $j++) { if ($pairs[$j].Code -eq 0 -and $pairs[$j].Value.Trim() -eq 'ENDSEC') { $entityBodyEnd = $j; break } }
            break
        }
    }
    if ($entityBodyStart -lt 0 -or $entityBodyEnd -lt 0) { throw 'DXF ENTITIES section was not found.' }
    $entities = [System.Collections.Generic.List[object]]::new()
    $current = $null
    for ($i = $entityBodyStart; $i -lt $entityBodyEnd; $i++) {
        $pair = $pairs[$i]
        if ($pair.Code -eq 0) {
            if ($null -ne $current) { $entities.Add($current) }
            $current = [pscustomobject]@{ Type = $pair.Value.Trim(); Pairs = [System.Collections.Generic.List[object]]::new(); SourceIndex = $entities.Count }
            $current.Pairs.Add($pair)
        } elseif ($null -ne $current) { $current.Pairs.Add($pair) }
    }
    if ($null -ne $current) { $entities.Add($current) }
    return [pscustomobject]@{ File = $File; Pairs = $pairs; EntityBodyStart = $entityBodyStart; EntityBodyEnd = $entityBodyEnd; Entities = $entities; Parts = @(); FeatureRecords = @(); Stats = $null }
}
function Get-DimensionText {
    param([string]$Value)
    if ($Value -match '^\s*(?<w>\d+(?:[.,]\d+)?)\s*[xX×]\s*(?<h>\d+(?:[.,]\d+)?)(?:\s*:.*)?\s*$') {
        $w = [double]::Parse($Matches['w'].Replace(',', '.'), $culture)
        $h = [double]::Parse($Matches['h'].Replace(',', '.'), $culture)
        return [pscustomobject]@{ Width = $w; Height = $h }
    }
    return $null
}
function Parse-FeatureLabel {
    param([string]$Label)
    # Parse the COMPLETE label, not substrings: malformed numbers must never
    # silently turn into the default SH/Z measurements.
    # Grammar: optional single identifier token followed by one or two feature
    # tokens, separated by _ or -.  SH and Z can appear in either order.
    $name = $Label.Trim()
    $number = '[0-9]+(?:[.,][0-9]+)?'
    $shPattern = '^(?:(?<prefix>' + $number + '))?SH(?:(?<offset>' + $number + '))?$'
    $zPattern = '^(?:(?<long>' + $number + '))?Z(?:(?<short>' + $number + '))?$'
    $tokens = @($name -split '[_-]')
    $hasSH = $false; $hasZ = $false
    $prefix = $null; $offset = 18.0; $long = 66.0; $short = 32.0
    $identifier = $null

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = [string]$tokens[$i]
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Invalid feature label '$Label': an empty token or repeated separator is not allowed."
        }
        $sh = [regex]::Match($token, $shPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $z = [regex]::Match($token, $zPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($sh.Success) {
            if ($hasSH) { throw "Invalid feature label '$Label': SH appears more than once." }
            $hasSH = $true
            if ($sh.Groups['prefix'].Success) { $prefix = [double]::Parse($sh.Groups['prefix'].Value.Replace(',','.'), $culture) }
            if ($sh.Groups['offset'].Success) { $offset = [double]::Parse($sh.Groups['offset'].Value.Replace(',','.'), $culture) }
        } elseif ($z.Success) {
            if ($hasZ) { throw "Invalid feature label '$Label': Z appears more than once." }
            $hasZ = $true
            if ($z.Groups['long'].Success) { $long = [double]::Parse($z.Groups['long'].Value.Replace(',','.'), $culture) }
            if ($z.Groups['short'].Success) { $short = [double]::Parse($z.Groups['short'].Value.Replace(',','.'), $culture) }
        } elseif ($i -eq 0 -and $token -match '^[A-Za-z0-9]+$' -and $token -notmatch '(?i)SH|Z') {
            # e.g. 01_SH100, 02_300SH100_Z.  A numeric identifier is
            # NOT the dimensional prefix before SH.
            $identifier = $token
        } else {
            throw "Invalid feature label '$Label': unsupported or malformed token '$token'."
        }
    }
    if (-not ($hasSH -or $hasZ)) { throw "Invalid feature label '$Label': neither SH nor Z was found." }
    if ($null -ne $prefix -and ($prefix -le 0 -or [double]::IsNaN($prefix) -or [double]::IsInfinity($prefix))) {
        throw "Invalid feature label '$Label': SH dimensional prefix must be positive and finite."
    }
    if ($hasSH -and ($offset -le 0 -or [double]::IsNaN($offset) -or [double]::IsInfinity($offset))) {
        throw "Invalid feature label '$Label': SH offset must be positive and finite."
    }
    if ($hasZ -and ($long -le 0 -or $short -le 0 -or [double]::IsNaN($long) -or [double]::IsInfinity($long) -or [double]::IsNaN($short) -or [double]::IsInfinity($short))) {
        throw "Invalid feature label '$Label': both Z lengths must be positive and finite."
    }
    return [pscustomobject]@{
        HasSH = $hasSH; HasZ = $hasZ; Identifier = $identifier
        Prefix = $prefix; GrooveOffset = $offset
        LongLength = $long; ShortLength = $short
    }
}
function Get-TextRecords {
    param([object]$Document)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($entity in $Document.Entities) {
        if ($entity.Type -ne 'TEXT') { continue }
        $value = Get-FirstValue $entity 1
        if ($null -eq $value) { continue }
        $xValue = Get-FirstValue $entity 10; $yValue = Get-FirstValue $entity 20
        $x = $null; $y = $null
        if ($null -ne $xValue -and $null -ne $yValue) {
            try { $x = ConvertFrom-DxfNumber $xValue; $y = ConvertFrom-DxfNumber $yValue }
            catch { throw "TEXT '$value' has invalid insertion coordinates." }
        }
        $dim = Get-DimensionText $value
        # Non-feature annotation TEXT is ignored as before.  Anything that
        # appears to be an SH/Z instruction must parse fully or fail fast.
        $candidate = ($null -eq $dim) -and ($value -match '(?i)SH|(?:^|[_-])[0-9.,]*Z')
        $parsed = $null
        if ($candidate) { $parsed = Parse-FeatureLabel -Label $value }
        $isFeature = $null -ne $parsed
        if ($isFeature -and ($null -eq $x -or $null -eq $y)) {
            throw "Feature label '$value' has no valid insertion point (codes 10/20)."
        }
        $records.Add([pscustomobject]@{
            Value = $value.Trim(); X = $x; Y = $y
            Entity = $entity; EntityIndex = $entity.SourceIndex
            Dimension = $dim
            HasSH = [bool]($isFeature -and $parsed.HasSH)
            HasZ = [bool]($isFeature -and $parsed.HasZ)
            IsFeature = [bool]$isFeature; Parameters = $parsed; Shape = $null
        })
    }
    return ,$records.ToArray()
}
function Test-TextInsidePart {
    param([object]$Text, [object]$Shape)
    return ([math]::Abs([double]$Shape.MinX - [double]$Text.X) -lt $epsilon -and [double]$Text.Y -gt ([double]$Shape.MinY + 1) -and [double]$Text.Y -lt ([double]$Shape.MaxY - 1))
}
function Get-Orientation {
    param([object]$Shape)
    if ([math]::Abs($Shape.Width - $Shape.Height) -lt 0.001) { throw "Part handle '$($Shape.Handle)' is square; the agreed N/Y rotation rule does not define square parts." }
    if ($Shape.Width -gt $Shape.Height) { return 'N' }
    return 'Y'
}
function Get-SymmetryState {
    param([string]$FirstOrientation, [string]$SecondOrientation)
    if ($FirstOrientation -notin @('N','Y') -or $SecondOrientation -notin @('N','Y')) { throw "Invalid orientation state '$FirstOrientation/$SecondOrientation'." }
    if ($FirstOrientation -eq 'N' -and $SecondOrientation -eq 'N') { return 'NN' }
    if ($FirstOrientation -eq 'Y' -and $SecondOrientation -eq 'Y') { return 'Y/Y' }
    return "$FirstOrientation/$SecondOrientation"
}
function Get-TableNumber {
    param([object]$Prefix, [object]$Shape, [string]$Label)
    if ($null -eq $Prefix) { return 2 }
    $matchWidth = [math]::Abs([double]$Shape.Width - [double]$Prefix) -lt $sizeTolerance
    $matchHeight = [math]::Abs([double]$Shape.Height - [double]$Prefix) -lt $sizeTolerance
    if (-not $matchWidth -and -not $matchHeight) { throw "Label '$Label': number before SH ($Prefix) does not match either dimension of part $($Shape.Width) x $($Shape.Height) mm." }
    if ($matchWidth -and $matchHeight) { return 1 }
    $small = [math]::Min([double]$Shape.Width, [double]$Shape.Height)
    if ([math]::Abs([double]$Prefix - $small) -lt $sizeTolerance) { return 1 }
    return 2
}
function Assert-ZNotchFitsPart {
    param([object]$Shape, [string]$Label, [object]$ZParameters, [int]$Table)
    $small = [math]::Min([double]$Shape.Width, [double]$Shape.Height)
    $large = [math]::Max([double]$Shape.Width, [double]$Shape.Height)
    # Existing CNC convention: table 1 long notch on SHORT side;
    # table 2 long notch on LONG side.  No cutting rule is changed.
    $beforeZLimit = if ($Table -eq 1) { $small } else { $large }
    $afterZLimit  = if ($Table -eq 1) { $large } else { $small }
    if ([double]$ZParameters.LongLength -ge $beforeZLimit -or [double]$ZParameters.ShortLength -ge $afterZLimit) {
        throw "Label '$Label': Z lengths ($($ZParameters.LongLength), $($ZParameters.ShortLength)) do not fit the $($Shape.Width)x$($Shape.Height) mm part under table $Table (limits: < $beforeZLimit and < $afterZLimit mm)."
    }
}
function Get-TableRule {
    param([int]$Table, [string]$State, [string]$Role)
    $key = "$State|$Role"
    $table1 = @{
        'NN|R' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'NN|L' = @{ Groove = 'BC'; Handles = @('CD','DA'); Corner = 'D' }
        'N/Y|R' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'N/Y|L' = @{ Groove = 'CD'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/N|R' = @{ Groove = 'CD'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/N|L' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/Y|R' = @{ Groove = 'AB'; Handles = @('BC','CD'); Corner = 'C' }
        'Y/Y|L' = @{ Groove = 'AB'; Handles = @('CD','DA'); Corner = 'D' }
    }
    $table2 = @{
        'NN|R' = @{ Groove = 'AB'; Handles = @('BC','CD'); Corner = 'C' }
        'NN|L' = @{ Groove = 'AB'; Handles = @('CD','DA'); Corner = 'D' }
        'N/Y|R' = @{ Groove = 'AB'; Handles = @('BC','CD'); Corner = 'C' }
        'N/Y|L' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/N|R' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/N|L' = @{ Groove = 'AB'; Handles = @('BC','CD'); Corner = 'C' }
        'Y/Y|R' = @{ Groove = 'BC'; Handles = @('DA','AB'); Corner = 'A' }
        'Y/Y|L' = @{ Groove = 'DA'; Handles = @('AB','BC'); Corner = 'B' }
    }
    $rules = if ($Table -eq 1) { $table1 } else { $table2 }
    if (-not $rules.ContainsKey($key)) { throw "No symmetry rule exists for table $Table, state '$State', role '$Role'." }
    return $rules[$key]
}
function Get-LayerTableInfo {
    param([System.Collections.Generic.List[object]]$Pairs)
    $tablesStart = -1; $tablesEnd = -1
    for ($i = 0; $i -lt ($Pairs.Count - 1); $i++) {
        if ($Pairs[$i].Code -eq 0 -and $Pairs[$i].Value.Trim() -eq 'SECTION' -and $Pairs[$i + 1].Code -eq 2 -and $Pairs[$i + 1].Value.Trim() -eq 'TABLES') {
            $tablesStart = $i + 2
            for ($j = $tablesStart; $j -lt $Pairs.Count; $j++) { if ($Pairs[$j].Code -eq 0 -and $Pairs[$j].Value.Trim() -eq 'ENDSEC') { $tablesEnd = $j; break } }
            break
        }
    }
    if ($tablesStart -lt 0 -or $tablesEnd -lt 0) { throw 'DXF TABLES section was not found.' }
    for ($i = $tablesStart; $i -lt ($tablesEnd - 1); $i++) {
        if ($Pairs[$i].Code -eq 0 -and $Pairs[$i].Value.Trim() -eq 'TABLE' -and $Pairs[$i + 1].Code -eq 2 -and $Pairs[$i + 1].Value.Trim() -eq 'LAYER') {
            $endTable = -1
            for ($j = $i + 2; $j -lt $tablesEnd; $j++) { if ($Pairs[$j].Code -eq 0 -and $Pairs[$j].Value.Trim() -eq 'ENDTAB') { $endTable = $j; break } }
            if ($endTable -lt 0) { throw 'The LAYER table has no ENDTAB marker.' }
            $firstEntry = $endTable
            for ($j = $i + 2; $j -lt $endTable; $j++) { if ($Pairs[$j].Code -eq 0 -and $Pairs[$j].Value.Trim() -eq 'LAYER') { $firstEntry = $j; break } }
            $countIndex = -1
            for ($j = $i + 2; $j -lt $firstEntry; $j++) { if ($Pairs[$j].Code -eq 70) { $countIndex = $j; break } }
            if ($countIndex -lt 0) { throw 'The LAYER table record count was not found.' }
            return [pscustomobject]@{ Start = $i; End = $endTable; CountIndex = $countIndex }
        }
    }
    throw 'DXF LAYER table was not found.'
}
function Test-LayerExists {
    param([System.Collections.Generic.List[object]]$Pairs, [string]$Name)
    $info = Get-LayerTableInfo $Pairs
    for ($i = $info.Start + 2; $i -lt $info.End; $i++) {
        if ($Pairs[$i].Code -eq 0 -and $Pairs[$i].Value.Trim() -eq 'LAYER') {
            for ($j = $i + 1; $j -lt $info.End -and $Pairs[$j].Code -ne 0; $j++) { if ($Pairs[$j].Code -eq 2 -and $Pairs[$j].Value.Trim() -eq $Name) { return $true } }
        }
    }
    return $false
}
function Add-Layer2 {
    param([System.Collections.Generic.List[object]]$Pairs, [string]$Handle)
    $info = Get-LayerTableInfo $Pairs
    $record = [System.Collections.Generic.List[object]]::new()
    Add-DxfPair $record 0 'LAYER'; Add-DxfPair $record 5 $Handle; Add-DxfPair $record 100 'AcDbSymbolTableRecord'; Add-DxfPair $record 100 'AcDbLayerTableRecord'; Add-DxfPair $record 2 '2'; Add-DxfPair $record 70 '0'; Add-DxfPair $record 62 '7'; Add-DxfPair $record 6 'CONTINUOUS'
    $oldCount = [int]::Parse($Pairs[$info.CountIndex].Value.Trim(), $culture)
    $Pairs[$info.CountIndex].Value = [string]($oldCount + 1)
    $Pairs.InsertRange($info.End, $record)
}
function Get-NextHandle {
    param([System.Collections.Generic.List[object]]$Pairs)
    [uint64]$maximum = 0
    foreach ($pair in $Pairs) {
        if ($pair.Code -eq 5 -or $pair.Code -eq 105) {
            $text = ([string]$pair.Value).Trim()
            if ($text -match '^[0-9A-Fa-f]+$') { try { [uint64]$value = [Convert]::ToUInt64($text, 16); if ($value -gt $maximum) { $maximum = $value } } catch {} }
        }
    }
    return [uint64]($maximum + 1)
}
function Update-Handseed {
    param([System.Collections.Generic.List[object]]$Pairs, [uint64]$NextHandle)
    $hex = $NextHandle.ToString('X')
    for ($i = 0; $i -lt ($Pairs.Count - 1); $i++) {
        if ($Pairs[$i].Code -eq 9 -and $Pairs[$i].Value.Trim() -eq '$HANDSEED' -and $Pairs[$i + 1].Code -eq 5) { $Pairs[$i + 1].Value = $hex; return }
    }
}
function Set-PolylineVertices {
    param([object]$Entity, [object[]]$Points)
    $old = @($Entity.Pairs.ToArray()); $firstX = -1; $lastY = -1
    for ($i = 0; $i -lt $old.Count; $i++) { if ($old[$i].Code -eq 10 -and $firstX -lt 0) { $firstX = $i }; if ($old[$i].Code -eq 20) { $lastY = $i } }
    if ($firstX -lt 0 -or $lastY -lt $firstX) { throw 'Target outline has no readable vertices.' }
    $vertexStarts = [System.Collections.Generic.List[int]]::new()
    for ($i = $firstX; $i -le $lastY; $i++) { if ($old[$i].Code -eq 10) { $vertexStarts.Add($i) } }
    if ($vertexStarts.Count -ne 4) { throw 'Target outline does not have exactly four original vertices.' }
    $counts = @{}
    foreach ($code in @(30,40,41,42)) { $counts[$code] = @($old | Where-Object { $_.Code -eq $code }).Count; if ($counts[$code] -ne 0 -and $counts[$code] -ne 4) { throw "Target outline has inconsistent per-vertex group $code data." } }
    $has30 = ($counts[30] -eq 4); $has40 = ($counts[40] -eq 4); $has41 = ($counts[41] -eq 4); $has42 = ($counts[42] -eq 4)
    $tailStart = $old.Count
    for ($i = $lastY + 1; $i -lt $old.Count; $i++) { if ($old[$i].Code -eq 210) { $tailStart = $i; break } }
    $vertexData = [System.Collections.Generic.List[object]]::new(); $hasIds = $false
    for ($vertexIndex = 0; $vertexIndex -lt 4; $vertexIndex++) {
        $start = $vertexStarts[$vertexIndex]; $next = if ($vertexIndex -lt 3) { $vertexStarts[$vertexIndex + 1] } else { $tailStart }
        if (($start + 1) -ge $old.Count -or $old[$start + 1].Code -ne 20) { throw 'Target outline vertex lacks Y coordinate.' }
        $id = $null
        for ($j = $start + 2; $j -lt $next; $j++) {
            $code = [int]$old[$j].Code
            if ($code -in @(30,40,41,42)) {
                $number = 0.0
                if (-not [double]::TryParse(([string]$old[$j].Value).Trim(), [System.Globalization.NumberStyles]::Float, $culture, [ref]$number)) { throw "Invalid per-vertex value (group $code)." }
                if ([math]::Abs($number) -gt 0.0000001) { if ($code -eq 30) { throw 'Target outline has non-zero vertex Z values.' }; throw "Target outline has non-zero width/bulge data (group $code); refusing to alter geometry." }
                continue
            }
            if ($code -eq 91) { if ($null -ne $id) { throw 'More than one vertex ID found.' }; $parsed = 0L; if (-not [long]::TryParse(([string]$old[$j].Value).Trim(), [ref]$parsed)) { throw 'Invalid vertex ID.' }; $id = $parsed; $hasIds = $true; continue }
            throw "Unsupported per-vertex DXF data (group $code); refusing to alter geometry."
        }
        $vertexData.Add([pscustomobject]@{ X = (ConvertFrom-DxfNumber $old[$start].Value); Y = (ConvertFrom-DxfNumber $old[$start + 1].Value); Id = $id })
    }
    if ($hasIds) { foreach ($v in $vertexData) { if ($null -eq $v.Id) { throw 'Only some vertices have group 91 identifiers.' } } }
    $maxId = -1L; if ($hasIds) { $maxId = [long](($vertexData | Measure-Object -Property Id -Maximum).Maximum) }
    $newPairs = [System.Collections.Generic.List[object]]::new(); $countFound = $false
    for ($i = 0; $i -lt $firstX; $i++) { $p = [pscustomobject]@{ Code = $old[$i].Code; CodeText = $old[$i].CodeText; Value = $old[$i].Value }; if ($p.Code -eq 90) { $p.Value = [string]$Points.Count; $countFound = $true }; $newPairs.Add($p) }
    if (-not $countFound) { throw 'Target outline has no vertex count field (group 90).' }
    foreach ($point in $Points) {
        Add-DxfPair $newPairs 10 (ConvertTo-DxfNumber ([double]$point.X)); Add-DxfPair $newPairs 20 (ConvertTo-DxfNumber ([double]$point.Y))
        if ($has30) { Add-DxfPair $newPairs 30 '0.000000' }; if ($has40) { Add-DxfPair $newPairs 40 '0.000000' }; if ($has41) { Add-DxfPair $newPairs 41 '0.000000' }; if ($has42) { Add-DxfPair $newPairs 42 '0.000000' }
        if ($hasIds) {
            $matches = @($vertexData | Where-Object { [math]::Abs($_.X - [double]$point.X) -lt 0.000001 -and [math]::Abs($_.Y - [double]$point.Y) -lt 0.000001 })
            if ($matches.Count -gt 1) { throw 'Replacement vertex matches multiple original vertex IDs.' }
            if ($matches.Count -eq 1) { Add-DxfPair $newPairs 91 ([string]$matches[0].Id) } else { $maxId++; Add-DxfPair $newPairs 91 ([string]$maxId) }
        }
    }
    for ($i = $tailStart; $i -lt $old.Count; $i++) { $newPairs.Add([pscustomobject]@{ Code = $old[$i].Code; CodeText = $old[$i].CodeText; Value = $old[$i].Value }) }
    $Entity.Pairs = $newPairs
}
function Get-NotchedVertices {
    param([object]$Shape, [string]$Corner, [double]$LongLength, [double]$ShortLength, [int]$Table = 2)
    # Corner convention: A=upper-left, B=upper-right, C=lower-right, D=lower-left.
    # Table 2: long notch length follows the longer dimension; short notch length follows the shorter dimension.
    # Table 1: long notch length follows the shorter dimension; short notch length follows the longer dimension.
    if ($Table -notin @(1,2)) { throw "Unsupported handle-notch table '$Table'." }
    $horizontalGetsLong = if ($Table -eq 1) { [double]$Shape.Width -lt [double]$Shape.Height } else { [double]$Shape.Width -gt [double]$Shape.Height }
    $verticalGetsLong = if ($Table -eq 1) { [double]$Shape.Height -lt [double]$Shape.Width } else { [double]$Shape.Height -gt [double]$Shape.Width }
    $a = [pscustomobject]@{ Name = 'A'; X = [double]$Shape.MinX; Y = [double]$Shape.MaxY }
    $b = [pscustomobject]@{ Name = 'B'; X = [double]$Shape.MaxX; Y = [double]$Shape.MaxY }
    $c = [pscustomobject]@{ Name = 'C'; X = [double]$Shape.MaxX; Y = [double]$Shape.MinY }
    $d = [pscustomobject]@{ Name = 'D'; X = [double]$Shape.MinX; Y = [double]$Shape.MinY }
    $base = @($a,$b,$c,$d); $result = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt 4; $i++) {
        $v = $base[$i]
        if ($v.Name -ne $Corner) { $result.Add([pscustomobject]@{ X = $v.X; Y = $v.Y }); continue }
        $prev = $base[($i + 3) % 4]; $next = $base[($i + 1) % 4]
        $prevDx = [double]$prev.X - [double]$v.X; $prevDy = [double]$prev.Y - [double]$v.Y
        $nextDx = [double]$next.X - [double]$v.X; $nextDy = [double]$next.Y - [double]$v.Y
        $prevOffset = if ([math]::Abs($prevDx) -gt 0) { if ($horizontalGetsLong) { $LongLength } else { $ShortLength } } else { if ($verticalGetsLong) { $LongLength } else { $ShortLength } }
        $nextOffset = if ([math]::Abs($nextDx) -gt 0) { if ($horizontalGetsLong) { $LongLength } else { $ShortLength } } else { if ($verticalGetsLong) { $LongLength } else { $ShortLength } }
        $prevScale = if ([math]::Abs($prevDx) -gt 0) { [math]::Sign($prevDx) } else { [math]::Sign($prevDy) }
        $nextScale = if ([math]::Abs($nextDx) -gt 0) { [math]::Sign($nextDx) } else { [math]::Sign($nextDy) }
        if ([math]::Abs($prevDx) -gt 0) { $p1x = $v.X + $prevScale * $prevOffset; $p1y = $v.Y } else { $p1x = $v.X; $p1y = $v.Y + $prevScale * $prevOffset }
        if ([math]::Abs($nextDx) -gt 0) { $p3x = $v.X + $nextScale * $nextOffset; $p3y = $v.Y } else { $p3x = $v.X; $p3y = $v.Y + $nextScale * $nextOffset }
        $result.Add([pscustomobject]@{ X = [double]$p1x; Y = [double]$p1y })
        $result.Add([pscustomobject]@{ X = [double]($p1x + $p3x - $v.X); Y = [double]($p1y + $p3y - $v.Y) })
        $result.Add([pscustomobject]@{ X = [double]$p3x; Y = [double]$p3y })
    }
    return ,$result.ToArray()
}
function New-SlotLineEntity {
    param([string]$Handle, [string]$Edge, [object]$Shape, [double]$Offset)
    switch ($Edge) {
        'AB' { $x1 = $Shape.MinX; $y1 = $Shape.MaxY - $Offset; $x2 = $Shape.MaxX; $y2 = $y1 }
        'BC' { $x1 = $Shape.MaxX - $Offset; $y1 = $Shape.MinY; $x2 = $x1; $y2 = $Shape.MaxY }
        'CD' { $x1 = $Shape.MinX; $y1 = $Shape.MinY + $Offset; $x2 = $Shape.MaxX; $y2 = $y1 }
        'DA' { $x1 = $Shape.MinX + $Offset; $y1 = $Shape.MinY; $x2 = $x1; $y2 = $Shape.MaxY }
        default { throw "Unsupported groove edge '$Edge'." }
    }
    $entity = [pscustomobject]@{ Type = 'LINE'; Pairs = [System.Collections.Generic.List[object]]::new(); SourceIndex = -1 }
    Add-DxfPair $entity.Pairs 0 'LINE'; Add-DxfPair $entity.Pairs 5 $Handle; Add-DxfPair $entity.Pairs 100 'AcDbEntity'; Add-DxfPair $entity.Pairs 8 '2'; Add-DxfPair $entity.Pairs 100 'AcDbLine'
    Add-DxfPair $entity.Pairs 10 (ConvertTo-DxfNumber ([double]$x1)); Add-DxfPair $entity.Pairs 20 (ConvertTo-DxfNumber ([double]$y1)); Add-DxfPair $entity.Pairs 30 '0'
    Add-DxfPair $entity.Pairs 11 (ConvertTo-DxfNumber ([double]$x2)); Add-DxfPair $entity.Pairs 21 (ConvertTo-DxfNumber ([double]$y2)); Add-DxfPair $entity.Pairs 31 '0'
    return $entity
}
# Stage 2: inspect the exact geometry that the existing cutting rules would
# generate, without modifying the rules or writing any output files.
function ConvertTo-DxfGridNumber {
    param([double]$Value)
    # Output coordinates are serialized to three decimals by ConvertTo-DxfNumber.
    return (ConvertFrom-DxfNumber (ConvertTo-DxfNumber $Value))
}
function Assert-CncGeometry {
    param([object[]]$Documents)
    $gridTolerance = 0.0005
    foreach ($document in $Documents) {
        $sheet = $document.StockSheet
        if ($null -eq $sheet) { throw "File '$($document.File.Name)': stock sheet is missing." }
        $parts = @($document.Parts)
        # First-rectangle convention stays unchanged. Reject wrong ordering
        # when the presumed sheet does not enclose all part outlines.
        foreach ($part in $parts) {
            if ($part.MinX -lt ($sheet.MinX - $epsilon) -or
                $part.MaxX -gt ($sheet.MaxX + $epsilon) -or
                $part.MinY -lt ($sheet.MinY - $epsilon) -or
                $part.MaxY -gt ($sheet.MaxY + $epsilon)) {
                throw "File '$($document.File.Name)': first rectangle (handle $($sheet.Handle)) does not contain part handle $($part.Handle). Check DXF entity ordering; the first rectangle must be the stock sheet."
            }
        }
        # Adjacent pieces may share a border; overlapping interiors cannot
        # safely represent separate CNC pieces.
        for ($i = 0; $i -lt $parts.Count; $i++) {
            for ($j = $i + 1; $j -lt $parts.Count; $j++) {
                $first = $parts[$i]; $second = $parts[$j]
                $overlapX = [math]::Min($first.MaxX, $second.MaxX) - [math]::Max($first.MinX, $second.MinX)
                $overlapY = [math]::Min($first.MaxY, $second.MaxY) - [math]::Max($first.MinY, $second.MinY)
                if ($overlapX -gt $epsilon -and $overlapY -gt $epsilon) {
                    throw "File '$($document.File.Name)': overlapping part interiors (handles $($first.Handle) and $($second.Handle)); $overlapX x $overlapY mm overlap."
                }
            }
        }
        foreach ($record in $document.FeatureRecords) {
            $shape = $record.Shape
            $notchBox = $null
            if ($record.HasZ) {
                # Z size-to-part checks are already performed by stage 1.
                # Check the resulting SIX serialized outline vertices, including
                # very small decimal values that would round to zero.
                $notchPoints = Get-NotchedVertices -Shape $shape -Corner $record.Corner -LongLength $record.NotchLongLength -ShortLength $record.NotchShortLength -Table $record.Table
                if ($notchPoints.Count -ne 6) { throw "Label '$($record.Label)': expected six vertices after Z notch." }
                $rounded = @($notchPoints | ForEach-Object {
                    [pscustomobject]@{ X = (ConvertTo-DxfGridNumber ([double]$_.X)); Y = (ConvertTo-DxfGridNumber ([double]$_.Y)) }
                })
                for ($i = 0; $i -lt $rounded.Count; $i++) {
                    $a = $rounded[$i]; $b = $rounded[($i + 1) % $rounded.Count]
                    $dx = [math]::Abs([double]$a.X - [double]$b.X)
                    $dy = [math]::Abs([double]$a.Y - [double]$b.Y)
                    if (($dx -le $gridTolerance -and $dy -le $gridTolerance) -or
                        ($dx -gt $gridTolerance -and $dy -gt $gridTolerance)) {
                        throw "Label '$($record.Label)': Z notch produces a degenerate or diagonal edge after DXF 0.001 mm coordinate rounding (part $($shape.Handle))."
                    }
                    if ($a.X -lt ($shape.MinX - $gridTolerance) -or $a.X -gt ($shape.MaxX + $gridTolerance) -or
                        $a.Y -lt ($shape.MinY - $gridTolerance) -or $a.Y -gt ($shape.MaxY + $gridTolerance)) {
                        throw "Label '$($record.Label)': Z notch vertex outside part $($shape.Handle)."
                    }
                }
                # The new interior (concave) vertex is the only point strictly
                # inside the original rectangle. It defines the removed corner box.
                $innerPoints = @($rounded | Where-Object {
                    $_.X -gt ($shape.MinX + $gridTolerance) -and $_.X -lt ($shape.MaxX - $gridTolerance) -and
                    $_.Y -gt ($shape.MinY + $gridTolerance) -and $_.Y -lt ($shape.MaxY - $gridTolerance)
                })
                if ($innerPoints.Count -ne 1) {
                    throw "Label '$($record.Label)': Z corner is ambiguous after coordinate rounding (part $($shape.Handle))."
                }
                $cornerX = if ($record.Corner -in @('A','D')) { [double]$shape.MinX } else { [double]$shape.MaxX }
                $cornerY = if ($record.Corner -in @('A','B')) { [double]$shape.MaxY } else { [double]$shape.MinY }
                $notchBox = [pscustomobject]@{
                    MinX = [math]::Min($cornerX,[double]$innerPoints[0].X)
                    MaxX = [math]::Max($cornerX,[double]$innerPoints[0].X)
                    MinY = [math]::Min($cornerY,[double]$innerPoints[0].Y)
                    MaxY = [math]::Max($cornerY,[double]$innerPoints[0].Y)
                }
            }
            if ($record.HasSH) {
                # Use the original slot-line creator so this safety check
                # follows the unchanged table/edge calculations exactly.
                $line = New-SlotLineEntity -Handle '0' -Edge $record.GrooveEdge -Shape $shape -Offset $record.GrooveOffset
                $x1 = ConvertFrom-DxfNumber (Get-FirstValue $line 10)
                $y1 = ConvertFrom-DxfNumber (Get-FirstValue $line 20)
                $x2 = ConvertFrom-DxfNumber (Get-FirstValue $line 11)
                $y2 = ConvertFrom-DxfNumber (Get-FirstValue $line 21)
                $horizontal = ([math]::Abs($y1 - $y2) -le $gridTolerance)
                $vertical = ([math]::Abs($x1 - $x2) -le $gridTolerance)
                if ($horizontal -eq $vertical) {
                    throw "Label '$($record.Label)': SH slot is diagonal or zero length after serialization."
                }
                if ($horizontal) {
                    if ($y1 -le ($shape.MinY + $gridTolerance) -or $y1 -ge ($shape.MaxY - $gridTolerance) -or
                        [math]::Abs($x1 - $x2) -le $gridTolerance) {
                        throw "Label '$($record.Label)': SH slot lies on/outside the original part border after rounding."
                    }
                } else {
                    if ($x1 -le ($shape.MinX + $gridTolerance) -or $x1 -ge ($shape.MaxX - $gridTolerance) -or
                        [math]::Abs($y1 - $y2) -le $gridTolerance) {
                        throw "Label '$($record.Label)': SH slot lies on/outside the original part border after rounding."
                    }
                }
                if ($null -ne $notchBox) {
                    # The groove spans the full part; if its inset coordinate
                    # crosses the removed Z-corner box, part of it is in void.
                    # Boundary contact is conservatively rejected as ambiguous.
                    $touchesRemovedCorner = if ($horizontal) {
                        ($y1 -ge ($notchBox.MinY - $gridTolerance) -and $y1 -le ($notchBox.MaxY + $gridTolerance))
                    } else {
                        ($x1 -ge ($notchBox.MinX - $gridTolerance) -and $x1 -le ($notchBox.MaxX + $gridTolerance))
                    }
                    if ($touchesRemovedCorner) {
                        throw "Label '$($record.Label)': SH groove ($($record.GrooveEdge), offset $($record.GrooveOffset)) crosses or touches the material removed by Z notch at corner $($record.Corner) on part $($shape.Handle)."
                    }
                }
            }
        }
        Write-Host "  Geometry safe: sheet containment, part overlap, SH/Z bounds and groove/notch conflicts checked ($($document.File.Name))." -ForegroundColor DarkGreen
    }
}
# OptiCut has two known, independently identified DXF export layouts.
# Legacy: all outlines layer 0, first rectangle is the stock sheet, dimension
# and feature TEXT anchored on the left edge.
# Layered: Panel + Parts layers, centered feature TEXT, size from geometry.
function Get-OptiCutFormat {
    param([object]$Document)
    $panel = @($Document.Entities | Where-Object { $_.Type -eq 'LWPOLYLINE' -and (Get-FirstValue $_ 8) -ieq 'Panel' })
    $pieces = @($Document.Entities | Where-Object { $_.Type -eq 'LWPOLYLINE' -and (Get-FirstValue $_ 8) -ieq 'Parts' })
    if (($panel.Count -gt 0) -xor ($pieces.Count -gt 0)) {
        throw "Incomplete layered OptiCut format in '$($Document.File.Name)': both Panel and Parts outline layers must be present."
    }
    if ($panel.Count -gt 0) { return 'Layered' }
    # If it has layered-only geometry but no valid Panel/Parts pair, reject it
    # rather than mistaking an off-cut for a legacy stock sheet.
    $foreignOutlines = @($Document.Entities | Where-Object {
        $_.Type -eq 'LWPOLYLINE' -and (Get-FirstValue $_ 8) -in @('Off-Cuts','Panel','Parts')
    })
    if ($foreignOutlines.Count -gt 0) {
        throw "Incomplete OptiCut layer layout in '$($Document.File.Name)'."
    }
    return 'Legacy'
}
function Test-TextAtPartCenter {
    param([object]$Text,[object]$Shape)
    if ($null -eq $Text.X -or $null -eq $Text.Y) { return $false }
    # First require an unambiguous containment, then a central insertion point.
    $x = [double]$Text.X; $y = [double]$Text.Y
    if ($x -le ($Shape.MinX + $epsilon) -or $x -ge ($Shape.MaxX - $epsilon) -or
        $y -le ($Shape.MinY + $epsilon) -or $y -ge ($Shape.MaxY - $epsilon)) { return $false }
    $centerX = ([double]$Shape.MinX + [double]$Shape.MaxX) / 2.0
    $centerY = ([double]$Shape.MinY + [double]$Shape.MaxY) / 2.0
    # OptiCut centers its TEXT insertion exactly; permit a small 5% region
    # for minor exporter drift, without using a fixed sheet/part dimension.
    $marginX = [math]::Max($epsilon, [double]$Shape.Width * 0.05)
    $marginY = [math]::Max($epsilon, [double]$Shape.Height * 0.05)
    return ([math]::Abs($x - $centerX) -le $marginX -and
            [math]::Abs($y - $centerY) -le $marginY)
}
function Build-DxfPlan {
    param([object]$Document)
    $format = Get-OptiCutFormat -Document $Document
    $Document | Add-Member -NotePropertyName OptiCutFormat -NotePropertyValue $format -Force
    $texts = Get-TextRecords $Document
    $rectangles = [System.Collections.Generic.List[object]]::new()
    foreach ($entity in $Document.Entities) {
        if ($entity.Type -ne 'LWPOLYLINE') { continue }
        $layer = Get-FirstValue $entity 8
        if ($format -eq 'Layered' -and $layer -notin @('Panel','Parts')) { continue }
        $points = Get-EntityVertices $entity
        if ($points.Count -lt 2) { continue }
        $bounds = Get-EntityBounds $points
        if ($format -eq 'Legacy') {
            # Preserve the stage-2 threshold and legacy sheet order behavior.
            if ($bounds.Width -lt 100 -or $bounds.Height -lt 100) { continue }
        } elseif ($bounds.Width -le 0 -or $bounds.Height -le 0) {
            throw "Layered OptiCut outline '$((Get-FirstValue $entity 5))' has a zero-sized bounding box."
        }
        $closed = Get-FirstValue $entity 70
        if ($null -eq $closed -or (([int]$closed -band 1) -eq 0)) {
            throw "Candidate outline handle '$((Get-FirstValue $entity 5))' is not a closed polyline."
        }
        if (-not (Test-RectangleVertices -Points $points -Bounds $bounds)) {
            throw "Candidate outline handle '$((Get-FirstValue $entity 5))' is not a plain axis-aligned four-corner rectangle."
        }
        $rectangles.Add([pscustomobject]@{
            Entity = $entity; Handle = (Get-FirstValue $entity 5)
            Points = $points; Layer = $layer
            MinX = $bounds.MinX; MaxX = $bounds.MaxX
            MinY = $bounds.MinY; MaxY = $bounds.MaxY
            Width = [double]$bounds.Width; Height = [double]$bounds.Height
        })
    }
    $stockHandles = [System.Collections.Generic.HashSet[string]]::new()
    if ($format -eq 'Layered') {
        $sheets = @($rectangles | Where-Object { $_.Layer -ieq 'Panel' })
        if ($sheets.Count -ne 1) {
            throw "Layered OptiCut file must contain exactly one rectangular Panel outline; found $($sheets.Count)."
        }
        $sheet = $sheets[0]
        $partRects = @($rectangles | Where-Object { $_.Layer -ieq 'Parts' })
        if ($partRects.Count -eq 0) { throw 'Layered OptiCut file has no rectangular Parts outlines.' }
        # Do not infer a sheet from overall bounds or from entity order.
        [void]$stockHandles.Add([string]$sheet.Handle)
        Write-Host "  OptiCut layered: Panel handle $($sheet.Handle), $($partRects.Count) Parts outlines (off-cuts ignored)." -ForegroundColor DarkCyan
    } else {
        # Stage-2 legacy rule is intentionally unchanged.
        if ($rectangles.Count -lt 2) {
            throw 'Expected stock sheet followed by at least one part rectangle; fewer than two rectangular outlines found.'
        }
        $sheet = $rectangles[0]
        [void]$stockHandles.Add([string]$sheet.Handle)
        Write-Host "  OptiCut legacy: first rectangle is sheet handle $($sheet.Handle), $($sheet.Width)x$($sheet.Height) mm." -ForegroundColor DarkCyan
    }
    $Document | Add-Member -NotePropertyName StockSheet -NotePropertyValue $sheet -Force
    $parts = [System.Collections.Generic.List[object]]::new()
    foreach ($rect in $rectangles) {
        if ($stockHandles.Contains([string]$rect.Handle)) { continue }
        if ($format -eq 'Layered' -and $rect.Layer -ine 'Parts') { continue }
        $parts.Add([pscustomobject]@{
            Id = $parts.Count; Entity = $rect.Entity; Handle = $rect.Handle
            Points = $rect.Points; MinX = $rect.MinX; MaxX = $rect.MaxX
            MinY = $rect.MinY; MaxY = $rect.MaxY
            Width = $rect.Width; Height = $rect.Height
            DimensionText = $null; FeatureLabel = $null; Orientation = $null
        })
    }
    if ($parts.Count -eq 0) { throw "No part outlines were detected for OptiCut format '$format'." }
    $dimensionTexts = @($texts | Where-Object { $null -ne $_.Dimension })
    if ($format -eq 'Legacy') {
        # Exact stage-2 left-edge dimension matching: both position AND size.
        foreach ($part in $parts) {
            $positionMatches = @($dimensionTexts | Where-Object { Test-TextInsidePart -Text $_ -Shape $part })
            $matches = @($positionMatches | Where-Object {
                $dim = $_.Dimension
                ([math]::Abs($dim.Width - $part.Width) -lt $sizeTolerance -and [math]::Abs($dim.Height - $part.Height) -lt $sizeTolerance) -or
                ([math]::Abs($dim.Width - $part.Height) -lt $sizeTolerance -and [math]::Abs($dim.Height - $part.Width) -lt $sizeTolerance)
            })
            if ($matches.Count -ne 1) { throw "Part handle '$($part.Handle)' ($($part.Width)x$($part.Height) mm) has $($matches.Count) dimension TEXT entities matching BOTH its location and actual dimensions; exactly one is required (nearby dimension labels: $($positionMatches.Count))." }
            $part.DimensionText = $matches[0]
        }
        $reusedDimensions = @($parts | Group-Object -Property { $_.DimensionText.EntityIndex } | Where-Object { $_.Count -gt 1 })
        if ($reusedDimensions.Count -gt 0) { throw 'A dimension TEXT was assigned to multiple part outlines; geometry is ambiguous.' }
    }
    # Layered format derives width/height from rectangular outlines, because
    # these OptiCut exports have NO corresponding dimension TEXT entities.
    $featureTexts = @($texts | Where-Object { $_.IsFeature })
    foreach ($text in $featureTexts) {
        $matches = if ($format -eq 'Layered') {
            @($parts | Where-Object { Test-TextAtPartCenter -Text $text -Shape $_ })
        } else {
            @($parts | Where-Object { Test-TextInsidePart -Text $text -Shape $_ })
        }
        if ($matches.Count -ne 1) {
            throw "Feature label '$($text.Value)' at ($($text.X),$($text.Y)) matches $($matches.Count) parts in OptiCut $format format; exactly one is required."
        }
        $text.Shape = $matches[0]
        if ($null -eq $text.Shape.Orientation) { $text.Shape.Orientation = Get-Orientation $text.Shape }
        if ($null -ne $text.Shape.FeatureLabel) {
            throw "Part handle '$($text.Shape.Handle)' has more than one feature label ('$($text.Shape.FeatureLabel)' and '$($text.Value)')."
        }
        $text.Shape.FeatureLabel = $text.Value
    }
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($text in $featureTexts) {
        $parameters = $text.Parameters
        $zParameters = $text.Parameters
        $hasSH = [bool]$text.HasSH; $hasZ = [bool]$text.HasZ
        if ($hasSH -and $parameters.GrooveOffset -le 0) { throw "Label '$($text.Value)' has invalid groove offset $($parameters.GrooveOffset) mm; offset must be positive." }
        if ($hasSH -and $parameters.GrooveOffset -ge [math]::Min($text.Shape.Width, $text.Shape.Height)) { throw "Label '$($text.Value)': groove offset $($parameters.GrooveOffset) mm must be smaller than the part's short dimension $([math]::Min($text.Shape.Width,$text.Shape.Height)) mm (part $($text.Shape.Width)x$($text.Shape.Height))." }
        $table = Get-TableNumber -Prefix $parameters.Prefix -Shape $text.Shape -Label $text.Value
        if ($hasZ) { Assert-ZNotchFitsPart -Shape $text.Shape -Label $text.Value -ZParameters $zParameters -Table $table }
        $records.Add([pscustomobject]@{ Label = $text.Value; Text = $text; Shape = $text.Shape; HasSH = $hasSH; HasZ = $hasZ; GrooveOffset = [double]$parameters.GrooveOffset; Prefix = $parameters.Prefix; NotchLongLength = [double]$zParameters.LongLength; NotchShortLength = [double]$zParameters.ShortLength; Table = $table; Role = $null; State = $null; GrooveEdge = $null; HandleEdges = @(); Corner = $null; IsPair = $false })
    }
    # SH+Z pairs are resolved across all source DXF files after every file is parsed.
    # SH-only and Z-only parts remain independent, using the original standalone rule.
    foreach ($record in $records) {
        if ($record.HasSH -and $record.HasZ) { continue }
        # Standalone SH-only or Z-only parts use the R row and their own orientation on both sides.
        $record.Role = 'R'; $record.State = Get-SymmetryState -FirstOrientation $record.Shape.Orientation -SecondOrientation $record.Shape.Orientation
        $rule = Get-TableRule -Table $record.Table -State $record.State -Role $record.Role
        $record.GrooveEdge = $rule.Groove; $record.HandleEdges = @($rule.Handles); $record.Corner = $rule.Corner
    }
    $Document.Parts = $parts.ToArray(); $Document.FeatureRecords = $records.ToArray()
    $Document.Stats = [pscustomobject]@{ PartCount = $parts.Count; DimensionCount = $(if ($format -eq 'Legacy') { $parts.Count } else { 0 }); FeatureCount = $records.Count; PairCount = 0; GrooveCount = @($records | Where-Object { $_.HasSH }).Count; HandleCount = @($records | Where-Object { $_.HasZ }).Count }
    return $Document
}
function Get-FilenamePairRole {
    param([string]$FileName)
    # Only standalone tokens count: R, L, Right, Left (case-insensitive).
    # Hyphens, underscores, spaces and parentheses are supported separators.
    # Words containing these letters (e.g. Drawer, Rail) must not set a role.
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $r = [regex]::IsMatch($stem, '(?i)(?:^|[^a-z0-9])(?:R|RIGHT)(?=$|[^a-z0-9])')
    $l = [regex]::IsMatch($stem, '(?i)(?:^|[^a-z0-9])(?:L|LEFT)(?=$|[^a-z0-9])')
    if ($r -and $l) { throw "File '$FileName' contains both R and L role markers; rename it unambiguously." }
    if ($r) { return 'R' }
    if ($l) { return 'L' }
    return $null
}
function Resolve-GlobalPairs {
    param([object[]]$Documents)
    # Documents arrive in the source-file name order (Sort-Object Name).
    # Within each file, preserve the original DXF TEXT entity order.
    $candidates = [System.Collections.Generic.List[object]]::new()
    for ($fileOrder = 0; $fileOrder -lt $Documents.Count; $fileOrder++) {
        $document = $Documents[$fileOrder]
        foreach ($record in $document.FeatureRecords) {
            if (-not ($record.HasSH -and $record.HasZ)) { continue }
            $candidates.Add([pscustomobject]@{
                Label = $record.Label
                Document = $document
                Record = $record
                FileOrder = $fileOrder
                EntityIndex = [int]$record.Text.EntityIndex
            })
        }
    }
    $pairGroups = @($candidates | Group-Object -Property Label)
    foreach ($group in $pairGroups) {
        if ($group.Count -ne 2) {
            $sources = (@($group.Group | ForEach-Object { $_.Document.File.Name }) -join ', ')
            throw "Label '$($group.Name)' contains SH and Z and must occur exactly twice across folder A; found $($group.Count) in file(s): $sources."
        }
        $members = @($group.Group | Sort-Object FileOrder, EntityIndex)
        # Original behavior is preserved when both TEXT labels are in one DXF:
        # smaller EntityIndex is R and larger EntityIndex is L.
        # For different files, explicit filename roles take precedence over name order.
        if (-not [object]::ReferenceEquals($members[0].Document, $members[1].Document)) {
            $role0 = Get-FilenamePairRole -FileName $members[0].Document.File.Name
            $role1 = Get-FilenamePairRole -FileName $members[1].Document.File.Name
            if ($null -ne $role0 -and $null -ne $role1 -and $role0 -eq $role1) {
                throw "Pair '$($group.Name)': both files claim role '$role0' ('$($members[0].Document.File.Name)' and '$($members[1].Document.File.Name)')."
            }
            # A single explicit marker determines the counterpart's opposite role.
            # With no explicit markers, use the existing alphabetical filename order.
            $swap = ($role0 -eq 'L') -or ($role1 -eq 'R')
            if ($swap) { $members = @($members[1], $members[0]) }
        }
        $first = $members[0].Record; $second = $members[1].Record
        if ([object]::ReferenceEquals($first.Shape, $second.Shape)) { throw "Pair label '$($group.Name)' resolves twice to the same part outline." }
        if ($first.Table -ne $second.Table) {
            throw "Pair '$($group.Name)' selects inconsistent tables in '$($members[0].Document.File.Name)' and '$($members[1].Document.File.Name)'."
        }
        $state = Get-SymmetryState -FirstOrientation $first.Shape.Orientation -SecondOrientation $second.Shape.Orientation
        Write-Host "  Pair '$($group.Name)': R $($members[0].Document.File.Name) [TEXT $($members[0].EntityIndex)] -> L $($members[1].Document.File.Name) [TEXT $($members[1].EntityIndex)] | $state" -ForegroundColor DarkCyan
        foreach ($index in 0,1) {
            $role = if ($index -eq 0) { 'R' } else { 'L' }
            $record = $members[$index].Record
            $rule = Get-TableRule -Table $record.Table -State $state -Role $role
            $record.Role = $role; $record.State = $state; $record.GrooveEdge = $rule.Groove; $record.HandleEdges = @($rule.Handles); $record.Corner = $rule.Corner; $record.IsPair = $true
        }
    }
    foreach ($document in $Documents) {
        $document.Stats.PairCount = @($document.FeatureRecords | Where-Object { $_.IsPair } | Group-Object -Property Label).Count
    }
}
function Apply-DxfPlan {
    param([object]$Document)
    [uint64]$nextHandle = Get-NextHandle $Document.Pairs
    $layer2Exists = Test-LayerExists -Pairs $Document.Pairs -Name '2'
    $layerHandle = $null
    if (-not $layer2Exists) { $layerHandle = $nextHandle.ToString('X'); $nextHandle++ }
    $sourceEntityCount = $Document.Entities.Count
    $sourceEntityHandles = @($Document.Entities | ForEach-Object { Get-FirstValue $_ 5 } | Where-Object { $null -ne $_ -and $_ -ne '' })
    $notchCount = 0; $slotCount = 0
    $slotEntities = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Document.FeatureRecords) {
        if ($record.HasZ) {
            $newPoints = Get-NotchedVertices -Shape $record.Shape -Corner $record.Corner -LongLength $record.NotchLongLength -ShortLength $record.NotchShortLength -Table $record.Table
            if ($newPoints.Count -ne 6) { throw "Handle notch for label '$($record.Label)' did not produce exactly six outline vertices." }
            Set-PolylineVertices -Entity $record.Shape.Entity -Points $newPoints
            $notchCount++
        }
        if ($record.HasSH) {
            $handle = $nextHandle.ToString('X'); $nextHandle++
            $slotEntity = New-SlotLineEntity -Handle $handle -Edge $record.GrooveEdge -Shape $record.Shape -Offset $record.GrooveOffset
            $Document.Entities.Add($slotEntity)
            $slotEntities.Add($slotEntity)
            $slotCount++
        }
    }
    $finalPairs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Document.EntityBodyStart; $i++) { $finalPairs.Add($Document.Pairs[$i]) }
    foreach ($entity in $Document.Entities) { foreach ($pair in $entity.Pairs) { $finalPairs.Add($pair) } }
    for ($i = $Document.EntityBodyEnd; $i -lt $Document.Pairs.Count; $i++) { $finalPairs.Add($Document.Pairs[$i]) }
    if (-not $layer2Exists) { Add-Layer2 -Pairs $finalPairs -Handle $layerHandle }
    Update-Handseed -Pairs $finalPairs -NextHandle $nextHandle
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in $finalPairs) { $lines.Add([string]$pair.CodeText); $lines.Add([string]$pair.Value) }
    return [pscustomobject]@{ Source = $Document.File; OutputName = $Document.File.Name; Lines = $lines.ToArray(); NotchCount = $notchCount; SlotCount = $slotCount; Stats = $Document.Stats; Document = $Document; SourceEntityCount = $sourceEntityCount; SourceEntityHandles = $sourceEntityHandles; SlotEntities = $slotEntities.ToArray() }
}
function Test-GeneratedDxf {
    param([System.IO.FileInfo]$File, [object]$Plan)
    $parsed = Read-DxfDocument $File
    $expectedCount = [int]$Plan.SourceEntityCount + [int]$Plan.SlotCount
    if ($parsed.Entities.Count -ne $expectedCount) { throw "Round-trip verification failed for '$($File.Name)': expected $expectedCount entities, found $($parsed.Entities.Count)." }
    if (-not (Test-LayerExists -Pairs $parsed.Pairs -Name '2')) { throw "Round-trip verification failed for '$($File.Name)': DXF layer 2 is missing." }
    foreach ($handle in $Plan.SourceEntityHandles) {
        $matches = @($parsed.Entities | Where-Object { (Get-FirstValue $_ 5) -eq $handle })
        if ($matches.Count -ne 1) { throw "Round-trip verification failed for '$($File.Name)': source handle '$handle' appears $($matches.Count) times." }
    }
    foreach ($record in $Plan.Document.FeatureRecords) {
        $handle = [string]$record.Shape.Handle
        $matches = @($parsed.Entities | Where-Object { (Get-FirstValue $_ 5) -eq $handle })
        if ($matches.Count -ne 1 -or $matches[0].Type -ne 'LWPOLYLINE') { throw "Round-trip verification failed for label '$($record.Label)': outline handle '$handle' is missing or duplicated." }
        $expectedPoints = Get-EntityVertices $record.Shape.Entity
        $actualPoints = Get-EntityVertices $matches[0]
        if ($expectedPoints.Count -ne $actualPoints.Count) { throw "Round-trip verification failed for label '$($record.Label)': outline vertex count changed." }
        for ($i = 0; $i -lt $expectedPoints.Count; $i++) {
            if ([math]::Abs([double]$expectedPoints[$i].X - [double]$actualPoints[$i].X) -gt 0.001 -or [math]::Abs([double]$expectedPoints[$i].Y - [double]$actualPoints[$i].Y) -gt 0.001) { throw "Round-trip verification failed for label '$($record.Label)' at outline vertex $($i + 1)." }
        }
        $actualBounds = Get-EntityBounds $actualPoints
        foreach ($field in @('MinX','MaxX','MinY','MaxY')) {
            if ([math]::Abs([double]$actualBounds.$field - [double]$record.Shape.$field) -gt 0.001) { throw "Round-trip verification failed for label '$($record.Label)': outline bounds changed ($field)." }
        }
        if ($record.HasZ -and $actualPoints.Count -ne 6) { throw "Round-trip verification failed for label '$($record.Label)': handle notch is not represented by six vertices." }
    }
    foreach ($expectedLine in $Plan.SlotEntities) {
        $handle = Get-FirstValue $expectedLine 5
        $matches = @($parsed.Entities | Where-Object { (Get-FirstValue $_ 5) -eq $handle })
        if ($matches.Count -ne 1 -or $matches[0].Type -ne 'LINE') { throw "Round-trip verification failed: groove line handle '$handle' is missing or duplicated." }
        if ((Get-FirstValue $matches[0] 8) -ne '2') { throw "Round-trip verification failed: groove line '$handle' is not on layer 2." }
        foreach ($code in @(10,20,30,11,21,31)) {
            $expectedValue = Get-FirstValue $expectedLine $code
            $actualValue = Get-FirstValue $matches[0] $code
            if ($null -eq $expectedValue -or $null -eq $actualValue) { throw "Round-trip verification failed: groove line '$handle' is missing coordinate code $code." }
            if ([math]::Abs((ConvertFrom-DxfNumber $expectedValue) - (ConvertFrom-DxfNumber $actualValue)) -gt 0.001) { throw "Round-trip verification failed: groove line '$handle' coordinate code $code changed." }
        }
    }
    return $true
}

try {
    Write-Host ''
    Write-Host '=== Independent DXF Generator for CNC Parts ===' -ForegroundColor Cyan
    Write-Host "Input: $sourceFolder"
    Write-Host "Output: $outputFolder"
    if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) { throw "Input folder not found: $sourceFolder" }
    $files = @(Get-ChildItem -LiteralPath $sourceFolder -File | Where-Object { $_.Extension -match '^\.dxf$' } | Sort-Object Name)
    if ($files.Count -eq 0) { throw "No DXF files found in folder $sourceFolder." }
    Write-Host "Number of input files: $($files.Count)" -ForegroundColor Cyan

    $documents = [System.Collections.Generic.List[object]]::new(); $validationErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        Write-Host "`n[Validating] $($file.Name)" -ForegroundColor Yellow
        try {
            $doc = Read-DxfDocument $file
            $doc = Build-DxfPlan $doc
            $documents.Add($doc)
        } catch {
            $message = "$($file.Name): $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
        }
    }
    if ($validationErrors.Count -eq 0) {
        try { Resolve-GlobalPairs -Documents $documents.ToArray() }
        catch {
            $message = "Global SH+Z pairing: $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
        }
    }
    if ($validationErrors.Count -gt 0) {
        Write-Host "`nGeneration stopped; no new output files were written and existing files in folder B were preserved." -ForegroundColor Red
        foreach ($message in $validationErrors) { Write-Host " - $message" -ForegroundColor Red }
        throw 'Validation failed for one or more input files.'
    }
    if ($validationErrors.Count -eq 0) {
        try { Assert-CncGeometry -Documents $documents.ToArray() }
        catch {
            $message = "Geometry validation: $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
            Write-Host "`nGeneration stopped; geometry check failed; folder B was not changed." -ForegroundColor Red
            throw 'Geometry safety validation failed.'
        }
    }
    foreach ($doc in $documents) {
        Write-Host "  Detected OptiCut format: $($doc.OptiCutFormat) ($($doc.File.Name))" -ForegroundColor DarkCyan
        Write-Host "  Verified $($doc.File.Name): parts $($doc.Stats.PartCount), dimension TEXT checked $($doc.Stats.DimensionCount), feature labels $($doc.Stats.FeatureCount), pairs $($doc.Stats.PairCount), grooves $($doc.Stats.GrooveCount), handle notches $($doc.Stats.HandleCount)" -ForegroundColor Green
        foreach ($mark in $doc.FeatureRecords) {
            $actionParts = [System.Collections.Generic.List[string]]::new()
            if ($mark.HasSH) { $actionParts.Add("Groove $($mark.GrooveEdge), offset $($mark.GrooveOffset) mm") }
            if ($mark.HasZ) { $actionParts.Add("Notch $($mark.Corner); edges $($mark.HandleEdges -join '+')") }
            $mapping = if ($mark.IsPair) { "$($mark.State)/$($mark.Role)" } else { "Standalone/$($mark.Shape.Orientation)" }
            Write-Host "    $($mark.Label) | Handle $($mark.Shape.Handle) | $($mark.Shape.Width)x$($mark.Shape.Height) | Table $($mark.Table) | $mapping | $($actionParts -join '; ')" -ForegroundColor DarkCyan
        }
    }
    Write-Host "`nAll input files validated successfully; starting in-memory generation." -ForegroundColor Green

    $generated = [System.Collections.Generic.List[object]]::new()
    foreach ($doc in $documents) {
        try { $generated.Add((Apply-DxfPlan $doc)) }
        catch { throw "Error preparing output for '$($doc.File.Name)'; no output files have been written yet. Details: $($_.Exception.Message)" }
    }
    if ($ValidateOnly) {
        $verifyFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('.dxf-verify-' + [guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path $verifyFolder)
            foreach ($item in $generated) {
                $verifyPath = Join-Path $verifyFolder $item.OutputName
                [System.IO.File]::WriteAllLines($verifyPath, $item.Lines, [System.Text.UTF8Encoding]::new($false))
                [void](Test-GeneratedDxf -File (Get-Item -LiteralPath $verifyPath) -Plan $item)
            }
        } finally {
            if (Test-Path -LiteralPath $verifyFolder) { Remove-Item -LiteralPath $verifyFolder -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Write-Host "`nValidation, in-memory generation, and DXF round-trip verification succeeded; no files were written to B because ValidateOnly was specified." -ForegroundColor Green
        foreach ($item in $generated) { Write-Host "  $($item.Source.Name): handle notches $($item.NotchCount), groove lines $($item.SlotCount), DXF round-trip verification: passed" -ForegroundColor Green }
        return
    }

    # Before writing a new batch, clear ALL previous contents of B (including subfolders).
    # This intentionally runs only in normal mode, never with -ValidateOnly.
    $inputAbsolute = [System.IO.Path]::GetFullPath($sourceFolder).TrimEnd([char[]]@('\','/'))
    $outputAbsolute = [System.IO.Path]::GetFullPath($outputFolder).TrimEnd([char[]]@('\','/'))
    $desktopAbsolute = [System.IO.Path]::GetFullPath($desktop).TrimEnd([char[]]@('\','/'))
    if ($outputAbsolute -ieq $inputAbsolute -or $outputAbsolute -ieq $desktopAbsolute) {
        throw 'Unsafe output path: refusing to clear the input folder or Desktop.'
    }
    if (-not (Test-Path -LiteralPath $outputFolder -PathType Container)) { [void](New-Item -ItemType Directory -Path $outputFolder) }
    $previousItems = @(Get-ChildItem -LiteralPath $outputFolder -Force)
    if ($previousItems.Count -gt 0) {
        Write-Host "`nClearing folder B: $($previousItems.Count) old item(s)..." -ForegroundColor Yellow
        foreach ($previousItem in $previousItems) {
            Remove-Item -LiteralPath $previousItem.FullName -Recurse -Force -ErrorAction Stop
        }
    }

    # Stage every output before replacing anything. If commit fails, backups are restored.
    $token = [guid]::NewGuid().ToString('N')
    $stageFolder = Join-Path $outputFolder ".dxf-stage-$token"
    $backupFolder = Join-Path $outputFolder ".dxf-backup-$token"
    [void](New-Item -ItemType Directory -Path $stageFolder)
    [void](New-Item -ItemType Directory -Path $backupFolder)
    $backedUp = [System.Collections.Generic.List[string]]::new(); $installed = [System.Collections.Generic.List[string]]::new(); $preserveBackup = $false
    try {
        foreach ($item in $generated) {
            $stagePath = Join-Path $stageFolder $item.OutputName
            [System.IO.File]::WriteAllLines($stagePath, $item.Lines, [System.Text.UTF8Encoding]::new($false))
        }
        foreach ($item in $generated) {
            $stagePath = Join-Path $stageFolder $item.OutputName
            [void](Test-GeneratedDxf -File (Get-Item -LiteralPath $stagePath) -Plan $item)
        }
        foreach ($item in $generated) {
            $target = Join-Path $outputFolder $item.OutputName
            $backup = Join-Path $backupFolder $item.OutputName
            if (Test-Path -LiteralPath $target -PathType Leaf) { [System.IO.File]::Move($target, $backup); $backedUp.Add($target) }
            [System.IO.File]::Move((Join-Path $stageFolder $item.OutputName), $target)
            $installed.Add($target)
        }
    } catch {
        $commitError = $_.Exception.Message
        foreach ($target in $installed) { if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue } }
        foreach ($target in $backedUp) {
            $backup = Join-Path $backupFolder ([System.IO.Path]::GetFileName($target))
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                try { [System.IO.File]::Move($backup, $target) }
                catch { $preserveBackup = $true; Write-Host "Automatic restore failed; backup preserved at: $backupFolder" -ForegroundColor Red }
            }
        }
        throw "Failed to write output files; previous outputs were restored or backups were preserved for manual recovery. Details: $commitError"
    } finally {
        if (Test-Path -LiteralPath $stageFolder) { Remove-Item -LiteralPath $stageFolder -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $preserveBackup -and (Test-Path -LiteralPath $backupFolder)) { Remove-Item -LiteralPath $backupFolder -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "`n=== Generation Successful ===" -ForegroundColor Green
    foreach ($item in $generated) {
        Write-Host "  $($item.Source.Name) -> $(Join-Path $outputFolder $item.OutputName) | Parts: $($item.Stats.PartCount) | Handle notches: $($item.NotchCount) | Groove lines: $($item.SlotCount)" -ForegroundColor Green
    }
    Write-Host 'Input files in A were not modified. The OptiCut TXT output is also unchanged.' -ForegroundColor Green
    Write-Host ''
} catch {
    Write-Host "`nStopped: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
