import Foundation
#if os(Windows)
import CPont
#endif

/// Exécute ce que le travail de fond a déposé sur `DispatchQueue.main`.
///
/// À appeler **une fois par tour de boucle**. Tout ce que le modèle rend — le
/// fichier ouvert, l'avancement de l'analyse, les accords relevés, la batterie —
/// passe par cette file, et aucune des deux boucles d'évènements ne la vide
/// d'elle-même. C'est le piège qui donne une fenêtre noire, ou bloquée sur
/// « Lecture du fichier… », sans une seule erreur — payé une fois sous Windows, et
/// une seconde fois sous Linux faute d'avoir vu que c'était le même.
///
/// Les deux réponses diffèrent, et c'est irréductible. Sous Windows, libdispatch
/// expose une fonction qui vide la file et rend la main ; elle n'est dans aucun
/// en-tête de la distribution, d'où le détour par `Sources/CPont/file.c`. Sous
/// Linux, c'est `RunLoop` qui la draine, et il suffit de la laisser tourner un
/// instant.
public func viderLaFilePrincipale() {
    #if os(Windows)
    spectre_vider_la_file_principale()
    #else
    // Une milliseconde : assez pour que ce qui attend parte, trop peu pour que la
    // boucle d'images s'en aperçoive.
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
    #endif
}
