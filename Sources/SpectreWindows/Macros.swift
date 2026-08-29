import WinSDK

// Ce que Win32 écrit en macros, et que Swift ne peut donc pas importer.
//
// Swift importe les fonctions, les types et les constantes entières simples d'un
// en-tête C, mais pas ses macros. Or Win32 en est truffé : `IDC_ARROW` est un
// entier transtypé en pointeur, `HIWORD` un décalage, `MAKELPARAM` un assemblage.
// Les rassembler ici plutôt que de les récrire à chaque usage évite le pire des
// deux mondes — la même formule écrite deux fois, subtilement différemment.
//
// Chacune porte la définition d'origine en commentaire : c'est ce qu'on veut
// pouvoir comparer quand un comportement paraît décalé d'un pixel ou d'un bit.

/// `MAKEINTRESOURCEW(i)` — un identifiant numérique là où l'API veut une chaîne.
func ressource(_ identifiant: Int) -> UnsafePointer<WCHAR>? {
    UnsafePointer<WCHAR>(bitPattern: UInt(identifiant))
}

/// `IDC_ARROW`, le curseur ordinaire.
let curseurFleche = ressource(32512)

/// `HIWORD(x)` — les seize bits de poids fort.
func motHaut(_ valeur: UInt64) -> Int { Int((valeur >> 16) & 0xFFFF) }
/// `LOWORD(x)` — les seize bits de poids faible.
func motBas(_ valeur: UInt64) -> Int { Int(valeur & 0xFFFF) }

/// `GET_X_LPARAM(lp)` / `GET_Y_LPARAM(lp)` — la position de la souris.
///
/// **Les deux sont signées**, et c'est le piège : la souris passe en coordonnées
/// négatives dès qu'on tire hors de la fenêtre, ce qui arrive à chaque fois qu'on
/// trace une boucle jusqu'au bord. Les lire en non signé donne alors 65 000, et le
/// geste part à l'autre bout de l'écran.
func positionX(_ l: LPARAM) -> Int { Int(Int16(truncatingIfNeeded: l)) }
func positionY(_ l: LPARAM) -> Int { Int(Int16(truncatingIfNeeded: l >> 16)) }

/// Le pointeur que Windows passe dans un `LPARAM`.
func pointeur<T>(_ l: LPARAM, _ type: T.Type) -> UnsafeMutablePointer<T>? {
    UnsafeMutablePointer<T>(bitPattern: Int(l))
}

/// La cadence de l'écran, en hertz, telle que Windows la déclare.
///
/// Le relevé de fluidité s'en sert pour dire combien d'images ont manqué leur tour.
/// Il vit maintenant dans `SpectreDessin`, partagé avec Linux, et cette ligne-ci est
/// tout ce qu'il restait de Windows dedans.
func cadenceDeLEcran() -> Double {
    var mode = DEVMODEW()
    mode.dmSize = WORD(MemoryLayout<DEVMODEW>.size)
    // `ENUM_CURRENT_SETTINGS` vaut −1, et c'est une macro : Swift ne l'importe pas.
    let obtenu = EnumDisplaySettingsW(nil, DWORD(bitPattern: -1), &mode)
    return obtenu ? Double(mode.dmDisplayFrequency) : 0
}

/// Dort au plus `secondes`, et **se réveille dès qu'une entrée arrive**.
///
/// `Sleep` ne conviendrait pas : au repos, la boucle dort un dixième de seconde
/// entre deux images, et un `Sleep` ferait attendre ce dixième-là au premier clic.
/// `MsgWaitForMultipleObjectsEx` rend la main à la première molette, au premier
/// mouvement de souris, à la première touche — la latence du geste reste donc
/// celle d'une boucle à pleine cadence, alors que le coût est celui d'une boucle
/// arrêtée. Voir `SpectreDessin/Cadence.swift`.
///
/// `QS_ALLINPUT` et `MWMO_INPUTAVAILABLE` sont des macros, et sont donc récrites
/// ici — la seconde importe autant que la première : sans elle, un message déjà
/// dans la file au moment de l'appel ne réveille rien, et la boucle dort alors
/// pendant qu'un geste attend.
func dormirJusquAUneEntree(_ secondes: Double) {
    // QS_ALLINPUT = QS_INPUT | QS_POSTMESSAGE | QS_TIMER | QS_PAINT | QS_HOTKEY
    //             | QS_SENDMESSAGE
    let toutesLesEntrees = DWORD(0x04FF)
    let dejaLa = DWORD(0x0004)              // MWMO_INPUTAVAILABLE
    _ = MsgWaitForMultipleObjectsEx(0, nil, DWORD(max(secondes, 0) * 1000),
                                    toutesLesEntrees, dejaLa)
}
