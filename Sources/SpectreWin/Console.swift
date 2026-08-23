import CPont

/// Récupère la console du terminal qui a lancé l'application, quand il y en a une.
///
/// À appeler **avant tout ce qui écrit**, y compris avant de lire les arguments :
/// un message d'erreur émis plus tôt partirait dans le vide.
///
/// L'application est liée en sous-système « fenêtre » — c'est ce qui empêche
/// Windows d'ouvrir un terminal noir à côté d'elle au double-clic. Le revers est
/// qu'elle n'hérite alors d'aucune console, et que les instruments du dépôt
/// (`--photo`, `--fluidite`, `--rendu`) écriraient leur relevé nulle part. Le
/// détail des trois pièges est dans `Sources/CPont/console.c`.
public func rattacherLaConsole() {
    _ = spectre_console_rattacher()
}
