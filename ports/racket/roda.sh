#!/usr/bin/env bash
# roda.sh — executa o verificador em Racket com a interface do `forge`.
#
#     ./ports/racket/roda.sh types prog.fg
#
# ## Por que `racket` e não um executável compilado
#
# O Racket compila para bytecode (`raco make`) e para binário autocontido
# (`raco exe`), e nenhum dos dois entra aqui:
#
#   * `raco make` só acelera a carga, e o que ele produz (`compiled/*.zo`)
#     teria de ser ignorado pelo git ou versionado — e versionar bytecode num
#     repositório que compara código-fonte seria ruído;
#   * `raco exe` produz um binário de dezenas de megabytes, porque embute a
#     máquina virtual. Para um verificador de 23 casos, o ganho é nada.
#
# O custo é o tempo de carga do módulo a cada invocação, e ele não é medido
# por nada neste projeto: o `ports/verifica.sh` compara SAÍDA, não tempo.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

achar_racket() {
    if command -v racket >/dev/null 2>&1; then
        command -v racket
        return 0
    fi
    if [ -n "${RACKET:-}" ] && [ -x "$RACKET" ]; then
        printf '%s\n' "$RACKET"
        return 0
    fi
    local cand
    for cand in /usr/bin/racket /usr/local/bin/racket \
                "$HOME/.local/share/racket/bin/racket"; do
        [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}

RK="$(achar_racket)" || {
    echo 'racket não encontrado (PATH, $RACKET)' >&2
    exit 127
}

exec "$RK" "$AQUI/forge-check.rkt" "$@"
