# Mejora del script EPG para evitar duplicados y solapamientos
# Se añade al EPG_script.sh existente

enhance_epg_quality() {
    local epg_file="$1"
    local temp_file="${epg_file}.tmp"
    local cleaned_file="${epg_file}.cleaned"
    
    echo "🔧 Mejorando calidad EPG: $epg_file"
    
    # 1. ELIMINAR PROGRAMAS DUPLICADOS POR CANAL Y HORARIO
    echo "   - Eliminando duplicados..."
    
    # Extraer header
    sed -n '1,/<programme/p' "$epg_file" | sed '$d' > "$temp_file"
    
    # Procesar programas únicos
    grep '<programme' "$epg_file" | \
    awk '
    BEGIN { 
        RS="</programme>"
        FS="<programme"
    }
    {
        if (NF > 1) {
            # Extraer canal, inicio y fin
            match($2, /channel="([^"]*)"/, channel_arr)
            match($2, /start="([^"]*)"/, start_arr)
            match($2, /stop="([^"]*)"/, stop_arr)
            
            channel = channel_arr[1]
            start = start_arr[1]
            stop = stop_arr[1]
            
            # Crear clave única
            key = channel "|" start "|" stop
            
            # Solo mantener el primer programa para cada clave
            if (!(key in seen)) {
                seen[key] = 1
                print "<programme" $2 "</programme>"
            }
        }
    }' >> "$temp_file"
    
    # Añadir footer
    echo "</tv>" >> "$temp_file"
    
    # 2. ORDENAR PROGRAMAS POR CANAL Y HORARIO
    echo "   - Ordenando programas..."
    python3 -c "
import xml.etree.ElementTree as ET
import sys

try:
    tree = ET.parse('$temp_file')
    root = tree.getroot()
    
    # Agrupar programas por canal
    channels = {}
    for prog in root.findall('programme'):
        channel = prog.get('channel', '')
        if channel not in channels:
            channels[channel] = []
        channels[channel].append(prog)
    
    # Eliminar todos los programas del XML
    for prog in root.findall('programme'):
        root.remove(prog)
    
    # Reordenar programas por canal y horario
    for channel in sorted(channels.keys()):
        programs = channels[channel]
        # Ordenar por horario de inicio
        programs.sort(key=lambda x: x.get('start', ''))
        
        # Añadir programas ordenados de vuelta al XML
        for prog in programs:
            root.append(prog)
    
    # Guardar XML ordenado
    tree.write('$cleaned_file', encoding='utf-8', xml_declaration=True)
    print('✅ EPG procesado correctamente')
    
except Exception as e:
    print(f'❌ Error procesando EPG: {e}')
    sys.exit(1)
"
    
    # 3. REEMPLAZAR ARCHIVO ORIGINAL
    if [ -f "$cleaned_file" ]; then
        mv "$cleaned_file" "$epg_file"
        echo "   ✅ EPG optimizado guardado"
    else
        echo "   ⚠️  Manteniendo EPG original"
    fi
    
    # Limpiar archivos temporales
    rm -f "$temp_file" "$cleaned_file"
}

# Función para validar horarios
validate_program_schedules() {
    local epg_file="$1"
    
    echo "🔍 Validando horarios en: $epg_file"
    
    python3 -c "
import xml.etree.ElementTree as ET
from datetime import datetime

try:
    tree = ET.parse('$epg_file')
    root = tree.getroot()
    
    # Agrupar por canal
    channels = {}
    for prog in root.findall('programme'):
        channel = prog.get('channel', '')
        start = prog.get('start', '')
        stop = prog.get('stop', '')
        
        if channel not in channels:
            channels[channel] = []
        channels[channel].append((start, stop, prog))
    
    total_issues = 0
    
    for channel, programs in channels.items():
        programs.sort(key=lambda x: x[0])  # Ordenar por inicio
        
        issues = 0
        for i in range(len(programs) - 1):
            current_stop = programs[i][1][:14]  # Solo fecha/hora
            next_start = programs[i+1][0][:14]
            
            # Verificar solapamiento
            if current_stop > next_start:
                issues += 1
                total_issues += 1
        
        if issues > 0:
            print(f'   ⚠️  Canal {channel}: {issues} solapamientos')
        else:
            print(f'   ✅ Canal {channel}: Sin solapamientos')
    
    if total_issues == 0:
        print('✅ Todos los horarios son consistentes')
    else:
        print(f'⚠️  Total de problemas encontrados: {total_issues}')
        
except Exception as e:
    print(f'❌ Error validando horarios: {e}')
"
}
