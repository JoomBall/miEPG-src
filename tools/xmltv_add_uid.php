<?php
declare(strict_types=1);

if ($argc < 3) { fwrite(STDERR, "Uso: php {$argv[0]} input.xml[.gz] output.xml\n"); exit(1); }
[$_, $IN, $OUT] = $argv;

function loadXml(string $path): ?DOMDocument {
  $raw = file_get_contents($path);
  if ($raw === false) return null;
  if (str_ends_with(strtolower($path), '.gz')) { $raw = @gzdecode($raw); if ($raw === false) return null; }
  libxml_use_internal_errors(true);
  $dom = new DOMDocument('1.0','UTF-8'); $dom->preserveWhiteSpace=false; $dom->formatOutput=true;
  return $dom->loadXML($raw, LIBXML_NONET|LIBXML_NOERROR|LIBXML_NOWARNING) ? $dom : null;
}

$dom = loadXml($IN); if (!$dom) { fwrite(STDERR,"No pude leer XML de $IN\n"); exit(2); }
$xp  = new DOMXPath($dom);

$tv = $dom->getElementsByTagName('tv')->item(0);
if (!$tv) { fwrite(STDERR,"XMLTV inválido: falta <tv>\n"); exit(3); }
if (!$tv->hasAttribute('xmlns:ext')) $tv->setAttribute('xmlns:ext','urn:milcontratos:xmltv-ext:1');

foreach ($xp->query('/tv/programme') as $p) {
  /** @var DOMElement $p */
  if ($xp->query('ext:uid', $p)->length) continue;
  $channel = $p->getAttribute('channel') ?: '';
  $start   = $p->getAttribute('start') ?: '';
  $stop    = $p->getAttribute('stop') ?: '';
  $slug = preg_replace('~[^a-z0-9]+~i','-',$channel); $slug = trim((string)$slug,'-');
  $uidReadable = strtolower($slug.'-'.$start);
  $uidHash = substr(sha1($channel.'|'.$start.'|'.$stop), 0, 12);
  $uid = $uidReadable.'-'.$uidHash;
  $p->appendChild($dom->createElement('ext:uid', $uid));
}

file_put_contents($OUT, $dom->saveXML());
echo "OK UID → $OUT\n";
