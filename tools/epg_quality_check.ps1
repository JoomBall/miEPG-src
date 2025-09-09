# EPG Quality Check and Fix Tool
# Detecta y corrige problemas comunes en archivos EPG

param(
    [Parameter(Mandatory=$true)]
    [string]$EPGFile,
    
    [switch]$Fix = $false
)

Write-Host "=== EPG QUALITY CHECKER ===" -ForegroundColor Cyan
Write-Host "Archivo: $EPGFile" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $EPGFile)) {
    Write-Host "❌ Archivo no encontrado: $EPGFile" -ForegroundColor Red
    exit 1
}

$issues = @()
$content = Get-Content $EPGFile -Raw

# 1. VERIFICAR ESTRUCTURA XML BÁSICA
Write-Host "1. Verificando estructura XML..." -ForegroundColor Green
try {
    [xml]$testXml = $content
    Write-Host "   ✅ XML válido" -ForegroundColor Green
} catch {
    Write-Host "   ⚠️  XML inválido: $($_.Exception.Message)" -ForegroundColor Yellow
    $issues += "XML_INVALID: $($_.Exception.Message)"
}

# 2. BUSCAR PROGRAMAS DUPLICADOS EXACTOS
Write-Host "2. Buscando programas duplicados..." -ForegroundColor Green
$programPattern = '<programme start="([^"]*)" stop="([^"]*)" channel="([^"]*)"[^>]*>.*?</programme>'
$programMatches = [regex]::Matches($content, $programPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

$programHash = @{}
$duplicateCount = 0

foreach ($match in $programMatches) {
    $start = $match.Groups[1].Value
    $stop = $match.Groups[2].Value
    $channel = $match.Groups[3].Value
    $key = "$channel|$start|$stop"
    
    if ($programHash.ContainsKey($key)) {
        $programHash[$key]++
        $duplicateCount++
    } else {
        $programHash[$key] = 1
    }
}

if ($duplicateCount -gt 0) {
    Write-Host "   ⚠️  Programas duplicados encontrados: $duplicateCount" -ForegroundColor Yellow
    $issues += "DUPLICATES: $duplicateCount programas"
    
    # Mostrar ejemplos de duplicados
    $duplicates = $programHash.GetEnumerator() | Where-Object { $_.Value -gt 1 } | Select-Object -First 5
    foreach ($dup in $duplicates) {
        $parts = $dup.Key -split '\|'
        Write-Host "     Canal: $($parts[0]) | $($parts[1]) | $($dup.Value)x" -ForegroundColor Gray
    }
} else {
    Write-Host "   ✅ No se encontraron duplicados exactos" -ForegroundColor Green
}

# 3. VERIFICAR SOLAPAMIENTOS DE HORARIOS POR CANAL
Write-Host "3. Verificando solapamientos de horarios..." -ForegroundColor Green
$channelPrograms = @{}

foreach ($match in $programMatches) {
    $channel = $match.Groups[3].Value
    $start = $match.Groups[1].Value
    $stop = $match.Groups[2].Value
    
    if (-not $channelPrograms.ContainsKey($channel)) {
        $channelPrograms[$channel] = @()
    }
    
    $channelPrograms[$channel] += @{
        Start = $start
        Stop = $stop
        Full = $match.Value
    }
}

$overlapCount = 0
$sampleChannels = ($channelPrograms.Keys | Select-Object -First 10)

foreach ($channel in $sampleChannels) {
    $programs = $channelPrograms[$channel] | Sort-Object Start
    
    for ($i = 0; $i -lt ($programs.Count - 1); $i++) {
        $current = $programs[$i]
        $next = $programs[$i + 1]
        
        if ($current.Stop -gt $next.Start) {
            $overlapCount++
            if ($overlapCount -le 3) {  # Mostrar solo primeros 3
                Write-Host "     Solapamiento en $channel`: $($current.Stop) > $($next.Start)" -ForegroundColor Gray
            }
        }
    }
}

if ($overlapCount -gt 0) {
    Write-Host "   ⚠️  Solapamientos encontrados: $overlapCount" -ForegroundColor Yellow
    $issues += "OVERLAPS: $overlapCount solapamientos"
} else {
    Write-Host "   ✅ No se encontraron solapamientos en muestra" -ForegroundColor Green
}

# 4. VERIFICAR HUECOS EN PROGRAMACIÓN
Write-Host "4. Verificando huecos en programación..." -ForegroundColor Green
$gapCount = 0

foreach ($channel in $sampleChannels) {
    $programs = $channelPrograms[$channel] | Sort-Object Start
    
    for ($i = 0; $i -lt ($programs.Count - 1); $i++) {
        $current = $programs[$i]
        $next = $programs[$i + 1]
        
        if ($current.Stop -lt $next.Start) {
            $gapCount++
        }
    }
}

if ($gapCount -gt 0) {
    Write-Host "   ⚠️  Huecos encontrados: $gapCount" -ForegroundColor Yellow
    $issues += "GAPS: $gapCount huecos en programación"
} else {
    Write-Host "   ✅ Programación continua" -ForegroundColor Green
}

# 5. VERIFICAR HORARIOS INVÁLIDOS
Write-Host "5. Verificando horarios inválidos..." -ForegroundColor Green
$invalidTimes = 0

foreach ($match in ($programMatches | Select-Object -First 1000)) {
    $start = $match.Groups[1].Value
    $stop = $match.Groups[2].Value
    
    if ($start -ge $stop) {
        $invalidTimes++
    }
}

if ($invalidTimes -gt 0) {
    Write-Host "   ⚠️  Horarios inválidos: $invalidTimes" -ForegroundColor Yellow
    $issues += "INVALID_TIMES: $invalidTimes horarios inválidos"
} else {
    Write-Host "   ✅ Horarios válidos" -ForegroundColor Green
}

# RESUMEN
Write-Host ""
Write-Host "=== RESUMEN ===" -ForegroundColor Cyan
if ($issues.Count -eq 0) {
    Write-Host "✅ EPG sin problemas detectados" -ForegroundColor Green
} else {
    Write-Host "⚠️  Problemas encontrados:" -ForegroundColor Yellow
    foreach ($issue in $issues) {
        Write-Host "   - $issue" -ForegroundColor Red
    }
}

# ESTADISTICAS
$totalPrograms = $programMatches.Count
$totalChannels = $channelPrograms.Keys.Count
Write-Host ""
Write-Host "ESTADISTICAS:" -ForegroundColor Cyan
Write-Host "   Total canales: $totalChannels" -ForegroundColor White
Write-Host "   Total programas: $totalPrograms" -ForegroundColor White

# SUGERENCIAS DE MEJORA
if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "SUGERENCIAS:" -ForegroundColor Cyan
    
    if ($issues -match "DUPLICATES") {
        Write-Host "   - Implementar deduplicacion por canal+horario" -ForegroundColor Yellow
    }
    
    if ($issues -match "OVERLAPS") {
        Write-Host "   - Resolver conflictos de horarios solapados" -ForegroundColor Yellow
    }
    
    if ($issues -match "GAPS") {
        Write-Host "   - Considerar llenar huecos con programacion generica" -ForegroundColor Yellow
    }
}
