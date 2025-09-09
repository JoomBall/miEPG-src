# EPG Fixer - Corrige problemas de duplicados, solapamientos y XML
# Versión mejorada para mantener calidad EPG

param(
    [Parameter(Mandatory=$true)]
    [string]$EPGFile,
    
    [string]$OutputFile = $null,
    [switch]$Backup = $true
)

Write-Host "=== EPG FIXER - CORRECCIÓN AUTOMÁTICA ===" -ForegroundColor Cyan
Write-Host "Archivo: $EPGFile" -ForegroundColor Yellow

if (-not (Test-Path $EPGFile)) {
    Write-Host "❌ Archivo no encontrado: $EPGFile" -ForegroundColor Red
    exit 1
}

# Crear backup si se solicita
if ($Backup) {
    $backupFile = "$EPGFile.backup.$(Get-Date -Format 'yyyyMMdd_HHmm')"
    Copy-Item $EPGFile $backupFile
    Write-Host "✅ Backup creado: $backupFile" -ForegroundColor Green
}

# Determinar archivo de salida
if (-not $OutputFile) {
    $OutputFile = $EPGFile
}

Write-Host ""
Write-Host "🔧 INICIANDO CORRECCIONES..." -ForegroundColor Green

# 1. CORRECCIÓN DE ELEMENTOS XML INVÁLIDOS
Write-Host "1. Corrigiendo elementos XML inválidos..." -ForegroundColor Yellow
$content = Get-Content $EPGFile -Raw

# Contar errores antes
$invalidElements = [regex]::Matches($content, '<[0-9][^>]*>')
$invalidCount = $invalidElements.Count

if ($invalidCount -gt 0) {
    Write-Host "   ⚠️  Elementos inválidos encontrados: $invalidCount" -ForegroundColor Red
    
    # Corregir elementos que empiecen con números
    # Patrón: <5digitssomething> -> <programme5digitssomething> o eliminar
    $content = $content -replace '<([0-9][^>]*?)>', '<!-- ELEMENTO_INVALIDO: $1 -->'
    
    Write-Host "   ✅ Elementos inválidos comentados" -ForegroundColor Green
} else {
    Write-Host "   ✅ No se encontraron elementos XML inválidos" -ForegroundColor Green
}

# 2. EXTRACCIÓN Y ORGANIZACIÓN DE PROGRAMAS
Write-Host "2. Organizando programas por canal..." -ForegroundColor Yellow

# Extraer todos los programas válidos
$programPattern = '<programme\s+start="([^"]*)"\s+stop="([^"]*)"\s+channel="([^"]*)"[^>]*>.*?</programme>'
$programMatches = [regex]::Matches($content, $programPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

Write-Host "   📊 Programas encontrados: $($programMatches.Count)" -ForegroundColor White

# Organizar por canal
$channelPrograms = @{}
foreach ($match in $programMatches) {
    $channel = $match.Groups[3].Value
    $start = $match.Groups[1].Value
    $stop = $match.Groups[2].Value
    $fullProgram = $match.Value
    
    if (-not $channelPrograms.ContainsKey($channel)) {
        $channelPrograms[$channel] = @()
    }
    
    $channelPrograms[$channel] += @{
        Start = $start
        Stop = $stop
        Full = $fullProgram
        StartDate = [datetime]::ParseExact($start.Substring(0,14), "yyyyMMddHHmmss", $null)
        StopDate = [datetime]::ParseExact($stop.Substring(0,14), "yyyyMMddHHmmss", $null)
    }
}

# 3. CORRECCIÓN DE SOLAPAMIENTOS Y DUPLICADOS
Write-Host "3. Corrigiendo solapamientos y duplicados..." -ForegroundColor Yellow

$fixedPrograms = @()
$duplicatesRemoved = 0
$overlapsFixed = 0

foreach ($channel in $channelPrograms.Keys) {
    $programs = $channelPrograms[$channel] | Sort-Object StartDate
    
    # Eliminar duplicados exactos
    $uniquePrograms = @()
    $seenSlots = @{}
    
    foreach ($program in $programs) {
        $slotKey = "$($program.Start)-$($program.Stop)"
        if (-not $seenSlots.ContainsKey($slotKey)) {
            $seenSlots[$slotKey] = $true
            $uniquePrograms += $program
        } else {
            $duplicatesRemoved++
        }
    }
    
    # Corregir solapamientos
    $cleanPrograms = @()
    for ($i = 0; $i -lt $uniquePrograms.Count; $i++) {
        $currentProgram = $uniquePrograms[$i]
        
        # Verificar solapamiento con el siguiente programa
        if ($i -lt ($uniquePrograms.Count - 1)) {
            $nextProgram = $uniquePrograms[$i + 1]
            
            if ($currentProgram.StopDate -gt $nextProgram.StartDate) {
                # Ajustar fin del programa actual al inicio del siguiente
                $newStop = $nextProgram.StartDate.ToString("yyyyMMddHHmmss") + " +0000"
                $currentProgram.Full = $currentProgram.Full -replace 'stop="[^"]*"', "stop=`"$newStop`""
                $currentProgram.Stop = $newStop
                $overlapsFixed++
            }
        }
        
        $cleanPrograms += $currentProgram
    }
    
    $fixedPrograms += $cleanPrograms
}

Write-Host "   ✅ Duplicados eliminados: $duplicatesRemoved" -ForegroundColor Green
Write-Host "   ✅ Solapamientos corregidos: $overlapsFixed" -ForegroundColor Green

# 4. RECONSTRUCCIÓN DEL EPG
Write-Host "4. Reconstruyendo EPG..." -ForegroundColor Yellow

# Extraer header y canales del archivo original
$headerPattern = '(<\?xml[^>]*>.*?<tv[^>]*>.*?)(<programme|$)'
$headerMatch = [regex]::Match($content, $headerPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

$channelPattern = '<channel[^>]*>.*?</channel>'
$channelMatches = [regex]::Matches($content, $channelPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Construir nuevo EPG
$newContent = @()

# Header XML
if ($headerMatch.Success) {
    $newContent += $headerMatch.Groups[1].Value
}

# Canales
foreach ($channelMatch in $channelMatches) {
    $newContent += "  " + $channelMatch.Value
}

# Programas ordenados
$allPrograms = $fixedPrograms | Sort-Object StartDate
foreach ($program in $allPrograms) {
    $newContent += "  " + $program.Full
}

# Footer
$newContent += "</tv>"

# 5. GUARDAR ARCHIVO CORREGIDO
$finalContent = $newContent -join "`n"
$finalContent | Out-File -FilePath $OutputFile -Encoding UTF8

Write-Host "   ✅ EPG reconstruido y guardado" -ForegroundColor Green

# 6. VALIDACION FINAL
Write-Host ""
Write-Host "VALIDACION FINAL..." -ForegroundColor Green

try {
    [xml]$testXml = Get-Content $OutputFile -Raw
    Write-Host "   XML valido generado" -ForegroundColor Green
    
    $finalPrograms = $testXml.tv.programme.Count
    $finalChannels = $testXml.tv.channel.Count
    
    Write-Host ""
    Write-Host "ESTADISTICAS FINALES:" -ForegroundColor Cyan
    Write-Host "   Canales: $finalChannels" -ForegroundColor White
    Write-Host "   Programas: $finalPrograms" -ForegroundColor White
    Write-Host "   Duplicados eliminados: $duplicatesRemoved" -ForegroundColor Green
    Write-Host "   Solapamientos corregidos: $overlapsFixed" -ForegroundColor Green
    
} catch {
    Write-Host "   Error en XML final: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "CORRECCION COMPLETADA" -ForegroundColor Green
Write-Host "Archivo corregido: $OutputFile" -ForegroundColor Yellow
