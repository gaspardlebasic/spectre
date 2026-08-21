import Foundation
import SpectreWin
import WinSDK

// La fenêtre, en Win32 sans intermédiaire.
//
// SDL3 donnerait la même chose en trois appels, et c'est ce qu'avait fait le
// premier portage. Il coûtait en échange les trois choses qui font celui-ci : la
// barre de titre du système, le fond Mica, et le changement d'échelle tel que
// Windows l'attend — un écran par densité, et la densité qui change quand on
// déplace la fenêtre. Tout cela tient ici en quelques centaines de lignes.

/// Ce que la fenêtre sait faire savoir. Le comportement, lui, est dans le modèle.
public protocol EchosDeLaFenetre: AnyObject {
    /// La zone cliente a changé de taille, en pixels.
    func fenetreRedimensionnee(largeur: Int, hauteur: Int)
    /// La densité de l'écran a changé — écran différent, ou réglage modifié.
    func fenetreChangeDEchelle(_ echelle: Double)
    /// Redessiner tout de suite, sans attendre le tour de boucle : Windows bloque
    /// dans sa propre boucle pendant qu'on tire un bord, et une fenêtre qui ne se
    /// redessine pas pendant ce temps paraît plantée.
    func fenetreDemandeUneImage()
    /// L'application s'en va. Rendre `false` pour l'en empêcher.
    func fenetrePeutSeFermer() -> Bool
    /// Un message d'entrée — souris, molette, clavier. Rendre `true` s'il a été
    /// traité, `false` pour le laisser à Windows.
    ///
    /// La fenêtre ne sait rien de ce que ces messages veulent dire : c'est
    /// `Gestes` qui les traduit, et le modèle qui décide. Une fenêtre qui
    /// interpréterait elle-même un clic serait le début du second cerveau.
    func fenetreRecoitUneEntree(_ message: UINT, _ w: WPARAM, _ l: LPARAM) -> Bool
}

public final class Fenetre {
    public private(set) var poignee: HWND?
    public weak var echos: EchosDeLaFenetre?

    /// Points par pixel : 1 sur un écran ordinaire, 2 sur un écran dense. Windows
    /// le donne en points par pouce, dont 96 est l'unité.
    public private(set) var echelle: Double = 1

    private static let nomDeClasse = "SpectreFenetre"
    private static var classeEnregistree = false

    public init?(titre: String, largeur: Int, hauteur: Int) {
        // Conscience du changement d'échelle, version par écran, version 2 : c'est
        // la seule qui redimensionne aussi la zone non cliente — la barre de titre
        // — quand la fenêtre passe d'un écran à l'autre. Sans elle, Windows
        // agrandit l'image au lieu de la redessiner, et tout devient flou.
        //
        // La constante est une macro qui transtype l'entier −4 en poignée ; Swift
        // n'importe pas les macros d'un en-tête, d'où la reconstruction à la main.
        // C'est le premier de plusieurs — voir `Macros.swift`, qui les rassemble.
        if let contexte = UnsafeMutablePointer<DPI_AWARENESS_CONTEXT__>(bitPattern: -4) {
            _ = SetProcessDpiAwarenessContext(contexte)
        }

        let instance = GetModuleHandleW(nil)
        if !Self.classeEnregistree {
            var classe = WNDCLASSEXW()
            classe.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            // Redessiner sur les deux axes : sans ces deux drapeaux, agrandir la
            // fenêtre laisse la bande neuve remplie de ce qui l'occupait avant.
            classe.style = UINT(CS_HREDRAW | CS_VREDRAW)
            classe.lpfnWndProc = procedure
            classe.hInstance = instance
            classe.hCursor = LoadCursorW(nil, curseurFleche)
            // Aucun pinceau de fond : c'est Direct3D qui remplit chaque pixel, et
            // laisser Windows effacer d'abord fait clignoter en blanc au
            // redimensionnement.
            classe.hbrBackground = nil
            Self.nomDeClasse.withUTF16Pointer { nom in
                classe.lpszClassName = nom
                _ = RegisterClassExW(&classe)
            }
            Self.classeEnregistree = true
        }

        // La taille demandée est celle de la **zone cliente** : l'image en occupe
        // tout l'espace, et c'est elle qu'on veut de la bonne taille. `AdjustWindow`
        // y rajoute les bords et la barre de titre.
        var zone = RECT(left: 0, top: 0, right: LONG(largeur), bottom: LONG(hauteur))
        let style = DWORD(WS_OVERLAPPEDWINDOW)
        AdjustWindowRectEx(&zone, style, false, 0)

        let fenetre = titre.withUTF16Pointer { t in
            Self.nomDeClasse.withUTF16Pointer { c in
                CreateWindowExW(0, c, t, style,
                                Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT),
                                zone.right - zone.left, zone.bottom - zone.top,
                                nil, nil, instance,
                                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
            }
        }
        guard let fenetre else {
            Journal.erreur("La fenêtre n'a pas pu être créée (erreur \(GetLastError())).")
            return nil
        }
        poignee = fenetre
        echelle = Double(GetDpiForWindow(fenetre)) / 96
    }

    deinit {
        if let poignee { DestroyWindow(poignee) }
    }

    public func montrer() {
        guard let poignee else { return }
        ShowWindow(poignee, SW_SHOW)
        UpdateWindow(poignee)
    }

    public func titre(_ texte: String) {
        guard let poignee else { return }
        texte.withUTF16Pointer { _ = SetWindowTextW(poignee, $0) }
    }

    /// Taille de la zone cliente, en pixels.
    public var taillePixels: (largeur: Int, hauteur: Int) {
        guard let poignee else { return (1, 1) }
        var zone = RECT()
        GetClientRect(poignee, &zone)
        return (max(Int(zone.right - zone.left), 1), max(Int(zone.bottom - zone.top), 1))
    }

    /// Taille de la zone cliente, en points — l'unité dans laquelle raisonne tout
    /// le modèle.
    public var taillePoints: (largeur: Double, hauteur: Double) {
        let pixels = taillePixels
        return (Double(pixels.largeur) / echelle, Double(pixels.hauteur) / echelle)
    }

    /// Vide la file des messages. Rend `false` quand l'application doit s'arrêter.
    public func traiterLesMessages() -> Bool {
        var message = MSG()
        while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
            if message.message == UINT(WM_QUIT) { return false }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        return true
    }

    // MARK: La procédure de fenêtre

    fileprivate func repondre(_ message: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_MOUSEWHEEL, WM_MOUSEHWHEEL, WM_LBUTTONDOWN, WM_LBUTTONUP,
             WM_MOUSEMOVE, WM_MOUSELEAVE, WM_KEYDOWN:
            guard echos?.fenetreRecoitUneEntree(message, w, l) == true else { return nil }
            // On ne redessine **pas** ici. La boucle tourne à la cadence de l'écran
            // et prendra le geste au tour suivant, c'est-à-dire dans moins d'une
            // période — on ne peut pas montrer une image plus tôt que le balayage
            // suivant, quoi qu'on fasse. Dessiner ici en plus ne rapproche rien et
            // double le travail de la carte, ce que la mesure de fluidité voit tout
            // de suite : deux fois plus d'images que de tours de boucle.
            return 0

        case WM_SETCURSOR:
            // Sans cela, Windows repose le curseur de la classe à chaque mouvement,
            // et celui que le geste a choisi ne tient pas le temps d'être vu.
            if motBas(UInt64(l)) == Int(HTCLIENT) { return 1 }
            return nil

        case WM_SIZE:
            // Réduite, la fenêtre annonce une zone cliente nulle. Redimensionner la
            // chaîne d'échange à zéro la ferait échouer, et l'image ne reviendrait
            // pas à la restauration.
            if w == WPARAM(SIZE_MINIMIZED) { return 0 }
            let pixels = taillePixels
            echos?.fenetreRedimensionnee(largeur: pixels.largeur, hauteur: pixels.hauteur)
            echos?.fenetreDemandeUneImage()
            return 0

        case WM_DPICHANGED:
            // Le mot de poids fort porte la nouvelle densité, et `l` le rectangle
            // que Windows propose : le suivre est ce qui garde la fenêtre de la même
            // taille physique quand elle passe sur un écran plus dense.
            echelle = Double(motHaut(UInt64(w))) / 96
            if let propose = pointeur(l, RECT.self),
               let poignee {
                let r = propose.pointee
                SetWindowPos(poignee, nil, r.left, r.top,
                             r.right - r.left, r.bottom - r.top,
                             UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            echos?.fenetreChangeDEchelle(echelle)
            return 0

        case WM_PAINT:
            // On ne peint pas ici, mais il faut valider la zone : sans quoi Windows
            // renvoie `WM_PAINT` sans fin et la boucle ne rend plus la main.
            var peinture = PAINTSTRUCT()
            _ = BeginPaint(poignee, &peinture)
            EndPaint(poignee, &peinture)
            echos?.fenetreDemandeUneImage()
            return 0

        case WM_ERASEBKGND:
            // Direct3D remplit chaque pixel : laisser Windows effacer d'abord ne
            // fait que clignoter.
            return 1

        case WM_CLOSE:
            if echos?.fenetrePeutSeFermer() ?? true { DestroyWindow(poignee) }
            return 0

        case WM_DESTROY:
            poignee = nil
            PostQuitMessage(0)
            return 0

        default:
            return nil
        }
    }
}

// La procédure de fenêtre est une fonction C : elle ne capture rien, et retrouve
// son objet Swift par le champ que Windows réserve à cet usage. Le pointeur y est
// posé au tout premier message — `WM_NCCREATE`, qui précède `WM_CREATE` — sans
// quoi les messages envoyés pendant la création n'auraient personne à qui parler.
private let procedure: WNDPROC = { poignee, message, w, l in
    if message == UINT(WM_NCCREATE) {
        if let creation = pointeur(l, CREATESTRUCTW.self) {
            SetWindowLongPtrW(poignee, GWLP_USERDATA,
                              LONG_PTR(Int(bitPattern: creation.pointee.lpCreateParams)))
        }
    }
    let brut = GetWindowLongPtrW(poignee, GWLP_USERDATA)
    if brut != 0, let pointeur = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(brut))) {
        let fenetre = Unmanaged<Fenetre>.fromOpaque(pointeur).takeUnretainedValue()
        if let reponse = fenetre.repondre(message, w, l) { return reponse }
    }
    return DefWindowProcW(poignee, message, w, l)
}

extension String {
    /// Le texte tel que Win32 le veut : de l'UTF-16 terminé par un zéro.
    ///
    /// Toute l'API large en demande, et `withCString(encodedAs:)` n'ajoute pas le
    /// zéro final — d'où ce détour, qui est le seul endroit du portage où l'on y
    /// pense.
    func withUTF16Pointer<T>(_ corps: (UnsafePointer<UInt16>) -> T) -> T {
        var unites = Array(utf16)
        unites.append(0)
        return unites.withUnsafeBufferPointer { corps($0.baseAddress!) }
    }
}
