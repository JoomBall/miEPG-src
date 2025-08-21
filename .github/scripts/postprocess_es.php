<?php
declare(strict_types=1);

/**
 * postprocess_es.php IN OUT
 * - Añade UID estable por programa
 * - Limpia <desc>
 * - Extrae rating (TP/7/12/16/18), star-rating (x/10), año, país, créditos, icon
 * - Normaliza categoría a un conjunto genérico
 * Sin dependencias externas. PHP 8.1+
 */

if ($argc < 3) {
    fwrite(STDERR, "Uso: php postprocess_es.php <input.xml> <output.xml>\n");
    exit(1);
}

[$_, $in, $out] = $argv;
if (!is_file($in)) {
    fwrite(STDERR, "No existe $in\n");
    exit(2);
}

libxml_use_internal_errors(true);
$dom = new DOMDocument('1.0', 'UTF-8');
$dom->preserveWhiteSpace = false;
$dom->formatOutput = true;
if (!$dom->load($in)) {
    fwrite(STDERR, "XML inválido en $in\n");
    foreach (libxml_get_errors() as $err) fwrite(STDERR, $err->message);
    exit(3);
}
$xpath = new DOMXPath($dom);

function normalize(string $s): string {
    $s = trim(preg_replace('/\s+/u', ' ', $s) ?? '');
    return $s;
}

function mapCategory(string $raw): string {
    $raw = mb_strtolower($raw);
    $map = [
        'inform' => 'Información',
        'notic'  => 'Información',
        'magac'  => 'Entretenimiento',
        'entreten' => 'Entretenimiento',
        'concurso' => 'Entretenimiento',
        'serie'  => 'Series',
        'pelí'   => 'Películas',
        'cine'   => 'Películas',
        'deporte' => 'Deportes',
        'document' => 'Documentales',
        'infantil' => 'Infantil',
        'animación' => 'Infantil',
        'música' => 'Música',
        'cultura' => 'Cultura',
        'telerreal' => 'Telerrealidad',
        'tecnolog' => 'Tecnología'
    ];
    foreach ($map as $needle => $target) {
        if (str_contains($raw, $needle)) return $target;
    }
    return 'Otros';
}

function stableUid(string $channel, string $start, string $title): string {
    // UID estable (mismo input => mismo hash)
    $norm = mb_strtolower(normalize($channel.'|'.$start.'|'.$title));
    return substr(hash('sha1', $norm), 0, 16);
}

foreach ($xpath->query('/tv/programme') as $prog) {
    /** @var DOMElement $prog */

    $channel = $prog->getAttribute('channel');
    $start   = $prog->getAttribute('start');

    // Título
    $titleNode = $xpath->query('title', $prog)->item(0);
    $title = $titleNode?->textContent ?? '';

    // UID
    $uid = stableUid($channel, $start, $title);
    // Inserta episode-num system="jb_uid" (si no existe)
    if ($xpath->query('episode-num[@system="jb_uid"]', $prog)->length === 0) {
        $ep = $dom->createElement('episode-num', 'jb:ES:'.$uid);
        $ep->setAttribute('system','jb_uid');
        // Colocar tras <title>
        $ref = $xpath->query('sub-title', $prog)->item(0) ?: $xpath->query('title', $prog)->item(0);
        if ($ref && $ref->nextSibling) $prog->insertBefore($ep, $ref->nextSibling);
        else $prog->appendChild($ep);
    }

    // Desc original
    $descNode = $xpath->query('desc', $prog)->item(0);
    $desc = $descNode?->textContent ?? '';

    // Heurística: muchas fuentes meten en <desc> bloques tipo:
    // "Géneros | Año | TP | *6/10 · Sinopsis … · País: … · Presenta: … · Dirección: …"
    $lineas = array_map('normalize', preg_split('/\R/u', $desc));
    $lineas = array_values(array_filter($lineas, fn($l) => $l !== ''));

    $soloDesc = '';
    $rawHeader = $lineas[0] ?? '';
    $bullets = [];
    foreach ($lineas as $l) {
        if (mb_str_starts_with($l, '·')) $bullets[] = mb_substr($l, 1);
        else $soloDesc .= ($soloDesc ? ' ' : '') . $l;
    }

    // Extraer metadatos del "header" y bullets
    $rating = null;      // TP/7/12/16/18
    $stars  = null;      // 6/10
    $year   = null;
    $country= null;
    $icon   = null;

    // rating tipo " | TP " o " | +16 " en header
    if (preg_match('/\|\s*(TP|\+?\d{1,2})\b/u', $rawHeader, $m)) {
        $rating = str_replace('+','', $m[1]);
    }
    // estrellas tipo "*6.2/10"
    if (preg_match('/\*([\d.]+)\/10/u', $rawHeader, $m)) {
        $stars = $m[1] . '/10';
    }
    // año " | 2025 | "
    if (preg_match('/\|\s*(\d{4})\s*(\||$)/u', $rawHeader, $m)) {
        $year = $m[1];
    }

    // bullets
    $presenters = [];
    $directors  = [];
    $actors     = [];
    $composers  = [];
    foreach ($bullets as $b) {
        $b = normalize($b);
        if (preg_match('/^País:\s*(.+)$/u', $b, $m)) $country = $m[1];
        elseif (preg_match('/^Presenta:\s*(.+)$/u', $b, $m)) $presenters = array_map('trim', explode(',', $m[1]));
        elseif (preg_match('/^(Dirección|Director[a]?):\s*(.+)$/u', $b, $m)) $directors = array_map('trim', explode(',', $m[2]));
        elseif (preg_match('/^(Reparto|Actores?):\s*(.+)$/u', $b, $m)) $actors = array_map('trim', explode(',', $m[2]));
        elseif (preg_match('/^Música:\s*(.+)$/u', $b, $m)) $composers = array_map('trim', explode(',', $m[1]));
        elseif (preg_match('/^Icono?:\s*(https?:\/\/\S+)/u', $b, $m)) $icon = $m[1];
        // Ignora "Productora:" (XMLTV no tiene <production-company>)
    }

    // <desc> limpio: deja solo la sinopsis (sin cabecera ni bullets)
    if ($descNode) $descNode->nodeValue = $soloDesc ?: $desc;

    // <category> → toma la primera lista del header (antes de la primera "|")
    $catNode = $xpath->query('category', $prog)->item(0);
    $rawCats = $catNode?->textContent ?? '';
    $generic = mapCategory($rawCats ?: $rawHeader);
    if ($catNode) { $catNode->nodeValue = $generic; }
    else { $prog->appendChild($tmp = $dom->createElement('category', $generic)); $tmp->setAttribute('lang','es'); }

    // <date> (año)
    if ($year && $xpath->query('date', $prog)->length === 0) {
        $prog->appendChild($dom->createElement('date', $year));
    }

    // <country>
    if ($country && $xpath->query('country', $prog)->length === 0) {
        $prog->appendChild($dom->createElement('country', $country));
    }

    // <rating>
    if ($rating && $xpath->query('rating', $prog)->length === 0) {
        $r = $dom->createElement('rating');
        $r->setAttribute('system', 'ES');
        $r->appendChild($dom->createElement('value', $rating));
        $prog->appendChild($r);
    }

    // <star-rating>
    if ($stars && $xpath->query('star-rating', $prog)->length === 0) {
        $sr = $dom->createElement('star-rating');
        $sr->setAttribute('system', 'ES');
        $sr->appendChild($dom->createElement('value', $stars));
        $prog->appendChild($sr);
    }

    // <credits>
    if ($xpath->query('credits', $prog)->length === 0) {
        if ($presenters || $directors || $actors || $composers) {
            $cr = $dom->createElement('credits');
            foreach ($presenters as $p) $cr->appendChild($dom->createElement('presenter', $p));
            foreach ($directors  as $d) $cr->appendChild($dom->createElement('director',  $d));
            foreach ($actors     as $a) $cr->appendChild($dom->createElement('actor',     $a));
            foreach ($composers  as $c) $cr->appendChild($dom->createElement('composer',  $c));
            $prog->appendChild($cr);
        }
    }

    // <icon> (si no trae uno, usa el detectado)
    if ($icon && $xpath->query('icon', $prog)->length === 0) {
        $ic = $dom->createElement('icon');
        $ic->setAttribute('src', $icon);
        $prog->appendChild($ic);
    }
}

$dom->save($out) || exit(4);
