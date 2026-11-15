#!/usr/bin/env bash
# run_tests.sh — suíte do forge, em quatro partes.
#
#   uso: bash tests/run_tests.sh [caminho/forge] [caminho/fvm]
#
# As quatro partes, e por que cada uma existe:
#
#   ok/      compila, roda na VM do P01 e compara a saída. É o teste de ponta
#            a ponta: linguagem -> bytecode -> execução.
#   err/     o VERIFICADOR DE TIPOS tem de recusar, com a mensagem esperada.
#            Testar o que o compilador rejeita é tão importante quanto testar
#            o que ele aceita — um verificador que aceita tudo passa em
#            qualquer suíte de programas válidos.
#   phase2/  `forge check` tem de ACEITAR e `forge build` tem de recusar
#            citando a Fase 2. É o que prova que a limitação está no backend e
#            não no sistema de tipos; se um dia o check passar a recusar, a
#            suíte acusa a regressão.
#   bytes    o mesmo programa montado pelo forge e pelo montador em C do P01
#            tem de dar bytes idênticos. Garante que o gerador de código não
#            divergiu do formato .fbc.
set -u

FORGE=${1:-"$(dirname "$0")/../build/forge"}
VM=${2:-"$(dirname "$0")/../../p01-metal-vm/build-switch/fvm"}
HERE=$(cd "$(dirname "$0")" && pwd)

[ -x "$FORGE" ] || { echo "forge nao encontrado em $FORGE; rode bash build.sh" >&2; exit 2; }
[ -x "$VM" ]    || { echo "fvm nao encontrado em $VM; compile o P01 primeiro"  >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()   { printf 'ok   %-24s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad()  { printf 'FAIL %-24s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# ----------------------------------------------------------------- ok/
echo "--- ok: compila, roda, compara saida ---"
for src in "$HERE"/ok/*.fg; do
    name=$(basename "$src" .fg)
    exp="${src%.fg}.expected"
    [ -f "$exp" ] || continue

    if ! "$FORGE" build "$src" -o "$TMP/$name.fbc" 2>"$TMP/$name.err"; then
        bad "$name" "forge build falhou: $(head -1 "$TMP/$name.err")"
        continue
    fi
    got=$("$VM" exec "$TMP/$name.fbc" 2>/dev/null)
    if [ "$got" = "$(cat "$exp")" ]; then
        ok "$name"
    else
        bad "$name" "esperado [$(tr '\n' '|' < "$exp")] obtido [$(printf '%s' "$got" | tr '\n' '|')]"
    fi
done

# ----------------------------------------------------------------- err/
echo
echo "--- err: o verificador de tipos tem de recusar ---"
for src in "$HERE"/err/*.fg; do
    name=$(basename "$src" .fg)
    exp="${src%.fg}.expected"
    [ -f "$exp" ] || continue
    want=$(cat "$exp")

    if "$FORGE" check "$src" >/dev/null 2>"$TMP/$name.err"; then
        bad "$name" "aceitou um programa que devia recusar"
    elif grep -qF "$want" "$TMP/$name.err"; then
        ok "$name" "recusou: $want"
    else
        bad "$name" "recusou, mas sem '$want': $(head -1 "$TMP/$name.err")"
    fi
done

# ----------------------------------------------------------------- phase2/
echo
echo "--- phase2: check aceita, build recusa ---"
for src in "$HERE"/phase2/*.fg; do
    name=$(basename "$src" .fg)
    exp="${src%.fg}.expected"
    [ -f "$exp" ] || continue
    want=$(cat "$exp")

    if ! "$FORGE" check "$src" >/dev/null 2>"$TMP/$name.chk"; then
        bad "$name" "o verificador recusou um programa bem tipado: $(head -1 "$TMP/$name.chk")"
        continue
    fi
    if "$FORGE" build "$src" -o "$TMP/$name.fbc" 2>"$TMP/$name.err"; then
        bad "$name" "o backend gerou codigo que nao deveria conseguir gerar"
    elif grep -qF "$want" "$TMP/$name.err"; then
        ok "$name" "tipou, nao baixou (correto)"
    else
        bad "$name" "recusou sem citar '$want': $(head -1 "$TMP/$name.err")"
    fi
done

# ----------------------------------------------------------------- bytes
echo
echo "--- bytes: forge e o montador do P01 concordam ---"
for src in "$HERE"/ok/*.fg; do
    name=$(basename "$src" .fg)

    "$FORGE" build "$src" -o "$TMP/$name.direto.fbc" 2>/dev/null || continue
    "$FORGE" emit "$src" > "$TMP/$name.fasm" 2>/dev/null || continue
    "$VM" asm "$TMP/$name.fasm" -o "$TMP/$name.viaC.fbc" 2>/dev/null || {
        bad "$name" "o montador do P01 recusou o .fasm gerado"
        continue
    }
    if cmp -s "$TMP/$name.direto.fbc" "$TMP/$name.viaC.fbc"; then
        ok "$name" "bytes identicos"
    else
        bad "$name" "bytes divergem entre forge e montador do P01"
        cmp "$TMP/$name.direto.fbc" "$TMP/$name.viaC.fbc" || true
    fi
done

echo
echo "$pass passaram, $fail falharam"
[ "$fail" -eq 0 ]
