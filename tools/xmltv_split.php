<?php
declare(strict_types=1);

if ($argc < 4) { fwrite(STDERR,"Uso: php {$argv[0]} input.xml[.gz] allowlist.txt output.xml\n"); exit(1); }
[$_, $IN, $ALLOW, $OUT] = $argv;

function loadXmltv(string $path): ?DOMXPath {
  $raw = file_get_contents($path);
  if ($raw === false) return null;
  if (str_ends_with(strtolower($path), '.gz')) { $raw = @gzdecode($raw); if ($raw === false) return null; }
  libxml_use_internal_errors(true);
  $dom = new DOMDocument('1.0','UTF-8'); $dom->preserveWhiteSpace=false; $dom->formatOutput=true;
  return $dom->loadXML($raw, LIBXML_NONET|LIBXML_NOERROR|LIBXML_NOWARNING) ? new DOMXPath($dom) : null;
}
function readAllow(string $file): array {
  $ids=[]; $names=[];
  foreach (file($file, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
    $s=trim($line); if ($s==='' || str_starts_with($s,'#')) continue;
    if (preg_match('/^[A-Za-z0-9_.:-]+$/u',$s)) $ids[$s]=true; else $names[mb_strtolower($s,'UTF-8')]=true;
  }
  return [$ids,$names];
}

$xp = loadXmltv($IN); if (!$xp) { fwrite(STDERR,"No pude leer XMLTV de $IN\n"); exit(2); }
$dom=$xp->document; [$allowIds,$allowNames]=readAllow($ALLOW);

$nameToId=[];
foreach ($xp->query('/tv/channel') as $c) {
  /** @var DOMElement $c */
  $id=$c->getAttribute('id');
  foreach ($xp->query('display-name',$c) as $dn) {
    $nm=mb_strtolower(trim($dn->textContent),'UTF-8'); if ($nm) $nameToId[$nm]=$id;
  }
}
foreach ($allowNames as $nm=>$_) if (isset($nameToId[$nm])) $allowIds[$nameToId[$nm]]=true;

$out=new DOMDocument('1.0','UTF-8'); $out->preserveWhiteSpace=false; $out->formatOutput=true;
$root=$out->createElement('tv'); $out->appendChild($root);

$keep=[];
foreach ($xp->query('/tv/channel') as $c) {
  $id=$c->getAttribute('id'); if (!isset($allowIds[$id])) continue;
  $keep[$id]=true; $root->appendChild($out->importNode($c,true));
}
$cnt=0;
foreach ($xp->query('/tv/programme') as $p) {
  $ch=$p->getAttribute('channel'); if (!isset($keep[$ch])) continue;
  $root->appendChild($out->importNode($p,true)); $cnt++;
}
file_put_contents($OUT,$out->saveXML());
echo "OK: ".count($keep)." canales, $cnt programas → $OUT\n";
