# Video Dehydrator engine.
# Dot-source this file from the window. Running it directly is for tests.
#
# The PhilipMedia library signed off 1920x1080 at 3000 kbps video, with a
# file treated as too big at 2 GiB per hour (3 GiB per hour when it is
# already HEVC or AV1). This engine scales those three numbers by picture
# area, so 4K is allowed four times the bits per second of 1080p and 720p
# is allowed less. Encode settings otherwise match the library job:
# software x265, 2-pass turbo, medium, no crop, audio copy, subtitle copy,
# never burn subtitles.

$script:AudioCopyMask = 'aac,ac3,eac3,truehd,dts,dtshd,mp2,mp3,flac,opus'
# AC-3 frame size in 16-bit words, from the ATSC table ffmpeg uses.
# Row is frmsizecod 0..37. Column is 48 kHz, 44.1 kHz, 32 kHz.
$script:Ac3FrameWords = @(
    ,@(64, 69, 96)
    ,@(64, 70, 96)
    ,@(80, 87, 120)
    ,@(80, 88, 120)
    ,@(96, 104, 144)
    ,@(96, 105, 144)
    ,@(112, 121, 168)
    ,@(112, 122, 168)
    ,@(128, 139, 192)
    ,@(128, 140, 192)
    ,@(160, 174, 240)
    ,@(160, 175, 240)
    ,@(192, 208, 288)
    ,@(192, 209, 288)
    ,@(224, 243, 336)
    ,@(224, 244, 336)
    ,@(256, 278, 384)
    ,@(256, 279, 384)
    ,@(320, 348, 480)
    ,@(320, 349, 480)
    ,@(384, 417, 576)
    ,@(384, 418, 576)
    ,@(448, 487, 672)
    ,@(448, 488, 672)
    ,@(512, 557, 768)
    ,@(512, 558, 768)
    ,@(640, 696, 960)
    ,@(640, 697, 960)
    ,@(768, 835, 1152)
    ,@(768, 836, 1152)
    ,@(896, 975, 1344)
    ,@(896, 976, 1344)
    ,@(1024, 1114, 1536)
    ,@(1024, 1115, 1536)
    ,@(1152, 1253, 1728)
    ,@(1152, 1254, 1728)
    ,@(1280, 1393, 1920)
    ,@(1280, 1394, 1920)
)
$script:ReferencePixels = [double](1920 * 1080)
$script:ReferenceKbps = 3000
$script:ReferenceBudgetGiBph = 2.0
$script:ReferenceHevcGiBph = 3.0
$script:MinimumKbps = 200
# Listed picture sizes. A file uses the nearest one, then the user's budget
# multiple for that size. Recommended is 1, so these reference numbers stay put.
$script:BudgetPicks = @{}
$script:CompareHalfWidth = 960
$script:CompareHalfHeight = 540
# Preview rate. The window shows one of these frames per wall-clock interval,
# so the picture stays with the sound instead of running at decode speed.
$script:CompareFps = 12
$script:VideoExtensions = @{
    '.avi' = $true; '.mpg' = $true; '.mpeg' = $true; '.mp4' = $true
    '.mkv' = $true; '.m4v' = $true; '.wmv' = $true; '.mov' = $true
    '.ts' = $true; '.vob' = $true; '.m2ts' = $true; '.webm' = $true
    '.flv' = $true; '.divx' = $true
}

function Get-BundledTools {
    $app = $PSScriptRoot
    if (-not $app) { $app = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $root = Split-Path -Parent $app
    $tools = Join-Path $root 'tools'
    return [pscustomobject]@{
        Root      = $root
        Tools     = $tools
        Ffmpeg    = (Join-Path $tools 'ffmpeg.exe')
        Ffprobe   = (Join-Path $tools 'ffprobe.exe')
        Ffplay    = (Join-Path $tools 'ffplay.exe')
        HandBrake = (Join-Path $tools 'HandBrakeCLI.exe')
    }
}

function ConvertTo-QuotedArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\s"&<>|^()]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function ConvertTo-ArgumentLine {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join ' ')
}

function Get-NoteProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = ConvertTo-ArgumentLine $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $outText = $outTask.Result
    $errText = $errTask.Result
    if (-not $outText) { $outText = '' }
    if (-not $errText) { $errText = '' }
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $outText
        StdErr   = $errText
    }
}

function Get-PictureScale {
    param([int]$Width, [int]$Height)
    if ($Width -le 0 -or $Height -le 0) { return $null }
    return ($Width * [double]$Height) / $script:ReferencePixels
}

function Get-BudgetAnchors {
    return @(
        @{ Id = '2160'; Name = '2160p'; Width = 3840; Height = 2160 }
        @{ Id = '1080'; Name = '1080p'; Width = 1920; Height = 1080 }
        @{ Id = '720'; Name = '720p'; Width = 1280; Height = 720 }
        @{ Id = '480'; Name = '480p'; Width = 720; Height = 480 }
    )
}

function Get-BudgetFactorTable {
    return @(
        @{ Id = 'half'; Label = 'Half'; Factor = 0.5 }
        @{ Id = 'recommended'; Label = 'Recommended'; Factor = 1.0 }
        @{ Id = 'plus'; Label = '1.5 times'; Factor = 1.5 }
        @{ Id = 'double'; Label = 'Double'; Factor = 2.0 }
    )
}

function Get-NearestBudgetAnchor {
    param([int]$Width, [int]$Height)
    $pixels = [double]$Width * [double]$Height
    $best = $null
    $bestDistance = [double]::MaxValue
    foreach ($anchor in (Get-BudgetAnchors)) {
        $anchorPixels = [double]$anchor.Width * [double]$anchor.Height
        $distance = [math]::Abs($pixels - $anchorPixels)
        if ($distance -lt $bestDistance) {
            $bestDistance = $distance
            $best = $anchor
        }
    }
    return $best
}

function Get-BudgetPickFactor {
    param([int]$Width, [int]$Height)
    $anchor = Get-NearestBudgetAnchor -Width $Width -Height $Height
    $pick = 'recommended'
    if ($anchor -and $script:BudgetPicks -and $script:BudgetPicks.ContainsKey([string]$anchor.Id)) {
        $pick = [string]$script:BudgetPicks[[string]$anchor.Id]
    }
    foreach ($row in (Get-BudgetFactorTable)) {
        if ($row.Id -eq $pick) { return [double]$row.Factor }
    }
    return 1.0
}

function Set-BudgetPicks {
    param([string]$Packed)
    $script:BudgetPicks = @{}
    foreach ($anchor in (Get-BudgetAnchors)) {
        $script:BudgetPicks[[string]$anchor.Id] = 'recommended'
    }
    if (-not $Packed) { return }
    foreach ($part in ($Packed -split ';')) {
        if ($part -notmatch '^(\d+)=([A-Za-z0-9.]+)$') { continue }
        $id = $Matches[1]
        $choice = $Matches[2]
        if (-not $script:BudgetPicks.ContainsKey($id)) { continue }
        $known = $false
        foreach ($row in (Get-BudgetFactorTable)) {
            if ($row.Id -eq $choice) { $known = $true }
        }
        if ($known) { $script:BudgetPicks[$id] = $choice }
    }
}

function Get-BudgetPickPack {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($anchor in (Get-BudgetAnchors)) {
        $pick = 'recommended'
        $id = [string]$anchor.Id
        if ($script:BudgetPicks -and $script:BudgetPicks.ContainsKey($id)) { $pick = [string]$script:BudgetPicks[$id] }
        $parts.Add($id + '=' + $pick)
    }
    return ($parts -join ';')
}

function Get-AnchorBudget {
    param($Anchor, [string]$PickId, [bool]$Efficient)
    $scale = Get-PictureScale -Width ([int]$Anchor.Width) -Height ([int]$Anchor.Height)
    $factor = 1.0
    foreach ($row in (Get-BudgetFactorTable)) {
        if ($row.Id -eq $PickId) { $factor = [double]$row.Factor }
    }
    $base = $script:ReferenceBudgetGiBph
    if ($Efficient) { $base = $script:ReferenceHevcGiBph }
    $kbps = [int][math]::Round($script:ReferenceKbps * $scale * $factor)
    if ($kbps -lt $script:MinimumKbps) { $kbps = $script:MinimumKbps }
    return [pscustomobject]@{
        GiBph     = ($base * $scale * $factor)
        HevcGiBph = ($script:ReferenceHevcGiBph * $scale * $factor)
        Kbps      = $kbps
    }
}

function Format-BudgetGiB {
    param([double]$GiBPerHour)
    $text = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.##}', $GiBPerHour)
    return ($text + ' GiB/h')
}

function Get-BudgetChoiceLabel {
    param($Anchor, [string]$PickId)
    $label = $PickId
    foreach ($row in (Get-BudgetFactorTable)) {
        if ($row.Id -eq $PickId) { $label = [string]$row.Label }
    }
    $gib = (Get-AnchorBudget -Anchor $Anchor -PickId $PickId).GiBph
    return ($label + ', ' + (Format-BudgetGiB $gib))
}

Set-BudgetPicks ''

function Get-TargetKbps {
    param([int]$Width, [int]$Height)
    $scale = Get-PictureScale -Width $Width -Height $Height
    if ($null -eq $scale) { return $null }
    $factor = Get-BudgetPickFactor -Width $Width -Height $Height
    $kbps = [int][math]::Round($script:ReferenceKbps * $scale * $factor)
    if ($kbps -lt $script:MinimumKbps) { $kbps = $script:MinimumKbps }
    return $kbps
}

function Get-BudgetGiBPerHour {
    param([int]$Width, [int]$Height, [bool]$Efficient)
    $scale = Get-PictureScale -Width $Width -Height $Height
    if ($null -eq $scale) { return $null }
    $factor = Get-BudgetPickFactor -Width $Width -Height $Height
    $base = $script:ReferenceBudgetGiBph
    if ($Efficient) { $base = $script:ReferenceHevcGiBph }
    return $base * $scale * $factor
}

function Get-GiBPerHour {
    param([int64]$Bytes, [double]$Seconds)
    if ($Seconds -le 0) { return $null }
    return ($Bytes / 1GB) / ($Seconds / 3600.0)
}

function Format-ByteSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:0.00} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:0.0} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:0} KiB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-Clock {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds)) { $Seconds = 0 }
    $span = [TimeSpan]::FromSeconds([int][math]::Round($Seconds))
    if ($span.TotalHours -ge 1) {
        return '{0}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds
    }
    return '{0}:{1:00}' -f $span.Minutes, $span.Seconds
}

function Format-Rate {
    param($GiBPerHour)
    if ($null -eq $GiBPerHour) { return '' }
    return ('{0:0.00}' -f [double]$GiBPerHour)
}

function Get-OverRatio($GiBph, $BudgetGiBph) {
    if ($null -eq $GiBph -or $null -eq $BudgetGiBph) { return $null }
    if ([string]$GiBph -eq '' -or [string]$BudgetGiBph -eq '') { return $null }
    $used = [double]$GiBph
    $budget = [double]$BudgetGiBph
    if ($budget -le 0) { return $null }
    return ($used / $budget)
}

function Get-OverBandId($Ratio) {
    if ($null -eq $Ratio -or [string]$Ratio -eq '') { return '' }
    $value = [double]$Ratio
    if ($value -lt 1) { return '' }
    if ($value -lt 1.5) { return 'slight' }
    if ($value -lt 3) { return 'heavy' }
    return 'extreme'
}

function Format-OverRatio($Ratio) {
    if ($null -eq $Ratio -or [string]$Ratio -eq '') { return '' }
    $value = [double]$Ratio
    $places = 2
    if ($value -gt 1) {
        while ($places -lt 4 -and ([math]::Round($value, $places) -le 1)) { $places++ }
    }
    $text = [math]::Round($value, $places).ToString(('0.' + ('0' * $places)), [Globalization.CultureInfo]::InvariantCulture)
    return ($text + 'x')
}

function Get-HandBrakeFraction {
    param([string]$Line)
    if ($Line -notmatch 'Encoding:\s*task\s+(\d+)\s+of\s+(\d+),\s*([\d.]+)\s*%') { return $null }
    $task = [int]$Matches[1]
    $tasks = [int]$Matches[2]
    $part = 0.0
    [void][double]::TryParse($Matches[3], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$part)
    if ($tasks -lt 1) { $tasks = 1 }
    if ($task -lt 1) { $task = 1 }
    if ($task -gt $tasks) { $task = $tasks }
    $overall = (($task - 1) + ($part / 100.0)) / $tasks * 100.0
    if ($overall -lt 0) { $overall = 0 }
    if ($overall -gt 100) { $overall = 100 }
    return $overall
}

function Get-MediaProbe {
    param(
        [Parameter(Mandatory)][string]$Ffprobe,
        [Parameter(Mandatory)][string]$File
    )
    $run = Invoke-CapturedProcess -File $Ffprobe -Arguments @(
        '-v', 'error', '-show_format', '-show_streams', '-print_format', 'json', '--', $File
    )
    if (-not $run.StdOut) { throw "ffprobe returned nothing for $File" }
    $json = $run.StdOut | ConvertFrom-Json
    $streams = @(Get-NoteProperty $json 'streams')
    $video = $null
    foreach ($stream in $streams) {
        if ((Get-NoteProperty $stream 'codec_type') -ne 'video') { continue }
        $disposition = Get-NoteProperty $stream 'disposition'
        $attached = Get-NoteProperty $disposition 'attached_pic'
        if ([string]$attached -eq '1') { continue }
        $width = 0
        [void][int]::TryParse([string](Get-NoteProperty $stream 'width'), [ref]$width)
        if ($width -le 0) { continue }
        $video = $stream
        break
    }
    if (-not $video) { throw "No video picture in $File" }

    $audio = @($streams | Where-Object { (Get-NoteProperty $_ 'codec_type') -eq 'audio' })
    $subs = @($streams | Where-Object { (Get-NoteProperty $_ 'codec_type') -eq 'subtitle' })
    $format = Get-NoteProperty $json 'format'
    $duration = 0.0
    $durationRaw = Get-NoteProperty $format 'duration'
    if ($durationRaw) { [void][double]::TryParse([string]$durationRaw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) }
    $size = [int64]0
    $sizeRaw = Get-NoteProperty $format 'size'
    if ($sizeRaw) { [void][int64]::TryParse([string]$sizeRaw, [ref]$size) }
    if ($size -le 0 -and (Test-Path -LiteralPath $File)) {
        $size = (Get-Item -LiteralPath $File).Length
    }

    $sideTypes = New-Object System.Collections.Generic.List[string]
    foreach ($side in @($(Get-NoteProperty $video 'side_data_list'))) {
        $sideType = Get-NoteProperty $side 'side_data_type'
        if ($sideType) { [void]$sideTypes.Add([string]$sideType) }
    }
    $sideBlob = ($sideTypes -join ' | ')
    $tag = [string](Get-NoteProperty $video 'codec_tag_string')
    $isDovi = $false
    if ($tag -match '^(dvhe|dvh1|dva1|dvav)$') { $isDovi = $true }
    if ($sideBlob -match 'DOVI|Dolby Vision|dovi') { $isDovi = $true }
    if ($null -ne (Get-NoteProperty $video 'dovi_configuration')) { $isDovi = $true }

    $transfer = [string](Get-NoteProperty $video 'color_transfer')
    $isHdr10Plus = ($sideBlob -match 'HDR10\+|SMPTE2094-40|SMPTE 2094')
    $isHdr10 = ($transfer -eq 'smpte2084') -or ($sideBlob -match 'Mastering display|Content light level')
    $isHlg = ($transfer -eq 'arib-std-b67')
    $pix = [string](Get-NoteProperty $video 'pix_fmt')
    $field = [string](Get-NoteProperty $video 'field_order')
    $isInterlaced = ($field -and $field -notin @('progressive', 'unknown', ''))
    $codec = [string](Get-NoteProperty $video 'codec_name')
    $height = 0
    [void][int]::TryParse([string](Get-NoteProperty $video 'height'), [ref]$height)
    $width = 0
    [void][int]::TryParse([string](Get-NoteProperty $video 'width'), [ref]$width)
    $videoBitrate = Get-StreamBitrate $video $duration

    return [pscustomobject]@{
        Path             = $File
        DurationSec      = $duration
        SizeBytes        = $size
        VideoCodec       = $codec
        Width            = $width
        Height           = $height
        PixFmt           = $pix
        FieldOrder       = $field
        ColorTransfer    = $transfer
        CodecTag         = $tag
        Is10Bit          = ($pix -match 'p10|10le|10be')
        IsInterlaced     = [bool]$isInterlaced
        IsDolbyVision    = [bool]$isDovi
        IsHdr10Plus      = [bool]$isHdr10Plus
        IsHdr10          = [bool]$isHdr10
        IsHlg            = [bool]$isHlg
        AudioCodecs      = @($audio | ForEach-Object { [string](Get-NoteProperty $_ 'codec_name') })
        AudioCount       = @($audio).Count
        SubCodecs        = @($subs | ForEach-Object { [string](Get-NoteProperty $_ 'codec_name') })
        SubCount         = @($subs).Count
        SideData         = $sideBlob
        AlreadyEfficient = ($codec -in @('hevc', 'h265', 'av1'))
        VideoBitrate     = $videoBitrate
    }
}

function ConvertTo-PositiveInt64([string]$Text) {
    $value = [int64]0
    if ([string]::IsNullOrWhiteSpace($Text)) { return [int64]0 }
    if (-not [int64]::TryParse($Text.Trim(), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return [int64]0
    }
    if ($value -le 0) { return [int64]0 }
    return $value
}

function Get-TaggedText($tags, [string]$Name) {
    if ($null -eq $tags -or -not $Name) { return '' }
    $direct = Get-NoteProperty $tags $Name
    if ($null -ne $direct -and [string]$direct -ne '') { return [string]$direct }
    $prefix = $Name + '-'
    foreach ($property in @($tags.PSObject.Properties)) {
        $propertyName = [string]$property.Name
        if (-not $propertyName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($null -ne $property.Value -and [string]$property.Value -ne '') { return [string]$property.Value }
    }
    return ''
}

function Get-StreamBitrate($stream, [double]$DurationSec) {
    if ($null -eq $stream) { return [int64]0 }
    $bits = ConvertTo-PositiveInt64 ([string](Get-NoteProperty $stream 'bit_rate'))
    if ($bits -gt 0) { return $bits }
    $tags = Get-NoteProperty $stream 'tags'
    $tagged = ConvertTo-PositiveInt64 (Get-TaggedText $tags 'BPS')
    if ($tagged -gt 0) { return $tagged }
    if ($DurationSec -gt 0) {
        $bytes = ConvertTo-PositiveInt64 (Get-TaggedText $tags 'NUMBER_OF_BYTES')
        if ($bytes -gt 0) { return [int64][math]::Round(($bytes * 8.0) / $DurationSec) }
    }
    return [int64]0
}

function Get-EstimatedBytes {
    param($Probe, [int]$TargetKbps)
    if ($null -eq $Probe) { return $null }
    if ($Probe.DurationSec -le 0) { return $null }
    if ($TargetKbps -le 0) { return $null }
    $other = 0.0
    if ($Probe.VideoBitrate -gt 0 -and $Probe.SizeBytes -gt 0) {
        $fileBps = ($Probe.SizeBytes * 8.0) / $Probe.DurationSec
        $other = $fileBps - $Probe.VideoBitrate
        if ($other -lt 0) { $other = 0 }
    }
    $estimate = (($TargetKbps * 1000.0) + $other) * $Probe.DurationSec / 8.0
    if ($estimate -lt 0) { return $null }
    return [int64][math]::Round($estimate)
}

function Test-ShrinkablePicture($Probe, [int]$TargetKbps, $Estimate) {
    if ($null -eq $Probe -or $TargetKbps -le 0) { return $false }
    if ($Probe.VideoBitrate -le 0 -or $Probe.SizeBytes -le 0 -or $Probe.DurationSec -le 0) { return $false }
    if ($null -eq $Estimate -or [int64]$Estimate -le 0 -or [int64]$Estimate -ge [int64]$Probe.SizeBytes) { return $false }
    $fileBps = ($Probe.SizeBytes * 8.0) / $Probe.DurationSec
    if ($fileBps -le 0 -or $Probe.VideoBitrate -lt ($fileBps * 0.4)) { return $false }
    return ($Probe.VideoBitrate -gt ($TargetKbps * 1000.0 * 1.05))
}

function Get-BloatDecision {
    param($Probe)
    $scale = Get-PictureScale -Width $Probe.Width -Height $Probe.Height
    $target = Get-TargetKbps -Width $Probe.Width -Height $Probe.Height
    $budget = $null
    if ($null -ne $scale) {
        $budget = Get-BudgetGiBPerHour -Width $Probe.Width -Height $Probe.Height -Efficient ([bool]$Probe.AlreadyEfficient)
    }
    $gibph = Get-GiBPerHour -Bytes $Probe.SizeBytes -Seconds $Probe.DurationSec
    $estimate = $null
    if ($null -ne $target) { $estimate = Get-EstimatedBytes -Probe $Probe -TargetKbps $target }

    $decision = 'lean'
    $reason = 'Under the budget for this picture size.'
    if ($Probe.IsDolbyVision) {
        $decision = 'dv'
        $reason = 'Dolby Vision is left alone.'
    }
    elseif ($Probe.DurationSec -le 0) {
        $decision = 'nodur'
        $reason = 'The duration could not be read.'
    }
    elseif ($Probe.Width -le 0 -or $Probe.Height -le 0) {
        $decision = 'nopicture'
        $reason = 'The picture size could not be read.'
    }
    elseif ($null -eq $gibph -or $null -eq $budget) {
        $decision = 'nodur'
        $reason = 'The size per hour could not be read.'
    }
    elseif ($gibph -lt $budget) {
        if (Test-ShrinkablePicture $Probe $target $estimate) {
            $decision = 'shrink'
            $reason = 'The file is under the budget line. The picture is still above the target rate, so a new file should be smaller.'
        }
        else {
            $decision = 'lean'
            $reason = 'Under the budget for this picture size.'
        }
    }
    else {
        $fileBps = ($Probe.SizeBytes * 8.0) / $Probe.DurationSec
        $targetBps = $target * 1000.0
        $videoKnown = ($Probe.VideoBitrate -gt 0 -and $fileBps -gt 0 -and $Probe.VideoBitrate -ge ($fileBps * 0.4))
        if ($videoKnown -and $Probe.VideoBitrate -le ($targetBps * 1.05)) {
            $decision = 'within'
            $reason = 'The picture is already within the target bits per second. Extra size is audio or other tracks, which stay as they are.'
        }
        else {
            $decision = 'bloated'
            $reason = 'Over the budget for this picture size.'
        }
    }

    return [pscustomobject]@{
        Decision      = $decision
        Reason        = $reason
        Scale         = $scale
        BudgetGiBph   = $budget
        TargetKbps    = $target
        GiBph         = $gibph
        EstimateBytes = $estimate
        EstimateRough = [bool]($null -ne $estimate -and $estimate -gt 0 -and $Probe.VideoBitrate -le 0)
    }
}

function Get-EncoderName {
    param($Probe)
    if ($Probe.Is10Bit -or $Probe.IsHdr10 -or $Probe.IsHdr10Plus -or $Probe.IsHlg) { return 'x265_10bit' }
    return 'x265'
}

function Get-HandBrakeArguments {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Temp,
        $Probe,
        [Parameter(Mandatory)][int]$VideoKbps,
        [Parameter(Mandatory)][string]$Encoder,
        [switch]$ReencodeAudio
    )
    $fallback = 'none'
    if ($ReencodeAudio) { $fallback = 'av_aac' }
    $arguments = @(
        '-i', $Source,
        '-o', $Temp,
        '--format', 'av_mkv',
        '--encoder', $Encoder,
        '--encoder-preset', 'medium',
        '--vb', "$VideoKbps",
        '--multi-pass',
        '--turbo',
        '--vfr',
        '--crop-mode', 'none',
        '--crop', '0:0:0:0',
        '--markers',
        '--all-audio',
        '--aencoder', 'copy',
        '--audio-copy-mask', $script:AudioCopyMask,
        '--audio-fallback', $fallback
    )
    $subCount = 0
    if ($Probe -and $null -ne $Probe.SubCount) { $subCount = [int]$Probe.SubCount }
    if ($subCount -gt 0) {
        $arguments += @(
            '--all-subtitles',
            '--subtitle-burned=none',
            '--subtitle-default=none',
            '--keep-subname'
        )
    }
    else {
        $arguments += @('--subtitle', 'none')
    }
    if ($Probe.IsHdr10Plus) {
        $arguments += @('--hdr-dynamic-metadata', 'hdr10plus')
    }
    if ($Probe.IsInterlaced) {
        $arguments += @('--comb-detect', 'default', '--decomb')
    }
    else {
        $arguments += @('--no-comb-detect', '--no-deinterlace', '--no-decomb', '--no-bwdif')
    }
    return $arguments
}

function Test-HarmlessDecodeNote([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $lines = @($Text -split '\s+\|\s+|\r?\n' | Where-Object { $_ -and $_.Trim() })
    if ($lines.Count -eq 0) { return $true }
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -notmatch '^(?:\[[^\]]+\]\s*)?Application provided invalid, non monotonically increasing dts to muxer in stream \d+:\s*(\d+)\s*>=\s*(\d+)\s*$') {
            return $false
        }
        if ($Matches[1] -ne $Matches[2]) { return $false }
    }
    return $true
}

function Get-Ac3FrameSize([byte[]]$Data, [int]$Offset) {
    if ($null -eq $Data -or $Offset -lt 0 -or ($Offset + 5) -gt $Data.Length) { return 0 }
    if ($Data[$Offset] -ne 0x0B -or $Data[$Offset + 1] -ne 0x77) { return 0 }
    $fscod = [int]($Data[$Offset + 4] -shr 6)
    $code = [int]($Data[$Offset + 4] -band 0x3F)
    if ($fscod -gt 2 -or $code -gt 37) { return 0 }
    $words = [int]$script:Ac3FrameWords[$code][$fscod]
    if ($words -le 0) { return 0 }
    return ($words * 2)
}

function Test-Ac3ShortTailBytes([byte[]]$Data) {
    if ($null -eq $Data -or $Data.Length -lt 16) { return $false }
    $start = -1
    $limit = $Data.Length - 5
    for ($i = 0; $i -lt $limit; $i++) {
        $size = Get-Ac3FrameSize $Data $i
        if ($size -lt 64) { continue }
        $next = $i + $size
        if ($next -ge $Data.Length) { continue }
        if ((Get-Ac3FrameSize $Data $next) -gt 0) {
            $start = $i
            break
        }
    }
    if ($start -lt 0) { return $false }
    $pos = $start
    $frames = 0
    while ($pos -lt $Data.Length) {
        $size = Get-Ac3FrameSize $Data $pos
        if ($size -lt 64) { return $false }
        if (($pos + $size) -gt $Data.Length) {
            return ($frames -ge 2)
        }
        if (($pos + $size) -eq $Data.Length) { return $false }
        $frames++
        $pos += $size
    }
    return $false
}

function Test-TrailingAc3Note([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $lines = @($Text -split '\s+\|\s+|\r?\n' | Where-Object { $_ -and $_.Trim() })
    if ($lines.Count -eq 0) { return $false }
    $incomplete = 0
    foreach ($line in $lines) {
        $body = $line.Trim()
        if ($body -match '^decode Last exit=(-?\d+)\s+(.*)$') {
            $exitCode = [int64]$Matches[1]
            if ($exitCode -eq 0) { return $false }
            $body = [string]$Matches[2]
        }
        $known = $false
        if ($body -match '^\[ac3 @ [0-9A-Fa-fx]+\] incomplete frame$') {
            $incomplete++
            $known = $true
        }
        elseif ($body -match '^\[aist#\d+:\d+/ac3 @ [^\]]+\] \[dec:ac3 @ [^\]]+\] corrupt decoded frame$') {
            $known = $true
        }
        elseif ($body -match '^\[aist#\d+:\d+/ac3 @ [^\]]+\] \[dec:ac3 @ [^\]]+\] Error processing packet in decoder: Invalid data found when processing input$') {
            $known = $true
        }
        elseif ($body -match '^\[aist#\d+:\d+/ac3 @ [^\]]+\] \[dec:ac3 @ [^\]]+\] Error submitting packet to decoder: Invalid data found when processing input$') {
            $known = $true
        }
        elseif ($body -match '^\[aist#\d+:\d+/ac3 @ [^\]]+\] \[dec:ac3 @ [^\]]+\] Task finished with error code: -1094995529 \(Invalid data found when processing input\)$') {
            $known = $true
        }
        elseif ($body -match '^\[aist#\d+:\d+/ac3 @ [^\]]+\] \[dec:ac3 @ [^\]]+\] Terminating thread with return code -1094995529 \(Invalid data found when processing input\)$') {
            $known = $true
        }
        if (-not $known) { return $false }
    }
    return ($incomplete -eq 1)
}

function Test-CopiedAc3([string[]]$SourceCodecs, [string[]]$OutputCodecs) {
    $source = @()
    $output = @()
    if ($null -ne $SourceCodecs) { $source = @($SourceCodecs) }
    if ($null -ne $OutputCodecs) { $output = @($OutputCodecs) }
    $found = $false
    for ($i = 0; $i -lt $source.Count; $i++) {
        $left = [string]$source[$i]
        if ($left.Trim().ToLowerInvariant() -ne 'ac3') { continue }
        $right = ''
        if ($i -lt $output.Count) { $right = [string]$output[$i] }
        if ($right.Trim().ToLowerInvariant() -ne 'ac3') { return $false }
        $found = $true
    }
    return $found
}

function Test-OneAc3ShortTail {
    param(
        [Parameter(Mandatory)][string]$Ffmpeg,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int]$AudioIndex
    )
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('vd-ac3-' + [guid]::NewGuid().ToString('n') + '.ac3')
    try {
        $run = Invoke-CapturedProcess -File $Ffmpeg -Arguments @(
            '-y', '-hide_banner', '-nostdin', '-v', 'error',
            '-sseof', '-3', '-i', $File,
            '-map', "0:a:$AudioIndex",
            '-c', 'copy', '-f', 'ac3', $temp
        )
        if ($run.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $temp)) { return $false }
        $bytes = [IO.File]::ReadAllBytes($temp)
        return (Test-Ac3ShortTailBytes $bytes)
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-SourceAc3ShortTail {
    param(
        [Parameter(Mandatory)][string]$Ffmpeg,
        [Parameter(Mandatory)][string]$File,
        [string[]]$Codecs
    )
    if ([string]::IsNullOrWhiteSpace($File) -or -not (Test-Path -LiteralPath $File)) { return $false }
    $names = @()
    if ($null -ne $Codecs) { $names = @($Codecs) }
    $indexes = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $names.Count; $i++) {
        if ([string]$names[$i] -and [string]$names[$i].Trim().ToLowerInvariant() -eq 'ac3') {
            $indexes.Add($i)
        }
    }
    if ($indexes.Count -eq 0) { return $false }
    foreach ($index in $indexes) {
        if (-not (Test-OneAc3ShortTail -Ffmpeg $Ffmpeg -File $File -AudioIndex $index)) { return $false }
    }
    return $true
}

function Test-DecodeWindow {
    param(
        [Parameter(Mandatory)][string]$Ffmpeg,
        [Parameter(Mandatory)][string]$File,
        [double]$DurationSec,
        [ValidateSet('First', 'Last')][string]$Window
    )
    $seconds = 15
    if ($DurationSec -gt 0 -and $DurationSec -lt $seconds) {
        $seconds = [math]::Max(1, [int][math]::Floor($DurationSec))
    }
    $ffArgs = @('-hide_banner', '-nostdin', '-v', 'error', '-xerror')
    if ($Window -eq 'Last' -and $DurationSec -gt $seconds) {
        $ffArgs += @('-sseof', ('-{0}' -f $seconds))
    }
    elseif ($Window -eq 'First') {
        $ffArgs += @('-ss', '0')
    }
    $ffArgs += @('-t', "$seconds", '-i', $File, '-f', 'null', '-')
    $run = Invoke-CapturedProcess -File $Ffmpeg -Arguments $ffArgs
    $err = (($run.StdOut + "`n" + $run.StdErr) -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s*$' }) -join ' | '
    if ($run.ExitCode -ne 0 -or -not (Test-HarmlessDecodeNote $err)) {
        return [pscustomobject]@{ Ok = $false; Detail = "decode $Window exit=$($run.ExitCode) $err" }
    }
    return [pscustomobject]@{ Ok = $true; Detail = '' }
}

function Test-CopyableAudioCodec([string]$Codec) {
    if ([string]::IsNullOrWhiteSpace($Codec)) { return $false }
    $name = $Codec.Trim().ToLowerInvariant()
    foreach ($allowed in ($script:AudioCopyMask -split ',')) {
        if ($name -eq $allowed.Trim().ToLowerInvariant()) { return $true }
    }
    return $false
}

function Test-AudioFallbackLog([string]$Log) {
    if ([string]::IsNullOrEmpty($Log)) { return $false }
    return [bool]($Log -match 'passthru not possible|Auto Passthru: no codecs allowed|using fallback encoder')
}

function Get-AudioFallbackReason {
    param(
        [string]$Log,
        [switch]$AllowReencode
    )
    if ($AllowReencode) { return '' }
    if (Test-AudioFallbackLog $Log) { return 'audio could not be copied' }
    return ''
}

function Get-AudioChangeReasons {
    param(
        [string[]]$SourceCodecs,
        [string[]]$OutputCodecs,
        [switch]$AllowReencode
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $source = @()
    $output = @()
    if ($null -ne $SourceCodecs) { $source = @($SourceCodecs) }
    if ($null -ne $OutputCodecs) { $output = @($OutputCodecs) }
    if ($source.Count -ne $output.Count) {
        $reasons.Add("audio tracks changed from $($source.Count) to $($output.Count)")
    }
    $slots = [math]::Max($source.Count, $output.Count)
    for ($i = 0; $i -lt $slots; $i++) {
        $left = if ($i -lt $source.Count) { [string]$source[$i] } else { 'missing' }
        $right = if ($i -lt $output.Count) { [string]$output[$i] } else { 'missing' }
        if ($left -eq $right) { continue }
        $reencoded = $AllowReencode -and -not (Test-CopyableAudioCodec $left) -and ($right.ToLowerInvariant() -eq 'aac')
        if ($reencoded) { continue }
        $reasons.Add("audio $i changed from $left to $right")
    }
    return @($reasons.ToArray())
}

function Test-SizeSkipReason([string]$Reason) {
    $parts = @(([string]$Reason) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $false }
    foreach ($part in $parts) {
        if ($part -ne 'the new file is not smaller' -and $part -ne 'the new file is not smaller per hour') {
            return $false
        }
    }
    return $true
}

function Get-LargerFileNote {
    param(
        [string]$Reason,
        [int64]$SourceBytes = 0,
        [int64]$NewBytes = 0,
        [int]$TargetKbps = 0,
        [string[]]$SourceCodecs,
        [string[]]$OutputCodecs
    )
    if ([string]$Reason -notmatch 'the new file is not smaller') { return '' }
    $source = @()
    $output = @()
    if ($null -ne $SourceCodecs) { $source = @($SourceCodecs) }
    if ($null -ne $OutputCodecs) { $output = @($OutputCodecs) }
    $reencoded = $false
    $copied = $true
    $slots = [math]::Min($source.Count, $output.Count)
    for ($i = 0; $i -lt $slots; $i++) {
        $left = [string]$source[$i]
        $right = [string]$output[$i]
        if ($left -eq $right) { continue }
        $copied = $false
        if ($right.ToLowerInvariant() -eq 'aac' -and -not (Test-CopyableAudioCodec $left)) { $reencoded = $true }
    }
    if ($output.Count -lt $source.Count) { $copied = $false }
    $sentences = New-Object System.Collections.Generic.List[string]
    $sentences.Add('The original was left in place.')
    $rate = 'the target rate'
    if ($TargetKbps -gt 0) { $rate = "$TargetKbps kbps" }
    if ($reencoded) {
        $sentences.Add("The picture was encoded at $rate. Audio that could not be copied was re-encoded to AAC, and the rest was copied.")
    }
    elseif ($copied) {
        $sentences.Add("The picture was encoded at $rate, and the audio was copied as it was.")
    }
    else {
        $sentences.Add("The picture was encoded at $rate.")
    }
    if ($SourceBytes -gt 0 -and $NewBytes -ge $SourceBytes) {
        $sentences.Add("Together that made $(Format-ByteSize $NewBytes), which is not smaller than the original $(Format-ByteSize $SourceBytes).")
    }
    elseif ($SourceBytes -gt 0 -and $NewBytes -gt 0) {
        $sentences.Add("The new file is $(Format-ByteSize $NewBytes) and the original is $(Format-ByteSize $SourceBytes). It is not smaller for the length of the video.")
    }
    else {
        $sentences.Add('Together that is not smaller than the original.')
    }
    $sentences.Add('That happens when the target rate plus the audio is more than this file already used.')
    return ($sentences -join ' ')
}

function Test-EncodedFile {
    param(
        [Parameter(Mandatory)][string]$Ffmpeg,
        [Parameter(Mandatory)][string]$Ffprobe,
        [Parameter(Mandatory)][string]$Temp,
        $SourceProbe,
        [string]$HandBrakeLog,
        [switch]$AllowAudioReencode
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Temp)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'The new file is missing.'; OutProbe = $null; NewGiBph = $null; OldGiBph = $null }
    }
    $tempItem = Get-Item -LiteralPath $Temp
    $floor = [int64]64KB
    if ($tempItem.Length -lt $floor) {
        $reasons.Add("new file is too small ($($tempItem.Length) bytes)")
    }
    $fallbackReason = Get-AudioFallbackReason -Log $HandBrakeLog -AllowReencode:$AllowAudioReencode
    if ($fallbackReason) { $reasons.Add($fallbackReason) }
    if ($HandBrakeLog -match 'Burned-in|Render/Burn-in') {
        $reasons.Add('a subtitle was burned into the picture')
    }

    $out = $null
    try {
        $out = Get-MediaProbe -Ffprobe $Ffprobe -File $Temp
    }
    catch {
        $reasons.Add("could not read the new file: $($_.Exception.Message)")
        return [pscustomobject]@{ Ok = $false; Reason = ($reasons -join '; '); OutProbe = $null; NewGiBph = $null; OldGiBph = $null }
    }

    if ([math]::Abs($out.DurationSec - $SourceProbe.DurationSec) -gt 2) {
        $reasons.Add("duration changed from $([math]::Round($SourceProbe.DurationSec, 1))s to $([math]::Round($out.DurationSec, 1))s")
    }
    if ($out.Width -ne $SourceProbe.Width -or $out.Height -ne $SourceProbe.Height) {
        $reasons.Add("picture size changed from $($SourceProbe.Width)x$($SourceProbe.Height) to $($out.Width)x$($out.Height)")
    }
    $first = Test-DecodeWindow -Ffmpeg $Ffmpeg -File $Temp -DurationSec $out.DurationSec -Window First
    if (-not $first.Ok) { $reasons.Add($first.Detail) }
    $last = Test-DecodeWindow -Ffmpeg $Ffmpeg -File $Temp -DurationSec $out.DurationSec -Window Last
    if (-not $last.Ok) {
        # A VirtualDub-style AVI can end in the middle of an AC3 frame.
        # Copying that track keeps the short tail. Accept one incomplete
        # frame at the end when every copied AC3 track already ended that way.
        $sourcePath = ''
        if ($SourceProbe -and $SourceProbe.Path) { $sourcePath = [string]$SourceProbe.Path }
        $trailing = (Test-TrailingAc3Note $last.Detail) -and (Test-CopiedAc3 @($SourceProbe.AudioCodecs) @($out.AudioCodecs)) -and (Test-SourceAc3ShortTail -Ffmpeg $Ffmpeg -File $sourcePath -Codecs @($SourceProbe.AudioCodecs))
        if (-not $trailing) { $reasons.Add($last.Detail) }
    }
    foreach ($audioReason in @(Get-AudioChangeReasons -SourceCodecs @($SourceProbe.AudioCodecs) -OutputCodecs @($out.AudioCodecs) -AllowReencode:$AllowAudioReencode)) {
        $reasons.Add($audioReason)
    }
    if ($out.SubCount -lt $SourceProbe.SubCount) {
        $reasons.Add("subtitles dropped from $($SourceProbe.SubCount) to $($out.SubCount)")
    }
    if ($tempItem.Length -ge $SourceProbe.SizeBytes) {
        $reasons.Add('the new file is not smaller')
    }
    $oldRate = Get-GiBPerHour -Bytes $SourceProbe.SizeBytes -Seconds $SourceProbe.DurationSec
    $newRate = Get-GiBPerHour -Bytes $tempItem.Length -Seconds $out.DurationSec
    if ($null -eq $newRate -or $null -eq $oldRate -or $newRate -ge $oldRate) {
        $reasons.Add('the new file is not smaller per hour')
    }

    $ok = ($reasons.Count -eq 0)
    return [pscustomobject]@{
        Ok       = $ok
        Reason   = $(if ($ok) { 'ok' } else { $reasons -join '; ' })
        OutProbe = $out
        NewGiBph = $newRate
        OldGiBph = $oldRate
        NewBytes = $tempItem.Length
    }
}

function Get-PlexIgnoreLines {
    return @('.vd-originals', '.vd-originals/*')
}

function Add-PlexIgnore {
    param([Parameter(Mandatory)][string]$Directory)
    $path = Join-Path $Directory '.plexignore'
    $lines = @(Get-PlexIgnoreLines)
    if (Test-Path -LiteralPath $path) {
        $existing = [IO.File]::ReadAllText($path)
        $missing = @($lines | Where-Object { $existing -notmatch ('(?m)^\s*' + [regex]::Escape($_) + '\s*$') })
        if ($missing.Count -eq 0) { return }
        $suffix = "`r`n" + ($missing -join "`r`n") + "`r`n"
        [IO.File]::AppendAllText($path, $suffix)
        return
    }
    [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"))
}

function Remove-PlexIgnore {
    param([Parameter(Mandatory)][string]$Directory)
    $hold = Join-Path $Directory '.vd-originals'
    if (Test-Path -LiteralPath $hold) { return }
    $path = Join-Path $Directory '.plexignore'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $owned = @(Get-PlexIgnoreLines)
    try {
        $lines = @([IO.File]::ReadAllLines($path))
        $kept = New-Object System.Collections.Generic.List[string]
        $removed = 0
        foreach ($line in $lines) {
            $drop = $false
            foreach ($name in $owned) {
                if ($line -match ('^\s*' + [regex]::Escape($name) + '\s*$')) { $drop = $true; break }
            }
            if ($drop) { $removed++; continue }
            [void]$kept.Add($line)
        }
        $meaningful = 0
        foreach ($line in $kept) {
            if ($line.Trim() -ne '') { $meaningful++ }
        }
        if ($meaningful -eq 0) {
            $length = [int64](Get-Item -LiteralPath $path -Force).Length
            Remove-Item -LiteralPath $path -Force
            if (-not (Test-Path -LiteralPath $path)) {
                try { [void](Remove-RecycledPlexIgnore -Path $path -Length $length) } catch { }
            }
            return
        }
        if ($removed -eq 0) { return }
        while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') {
            $kept.RemoveAt($kept.Count - 1)
        }
        [IO.File]::WriteAllText($path, (($kept.ToArray() -join "`r`n") + "`r`n"))
    }
    catch { }
}

# A shared drive can park a deleted file in a #recycle folder at the share
# root. The purge below removes one of those copies, and only when every
# gate passes: the path is \\server\share\#recycle\ plus the original path,
# the parent folder is named .vd-originals, the size matches the file just
# deleted, and the item is a normal file. Empty folders are removed on the
# way back up and the walk stops at #recycle. AllowLocal exists so the
# self-test can point at a temp folder. Production plans keep it false,
# which refuses a drive-letter share root.
$script:RecycleFolderName = '#recycle'
$script:RecycleResults = New-Object System.Collections.ArrayList

# The window stores the checkbox in RecyclePurgeEnabled. An unset value means
# the engine is running its own self-test, where the purge stays available.
function Test-RecyclePurgeEnabled {
    if ($null -eq $script:RecyclePurgeEnabled) { return $true }
    return [bool]$script:RecyclePurgeEnabled
}

function New-RecycleResult {
    param(
        [string]$Status,
        [string]$Path,
        [string]$RecycleFile,
        [string]$Message,
        [string]$Name
    )
    return [pscustomobject]@{
        Status      = $Status
        Path        = $Path
        RecycleFile = $RecycleFile
        Message     = $Message
        Name        = $Name
        Reported    = $false
        Shown       = $false
    }
}

function Add-RecycleResult($Result) {
    if (-not $script:RecycleResults) {
        $script:RecycleResults = New-Object System.Collections.ArrayList
    }
    [void]$script:RecycleResults.Add($Result)
    return $Result
}

function Clear-RecycleResults {
    if ($script:RecycleResults) { $script:RecycleResults.Clear() }
    $script:RecycleLogOnce = @{}
}

function Get-PlainPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $raw = $Path.Trim().Replace('/', '\')
    if ($raw.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        return '\\' + $raw.Substring(8)
    }
    if ($raw.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        return $raw.Substring(4)
    }
    return $raw
}

function Test-PlainSegments([string]$Path) {
    foreach ($part in @($Path.Split('\'))) {
        if ($part -eq '.' -or $part -eq '..') { return $false }
    }
    return $true
}

function ConvertTo-NormalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return [IO.Path]::GetFullPath($Path) } catch { return '' }
}

function Get-MappedUncRoot {
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        $DriveMap
    )
    $letter = $DriveLetter.Substring(0, 1).ToUpperInvariant()
    if ($null -ne $DriveMap) {
        if ($DriveMap.Contains($letter)) {
            $mapped = [string]$DriveMap[$letter]
            if ([string]::IsNullOrWhiteSpace($mapped)) { return $null }
            return $mapped.TrimEnd('\')
        }
        return $null
    }
    try {
        $info = New-Object System.IO.DriveInfo ($letter + ':')
        if ($info.DriveType -ne [IO.DriveType]::Network) { return $null }
    }
    catch { return $null }
    $root = ''
    try {
        $drive = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction Stop
        $root = [string]$drive.DisplayRoot
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($root)) {
        try {
            $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $letter + ":'") -ErrorAction Stop
            $root = [string]$disk.ProviderName
        }
        catch { }
    }
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    if (-not $root.StartsWith('\\')) { return $null }
    return $root.TrimEnd('\')
}

function Split-UncLocation([string]$Unc) {
    if ([string]::IsNullOrWhiteSpace($Unc)) { return $null }
    $body = $Unc.TrimEnd('\')
    if ($body -notmatch '^\\\\([^\\]+)\\([^\\]+)\\(.+)$') { return $null }
    $server = $Matches[1]
    $share = $Matches[2]
    if ($server -eq '.' -or $server -eq '..' -or $share -eq '.' -or $share -eq '..') { return $null }
    $relativeParts = @($Matches[3].Split('\') | Where-Object { $_ -ne '' })
    if ($relativeParts.Count -lt 1) { return $null }
    foreach ($part in $relativeParts) {
        if ($part -eq '.' -or $part -eq '..') { return $null }
        if ($part.IndexOfAny([char[]]@('/', ':', '*', '?', '"', '<', '>', '|')) -ge 0) { return $null }
    }
    $relative = $relativeParts -join '\'
    $shareRoot = '\\' + $server + '\' + $share
    return [pscustomobject]@{
        UncFile   = ($shareRoot + '\' + $relative)
        ShareRoot = $shareRoot
        Relative  = $relative
        Parts     = $relativeParts
    }
}

function Get-ShareLocation {
    param([string]$Path, $DriveMap)
    $plain = Get-PlainPath $Path
    if (-not $plain) { return $null }
    if (-not (Test-PlainSegments $plain)) { return $null }
    if ($plain -match '^[A-Za-z]:\\') {
        $root = Get-MappedUncRoot -DriveLetter $plain.Substring(0, 1) -DriveMap $DriveMap
        if (-not $root) { return $null }
        if (-not (Test-PlainSegments $root)) { return $null }
        $rest = $plain.Substring(2).TrimStart('\')
        $plain = $root.TrimEnd('\') + '\' + $rest
        if (-not (Test-PlainSegments $plain)) { return $null }
    }
    elseif (-not $plain.StartsWith('\\')) {
        return $null
    }
    $loc = Split-UncLocation $plain
    if (-not $loc) { return $null }
    if ($null -ne $DriveMap) { return $loc }
    $normal = ConvertTo-NormalPath $loc.UncFile
    if (-not $normal) { return $loc }
    $again = Split-UncLocation $normal
    if (-not $again) { return $null }
    if (-not [string]::Equals($again.ShareRoot, $loc.ShareRoot, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $again
}

function Test-RecycleSegment([string]$Part) {
    if ($Part.Equals('#recycle', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Part.Equals('@Recycle', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Get-RecyclePlan {
    param([string]$Path, $DriveMap)
    $loc = Get-ShareLocation -Path $Path -DriveMap $DriveMap
    if (-not $loc) { return $null }
    $parts = @($loc.Parts)
    if ($parts.Count -lt 2) { return $null }
    $leaf = [string]$parts[$parts.Count - 1]
    $parent = [string]$parts[$parts.Count - 2]
    if (-not $parent.Equals('.vd-originals', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if ($leaf.Equals('.vd-originals', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    foreach ($part in $parts) {
        if (Test-RecycleSegment $part) { return $null }
    }
    $recycleRoot = $loc.ShareRoot + '\' + $script:RecycleFolderName
    return [pscustomobject]@{
        SourcePath  = $Path
        ShareRoot   = $loc.ShareRoot
        Relative    = $loc.Relative
        RecycleRoot = $recycleRoot
        RecycleFile = ($recycleRoot + '\' + $loc.Relative)
        Name        = $leaf
        AllowLocal  = $false
        DriveMap    = $DriveMap
    }
}

function Get-RecycleDirectoryPlan {
    param([string]$Directory, $DriveMap)
    $loc = Get-ShareLocation -Path $Directory -DriveMap $DriveMap
    if (-not $loc) { return $null }
    $parts = @($loc.Parts)
    if ($parts.Count -lt 1) { return $null }
    $leaf = [string]$parts[$parts.Count - 1]
    if (-not $leaf.Equals('.vd-originals', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    foreach ($part in $parts) {
        if (Test-RecycleSegment $part) { return $null }
    }
    $recycleRoot = $loc.ShareRoot + '\' + $script:RecycleFolderName
    return [pscustomobject]@{
        SourcePath  = $Directory
        ShareRoot   = $loc.ShareRoot
        Relative    = $loc.Relative
        RecycleRoot = $recycleRoot
        RecycleFile = ($recycleRoot + '\' + $loc.Relative)
        Name        = $leaf
        AllowLocal  = $false
        DriveMap    = $DriveMap
    }
}

function Test-SamePath([string]$Left, [string]$Right) {
    $a = ConvertTo-NormalPath $Left
    $b = ConvertTo-NormalPath $Right
    if (-not $a -or -not $b) { return $false }
    return [string]::Equals($a.TrimEnd('\'), $b.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathUnderRoot([string]$Path, [string]$Root) {
    $pathFull = (ConvertTo-NormalPath $Path)
    $rootFull = (ConvertTo-NormalPath $Root)
    if (-not $pathFull -or -not $rootFull) { return $false }
    $pathFull = $pathFull.TrimEnd('\')
    $rootFull = $rootFull.TrimEnd('\')
    if ([string]::Equals($pathFull, $rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-PathBelowRoot([string]$Path, [string]$Root) {
    $pathFull = ConvertTo-NormalPath $Path
    $rootFull = ConvertTo-NormalPath $Root
    if (-not $pathFull -or -not $rootFull) { return $null }
    $pathFull = $pathFull.TrimEnd('\')
    $rootFull = $rootFull.TrimEnd('\')
    if ([string]::Equals($pathFull, $rootFull, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    $prefix = $rootFull + '\'
    if (-not $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $pathFull.Substring($prefix.Length)
}

function Test-RecycleNotFound($ErrorRecord) {
    $ex = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    elseif ($ErrorRecord -is [Exception]) { $ex = $ErrorRecord }
    while ($ex) {
        if ($ex -is [System.Management.Automation.ItemNotFoundException]) { return $true }
        if ($ex -is [System.IO.DirectoryNotFoundException]) { return $true }
        if ($ex -is [System.IO.FileNotFoundException]) { return $true }
        $io = $ex -as [System.IO.IOException]
        if ($io) {
            $code = $io.HResult -band 0xFFFF
            if ($code -eq 2 -or $code -eq 3) { return $true }
        }
        $ex = $ex.InnerException
    }
    return $false
}

function Test-RecycleAccessDenied($ErrorRecord) {
    $ex = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    elseif ($ErrorRecord -is [Exception]) { $ex = $ErrorRecord }
    while ($ex) {
        if ($ex -is [UnauthorizedAccessException]) { return $true }
        if ($ex -is [System.Security.SecurityException]) { return $true }
        $io = $ex -as [System.IO.IOException]
        if ($io) {
            $code = $io.HResult -band 0xFFFF
            if ($code -eq 5 -or $code -eq 32 -or $code -eq 33) { return $true }
        }
        $ex = $ex.InnerException
    }
    return $false
}

function Test-ReparsePoint($Item) {
    if (-not $Item) { return $false }
    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function New-RecycleRefusal {
    param($Plan, [string]$Message)
    $name = ''
    $source = ''
    $recycleFile = ''
    if ($Plan) {
        $name = [string]$Plan.Name
        $source = [string]$Plan.SourcePath
        $recycleFile = [string]$Plan.RecycleFile
    }
    if (-not $Message) { $Message = 'The recycle path did not pass the safety check. Nothing was deleted.' }
    return (New-RecycleResult 'skipped' $source $recycleFile $Message $name)
}

function Test-RecycleFilePlan($Plan) {
    if (-not $Plan) { return (New-RecycleRefusal $null '') }
    $relative = [string]$Plan.Relative
    $parts = @($relative.Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2) { return (New-RecycleRefusal $Plan '') }
    $leaf = [string]$parts[$parts.Count - 1]
    $parent = [string]$parts[$parts.Count - 2]
    if (-not $parent.Equals('.vd-originals', [StringComparison]::OrdinalIgnoreCase)) { return (New-RecycleRefusal $Plan '') }
    if (-not $leaf.Equals([string]$Plan.Name, [StringComparison]::OrdinalIgnoreCase)) { return (New-RecycleRefusal $Plan '') }
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..') { return (New-RecycleRefusal $Plan '') }
        if (Test-RecycleSegment $part) { return (New-RecycleRefusal $Plan '') }
        if ($part.IndexOfAny([char[]]@('/', ':', '*', '?', '"', '<', '>', '|')) -ge 0) { return (New-RecycleRefusal $Plan '') }
    }
    $share = ConvertTo-NormalPath ([string]$Plan.ShareRoot)
    if (-not $share) { return (New-RecycleRefusal $Plan '') }
    $share = $share.TrimEnd('\')
    $isUnc = $share.StartsWith('\\')
    if (-not $isUnc -and -not [bool]$Plan.AllowLocal) { return (New-RecycleRefusal $Plan '') }
    if ($isUnc -and $share -notmatch '^\\\\[^\\]+\\[^\\]+$') { return (New-RecycleRefusal $Plan '') }
    $rootExpected = $share + '\' + $script:RecycleFolderName
    $fileExpected = $rootExpected + '\' + ($parts -join '\')
    if (-not (Test-SamePath ([string]$Plan.RecycleRoot) $rootExpected)) { return (New-RecycleRefusal $Plan '') }
    if (-not (Test-SamePath ([string]$Plan.RecycleFile) $fileExpected)) { return (New-RecycleRefusal $Plan '') }
    if (-not (Test-PathUnderRoot $fileExpected $rootExpected)) { return (New-RecycleRefusal $Plan '') }
    return $null
}

function Get-UnderRecycleRelative($Plan, [string]$Path) {
    if ([bool]$Plan.AllowLocal) { return (Get-PathBelowRoot $Path ([string]$Plan.RecycleRoot)) }
    $loc = Get-ShareLocation -Path $Path -DriveMap $Plan.DriveMap
    if (-not $loc) { return $null }
    if (-not [string]::Equals($loc.ShareRoot, [string]$Plan.ShareRoot, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if ($loc.Relative.Equals($script:RecycleFolderName, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    $prefix = $script:RecycleFolderName + '\'
    if (-not $loc.Relative.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $loc.Relative.Substring($prefix.Length)
}

function Test-RecycleFileItem($Item, $Plan, [int64]$Length) {
    $source = [string]$Plan.SourcePath
    $recycleFile = [string]$Plan.RecycleFile
    $name = [string]$Plan.Name
    if (Test-ReparsePoint $Item) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("A link is at $recycleFile. It was left in place.") $name)
    }
    if ($Item.PSIsContainer) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("A folder is at $recycleFile. It was left in place.") $name)
    }
    $itemName = [string]$Item.Name
    if (-not $itemName.Equals($name, [StringComparison]::OrdinalIgnoreCase)) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("The file at $recycleFile is named $itemName. It was left in place.") $name)
    }
    $parentName = [IO.Path]::GetFileName($Item.DirectoryName)
    if (-not $parentName.Equals('.vd-originals', [StringComparison]::OrdinalIgnoreCase)) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("The file at $recycleFile is outside .vd-originals. It was left in place.") $name)
    }
    $relative = Get-UnderRecycleRelative $Plan ([string]$Item.FullName)
    if (-not $relative -or -not $relative.Equals([string]$Plan.Relative, [StringComparison]::OrdinalIgnoreCase)) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("The file at $recycleFile resolved to a different path. It was left in place.") $name)
    }
    $size = [int64]$Item.Length
    if ($size -ne $Length) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("A file at $recycleFile does not match the size of $name. It was left in place.") $name)
    }
    return $null
}

function Test-StaleRecycleChild($Children, [string]$RemovedName) {
    if ([string]::IsNullOrWhiteSpace($RemovedName)) { return $false }
    $list = @($Children)
    if ($list.Count -ne 1) { return $false }
    $only = ''
    try { $only = [string]$list[0].Name } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($only)) { return $false }
    return $only.Equals($RemovedName, [StringComparison]::OrdinalIgnoreCase)
}

function Test-RecycleDirectoryEmpty {
    param(
        [string]$Directory,
        [string]$RemovedChild
    )
    try { $children = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop) } catch { return $null }
    if ($children.Count -eq 0) { return $true }
    if (-not (Test-StaleRecycleChild $children $RemovedChild)) { return $false }
    $stale = Join-Path $Directory $RemovedChild
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        Start-Sleep -Milliseconds 150
        try { $children = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop) } catch { return $null }
        if ($children.Count -eq 0) { return $true }
        if (-not (Test-StaleRecycleChild $children $RemovedChild)) { return $false }
    }
    if (Test-Path -LiteralPath $stale) { return $false }
    return $true
}

function Remove-VerifiedEmptyRecycleDirectory {
    param(
        [string]$Path,
        [string]$RemovedChild
    )
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $empty = Test-RecycleDirectoryEmpty -Directory $Path -RemovedChild $RemovedChild
        if ($null -eq $empty -or -not $empty) { return $false }
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { }
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        if ($attempt -ge 3) { return $false }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Remove-EmptyRecycleDirectories {
    param(
        $Plan,
        [string]$StartDirectory,
        [string]$ExpectedRelative
    )
    if (-not $Plan -or -not $StartDirectory -or -not $ExpectedRelative) { return }
    $expected = $ExpectedRelative.Trim('\')
    $holding = $expected.Equals('.vd-originals', [StringComparison]::OrdinalIgnoreCase) -or $expected.EndsWith('\.vd-originals', [StringComparison]::OrdinalIgnoreCase)
    if (-not $holding) { return }
    $actual = Get-UnderRecycleRelative $Plan $StartDirectory
    if (-not $actual -or -not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { return }
    $dir = $StartDirectory
    $requireHolding = $true
    $removedChild = ''
    while ($dir) {
        $relative = Get-UnderRecycleRelative $Plan $dir
        if (-not $relative) { return }
        $leaf = [IO.Path]::GetFileName($relative.TrimEnd('\'))
        if ($requireHolding -and -not $leaf.Equals('.vd-originals', [StringComparison]::OrdinalIgnoreCase)) { return }
        $requireHolding = $false
        if ($relative.Split('\') | Where-Object { Test-RecycleSegment $_ }) { return }
        try { $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop } catch { return }
        if (Test-ReparsePoint $item) { return }
        if (-not $item.PSIsContainer) { return }
        $itemRelative = Get-UnderRecycleRelative $Plan ([string]$item.FullName)
        if (-not $itemRelative -or -not $itemRelative.Equals($relative, [StringComparison]::OrdinalIgnoreCase)) { return }
        $leafName = [IO.Path]::GetFileName(([string]$item.FullName).TrimEnd('\'))
        if (-not (Remove-VerifiedEmptyRecycleDirectory -Path ([string]$item.FullName) -RemovedChild $removedChild)) { return }
        $removedChild = $leafName
        $dir = Split-Path -Parent $item.FullName
    }
}

function Invoke-RecyclePurge {
    param($Plan, [int64]$Length)
    $refusal = Test-RecycleFilePlan $Plan
    if ($refusal) { return $refusal }
    $source = [string]$Plan.SourcePath
    $name = [string]$Plan.Name
    $recycleFile = [string]$Plan.RecycleFile
    if ($Length -le 0) {
        return (New-RecycleResult 'skipped' $source $recycleFile 'The file length was not known.' $name)
    }
    try {
        $rootItem = Get-Item -LiteralPath ([string]$Plan.RecycleRoot) -Force -ErrorAction Stop
    }
    catch {
        if (Test-RecycleNotFound $_) {
            return (New-RecycleResult 'absent' $source $recycleFile ("No #recycle folder on " + $Plan.ShareRoot + ". Deleted files were not left in a drive recycle bin.") $name)
        }
        if (Test-RecycleAccessDenied $_) {
            return (New-RecycleResult 'denied' $source $recycleFile ("The drive recycle bin on " + $Plan.ShareRoot + " could not be opened. A copy of $name may still be there.") $name)
        }
        return (New-RecycleResult 'failed' $source $recycleFile ("Could not open the drive recycle bin. " + $_.Exception.Message) $name)
    }
    if (Test-ReparsePoint $rootItem) {
        return (New-RecycleResult 'failed' $source $recycleFile 'The #recycle path is a link. Nothing was deleted.' $name)
    }
    if (-not $rootItem.PSIsContainer) {
        return (New-RecycleResult 'failed' $source $recycleFile 'The #recycle path is not a folder. Nothing was deleted.' $name)
    }
    $rootRelative = Get-UnderRecycleRelative $Plan ([string]$rootItem.FullName)
    if ($null -eq $rootRelative -or $rootRelative -ne '') {
        return (New-RecycleResult 'failed' $source $recycleFile 'The #recycle folder resolved to a different path. Nothing was deleted.' $name)
    }
    try {
        $fileItem = Get-Item -LiteralPath $recycleFile -Force -ErrorAction Stop
    }
    catch {
        if (Test-RecycleNotFound $_) {
            return (New-RecycleResult 'missing' $source $recycleFile ("The drive recycle bin has no copy of $name at $recycleFile.") $name)
        }
        if (Test-RecycleAccessDenied $_) {
            return (New-RecycleResult 'denied' $source $recycleFile ("The drive recycle bin could not be changed for $name. $recycleFile may still hold a copy.") $name)
        }
        return (New-RecycleResult 'failed' $source $recycleFile ("Could not read the recycle copy of $name. " + $_.Exception.Message) $name)
    }
    $mismatch = Test-RecycleFileItem $fileItem $Plan $Length
    if ($mismatch) { return $mismatch }
    try {
        Remove-Item -LiteralPath $fileItem.FullName -Force -ErrorAction Stop
    }
    catch {
        if (Test-RecycleAccessDenied $_) {
            return (New-RecycleResult 'denied' $source $recycleFile ("The drive recycle bin could not be changed for $name. $recycleFile may still hold a copy.") $name)
        }
        return (New-RecycleResult 'failed' $source $recycleFile ("Could not remove the recycle copy of $name. " + $_.Exception.Message) $name)
    }
    if (Test-Path -LiteralPath $fileItem.FullName) {
        return (New-RecycleResult 'remained' $source $recycleFile ("The recycle copy of $name is still at $recycleFile.") $name)
    }
    $nested = ([string]$Plan.RecycleRoot).TrimEnd('\') + '\' + $script:RecycleFolderName + '\' + [string]$Plan.Relative
    if (Test-Path -LiteralPath $nested) {
        return (New-RecycleResult 'remained' $source $nested ("The drive put another copy of $name inside the recycle bin at $nested. It was left in place.") $name)
    }
    $parentRelative = ''
    $slash = $Plan.Relative.LastIndexOf('\')
    if ($slash -gt 0) { $parentRelative = $Plan.Relative.Substring(0, $slash) }
    Remove-EmptyRecycleDirectories -Plan $Plan -StartDirectory (Split-Path -Parent $fileItem.FullName) -ExpectedRelative $parentRelative
    return (New-RecycleResult 'purged' $source $recycleFile ("Removed the drive recycle copy of $name.") $name)
}

function Test-OwnedPlexIgnoreText([string]$Text) {
    if ($null -eq $Text) { return $false }
    $clean = $Text.TrimStart([char]0xFEFF)
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($clean -split '\r\n|\n|\r')) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }
        [void]$kept.Add($trimmed)
    }
    $owned = @(Get-PlexIgnoreLines)
    if ($kept.Count -ne $owned.Count) { return $false }
    for ($i = 0; $i -lt $owned.Count; $i++) {
        if (-not $kept[$i].Equals([string]$owned[$i], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Get-RecycleNamedPlan {
    param(
        [string]$Path,
        [string]$LeafName,
        $DriveMap
    )
    if ($LeafName -ne '.plexignore') { return $null }
    $loc = Get-ShareLocation -Path $Path -DriveMap $DriveMap
    if (-not $loc) { return $null }
    $parts = @($loc.Parts)
    if ($parts.Count -lt 1) { return $null }
    $leaf = [string]$parts[$parts.Count - 1]
    if (-not $leaf.Equals($LeafName, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    foreach ($part in $parts) {
        if (Test-RecycleSegment $part) { return $null }
    }
    $recycleRoot = $loc.ShareRoot + '\' + $script:RecycleFolderName
    return [pscustomobject]@{
        SourcePath  = $Path
        ShareRoot   = $loc.ShareRoot
        Relative    = $loc.Relative
        RecycleRoot = $recycleRoot
        RecycleFile = ($recycleRoot + '\' + $loc.Relative)
        Name        = $leaf
        AllowLocal  = $false
        DriveMap    = $DriveMap
    }
}

function Remove-EmptyRecycleAncestors {
    param(
        $Plan,
        [string]$StartDirectory,
        [string]$ExpectedRelative
    )
    if (-not $Plan -or -not $StartDirectory -or -not $ExpectedRelative) { return }
    $expected = $ExpectedRelative.Trim('\')
    if (-not $expected) { return }
    foreach ($part in @($expected.Split('\'))) {
        if ($part -eq '.' -or $part -eq '..' -or (Test-RecycleSegment $part)) { return }
    }
    $actual = Get-UnderRecycleRelative $Plan $StartDirectory
    if (-not $actual -or -not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { return }
    $dir = $StartDirectory
    $removedChild = ''
    while ($dir) {
        $relative = Get-UnderRecycleRelative $Plan $dir
        if (-not $relative) { return }
        if ($relative.Split('\') | Where-Object { Test-RecycleSegment $_ }) { return }
        try { $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop } catch { return }
        if (Test-ReparsePoint $item) { return }
        if (-not $item.PSIsContainer) { return }
        $itemRelative = Get-UnderRecycleRelative $Plan ([string]$item.FullName)
        if (-not $itemRelative -or -not $itemRelative.Equals($relative, [StringComparison]::OrdinalIgnoreCase)) { return }
        $leafName = [IO.Path]::GetFileName(([string]$item.FullName).TrimEnd('\'))
        if (-not (Remove-VerifiedEmptyRecycleDirectory -Path ([string]$item.FullName) -RemovedChild $removedChild)) { return }
        $removedChild = $leafName
        $dir = Split-Path -Parent $item.FullName
    }
}

function Invoke-RecyclePlexIgnorePurge {
    param($Plan, [int64]$Length)
    if (-not $Plan) { return (New-RecycleRefusal $null '') }
    $source = [string]$Plan.SourcePath
    $name = '.plexignore'
    $recycleFile = [string]$Plan.RecycleFile
    $relative = [string]$Plan.Relative
    $parts = @($relative.Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 1) { return (New-RecycleRefusal $Plan '') }
    $leaf = [string]$parts[$parts.Count - 1]
    if (-not $leaf.Equals('.plexignore', [StringComparison]::OrdinalIgnoreCase)) { return (New-RecycleRefusal $Plan '') }
    if (-not ([string]$Plan.Name).Equals('.plexignore', [StringComparison]::OrdinalIgnoreCase)) { return (New-RecycleRefusal $Plan '') }
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..' -or (Test-RecycleSegment $part)) { return (New-RecycleRefusal $Plan '') }
    }
    $share = ConvertTo-NormalPath ([string]$Plan.ShareRoot)
    if (-not $share) { return (New-RecycleRefusal $Plan '') }
    $share = $share.TrimEnd('\')
    if (-not $share.StartsWith('\\') -and -not [bool]$Plan.AllowLocal) { return (New-RecycleRefusal $Plan '') }
    $rootExpected = $share + '\' + $script:RecycleFolderName
    $fileExpected = $rootExpected + '\' + ($parts -join '\')
    if (-not (Test-SamePath ([string]$Plan.RecycleRoot) $rootExpected)) { return (New-RecycleRefusal $Plan '') }
    if (-not (Test-SamePath $recycleFile $fileExpected)) { return (New-RecycleRefusal $Plan '') }
    if ($Length -le 0 -or $Length -gt 4096) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("A .plexignore at $recycleFile is not the holding-folder file. It was left in place.") $name)
    }
    try {
        $rootItem = Get-Item -LiteralPath ([string]$Plan.RecycleRoot) -Force -ErrorAction Stop
    }
    catch {
        if (Test-RecycleNotFound $_) { return (New-RecycleResult 'absent' $source $recycleFile 'No #recycle folder was found.' $name) }
        if (Test-RecycleAccessDenied $_) {
            return (New-RecycleResult 'denied' $source $recycleFile ("The drive recycle bin on " + $Plan.ShareRoot + " could not be opened. A .plexignore copy may still be there.") $name)
        }
        return (New-RecycleResult 'failed' $source $recycleFile ("Could not open the drive recycle bin. " + $_.Exception.Message) $name)
    }
    if ((Test-ReparsePoint $rootItem) -or -not $rootItem.PSIsContainer) {
        return (New-RecycleResult 'failed' $source $recycleFile 'The #recycle path is not the recycle folder. Nothing was deleted.' $name)
    }
    try {
        $fileItem = Get-Item -LiteralPath $recycleFile -Force -ErrorAction Stop
    }
    catch {
        if (Test-RecycleNotFound $_) { return (New-RecycleResult 'missing' $source $recycleFile 'The recycled .plexignore was not found.' $name) }
        if (Test-RecycleAccessDenied $_) {
            return (New-RecycleResult 'denied' $source $recycleFile ("The drive recycle bin could not be changed for .plexignore. $recycleFile may still hold a copy.") $name)
        }
        return (New-RecycleResult 'failed' $source $recycleFile ("Could not read the recycled .plexignore. " + $_.Exception.Message) $name)
    }
    if ((Test-ReparsePoint $fileItem) -or $fileItem.PSIsContainer -or -not $fileItem.Name.Equals('.plexignore', [StringComparison]::OrdinalIgnoreCase)) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("The item at $recycleFile is not the holding-folder .plexignore. It was left in place.") $name)
    }
    $seen = Get-UnderRecycleRelative $Plan ([string]$fileItem.FullName)
    if (-not $seen -or -not $seen.Equals($relative, [StringComparison]::OrdinalIgnoreCase)) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("The .plexignore at $recycleFile resolved to a different path. It was left in place.") $name)
    }
    if ([int64]$fileItem.Length -ne $Length) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("A .plexignore at $recycleFile does not match the size of the file that was deleted. It was left in place.") $name)
    }
    $text = ''
    try { $text = [IO.File]::ReadAllText($fileItem.FullName) } catch {
        return (New-RecycleResult 'failed' $source $recycleFile ("Could not read the recycled .plexignore. " + $_.Exception.Message) $name)
    }
    if (-not (Test-OwnedPlexIgnoreText $text)) {
        return (New-RecycleResult 'mismatch' $source $recycleFile ("A .plexignore at $recycleFile lists more than the holding folder. It was left in place.") $name)
    }
    try { Remove-Item -LiteralPath $fileItem.FullName -Force -ErrorAction Stop }
    catch {
        if (Test-RecycleAccessDenied $_) {
            return (New-RecycleResult 'denied' $source $recycleFile ("The drive recycle bin could not be changed for .plexignore. $recycleFile may still hold a copy.") $name)
        }
        return (New-RecycleResult 'failed' $source $recycleFile ("Could not remove the recycled .plexignore. " + $_.Exception.Message) $name)
    }
    if (Test-Path -LiteralPath $fileItem.FullName) {
        return (New-RecycleResult 'remained' $source $recycleFile ("The recycled .plexignore is still at $recycleFile.") $name)
    }
    $parentRelative = ''
    $slash = $relative.LastIndexOf('\')
    if ($slash -gt 0) { $parentRelative = $relative.Substring(0, $slash) }
    if ($parentRelative) {
        Remove-EmptyRecycleAncestors -Plan $Plan -StartDirectory (Split-Path -Parent $fileItem.FullName) -ExpectedRelative $parentRelative
    }
    return (New-RecycleResult 'purged' $source $recycleFile 'Removed the drive recycle copy of .plexignore.' $name)
}

function Remove-RecycledPlexIgnore {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$Length,
        $DriveMap
    )
    if (-not (Test-RecyclePurgeEnabled)) { return }
    if ($Length -le 0 -or $Length -gt 4096) { return }
    $plan = Get-RecycleNamedPlan -Path $Path -LeafName '.plexignore' -DriveMap $DriveMap
    if (-not $plan) { return }
    try { $result = Invoke-RecyclePlexIgnorePurge -Plan $plan -Length $Length }
    catch {
        $result = New-RecycleResult 'failed' $Path ([string]$plan.RecycleFile) ("Could not remove the recycled .plexignore. " + $_.Exception.Message) '.plexignore'
    }
    if (-not $result) { return }
    if ($result.Status -eq 'missing' -or $result.Status -eq 'absent' -or $result.Status -eq 'skipped') { return }
    return (Add-RecycleResult $result)
}

function Remove-RecycleCopy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$Length,
        $DriveMap
    )
    if (-not (Test-RecyclePurgeEnabled)) { return }
    $name = ''
    try { $name = [IO.Path]::GetFileName($Path) } catch { $name = '' }
    if ($Length -le 0) {
        return (Add-RecycleResult (New-RecycleResult 'skipped' $Path '' 'The file length was not known.' $name))
    }
    $plan = Get-RecyclePlan -Path $Path -DriveMap $DriveMap
    if (-not $plan) {
        return (Add-RecycleResult (New-RecycleResult 'skipped' $Path '' 'This path is not a held original on a shared drive.' $name))
    }
    try { $result = Invoke-RecyclePurge -Plan $plan -Length $Length }
    catch {
        $result = New-RecycleResult 'failed' $Path ([string]$plan.RecycleFile) ("Could not remove the recycle copy of $name. " + $_.Exception.Message) $name
    }
    return (Add-RecycleResult $result)
}

function Invoke-RecycleDirectoryCleanup {
    param($Plan)
    if (-not $Plan) { return }
    $relative = [string]$Plan.Relative
    $parts = @($relative.Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 1) { return }
    $leaf = [string]$parts[$parts.Count - 1]
    if (-not $leaf.Equals('.vd-originals', [StringComparison]::OrdinalIgnoreCase)) { return }
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..' -or (Test-RecycleSegment $part)) { return }
    }
    $share = ConvertTo-NormalPath ([string]$Plan.ShareRoot)
    if (-not $share) { return }
    $share = $share.TrimEnd('\')
    if (-not $share.StartsWith('\\') -and -not [bool]$Plan.AllowLocal) { return }
    $rootExpected = $share + '\' + $script:RecycleFolderName
    $dirExpected = $rootExpected + '\' + ($parts -join '\')
    if (-not (Test-SamePath ([string]$Plan.RecycleRoot) $rootExpected)) { return }
    if (-not (Test-SamePath ([string]$Plan.RecycleFile) $dirExpected)) { return }
    Remove-EmptyRecycleDirectories -Plan $Plan -StartDirectory $dirExpected -ExpectedRelative ($parts -join '\')
}

function Remove-RecycledHoldingFolder {
    param([string]$Directory, $DriveMap)
    if (-not (Test-RecyclePurgeEnabled)) { return }
    if (-not $Directory) { return }
    $plan = Get-RecycleDirectoryPlan -Directory $Directory -DriveMap $DriveMap
    if (-not $plan) { return }
    try { Invoke-RecycleDirectoryCleanup -Plan $plan } catch { }
}

function Remove-EmptyDirectory {
    param([string]$Directory)
    if (-not $Directory) { return }
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    $left = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) {
        Remove-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $Directory) { return }
    $leaf = [IO.Path]::GetFileName($Directory.TrimEnd('\', '/'))
    if ($leaf -ne '.vd-originals') { return }
    $parent = Split-Path -Parent $Directory
    if ($parent) { Remove-PlexIgnore -Directory $parent }
    Remove-RecycledHoldingFolder -Directory $Directory
}

function Get-ReplacePlan {
    param([Parameter(Mandatory)][string]$Source)
    $item = Get-Item -LiteralPath $Source
    $holdDir = Join-Path $item.DirectoryName '.vd-originals'
    $final = Join-Path $item.DirectoryName ($item.BaseName + '.mkv')
    $temp = Join-Path $holdDir ($item.BaseName + '.vd.tmp.mkv')
    $hold = Join-Path $holdDir $item.Name
    if (Test-Path -LiteralPath $hold) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $hold = Join-Path $holdDir ($item.BaseName + '.' + $stamp + $item.Extension)
    }
    $sameFinal = [string]::Equals(
        [IO.Path]::GetFullPath($final),
        [IO.Path]::GetFullPath($item.FullName),
        [StringComparison]::OrdinalIgnoreCase)
    return [pscustomobject]@{
        Source    = $item.FullName
        HoldDir   = $holdDir
        Temp      = $temp
        Final     = $final
        Hold      = $hold
        SameFinal = $sameFinal
        Blocked   = ((-not $sameFinal) -and (Test-Path -LiteralPath $final))
    }
}

function Invoke-ReplaceWithEncode {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$TempFile,
        [bool]$DeleteOriginal
    )
    if (-not (Test-Path -LiteralPath $Source)) { throw "The original is missing: $Source" }
    if (-not (Test-Path -LiteralPath $TempFile)) { throw "The new file is missing: $TempFile" }
    $sourceItem = Get-Item -LiteralPath $Source
    $tempItem = Get-Item -LiteralPath $TempFile
    if ($tempItem.Length -ge $sourceItem.Length) { throw 'The new file is not smaller than the original.' }
    if ($tempItem.Length -lt 64KB) { throw 'The new file is too small to keep.' }

    $plan = Get-ReplacePlan -Source $Source
    if ($plan.Blocked) { throw "A file already has the new name: $($plan.Final)" }
    New-Item -ItemType Directory -Force -Path $plan.HoldDir | Out-Null
    Add-PlexIgnore -Directory $sourceItem.DirectoryName
    if (Test-Path -LiteralPath $plan.Hold) { throw "A held original already exists: $($plan.Hold)" }

    Move-Item -LiteralPath $sourceItem.FullName -Destination $plan.Hold
    try {
        Move-Item -LiteralPath $tempItem.FullName -Destination $plan.Final
    }
    catch {
        if ((Test-Path -LiteralPath $plan.Hold) -and -not (Test-Path -LiteralPath $sourceItem.FullName)) {
            Move-Item -LiteralPath $plan.Hold -Destination $sourceItem.FullName
        }
        throw
    }

    $finalItem = Get-Item -LiteralPath $plan.Final
    if ($finalItem.Length -lt 64KB) {
        if (Test-Path -LiteralPath $plan.Final) { Remove-Item -LiteralPath $plan.Final -Force -ErrorAction SilentlyContinue }
        if (-not (Test-Path -LiteralPath $sourceItem.FullName) -and (Test-Path -LiteralPath $plan.Hold)) {
            Move-Item -LiteralPath $plan.Hold -Destination $sourceItem.FullName
        }
        throw 'The new file was too small after it was moved into place.'
    }

    $kept = $plan.Hold
    $deleted = $false
    if ($DeleteOriginal) {
        $holdLength = [int64](Get-Item -LiteralPath $plan.Hold -Force).Length
        Remove-Item -LiteralPath $plan.Hold -Force
        $kept = $null
        $deleted = $true
        if (-not (Test-Path -LiteralPath $plan.Hold)) {
            try { [void](Remove-RecycleCopy -Path $plan.Hold -Length $holdLength) } catch { }
        }
        Remove-EmptyDirectory -Directory $plan.HoldDir
    }

    return [pscustomobject]@{
        NewPath  = $plan.Final
        KeptPath = $kept
        Deleted  = $deleted
        NewBytes = $finalItem.Length
        OldBytes = $sourceItem.Length
    }
}

function Undo-ReplacedFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$KeptPath,
        [Parameter(Mandatory)][string]$NewPath
    )
    $kept = [IO.Path]::GetFullPath($KeptPath)
    $new = [IO.Path]::GetFullPath($NewPath)
    $source = [IO.Path]::GetFullPath($Source)
    if ($kept -notmatch '\\.vd-originals\\') {
        throw "Refusing to restore a file outside .vd-originals: $kept"
    }
    if (-not (Test-Path -LiteralPath $kept)) {
        throw "The held original is missing: $kept"
    }
    $sourceDir = Split-Path -Parent $source
    if (-not (Test-Path -LiteralPath $sourceDir)) {
        New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
    }
    $newExists = Test-Path -LiteralPath $new
    if ((Test-Path -LiteralPath $source) -and -not [string]::Equals($source, $new, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Something else is already at the original place: $source"
    }
    if (-not $newExists) {
        if (Test-Path -LiteralPath $source) {
            throw "The new file is missing and the original place is occupied: $source"
        }
        Move-Item -LiteralPath $kept -Destination $source
        Remove-EmptyDirectory -Directory (Split-Path -Parent $kept)
        return $true
    }
    $holdDir = Split-Path -Parent $kept
    $aside = Join-Path $holdDir ('.vd-undo-' + [guid]::NewGuid().ToString('n') + '.mkv')
    Move-Item -LiteralPath $new -Destination $aside
    try {
        if (Test-Path -LiteralPath $source) {
            throw "The original place is still occupied: $source"
        }
        Move-Item -LiteralPath $kept -Destination $source
    }
    catch {
        if ((Test-Path -LiteralPath $aside) -and -not (Test-Path -LiteralPath $new)) {
            Move-Item -LiteralPath $aside -Destination $new -ErrorAction SilentlyContinue
        }
        throw
    }
    $asideLength = [int64](Get-Item -LiteralPath $aside -Force).Length
    Remove-Item -LiteralPath $aside -Force
    if (-not (Test-Path -LiteralPath $aside)) {
        try { [void](Remove-RecycleCopy -Path $aside -Length $asideLength) } catch { }
    }
    Remove-EmptyDirectory -Directory $holdDir
    return $true
}

function Remove-KeptOriginal {
    param(
        [Parameter(Mandatory)][string]$KeptPath,
        [string]$NewPath
    )
    $full = [IO.Path]::GetFullPath($KeptPath)
    if ($full -notmatch '\\.vd-originals\\') {
        throw "Refusing to delete a file outside .vd-originals: $full"
    }
    if ($NewPath -and -not (Test-Path -LiteralPath $NewPath)) {
        throw "The new file is missing, so the original stays: $NewPath"
    }
    if (-not (Test-Path -LiteralPath $full)) { return $false }
    $length = [int64](Get-Item -LiteralPath $full -Force).Length
    Remove-Item -LiteralPath $full -Force
    if (-not (Test-Path -LiteralPath $full)) {
        try { [void](Remove-RecycleCopy -Path $full -Length $length) } catch { }
    }
    Remove-EmptyDirectory -Directory (Split-Path -Parent $full)
    return $true
}

function Get-CompareArguments {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right,
        [double]$StartSec = 0,
        [int]$FrameCount = 0,
        [string]$Output = 'pipe:1'
    )
    $width = $script:CompareHalfWidth
    $height = $script:CompareHalfHeight
    $filter = "[0:v]scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:black,setsar=1[a];[1:v]scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:black,setsar=1[b];[a][b]hstack=inputs=2[v]"
    $start = '{0:0.###}' -f $StartSec
    if ([double]$StartSec -le 0) { $start = '0' }
    $arguments = @(
        '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-ss', $start, '-i', $Left,
        '-ss', $start, '-i', $Right,
        '-filter_complex', $filter,
        '-map', '[v]',
        '-an', '-r', "$($script:CompareFps)"
    )
    if ($FrameCount -gt 0) { $arguments += @('-frames:v', "$FrameCount") }
    $arguments += @('-f', 'rawvideo', '-pix_fmt', 'bgr24', $Output)
    return $arguments
}

function Get-CompareFrameInfo {
    $width = $script:CompareHalfWidth * 2
    $height = $script:CompareHalfHeight
    return [pscustomobject]@{
        Width  = $width
        Height = $height
        Fps    = $script:CompareFps
        Bytes  = ($width * $height * 3)
    }
}

function Test-VideoFileName {
    param([string]$Path)
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (-not $script:VideoExtensions.ContainsKey($extension)) { return $false }
    $leaf = [IO.Path]::GetFileName($Path)
    if ($leaf -like '*.vd.tmp.mkv') { return $false }
    if ($leaf -like '*.hb.tmp.mkv') { return $false }
    if ($leaf -like '*.hb.src.bak*') { return $false }
    return $true
}

function Test-RememberedSkip {
    param(
        $Rows,
        [string]$Path,
        [int64]$SizeBytes,
        [int]$TargetKbps
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or $SizeBytes -le 0 -or $TargetKbps -le 0) { return $false }
    if ($null -eq $Rows) { return $false }
    foreach ($row in @($Rows)) {
        if ($null -eq $row -or -not $row.path) { continue }
        if (-not [string]::Equals([string]$row.path, $Path, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $savedSize = [int64]0
        [void][int64]::TryParse([string]$row.size, [ref]$savedSize)
        if ($savedSize -ne $SizeBytes) { continue }
        $savedTarget = 0
        [void][int]::TryParse([string]$row.targetKbps, [ref]$savedTarget)
        if ($savedTarget -gt 0 -and $TargetKbps -ge $savedTarget) { return $true }
    }
    return $false
}

function Merge-SkipRow {
    param(
        $Rows,
        [Parameter(Mandatory)][string]$Path,
        [int64]$SizeBytes,
        [int]$TargetKbps
    )
    $kept = New-Object System.Collections.Generic.List[object]
    $found = $false
    if ($null -ne $Rows) {
        foreach ($row in @($Rows)) {
            if ($null -eq $row -or -not $row.path) { continue }
            if (-not [string]::Equals([string]$row.path, $Path, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$kept.Add($row)
                continue
            }
            $found = $true
            $savedSize = [int64]0
            [void][int64]::TryParse([string]$row.size, [ref]$savedSize)
            $savedTarget = 0
            [void][int]::TryParse([string]$row.targetKbps, [ref]$savedTarget)
            $target = $TargetKbps
            if ($savedSize -eq $SizeBytes -and $savedTarget -gt 0 -and $savedTarget -lt $target) { $target = $savedTarget }
            [void]$kept.Add([pscustomobject]@{ path = $Path; size = $SizeBytes; targetKbps = $target })
        }
    }
    if (-not $found -and $SizeBytes -gt 0 -and $TargetKbps -gt 0) {
        [void]$kept.Add([pscustomobject]@{ path = $Path; size = $SizeBytes; targetKbps = $TargetKbps })
    }
    foreach ($row in $kept) { Write-Output $row }
}

function Remove-SkipRow {
    param(
        $Rows,
        [string]$Path
    )
    if ($null -eq $Rows -or [string]::IsNullOrWhiteSpace($Path)) {
        if ($null -ne $Rows) {
            foreach ($row in @($Rows)) { if ($null -ne $row -and $row.path) { Write-Output $row } }
        }
        return
    }
    foreach ($row in @($Rows)) {
        if ($null -eq $row -or -not $row.path) { continue }
        if ([string]::Equals([string]$row.path, $Path, [StringComparison]::OrdinalIgnoreCase)) { continue }
        Write-Output $row
    }
}

function Format-SkipJson {
    param($Rows)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Rows) {
        foreach ($row in @($Rows)) {
            if ($null -eq $row -or -not $row.path) { continue }
            $size = [int64]0
            [void][int64]::TryParse([string]$row.size, [ref]$size)
            $target = 0
            [void][int]::TryParse([string]$row.targetKbps, [ref]$target)
            if ($size -le 0 -or $target -le 0) { continue }
            $obj = [ordered]@{ path = [string]$row.path; size = $size; targetKbps = $target }
            [void]$parts.Add(($obj | ConvertTo-Json -Compress))
        }
    }
    if ($parts.Count -eq 0) { return '' }
    return '[' + ($parts -join ',') + ']'
}

function Convert-SkipRows([string]$Json) {
    if ([string]::IsNullOrWhiteSpace($Json)) { return }
    $parsed = $null
    try { $parsed = $Json | ConvertFrom-Json } catch { return }
    if ($null -eq $parsed) { return }
    foreach ($item in @($parsed)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Array]) {
            foreach ($inner in @($item)) {
                if ($null -ne $inner -and $inner.path) { Write-Output $inner }
            }
            continue
        }
        if ($item.path) { Write-Output $item }
    }
}

function Send-ScanMessage {
    param($Queue, $Object)
    $json = $Object | ConvertTo-Json -Compress -Depth 4
    $Queue.Enqueue([string]$json)
}

function Add-ScanDirectory {
    param(
        [string]$Directory,
        [bool]$Recurse,
        [string]$Ffprobe,
        $Queue,
        $Cancel,
        $State
    )
    if ($Cancel.Stop) { $State.Cancelled = $true; return }
    $leaf = [IO.Path]::GetFileName($Directory.TrimEnd('\'))
    if ($leaf -eq '.vd-originals') { return }
    $files = $null
    try {
        $files = @([IO.Directory]::EnumerateFiles($Directory))
    }
    catch {
        $State.Errors++
        if ($State.Samples.Count -lt 8) { [void]$State.Samples.Add($_.Exception.Message) }
        return
    }
    foreach ($file in $files) {
        if ($Cancel.Stop) { $State.Cancelled = $true; return }
        if (-not (Test-VideoFileName $file)) { continue }
        $State.Seen++
        $name = [IO.Path]::GetFileName($file)
        Send-ScanMessage $Queue @{ Kind = 'progress'; Seen = $State.Seen; Hits = $State.Hits; Shrink = $State.Shrink; Name = $name }
        try {
            $probe = Get-MediaProbe -Ffprobe $Ffprobe -File $file
            $decision = Get-BloatDecision -Probe $probe
            if ($decision.Decision -eq 'bloated' -or $decision.Decision -eq 'shrink') {
                if (Test-RememberedSkip -Rows $State.Skips -Path $file -SizeBytes ([int64]$probe.SizeBytes) -TargetKbps ([int]$decision.TargetKbps)) {
                    $State.Ignored++
                    continue
                }
                if ($decision.Decision -eq 'shrink') { $State.Shrink++ } else { $State.Hits++ }
                Send-ScanMessage $Queue @{
                    Kind          = 'hit'
                    Decision      = $decision.Decision
                    Path          = $file
                    Codec         = $probe.VideoCodec
                    Width         = $probe.Width
                    Height        = $probe.Height
                    DurationSec   = $probe.DurationSec
                    SizeBytes     = $probe.SizeBytes
                    GiBph         = $decision.GiBph
                    BudgetGiBph   = $decision.BudgetGiBph
                    TargetKbps    = $decision.TargetKbps
                    EstimateBytes = $decision.EstimateBytes
                    EstimateRough = [bool]$decision.EstimateRough
                    VideoBitrate  = $probe.VideoBitrate
                    Reason        = $decision.Reason
                }
            }
            elseif ($decision.Decision -eq 'dv') { $State.Dv++ }
            elseif ($decision.Decision -eq 'nodur' -or $decision.Decision -eq 'nopicture') { $State.NoDur++ }
            elseif ($decision.Decision -eq 'within') { $State.Within++ }
            else { $State.Lean++ }
        }
        catch {
            $State.Errors++
            if ($State.Samples.Count -lt 8) { [void]$State.Samples.Add("$name`: $($_.Exception.Message)") }
        }
    }
    if (-not $Recurse) { return }
    $dirs = $null
    try {
        $dirs = @([IO.Directory]::EnumerateDirectories($Directory))
    }
    catch {
        $State.Errors++
        if ($State.Samples.Count -lt 8) { [void]$State.Samples.Add($_.Exception.Message) }
        return
    }
    foreach ($sub in $dirs) {
        if ($Cancel.Stop) { $State.Cancelled = $true; return }
        Add-ScanDirectory -Directory $sub -Recurse $true -Ffprobe $Ffprobe -Queue $Queue -Cancel $Cancel -State $State
    }
}

function Invoke-ScanFolder {
    param(
        [Parameter(Mandatory)][string]$Root,
        [bool]$Recurse,
        [Parameter(Mandatory)][string]$Ffprobe,
        $Queue,
        $Cancel,
        $Skips
    )
    $samples = New-Object System.Collections.Generic.List[string]
    $state = @{
        Seen      = 0
        Hits      = 0
        Shrink    = 0
        Lean      = 0
        Dv        = 0
        NoDur     = 0
        Within    = 0
        Errors    = 0
        Ignored   = 0
        Samples   = $samples
        Cancelled = $false
        Skips     = @()
    }
    if ($null -ne $Skips) {
        $skipList = New-Object System.Collections.Generic.List[object]
        foreach ($row in @($Skips)) {
            if ($null -ne $row -and $row.path) { [void]$skipList.Add($row) }
        }
        $state.Skips = $skipList.ToArray()
    }
    try {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
            throw "That folder was not found: $Root"
        }
        Add-ScanDirectory -Directory $Root -Recurse $Recurse -Ffprobe $Ffprobe -Queue $Queue -Cancel $Cancel -State $state
    }
    catch {
        $state.Errors++
        if ($state.Samples.Count -lt 8) { [void]$state.Samples.Add($_.Exception.Message) }
    }
    finally {
        Send-ScanMessage $Queue @{
            Kind      = 'done'
            Seen      = $state.Seen
            Hits      = $state.Hits
            Shrink    = $state.Shrink
            Lean      = $state.Lean
            Dv        = $state.Dv
            NoDur     = $state.NoDur
            Within    = $state.Within
            Errors    = $state.Errors
            Ignored   = $state.Ignored
            Samples   = ($state.Samples -join ' | ')
            Cancelled = [bool]$state.Cancelled
        }
    }
}

function Invoke-RecycleSelfTest {
    $lone = @([pscustomobject]@{ Name = 'Movies' })
    Assert-Engine (Test-StaleRecycleChild -Children $lone -RemovedName 'Movies') 'a lone removed folder was not stale'
    $pair = @([pscustomobject]@{ Name = 'Movies' }, [pscustomobject]@{ Name = 'other.txt' })
    Assert-Engine (-not (Test-StaleRecycleChild -Children $pair -RemovedName 'Movies')) 'another name was treated as a stale listing'
    $otherName = @([pscustomobject]@{ Name = 'keep.txt' })
    Assert-Engine (-not (Test-StaleRecycleChild -Children $otherName -RemovedName 'Movies')) 'a different file was treated as a stale listing'
    $none = @()
    Assert-Engine (-not (Test-StaleRecycleChild -Children $none -RemovedName 'Movies')) 'an empty folder was treated as a stale listing'
    $plain = Get-RecyclePlan -Path '\\nas\media\TV\Show\.vd-originals\Episode.avi'
    Assert-Engine ($null -ne $plain) 'share path did not produce a recycle plan'
    Assert-Engine ($plain.ShareRoot -eq '\\nas\media') 'share root'
    Assert-Engine ($plain.RecycleFile -eq '\\nas\media\#recycle\TV\Show\.vd-originals\Episode.avi') 'recycle file path'
    Assert-Engine (-not $plain.AllowLocal) 'production plan allowed a local root'
    $rootHeld = Get-RecyclePlan -Path '\\nas\media\.vd-originals\Episode.avi'
    Assert-Engine ($rootHeld.RecycleFile -eq '\\nas\media\#recycle\.vd-originals\Episode.avi') 'share-root holding folder'
    $map = @{ Z = '\\nas\media\TV Shows' }
    $mapped = Get-RecyclePlan -Path 'Z:\Season 1\.vd-originals\Pilot.avi' -DriveMap $map
    Assert-Engine ($null -ne $mapped) 'mapped drive did not produce a recycle plan'
    Assert-Engine ($mapped.ShareRoot -eq '\\nas\media') 'mapped drive share root'
    Assert-Engine ($mapped.RecycleFile -eq '\\nas\media\#recycle\TV Shows\Season 1\.vd-originals\Pilot.avi') 'mapped drive recycle path'
    Assert-Engine ($null -eq (Get-RecyclePlan -Path 'C:\Library\.vd-originals\Episode.avi')) 'local disk produced a recycle plan'
    Assert-Engine ($null -eq (Get-RecyclePlan -Path '\\nas\media\TV\Show\Episode.avi')) 'a library file produced a recycle plan'
    Assert-Engine ($null -eq (Get-RecyclePlan -Path '\\nas\media\TV\.vd-originals\extra\Episode.avi')) 'a nested holding file produced a recycle plan'
    Assert-Engine ($null -eq (Get-RecyclePlan -Path '\\nas\media\#recycle\TV\.vd-originals\Episode.avi')) 'a path already in #recycle produced a plan'
    Assert-Engine ($null -eq (Get-RecyclePlan -Path '\\nas\media\ShowA\.vd-originals\..\ShowB\.vd-originals\Episode.avi')) 'a parent segment produced a plan'
    $odd = Get-RecyclePlan -Path ('\\nas\media\TV\Show' + "'" + 's\.vd-originals\Episode.avi')
    Assert-Engine ($odd.RecycleFile -eq ('\\nas\media\#recycle\TV\Show' + "'" + 's\.vd-originals\Episode.avi')) 'apostrophe path'
    $keptPurge = $script:RecyclePurgeEnabled
    $script:RecyclePurgeEnabled = $false
    $gated = Remove-RecycleCopy -Path '\\nas\media\TV\.vd-originals\Episode.avi' -Length 100
    Assert-Engine ($null -eq $gated) 'a turned-off recycle purge still ran'
    $gatedIgnore = Remove-RecycledPlexIgnore -Path '\\nas\media\TV\.plexignore' -Length 40
    Assert-Engine ($null -eq $gatedIgnore) 'a turned-off recycle purge removed a plexignore'
    $script:RecyclePurgeEnabled = $keptPurge
    Assert-Engine (Test-RecyclePurgeEnabled) 'recycle purge was off with no choice stored'
    $zero = Remove-RecycleCopy -Path '\\nas\media\TV\.vd-originals\Episode.avi' -Length 0
    Assert-Engine ($zero.Status -eq 'skipped') 'unknown length was purged'
    $localSkip = Remove-RecycleCopy -Path 'C:\Library\.vd-originals\Episode.avi' -Length 100
    Assert-Engine ($localSkip.Status -eq 'skipped') 'a local file was treated as a share'

    $root = $null
    $absentRoot = $null
    $junction = $null
    try {
        $root = Join-Path $env:TEMP ('vdh-recycle-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $relative = 'TV\Show\.vd-originals\Episode.avi'
        $recycleRoot = Join-Path $root '#recycle'
        $hold = Join-Path $recycleRoot 'TV\Show\.vd-originals'
        New-Item -ItemType Directory -Force -Path $hold | Out-Null
        $target = Join-Path $hold 'Episode.avi'
        $bytes = [Text.Encoding]::UTF8.GetBytes('original-bytes')
        [IO.File]::WriteAllBytes($target, $bytes)
        $decoy = Join-Path (Join-Path $recycleRoot 'TV\Show') 'Episode.avi'
        [IO.File]::WriteAllBytes($decoy, $bytes)
        $sibling = Join-Path $hold 'Other.avi'
        [IO.File]::WriteAllBytes($sibling, $bytes)
        $hidden = Join-Path $hold 'desktop.ini'
        [IO.File]::WriteAllText($hidden, 'keep')
        (Get-Item -LiteralPath $hidden -Force).Attributes = [IO.FileAttributes]::Hidden
        $tv = Join-Path $recycleRoot 'TV'
        $keep = Join-Path $tv 'keep.txt'
        [IO.File]::WriteAllText($keep, 'keep')
        $liveDir = Join-Path $root 'TV\Show'
        New-Item -ItemType Directory -Force -Path $liveDir | Out-Null
        $live = Join-Path $liveDir 'Episode.mkv'
        [IO.File]::WriteAllText($live, 'library')
        $plan = [pscustomobject]@{
            SourcePath  = '\\nas\media\TV\Show\.vd-originals\Episode.avi'
            ShareRoot   = $root
            Relative    = $relative
            RecycleRoot = $recycleRoot
            RecycleFile = $target
            Name        = 'Episode.avi'
            AllowLocal  = $true
            DriveMap    = $null
        }
        $off = [pscustomobject]@{
            SourcePath  = $plan.SourcePath
            ShareRoot   = $root
            Relative    = $relative
            RecycleRoot = $recycleRoot
            RecycleFile = $target
            Name        = 'Episode.avi'
            AllowLocal  = $false
            DriveMap    = $null
        }
        $blocked = Invoke-RecyclePurge -Plan $off -Length ([int64]$bytes.Length)
        Assert-Engine ($blocked.Status -eq 'skipped') 'a local root was accepted'
        Assert-Engine (Test-Path -LiteralPath $target) 'a local root removed the file'
        $wrong = Invoke-RecyclePurge -Plan $plan -Length ([int64]($bytes.Length + 9))
        Assert-Engine ($wrong.Status -eq 'mismatch') 'a different size was deleted'
        Assert-Engine ((Get-Item -LiteralPath $target).Length -eq $bytes.Length) 'a different size changed the file'
        $bad = [pscustomobject]@{
            SourcePath  = $live
            ShareRoot   = $root
            Relative    = 'TV\Show\Episode.mkv'
            RecycleRoot = $recycleRoot
            RecycleFile = $live
            Name        = 'Episode.mkv'
            AllowLocal  = $true
            DriveMap    = $null
        }
        $refused = Invoke-RecyclePurge -Plan $bad -Length ([int64](Get-Item -LiteralPath $live).Length)
        Assert-Engine ($refused.Status -eq 'skipped') 'a library path passed the recycle check'
        Assert-Engine ((Get-Content -LiteralPath $live -Raw) -eq 'library') 'the library file was changed'
        $purged = Invoke-RecyclePurge -Plan $plan -Length ([int64]$bytes.Length)
        Assert-Engine ($purged.Status -eq 'purged') 'the matching copy was not removed'
        Assert-Engine (-not (Test-Path -LiteralPath $target)) 'the matching copy remained'
        Assert-Engine (Test-Path -LiteralPath $decoy) 'a same-named file outside .vd-originals was deleted'
        Assert-Engine ((Get-Item -LiteralPath $decoy).Length -eq $bytes.Length) 'the decoy was changed'
        Assert-Engine (Test-Path -LiteralPath $sibling) 'a different held file was deleted'
        Assert-Engine (Test-Path -LiteralPath $hidden) 'a hidden file was deleted'
        Assert-Engine (Test-Path -LiteralPath $keep) 'keep.txt was deleted'
        Assert-Engine ((Get-Content -LiteralPath $live -Raw) -eq 'library') 'the library file was deleted'
        Assert-Engine (Test-Path -LiteralPath $hold) 'the holding folder was removed while files remained'
        Assert-Engine (Test-Path -LiteralPath $recycleRoot) 'the recycle root was removed'
        Remove-Item -LiteralPath $sibling -Force
        Remove-Item -LiteralPath $hidden -Force
        Remove-Item -LiteralPath $decoy -Force
        [IO.File]::WriteAllBytes($target, $bytes)
        $collapsed = Invoke-RecyclePurge -Plan $plan -Length ([int64]$bytes.Length)
        Assert-Engine ($collapsed.Status -eq 'purged') 'the empty-folder purge failed'
        Assert-Engine (-not (Test-Path -LiteralPath $hold)) 'the empty holding folder remained'
        $show = Join-Path $recycleRoot 'TV\Show'
        Assert-Engine (-not (Test-Path -LiteralPath $show)) 'the empty show folder remained'
        Assert-Engine (Test-Path -LiteralPath $tv) 'a folder that still had a file was removed'
        Assert-Engine (Test-Path -LiteralPath $keep) 'keep.txt was removed with its folder'
        Assert-Engine (Test-Path -LiteralPath $recycleRoot) 'the recycle root was removed after cleanup'
        Assert-Engine ((Get-Content -LiteralPath $live -Raw) -eq 'library') 'cleanup removed the library file'
        $soloHold = Join-Path $recycleRoot 'Solo\Nest\.vd-originals'
        New-Item -ItemType Directory -Force -Path $soloHold | Out-Null
        $clip = Join-Path $soloHold 'Clip.avi'
        [IO.File]::WriteAllBytes($clip, $bytes)
        $soloPlan = [pscustomobject]@{
            SourcePath  = '\\nas\media\Solo\Nest\.vd-originals\Clip.avi'
            ShareRoot   = $root
            Relative    = 'Solo\Nest\.vd-originals\Clip.avi'
            RecycleRoot = $recycleRoot
            RecycleFile = $clip
            Name        = 'Clip.avi'
            AllowLocal  = $true
            DriveMap    = $null
        }
        $solo = Invoke-RecyclePurge -Plan $soloPlan -Length ([int64]$bytes.Length)
        Assert-Engine ($solo.Status -eq 'purged') 'an empty folder chain was not purged'
        Assert-Engine (-not (Test-Path -LiteralPath $soloHold)) 'the empty nest holding folder remained'
        Assert-Engine (-not (Test-Path -LiteralPath (Join-Path $recycleRoot 'Solo\Nest'))) 'the empty nest folder remained'
        Assert-Engine (-not (Test-Path -LiteralPath (Join-Path $recycleRoot 'Solo'))) 'the empty solo folder remained'
        Assert-Engine (Test-Path -LiteralPath $recycleRoot) 'the recycle root was removed with an empty chain'
        Assert-Engine (Test-Path -LiteralPath $keep) 'an empty chain removed keep.txt'
        $busyDir = Join-Path $recycleRoot 'Busy'
        New-Item -ItemType Directory -Force -Path $busyDir | Out-Null
        $busyFile = Join-Path $busyDir 'other.txt'
        [IO.File]::WriteAllText($busyFile, 'keep')
        $busyWatch = [Diagnostics.Stopwatch]::StartNew()
        $busyEmpty = Test-RecycleDirectoryEmpty -Directory $busyDir -RemovedChild 'Gone'
        $busyWatch.Stop()
        Assert-Engine ($busyEmpty -eq $false) 'a folder with another file was treated as empty'
        Assert-Engine ($busyWatch.ElapsedMilliseconds -lt 120) 'a folder with another file waited'
        $busyRemoved = Remove-VerifiedEmptyRecycleDirectory -Path $busyDir -RemovedChild 'Gone'
        Assert-Engine (-not $busyRemoved) 'a folder with a file was removed'
        Assert-Engine ((Get-Content -LiteralPath $busyFile -Raw) -eq 'keep') 'a folder with a file lost that file'
        $sameDir = Join-Path $recycleRoot 'SameParent\Child'
        New-Item -ItemType Directory -Force -Path $sameDir | Out-Null
        $sameEmpty = Test-RecycleDirectoryEmpty -Directory (Split-Path -Parent $sameDir) -RemovedChild 'Child'
        Assert-Engine ($sameEmpty -eq $false) 'a real folder with the removed name was treated as empty'
        Assert-Engine (Test-Path -LiteralPath $sameDir) 'the real same-named folder was removed'
        $emptyShow = Join-Path $recycleRoot 'EmptyShow'
        New-Item -ItemType Directory -Force -Path $emptyShow | Out-Null
        Remove-EmptyRecycleDirectories -Plan $plan -StartDirectory $emptyShow -ExpectedRelative 'EmptyShow'
        Assert-Engine (Test-Path -LiteralPath $emptyShow) 'a folder outside .vd-originals was removed'
        $nestedHold = Join-Path (Join-Path $recycleRoot '#recycle\TV\Show') '.vd-originals'
        New-Item -ItemType Directory -Force -Path $nestedHold | Out-Null
        New-Item -ItemType Directory -Force -Path $hold | Out-Null
        [IO.File]::WriteAllBytes($target, $bytes)
        $nested = Join-Path $nestedHold 'Episode.avi'
        [IO.File]::WriteAllBytes($nested, $bytes)
        $nestedResult = Invoke-RecyclePurge -Plan $plan -Length ([int64]$bytes.Length)
        Assert-Engine ($nestedResult.Status -eq 'remained') 'a nested recycle copy was ignored'
        Assert-Engine (-not (Test-Path -LiteralPath $target)) 'the exact copy remained after the nested check'
        Assert-Engine (Test-Path -LiteralPath $nested) 'the nested copy was deleted'
        Assert-Engine (Test-Path -LiteralPath $keep) 'the nested check removed keep.txt'
        $linkHold = Join-Path $recycleRoot 'TV\LinkShow\.vd-originals'
        New-Item -ItemType Directory -Force -Path $linkHold | Out-Null
        $realDir = Join-Path $root 'real-dir'
        New-Item -ItemType Directory -Force -Path $realDir | Out-Null
        $marker = Join-Path $realDir 'marker.txt'
        [IO.File]::WriteAllText($marker, 'marker')
        $junction = Join-Path $linkHold 'Episode.avi'
        & cmd.exe /c "mklink /J `"$junction`" `"$realDir`"" | Out-Null
        Assert-Engine ($LASTEXITCODE -eq 0) 'the junction could not be created'
        $linkPlan = [pscustomobject]@{
            SourcePath  = '\\nas\media\TV\LinkShow\.vd-originals\Episode.avi'
            ShareRoot   = $root
            Relative    = 'TV\LinkShow\.vd-originals\Episode.avi'
            RecycleRoot = $recycleRoot
            RecycleFile = $junction
            Name        = 'Episode.avi'
            AllowLocal  = $true
            DriveMap    = $null
        }
        $linked = Invoke-RecyclePurge -Plan $linkPlan -Length 6
        Assert-Engine ($linked.Status -eq 'mismatch') 'a junction was deleted'
        Assert-Engine ((Get-Content -LiteralPath $marker -Raw) -eq 'marker') 'the junction target was deleted'
        Assert-Engine (Test-Path -LiteralPath $junction) 'the junction was removed'
        $absentRoot = Join-Path $env:TEMP ('vdh-recycle-absent-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path $absentRoot | Out-Null
        $bait = Join-Path $absentRoot 'Episode.avi'
        [IO.File]::WriteAllText($bait, 'bait')
        $absentPlan = [pscustomobject]@{
            SourcePath  = '\\nas\media\TV\.vd-originals\Episode.avi'
            ShareRoot   = $absentRoot
            Relative    = 'TV\.vd-originals\Episode.avi'
            RecycleRoot = (Join-Path $absentRoot '#recycle')
            RecycleFile = (Join-Path $absentRoot '#recycle\TV\.vd-originals\Episode.avi')
            Name        = 'Episode.avi'
            AllowLocal  = $true
            DriveMap    = $null
        }
        $absent = Invoke-RecyclePurge -Plan $absentPlan -Length 4
        Assert-Engine ($absent.Status -eq 'absent') 'a missing bin was treated as a failure'
        Assert-Engine ((Get-Content -LiteralPath $bait -Raw) -eq 'bait') 'a missing bin deleted another file'
    }
    finally {
        if ($junction -and (Test-Path -LiteralPath $junction)) {
            & cmd.exe /c "rmdir `"$junction`"" | Out-Null
        }
        if ($root -and (Test-Path -LiteralPath $root)) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($absentRoot -and (Test-Path -LiteralPath $absentRoot)) {
            Remove-Item -LiteralPath $absentRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-Engine {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-FakeProbe {
    param(
        [int]$Width,
        [int]$Height,
        [int64]$SizeBytes,
        [double]$DurationSec,
        [int64]$VideoBitrate = 0,
        [bool]$Efficient = $false,
        [bool]$Dolby = $false
    )
    return [pscustomobject]@{
        Width            = $Width
        Height           = $Height
        SizeBytes        = $SizeBytes
        DurationSec      = $DurationSec
        VideoBitrate     = $VideoBitrate
        AlreadyEfficient = $Efficient
        IsDolbyVision    = $Dolby
        SubCount         = 0
        AudioCount       = 0
    }
}

function Invoke-RecycleSidecarSelfTest {
    $owned = ((@(Get-PlexIgnoreLines) -join "`r`n") + "`r`n")
    Assert-Engine (Test-OwnedPlexIgnoreText $owned) 'owned plexignore text was rejected'
    Assert-Engine (-not (Test-OwnedPlexIgnoreText ($owned + "KeepMe`r`n"))) 'a plexignore with another line was accepted'
    Assert-Engine ($null -eq (Get-RecycleNamedPlan -Path '\\nas\media\Movies\Show\.plexignore' -LeafName 'notes.txt')) 'a non-plexignore name produced a plan'
    $named = Get-RecycleNamedPlan -Path '\\nas\media\Movies\Show\.plexignore' -LeafName '.plexignore'
    Assert-Engine ($named.RecycleFile -eq '\\nas\media\#recycle\Movies\Show\.plexignore') 'plexignore recycle path'
    Assert-Engine ($null -eq (Get-RecycleNamedPlan -Path '\\nas\media\#recycle\Movies\Show\.plexignore' -LeafName '.plexignore')) 'a plexignore already in #recycle produced a plan'
    $root = $null
    try {
        $root = Join-Path $env:TEMP ('vdh-plex-' + [guid]::NewGuid().ToString('n'))
        $recycleRoot = Join-Path $root '#recycle'
        $show = Join-Path $recycleRoot 'Movies\Show'
        New-Item -ItemType Directory -Force -Path $show | Out-Null
        $ignore = Join-Path $show '.plexignore'
        $bytes = [Text.Encoding]::UTF8.GetBytes($owned)
        [IO.File]::WriteAllBytes($ignore, $bytes)
        $other = Join-Path $recycleRoot 'Movies\other.txt'
        [IO.File]::WriteAllText($other, 'keep')
        $tv = Join-Path $recycleRoot 'TV'
        New-Item -ItemType Directory -Force -Path $tv | Out-Null
        $keep = Join-Path $tv 'keep.mkv'
        [IO.File]::WriteAllText($keep, 'video')
        $library = Join-Path $root 'library.txt'
        [IO.File]::WriteAllText($library, 'library')
        $plan = [pscustomobject]@{
            SourcePath  = '\\nas\media\Movies\Show\.plexignore'
            ShareRoot   = $root
            Relative    = 'Movies\Show\.plexignore'
            RecycleRoot = $recycleRoot
            RecycleFile = $ignore
            Name        = '.plexignore'
            AllowLocal  = $true
            DriveMap    = $null
        }
        $off = Invoke-RecyclePlexIgnorePurge -Plan ([pscustomobject]@{
            SourcePath = $plan.SourcePath; ShareRoot = $root; Relative = $plan.Relative
            RecycleRoot = $recycleRoot; RecycleFile = $ignore; Name = '.plexignore'
            AllowLocal = $false; DriveMap = $null
        }) -Length ([int64]$bytes.Length)
        Assert-Engine ($off.Status -eq 'skipped') 'a local plexignore root was accepted'
        Assert-Engine (Test-Path -LiteralPath $ignore) 'a local plexignore root removed the file'
        $wrong = Invoke-RecyclePlexIgnorePurge -Plan $plan -Length ([int64]($bytes.Length + 4))
        Assert-Engine ($wrong.Status -eq 'mismatch') 'a different plexignore size was deleted'
        Assert-Engine (Test-Path -LiteralPath $ignore) 'a different plexignore size removed the file'
        $extraDir = Join-Path $recycleRoot 'Movies\OtherShow'
        New-Item -ItemType Directory -Force -Path $extraDir | Out-Null
        $extra = Join-Path $extraDir '.plexignore'
        [IO.File]::WriteAllText($extra, ($owned + "KeepMe`r`n"))
        $extraPlan = [pscustomobject]@{
            SourcePath = $plan.SourcePath; ShareRoot = $root; Relative = 'Movies\OtherShow\.plexignore'
            RecycleRoot = $recycleRoot; RecycleFile = $extra; Name = '.plexignore'
            AllowLocal = $true; DriveMap = $null
        }
        $extraResult = Invoke-RecyclePlexIgnorePurge -Plan $extraPlan -Length ([int64](Get-Item -LiteralPath $extra).Length)
        Assert-Engine ($extraResult.Status -eq 'mismatch') 'a plexignore with other lines was deleted'
        Assert-Engine (Test-Path -LiteralPath $extra) 'a plexignore with other lines was removed'
        $purged = Invoke-RecyclePlexIgnorePurge -Plan $plan -Length ([int64]$bytes.Length)
        Assert-Engine ($purged.Status -eq 'purged') 'the owned plexignore was not removed'
        Assert-Engine (-not (Test-Path -LiteralPath $ignore)) 'the owned plexignore remained'
        Assert-Engine (-not (Test-Path -LiteralPath $show)) 'the empty show folder remained'
        Assert-Engine (Test-Path -LiteralPath (Join-Path $recycleRoot 'Movies')) 'a folder that still had a file was removed'
        Assert-Engine (Test-Path -LiteralPath $other) 'other.txt was removed'
        Assert-Engine (Test-Path -LiteralPath $keep) 'a video in another folder was removed'
        Assert-Engine (Test-Path -LiteralPath $extra) 'the other plexignore was removed'
        Assert-Engine ((Get-Content -LiteralPath $library -Raw) -eq 'library') 'the library file was removed'
        Assert-Engine (Test-Path -LiteralPath $recycleRoot) 'the recycle root was removed'
    }
    finally {
        if ($root -and (Test-Path -LiteralPath $root)) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-EngineSelfTest {
    Invoke-RecycleSelfTest
    Invoke-RecycleSidecarSelfTest
    Assert-Engine ((Get-TargetKbps -Width 1920 -Height 1080) -eq 3000) '1080p target'
    Assert-Engine ((Get-TargetKbps -Width 3840 -Height 2160) -eq 12000) '4K target'
    Assert-Engine ((Get-TargetKbps -Width 1280 -Height 720) -eq 1333) '720p target'
    Assert-Engine ((Get-TargetKbps -Width 720 -Height 480) -eq 500) '480p target'
    Assert-Engine ((Get-TargetKbps -Width 1920 -Height 800) -eq 2222) 'scope target'
    Assert-Engine ((Get-TargetKbps -Width 4096 -Height 2160) -eq 12800) 'DCI 4K target'
    Assert-Engine ((Get-TargetKbps -Width 160 -Height 120) -eq 200) 'tiny picture floor'
    $budget1080 = Get-BudgetGiBPerHour -Width 1920 -Height 1080 -Efficient $false
    Assert-Engine ([math]::Abs($budget1080 - 2.0) -lt 0.0001) '1080p budget'
    $hevc1080 = Get-BudgetGiBPerHour -Width 1920 -Height 1080 -Efficient $true
    Assert-Engine ([math]::Abs($hevc1080 - 3.0) -lt 0.0001) '1080p HEVC line'
    $budget4k = Get-BudgetGiBPerHour -Width 3840 -Height 2160 -Efficient $false
    Assert-Engine ([math]::Abs($budget4k - 8.0) -lt 0.0001) '4K budget'
    Assert-Engine ($null -eq (Get-OverRatio $null 2)) 'missing rate has no overage'
    Assert-Engine ($null -eq (Get-OverRatio 4 0)) 'zero budget has no overage'
    Assert-Engine ([math]::Abs((Get-OverRatio 4 2) - 2) -lt 0.0001) 'twice the budget'
    Assert-Engine ((Get-OverBandId 1.2) -eq 'slight') 'barely over is slight'
    Assert-Engine ((Get-OverBandId 1.49) -eq 'slight') 'under 1.5x is slight'
    Assert-Engine ((Get-OverBandId 1.5) -eq 'heavy') '1.5x is heavy'
    Assert-Engine ((Get-OverBandId 2.9) -eq 'heavy') 'under 3x is heavy'
    Assert-Engine ((Get-OverBandId 3) -eq 'extreme') '3x is extreme'
    Assert-Engine ((Get-OverBandId 0.8) -eq '') 'under budget is not a band'
    Assert-Engine ((Format-OverRatio 2) -eq '2.00x') 'over format'
    Assert-Engine ((Format-OverRatio 1) -eq '1.00x') 'the budget line reads 1.00x'
    Assert-Engine ((Format-OverRatio 1.04) -eq '1.04x') 'a small overage keeps two decimals'
    Assert-Engine ((Format-OverRatio 1.004) -eq '1.004x') 'a tiny overage does not round back to 1.00x'
    Assert-Engine ((Format-OverRatio $null) -eq '') 'blank over format'

    $hour = 3600.0
    $bloated = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]3GB) -DurationSec $hour -VideoBitrate 15000000)
    Assert-Engine ($bloated.Decision -eq 'bloated' -and $bloated.TargetKbps -eq 3000) '1080p over budget is bloated'

    $lean = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]1.5GB) -DurationSec $hour -VideoBitrate 2500000)
    Assert-Engine ($lean.Decision -eq 'lean') '1080p under budget is lean'

    $hevcOk = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]2.5GB) -DurationSec $hour -VideoBitrate 5000000 -Efficient $true)
    Assert-Engine ($hevcOk.Decision -eq 'shrink') 'HEVC under 3 GiB/h with a high picture rate can shrink'
    $hevcAtTarget = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]2.5GB) -DurationSec $hour -VideoBitrate 3000000 -Efficient $true)
    Assert-Engine ($hevcAtTarget.Decision -eq 'lean') 'HEVC under the line with a picture at the target is left alone'

    $hevcFat = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]3.2GB) -DurationSec $hour -VideoBitrate 7000000 -Efficient $true)
    Assert-Engine ($hevcFat.Decision -eq 'bloated') 'HEVC over 3 GiB/h is bloated'

    $fourLean = Get-BloatDecision -Probe (New-FakeProbe -Width 3840 -Height 2160 -SizeBytes ([int64]7GB) -DurationSec $hour -VideoBitrate 12000000)
    Assert-Engine ($fourLean.Decision -eq 'lean') '4K under 8 GiB/h with a picture at the target is left alone'
    $underLine = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64](1.9GB)) -DurationSec $hour -VideoBitrate 4500000)
    Assert-Engine ($underLine.Decision -eq 'shrink') 'a file under the line with a high picture rate can shrink'
    Assert-Engine ($underLine.EstimateBytes -lt [int64](1.9GB)) 'the can-shrink estimate is smaller'
    $underMissing = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64](1.9GB)) -DurationSec $hour)
    Assert-Engine ($underMissing.Decision -eq 'lean') 'a missing picture rate under the line stays off the list'
    $tinyUnder = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64](1.9GB)) -DurationSec $hour -VideoBitrate 100000)
    Assert-Engine ($tinyUnder.Decision -eq 'lean') 'a tiny picture rate under the line stays off the list'

    $fourFat = Get-BloatDecision -Probe (New-FakeProbe -Width 3840 -Height 2160 -SizeBytes ([int64]9GB) -DurationSec $hour -VideoBitrate 20000000)
    Assert-Engine ($fourFat.Decision -eq 'bloated' -and $fourFat.TargetKbps -eq 12000) '4K over 8 GiB/h targets 12000 kbps'

    $fileBps = (2.5GB * 8.0) / $hour
    $withinRate = [int64]($fileBps * 0.5)
    $within = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]2.5GB) -DurationSec $hour -VideoBitrate $withinRate)
    Assert-Engine ($within.Decision -eq 'within') 'picture already at the target is not converted'

    $bogus = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]6GB) -DurationSec $hour -VideoBitrate 100000)
    Assert-Engine ($bogus.Decision -eq 'bloated') 'a tiny reported bitrate does not hide a huge file'

    $targetOnly = [int64][math]::Round((3000 * 1000.0 * $hour) / 8.0)
    $missingRate = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]3GB) -DurationSec $hour)
    Assert-Engine ($missingRate.Decision -eq 'bloated') 'a missing picture rate is still bloated'
    Assert-Engine ($missingRate.EstimateBytes -eq $targetOnly) 'a missing picture rate uses the target size'
    Assert-Engine ([bool]$missingRate.EstimateRough) 'a missing picture rate is not marked rough'
    $audioBytes = [int64](192000 * $hour / 8.0)
    $videoBytes = [int64](8000000 * $hour / 8.0)
    $withAudio = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ($videoBytes + $audioBytes) -DurationSec $hour -VideoBitrate 8000000)
    $keptAudio = [int64][math]::Round(((3000 * 1000.0) + 192000) * $hour / 8.0)
    Assert-Engine ($withAudio.EstimateBytes -eq $keptAudio) 'a known picture rate keeps the other tracks'
    Assert-Engine (-not [bool]$withAudio.EstimateRough) 'a known picture rate was marked rough'
    $headerRate = [pscustomobject]@{ bit_rate = '8000000'; tags = [pscustomobject]@{ BPS = '1000' } }
    Assert-Engine ((Get-StreamBitrate $headerRate $hour) -eq 8000000) 'header bitrate wins'
    $tagRate = [pscustomobject]@{ bit_rate = ''; tags = [pscustomobject]@{ BPS = '4500000' } }
    Assert-Engine ((Get-StreamBitrate $tagRate $hour) -eq 4500000) 'BPS tag fills a missing bitrate'
    $byteTags = New-Object psobject
    $byteTags | Add-Member -NotePropertyName 'NUMBER_OF_BYTES-eng' -NotePropertyValue '1800000000'
    Assert-Engine ((Get-StreamBitrate ([pscustomobject]@{ tags = $byteTags }) $hour) -eq 4000000) 'byte-count tag fills a missing bitrate'
    Assert-Engine ((Get-StreamBitrate ([pscustomobject]@{}) $hour) -eq 0) 'no bitrate stays unknown'

    $dv = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]8GB) -DurationSec $hour -Dolby $true)
    Assert-Engine ($dv.Decision -eq 'dv') 'Dolby Vision is left alone'

    $sameStamp = '[null @ 0000028ef7cc3f80] Application provided invalid, non monotonically increasing dts to muxer in stream 0: 10 >= 10 | [null @ 0000028ef7cc3f80] Application provided invalid, non monotonically increasing dts to muxer in stream 0: 18 >= 18'
    Assert-Engine (Test-HarmlessDecodeNote $sameStamp) 'equal timestamp notes are harmless'
    Assert-Engine (Test-HarmlessDecodeNote '') 'an empty decode note is harmless'
    Assert-Engine (-not (Test-HarmlessDecodeNote '[null @ 0000028ef7cc3f80] Application provided invalid, non monotonically increasing dts to muxer in stream 0: 10 >= 4')) 'a backwards timestamp is not harmless'
    Assert-Engine (-not (Test-HarmlessDecodeNote ($sameStamp + ' | Error while decoding stream'))) 'another decode message is not harmless'
    $ac3Tail = 'decode Last exit=-1094995529 [ac3 @ 00000200d45dad40] incomplete frame | [aist#0:1/ac3 @ 00000200d2731900] [dec:ac3 @ 00000200d45b9b40] corrupt decoded frame | [aist#0:1/ac3 @ 00000200d2731900] [dec:ac3 @ 00000200d45b9b40] Error processing packet in decoder: Invalid data found when processing input | [aist#0:1/ac3 @ 00000200d2731900] [dec:ac3 @ 00000200d45b9b40] Task finished with error code: -1094995529 (Invalid data found when processing input) | [aist#0:1/ac3 @ 00000200d2731900] [dec:ac3 @ 00000200d45b9b40] Terminating thread with return code -1094995529 (Invalid data found when processing input)'
    Assert-Engine (Test-TrailingAc3Note $ac3Tail) 'one trailing incomplete AC3 frame is the allowed note'
    Assert-Engine (-not (Test-TrailingAc3Note ($ac3Tail + ' | [mpeg4 @ 00000001] error while decoding'))) 'a picture error stays a failure'
    Assert-Engine (-not (Test-TrailingAc3Note ($ac3Tail + ' | [ac3 @ 00000001] incomplete frame'))) 'two incomplete AC3 frames stay a failure'
    Assert-Engine (-not (Test-TrailingAc3Note ($ac3Tail -replace 'decode Last', 'decode First'))) 'the first window does not use the tail exception'
    Assert-Engine (-not (Test-TrailingAc3Note '')) 'a blank note is not a trailing AC3 frame'
    $ac3Frame = New-Object byte[] 768
    $ac3Frame[0] = 0x0B
    $ac3Frame[1] = 0x77
    $ac3Frame[4] = 20
    Assert-Engine ((Get-Ac3FrameSize $ac3Frame 0) -eq 768) '192 kbps 48 kHz AC3 frame is 768 bytes'
    $ac3Whole = New-Object byte[] 1536
    [Buffer]::BlockCopy($ac3Frame, 0, $ac3Whole, 0, 768)
    [Buffer]::BlockCopy($ac3Frame, 0, $ac3Whole, 768, 768)
    Assert-Engine (-not (Test-Ac3ShortTailBytes $ac3Whole)) 'a complete AC3 tail is not short'
    $ac3Short = New-Object byte[] (1536 + 288)
    [Buffer]::BlockCopy($ac3Whole, 0, $ac3Short, 0, 1536)
    $ac3Short[1536] = 0x0B
    $ac3Short[1537] = 0x77
    $ac3Short[1540] = 20
    Assert-Engine (Test-Ac3ShortTailBytes $ac3Short) 'a copied AC3 tail that ends mid-frame is short'
    $ac3Prefixed = New-Object byte[] (20 + $ac3Short.Length)
    [Buffer]::BlockCopy($ac3Short, 0, $ac3Prefixed, 20, $ac3Short.Length)
    Assert-Engine (Test-Ac3ShortTailBytes $ac3Prefixed) 'junk before the AC3 frames still shows the short tail'
    Assert-Engine (Test-CopiedAc3 @('ac3') @('ac3')) 'copied AC3 stays AC3'
    Assert-Engine (-not (Test-CopiedAc3 @('ac3') @('aac'))) 'AC3 re-encoded to AAC is not the tail exception'
    Assert-Engine (-not (Test-CopiedAc3 @('aac') @('aac'))) 'AAC does not use the AC3 tail exception'
    Assert-Engine (-not (Test-CopiedAc3 @('ac3', 'ac3') @('ac3', 'aac'))) 'one changed AC3 track blocks the exception'

    Assert-Engine (Test-CopyableAudioCodec 'aac') 'aac can be copied'
    Assert-Engine (Test-CopyableAudioCodec 'AC3') 'ac3 can be copied'
    Assert-Engine (-not (Test-CopyableAudioCodec 'wmav2')) 'wmav2 cannot be copied'
    Assert-Engine (-not (Test-CopyableAudioCodec 'vorbis')) 'vorbis cannot be copied'
    Assert-Engine (-not (Test-CopyableAudioCodec '')) 'a blank codec cannot be copied'
    Assert-Engine ((Get-AudioFallbackReason 'using fallback encoder') -eq 'audio could not be copied') 'a fallback encode is rejected'
    Assert-Engine ((Get-AudioFallbackReason 'using fallback encoder' -AllowReencode) -eq '') 'a chosen re-encode is allowed'
    Assert-Engine ((Get-AudioFallbackReason 'encoded fine') -eq '') 'a clean log has no audio failure'
    $blockedAudio = @(Get-AudioChangeReasons -SourceCodecs @('wmav2') -OutputCodecs @('aac'))
    Assert-Engine ($blockedAudio.Count -eq 1 -and $blockedAudio[0] -match 'wmav2 to aac') 'wmav2 re-encode is rejected when left off'
    $allowedAudio = @(Get-AudioChangeReasons -SourceCodecs @('wmav2') -OutputCodecs @('aac') -AllowReencode)
    Assert-Engine ($allowedAudio.Count -eq 0) 'wmav2 re-encode to aac is kept when turned on'
    $mixedAudio = @(Get-AudioChangeReasons -SourceCodecs @('aac', 'wmav2') -OutputCodecs @('aac', 'aac') -AllowReencode)
    Assert-Engine ($mixedAudio.Count -eq 0) 'copied aac plus re-encoded wmav2 is kept'
    $copyBroken = @(Get-AudioChangeReasons -SourceCodecs @('ac3') -OutputCodecs @('aac') -AllowReencode)
    Assert-Engine ($copyBroken.Count -eq 1) 'audio that can be copied is still required to stay as it was'
    $droppedAudio = @(Get-AudioChangeReasons -SourceCodecs @('wmav2') -OutputCodecs @() -AllowReencode)
    Assert-Engine (($droppedAudio -join ' ') -match 'tracks changed') 'a dropped track still fails when re-encode is on'
    $probeForArgs = New-FakeProbe -Width 640 -Height 480 -SizeBytes 1000000 -DurationSec 60
    $offArgs = (Get-HandBrakeArguments -Source 'in.wmv' -Temp 'out.mkv' -Probe $probeForArgs -VideoKbps 444 -Encoder 'x265') -join ' '
    $onArgs = (Get-HandBrakeArguments -Source 'in.wmv' -Temp 'out.mkv' -Probe $probeForArgs -VideoKbps 444 -Encoder 'x265' -ReencodeAudio) -join ' '
    Assert-Engine ($offArgs -match '--audio-fallback none') 'audio fallback stays off'
    Assert-Engine ($onArgs -match '--audio-fallback av_aac' -and $onArgs -match '--aencoder copy') 'audio fallback re-encodes to AAC'
    $bigger = Get-LargerFileNote -Reason 'the new file is not smaller; the new file is not smaller per hour' -SourceBytes 46391948 -NewBytes 55000000 -TargetKbps 200 -SourceCodecs @('aac') -OutputCodecs @('aac')
    Assert-Engine ($bigger -match 'left in place' -and $bigger -match '200 kbps' -and $bigger -match 'copied as it was' -and $bigger -match [regex]::Escape((Format-ByteSize 46391948)) -and $bigger -match 'more than this file already used') 'a larger file explains why'
    $biggerRe = Get-LargerFileNote -Reason 'the new file is not smaller per hour' -SourceBytes 100000000 -NewBytes 120000000 -TargetKbps 444 -SourceCodecs @('wmav2') -OutputCodecs @('aac')
    Assert-Engine ($biggerRe -match 're-encoded to AAC' -and $biggerRe -match '444 kbps') 'a larger re-encoded file says the audio changed'
    Assert-Engine ((Get-LargerFileNote -Reason 'audio could not be copied' -SourceBytes 100 -NewBytes 50 -TargetKbps 200) -eq '') 'another failure does not get the size note'
    Assert-Engine (Test-SizeSkipReason 'the new file is not smaller') 'a larger file is a skip'
    Assert-Engine (Test-SizeSkipReason 'the new file is not smaller; the new file is not smaller per hour') 'both size reasons are a skip'
    Assert-Engine (-not (Test-SizeSkipReason 'audio could not be copied; the new file is not smaller')) 'a size reason mixed with another problem is still a failure'
    Assert-Engine (-not (Test-SizeSkipReason 'audio could not be copied')) 'a real problem is not a skip'
    Assert-Engine (-not (Test-SizeSkipReason '')) 'a blank reason is not a skip'
    $remembered = @(Merge-SkipRow -Rows @() -Path 'C:\Show\A.mkv' -SizeBytes 1000 -TargetKbps 3000)
    Assert-Engine ($remembered.Count -eq 1) 'a size skip was not remembered'
    Assert-Engine (Test-RememberedSkip -Rows $remembered -Path 'c:\show\a.mkv' -SizeBytes 1000 -TargetKbps 3000) 'the same file was not ignored'
    Assert-Engine (Test-RememberedSkip -Rows $remembered -Path 'C:\Show\A.mkv' -SizeBytes 1000 -TargetKbps 4000) 'a higher target was not ignored'
    Assert-Engine (-not (Test-RememberedSkip -Rows $remembered -Path 'C:\Show\A.mkv' -SizeBytes 1000 -TargetKbps 1500)) 'a smaller target stayed ignored'
    Assert-Engine (-not (Test-RememberedSkip -Rows $remembered -Path 'C:\Show\A.mkv' -SizeBytes 999 -TargetKbps 3000)) 'a changed file stayed ignored'
    $tighter = @(Merge-SkipRow -Rows $remembered -Path 'C:\Show\A.mkv' -SizeBytes 1000 -TargetKbps 1500)
    Assert-Engine (Test-RememberedSkip -Rows $tighter -Path 'C:\Show\A.mkv' -SizeBytes 1000 -TargetKbps 1500) 'a later skip did not keep the smaller target'
    Assert-Engine (-not (Test-RememberedSkip -Rows $tighter -Path 'C:\Show\A.mkv' -SizeBytes 1000 -TargetKbps 1499)) 'a target under the remembered one stayed ignored'
    $roundTrip = @(Convert-SkipRows (Format-SkipJson $tighter))
    Assert-Engine (Test-RememberedSkip -Rows $roundTrip -Path 'C:\Show\A.mkv' -SizeBytes 1000 -TargetKbps 1500) 'a remembered skip did not survive saving'
    $cleared = @(Remove-SkipRow -Rows $roundTrip -Path 'c:\show\a.mkv')
    Assert-Engine ($cleared.Count -eq 0) 'clearing a skip left the file'
    Assert-Engine ((Format-SkipJson @()) -eq '') 'an empty skip list was written'

    $fraction = Get-HandBrakeFraction 'Encoding: task 1 of 2, 50.00 % (12.00 fps, avg 10.00 fps, ETA 00h00m10s)'
    Assert-Engine ([math]::Abs($fraction - 25) -lt 0.01) 'pass 1 progress'
    $fraction2 = Get-HandBrakeFraction 'Encoding: task 2 of 2, 50.00 %'
    Assert-Engine ([math]::Abs($fraction2 - 75) -lt 0.01) 'pass 2 progress'
    Assert-Engine ($null -eq (Get-HandBrakeFraction 'nothing to see')) 'non progress line'

    $frame = Get-CompareFrameInfo
    Assert-Engine ($frame.Width -eq 1920 -and $frame.Height -eq 540 -and $frame.Bytes -eq (1920 * 540 * 3)) 'compare frame size'

    $anchor1080 = $null
    $anchor720 = $null
    $anchor480 = $null
    foreach ($anchor in (Get-BudgetAnchors)) {
        if ($anchor.Id -eq '1080') { $anchor1080 = $anchor }
        if ($anchor.Id -eq '720') { $anchor720 = $anchor }
        if ($anchor.Id -eq '480') { $anchor480 = $anchor }
    }
    Assert-Engine ((Get-BudgetChoiceLabel -Anchor $anchor1080 -PickId 'recommended') -eq 'Recommended, 2 GiB/h') '1080p recommended label'
    Assert-Engine ((Get-BudgetChoiceLabel -Anchor $anchor1080 -PickId 'half') -eq 'Half, 1 GiB/h') '1080p half label'
    Assert-Engine ((Get-BudgetChoiceLabel -Anchor $anchor720 -PickId 'recommended') -eq 'Recommended, 0.89 GiB/h') '720p recommended label'
    Assert-Engine ((Get-BudgetChoiceLabel -Anchor $anchor480 -PickId 'recommended') -eq 'Recommended, 0.33 GiB/h') '480p recommended label'
    Assert-Engine ((Get-NearestBudgetAnchor -Width 1920 -Height 800).Id -eq '1080') 'scope uses 1080p'
    Assert-Engine ((Get-NearestBudgetAnchor -Width 2560 -Height 1440).Id -eq '1080') '1440p is nearer 1080p'
    $savedPicks = Get-BudgetPickPack
    try {
        Set-BudgetPicks '1080=half'
        Assert-Engine ((Get-TargetKbps -Width 1920 -Height 1080) -eq 1500) '1080p half target'
        Assert-Engine ([math]::Abs((Get-BudgetGiBPerHour -Width 1920 -Height 1080 -Efficient $false) - 1.0) -lt 0.0001) '1080p half budget'
        Assert-Engine ([math]::Abs((Get-BudgetGiBPerHour -Width 1920 -Height 1080 -Efficient $true) - 1.5) -lt 0.0001) '1080p half HEVC line'
        Assert-Engine ((Get-TargetKbps -Width 1920 -Height 800) -eq 1111) 'scope follows the 1080p budget'
        Assert-Engine ((Get-TargetKbps -Width 3840 -Height 2160) -eq 12000) '4K stays recommended when only 1080p changes'
        Set-BudgetPicks '2160=double;720=nope'
        Assert-Engine ((Get-TargetKbps -Width 3840 -Height 2160) -eq 24000) '4K double target'
        Assert-Engine ([math]::Abs((Get-BudgetGiBPerHour -Width 3840 -Height 2160 -Efficient $false) - 16.0) -lt 0.0001) '4K double budget'
        Assert-Engine ((Get-TargetKbps -Width 1280 -Height 720) -eq 1333) 'unknown budget choice is ignored'
        Set-BudgetPicks '1080=half'
        $halfHevc = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]2.5GB) -DurationSec 3600 -VideoBitrate 5000000 -Efficient $true)
        Assert-Engine ($halfHevc.Decision -eq 'bloated') 'HEVC over the lowered line is bloated'
    }
    finally {
        Set-BudgetPicks $savedPicks
    }

    $guard = Join-Path $env:TEMP 'vd-not-an-original.mp4'
    [IO.File]::WriteAllText($guard, 'keep')
    $threw = $false
    try { Remove-KeptOriginal -KeptPath $guard -NewPath $guard } catch { $threw = $true }
    Assert-Engine $threw 'delete guard'
    Assert-Engine ((Get-Content -LiteralPath $guard -Raw) -eq 'keep') 'guard did not delete'
    Remove-Item -LiteralPath $guard -Force

    $plexDir = Join-Path $env:TEMP ('vdh-plex-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $plexDir | Out-Null
    try {
        $plexHold = Join-Path $plexDir '.vd-originals'
        New-Item -ItemType Directory -Force -Path $plexHold | Out-Null
        $plexNew = Join-Path $plexDir 'clip.mkv'
        $plexA = Join-Path $plexHold 'a.avi'
        $plexB = Join-Path $plexHold 'b.avi'
        [IO.File]::WriteAllText($plexNew, 'new')
        [IO.File]::WriteAllText($plexA, 'a')
        [IO.File]::WriteAllText($plexB, 'b')
        Add-PlexIgnore -Directory $plexDir
        $plexFile = Join-Path $plexDir '.plexignore'
        Assert-Engine (Test-Path -LiteralPath $plexFile) 'plexignore was not written'
        Assert-Engine (Remove-KeptOriginal -KeptPath $plexA -NewPath $plexNew) 'first original was not deleted'
        Assert-Engine (Test-Path -LiteralPath $plexHold) 'holding folder was removed while another original remains'
        Assert-Engine (Test-Path -LiteralPath $plexFile) 'plexignore was removed while another original remains'
        Assert-Engine (Remove-KeptOriginal -KeptPath $plexB -NewPath $plexNew) 'last original was not deleted'
        Assert-Engine (-not (Test-Path -LiteralPath $plexHold)) 'holding folder stayed after the last original'
        Assert-Engine (-not (Test-Path -LiteralPath $plexFile)) 'plexignore stayed after the last original'

        New-Item -ItemType Directory -Force -Path $plexHold | Out-Null
        $plexC = Join-Path $plexHold 'c.avi'
        [IO.File]::WriteAllText($plexC, 'c')
        [IO.File]::WriteAllText($plexFile, "KeepMe`r`n.vd-originals`r`n.vd-originals/*`r`n")
        Remove-Item -LiteralPath $plexC -Force
        Remove-EmptyDirectory -Directory $plexHold
        Assert-Engine (-not (Test-Path -LiteralPath $plexHold)) 'auto cleanup left the holding folder'
        Assert-Engine (Test-Path -LiteralPath $plexFile) 'a plexignore with other lines was deleted'
        $plexLeft = [IO.File]::ReadAllText($plexFile)
        Assert-Engine ($plexLeft -match '(?m)^\s*KeepMe\s*$') 'other plexignore lines were dropped'
        Assert-Engine ($plexLeft -notmatch '(?m)^\s*\.vd-originals(\/\*)?\s*$') 'holding-folder lines stayed in plexignore'
    }
    finally {
        if (Test-Path -LiteralPath $plexDir) { Remove-Item -LiteralPath $plexDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $undoDir = Join-Path $env:TEMP ('vdh-undo-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $undoDir | Out-Null
    try {
        $holdDir = Join-Path $undoDir '.vd-originals'
        New-Item -ItemType Directory -Force -Path $holdDir | Out-Null
        $source = Join-Path $undoDir 'clip.avi'
        $new = Join-Path $undoDir 'clip.mkv'
        $kept = Join-Path $holdDir 'clip.avi'
        [IO.File]::WriteAllText($kept, 'original-bytes')
        [IO.File]::WriteAllText($new, 'new-bytes')
        [void](Undo-ReplacedFile -Source $source -KeptPath $kept -NewPath $new)
        Assert-Engine ((Get-Content -LiteralPath $source -Raw) -eq 'original-bytes') 'undo restored the original'
        Assert-Engine (-not (Test-Path -LiteralPath $new)) 'undo deleted the new file'
        Assert-Engine (-not (Test-Path -LiteralPath $kept)) 'undo removed the held original'
        Assert-Engine (-not (Test-Path -LiteralPath $holdDir)) 'undo removed the empty holding folder'

        New-Item -ItemType Directory -Force -Path $holdDir | Out-Null
        $source2 = Join-Path $undoDir 'movie.mkv'
        $kept2 = Join-Path $holdDir 'movie.mkv'
        [IO.File]::WriteAllText($kept2, 'orig-mkv')
        [IO.File]::WriteAllText($source2, 'new-mkv')
        [void](Undo-ReplacedFile -Source $source2 -KeptPath $kept2 -NewPath $source2)
        Assert-Engine ((Get-Content -LiteralPath $source2 -Raw) -eq 'orig-mkv') 'undo restored over the new mkv'

        $outside = Join-Path $undoDir 'not-held.avi'
        [IO.File]::WriteAllText($outside, 'x')
        $blocked = $false
        try { Undo-ReplacedFile -Source $source -KeptPath $outside -NewPath $new } catch { $blocked = $true }
        Assert-Engine $blocked 'undo refuses a file outside .vd-originals'
        Assert-Engine ((Get-Content -LiteralPath $outside -Raw) -eq 'x') 'undo left the outside file'

        New-Item -ItemType Directory -Force -Path $holdDir | Out-Null
        [IO.File]::WriteAllText($source, 'stranger')
        [IO.File]::WriteAllText($kept, 'original-bytes')
        [IO.File]::WriteAllText($new, 'new-bytes')
        $occupied = $false
        try { Undo-ReplacedFile -Source $source -KeptPath $kept -NewPath $new } catch { $occupied = $true }
        Assert-Engine $occupied 'undo refuses an occupied original place'
        Assert-Engine ((Get-Content -LiteralPath $source -Raw) -eq 'stranger') 'undo left the other file'
        Assert-Engine ((Get-Content -LiteralPath $new -Raw) -eq 'new-bytes') 'undo left the new file'
        Assert-Engine ((Get-Content -LiteralPath $kept -Raw) -eq 'original-bytes') 'undo left the held original'
    }
    finally {
        if (Test-Path -LiteralPath $undoDir) { Remove-Item -LiteralPath $undoDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-PipelineTest {
    $tools = Get-BundledTools
    foreach ($path in @($tools.Ffmpeg, $tools.Ffprobe, $tools.HandBrake)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing tool: $path" }
    }
    $dir = Join-Path $env:TEMP ('video-dehydrator-test-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $bloated = Join-Path $dir 'bloated.mp4'
        $lean = Join-Path $dir 'lean.mp4'
        $made = Invoke-CapturedProcess -File $tools.Ffmpeg -Arguments @(
            '-y', '-hide_banner', '-loglevel', 'error',
            '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=24:duration=4,noise=alls=100:allf=t',
            '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=4',
            '-c:v', 'libx264', '-preset', 'veryfast', '-b:v', '6000k', '-minrate', '5000k', '-maxrate', '7000k', '-bufsize', '3000k', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-b:a', '128k', '-shortest', $bloated
        )
        if ($made.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $bloated)) {
            throw "Could not make the test video. $($made.StdErr)"
        }
        $madeLean = Invoke-CapturedProcess -File $tools.Ffmpeg -Arguments @(
            '-y', '-hide_banner', '-loglevel', 'error',
            '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=24:duration=4',
            '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=4',
            '-c:v', 'libx264', '-b:v', '180k', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-b:a', '64k', '-shortest', $lean
        )
        if ($madeLean.ExitCode -ne 0) { throw "Could not make the lean video. $($madeLean.StdErr)" }

        $probe = Get-MediaProbe -Ffprobe $tools.Ffprobe -File $bloated
        $decision = Get-BloatDecision -Probe $probe
        if ($decision.Decision -ne 'bloated') { throw "Test video was $($decision.Decision), expected bloated. GiB/h=$($decision.GiBph) budget=$($decision.BudgetGiBph)" }
        $leanProbe = Get-MediaProbe -Ffprobe $tools.Ffprobe -File $lean
        $leanDecision = Get-BloatDecision -Probe $leanProbe
        if ($leanDecision.Decision -eq 'bloated') { throw "Lean video was marked bloated. GiB/h=$($leanDecision.GiBph) budget=$($leanDecision.BudgetGiBph)" }

        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        $cancel = @{ Stop = $false }
        Invoke-ScanFolder -Root $dir -Recurse $true -Ffprobe $tools.Ffprobe -Queue $queue -Cancel $cancel
        $hits = 0
        $done = $null
        while ($queue.Count -gt 0) {
            $line = $null
            if (-not $queue.TryDequeue([ref]$line)) { break }
            $msg = $line | ConvertFrom-Json
            if ($msg.Kind -eq 'hit') { $hits++ }
            if ($msg.Kind -eq 'done') { $done = $msg }
        }
        if ($hits -ne 1) { throw "Scan found $hits bloated files, expected 1." }
        if ($null -eq $done) { throw 'Scan did not finish.' }

        $plan = Get-ReplacePlan -Source $bloated
        if ($plan.Blocked) { throw 'Replace plan was blocked before the encode.' }
        New-Item -ItemType Directory -Force -Path $plan.HoldDir | Out-Null
        $encoder = Get-EncoderName -Probe $probe
        $hbArgs = Get-HandBrakeArguments -Source $bloated -Temp $plan.Temp -Probe $probe -VideoKbps $decision.TargetKbps -Encoder $encoder
        Write-Output ("ENCODE " + (ConvertTo-ArgumentLine $hbArgs))
        $encoded = Invoke-CapturedProcess -File $tools.HandBrake -Arguments $hbArgs
        if ($encoded.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $plan.Temp)) {
            $tail = (($encoded.StdOut + "`n" + $encoded.StdErr) -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 12) -join ' | '
            throw "HandBrake failed ($($encoded.ExitCode)). $tail"
        }
        $log = $encoded.StdOut + "`n" + $encoded.StdErr
        $verify = Test-EncodedFile -Ffmpeg $tools.Ffmpeg -Ffprobe $tools.Ffprobe -Temp $plan.Temp -SourceProbe $probe -HandBrakeLog $log
        if (-not $verify.Ok) { throw "Verify failed: $($verify.Reason)" }
        $swap = Invoke-ReplaceWithEncode -Source $bloated -TempFile $plan.Temp -DeleteOriginal $false
        if (-not (Test-Path -LiteralPath $swap.NewPath)) { throw 'New file is missing after the swap.' }
        if (-not (Test-Path -LiteralPath $swap.KeptPath)) { throw 'Original was not kept.' }
        if (Test-Path -LiteralPath $bloated) { throw 'Original path was not cleared.' }
        $newItem = Get-Item -LiteralPath $swap.NewPath
        if ($newItem.Length -ge $swap.OldBytes) { throw 'New file is not smaller.' }
        if ($swap.KeptPath -notmatch '\\.vd-originals\\') { throw 'Original was not moved into .vd-originals.' }

        $raw = Join-Path $dir 'frame.raw'
        $compare = Get-CompareArguments -Left $swap.KeptPath -Right $swap.NewPath -StartSec 0.5 -FrameCount 1 -Output $raw
        $frameRun = Invoke-CapturedProcess -File $tools.Ffmpeg -Arguments $compare
        if ($frameRun.ExitCode -ne 0) { throw "Compare frame failed. $($frameRun.StdErr)" }
        $info = Get-CompareFrameInfo
        $rawItem = Get-Item -LiteralPath $raw
        if ($rawItem.Length -ne $info.Bytes) { throw "Compare frame was $($rawItem.Length) bytes, expected $($info.Bytes)." }

        $removed = Remove-KeptOriginal -KeptPath $swap.KeptPath -NewPath $swap.NewPath
        if (-not $removed) { throw 'Original was not deleted.' }
        if (Test-Path -LiteralPath $swap.KeptPath) { throw 'Held original is still on disk.' }
        if (-not (Test-Path -LiteralPath $swap.NewPath)) { throw 'Delete removed the new file too.' }
        Write-Output 'PIPELINE OK'
    }
    finally {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($args -contains '-PipelineTest') {
        try {
            Invoke-PipelineTest
            exit 0
        }
        catch {
            Write-Output ("PIPELINE FAIL: " + $_.Exception.Message)
            Write-Output $_.ScriptStackTrace
            exit 1
        }
    }
    if ($args -contains '-SelfTest') {
        try {
            Invoke-EngineSelfTest
            Write-Output 'SELF TEST OK'
            exit 0
        }
        catch {
            Write-Output ("SELF TEST FAIL: " + $_.Exception.Message)
            Write-Output $_.ScriptStackTrace
            exit 1
        }
    }
    Write-Output 'Open Video Dehydrator from the folder above this one.'
    exit 0
}
