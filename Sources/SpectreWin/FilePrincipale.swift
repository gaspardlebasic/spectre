import CPont

/// Exécute ce que le travail de fond a déposé sur `DispatchQueue.main`.
///
/// À appeler **une fois par tour de boucle**, avant de traiter les messages. Tout
/// ce que le modèle rend — le fichier ouvert, l'avancement de l'analyse, les
/// accords relevés — passe par cette file, et une boucle de messages Win32 ne la
/// vide pas d'elle-même. Voir `Sources/CPont/file.c` : c'est le piège qui donne
/// une fenêtre noire sans une seule erreur.
public func viderLaFilePrincipale() {
    spectre_vider_la_file_principale()
}
