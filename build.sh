#!/usr/bin/env bash
# build.sh — compila o forge com o ghc, sem cabal e sem rede.
#
# O compilador usa apenas base, containers e mtl, que vem com o GHC. Por isso
# nao ha resolucao de dependencias: um unico comando ghc basta. Um .cabal
# existe em hs/forge.cabal para quem preferir, mas nao e necessario.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build

ghc -O2 -Wall \
    -ihs/src \
    -outputdir build/obj \
    -o build/forge \
    hs/app/Main.hs

echo
./build/forge version
echo "binario: build/forge"
