#!/usr/bin/env bash
# roda.sh — executa o verificador em Prolog com a mesma interface do `forge`.
#
#     ./ports/prolog/roda.sh types prog.fg
#
# O `ports/verifica.sh` chama este script como se fosse o binário de
# referência, o que mantém a comparação simétrica: os dois lados recebem
# exatamente os mesmos argumentos.
#
# ## Por que `-q` e por que `-g main -t halt` não aparecem aqui
#
# O `forge_types.pl` declara `:- initialization(main, main)`, que faz o SWI
# chamar `main/1` com os argumentos da linha de comando e sair com o código
# que ela determinar. É o equivalente Prolog de uma função `main`, e dispensa
# as opções `-g`/`-t` que aparecem em tutoriais antigos.
#
# `-q` suprime a mensagem de boas-vindas do interpretador. Sem ela, a saída
# começaria com o banner do SWI-Prolog e **toda** comparação byte a byte
# falharia — com um diff que fala de versão de Prolog num teste sobre tipos.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

achar_swipl() {
    if command -v swipl >/dev/null 2>&1; then
        command -v swipl
        return 0
    fi
    if [ -n "${SWIPL:-}" ] && [ -x "$SWIPL" ]; then
        printf '%s\n' "$SWIPL"
        return 0
    fi
    local cand
    for cand in /usr/lib/swi-prolog/bin/x86_64-linux/swipl \
                /usr/local/bin/swipl; do
        [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}

SW="$(achar_swipl)" || {
    echo 'swipl não encontrado (PATH, $SWIPL)' >&2
    exit 127
}

exec "$SW" -q "$AQUI/forge_types.pl" "$@"
