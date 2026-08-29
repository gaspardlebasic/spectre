import Foundation
import SpectreCore
#if canImport(WinSDK)
import WinSDK
#endif

// Ce qui part quand une panne arrive, et surtout ce qui n'en part pas.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE HARNAIS EST LE PLUS IMPORTANT DE TOUS CEUX QUI NE MESURENT RIEN
//
// Les autres vérifications disent si l'application calcule juste. Celle-ci dit si
// elle **se tait sur ce qui ne la regarde pas**. La différence est qu'un défaut de
// calcul se voit à l'écran, alors qu'un titre de morceau parti chez un tiers ne se
// voit nulle part : ni dans la fenêtre, ni dans une relecture de code, ni le jour
// où cela arrive. On l'apprendrait par quelqu'un d'autre, et trop tard.
//
// Le contrôle qui compte est donc le plus bête : on fabrique une panne dont le
// message porte un chemin personnel et un titre de morceau, on laisse partir le
// rapport, on attrape les octets **au dernier moment avant le réseau**, et l'on
// cherche dedans le nom de la personne et le titre. Pas la fonction qui les retire :
// les octets. C'est la seule formulation qui reste vraie si quelqu'un ajoute un
// champ au rapport dans six mois.
//
// Tout se fait sans réseau : `Rapports.poste` remplace le fil par une fonction qui
// garde ce qu'on lui donne. Le harnais tourne donc partout où Swift compile, y
// compris sur un coureur sans sortie vers l'extérieur. `SPECTRE_RECEVEUR` ajoute,
// quand il est posé, un vrai envoi sur une boucle locale — c'est `check.sh` et
// `essai.ps1` qui le posent, et c'est ce qui éprouve `URLSession` elle-même sur les
// trois systèmes.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

func poserDansLEnvironnement(_ nom: String, _ valeur: String) {
    #if canImport(WinSDK)
    _ = nom.withCString(encodedAs: UTF16.self) { n in
        valeur.withCString(encodedAs: UTF16.self) { v in SetEnvironmentVariableW(n, v) }
    }
    #else
    setenv(nom, valeur, 1)
    #endif
}

let gestionnaire = FileManager.default
let atelier = gestionnaire.temporaryDirectory
    .appendingPathComponent("spectre-rapports-\(ProcessInfo.processInfo.processIdentifier)",
                            isDirectory: true)
try? gestionnaire.createDirectory(at: atelier, withIntermediateDirectories: true)
poserDansLEnvironnement("SPECTRE_RANGEMENT", atelier.path)
// Une adresse d'essai, qui ne mène nulle part : rien ne sortira d'ici puisque
// `Rapports.poste` est remplacé juste après.
let adresseDEssai = "https://cle-publique@sentry.exemple.invalid/42"
let fileDuHarnais = atelier.appendingPathComponent("rapports", isDirectory: true)

/// Ce que le harnais a intercepté à la place du réseau.
var postes = [(url: URL, entetes: [String: String], corps: Data)]()
/// Ce que le service est censé répondre au prochain envoi.
var reponse = 200

func recommencer(adresse: String = adresseDEssai) {
    Rapports.remiseAZeroPourLeHarnais()
    try? gestionnaire.removeItem(at: fileDuHarnais)
    postes.removeAll()
    Rapports.poste = { url, entetes, corps in
        postes.append((url, entetes, corps))
        return reponse
    }
    Rapports.ouvrir(version: "essai", dsn: adresse, envoiEnFond: false)
}

// ─────────────────────────────────────────────────────────────────────────────

titre("Ce qui ne part jamais")

let maison = NSHomeDirectory()
let personne = (maison as NSString).lastPathComponent
let titreDuMorceau = "Santi & Tuğçe - Hikâye"

do {
    let brut = "impossible de décoder : \(maison)/Musique/\(titreDuMorceau).mp3"
    let propre = Anonyme.nettoyer(brut)
    verifie(!propre.contains(titreDuMorceau), "le titre du morceau s'en va", propre)
    verifie(!propre.contains(maison) && !propre.contains(personne),
            "le chemin personnel aussi")
    verifie(propre.contains("mp3"), "le format reste — c'est lui qui explique la panne")
    verifie(propre.hasPrefix("impossible de décoder"), "et la panne reste lisible")
}

do {
    // La forme qu'ont les messages de Foundation : le nom entre guillemets, au
    // milieu d'une phrase. C'est le cas qui décide, parce que c'est celui qu'on
    // remonte sans l'avoir écrit soi-même.
    let propre = Anonyme.nettoyer("The file “\(titreDuMorceau).mp3” couldn’t be opened.")
    verifie(!propre.contains("Hikâye") && !propre.contains("Santi"),
            "un titre entre guillemets, espaces compris", propre)
    verifie(propre.contains("couldn"), "sans emporter la fin de la phrase")
}

do {
    // Hors du dossier personnel : le dossier reste — il explique les pannes de
    // permission — et le titre s'en va.
    let propre = Anonyme.nettoyer("/Volumes/Musique/Démos/Mon Titre.wav est illisible")
    verifie(!propre.contains("Mon Titre"), "un morceau sur un disque externe", propre)
    verifie(propre.contains("/Volumes/Musique/Démos/"), "mais le dossier reste")
}

do {
    // Le message que le Mac rend vraiment quand un fichier ne se décode pas, relevé
    // sur la machine d'essai : le titre y est entre guillemets français. Ce cas-là
    // n'a pas été deviné, il a été lu dans un journal.
    let propre = Anonyme.nettoyer("Impossible de lire « \(titreDuMorceau).mp3 » : "
                                  + "L\u{2019}opération n\u{2019}a pas pu s\u{2019}achever. "
                                  + "(com.apple.coreaudio.avfaudio erreur 1685348671.)")
    verifie(!propre.contains("Hikâye") && !propre.contains("Santi"),
            "le message d'AVFoundation, tel qu'il arrive", propre)
    verifie(propre.contains("avfaudio"), "et le domaine de l'erreur reste")
}

do {
    let brut = "ONNX Runtime : le modèle /opt/spectre/htdemucs.onnx n'a pas 4 sorties"
    verifie(Anonyme.nettoyer(brut) == brut,
            "un message sans rien de personnel n'est pas touché")
}

do {
    verifie(Anonyme.empreinte("arrêt à 12,4 s") == Anonyme.empreinte("arrêt à 31,9 s"),
            "deux fois la même panne à deux instants différents font une empreinte")
    verifie(Anonyme.empreinte("le décodeur") != Anonyme.empreinte("le lecteur"),
            "deux pannes différentes en font deux")
}

// ─────────────────────────────────────────────────────────────────────────────

titre("Rien ne part sans adresse")

do {
    Rapports.remiseAZeroPourLeHarnais()
    try? gestionnaire.removeItem(at: fileDuHarnais)
    Rapports.ouvrir(version: "essai", dsn: "", envoiEnFond: false)
    verifie(!Rapports.actifs, "sans DSN, les rapports sont inertes")
    Rapports.signaler("une panne")
    verifie(Rapports.fileEnAttente().isEmpty, "et rien n'est écrit sur le disque")
    Rapports.remiseAZeroPourLeHarnais()
    Rapports.ouvrir(version: "essai", dsn: "ceci n'est pas une adresse", envoiEnFond: false)
    verifie(!Rapports.actifs, "une adresse illisible ne réveille rien")
}

// ─────────────────────────────────────────────────────────────────────────────

titre("L'enveloppe")

recommencer()
Rapports.carte("Apple M2 Max")
Rapports.signaler("impossible de décoder : \(maison)/Musique/\(titreDuMorceau).mp3")
Rapports.envoyerLaFile()

verifie(postes.count == 1, "un rapport, un envoi", "\(postes.count)")
if let envoi = postes.first {
    verifie(envoi.url.absoluteString == "https://sentry.exemple.invalid/api/42/envelope/",
            "le DSN devient une adresse d'envoi", envoi.url.absoluteString)
    let auth = envoi.entetes["X-Sentry-Auth"] ?? ""
    verifie(auth.contains("sentry_key=cle-publique") && auth.contains("sentry_version=7"),
            "l'en-tête d'authentification porte la clé publique", auth)
    verifie(envoi.entetes["Content-Type"] == "application/x-sentry-envelope",
            "et le type de contenu est celui d'une enveloppe")

    // LE contrôle. Sur les octets, et pas sur la fonction qui les a fabriqués.
    let texte = String(decoding: envoi.corps, as: UTF8.self)
    verifie(!texte.contains(titreDuMorceau), "le titre du morceau n'est pas dans ce qui part")
    verifie(!texte.contains(personne), "le nom de la personne non plus")

    let lignes = texte.split(separator: "\n", omittingEmptySubsequences: false)
    verifie(lignes.count >= 3, "trois lignes : l'enveloppe, l'objet, l'évènement")
    let tete = (try? JSONSerialization.jsonObject(with: Data(lignes[0].utf8))) as? [String: Any]
    let objet = (try? JSONSerialization.jsonObject(with: Data(lignes[1].utf8))) as? [String: Any]
    let evenement = (try? JSONSerialization.jsonObject(with: Data(lignes[2].utf8))) as? [String: Any]
    verifie(tete?["event_id"] as? String != nil, "l'en-tête porte le numéro d'évènement")
    verifie(objet?["type"] as? String == "event", "l'objet est un évènement")
    // La longueur est en octets. Un message accentué — c'est-à-dire tous les nôtres —
    // serait tronqué à l'arrivée si l'on comptait les caractères.
    verifie(objet?["length"] as? Int == Data(lignes[2].utf8).count,
            "et sa longueur est celle des octets, pas des caractères")
    verifie(evenement?["release"] as? String == "spectre@essai",
            "la version part avec", "\(evenement?["release"] ?? "—")")
    verifie(evenement?["level"] as? String == "error", "le niveau aussi")
    verifie((evenement?["user"] as? [String: Any])?["id"] as? String != nil,
            "un numéro de machine, sans lien avec la personne")
    verifie((evenement?["fingerprint"] as? [String])?.count == 2,
            "et de quoi regrouper deux fois la même panne")
    let etiquettes = evenement?["tags"] as? [String: String]
    verifie(etiquettes?["carte"] == "Apple M2 Max", "la carte graphique est du voyage")
    verifie(etiquettes?["origine"]?.contains("main.swift") == true,
            "avec l'endroit du programme d'où vient la panne", etiquettes?["origine"] ?? "—")
}

do {
    // Le même numéro de machine d'un lancement à l'autre : c'est toute son utilité.
    let premier = numeroDeMachine()
    Rapports.remiseAZeroPourLeHarnais()
    Rapports.ouvrir(version: "essai", dsn: adresseDEssai, envoiEnFond: false)
    Rapports.signaler("une autre panne")
    verifie(!premier.isEmpty && premier == numeroDeMachine(),
            "le numéro de machine survit au lancement suivant")
}

func numeroDeMachine() -> String {
    let fichier = fileDuHarnais.appendingPathComponent("machine.txt")
    return ((try? String(contentsOf: fichier, encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// ─────────────────────────────────────────────────────────────────────────────

titre("Ce qui empêche mille rapports en une minute")

recommencer()
for _ in 0..<40 { Rapports.signaler("la carte a refusé le nuanceur") }
verifie(Rapports.fileEnAttente().count == 1, "la même panne est comptée, pas répétée",
        "\(Rapports.fileEnAttente().count) rapport(s)")
verifie(Rapports.fileEnAttente().first?.contains("[40]") == true,
        "et le compte part avec", Rapports.fileEnAttente().first ?? "—")

recommencer()
// Vingt pannes **de formes différentes** : l'empreinte retire les chiffres, si
// bien que vingt fois le même message numéroté n'en ferait qu'une — ce qui est le
// but du compteur d'au-dessus, et ce qui a mis ce contrôle-ci en défaut la première
// fois qu'il a été écrit.
let mots = ["décodeur", "lecteur", "nuanceur", "modèle", "réseau", "tampon",
            "fenêtre", "carte", "fichier", "moteur", "filtre", "cache",
            "session", "piste", "grille", "onglet", "curseur", "volume",
            "tempo", "accord"]
for mot in mots { Rapports.signaler("le \(mot) a refusé") }
verifie(Rapports.fileEnAttente().count == 8, "un lancement n'écrit pas plus de huit rapports",
        "\(Rapports.fileEnAttente().count)")

do {
    recommencer()
    let compteur = fileDuHarnais.appendingPathComponent("compte.json")
    let jour = Int(Date().timeIntervalSince1970 / 86_400)
    try? Data("{\"jour\":\(jour),\"nombre\":40}".utf8).write(to: compteur)
    Rapports.signaler("une panne de plus, mais la journée est pleine")
    verifie(Rapports.fileEnAttente().isEmpty, "et une journée pas plus de quarante")
    // Le compteur est dans le même dossier que la file : l'envoi ne doit pas
    // l'emporter en faisant le ménage.
    Rapports.envoyerLaFile()
    verifie(gestionnaire.fileExists(atPath: compteur.path),
            "le compteur du jour survit à un envoi")
}

// ─────────────────────────────────────────────────────────────────────────────

titre("La file, entre deux lancements")

do {
    recommencer()
    reponse = 500
    Rapports.signaler("le service est en panne")
    Rapports.envoyerLaFile()
    verifie(Rapports.fileEnAttente().count == 1, "un service muet ne fait pas perdre le rapport")
    reponse = 200
    Rapports.envoyerLaFile()
    verifie(Rapports.fileEnAttente().isEmpty, "qui repart au lancement suivant")

    recommencer()
    reponse = 413
    Rapports.signaler("une enveloppe que le service refuse")
    Rapports.envoyerLaFile()
    verifie(Rapports.fileEnAttente().isEmpty,
            "un refus définitif jette le rapport plutôt que de le renvoyer cent fois")
    reponse = 200
}

do {
    recommencer()
    // Trois jours et une seconde : une panne dont personne n'a de nouvelles est
    // une panne dont la version a peut-être déjà changé.
    let vieux = fileDuHarnais.appendingPathComponent("00000000000000000000000000000001.rapport")
    let quand = Date().timeIntervalSince1970 - 3 * 86_400 - 1
    let json = """
    {"identifiant":"00000000000000000000000000000001","quand":\(quand),\
    "niveau":"error","quoi":"une panne d'avant-hier","origine":"x:1",\
    "version":"essai","systeme":"x","architecture":"arm64","machine":"m","repetitions":1}
    """
    try? Data(json.utf8).write(to: vieux)
    verifie(Rapports.fileEnAttente().count == 1, "un vieux rapport attend encore")
    Rapports.envoyerLaFile()
    verifie(postes.isEmpty, "il ne part pas")
    verifie(Rapports.fileEnAttente().isEmpty, "et il ne reste pas là non plus")

    // Un rapport à demi écrit par un lancement mort en l'écrivant : il n'apprendra
    // rien à personne, et il resterait dans le dossier pour toujours.
    let tronque = fileDuHarnais.appendingPathComponent("00000000000000000000000000000002.rapport")
    try? Data("{\"identifiant\":\"0000".utf8).write(to: tronque)
    Rapports.envoyerLaFile()
    verifie(!gestionnaire.fileExists(atPath: tronque.path), "un rapport illisible est jeté")
}

// ─────────────────────────────────────────────────────────────────────────────

// Le seul contrôle qui touche vraiment à la couche réseau. Il ne tourne que si
// `check.sh` ou `essai.ps1` a posé un receveur sur la boucle locale — sans quoi il
// se saute, et il le dit. C'est le pendant, pour les rapports, de ce que la machine
// d'essai est pour les paquets : le code qui n'a jamais posté ne poste peut-être
// pas.
titre("Un vrai envoi, sur une boucle locale")

if let receveur = ProcessInfo.processInfo.environment["SPECTRE_RECEVEUR"] {
    Rapports.remiseAZeroPourLeHarnais()
    try? gestionnaire.removeItem(at: fileDuHarnais)
    Rapports.poste = nil
    Rapports.ouvrir(version: "essai", dsn: receveur, envoiEnFond: false)
    Rapports.signaler("un rapport qui passe par la vraie pile réseau")
    Rapports.envoyerLaFile()
    verifie(Rapports.fileEnAttente().isEmpty,
            "l'envoi aboutit et la file se vide", receveur)
} else {
    print("  (pas de receveur — SPECTRE_RECEVEUR n'est pas posé)")
}

try? gestionnaire.removeItem(at: atelier)

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
