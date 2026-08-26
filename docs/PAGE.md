# Le texte de la page — version 2

Plus court, et sans emphase. Le français est la référence ; les quatre autres en
sont la traduction.

Chaque section : un titre, une ou deux phrases, une capture. Les quatre couleurs
de l'icône marquent les sections, dans leur ordre d'apparition dans l'icône.

---
---

# 🇫🇷 FRANÇAIS

# Spectre

### Une aide à l'écoute active de la musique.

Un spectrogramme qui donne à chaque note sa couleur, relève les accords et sépare
les quatre pistes.

**[ Télécharger pour macOS ]**
Libre et gratuit · macOS 15 ou plus récent · 104 Mo

---

## Tout le morceau dans une image  ·  *turquoise*

Le fichier est analysé une fois, à l'ouverture. Ensuite, zoomer ou défiler ne fait
que relire une matrice déjà en mémoire : n'importe quel instant est immédiat.

Chaque fréquence est recalée de son propre retard d'analyse, de sorte que les
graves ne traînent pas derrière la caisse claire.

> *capture : le morceau en un coup d'œil*

---

## Une couleur par note

Les douze teintes suivent le cycle des quintes : deux notes proches harmoniquement
sont proches en couleur. Elles ont toutes la même clarté, donc à niveau égal
aucune ne paraît plus forte qu'une autre.

> *capture : la musique en mode guitar hero*

---

## Détection automatique des accords  ·  *violet*

Les accords sont écrits sous l'image, mesure par mesure. Le curseur s'aimante sur
la raie la plus proche et donne la note, sa fréquence et son écart en cents.

Survoler un accord entoure ses notes dans l'image, à l'octave où elles sont
jouées.

> *captures : les voicings de chaque accord · voix, accords, batterie*

---

## Séparation des pistes  ·  *rose*

Basse, batterie, voix, reste — par le modèle open source **Demucs v4**, sur le GPU
de la machine, sans internet. Cinq minutes de musique en vingt-six secondes, en
tâche de fond.

Le spectrogramme est recalculé sur les pistes gardées : une basse seule n'a
presque plus de partielles qui se croisent, et le curseur tombe sur la bonne raie.
Retirer la voix donne un playback.

> *capture : choix des pistes*

---

## Ralentir, boucler, transposer  ·  *jaune*

Un glisser dans la réglette trace une boucle, calée sur la grille des mesures.

La vitesse et la hauteur se règlent séparément. Les valeurs intermédiaires de
hauteur recalent un enregistrement désaccordé.

> *capture : faire boucler une section au ralenti*

---

## N'entendre que ce qu'on regarde

La lecture est limitée à la portion du spectre visible : zoomer sur les graves
isole la basse. Cliquer dans l'image déplace la tête de lecture et fait sonner la
raie désignée.

---

## La batterie sur trois lignes  ·  *jaune*

Une fois séparée, la batterie quitte le spectrogramme et prend trois lignes en
dessous : grosse caisse, caisse claire, cymbales.

---

## Usages

- Relever un morceau à l'oreille
- Apprendre un solo au ralenti
- Se faire un playback
- Démêler un voicing de piano
- Vérifier un accord
- Travailler sur un enregistrement désaccordé

---

## Installer

**[ Télécharger pour macOS ]** · 104 Mo · macOS 15 ou plus récent

L'application n'est pas signée par un identifiant Apple : macOS la met en
quarantaine au téléchargement. Après l'avoir glissée dans `Applications` :

```
xattr -dr com.apple.quarantine /Applications/Spectre.app
```

Ou un clic droit sur l'application, « Ouvrir », et confirmer une fois. Le même
blocage frappe les fichiers audio téléchargés ; le message désigne alors le
fichier, ce qui est trompeur.

**Ou construire soi-même** — Xcode n'est pas nécessaire, l'application est dans
`build/Spectre.app` :

```
git clone https://github.com/gaspardlebasic/spectre.git
cd spectre && ./build.sh
```

---

## Autres plateformes

**Windows** — le portage est terminé : onze étapes sur onze. Il n'y a pas encore
de version publiée ; `build.ps1` fabrique l'application.

**Linux** — prévu après Windows.

---

## Pied de page

Logiciel libre · Code source sur GitHub · Séparation par Demucs v4 (Meta AI
Research)

---
---

# 🇬🇧 ENGLISH

# Spectre

### A tool for listening to music closely.

A spectrogram that gives every note its own colour, reads out the chords, and
separates the four stems.

**[ Download for macOS ]**
Free and open source · macOS 15 or later · 104 MB

*The interface is in French for now.*

---

## The whole track in one image  ·  *teal*

The file is analysed once, when it opens. After that, zooming or scrolling only
re-reads a matrix already in memory, so any point in the track is immediate.

Each frequency is shifted back by its own analysis delay, so the low end doesn't
lag behind the snare.

---

## One colour per note

The twelve hues follow the circle of fifths: notes that are close harmonically
are close in colour. They all share the same lightness, so at equal level none
looks louder than another.

---

## Automatic chord detection  ·  *purple*

Chords are written under the image, bar by bar. The cursor snaps to the nearest
partial and gives the note, its frequency and how far off it is in cents.

Hovering a chord rings its notes in the image, at the octave where they are
played.

---

## Stem separation  ·  *pink*

Bass, drums, vocals, other — using the open-source **Demucs v4** model, on the
machine's GPU, with no internet. Five minutes of audio in twenty-six seconds, in
the background.

The spectrogram is recomputed on whichever stems are kept: an isolated bass has
almost no crossing partials left, so the cursor lands on the right line. Drop the
vocal and you have a backing track.

---

## Slow down, loop, transpose  ·  *yellow*

Dragging in the ruler draws a loop, aligned to the bar grid.

Speed and pitch are set independently. Intermediate pitch values bring an
out-of-tune recording back to concert pitch.

---

## Hear only what you're looking at

Playback is limited to the visible part of the spectrum: zoom into the low end
and the bass is isolated. Clicking in the image moves the playhead and sounds the
line you clicked.

---

## Drums on three lines  ·  *yellow*

Once separated, the drums leave the spectrogram and take three lines below it:
kick, snare, cymbals.

---

## Uses

- Working a song out by ear
- Learning a solo slowly
- Making a backing track
- Untangling a piano voicing
- Checking a chord
- Working with an out-of-tune recording

---

## Install

**[ Download for macOS ]** · 104 MB · macOS 15 or later

The app is not signed with an Apple developer ID, so macOS quarantines it on
download. Once it is in `Applications`:

```
xattr -dr com.apple.quarantine /Applications/Spectre.app
```

Or right-click the app, choose "Open", and confirm once. The same block catches
downloaded audio files; the warning then names the audio file, which is
misleading.

**Or build it yourself** — Xcode is not required, the app lands in
`build/Spectre.app`:

```
git clone https://github.com/gaspardlebasic/spectre.git
cd spectre && ./build.sh
```

---

## Other platforms

**Windows** — the port is finished: eleven steps out of eleven. There is no
published build yet; `build.ps1` makes the app.

**Linux** — planned after Windows.

---

## Footer

Free software · Source on GitHub · Separation by Demucs v4 (Meta AI Research)

---
---

# 🇪🇸 ESPAÑOL

# Spectre

### Una ayuda para la escucha activa.

Un espectrograma que da a cada nota su color, detecta los acordes y separa las
cuatro pistas.

**[ Descargar para macOS ]**
Libre y gratuito · macOS 15 o posterior · 104 MB

*La interfaz está en francés por ahora.*

---

## Todo el tema en una imagen  ·  *turquesa*

El archivo se analiza una vez, al abrirlo. Después, hacer zoom o desplazarse solo
relee una matriz que ya está en memoria: cualquier punto del tema es inmediato.

Cada frecuencia se recoloca según su propio retardo de análisis, de modo que los
graves no van por detrás de la caja.

---

## Un color por nota

Los doce tonos siguen el círculo de quintas: dos notas cercanas armónicamente son
cercanas en color. Todas tienen la misma claridad, así que a igual nivel ninguna
parece más fuerte que otra.

---

## Detección automática de acordes  ·  *violeta*

Los acordes se escriben debajo de la imagen, compás a compás. El cursor se imanta
a la raya más cercana y da la nota, su frecuencia y su desviación en cents.

Al pasar por encima de un acorde se rodean sus notas en la imagen, en la octava
en que se tocan.

---

## Separación de pistas  ·  *rosa*

Bajo, batería, voz y resto — con el modelo de código abierto **Demucs v4**, en la
GPU del equipo y sin internet. Cinco minutos de audio en veintiséis segundos, en
segundo plano.

El espectrograma se recalcula sobre las pistas que se conservan: un bajo aislado
casi no tiene parciales que se crucen, y el cursor cae en la raya correcta. Al
quitar la voz queda una base instrumental.

---

## Ralentizar, hacer bucles, transponer  ·  *amarillo*

Arrastrar en la regla traza un bucle, ajustado a la cuadrícula de compases.

La velocidad y la afinación se ajustan por separado. Los valores intermedios de
afinación recolocan una grabación desafinada.

---

## Oír solo lo que se está mirando

La reproducción se limita a la parte visible del espectro: al ampliar los graves,
el bajo queda aislado. Al hacer clic en la imagen se mueve la cabeza de lectura y
suena la raya señalada.

---

## La batería en tres líneas  ·  *amarillo*

Una vez separada, la batería deja el espectrograma y ocupa tres líneas debajo:
bombo, caja, platos.

---

## Usos

- Sacar un tema de oído
- Aprender un solo despacio
- Hacerse una base instrumental
- Desenredar un voicing de piano
- Comprobar un acorde
- Trabajar con una grabación desafinada

---

## Instalar

**[ Descargar para macOS ]** · 104 MB · macOS 15 o posterior

La aplicación no está firmada con un identificador de desarrollador de Apple, así
que macOS la pone en cuarentena al descargarla. Una vez en `Aplicaciones`:

```
xattr -dr com.apple.quarantine /Applications/Spectre.app
```

O clic derecho sobre la aplicación, «Abrir», y confirmar una vez. El mismo bloqueo
alcanza a los archivos de audio descargados; el aviso señala entonces el archivo,
lo cual despista.

**O compilarla uno mismo** — no hace falta Xcode, la aplicación queda en
`build/Spectre.app`:

```
git clone https://github.com/gaspardlebasic/spectre.git
cd spectre && ./build.sh
```

---

## Otras plataformas

**Windows** — el port está terminado: once etapas de once. Aún no hay versión
publicada; `build.ps1` genera la aplicación.

**Linux** — previsto después de Windows.

---

## Pie

Software libre · Código en GitHub · Separación con Demucs v4 (Meta AI Research)

---
---

# 🇩🇪 DEUTSCH

# Spectre

### Eine Hilfe zum genauen Hören.

Ein Spektrogramm, das jedem Ton seine Farbe gibt, die Akkorde erkennt und die
vier Spuren trennt.

**[ Für macOS herunterladen ]**
Frei und quelloffen · macOS 15 oder neuer · 104 MB

*Die Oberfläche ist vorerst auf Französisch.*

---

## Das ganze Stück in einem Bild  ·  *Türkis*

Die Datei wird beim Öffnen einmal analysiert. Danach liest Zoomen oder Scrollen
nur eine Matrix, die bereits im Speicher liegt: Jede Stelle des Stücks ist sofort
da.

Jede Frequenz wird um ihre eigene Analyseverzögerung zurückgeschoben, sodass die
Bässe der Snare nicht hinterherhinken.

---

## Eine Farbe pro Ton

Die zwölf Farbtöne folgen dem Quintenzirkel: harmonisch benachbarte Töne sind
farblich benachbart. Alle haben dieselbe Helligkeit, also wirkt bei gleichem
Pegel kein Ton lauter als ein anderer.

---

## Automatische Akkorderkennung  ·  *Violett*

Die Akkorde stehen Takt für Takt unter dem Bild. Der Cursor rastet auf der
nächstgelegenen Linie ein und nennt den Ton, seine Frequenz und die Abweichung in
Cent.

Fährt man über einen Akkord, werden seine Töne im Bild eingekreist, in der
Oktave, in der sie gespielt werden.

---

## Spurtrennung  ·  *Pink*

Bass, Schlagzeug, Gesang, Rest — mit dem quelloffenen Modell **Demucs v4**, auf
der GPU des Rechners, ohne Internet. Fünf Minuten Audio in sechsundzwanzig
Sekunden, im Hintergrund.

Das Spektrogramm wird auf den behaltenen Spuren neu berechnet: Ein isolierter
Bass hat kaum noch sich kreuzende Teiltöne, und der Cursor trifft die richtige
Linie. Ohne Gesang bleibt ein Playback.

---

## Verlangsamen, loopen, transponieren  ·  *Gelb*

Ein Zug im Lineal zeichnet einen Loop, am Taktraster ausgerichtet.

Tempo und Tonhöhe werden getrennt eingestellt. Zwischenwerte der Tonhöhe rücken
eine verstimmte Aufnahme zurecht.

---

## Nur hören, was man ansieht

Die Wiedergabe ist auf den sichtbaren Teil des Spektrums begrenzt: Zoomt man in
die Tiefen, ist der Bass isoliert. Ein Klick ins Bild setzt den Abspielkopf und
lässt die angeklickte Linie klingen.

---

## Schlagzeug auf drei Linien  ·  *Gelb*

Einmal getrennt, verlässt das Schlagzeug das Spektrogramm und bekommt drei Linien
darunter: Bassdrum, Snare, Becken.

---

## Wofür

- Ein Stück nach Gehör heraushören
- Ein Solo langsam lernen
- Sich ein Playback bauen
- Ein Klavier-Voicing entwirren
- Einen Akkord überprüfen
- Mit einer verstimmten Aufnahme arbeiten

---

## Installieren

**[ Für macOS herunterladen ]** · 104 MB · macOS 15 oder neuer

Die App ist nicht mit einer Apple-Entwickler-ID signiert, deshalb stellt macOS sie
beim Herunterladen unter Quarantäne. Sobald sie in `Programme` liegt:

```
xattr -dr com.apple.quarantine /Applications/Spectre.app
```

Oder Rechtsklick auf die App, „Öffnen", und einmal bestätigen. Dieselbe Sperre
trifft heruntergeladene Audiodateien; die Meldung nennt dann die Audiodatei, was
in die Irre führt.

**Oder selbst bauen** — Xcode wird nicht gebraucht, die App liegt danach in
`build/Spectre.app`:

```
git clone https://github.com/gaspardlebasic/spectre.git
cd spectre && ./build.sh
```

---

## Andere Plattformen

**Windows** — die Portierung ist fertig: elf von elf Schritten. Es gibt noch keine
veröffentlichte Version; `build.ps1` baut die Anwendung.

**Linux** — nach Windows geplant.

---

## Fußzeile

Freie Software · Quellcode auf GitHub · Trennung mit Demucs v4 (Meta AI Research)

---
---

# 🇵🇱 POLSKI

# Spectre

### Pomoc w uważnym słuchaniu muzyki.

Spektrogram, który nadaje każdemu dźwiękowi kolor, rozpoznaje akordy i rozdziela
cztery ścieżki.

**[ Pobierz na macOS ]**
Wolne i otwarte · macOS 15 lub nowszy · 104 MB

*Interfejs jest na razie po francusku.*

---

## Cały utwór na jednym obrazie  ·  *turkus*

Plik jest analizowany raz, przy otwarciu. Potem powiększanie i przewijanie tylko
odczytuje macierz, która już jest w pamięci: każde miejsce utworu jest
natychmiast dostępne.

Każda częstotliwość jest cofnięta o własne opóźnienie analizy, więc dół nie
wlecze się za werblem.

---

## Jeden kolor na dźwięk

Dwanaście barw układa się według koła kwintowego: dźwięki bliskie harmonicznie są
bliskie kolorem. Wszystkie mają tę samą jasność, więc przy równym poziomie żaden
nie wygląda głośniej od innego.

---

## Automatyczne rozpoznawanie akordów  ·  *fiolet*

Akordy są wypisywane pod obrazem, takt po takcie. Kursor przyciąga się do
najbliższego prążka i podaje dźwięk, jego częstotliwość i odchylenie w centach.

Najechanie na akord obwodzi jego składniki na obrazie, w oktawie, w której są
grane.

---

## Rozdzielanie ścieżek  ·  *róż*

Bas, perkusja, wokal, reszta — modelem otwartoźródłowym **Demucs v4**, na GPU
komputera, bez internetu. Pięć minut nagrania w dwadzieścia sześć sekund, w tle.

Spektrogram jest przeliczany na zachowanych ścieżkach: wyizolowany bas prawie nie
ma krzyżujących się składowych, więc kursor trafia we właściwy prążek. Bez wokalu
zostaje podkład.

---

## Zwolnić, zapętlić, transponować  ·  *żółć*

Przeciągnięcie po linijce rysuje pętlę, dopasowaną do siatki taktów.

Tempo i wysokość ustawia się osobno. Pośrednie wartości wysokości prostują
rozstrojone nagranie.

---

## Słyszeć tylko to, na co się patrzy

Odtwarzanie jest ograniczone do widocznej części widma: powiększenie dołu izoluje
bas. Kliknięcie w obraz przesuwa głowicę i wybrzmiewa wskazanym prążkiem.

---

## Perkusja na trzech liniach  ·  *żółć*

Po rozdzieleniu perkusja opuszcza spektrogram i zajmuje trzy linie poniżej:
stopa, werbel, talerze.

---

## Zastosowania

- Wyciąganie utworu ze słuchu
- Nauka solówki na wolnych obrotach
- Zrobienie sobie podkładu
- Rozplątanie fortepianowego voicingu
- Sprawdzenie akordu
- Praca z rozstrojonym nagraniem

---

## Instalacja

**[ Pobierz na macOS ]** · 104 MB · macOS 15 lub nowszy

Aplikacja nie jest podpisana identyfikatorem dewelopera Apple, więc macOS poddaje
ją kwarantannie po pobraniu. Gdy znajdzie się w `Aplikacje`:

```
xattr -dr com.apple.quarantine /Applications/Spectre.app
```

Albo prawy przycisk na aplikacji, „Otwórz", i jedno potwierdzenie. Ta sama blokada
dotyka pobranych plików dźwiękowych; komunikat wskazuje wtedy plik audio, co
wprowadza w błąd.

**Albo zbudować samodzielnie** — Xcode nie jest potrzebny, aplikacja ląduje w
`build/Spectre.app`:

```
git clone https://github.com/gaspardlebasic/spectre.git
cd spectre && ./build.sh
```

---

## Inne platformy

**Windows** — port jest gotowy: jedenaście kroków z jedenastu. Nie ma jeszcze
opublikowanej wersji; `build.ps1` buduje aplikację.

**Linux** — planowany po Windows.

---

## Stopka

Wolne oprogramowanie · Kod na GitHubie · Rozdzielanie: Demucs v4 (Meta AI
Research)
