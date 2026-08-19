import AVFoundation
import Accelerate
import Foundation
import OnnxRuntimeBindings
import SpectreCore

/// Séparation par Demucs v4, exécutée par ONNX Runtime.
///
/// Le réseau travaille sur une **tranche de taille fixe** — 7,8 s de stéréo à
/// 44,1 kHz — parce que c'est ainsi qu'il a été entraîné et exporté. Séparer un
/// morceau consiste donc à le découper, appliquer le réseau tranche par tranche, et
/// recoller le tout en fondu enchaîné.
///
/// Un seul réseau rend les quatre pistes, en un parcours du morceau.
public struct DemucsSeparator: StemSeparator {
    /// Passer par le GPU, ou rester sur les cœurs.
    ///
    /// Ce n'est pas un réglage offert à l'usage — le GPU gagne partout — mais le
    /// moyen de **comparer les deux chemins**, ce que `SeparationCheck` fait sur un
    /// signal connu. Une accélération dont on ne peut pas mesurer l'écart avec la
    /// route lente n'est qu'une promesse.
    public var accelerated = true

    public init(accelerated: Bool = true) { self.accelerated = accelerated }

    /// Longueur de la tranche, en échantillons : `segment × samplerate` du modèle.
    public static let segment = 343_980
    public static let sampleRate = 44_100.0
    public static let channels = 2
    /// Recouvrement entre tranches voisines, comme dans Demucs.
    public static let overlap = 0.25

    // **Les tranches restent en file, une à la fois — et c'est un choix mesuré, non
    // une occasion manquée.** Le GPU n'est pas saturé par une seule tranche : deux
    // menées de front la ramènent de 0,27 s à 0,16 s. Mais elles ne peuvent pas
    // partager une session — le fournisseur CoreML de cette version d'ONNX Runtime
    // n'est pas sûr en concurrence, et deux appels simultanés rendent des valeurs
    // fausses, jusqu'à 3,9 % de l'échelle, jamais deux fois les mêmes (le défaut est
    // réparé en amont, mais le paquet Swift s'arrête à la 1.24). Et deux sessions
    // coûtent chacune leur jeu de poids compilés : neuf secondes de chargement de
    // plus et 5,5 Go de mémoire vive, pour un gain qui ne rembourse ces neuf
    // secondes qu'au-delà de cinq minutes et demie de musique. Sur un morceau de
    // trois minutes c'est une perte sèche — 22 s au lieu de 15.

    public func separate(fileAt url: URL,
                  progress: @escaping (SeparationProgress) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> SeparatedStems {
        guard StemStore.hasModel else { throw SeparationFailure.modelMissing }

        progress(SeparationProgress(fraction: 0, stage: "Lecture du morceau…"))
        var mix = try Self.loadForNetwork(url)
        let length = mix[0].count
        guard length > 0 else { throw SeparationFailure.engine("morceau vide") }

        // Demucs travaille sur un signal recentré et réduit, et rend le résultat à
        // la même échelle. Les deux scalaires sont calculés sur la moyenne des
        // canaux, comme dans `separate.py` — pas canal par canal, ce qui
        // déplacerait l'image stéréo.
        let (mean, deviation) = Self.moments(of: mix)
        let shift = Float(-mean), scale = Float(1 / deviation)
        for c in 0..<mix.count {
            // Un seul tampon en entrée **et** en sortie d'un appel vDSP est un
            // accès exclusif violé : Swift n'est alors tenu à rien, et ce qui en
            // sort ici était `nan` de bout en bout. On passe donc par un pointeur
            // unique, qui décrit exactement l'opération sur place voulue.
            mix[c].withUnsafeMutableBufferPointer { buffer in
                let p = buffer.baseAddress!
                var s = shift, m = scale
                vDSP_vsadd(p, 1, &s, p, 1, vDSP_Length(length))
                vDSP_vsmul(p, 1, &m, p, 1, vDSP_Length(length))
            }
        }
        guard mix[0].allSatisfy(\.isFinite) else {
            throw SeparationFailure.engine("signal d'entrée non exploitable")
        }

        let step = Int(Double(Self.segment) * (1 - Self.overlap))
        let starts = Array(stride(from: 0, to: length, by: step))
        let window = Self.transitionWindow()

        let environment: ORTEnv
        do {
            environment = try ORTEnv(loggingLevel: .warning)
        } catch {
            throw SeparationFailure.engine("environnement ONNX indisponible — \(error.localizedDescription)")
        }

        // L'ouverture du réseau est le long moment muet : huit à neuf secondes pour
        // relire les 625 Mo de la compilation, une demi-minute quand il faut d'abord
        // la produire. Il n'y a rien à mesurer là-dedans — c'est un seul appel qui
        // rend la main quand il a fini — mais on peut au moins dire lequel des deux
        // est en cours, et que le second n'arrive qu'une fois.
        progress(SeparationProgress(fraction: 0, stage: Self.loadingStage(accelerated)))
        let session = try Self.session(in: environment, accelerated: accelerated)
        guard let fourier = DemucsFourier() else {
            throw SeparationFailure.engine("transformée de Fourier indisponible")
        }

        // Un accumulateur par piste : le réseau les rend toutes ensemble.
        var sums = Stem.separated.map { _ in
            [[Float]](repeating: [Float](repeating: 0, count: length), count: Self.channels)
        }
        var weights = [Float](repeating: 0, count: length)
        var done = 0.0

        for start in starts {
            if isCancelled() { throw SeparationFailure.cancelled }
            let count = min(Self.segment, length - start)
            let voices = try Self.apply(session, fourier: fourier,
                                        to: mix, from: start, count: count)

            // Fondu enchaîné : chaque tranche est pesée par une fenêtre
            // triangulaire, et l'on divise à la fin par la somme des poids. Sans
            // cela, la couture s'entendrait toutes les 5,8 s.
            for (source, _) in Stem.separated.enumerated() {
                for c in 0..<Self.channels {
                    let voice = voices[source * Self.channels + c]
                    sums[source][c].withUnsafeMutableBufferPointer { out in
                        for i in 0..<count { out[start + i] += window[i] * voice[i] }
                    }
                }
            }
            for i in 0..<count { weights[start + i] += window[i] }

            done += 1
            progress(SeparationProgress(fraction: done / Double(starts.count),
                                        stage: "Séparation des pistes…"))
        }

        var result: [Stem: [[Float]]] = [:]
        for (source, stem) in Stem.separated.enumerated() {
            // Normalisation par les poids et retour à l'échelle d'origine, en un
            // seul passage.
            for c in 0..<Self.channels {
                for i in 0..<length {
                    let w = weights[i]
                    sums[source][c][i] = w > 0
                        ? sums[source][c][i] / w * Float(deviation) + Float(mean) : 0
                }
            }
            // Une piste non finie ne doit jamais atteindre le disque : elle
            // s'écrirait sans bruit, se relirait sans erreur, et ne se verrait
            // qu'au moment où le spectrogramme resterait noir.
            guard sums[source].allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
                throw SeparationFailure.engine("piste « \(stem.label) » non finie")
            }
            result[stem] = sums[source]
        }
        // **44,1 kHz, quoi qu'on ait ouvert.** Le réseau a appris là et `loadForNetwork`
        // y ramène tout ; les pistes rendues n'ont donc pas la fréquence du fichier
        // d'origine, et le dire est le seul moyen qu'elles s'écrivent juste.
        return SeparatedStems(sampleRate: Self.sampleRate, channels: result)
    }

    /// Ce qu'on affiche pendant l'ouverture du réseau.
    ///
    /// Compiler ou relire ne se ressemblent pas — une demi-minute contre huit
    /// secondes — et l'attente longue mérite d'être annoncée comme telle, sans quoi
    /// elle passe pour une panne. On le sait d'avance : il suffit de regarder si une
    /// compilation attend déjà dans le dossier.
    private static func loadingStage(_ accelerated: Bool) -> String {
        guard accelerated, let model = StemStore.modelFile,
              let cache = compiledModelFolder(for: model) else {
            return "Ouverture du réseau…"
        }
        let compiled = (try? FileManager.default.contentsOfDirectory(atPath: cache.path))?
            .isEmpty == false
        return compiled
            ? "Ouverture du réseau…"
            : "Compilation du réseau pour cette machine — une seule fois…"
    }

    // MARK: Une tranche

    /// Applique le réseau à une tranche et rend ses huit voies — quatre sources,
    /// deux canaux.
    ///
    /// Le graphe ne fait plus les transformées : on lui donne le spectre en même
    /// temps que la forme d'onde — dont sa branche temporelle a besoin — et il rend
    /// le spectre masqué plus cette branche. La transformée inverse et le recollement
    /// des deux branches se font ici.
    private static func apply(_ session: ORTSession, fourier: DemucsFourier,
                              to mix: [[Float]],
                              from start: Int, count: Int) throws -> [[Float]] {
        // La tranche est complétée par du silence quand on arrive au bout : le
        // réseau n'accepte qu'une taille, celle sur laquelle il a été figé.
        var flat = [Float](repeating: 0, count: channels * segment)
        for c in 0..<channels {
            mix[c].withUnsafeBufferPointer { source in
                flat.withUnsafeMutableBufferPointer { destination in
                    (destination.baseAddress! + c * segment)
                        .update(from: source.baseAddress! + start, count: count)
                }
            }
        }

        // Le spectre, rangé comme PyTorch : (canal, raie, trame, réel/imaginaire).
        let bins = DemucsFourier.bins
        let frames = DemucsFourier.frames(for: segment)
        let plane = bins * frames
        var spec = [Float](repeating: 0, count: channels * plane * 2)
        for c in 0..<channels {
            let (real, imaginary) = fourier.spectrogram(
                of: Array(flat[c * segment..<(c + 1) * segment]))
            let base = c * plane * 2
            for k in 0..<plane {
                spec[base + k * 2] = real[k]
                spec[base + k * 2 + 1] = imaginary[k]
            }
        }

        let mixData = NSMutableData(bytes: &flat, length: flat.count * MemoryLayout<Float>.size)
        let specData = NSMutableData(bytes: &spec, length: spec.count * MemoryLayout<Float>.size)
        let inputs = [
            "mix": try ORTValue(tensorData: mixData, elementType: .float,
                                shape: [1, NSNumber(value: channels), NSNumber(value: segment)]),
            "spec": try ORTValue(tensorData: specData, elementType: .float,
                                 shape: [1, NSNumber(value: channels), NSNumber(value: bins),
                                         NSNumber(value: frames), 2]),
        ]
        let outputs = try session.run(withInputs: inputs,
                                      outputNames: ["zout", "xt"], runOptions: nil)
        guard let zout = outputs["zout"], let xt = outputs["xt"] else {
            throw SeparationFailure.engine("le réseau n'a rien rendu")
        }
        let spectra = try zout.tensorData() as Data
        let temporal = try xt.tensorData() as Data

        let voices = Stem.separated.count * channels
        guard spectra.count >= voices * plane * 2 * MemoryLayout<Float>.size,
              temporal.count >= voices * segment * MemoryLayout<Float>.size else {
            throw SeparationFailure.engine("sortie de taille inattendue")
        }

        return spectra.withUnsafeBytes { zBytes -> [[Float]] in
            temporal.withUnsafeBytes { tBytes -> [[Float]] in
                let z = zBytes.bindMemory(to: Float.self)
                let t = tBytes.bindMemory(to: Float.self)
                var real = [Float](repeating: 0, count: plane)
                var imaginary = [Float](repeating: 0, count: plane)
                return (0..<voices).map { v in
                    let base = v * plane * 2
                    for k in 0..<plane {
                        real[k] = z[base + k * 2]
                        imaginary[k] = z[base + k * 2 + 1]
                    }
                    // Les deux branches se rejoignent ici, comme le faisait la
                    // dernière ligne du réseau.
                    let spectral = fourier.signal(real: real, imaginary: imaginary,
                                                  length: segment)
                    var voice = [Float](repeating: 0, count: count)
                    let offset = v * segment
                    for i in 0..<count { voice[i] = spectral[i] + t[offset + i] }
                    return voice
                }
            }
        }
    }

    /// Où CoreML garde le réseau compilé pour cette machine.
    ///
    /// Le dossier porte l'**empreinte du modèle**, et pas seulement son nom. ONNX
    /// Runtime, lui, range sa compilation sous le condensé du *chemin* du fichier, et
    /// prévient qu'il ne vérifie jamais que le modèle n'a pas changé depuis : poser un
    /// autre jeu de poids sous le même nom lui ferait resservir l'ancienne
    /// compilation, en silence et sans que rien ne sonne faux — sauf les pistes.
    /// L'empreinte referme ce trou.
    ///
    /// C'est la même que celle qui rattache une session à un morceau : taille, début
    /// et fin. Elle se calcule instantanément, là où hacher les 166 Mo du réseau
    /// coûterait une demi-seconde à chaque séparation.
    private static func compiledModelFolder(for model: URL) -> URL? {
        guard let root = Storage.root,
              let print = SessionStore.fingerprint(of: model) else { return nil }
        let folder = root.appendingPathComponent("coreml/\(print.prefix(16))",
                                                 isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var compiledRoot: URL? {
        Storage.root?.appendingPathComponent("coreml", isDirectory: true)
    }

    /// Combien de compilations on garde en tout.
    ///
    /// Une compilation pèse 625 Mo. Deux, parce qu'il en existe normalement deux à la
    /// fois : le réseau embarqué dans l'application, et le même relu depuis son autre
    /// emplacement par les vérifications — ONNX Runtime en range une par chemin. Les
    /// garder toutes deux évite de recompiler une demi-minute à chaque aller-retour ;
    /// la troisième chasse la plus ancienne plutôt que de s'ajouter.
    private static let keptCompilations = 2

    /// Ramène le dossier aux deux compilations les plus récemment servies.
    ///
    /// Le tri se fait sur les feuilles, sans égard pour le modèle dont elles
    /// viennent : une compilation devenue inutile — modèle remplacé, moteur mis à
    /// jour — sort d'elle-même quand deux autres ont servi depuis. Sans cela ce
    /// dossier ne ferait que grossir, et six cents mégaoctets par entrée se
    /// remarquent.
    private static func pruneCompiled(keeping current: URL) {
        let manager = FileManager.default
        let now = Date()
        // Celle qui vient de servir est marquée d'emblée : ONNX Runtime ne touche pas
        // aux fichiers qu'il relit, si bien que sans cela l'entrée la plus utile
        // vieillirait tout autant qu'une abandonnée.
        if let used = try? manager.contentsOfDirectory(at: current,
                                                       includingPropertiesForKeys: nil) {
            for url in used {
                try? manager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            }
        }

        guard let root = compiledRoot,
              let folders = try? manager.contentsOfDirectory(at: root,
                                                             includingPropertiesForKeys: nil)
        else { return }
        var leaves = [(URL, Date)]()
        for folder in folders {
            let entries = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in entries {
                let when = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                leaves.append((url, when ?? .distantPast))
            }
        }
        for (url, _) in leaves.sorted(by: { $0.1 > $1.1 }).dropFirst(keptCompilations) {
            try? manager.removeItem(at: url)
        }
        // Un dossier de modèle vidé de ses compilations n'a plus de raison d'être.
        for folder in folders
        where ((try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? false) {
            try? manager.removeItem(at: folder)
        }
    }

    /// La session, **sur le GPU** quand la machine et le modèle le permettent.
    ///
    /// CoreML avait été écarté, et à raison à l'époque : il calcule en demi-précision,
    /// et le graphe portait alors une constante de 4,1 × 10¹¹ — la normalisation de la
    /// transformée inverse — qui déborde des 65 504 que ce format supporte. Elle
    /// devenait infinie, et toute la piste avec.
    ///
    /// Cette constante **a quitté le graphe** le jour où les transformées de Fourier
    /// sont passées côté Swift : le réseau reçoit le spectre et rend le spectre, il
    /// n'a plus d'inverse à normaliser. Le plus grand nombre qu'il porte encore vaut
    /// 10⁴ — la période des plongements du transformeur — soit six fois sous le
    /// plafond. Le verrou est tombé avec la refonte, pas avec CoreML.
    ///
    /// Mesuré sur M2 Max, une tranche de 7,8 s : **1,07 s sur les douze cœurs,
    /// 0,27 s sur le GPU**, et l'écart sur la sortie vaut 0,07 % de son amplitude —
    /// −63 dB, très en dessous de ce que la séparation elle-même laisse passer.
    /// Le moteur neuronal a été mesuré aussi : 0,70 s, deux fois et demie plus lent
    /// que le GPU sur ce réseau-là, et plus long à compiler. D'où `CPUAndGPU` plutôt
    /// que `All`, qui rend le même temps de calcul pour trente secondes de
    /// compilation de plus.
    private static func session(in environment: ORTEnv,
                                accelerated: Bool) throws -> ORTSession {
        guard let file = StemStore.modelFile else {
            throw SeparationFailure.modelMissing
        }
        // Le GPU d'abord ; le processeur si quoi que ce soit s'y oppose. Une machine
        // sans CoreML, un cache impossible à écrire, une version de macOS qui refuse
        // le graphe : rien de tout cela ne doit empêcher de séparer un morceau — cela
        // le rend seulement quatre fois plus long.
        if accelerated {
            if let session = try? acceleratedSession(in: environment, model: file) {
                return session
            }
            // Un cache écrit par une autre version d'ONNX Runtime ne se relit pas :
            // le chargement échoue sur un nœud manquant. Vérifié en changeant de
            // version à la main — sans cela, une mise à jour du moteur ferait tomber
            // la séparation sur le processeur pour toujours, sans rien dire. On jette
            // et on recompile ; c'est une demi-minute, une seule fois.
            if let cache = compiledModelFolder(for: file) {
                try? FileManager.default.removeItem(at: cache)
                if let session = try? acceleratedSession(in: environment, model: file) {
                    return session
                }
            }
        }
        do {
            return try ORTSession(env: environment, modelPath: file.path,
                                  sessionOptions: try ORTSessionOptions())
        } catch {
            throw SeparationFailure.modelUnreadable(error.localizedDescription)
        }
    }

    private static func acceleratedSession(in environment: ORTEnv,
                                           model: URL) throws -> ORTSession {
        guard ORTIsCoreMLExecutionProviderAvailable(),
              let cache = compiledModelFolder(for: model) else {
            throw SeparationFailure.engine("CoreML indisponible")
        }
        let options = try ORTSessionOptions()
        // `MLProgram` et non le format hérité : c'est lui qui accepte les opérations
        // dont ce graphe se sert, et le seul que le cache sache garder.
        //
        // Sans ce cache, chaque séparation recommencerait la compilation du réseau —
        // une demi-minute avant la première note. Avec, c'est neuf secondes de
        // relecture, une fois par morceau, contre les six cents mégaoctets que le
        // dossier pèse.
        try options.appendCoreMLExecutionProvider(withOptionsV2: [
            "ModelFormat": "MLProgram",
            "MLComputeUnits": "CPUAndGPU",
            "ModelCacheDirectory": cache.path,
        ])
        let session = try ORTSession(env: environment, modelPath: model.path,
                                     sessionOptions: options)
        // Après coup : celle qui vient de servir porte la date la plus récente, et
        // ne risque donc pas d'être celle qu'on jette.
        pruneCompiled(keeping: cache)
        return session
    }

    // MARK: Préparation du signal

    /// Fenêtre triangulaire de recollement, telle que Demucs la construit : elle
    /// monte jusqu'au milieu puis redescend, si bien que deux tranches voisines se
    /// relaient sans saut.
    public static func transitionWindow() -> [Float] {
        let half = segment / 2
        var window = [Float](repeating: 0, count: segment)
        for i in 0..<half { window[i] = Float(i + 1) }
        for i in half..<segment { window[i] = Float(segment - i) }
        let peak = Float(half)
        for i in 0..<segment { window[i] /= peak }
        return window
    }

    /// Moyenne et écart-type du signal moyenné sur les canaux.
    ///
    /// Calculés à la main plutôt qu'avec `vDSP_normalize`, dont la variante sans
    /// tampon de sortie n'est pas ce qu'on croit — et en double précision, parce
    /// qu'une somme de dix millions de carrés en simple précision perd ses derniers
    /// chiffres bien avant la fin.
    public static func moments(of mix: [[Float]]) -> (Double, Double) {
        let length = mix[0].count
        guard length > 0, !mix.isEmpty else { return (0, 1) }
        var total = 0.0, totalSquares = 0.0
        for i in 0..<length {
            var averaged = 0.0
            for channel in mix { averaged += Double(channel[i]) }
            averaged /= Double(mix.count)
            total += averaged
            totalSquares += averaged * averaged
        }
        let mean = total / Double(length)
        let variance = max(totalSquares / Double(length) - mean * mean, 0)
        let deviation = variance.squareRoot()
        // Un signal parfaitement plat donnerait un écart-type nul : on ne divise
        // pas par lui.
        return (mean, deviation > 1e-8 ? deviation : 1)
    }

    /// Charge le morceau tel que le réseau l'attend : stéréo, 44,1 kHz, flottant.
    ///
    /// Le rééchantillonnage n'est pas une politesse — le réseau a appris à cette
    /// fréquence-là, et lui donner du 48 kHz reviendrait à lui présenter une musique
    /// transposée d'un demi-ton et jouée trop vite.
    public static func loadForNetwork(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw SeparationFailure.engine("format d'entrée inutilisable") }

        let block: AVAudioFrameCount = 1 << 16
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: block),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: block * 2)
        else { throw SeparationFailure.engine("tampons indisponibles") }

        var result = [[Float]](repeating: [], count: channels)
        var finished = false
        while !finished {
            var failure: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &failure) { _, outStatus in
                input.frameLength = 0
                if file.framePosition < file.length {
                    try? file.read(into: input, frameCount: block)
                }
                if input.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let failure { throw SeparationFailure.engine(failure.localizedDescription) }

            let produced = Int(output.frameLength)
            if produced > 0, let data = output.floatChannelData {
                for c in 0..<channels {
                    result[c].append(contentsOf:
                        UnsafeBufferPointer(start: data[c], count: produced))
                }
            }
            if status == .endOfStream || status == .error { finished = true }
            if status == .inputRanDry && produced == 0 { finished = true }
        }
        guard !result[0].isEmpty else { throw SeparationFailure.engine("aucun échantillon lu") }
        return result
    }
}
