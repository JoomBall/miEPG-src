<?php
declare(strict_types=1);
/**
 * Uso: php filter_allowlist.php IN.xml allowlist.txt OUT.xml
 * Mantiene solo <channel>/<programme> de los canales cuyo display-name (y channel="@...") estén en allowlist.
 */
if ($argc < 4) {
    fwrite(STDERR, "Uso: php filter_allowlist.php IN.xml allowlist.txt OUT.xml\n");
    exit(1);
}
[$_, $in, $list, $out] = $argv;
if (!is_file($in))  { fwrite(STDERR, "No existe $in\n");  exit(2); }
if (!is_file($list)){ fwrite(STDERR, "No existe $list\n");exit(3); }

$allow = array_values(array_filter(array_map('trim', file($list) ?: []), fn($l)=>$l!==''));
$allowSet = array_fill_keys($allow, true);

libxml_use_internal_errors(true);
$dom = new DOMDocument('1.0', 'UTF-8');
$dom->preserveWhiteSpace = false;
$dom->formatOutput = true;
if (!$dom->load($in)) {
    fwrite(STDERR, "XML inválido en $in\n");
    exit(4);
}
$xp = new DOMXPath($dom);

// 1) Determinar IDs permitidos: usamos el <channel id="..."> y el <display-name> visible.
//    En tu pipeline, el atributo channel="@..." de <programme> coincide con el nombre final (p.ej. "Antena 3 HD").
//    Por tanto, construimos set de permitidos a partir del display-name.
$allowedIds = [];

// Recorre canales y guarda ID o display-name que coincida con la allowlist
foreach ($xp->query('/tv/channel') as $ch) {
    /** @var DOMElement $ch */
    $names = $xp->query('display-name', $ch);
    $ok = false;
    foreach ($names as $dn) {
        $name = trim($dn->textContent);
        if (isset($allowSet[$name])) { $ok = true; break; }
    }
    if ($ok) {
        // usa id si existe, pero tu flujo normalmente usa el nombre final como id
        $id = $ch->getAttribute('id') ?: ($names->length ? trim($names->item(0)->textContent) : '');
        if ($id !== '') $allowedIds[$id] = true;
        // también guarda cada display-name (por si channel="@display-name")
        foreach ($names as $dn) $allowedIds[trim($dn->textContent)] = true;
    }
}

// 2) Eliminar canales NO permitidos
foreach ($xp->query('/tv/channel') as $ch) {
    $names = $xp->query('display-name', $ch);
    $keep = false;
    foreach ($names as $dn) {
        if (isset($allowSet[trim($dn->textContent)])) { $keep = true; break; }
    }
    if (!$keep) $ch->parentNode->removeChild($ch);
}

// 3) Eliminar programmes cuyo @channel no esté en allowedIds
foreach ($xp->query('/tv/programme') as $p) {
    $chan = $p->getAttribute('channel');
    if ($chan === '' || !isset($allowedIds[$chan])) {
        $p->parentNode->removeChild($p);
    }
}

$dom->save($out) || exit(5);
