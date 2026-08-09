#!/bin/bash
# Fabrique les réseaux de Demucs au format ONNX, pour que l'application les embarque
# et n'ait plus besoin ni de Python ni de PyTorch. Deux variantes :
#   htdemucs_ft — quatre réseaux affinés, un par piste, meilleur mais quatre passages
#   htdemucs    — un seul réseau qui rend les quatre pistes d'un coup
#
# À lancer **une fois**. Le résultat va dans Resources/, que .gitignore écarte :
# les poids de Demucs ne sont pas couverts par la licence MIT du code — leur auteur
# les dit « fournis à des fins scientifiques uniquement », parce qu'ils sont
# entraînés sur MUSDB18. Les convertir pour son propre usage ne pose pas de
# question ; les rediffuser, si. D'où le refus de les verser au dépôt.
#
# Tout ce qui est téléchargé ici l'est depuis les serveurs de Meta, à l'adresse que
# le code de Demucs utilise lui-même.
set -euo pipefail
cd "$(dirname "$0")"

WORK=build/modele
VENV="$WORK/venv"
mkdir -p "$WORK"

# Le fork emploie `enum.StrEnum`, qui n'existe qu'à partir de Python 3.11 : on prend
# donc le premier interpréteur assez récent plutôt que le `python3` du système, qui
# peut être plus ancien.
PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
    PYTHON="$candidate"; break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "Échec : il faut Python 3.11 ou plus récent." >&2
  exit 1
fi

if [ ! -d "$VENV" ] || ! "$VENV/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  echo "→ environnement Python jetable dans $VENV ($("$PYTHON" -V))"
  rm -rf "$VENV"
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
fi

# Demucs tel quel **ne s'exporte pas** : sa STFT et son inverse travaillent sur des
# tenseurs complexes, que ONNX ne sait pas représenter. C'est l'obstacle qui a
# occupé tout un GSoC chez Mixxx ; on reprend leur travail plutôt que de le refaire.
# Leur fork réécrit les deux transformées en paires sinus/cosinus et ajoute un
# drapeau `onnx_exportable` qui bascule le modèle sur ce chemin.
FORK="$WORK/demucs-onnx"
if [ ! -d "$FORK/.git" ]; then
  echo "→ fork Mixxx/GSoC (dhunstack/demucs, branche allchanges)"
  git clone --quiet --branch allchanges --depth 20 \
    https://github.com/dhunstack/demucs.git "$FORK"
else
  git -C "$FORK" fetch --quiet origin allchanges
  git -C "$FORK" checkout --quiet --force allchanges
fi

# Notre correctif : le réseau reçoit le spectre au lieu de le calculer, et rend le
# spectre masqué plus la branche temporelle. Les transformées se font côté Swift,
# avec Accelerate — ce qui retire du graphe 128 Mo de tables de Fourier et remplace
# une multiplication matricielle en N² par une FFT en N log N.
git -C "$FORK" apply "$PWD/Tools/Fourier/spectre-externe.patch"

# Toujours vérifié, pas seulement à la création : l'environnement peut dater d'un
# passage où il manquait une dépendance. Rien de tout cela ne survit à la
# conversion — l'application n'exécute que du Swift et ONNX Runtime.
"$VENV/bin/pip" install --quiet torch onnx onnxscript
# Le fork remplace `demucs` : installé en dernier, et en mode « édition » pour que
# ce soit bien son code qui s'exécute et non celui du paquet publié.
"$VENV/bin/pip" install --quiet -e "$FORK"

echo "→ conversion (téléchargement des poids au premier passage)"
"$VENV/bin/python" - <<'PY'
import pathlib
import torch
from torch.nn import functional as F
from demucs.pretrained import get_model

# PyTorch 2.9 aiguille `nn.MultiheadAttention` vers un noyau fusionné,
# `_native_multi_head_attention`, qui n'a pas d'équivalent ONNX. Désactivé, le
# module repasse par ses opérations élémentaires — mêmes calculs, mêmes poids,
# simplement écrits d'une façon qui s'exporte. Le fork de Mixxx n'avait pas à s'en
# soucier : ce chemin rapide n'existait pas dans les versions qu'il visait.
torch.backends.mha.set_fastpath_enabled(False)

out = pathlib.Path("Resources")
out.mkdir(exist_ok=True)


def export(model, target):
    """Fige un réseau sur une tranche de la taille qu'il a apprise."""
    model.eval()
    # Le drapeau du fork bascule la STFT sur des tenseurs réels — nécessaire pour que
    # `_spec` reste traçable, puisqu'on s'en sert encore pour fabriquer l'exemple.
    model.onnx_exportable = True
    # Le nôtre sort les transformées du graphe.
    model.external_spectrogram = True
    length = int(model.segment * model.samplerate)
    mix = F.pad(torch.randn(1, model.audio_channels, 343980), (0, length - 343980))
    with torch.no_grad():
        spec = model._spec(mix)
    target.unlink(missing_ok=True)          # pas de reste d'un essai précédent
    print(f"   {target.name}  (tranche {length}, spectre {tuple(spec.shape)})", flush=True)
    with torch.no_grad():
        # `dynamo=False` : le chemin par traçage, celui qu'ont employé les gens de
        # Mixxx. L'exportateur récent de torch 2.9 bute en amont, sur une taille
        # calculée dans `pad1d` qu'il ne sait pas trancher.
        torch.onnx.export(model, (mix, spec), str(target),
                          export_params=True, opset_version=17,
                          do_constant_folding=True, dynamo=False,
                          input_names=["mix", "spec"],
                          output_names=["zout", "xt"])


def core(bag):
    return bag.models[0] if hasattr(bag, "models") else bag


# `htdemucs_ft` : un sac de quatre réseaux, un par piste. Sa matrice de pondération
# est l'identité, donc le réseau i ne sert qu'à la source i — on les nomme par la
# piste dont chacun a la charge.
bag = get_model("htdemucs_ft")
sources = bag.models[0].sources        # ['drums', 'bass', 'other', 'vocals']
assert len(bag.models) == len(sources), "le sac n'a pas quatre réseaux"
print("→ htdemucs_ft : quatre réseaux affinés")
for model, source in zip(bag.models, sources):
    export(model, out / f"htdemucs_ft-{source}.onnx")

# `htdemucs` : un seul réseau, qui rend les quatre pistes d'un coup. Un peu moins
# bon, mais un seul passage sur le morceau au lieu de quatre.
print("→ htdemucs : un seul réseau")
export(core(get_model("htdemucs")), out / "htdemucs.onnx")
PY

echo "→ allègement : demi-précision et tables de Fourier partagées"
"$VENV/bin/pip" install --quiet onnxconverter_common onnxruntime
"$VENV/bin/python" Tools/ModelPack/pack.py Resources --verifier

# Les originaux en simple précision ne servent plus qu'à revérifier : ils quittent
# Resources/, où ils doubleraient inutilement l'empreinte sur le disque.
mkdir -p "$WORK/fp32"
mv -f Resources/htdemucs*-fp32.onnx "$WORK/fp32/" 2>/dev/null || true

echo
# Le sac n'est utilisable qu'entier : sortir en succès avec trois fichiers, ou
# aucun, laisserait croire que le modèle est prêt.
COUNT=$(ls Resources/htdemucs_ft-*.onnx 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" -ne 4 ] || [ ! -f Resources/htdemucs.onnx ]; then
  echo "Échec : $COUNT réseau(x) affiné(s) sur 4, htdemucs simple $([ -f Resources/htdemucs.onnx ] && echo présent || echo absent)."
  exit 1
fi
ls -lh Resources/htdemucs*.onnx Resources/*.bin
echo "→ relancer ./build.sh pour les embarquer dans l'application"
