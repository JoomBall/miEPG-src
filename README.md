# miEPG Multi-País v3.0

Este repositorio utiliza GitHub Actions para generar EPGs (Electronic Program Guide) independientes para múltiples países a partir de fuentes diversas.

## 🌍 **Países soportados:**

| País | Código | URL del EPG | Estado |
|------|--------|-------------|--------|
| 🇪🇸 España | `es` | `https://raw.githubusercontent.com/JoomBall/miEPG-src/main/countries/es/EPG.xml` | ✅ Activo |
| 🇬🇧 Reino Unido | `gb` | `https://raw.githubusercontent.com/JoomBall/miEPG-src/main/countries/gb/EPG.xml` | ✅ Activo |
| 🇺🇸 Estados Unidos | `us` | `https://raw.githubusercontent.com/JoomBall/miEPG-src/main/countries/us/EPG.xml` | 🚀 Nuevo |
| 🇦🇺 Australia | `au` | `https://raw.githubusercontent.com/JoomBall/miEPG-src/main/countries/au/EPG.xml` | 🚀 Nuevo |

## ⏰ **Programación:**
El script se ejecuta automáticamente todos los días a las **00:00 UTC** para todos los países en paralelo.

## 📁 **Estructura por país:**

Cada país tiene su propia carpeta bajo `countries/` con:
- `epgs.txt` - URLs de fuentes EPG
- `canales.txt` - Mapeo de canales 
- `allowlist.txt` - Filtros (actualmente deshabilitado)
- `EPG.xml` - EPG generado
- `channels.txt` - Lista de canales disponibles (para debug)

## 🔧 **Configuración:**

### **Modificar fuentes EPG:**
Edita el archivo `countries/{país}/epgs.txt` con las URLs de las EPGs de origen.

### **Mapear canales:**
Modifica el archivo `countries/{país}/canales.txt` con los canales deseados.

**Formato:** `NombreEPG,NombreFinal`
- **NombreEPG**: Nombre exacto del canal en la fuente EPG
- **NombreFinal**: Nombre que quieres mostrar en tu EPG

**Ejemplo:**
```
BBC ONE Lon,BBC One
CNN International,CNN
ESPN,ESPN
```

### **Prioridad de fuentes:**
Si se encuentran canales con el mismo nombre en distintas EPGs, solo se añadirá la primera coincidencia (la primera EPG tiene prioridad sobre las siguientes).

## 🚀 **Ventajas del sistema multi-país:**

✅ **Builds paralelos** - Todos los países se procesan simultáneamente
✅ **Resistente a fallos** - Si falla un país, los otros continúan  
✅ **Escalable** - Fácil añadir nuevos países
✅ **Independiente** - Cada país tiene sus propias fuentes y canales
✅ **Debug integrado** - Archivo `channels.txt` para verificar canales disponibles

## 📝 **Fuentes EPG utilizadas:**

### 🇪🇸 **España:**
- MovistarPlus EPG
- TDTChannels 
- PlutoTV España

### 🇬🇧 **Reino Unido:**
- PlutoTV UK
- Samsung TV Plus UK
- EPGShare UK
- BBC/ITV/Channel4 oficiales

### 🇺🇸 **Estados Unidos:**
- PlutoTV US
- Samsung TV Plus US
- PBS Network
- MeTV Network
- Roku Channels
- TV Guide

### 🇦🇺 **Australia:**
- Free-to-Air consolidado (ABC, Seven, Nine, Ten, SBS)
- Foxtel
- Samsung TV Plus AU
- PlutoTV Australia

### Creando un fork desde GitHub

Un fork es una copia de un repositorio de GitHub independiente del repositorio original. Nosotros somos los dueños de ese fork, por lo que podemos hacer todos los cambios que queramos, aunque no tengamos permisos de escritura en el repositorio original.

Crear un fork desde GitHub es muy sencillo. Ve a la página principal del repositorio del que quieras hacer un fork y pulsa el botón fork.

Una vez completado el fork, nos aparecerá en nuestra cuenta el repositorio "forkeado".

![alt text](https://raw.githubusercontent.com/davidmuma/miEPG/refs/heads/main/.github/workflows/fork1.png)

### Habilitar GitHub Actions en tu fork

1. Habilita GitHub Actions en tu fork:

  - Una vez que hayas creado el fork, ve a la pestaña "Actions" en tu repositorio en GitHub.

  - Verás un mensaje que dice: "Workflows aren’t being run on this forked repository". Esto es normal, ya que GitHub deshabilita por defecto los workflows en los nuevos forks por motivos de seguridad.

  - Haz clic en el botón "I understand my workflows, go ahead and enable them" para habilitar los workflows en tu fork.

2. Verifica la configuración:

  - Realiza un cambio en algún archivo del proyecto (por ejemplo, edita un archivo .md) en una rama distinta de master y súbelo a tu fork.

  - Abre una pull request desde nueva rama hacia master en tu fork.

  - Ve a la pestaña "Actions" y verifica que los tests se están ejecutando correctamente en base a los workflows definidos en la carpeta .github/workflows/ del proyecto.


