# Script de análisis y corrección EPG
$epgFile = "EPG.xml"

if (Test-Path $epgFile) {
    echo "=== ANÁLISIS DE PROBLEMAS EPG ==="
    
    # 1. Buscar elementos XML inválidos
    echo "1. Buscando elementos XML inválidos..."
    $invalidElements = Select-String -Path $epgFile -Pattern "<[0-9]|<[^a-zA-Z!?/]" 
    if ($invalidElements) {
        echo "     Elementos inválidos encontrados: $($invalidElements.Count)"
        $invalidElements | Select-Object -First 3 | ForEach-Object {
            echo "   Línea $($_.LineNumber): $($_.Line.Trim())"
        }
    } else {
        echo "    No se encontraron elementos XML inválidos"
    }
    
    # 2. Verificar programas duplicados
    echo ""
    echo "2. Analizando duplicados por canal..."
    $content = Get-Content $epgFile -Raw
    $programMatches = [regex]::Matches($content, '<programme start="([^"]*)" stop="([^"]*)" channel="([^"]*)">')
    
    $duplicates = @{}
    foreach ($match in $programMatches) {
        $key = "$($match.Groups[3].Value)|$($match.Groups[1].Value)|$($match.Groups[2].Value)"
        if ($duplicates.ContainsKey($key)) {
            $duplicates[$key]++
        } else {
            $duplicates[$key] = 1
        }
    }
    
    $duplicateEntries = $duplicates.GetEnumerator() | Where-Object { $_.Value -gt 1 }
    if ($duplicateEntries) {
        echo "     Programas duplicados: $($duplicateEntries.Count)"
        $duplicateEntries | Select-Object -First 3 | ForEach-Object {
            $parts = $_.Key -split '\|'
            echo "   Canal: $($parts[0]) | $($parts[1])-$($parts[2]) | $($_.Value) veces"
        }
    } else {
        echo "    No se encontraron duplicados exactos"
    }
    
    # 3. Verificar consistencia de horarios
    echo ""
    echo "3. Verificando consistencia de horarios..."
    $inconsistentCount = 0
    foreach ($match in ($programMatches | Select-Object -First 100)) {
        $start = $match.Groups[1].Value
        $stop = $match.Groups[2].Value
        if ($start -ge $stop) {
            $inconsistentCount++
        }
    }
    
    if ($inconsistentCount -gt 0) {
        echo "     Horarios inconsistentes: $inconsistentCount en muestra de 100"
    } else {
        echo "    Horarios consistentes en muestra analizada"
    }
    
} else {
    echo "EPG.xml no encontrado"
}
