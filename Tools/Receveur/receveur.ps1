# Le jumeau Windows de `receveur.py`, et pour la même raison exactement.
#
# `RapportsCheck` remplace le réseau par une fonction dans tous ses autres contrôles,
# ce qui le rend portable et sans effet de bord. Mais **un code qui n'a jamais posté
# ne poste peut-être pas** : `URLSession` vient de Foundation sur le Mac et d'un
# module à part sous Windows, où elle traîne une bibliothèque de plus qu'il faut
# empaqueter. C'est précisément le genre de manque que la v0.4 a fait payer.
#
# Pourquoi une prise TCP nue plutôt que `HttpListener`, qui parlerait HTTP tout seul :
# celui-ci exige une réservation d'espace de noms — `netsh http add urlacl` — sous
# peine de refuser d'écouter hors d'une session administrateur. Un harnais qui
# demande les droits d'administrateur est un harnais qu'on finit par sauter. Trente
# lignes de HTTP écrites à la main coûtent moins cher que cela.
#
# Le port est celui que le système donne : un port écrit en dur finirait par tomber
# sur celui de quelqu'un d'autre, un jour, sur une machine qu'on ne verra pas.
param([Parameter(Mandatory = $true)][string]$Dossier)

New-Item -ItemType Directory -Force -Path $Dossier | Out-Null
$service = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$service.Start()
Set-Content -Path (Join-Path $Dossier "port") -Value $service.LocalEndpoint.Port -NoNewline

while ($true) {
    $client = $service.AcceptTcpClient()
    $flux = $client.GetStream()

    # On lit **des octets** et non des caractères : la longueur annoncée est celle des
    # octets, et un message accentué — c'est-à-dire tous les nôtres — décalerait le
    # compte si on le lisait en texte.
    $tampon = New-Object byte[] 65536
    $recu = New-Object System.IO.MemoryStream
    $finDesEntetes = -1
    while ($finDesEntetes -lt 0) {
        $lu = $flux.Read($tampon, 0, $tampon.Length)
        if ($lu -le 0) { break }
        $recu.Write($tampon, 0, $lu)
        $tout = $recu.ToArray()
        for ($i = 0; $i -lt $tout.Length - 3; $i++) {
            if ($tout[$i] -eq 13 -and $tout[$i+1] -eq 10 -and
                $tout[$i+2] -eq 13 -and $tout[$i+3] -eq 10) { $finDesEntetes = $i + 4; break }
        }
    }
    if ($finDesEntetes -ge 0) {
        $tout = $recu.ToArray()
        $entetes = [Text.Encoding]::ASCII.GetString($tout, 0, $finDesEntetes)
        $taille = 0
        if ($entetes -match '(?im)^content-length:\s*(\d+)') { $taille = [int]$Matches[1] }
        while ($recu.Length - $finDesEntetes -lt $taille) {
            $lu = $flux.Read($tampon, 0, $tampon.Length)
            if ($lu -le 0) { break }
            $recu.Write($tampon, 0, $lu)
        }
        $tout = $recu.ToArray()
        $corps = New-Object byte[] ($tout.Length - $finDesEntetes)
        [Array]::Copy($tout, $finDesEntetes, $corps, 0, $corps.Length)
        [IO.File]::WriteAllBytes((Join-Path $Dossier "recu.txt"), $corps)
        Set-Content -Path (Join-Path $Dossier "entetes.txt") -Value $entetes
    }

    $reponse = [Text.Encoding]::ASCII.GetBytes(
        "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: 2`r`n" +
        "Connection: close`r`n`r`n{}")
    $flux.Write($reponse, 0, $reponse.Length)
    $flux.Flush()
    $client.Close()
}
