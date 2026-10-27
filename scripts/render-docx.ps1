param(
    [Parameter(Mandatory = $true)][string]$Docx,
    [Parameter(Mandatory = $true)][string]$Pdf
)
$ErrorActionPreference = 'Stop'
$word = $null
try {
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false
    $word.DisplayAlerts = 0
    $doc = $word.Documents.Open($Docx, $false, $true)
    $doc.SaveAs([ref]$Pdf, [ref]17)
    $doc.Close([ref]0)
    'pdf: ' + $Pdf
    'size: ' + (Get-Item $Pdf).Length
} catch {
    'RENDER FAILED: ' + $_.Exception.Message
    exit 1
} finally {
    if ($word) {
        try { $word.Quit() } catch { }
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) } catch { }
    }
}
