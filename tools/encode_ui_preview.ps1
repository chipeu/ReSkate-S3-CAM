param([string]$Frames, [string]$Output)
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
$encoder = [System.Windows.Media.Imaging.GifBitmapEncoder]::new()
$index = 0
foreach ($file in (Get-ChildItem -LiteralPath $Frames -Filter 'frame-*.png' | Sort-Object Name)) {
    $image = [System.Windows.Media.Imaging.BitmapImage]::new()
    $image.BeginInit()
    $image.UriSource = [Uri]::new($file.FullName)
    $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.DecodePixelWidth = 900
    $image.EndInit();$image.Freeze()
    $metadata = [System.Windows.Media.Imaging.BitmapMetadata]::new('gif')
    $metadata.SetQuery('/grctlext/Delay',[UInt16]5)
    $metadata.SetQuery('/grctlext/Disposal',[Byte]2)
    if ($index -eq 0) {
        $metadata.SetQuery('/appext/application',[System.Text.Encoding]::ASCII.GetBytes('NETSCAPE2.0'))
        $metadata.SetQuery('/appext/data',[byte[]](3,1,0,0,0))
    }
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($image,$null,$metadata,$null))
    $index += 1
}
$stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($Output),[System.IO.FileMode]::Create)
try {$encoder.Save($stream)} finally {$stream.Dispose()}
python (Join-Path $PSScriptRoot 'fix_gif_metadata.py') $Output
if ($LASTEXITCODE -ne 0) {throw 'Could not set GIF preview timing'}
Write-Output "Encoded $index offline UI frames"
