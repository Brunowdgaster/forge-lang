#!/usr/bin/env bash
#
# verifica.sh — os portes do verificador inferem OS MESMOS TIPOS que a referência.
#
#   bash ports/verifica.sh              # todos os portes compilados
#   bash ports/verifica.sh ocaml        # só esse
#
# ## O contrato, e por que ele é mais severo que "aceita ou recusa"
#
# Um porte do verificador tem de produzir a **saída byte a byte idêntica** à
# implementação em Haskell em `forge types` e `forge check`, sobre os 23 casos
# de `tests/`.
#
# `forge types` imprime o tipo inferido de cada declaração **com os nomes das
# variáveis de tipo**:
#
#     compose : forall t2 t3 t4. (t3 -> t4) -> (t2 -> t3) -> t2 -> t4
#
# Casar isso obriga o porte a gerar variáveis frescas na **mesma ordem** que o
# Haskell, o que só acontece se ele percorrer a árvore na mesma ordem em cada
# regra do Algoritmo W. Um porte que inferisse os tipos certos com numeração
# diferente **falha aqui** — e é esse rigor que torna o teste uma verificação
# da implementação, e não só do resultado.
#
# É o análogo, no P02, da exigência de `.fbc` byte-idêntico nos portes do P01.
#
# ## Os três casos de erro também contam
#
# Para `tests/err/`, o porte tem de recusar com a **mensagem idêntica**,
# incluindo o nome da declaração onde o erro ocorreu e, no caso do tipo
# infinito, **o número da variável**:
#
#     forge: erro de tipo: em 'bad': tipo infinito: t0 ocorre em t0 -> t1
#
# Um porte com numeração divergente passa nos 17 casos de sucesso e falha
# neste — que é exatamente o que se quer de um teste.
#
# ## Falha alto
#
# Se o binário de um porte não existe, este script **não pula em silêncio**:
# conta como falha e diz como compilar. Harness que pula teste é harness que
# mente, e este portfólio já pagou por isso oito vezes.

set -uo pipefail

cd "$(dirname "$0")/.."

REF="${REF:-build/forge}"

# porte -> comando. Único lugar a mudar ao acrescentar uma linguagem.
declare -A CMD=(
  [ocaml]="ports/ocaml/forge_check"
  [fsharp]="dotnet ports/fsharp/bin/Release/net10.0/forge_check.dll"
)

declare -A COMO=(
  [ocaml]="cd ports/ocaml && ocamlopt -o forge_check forge_check.ml"
  [fsharp]="cd ports/fsharp && dotnet build -c Release"
)

ORDEM=(ocaml fsharp)
[ $# -gt 0 ] && ORDEM=("$@")

echo
echo "=============================================================="
echo "  Portes do verificador de tipos da forge"
echo "=============================================================="
echo

if [ ! -x "$REF" ]; then
  echo "A referência em Haskell não existe em '$REF'."
  echo "Rode: bash build.sh"
  exit 1
fi

# Os casos, em dois grupos com critérios diferentes.
mapfile -t CASOS_OK < <(ls tests/ok/*.fg tests/phase2/*.fg 2>/dev/null)
mapfile -t CASOS_ERR < <(ls tests/err/*.fg 2>/dev/null)

echo "casos de sucesso : ${#CASOS_OK[@]}  (tipos têm de bater byte a byte)"
echo "casos de erro    : ${#CASOS_ERR[@]}  (mensagem tem de bater byte a byte)"
echo

# Linha de base: a referência concorda consigo mesma e cita o esperado.
#
# A saída é CAPTURADA antes de ser filtrada, e não passada por pipe para o
# grep. Com `set -o pipefail`, o pipe falharia sempre: estes casos são de erro,
# então o `forge` sai com codigo nao-zero DE PROPOSITO, e o pipefail propaga
# isso mesmo com o grep casando. O sintoma foi "a referência não cita o erro
# esperado" para todos os seis casos, o que era falso.
for f in "${CASOS_ERR[@]}"; do
  n=$(basename "$f" .fg)
  esp=$(cat "tests/err/$n.expected")
  saida=$("$REF" check "$f" 2>&1)

  if ! grep -q "$esp" <<<"$saida"; then
    echo "FALHA NA LINHA DE BASE: a referência não cita '$esp' em $n"
    echo "  saída: $saida"
    exit 1
  fi
done
echo "linha de base (a referência cita o erro esperado em ${#CASOS_ERR[@]} casos): ok"
echo

total_falhas=0

for porte in "${ORDEM[@]}"; do
  cmd="${CMD[$porte]:-}"

  if [ -z "$cmd" ]; then
    echo "porte desconhecido: $porte"
    total_falhas=$((total_falhas + 1))
    continue
  fi

  printf '%-8s ' "$porte"

  # Verifica que o porte EXECUTA antes de contar divergências: um binário
  # ausente daria "divergiu em 23 casos", que esconde a causa real.
  if ! $cmd version >/dev/null 2>&1; then
    echo "NÃO COMPILADO — conta como falha"
    echo "         compile com: ${COMO[$porte]}"
    total_falhas=$((total_falhas + 1))
    continue
  fi

  ok=0
  falhas=()

  for f in "${CASOS_OK[@]}"; do
    a=$("$REF" types "$f" 2>&1)
    b=$($cmd types "$f" 2>&1)
    if [ "$a" = "$b" ]; then ok=$((ok + 1)); else falhas+=("$(basename "$f")"); fi
  done

  for f in "${CASOS_ERR[@]}"; do
    n=$(basename "$f" .fg)
    esp=$(cat "tests/err/$n.expected")
    a=$("$REF" check "$f" 2>&1)
    b=$($cmd check "$f" 2>&1)

    # Dois critérios: idêntico à referência E citando o erro esperado. O
    # segundo existe porque dois portes poderiam concordar numa mensagem
    # errada se ambos fossem derivados do mesmo engano.
    if [ "$a" = "$b" ] && grep -q "$esp" <<<"$b"; then
      ok=$((ok + 1))
    else
      falhas+=("$n(err)")
    fi
  done

  total=$((${#CASOS_OK[@]} + ${#CASOS_ERR[@]}))

  if [ ${#falhas[@]} -eq 0 ]; then
    echo "$ok/$total"
  else
    echo "$ok/$total  — divergiu em: ${falhas[*]}"
    total_falhas=$((total_falhas + ${#falhas[@]}))

    primeiro="${falhas[0]}"
    primeiro="${primeiro%(err)}"
    arq=$(ls tests/ok/"$primeiro" tests/phase2/"$primeiro" "tests/err/$primeiro.fg" 2>/dev/null | head -1)

    if [ -n "$arq" ]; then
      echo
      echo "         primeiro diff ($primeiro):"
      diff <("$REF" types "$arq" 2>&1) <($cmd types "$arq" 2>&1) |
        sed 's/^/           /' | head -10
      echo
    fi
  fi
done

echo
echo "=============================================================="

if [ "$total_falhas" -eq 0 ]; then
  echo "  Todos os portes inferem os mesmos tipos que a referência,"
  echo "  com os mesmos nomes de variável e as mesmas mensagens de erro."
  exit 0
else
  echo "  $total_falhas divergência(s)."
  exit 1
fi
