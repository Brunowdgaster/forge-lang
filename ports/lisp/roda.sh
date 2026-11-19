#!/usr/bin/env bash
# roda.sh — executa o verificador em Common Lisp com a interface do `forge`.
#
#     ./ports/lisp/roda.sh types prog.fg
#
# ## `--script` e por que ele é a opção certa aqui
#
# `sbcl --script arquivo` faz quatro coisas que importam para este porte:
#
#   1. carrega e executa o arquivo, sem banner e sem entrar no REPL;
#   2. **desliga o depurador** — sem isso, qualquer condição não tratada abriria
#      o depurador interativo e o processo ficaria pendurado esperando entrada
#      que nunca vem. Num teste automatizado isso aparece como travamento, e a
#      causa não é mencionada em lugar nenhum;
#   3. põe os argumentos em `sb-ext:*posix-argv*`, cujo primeiro elemento é o
#      nome do executável — daí o `(rest ...)` no `principal`;
#   4. sai com código 0 ao terminar, o que o `verifica.sh` usa como sonda.
#
# ## Por que não um `core` pré-compilado
#
# `sb-ext:save-lisp-and-die` produziria uma imagem que carrega em
# milissegundos, contra o tempo de compilar o arquivo a cada invocação. Não
# entra por duas razões: a imagem tem dezenas de megabytes, e nada neste
# projeto mede tempo — o `ports/verifica.sh` compara SAÍDA.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

achar_sbcl() {
    if command -v sbcl >/dev/null 2>&1; then
        command -v sbcl
        return 0
    fi
    if [ -n "${SBCL:-}" ] && [ -x "$SBCL" ]; then
        printf '%s\n' "$SBCL"
        return 0
    fi
    local cand
    for cand in /usr/bin/sbcl /usr/local/bin/sbcl; do
        [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}

SB="$(achar_sbcl)" || {
    echo 'sbcl não encontrado (PATH, $SBCL)' >&2
    exit 127
}

exec "$SB" --script "$AQUI/forge-check.lisp" "$@"
