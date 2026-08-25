import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Où va ce qui ne peut pas s'afficher dans la fenêtre.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// LE SEUL `#if` DE TOUTE LA COUCHE PARTAGÉE, ET POURQUOI IL EST LÉGITIME
///
/// `SpectreToile`, `SpectreSon` et `SpectreDessin` n'en portent aucun : ce qui
/// change d'un système à l'autre est un étage plus bas, dans `Sources/CPont`, où
/// deux fichiers C exportent les mêmes fonctions. Ce fichier-ci fait exception, et
/// la raison est réelle plutôt que commode.
///
/// Sous Windows, l'application est bâtie en sous-système « fenêtre », donc **sans
/// console à elle** : écrire sur la sortie d'erreur n'irait nulle part, et le
/// premier message qu'on cherche est justement celui qui explique pourquoi la
/// fenêtre ne s'est pas ouverte. `rattacherLaConsole()` reprend celle du terminal
/// quand il y en avait une ; lancée par un double-clic, il n'y en a pas. On écrit
/// donc aussi par `OutputDebugString`, que le débogueur et DebugView lisent.
///
/// Sous Linux et sur le Mac, une application graphique garde la sortie d'erreur du
/// terminal qui l'a lancée, et le bureau la range dans le journal du système quand
/// personne ne l'a lancée à la main.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI IL Y A MAINTENANT UN FICHIER, ET CE QU'IL A COÛTÉ DE NE PAS L'AVOIR
///
/// La v0.4 est partie avec un installeur Windows qui ne s'ouvrait pas. Windows en a
/// gardé cinq rapports, tous identiques : erreur fatale du runtime Swift, au même
/// endroit à chaque fois. **Une erreur fatale de Swift écrit son message**, et ce
/// message-là n'est arrivé nulle part : pas de console, pas de fichier, rien. Il a
/// fallu une machine virtuelle, un accès distant et une demi-journée pour apprendre
/// ce qu'une ligne de texte disait déjà.
///
/// D'où `ouvrir(dans:)`, et d'où la forme qu'il prend : **on ne recopie pas la
/// sortie d'erreur dans un fichier, on la déplace dedans.** `freopen` fait pointer
/// la sortie d'erreur du processus — celle du C, celle de Foundation, et celle où
/// le runtime de Swift écrit avant de mourir — sur le journal. Tout ce que
/// l'application a jamais su dire y arrive donc sans qu'on ait à le lui demander, y
/// compris ce qu'elle dit dans sa dernière milliseconde.
///
/// **Et sans tampon.** C'est la moitié qui compte : un message poussé dans un
/// tampon que personne ne vide avant le plantage n'a pas été écrit. `setvbuf` le
/// retire, ce qui coûte un appel système par ligne — quelques dizaines par
/// lancement, et l'on n'écrit pas ici en boucle de dessin.
///
/// **Et l'ancienne sortie d'erreur est gardée, pas jetée.** C'est la subtilité qui
/// a failli coûter cher : « pas de terminal » ne veut pas dire « personne
/// n'écoute ». Un coureur d'intégration continue n'a pas de terminal, et
/// `build.ps1` capture pourtant cette sortie-là dans un fichier pour l'imprimer
/// quand l'épreuve du dossier propre échoue — c'est-à-dire exactement quand on en a
/// besoin. La déplacer sans la garder rendait ce diagnostic muet, et l'on aurait
/// remplacé une panne aveugle par une autre.
///
/// `dup` met donc de côté la destination d'origine avant le détournement, et chaque
/// ligne que `Journal` écrit part **des deux côtés** : dans le journal, et là où
/// elle serait allée. Ce qui n'existe que d'un seul côté est ce qu'on ne contrôle
/// pas — le dernier mot du runtime de Swift, qui va dans le journal et lui seul, et
/// qui est précisément ce qu'on n'avait jamais pu lire.
/// ─────────────────────────────────────────────────────────────────────────────
public enum Journal {
    // MARK: - Ce que l'application dit

    public static func erreur(_ message: String) {
        ecrire("Spectre : \(message)", surLErreur: true)
    }

    /// Une note va sur la **sortie ordinaire**, et pas sur celle d'erreur.
    ///
    /// La distinction n'est pas cosmétique : PowerShell tient pour une erreur tout
    /// ce qu'un exécutable écrit sur la sortie d'erreur, et l'annonce comme telle au
    /// milieu d'une épreuve qui se passe bien. Un nom de carte graphique n'est pas
    /// une erreur.
    ///
    /// Elle bascule pourtant sur la sortie d'erreur dès que le journal a pris sa
    /// place — sans terminal, la sortie ordinaire ne mène nulle part, et une note
    /// perdue est une note qui manquera au rapport. Personne n'est plus là pour la
    /// prendre pour une erreur.
    public static func note(_ message: String) {
        ecrire("Spectre : \(message)", surLErreur: detourne)
    }

    private static func ecrire(_ ligne: String, surLErreur: Bool) {
        let flux = surLErreur ? FileHandle.standardError : FileHandle.standardOutput
        let octets = Array((ligne + "\n").utf8)
        flux.write(Data(octets))
        // Le double dans le fichier n'a lieu d'être que si la sortie d'erreur ne
        // s'y déverse pas déjà : sinon chaque ligne y figurerait deux fois.
        if !detourne { ecrireDansLeFichier(ligne + "\n") }
        // Et là où elle serait allée sans nous : voir la note en tête de fichier.
        if doublon >= 0 { ecrireSur(doublon, octets) }
        #if os(Windows)
        ligne.withCString(encodedAs: UTF16.self) { OutputDebugStringW($0) }
        #endif
    }

    // MARK: - Le fichier

    /// Le journal du lancement en cours, une fois `ouvrir(dans:)` passé.
    public private(set) static var chemin: URL?

    /// Là où la sortie d'erreur est allée se déverser.
    private static var detourne = false

    /// La sortie d'erreur d'origine, gardée de côté avant le détournement — le
    /// fichier d'un coureur, le journal du bureau, ou rien du tout. `-1` tant qu'on
    /// n'a rien détourné.
    private static var doublon: Int32 = -1

    /// Un journal, et un seul précédent. Deux fichiers suffisent : celui du
    /// lancement où l'on est, et celui du lancement d'avant — qui est presque
    /// toujours celui qu'on cherche, puisqu'on rouvre l'application pour comprendre
    /// pourquoi elle vient de se fermer.
    private static let plafond = 512 * 1024

    /// Ouvre le journal du lancement, et y déverse la sortie d'erreur.
    ///
    /// Il va dans le rangement, à côté des sessions et des pistes séparées : c'est
    /// le dossier que `SPECTRE_RANGEMENT` déplace, si bien qu'un harnais n'écrit
    /// pas dans le journal de la vraie application. Sans rangement, tout continue
    /// de marcher comme avant — l'application parle, et personne ne prend de notes.
    ///
    /// À appeler **le plus tôt possible**, et sous Windows après
    /// `rattacherLaConsole()` : c'est lui qui décide s'il y a un terminal.
    public static func ouvrir(version: String? = nil) {
        guard let dossier = Storage.root else { return }
        let fichier = dossier.appendingPathComponent("journal.txt", isDirectory: false)
        let precedent = dossier.appendingPathComponent("journal-1.txt", isDirectory: false)

        let gestionnaire = FileManager.default
        try? gestionnaire.createDirectory(at: dossier, withIntermediateDirectories: true)
        // On fait tourner sur la taille et non à chaque lancement : une application
        // qu'on rouvre trois fois de suite pour reproduire une panne effacerait
        // sinon la trace de la panne avec le troisième lancement.
        let attributs = try? gestionnaire.attributesOfItem(atPath: fichier.path)
        let taille = (attributs?[.size] as? Int) ?? 0
        if taille >= plafond {
            try? gestionnaire.removeItem(at: precedent)
            try? gestionnaire.moveItem(at: fichier, to: precedent)
        }
        if !gestionnaire.fileExists(atPath: fichier.path) {
            gestionnaire.createFile(atPath: fichier.path, contents: nil)
        }
        chemin = fichier

        if !surUnTerminal() {
            let garde = dupliquerLaSortieDErreur()
            detourne = fichier.path.withCString { freopen($0, "a", stderr) != nil }
            if detourne { doublon = garde } else { fermer(garde) }
        }
        // Sans tampon, et dans les deux cas : ce qui est écrit juste avant une
        // chute doit être sur le disque, pas dans un tampon que plus personne ne
        // videra.
        setvbuf(stderr, nil, _IONBF, 0)

        entete(version: version)
        attraperLesChutes()
    }

    /// La ligne d'ouverture : de quoi savoir, en lisant le journal seul, sur quelle
    /// machine et sur quelle version il a été écrit.
    ///
    /// Ne porte **ni nom de machine, ni nom d'utilisateur, ni chemin personnel** —
    /// c'est la même règle que celle des rapports de plantage, et elle commence ici
    /// puisque c'est ce fichier-ci qui partira un jour.
    private static func entete(version: String?) {
        let horodatage = ISO8601DateFormatter().string(from: Date())
        let systeme = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let tranche = "arm64"
        #elseif arch(x86_64)
        let tranche = "x86_64"
        #else
        let tranche = "architecture inconnue"
        #endif
        // Le numéro de version n'a pas encore de source unique : le Mac le lit dans
        // son paquet, les deux autres ne l'ont nulle part. « inconnue » est donc la
        // réponse honnête en attendant — voir `docs/PAQUETS.md`.
        let numero = version ?? "inconnue"
        ecrire("", surLErreur: detourne)
        ecrire("── \(horodatage) — Spectre \(numero) — \(systeme) — \(tranche)",
               surLErreur: detourne)
    }

    private static func ecrireDansLeFichier(_ ligne: String) {
        guard let chemin else { return }
        guard let poignee = try? FileHandle(forWritingTo: chemin) else { return }
        defer { try? poignee.close() }
        try? poignee.seekToEnd()
        try? poignee.write(contentsOf: Data(ligne.utf8))
    }

    private static func surUnTerminal() -> Bool {
        #if os(Windows)
        return _isatty(_fileno(stderr)) != 0
        #else
        return isatty(2) != 0
        #endif
    }

    /// Les trois appels du système où le nom seul change d'un système à l'autre.
    /// Windows préfixe d'un blanc soulignant ce que la norme C a laissé à POSIX.
    private static func dupliquerLaSortieDErreur() -> Int32 {
        #if os(Windows)
        return _dup(2)
        #else
        return dup(2)
        #endif
    }

    private static func ecrireSur(_ descripteur: Int32, _ octets: [UInt8]) {
        #if os(Windows)
        _ = _write(descripteur, octets, UInt32(octets.count))
        #else
        _ = write(descripteur, octets, octets.count)
        #endif
    }

    private static func fermer(_ descripteur: Int32) {
        guard descripteur >= 0 else { return }
        #if os(Windows)
        _ = _close(descripteur)
        #else
        _ = close(descripteur)
        #endif
    }

    // MARK: - La chute

    /// Pose « je suis tombé, et voici de quoi » avant que le processus ne meure.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// CE QU'ON A LE DROIT DE FAIRE ICI EST PRESQUE RIEN
    ///
    /// Un programme qui vient de recevoir un signal fatal n'a pas le droit
    /// d'allouer, ni d'appeler Foundation, ni de toucher à ses propres structures :
    /// la mémoire qu'il s'apprête à décrire est peut-être celle qui l'a tué. Tout
    /// ce que fait la fonction ci-dessous est donc **préparé d'avance** — le tampon
    /// est alloué ici, à l'installation — et la chute ne fait qu'un `write` sur un
    /// descripteur déjà ouvert. C'est le seul appel de la liste des appels sûrs en
    /// contexte de signal dont on ait besoin.
    ///
    /// Le signal est ensuite **rendu à qui de droit** : on remet le comportement par
    /// défaut et on se le renvoie. Sans cela, le système ne verrait pas de plantage,
    /// n'écrirait pas de rapport, et l'on aurait remplacé le diagnostic de Windows
    /// et de macOS par le nôtre — qui en dit dix fois moins.
    /// ─────────────────────────────────────────────────────────────────────────
    private static func attraperLesChutes() {
        preparerLeTampon()
        // La chute part des deux côtés, comme le reste — et pour la même raison :
        // le fichier d'un coureur doit dire « il est tombé » plutôt que de s'arrêter
        // au milieu d'une phrase.
        doublonDeChute = doublon
        #if os(Windows)
        // Windows ne connaît pas les signaux POSIX pour ce genre de mort : une
        // violation d'accès y est une « exception structurée », et c'est ce filtre
        // qui la voit passer en dernier.
        SetUnhandledExceptionFilter(chuteWindows)
        #else
        for numero in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            signal(numero, chutePosix)
        }
        #endif
    }
}

// MARK: - Ce que la chute écrit, préparé d'avance

/// Le tampon du message de chute, alloué à l'installation et jamais après.
private var tamponDeChute: UnsafeMutablePointer<UInt8>?
private var longueurDuPrefixe = 0
/// La sortie d'erreur d'origine, recopiée ici parce qu'un gestionnaire de signal ne
/// doit pas aller chercher une propriété d'un type.
private var doublonDeChute: Int32 = -1

private func preparerLeTampon() {
    guard tamponDeChute == nil else { return }
    let prefixe = Array("\nSpectre : chute — ".utf8)
    let tampon = UnsafeMutablePointer<UInt8>.allocate(capacity: prefixe.count + 32)
    tampon.update(from: prefixe, count: prefixe.count)
    tamponDeChute = tampon
    longueurDuPrefixe = prefixe.count
}

/// Écrit un nombre dans le tampon sans rien allouer, et rend la longueur totale.
private func poserLeNombre(_ valeur: Int, base: Int) -> Int {
    guard let tampon = tamponDeChute else { return 0 }
    var n = longueurDuPrefixe
    let v = valeur < 0 ? 0 : valeur
    var diviseur = 1
    while v / diviseur >= base { diviseur *= base }
    while diviseur > 0 {
        let chiffre = (v / diviseur) % base
        tampon[n] = chiffre < 10 ? UInt8(48 + chiffre) : UInt8(87 + chiffre)
        n += 1
        diviseur /= base
    }
    tampon[n] = 10  // le passage à la ligne
    return n + 1
}

#if os(Windows)
private func chuteWindows(_ infos: UnsafeMutablePointer<EXCEPTION_POINTERS>?) -> LONG {
    let code = Int(infos?.pointee.ExceptionRecord?.pointee.ExceptionCode ?? 0)
    let longueur = poserLeNombre(code, base: 16)
    if let tampon = tamponDeChute, longueur > 0 {
        tampon.withMemoryRebound(to: CChar.self, capacity: longueur) { texte in
            _ = fwrite(texte, 1, longueur, stderr)
        }
        fflush(stderr)
        if doublonDeChute >= 0 { _ = _write(doublonDeChute, tampon, UInt32(longueur)) }
    }
    // `CONTINUE_SEARCH` et non `EXECUTE_HANDLER` : on veut que Windows fasse
    // ensuite son propre rapport. Le nôtre dit où chercher, le sien dit quoi.
    return LONG(EXCEPTION_CONTINUE_SEARCH)
}
#else
private func chutePosix(_ numero: Int32) {
    let longueur = poserLeNombre(Int(numero), base: 10)
    if let tampon = tamponDeChute, longueur > 0 {
        _ = write(2, tampon, longueur)
        if doublonDeChute >= 0 { _ = write(doublonDeChute, tampon, longueur) }
    }
    signal(numero, SIG_DFL)
    raise(numero)
}
#endif
