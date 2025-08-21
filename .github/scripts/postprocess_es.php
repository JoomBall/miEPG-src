<?php
declare(strict_types=1);

/**
 * postprocess_es.php IN [OUT]
 * - Si solo se pasa IN => postproceso in-place (IN.tmp.xml -> IN)
 * - Si se pasa OUT => escribe OUT
 * Sanea XML y aplica:
 *   * UID estable en <episode-num system="jb_uid">jb:ES:...</episode-num>
 *   * Limpieza <desc> (solo sinopsis); mueve metadatos a etiquetas XMLTV
 *   * Normaliza <category> a conjunto genérico
 * Sin mbstring. PHP 8.1+.
 */

if ($argc < 2) {
    fwrite(STDERR, "Uso: php postprocess_es.php <input.xml> [output.xml]\n");
    exit(1);
}

$in  = $argv[1];
$out = $argv[2] ?? ($in . '.tmp.xml');

if (!is_file($in)) { fwrite(STDERR, "No existe $in\n"); exit(2); }

ini_set('memory_limit', '1024M');
libxml_use_internal_errors(true);

function normalize(string $s): string {
    $s = preg_replace('/\s+/u', ' ', $s);
    return trim($s ?? '');
}
function mapCategory(string $raw): string {
    $raw = strtolower($raw);
    $map = [
        'inform' => 'Información', 'notic' => 'Información',
        'magac' => 'Entretenimiento', 'entreten' => 'Entretenimiento', 'concurso' => 'Entretenimiento',
        'serie' => 'Series',
        'pelí' => 'Películas', 'peli' => 'Películas', 'cine' => 'Películas',
        'deporte' => 'Deportes',
        'document' => 'Documentales',
        'infantil' => 'Infantil', 'animación' => 'Infantil',
        'musica' => 'Música', 'música' => 'Música',
        'cultura' => 'Cultura',
        'telerreal' => 'Telerrealidad',
        'tecnolog' => 'Tecnología'
    ];
    foreach ($map as $needle => $target) if (strpos($raw, $needle) !== false) return $target;
    return 'Otros';
}
function stableUid(string $channel, string $start, string $title): string {
    $norm = strtolower(normalize($channel.'|'.$start.'|'.$title));
    return substr(hash('sha1', $norm), 0, 16);
}

/* --- Saneado previo del XML --- */
$raw = file_get_contents($in);
if ($raw === false) { fwrite(STDERR, "No se pudo leer $in\n"); exit(2); }

$origBytes = strlen($raw);
$raw = preg_replace('/^\xEF\xBB\xBF/u', '', $raw); // BOM
$raw = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', '', $raw); // control chars
$raw = preg_replace('/<\?xml[^?]*\?>/i', '', $raw); // <?xml ...?>
$raw = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" . ltrim($raw);
$raw = preg_replace('/&(?!#\d+;|#x[0-9A-Fa-f]+;|[A-Za-z0-9]+;)/', '&amp;', $raw); // & sueltos

$sanBytes = strlen($raw);

$dom = new DOMDocument('1.0', 'UTF-8');
$dom->preserveWhiteSpace = false;
$dom->formatOutput = true;
if (!$dom->loadXML($raw, LIBXML_BIGLINES)) {
    fwrite(STDERR, "XML inválido tras saneado (bytes $origBytes->$sanBytes).\n");
    foreach (libxml_get_errors() as $err) fwrite(STDERR, trim($err->message)."\n");
    exit(3);
}

$xpath = new DOMXPath($dom);
$progs = $xpath->query('/tv/programme');
fwrite(STDERR, "Programmes cargados: " . $progs->length . PHP_EOL);

/* --- Transformaciones --- */
foreach ($progs as $prog) {
    /** @var DOMElement $prog */
    $channel = $prog->getAttribute('channel');
    $start   = $prog->getAttribute('start');
    $titleNode = $xpath->query('title', $prog)->item(0);
    $title = $titleNode?->textContent ?? '';

    // UID
    if ($xpath->query('episode-num[@system="jb_uid"]', $prog)->length === 0) {
        $uid = stableUid($channel, $start, $title);
        $ep = $dom->createElement('episode-num', 'jb:ES:'.$uid);
        $ep->setAttribute('system','jb_uid');
        $ref = $xpath->query('sub-title', $prog)->item(0) ?: $titleNode;
        if ($ref && $ref->nextSibling) $prog->insertBefore($ep, $ref->nextSibling);
        else $prog->appendChild($ep);
    }

    // Desc → solo sinopsis; extrae metadatos del “header” y bullets
    $descNode = $xpath->query('desc', $prog)->item(0);
    $desc = $descNode?->textContent ?? '';
    $lineas = array_values(array_filter(array_map('normalize', preg_split('/\R/u', $desc) ?: []), fn($l)=>$l!==''));
    $soloDesc = '';
    $rawHeader = $lineas[0] ?? '';
    $bullets = [];
    foreach ($lineas as $l) {
        if (preg_match('/^\s*·\s*/u', $l)) $bullets[] = preg_replace('/^\s*·\s*/u','', $l);
        else $soloDesc .= ($soloDesc ? ' ' : '') . $l;
    }

    $rating=null; $stars=null; $year=null; $country=null; $icon=null;
    if (preg_match('/\|\s*(TP|\+?\d{1,2})\b/u', $rawHeader, $m)) $rating = str_replace('+','', $m[1]);
    if (preg_match('/\*([\d.]+)\/10/u', $rawHeader, $m)) $stars = $m[1].'/10';
    if (preg_match('/\|\s*(\d{4})\s*(\||$)/u', $rawHeader, $m)) $year = $m[1];

    $presenters=[]; $directors=[]; $actors=[]; $composers=[];
    foreach ($bullets as $b) {
        $b = normalize($b);
        if     (preg_match('/^País:\s*(.+)$/u', $b, $m)) $country = $m[1];
        elseif (preg_match('/^Presenta:\s*(.+)$/u', $b, $m)) $presenters = array_map('trim', explode(',', $m[1]));
        elseif (preg_match('/^(Dirección|Director[a]?):\s*(.+)$/u', $b, $m)) $directors = array_map('trim', explode(',', $m[2]));
        elseif (preg_match('/^(Reparto|Actores?):\s*(.+)$/u', $b, $m)) $actors = array_map('trim', explode(',', $m[2]));
        elseif (preg_match('/^Música:\s*(.+)$/u', $b, $m)) $composers = array_map('trim', explode(',', $m[1]));
        elseif (preg_match('/^Icono?:\s*(https?:\/\/\S+)/u', $b, $m)) $icon = $m[1];
    }

    if ($descNode) $descNode->nodeValue = $soloDesc ?: $desc;

    $catNode = $xpath->query('category', $prog)->item(0);
    $rawCats = $catNode?->textContent ?? '';
    $generic = mapCategory($rawCats ?: $rawHeader);
    if ($catNode) { $catNode->nodeValue = $generic; }
    else { $tmp = $dom->createElement('category', $generic); $tmp->setAttribute('lang','es'); $prog->appendChild($tmp); }

    if ($year && $xpath->query('date', $prog)->length === 0) $prog->appendChild($dom->createElement('date', $year));
    if ($country && $xpath->query('country', $prog)->length === 0) $prog->appendChild($dom->createElement('country', $country));

    if ($rating && $xpath->query('rating', $prog)->length === 0) {
        $r = $dom->createElement('rating'); $r->setAttribute('system','ES');
        $r->appendChild($dom->createElement('value', $rating));
        $prog->appendChild($r);
    }
    if ($stars && $xpath->query('star-rating', $prog)->length === 0) {
        $sr = $dom->createElement('star-rating'); $sr->setAttribute('system','ES');
        $sr->appendChild($dom->createElement('value', $stars));
        $prog->appendChild($sr);
    }

    if ($xpath->query('credits', $prog)->length === 0) {
        if ($presenters || $directors || $actors || $composers) {
            $cr = $dom->createElement('credits');
            foreach ($presenters as $p) if ($p !== '') $cr->appendChild($dom->createElement('presenter', $p));
            foreach ($directors  as $d) if ($d !== '') $cr->appendChild($dom->createElement('director',  $d));
            foreach ($actors     as $a) if ($a !== '') $cr->appendChild($dom->createElement('actor',     $a));
            foreach ($composers  as $c) if ($c !== '') $cr->appendChild($dom->createElement('composer',  $c));
            if ($cr->hasChildNodes()) $prog->appendChild($cr);
        }
    }
    if ($icon && $xpath->query('icon', $prog)->length === 0) {
        $ic = $dom->createElement('icon'); $ic->setAttribute('src', $icon);
        $prog->appendChild($ic);
    }
}

if (!$dom->save($out)) exit(4);

// Si fue in-place (solo 1 arg), reemplazar el original
if ($argc === 2) {
    @rename($out, $in);
}
