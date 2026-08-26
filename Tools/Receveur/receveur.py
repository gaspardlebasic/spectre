#!/usr/bin/env python3
"""Un service de rapports, le temps d'une vérification.

Il n'existe que pour une raison : `RapportsCheck` remplace le réseau par une
fonction dans tous ses autres contrôles — ce qui est ce qu'on veut, puisque cela
le rend portable et sans effet de bord — mais **un code qui n'a jamais posté ne
poste peut-être pas**. C'est la leçon de `docs/PAQUETS.md`, appliquée à une pile
réseau au lieu d'un paquet : `URLSession` vient de Foundation sur le Mac et d'un
module à part sous Linux et Windows, où elle traîne une bibliothèque de plus.

Il écoute sur la boucle locale, sur un port que le système choisit — un port
écrit en dur finirait par tomber sur celui de quelqu'un d'autre — et écrit ce
qu'il reçoit dans un fichier, pour que l'appelant puisse le relire.
"""
import http.server
import pathlib
import socketserver
import sys

dossier = pathlib.Path(sys.argv[1])
dossier.mkdir(parents=True, exist_ok=True)


class Receveur(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        taille = int(self.headers.get("content-length", 0))
        (dossier / "recu.txt").write_bytes(self.rfile.read(taille))
        (dossier / "entetes.txt").write_text(str(self.headers))
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *arguments):
        pass


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 0), Receveur) as service:
    (dossier / "port").write_text(str(service.server_address[1]))
    service.serve_forever()
