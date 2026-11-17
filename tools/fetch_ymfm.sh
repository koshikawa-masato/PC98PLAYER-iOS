#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest="$root/third_party/ymfm"
# Pin the dependency so local and CI builds use the same source.
revision=81aec25ccbb98f4873a255f7551ac4dadac59b4a
if [ ! -d "$dest/.git" ]; then
  git clone https://github.com/aaronsgiles/ymfm.git "$dest"
fi
git -C "$dest" checkout --detach "$revision"
# PC98PLAYER (iOS fork) local patch: CPU-driven ADPCM-B playback reads its
# byte stream from a host-side FIFO. Re-apply it on every fetch so the pinned
# revision stays the base. (third_party/patches/ymfm-adpcm-stream.patch)
patch_file="$root/third_party/patches/ymfm-adpcm-stream.patch"
if [ -f "$patch_file" ]; then
  git -C "$dest" checkout -- src/ymfm.h src/ymfm_adpcm.cpp
  git -C "$dest" apply "$patch_file"
fi
