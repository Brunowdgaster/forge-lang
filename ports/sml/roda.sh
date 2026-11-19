#!/usr/bin/env bash
# roda.sh — compila (se preciso) e executa o verificador em Standard ML.
#
#     ./ports/sml/roda.sh types prog.fg
#
# ## Por que este runner COMPILA, e os de Prolog/Racket/Lisp não
#
# MLton é um compilador de programa inteiro: ele produz um binário nativo
# autocontido, e não há interpretador para invocar. Então o runner tem de
# garantir que o binário existe antes de usá-lo.
#
# A compilação é feita **uma vez**, e só se o fonte for mais novo que o
# binário. Fazer isso aqui, e não no `ports/verifica.sh`, mantém a suíte
# simétrica: todos os portes são chamados do mesmo jeito, e cada um resolve
# sozinho como chegar ao executável.
#
# ## E por que MLton e não Poly/ML
#
# Os dois estão instalados e os dois compilam este arquivo. MLton foi escolhido
# por produzir um binário único sem dependência de runtime, o que torna o porte
# comparável ao de OCaml (`ocamlopt`) — que também produz nativo.
#
# Poly/ML (`polyc`) também produziria um binário, mas a diferença interessante
# dele está no REPL e na persistência de imagem, que não é o que este porte
# mede.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FONTE="$AQUI/forge-check.sml"
BIN="$AQUI/forge_check"

achar_mlton() {
    if command -v mlton >/dev/null 2>&1; then
        command -v mlton
        return 0
    fi
    if [ -n "${MLTON:-}" ] && [ -x "$MLTON" ]; then
        printf '%s\n' "$MLTON"
        return 0
    fi
    [ -x /usr/bin/mlton ] && { printf '%s\n' /usr/bin/mlton; return 0; }
    return 1
}

# Recompila só se o fonte mudou. O `-nt` compara datas de modificação, e a
# ausência do binário também entra no teste — `[ ! -x "$BIN" ]` vem primeiro
# porque `-nt` com um arquivo inexistente é verdadeiro por acidente e não por
# intenção.
if [ ! -x "$BIN" ] || [ "$FONTE" -nt "$BIN" ]; then
    MLTON="$(achar_mlton)" || {
        echo 'mlton não encontrado e o binário não existe' >&2
        exit 127
    }
    # A saída do compilador vai para stderr do runner e não é silenciada: se a
    # compilação falhar, quem chamou precisa ver o motivo. Silenciar aqui faria
    # o `verifica.sh` reportar "não compilado" sem dizer por quê — que é
    # exatamente o padrão de falha que este portfólio registrou onze vezes.
    ( cd "$AQUI" && "$MLTON" -output forge_check forge-check.sml ) >&2 || exit 1
fi

exec "$BIN" "$@"
