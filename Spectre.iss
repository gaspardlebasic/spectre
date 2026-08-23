; L'installeur Windows de Spectre.
;
; Ne se compile pas à la main : `.\paquet.ps1` s'en charge, et lui passe les quatre
; définitions ci-dessous. Voir ce script pour ce qu'il fabrique avant d'appeler le
; compilateur — notamment `build\formats.iss`, qui est engendré.
;
; ─────────────────────────────────────────────────────────────────────────────
; POURQUOI UN INSTALLEUR, PUISQU'IL SUFFIT DE COPIER UN DOSSIER
;
; `build.ps1` produit un dossier qui se suffit à lui-même, et une archive de ce
; dossier est une distribution valable — c'est celle qu'on donne à qui veut essayer
; sans rien inscrire nulle part. Ce qu'elle ne peut pas faire, c'est **se faire
; connaître de Windows** :
;
;   - un raccourci au menu Démarrer, et donc une application qui se trouve en
;     tapant son nom ;
;   - une entrée dans « Applications installées », et donc une désinstallation ;
;   - une icône et un nom sur les fichiers audio, et un double-clic qui les ouvre.
;
; Rien de tout cela n'est un fichier : ce sont des inscriptions dans la base de
; registres, et il faut quelqu'un pour les poser et pour les retirer. C'est le
; travail de ce fichier.
;
; ─────────────────────────────────────────────────────────────────────────────
; CE QUE WINDOWS NE LAISSE PLUS FAIRE À UN INSTALLEUR
;
; Depuis Windows 8, **aucun programme d'installation ne peut décider seul quelle
; application ouvre les `.mp3`**. Le choix de l'utilisateur est scellé dans une clé
; `UserChoice` que le système signe : l'écraser ne marche pas, et les quelques
; méthodes qui y parviennent encore sont exactement ce que Microsoft appelle un
; détournement. Un installeur qui promet « Spectre ouvrira vos fichiers audio » ment
; donc à moitié, et l'utilisateur constate ensuite que rien n'a changé.
;
; Ce fichier fait les trois choses qui, elles, marchent :
;
; 1. **Toujours** : le type de fichier `Spectre.Audio` est déclaré, et ajouté à la
;    liste `OpenWithProgids` de chaque extension. Spectre apparaît alors dans
;    « Ouvrir avec », avec son icône et son nom — sans rien enlever à personne.
; 2. **Toujours** : les `Capabilities` et `RegisteredApplications`, qui font
;    apparaître Spectre dans Paramètres → Applications par défaut. C'est le seul
;    endroit d'où le choix peut réellement se faire.
; 3. **Si la case est cochée** : l'association classique, sous `HKEY_CURRENT_USER`.
;    Elle prend effet là où l'utilisateur n'avait encore rien choisi — une extension
;    que rien ne réclamait, une installation neuve — et reste sans effet ailleurs.
;    La case ouvre ensuite les réglages de Windows sur la page de Spectre, pour que
;    le reste se fasse là où il doit se faire.
;
; **L'association ne s'écrit que dans `HKEY_CURRENT_USER`**, y compris quand
; l'installation est faite pour toute la machine. Poser un défaut dans
; `HKEY_LOCAL_MACHINE` écraserait celui du système, et la désinstallation ne le
; rendrait pas : on effacerait le lecteur audio de quelqu'un d'autre en s'en allant.
; Le reste — le type de fichier, les capacités — suit le mode d'installation.
;
; `mp4` est dans « Ouvrir avec » et hors de la case. Media Foundation sait en tirer
; le son, et Spectre l'ouvre donc volontiers ; mais c'est d'abord un conteneur
; vidéo, et une case qui dit « fichiers audio » n'a pas à emporter la vidéothèque
; de qui la coche. Voir `paquet.ps1`, qui fait le partage.
; ─────────────────────────────────────────────────────────────────────────────

#define Application "Spectre"
#define Executable "Spectre.exe"
#define ProgId "Spectre.Audio"
#define Adresse "https://github.com/gaspardlebasic/spectre"

#ifndef Version
  #define Version "1.0.0"
#endif
#ifndef Source
  #define Source "build\Spectre"
#endif
#ifndef Sortie
  #define Sortie "build"
#endif
#ifndef Arch
  #define Arch "x64"
#endif

; `x64os` et non `x64compatible` : le second accepterait une machine ARM qui ferait
; tourner l'exécutable en émulation, ce dont personne ne veut pour une application
; qui passe son temps dans la FFT et sur la carte graphique. Chaque architecture a
; son installeur, et refuse l'autre.
#if Arch == "arm64"
  #define Architectures "arm64"
#else
  #define Architectures "x64os"
#endif

[Setup]
; Cet identifiant est ce qui rattache une mise à jour à l'installation qu'elle
; remplace. **Il ne change jamais** : le changer ferait cohabiter deux Spectre dans
; « Applications installées », dont un que plus rien ne désinstalle.
AppId={{4497BF08-4CE9-49C4-A514-4E57489210BF}
AppName={#Application}
AppVersion={#Version}
AppVerName={#Application} {#Version}
AppPublisherURL={#Adresse}
AppSupportURL={#Adresse}
AppUpdatesURL={#Adresse}/releases
VersionInfoVersion={#Version}

DefaultDirName={autopf}\{#Application}
DefaultGroupName={#Application}
DisableProgramGroupPage=yes
AllowNoIcons=yes
UninstallDisplayIcon={app}\{#Executable}
UninstallDisplayName={#Application}

; Sans droits d'administrateur par défaut : l'application s'installe alors dans le
; dossier de l'utilisateur, sans élévation et sans fenêtre jaune. Qui veut l'ouvrir
; à toute la machine peut le demander — c'est ce que permet la seconde ligne, qui
; fait poser la question au lancement.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

ArchitecturesAllowed={#Architectures}
ArchitecturesInstallIn64BitMode={#Architectures}
; Media Foundation ne lit le FLAC et l'ALAC d'origine que depuis Windows 10, et le
; rendu demande Direct3D 11. En deçà, mieux vaut refuser que laisser découvrir.
MinVersion=10.0

LicenseFile={#Source}\LICENSE.txt
SetupIconFile=Resources\Spectre.ico
WizardStyle=modern
; `ChangesAssociations` fait prévenir l'explorateur à la fin : sans quoi les icônes
; des fichiers audio ne changent qu'à la prochaine ouverture de session.
ChangesAssociations=yes
Compression=lzma2/max
SolidCompression=yes
OutputDir={#Sortie}
OutputBaseFilename={#Application}-{#Version}-{#Arch}-installeur

[Languages]
; Les cinq langues de l'application, et dans le même ordre — voir
; `Sources/SpectreTextes/Langue.swift`. Le français est en tête parce qu'il est la
; langue de référence, celle vers laquelle on retombe.
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "pl"; MessagesFile: "compiler:Languages\Polish.isl"

[CustomMessages]
fr.GroupeAssociations=Fichiers audio
fr.TacheAssocier=Ouvrir les fichiers audio avec Spectre
fr.OuvrirLesReglages=Choisir Spectre dans les applications par défaut de Windows
fr.DescriptionApplication=Transcrire de la musique à l'oreille
fr.TypeFichierAudio=Fichier audio

en.GroupeAssociations=Audio files
en.TacheAssocier=Open audio files with Spectre
en.OuvrirLesReglages=Pick Spectre in Windows default apps
en.DescriptionApplication=Transcribe music by ear
en.TypeFichierAudio=Audio file

es.GroupeAssociations=Archivos de audio
es.TacheAssocier=Abrir los archivos de audio con Spectre
es.OuvrirLesReglages=Elegir Spectre en las aplicaciones predeterminadas de Windows
es.DescriptionApplication=Transcribir música de oído
es.TypeFichierAudio=Archivo de audio

de.GroupeAssociations=Audiodateien
de.TacheAssocier=Audiodateien mit Spectre öffnen
de.OuvrirLesReglages=Spectre in den Windows-Standard-Apps auswählen
de.DescriptionApplication=Musik nach Gehör transkribieren
de.TypeFichierAudio=Audiodatei

pl.GroupeAssociations=Pliki dźwiękowe
pl.TacheAssocier=Otwieraj pliki dźwiękowe w programie Spectre
pl.OuvrirLesReglages=Wybierz Spectre w domyślnych aplikacjach systemu Windows
pl.DescriptionApplication=Transkrypcja muzyki ze słuchu
pl.TypeFichierAudio=Plik dźwiękowy

[Tasks]
; **Décochée**, et c'est délibéré. Une application de transcription qui s'empare des
; `.mp3` de quelqu'un sans qu'il l'ait demandé est une application qu'on désinstalle
; le lendemain. Spectre reste de toute façon dans « Ouvrir avec » sans cette case.
Name: "associer"; Description: "{cm:TacheAssocier}"; \
    GroupDescription: "{cm:GroupeAssociations}"; Flags: unchecked
Name: "bureau"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#Application}"; Filename: "{app}\{#Executable}"
Name: "{autodesktop}\{#Application}"; Filename: "{app}\{#Executable}"; Tasks: bureau

[Registry]
; ── Le type de fichier, et l'application qui l'ouvre ─────────────────────────
Root: HKA; Subkey: "Software\Classes\{#ProgId}"; ValueType: string; \
    ValueName: ""; ValueData: "{cm:TypeFichierAudio}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\{#ProgId}\DefaultIcon"; ValueType: string; \
    ValueName: ""; ValueData: "{app}\{#Executable},0"
Root: HKA; Subkey: "Software\Classes\{#ProgId}\shell\open\command"; ValueType: string; \
    ValueName: ""; ValueData: """{app}\{#Executable}"" ""%1"""

Root: HKA; Subkey: "Software\Classes\Applications\{#Executable}"; ValueType: string; \
    ValueName: "FriendlyAppName"; ValueData: "{#Application}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\{#Executable}\shell\open\command"; \
    ValueType: string; ValueName: ""; ValueData: """{app}\{#Executable}"" ""%1"""

; ── Les capacités, pour Paramètres → Applications par défaut ─────────────────
;
; La première ligne ne pose rien : elle dit seulement d'emporter `Software\Spectre`
; en s'en allant, une fois `Capabilities` retirée. Sans elle, la désinstallation
; laisse une clé vide derrière elle — ce qui ne gêne personne, et qui est
; exactement le genre de trace qu'on reproche aux installeurs.
Root: HKA; Subkey: "Software\{#Application}"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\{#Application}\Capabilities"; ValueType: string; \
    ValueName: "ApplicationName"; ValueData: "{#Application}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\{#Application}\Capabilities"; ValueType: string; \
    ValueName: "ApplicationDescription"; ValueData: "{cm:DescriptionApplication}"
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; \
    ValueName: "{#Application}"; ValueData: "Software\{#Application}\Capabilities"; \
    Flags: uninsdeletevalue

; ── Une ligne par extension ──────────────────────────────────────────────────
;
; Engendré par `paquet.ps1` à partir de `DecodeurWindows.formats` — la liste que le
; décodeur sait vraiment ouvrir. Les deux ne peuvent donc pas diverger : ajouter un
; format dans `Sources/SpectreWin/Plateforme.swift` l'ajoute ici au prochain paquet,
; et un format qui n'y serait plus disparaîtrait des associations du même coup.
#include "build\formats.iss"

[Run]
; La page des applications par défaut, ouverte sur Spectre. C'est là — et nulle part
; ailleurs — que Windows laisse désigner ce qui ouvre les `.mp3` ; voir la note en
; tête de ce fichier. Proposé seulement à qui a coché la case.
Filename: "ms-settings:defaultapps?registeredAppUser={#Application}"; \
    Description: "{cm:OuvrirLesReglages}"; Tasks: associer; \
    Check: not IsAdminInstallMode; Flags: postinstall shellexec nowait skipifsilent
Filename: "ms-settings:defaultapps?registeredAppMachine={#Application}"; \
    Description: "{cm:OuvrirLesReglages}"; Tasks: associer; \
    Check: IsAdminInstallMode; Flags: postinstall shellexec nowait skipifsilent

Filename: "{app}\{#Executable}"; Description: "{cm:LaunchProgram,{#Application}}"; \
    Flags: postinstall nowait skipifsilent

; Rien à effacer de plus à la désinstallation. Les sessions, les réglages et le
; cache des pistes séparées sont dans le dossier de l'utilisateur — voir
; `Storage.root` — et pas dans celui de l'application : ce sont des heures de GPU
; que personne n'a envie de refaire pour avoir réinstallé.
