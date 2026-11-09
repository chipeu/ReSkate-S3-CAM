param([string]$Commands, [string]$Output, [switch]$NoOverview)
# Offline drawing-command preview. Segoe UI approximates the game's body font.
Add-Type -AssemblyName System.Drawing
$raw = Get-Content -LiteralPath $Commands -Raw
$frames = ($raw.Substring($raw.IndexOf('PREVIEW_JSON ') + 13)) | ConvertFrom-Json
$dest = [System.IO.Path]::GetFullPath($Output)
[System.IO.Directory]::CreateDirectory($dest) | Out-Null
$totalWidth = 0
foreach ($frame in $frames) { $totalWidth += $(if ($frame.width) {[int]$frame.width} else {896}) }
if (-not $NoOverview) {
    $strip = [System.Drawing.Bitmap]::new($totalWidth, 1080)
    $stripGraphics = [System.Drawing.Graphics]::FromImage($strip)
}
$frameX = 0
foreach ($frame in $frames) {
    $frameWidth = if ($frame.width) {[int]$frame.width} else {896}
    $bitmap = [System.Drawing.Bitmap]::new($frameWidth,1080)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(255,55,58,61))
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $clips = [System.Collections.Generic.Stack[System.Drawing.Drawing2D.GraphicsState]]::new()
    foreach ($shape in $frame.commands) {
        if ($shape.kind -eq 'clip') {
            $clips.Push($graphics.Save())
            $graphics.SetClip([System.Drawing.RectangleF]::new($shape.a[0],$shape.a[1],($shape.b[0]-$shape.a[0]),($shape.b[1]-$shape.a[1])))
            continue
        }
        if ($shape.kind -eq 'unclip') { $graphics.Restore($clips.Pop()); continue }
        $hex = $shape.style.colour.TrimStart('#')
        $alpha = if ($hex.Length -eq 8) { [Convert]::ToInt32($hex.Substring(6,2),16) } else {255}
        $colour = [System.Drawing.Color]::FromArgb($alpha,[Convert]::ToInt32($hex.Substring(0,2),16),[Convert]::ToInt32($hex.Substring(2,2),16),[Convert]::ToInt32($hex.Substring(4,2),16))
        $brush = [System.Drawing.SolidBrush]::new($colour)
        if ($shape.kind -eq 'rect') {
            $graphics.FillRectangle($brush,[float]$shape.a[0],[float]$shape.a[1],[float]($shape.b[0]-$shape.a[0]),[float]($shape.b[1]-$shape.a[1]))
        } elseif ($shape.kind -eq 'circle') {
            $radius = [float]$shape.b
            if ($shape.style.fill) {$graphics.FillEllipse($brush,[float]($shape.a[0]-$radius),[float]($shape.a[1]-$radius),2*$radius,2*$radius)}
            else {
                $pen = [System.Drawing.Pen]::new($colour,[float]$shape.style.thickness)
                $graphics.DrawEllipse($pen,[float]($shape.a[0]-$radius),[float]($shape.a[1]-$radius),2*$radius,2*$radius);$pen.Dispose()
            }
        } elseif ($shape.kind -eq 'line') {
            $pen = [System.Drawing.Pen]::new($colour,[float]$shape.style.thickness)
            $graphics.DrawLine($pen,[float]$shape.a[0],[float]$shape.a[1],[float]$shape.b[0],[float]$shape.b[1]);$pen.Dispose()
        } elseif ($shape.kind -eq 'text') {
            $family = if ($shape.style.font -eq 'heading') {'Impact'} else {'Segoe UI'}
            $weight = if ($shape.style.font -eq 'bold') {[System.Drawing.FontStyle]::Bold} else {[System.Drawing.FontStyle]::Regular}
            $font = [System.Drawing.Font]::new($family,[float]$shape.style.size,$weight,[System.Drawing.GraphicsUnit]::Pixel)
            $format = [System.Drawing.StringFormat]::new([System.Drawing.StringFormat]::GenericTypographic)
            if ($shape.style.align -eq 'right') { $format.Alignment = [System.Drawing.StringAlignment]::Far }
            $graphics.DrawString([string]$shape.b,$font,$brush,[System.Drawing.PointF]::new($shape.a[0],$shape.a[1]),$format)
            $format.Dispose();$font.Dispose()
        }
        $brush.Dispose()
    }
    $fileName = $frame.name.Replace(' ','-').ToLowerInvariant() + '.png'
    $bitmap.Save([System.IO.Path]::Combine($dest,$fileName))
    if (-not $NoOverview) {$stripGraphics.DrawImageUnscaled($bitmap,$frameX,0)}
    $graphics.Dispose();$bitmap.Dispose();$frameX += $frameWidth
}
if (-not $NoOverview) {
    $strip.Save([System.IO.Path]::Combine($dest,'ui-overview.png'))
    $stripGraphics.Dispose();$strip.Dispose()
}
