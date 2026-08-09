#!/usr/bin/env python3
"""Allège les modèles exportés sans toucher à ce qu'ils calculent.

**Tables de Fourier partagées.** La STFT réécrite du fork de Mixxx n'est pas une FFT
mais une multiplication par une base cosinus/sinus figée dans le graphe. Ces trois
tables pèsent plus de 130 Mo — et elles sont *identiques* dans les quatre réseaux.
On les sort dans un fichier unique auquel les quatre renvoient. L'opération est
exacte au bit près : `--verifier` le mesure.

La **demi-précision** était l'autre piste, et elle est écartée. Meta distribue bien
ses poids en demi-précision, si bien que les y ramener aurait dû être gratuit — mais
sur ce réseau-ci le convertisseur échoue deux fois :

- il produit un graphe invalide, où un `Sub` reçoit une entrée de chaque précision,
  et l'endroit change à chaque tentative ;
- surtout, il écrase une constante de 4,1 × 10¹¹ à 10⁴, faute de portée — la
  demi-précision plafonne à 65 504. Cette constante appartient à la normalisation de
  la transformée inverse ; la tronquer ne dégrade pas le résultat, elle le détruit.

Le drapeau `--demi-precision` reste pour qui voudrait réessayer avec un autre
convertisseur, mais il est désactivé par défaut, et à raison.
"""

import argparse
import hashlib
import pathlib
import sys

import numpy as np
import onnx
from onnx import TensorProto, numpy_helper

# Au-delà de ce seuil, un tenseur mérite d'être sorti du graphe.
BIG = 8 * 1024 * 1024
# Les décalages dans le fichier partagé sont alignés : ONNX Runtime peut alors
# projeter le fichier en mémoire au lieu de le recopier.
ALIGN = 4096


def hoist_constants(model, minimum=BIG):
    """Transforme les gros nœuds `Constant` en initialiseurs.

    Nécessaire parce que les données externes ne s'appliquent qu'aux
    initialiseurs : tant que les tables sont portées par un nœud, elles sont dans
    le graphe et il n'y a aucun moyen de les partager.
    """
    kept, hoisted = [], 0
    for node in model.graph.node:
        tensor = None
        if node.op_type == "Constant":
            for attr in node.attribute:
                if attr.type == onnx.AttributeProto.TENSOR:
                    tensor = attr.t
        if tensor is None or numpy_helper.to_array(tensor).nbytes < minimum:
            kept.append(node)
            continue
        # Un initialiseur portant le nom que produisait le nœud le remplace
        # exactement : tout ce qui lisait cette valeur la trouve toujours.
        promoted = numpy_helper.from_array(numpy_helper.to_array(tensor),
                                           name=node.output[0])
        model.graph.initializer.append(promoted)
        hoisted += 1
    del model.graph.node[:]
    model.graph.node.extend(kept)
    return hoisted


def to_float16(model):
    from onnxconverter_common import float16
    # `keep_io_types` : l'entrée et la sortie restent en simple précision, pour que
    # l'application n'ait pas à convertir ses échantillons de part et d'autre.
    #
    # L'inférence de formes est laissée active : c'est elle qui dit au convertisseur
    # où poser les conversions de type. Sans elle, il en oublie, et le modèle produit
    # est refusé au chargement — un `Mul` recevant une entrée en demi-précision et
    # l'autre en simple.
    converted = float16.convert_float_to_float16(model, keep_io_types=True)
    # Les annotations de types des valeurs intermédiaires datent d'avant la
    # conversion : elles annoncent encore de la simple précision là où les nœuds
    # produisent désormais de la demi-précision, et ONNX Runtime refuse le modèle
    # sur cette contradiction. Effacées, elles sont redéduites au chargement.
    del converted.graph.value_info[:]
    return converted


def share_big_tensors(models, blob_path, relative_name):
    """Sort les gros tenseurs communs à tous les modèles dans un fichier unique."""
    # Un tenseur n'est partagé que s'il est identique partout : on l'identifie par
    # l'empreinte de son contenu, jamais par son nom, qu'un export peut changer.
    counts = {}
    for model in models:
        seen = set()
        for init in model.graph.initializer:
            array = numpy_helper.to_array(init)
            if array.nbytes < BIG:
                continue
            digest = hashlib.sha256(array.tobytes()).hexdigest()
            if digest not in seen:
                seen.add(digest)
                counts[digest] = counts.get(digest, 0) + 1
    shared = {d for d, n in counts.items() if n == len(models)}
    if not shared:
        return {}

    placement, blob = {}, bytearray()
    for model in models:
        for init in model.graph.initializer:
            array = numpy_helper.to_array(init)
            if array.nbytes < BIG:
                continue
            digest = hashlib.sha256(array.tobytes()).hexdigest()
            if digest not in shared:
                continue
            if digest not in placement:
                blob.extend(b"\0" * ((-len(blob)) % ALIGN))
                raw = array.tobytes()
                placement[digest] = (len(blob), len(raw))
                blob.extend(raw)
            offset, length = placement[digest]
            init.ClearField("raw_data")
            for field in ("float_data", "int32_data", "int64_data", "double_data"):
                init.ClearField(field)
            init.data_location = TensorProto.EXTERNAL
            del init.external_data[:]
            for key, value in (("location", relative_name),
                               ("offset", str(offset)),
                               ("length", str(length))):
                entry = init.external_data.add()
                entry.key, entry.value = key, value
    blob_path.write_bytes(bytes(blob))
    return placement


def verify(reference, candidate, samples):
    import onnxruntime as ort

    rng = np.random.default_rng(20260809)
    signal = rng.standard_normal((1, 2, samples)).astype(np.float32) * 0.1

    def run(path):
        session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        # Le graphe a plusieurs entrées depuis que les transformées sont au dehors :
        # on les remplit toutes, en déduisant les formes du modèle lui-même.
        feed = {}
        for entry in session.get_inputs():
            if len(entry.shape) == 3:
                feed[entry.name] = signal
            else:
                feed[entry.name] = rng.standard_normal(
                    [d if isinstance(d, int) else 1 for d in entry.shape]).astype(np.float32)
        return session.run(None, feed)[0]

    before, after = run(reference), run(candidate)
    scale = float(np.abs(before).max())
    worst = float(np.abs(before - after).max())
    print(f"   amplitude de référence {scale:.4f}, écart maximal {worst:.5f}"
          f"  ({100 * worst / max(scale, 1e-9):.2f} % de l'échelle)")
    return worst, scale


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("--prefix", default="htdemucs")
    parser.add_argument("--demi-precision", dest="demi_precision", action="store_true",
                        help="convertit en demi-précision (déconseillé : voir l'en-tête)")
    parser.add_argument("--verifier", action="store_true",
                        help="compare la sortie avant et après, sur du bruit")
    parser.add_argument("--samples", type=int, default=343980)
    args = parser.parse_args()

    # `htdemucs*` attrape les deux variantes : `htdemucs.onnx` et les quatre
    # `htdemucs_ft-*.onnx`. Leurs tables de Fourier sont les mêmes — même taille de
    # fenêtre — donc une seule copie sert aux cinq.
    sources = sorted(args.directory.glob(f"{args.prefix}*.onnx"))
    sources = [p for p in sources if not p.name.endswith("-fp32.onnx")]
    if not sources:
        print(f"Aucun modèle {args.prefix}*.onnx dans {args.directory}", file=sys.stderr)
        return 1

    originals = []
    models = []
    for path in sources:
        keep = path.with_name(path.stem + "-fp32.onnx")
        if not keep.exists():
            path.rename(keep)
        originals.append(keep)
        print(f"→ {keep.name} ({keep.stat().st_size / 1e6:.0f} Mo)")
        model = onnx.load(keep)
        if args.demi_precision:
            model = to_float16(model)
        hoisted = hoist_constants(model)
        print(f"   {hoisted} table(s) sortie(s) du graphe")
        models.append(model)

    blob_name = f"{args.prefix}-fourier.bin"
    blob = args.directory / blob_name
    placement = share_big_tensors(models, blob, blob_name)
    if not placement and not args.demi_precision:
        # Plus rien de gros à partager : c'est le cas depuis que les transformées se
        # font côté Swift. On remet les fichiers en place plutôt que d'en écrire des
        # copies identiques.
        for keep, path in zip(originals, sources):
            keep.rename(path)
        print("   rien à partager : les tables de Fourier ne sont plus dans le graphe")
        return 0
    if placement:
        print(f"→ {blob_name} : {len(placement)} table(s) partagée(s),"
              f" {blob.stat().st_size / 1e6:.0f} Mo")

    total = blob.stat().st_size if placement else 0
    for path, model in zip(sources, models):
        onnx.save(model, path)
        total += path.stat().st_size
        print(f"→ {path.name} ({path.stat().st_size / 1e6:.0f} Mo)")

    before = sum(p.stat().st_size for p in originals)
    print(f"\n   {before / 1e6:.0f} Mo → {total / 1e6:.0f} Mo"
          f"  ({100 * (1 - total / before):.0f} % de moins)")

    if args.verifier:
        print("\n=== Vérification ===")
        for keep, path in zip(originals, sources):
            print(f"→ {path.name}")
            verify(keep, path, args.samples)

    return 0


if __name__ == "__main__":
    sys.exit(main())
