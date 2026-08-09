#!/usr/bin/env python3
"""Fabrique une référence pour les transformées, telles que Demucs les emploie.

Le but n'est pas de décrire la STFT « en général » mais **celle-là** : fenêtre de
4096, saut de 1024, normalisation en 1/√N, centrage par réflexion, puis le rognage
particulier que `_spec` applique — une raie de fréquence retirée en haut, deux
trames retirées de chaque côté. Une implémentation qui se tromperait d'une seule de
ces conventions donnerait un spectrogramme plausible et faux.

Les fichiers produits sont des flottants 32 bits bruts, que le contrôle Swift relit.
"""

import pathlib
import sys

import torch
import torch.nn.functional as F

sys.path.insert(0, "build/modele/demucs-onnx")
from demucs.hdemucs import pad1d          # noqa: E402

NFFT = 4096
HOP = 1024
LENGTH = 343_980


def spec(x):
    """Reproduit `HTDemucs._spec`, chemin de référence (torch.stft)."""
    le = int(-(-x.shape[-1] // HOP))
    pad = HOP // 2 * 3
    x = pad1d(x, (pad, pad + le * HOP - x.shape[-1]), mode="reflect")
    z = torch.stft(x, NFFT, HOP,
                   window=torch.hann_window(NFFT),
                   win_length=NFFT, normalized=True, center=True,
                   return_complex=True, pad_mode="reflect")
    z = z[..., :-1, :]                    # la raie de Nyquist ne sert pas
    assert z.shape[-1] == le + 4, z.shape
    return z[..., 2:2 + le]


def ispec(z, length):
    """Reproduit `HTDemucs._ispec`."""
    z = F.pad(z, (0, 0, 0, 1))            # la raie de Nyquist, remise à zéro
    z = F.pad(z, (2, 2))                  # les deux trames de garde
    pad = HOP // 2 * 3
    le = HOP * int(-(-length // HOP)) + 2 * pad
    x = torch.istft(z, NFFT, HOP,
                    window=torch.hann_window(NFFT),
                    win_length=NFFT, normalized=True, length=le, center=True)
    return x[..., pad:pad + length]


out = pathlib.Path("build/fourier")
out.mkdir(parents=True, exist_ok=True)


def dump(name, tensor):
    array = tensor.detach().contiguous().to(torch.float32).numpy()
    (out / name).write_bytes(array.tobytes())
    print(f"   {name}  {tuple(array.shape)}")


torch.manual_seed(20260809)

# Un signal quelconque mais reproductible : ce qu'on vérifie est une convention, pas
# une musique.
x = torch.randn(1, LENGTH)
z = spec(x)
print(f"→ signal {tuple(x.shape)} → spectre {tuple(z.shape)}")
dump("signal.f32", x)
dump("spectre-reel.f32", z.real)
dump("spectre-imag.f32", z.imag)

# Pour l'inverse, on repart d'un spectre quelconque plutôt que de celui qu'on vient
# de calculer : sinon une erreur commune aux deux transformées passerait inaperçue.
zr = torch.randn(z.shape)
zi = torch.randn(z.shape)
w = torch.complex(zr, zi)
y = ispec(w, LENGTH)
print(f"→ spectre {tuple(w.shape)} → signal {tuple(y.shape)}")
dump("inverse-reel.f32", zr)
dump("inverse-imag.f32", zi)
dump("inverse-signal.f32", y)

# Et le tour complet, qui doit rendre le signal de départ.
dump("aller-retour.f32", ispec(z, LENGTH))
print(f"→ {out}")
