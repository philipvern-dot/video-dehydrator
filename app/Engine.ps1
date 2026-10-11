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
    return ('{0:0.0}x' -f [double]$Ratio)
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
        $decision = 'lean'
        $reason = 'Under the budget for this picture size.'
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
        [Parameter(Mandatory)][string]$Encoder
    )
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
        '--audio-fallback', 'none'
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
    if ($run.ExitCode -ne 0 -or $err) {
        return [pscustomobject]@{ Ok = $false; Detail = "decode $Window exit=$($run.ExitCode) $err" }
    }
    return [pscustomobject]@{ Ok = $true; Detail = '' }
}

function Test-EncodedFile {
    param(
        [Parameter(Mandatory)][string]$Ffmpeg,
        [Parameter(Mandatory)][string]$Ffprobe,
        [Parameter(Mandatory)][string]$Temp,
        $SourceProbe,
        [string]$HandBrakeLog
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
    if ($HandBrakeLog -match 'passthru not possible|Auto Passthru: no codecs allowed|using fallback encoder') {
        $reasons.Add('audio could not be copied')
    }
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
    if (-not $last.Ok) { $reasons.Add($last.Detail) }
    if ($out.AudioCount -ne $SourceProbe.AudioCount) {
        $reasons.Add("audio tracks changed from $($SourceProbe.AudioCount) to $($out.AudioCount)")
    }
    $sourceAudio = @($SourceProbe.AudioCodecs)
    $outputAudio = @($out.AudioCodecs)
    $audioSlots = [math]::Max($sourceAudio.Count, $outputAudio.Count)
    for ($i = 0; $i -lt $audioSlots; $i++) {
        $left = if ($i -lt $sourceAudio.Count) { $sourceAudio[$i] } else { 'missing' }
        $right = if ($i -lt $outputAudio.Count) { $outputAudio[$i] } else { 'missing' }
        if ($left -ne $right) { $reasons.Add("audio $i changed from $left to $right") }
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
            Remove-Item -LiteralPath $path -Force
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
        Remove-Item -LiteralPath $plan.Hold -Force
        $kept = $null
        $deleted = $true
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
    Remove-Item -LiteralPath $aside -Force
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
    Remove-Item -LiteralPath $full -Force
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
        Send-ScanMessage $Queue @{ Kind = 'progress'; Seen = $State.Seen; Hits = $State.Hits; Name = $name }
        try {
            $probe = Get-MediaProbe -Ffprobe $Ffprobe -File $file
            $decision = Get-BloatDecision -Probe $probe
            if ($decision.Decision -eq 'bloated') {
                $State.Hits++
                Send-ScanMessage $Queue @{
                    Kind          = 'hit'
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
        $Cancel
    )
    $samples = New-Object System.Collections.Generic.List[string]
    $state = @{
        Seen      = 0
        Hits      = 0
        Lean      = 0
        Dv        = 0
        NoDur     = 0
        Within    = 0
        Errors    = 0
        Samples   = $samples
        Cancelled = $false
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
            Lean      = $state.Lean
            Dv        = $state.Dv
            NoDur     = $state.NoDur
            Within    = $state.Within
            Errors    = $state.Errors
            Samples   = ($state.Samples -join ' | ')
            Cancelled = [bool]$state.Cancelled
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

function Invoke-EngineSelfTest {
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
    Assert-Engine ((Format-OverRatio 2) -eq '2.0x') 'over format'
    Assert-Engine ((Format-OverRatio $null) -eq '') 'blank over format'

    $hour = 3600.0
    $bloated = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]3GB) -DurationSec $hour -VideoBitrate 15000000)
    Assert-Engine ($bloated.Decision -eq 'bloated' -and $bloated.TargetKbps -eq 3000) '1080p over budget is bloated'

    $lean = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]1.5GB) -DurationSec $hour -VideoBitrate 2500000)
    Assert-Engine ($lean.Decision -eq 'lean') '1080p under budget is lean'

    $hevcOk = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]2.5GB) -DurationSec $hour -VideoBitrate 5000000 -Efficient $true)
    Assert-Engine ($hevcOk.Decision -eq 'lean') 'HEVC under 3 GiB/h is lean'

    $hevcFat = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ([int64]3.2GB) -DurationSec $hour -VideoBitrate 7000000 -Efficient $true)
    Assert-Engine ($hevcFat.Decision -eq 'bloated') 'HEVC over 3 GiB/h is bloated'

    $fourLean = Get-BloatDecision -Probe (New-FakeProbe -Width 3840 -Height 2160 -SizeBytes ([int64]7GB) -DurationSec $hour -VideoBitrate 14000000)
    Assert-Engine ($fourLean.Decision -eq 'lean') '4K under 8 GiB/h is lean'

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
    $audioBytes = [int64](192000 * $hour / 8.0)
    $videoBytes = [int64](8000000 * $hour / 8.0)
    $withAudio = Get-BloatDecision -Probe (New-FakeProbe -Width 1920 -Height 1080 -SizeBytes ($videoBytes + $audioBytes) -DurationSec $hour -VideoBitrate 8000000)
    $keptAudio = [int64][math]::Round(((3000 * 1000.0) + 192000) * $hour / 8.0)
    Assert-Engine ($withAudio.EstimateBytes -eq $keptAudio) 'a known picture rate keeps the other tracks'
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
