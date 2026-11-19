#!/usr/bin/env swipl
% forge_types.pl — o verificador de tipos do forge em Prolog.
%
%     swipl -g main -t halt ports/prolog/forge_types.pl types prog.fg
%     ou, mais curto:  bash ports/prolog/roda.sh types prog.fg
%
% Terceiro porte do verificador, depois de OCaml e F#. O contrato é o mesmo e
% é severo: **saída byte a byte idêntica** à referência em Haskell nos 23
% casos, incluindo os nomes das variáveis de tipo (`forall t2 t3 t4. ...`) e o
% texto exato das mensagens de erro.
%
% ## Por que Prolog, e a resposta não é "porque unificação é nativa"
%
% É o que parece à primeira vista: o Algoritmo W é unificação, e unificação é a
% operação primitiva de Prolog. Escrever o verificador deveria ser quase
% escrever as regras de tipo.
%
% **E é uma armadilha**, por uma razão concreta:
%
%     ?- X = f(X).
%     X = f(f(f(f(f(f(f(f(f(f(...)))))))))).
%
% A unificação padrão de Prolog (`=/2`) **não faz teste de ocorrência**. Ela
% aceita `t0 = t0 -> t1` e constrói um termo cíclico — que é exatamente o erro
% que o caso `tests/err/tipo_infinito.fg` existe para pegar, e que o
% `Types.hs` detecta à mão em `bindVar`:
%
%     | v `S.member` ftv t = Left $ "tipo infinito: " ++ v ++ ...
%
% O ISO Prolog tem `unify_with_occurs_check/2`, que faz a coisa certa. **Não é
% o padrão**, e a razão é desempenho: o teste de ocorrência é O(tamanho do
% termo) em cada ligação de variável.
%
% Então a lição do porte é o inverso da expectativa: Prolog dá unificação de
% graça, mas **a variante que um verificador de tipos precisa tem de ser pedida
% por nome.** Quem escrever um inferidor em Prolog usando `=/2` terá um
% programa que aceita `\x -> x x` e trava ao imprimir o resultado.
%
% ## E por que, ainda assim, este porte NÃO usa a unificação de Prolog
%
% Decisão deliberada, e é o ponto mais interessante do arquivo.
%
% Usar variáveis Prolog como variáveis de tipo seria idiomático e mais curto.
% Mas o contrato exige que `t0`, `t1`, `t2` apareçam **na mesma ordem** que o
% Haskell gera — e a ordem vem de um contador de estado explícito
% (`StateT Int`), percorrido numa sequência precisa em cada regra.
%
% Com variáveis Prolog, a identidade de cada variável é do motor, não minha;
% nomeá-las na ordem certa exigiria reconstruir o contador de qualquer forma,
% e aí a unificação nativa deixa de poupar trabalho — passa a atrapalhar,
% porque o `composeSubst` do Haskell tem uma ordem de composição que a
% unificação destrutiva de Prolog não expressa.
%
% Então as substituições são **explícitas**, listas de `Var-Tipo`, espelhando
% `Types.hs` linha a linha. O que Prolog contribui de verdade está no parser:
% as DCG abaixo são a gramática, não um programa que a implementa.
%
% ## Representação
%
%     tipo      ::= int | bool | tv(Nome) | fun(Tipo, Tipo)
%     esquema   ::= scheme(ListaDeVars, Tipo)
%     subst     ::= lista de Var-Tipo, com busca pela PRIMEIRA ocorrência
%     ambiente  ::= lista de Nome-Esquema
%
% A busca pela primeira ocorrência é o que torna `append/3` equivalente ao
% `M.union` do Haskell, que é *left-biased*. Chaves repetidas ficam na lista e
% são inofensivas, porque nada aqui itera sobre as chaves da substituição.

:- initialization(main, main).

:- set_prolog_flag(double_quotes, codes).

% As clausulas de `infer/6` sao interrompidas pelos fatos `aritmetico/1` e
% `comparacao/1`, que pertencem conceitualmente a regra de `bin/3`. Sem esta
% diretiva o SWI avisa que elas nao estao juntas -- um aviso correto, que aqui
% e dispensado de proposito para manter os fatos ao lado do uso.
:- discontiguous infer/6.
:- discontiguous aritmetico/1.
:- discontiguous comparacao/1.

% E `executa/1`, cujas clausulas sao separadas por `frontend/3`.
%
% Este aviso NAO e cosmetico: ele e emitido em STDERR ao carregar o arquivo, e
% o `ports/verifica.sh` compara a saida com `2>&1`. Um aviso do carregador
% apareceria DENTRO da saida comparada, e os 23 casos falhariam com um diff
% que fala de clausulas desordenadas num teste sobre tipos.
:- discontiguous executa/1.

% ===========================================================================
% LÉXICO
% ===========================================================================
%
% Tokens: int(N), ident(Atom), kw(Atom), sym(Atom).
%
% A ordem dos símbolos de dois caracteres ANTES dos de um é significativa, e o
% `Lexer.hs` tem um comentário sobre isso: se `<` fosse testado antes de `<=`,
% a entrada `<=` lexaria como `<` seguido de `=` e o erro apareceria no parser,
% longe da causa. A ordem abaixo preserva isso.

sym_duplo("<=", '<=').
sym_duplo(">=", '>=').
sym_duplo("==", '==').
sym_duplo("!=", '!=').
sym_duplo("->", '->').

sym_simples(0'\\, '\\').
sym_simples(0'+, '+').
sym_simples(0'-, '-').
sym_simples(0'*, '*').
sym_simples(0'/, '/').
sym_simples(0'%, '%').
sym_simples(0'<, '<').
sym_simples(0'>, '>').
sym_simples(0'=, '=').
sym_simples(0'(, '(').
sym_simples(0'), ')').
sym_simples(0';, ';').

palavra_chave(let). palavra_chave(rec). palavra_chave(in).
palavra_chave(if).  palavra_chave(then). palavra_chave(else).
palavra_chave(true). palavra_chave(false).

% tokenize(+Codigos, -Tokens)
tokenize([], []).
% Comentário de linha: `--` até o fim da linha.
%
% Isto vem ANTES do símbolo `-`, e tem de vir: um `--` lido como dois menos
% faria `-- comentario` virar expressão, e o erro falaria de sintaxe numa
% linha que é prosa.
tokenize([0'-, 0'-|R], T) :-
    !,
    descarta_ate_nl(R, R2),
    tokenize(R2, T).
tokenize([C|R], T) :-
    code_type(C, space), !,
    tokenize(R, T).
tokenize([C|R], [int(N)|T]) :-
    code_type(C, digit), !,
    pega_digitos([C|R], Ds, R2),
    number_codes(N, Ds),
    tokenize(R2, T).
tokenize([C|R], [Tok|T]) :-
    ( code_type(C, alpha) ; C =:= 0'_ ), !,
    pega_palavra([C|R], Ws, R2),
    atom_codes(A, Ws),
    ( palavra_chave(A) -> Tok = kw(A) ; Tok = ident(A) ),
    tokenize(R2, T).
tokenize(Cs, [sym(S)|T]) :-
    sym_duplo(Par, S),
    append(Par, R, Cs), !,
    tokenize(R, T).
tokenize([C|R], [sym(S)|T]) :-
    sym_simples(C, S), !,
    tokenize(R, T).
tokenize([C|_], _) :-
    format(atom(M), 'caractere inesperado ~c', [C]),
    throw(erro_forge(M)).

descarta_ate_nl([], []).
descarta_ate_nl([0'\n|R], [0'\n|R]) :- !.
descarta_ate_nl([_|R], S) :- descarta_ate_nl(R, S).

pega_digitos([C|R], [C|Ds], S) :- code_type(C, digit), !, pega_digitos(R, Ds, S).
pega_digitos(R, [], R).

pega_palavra([C|R], [C|Ws], S) :-
    ( code_type(C, alnum) ; C =:= 0'_ ; C =:= 0'' ), !,
    pega_palavra(R, Ws, S).
pega_palavra(R, [], R).

% ===========================================================================
% SINTAXE — como DCG, que é onde Prolog paga pelo porte
% ===========================================================================
%
% As regras abaixo são a gramática do `Parser.hs` transcritas. A diferença é
% que ali ela é um parser de descida recursiva escrito à mão, com estado de
% lista de tokens passado explicitamente; aqui a lista é implícita e as regras
% se leem como a gramática.
%
% A AST é a mesma do `Ast.hs`:
%
%     lit_int(N) | lit_bool(B) | var(Nome) | lam(Nome, Corpo)
%     app(F, A) | neg(A) | bin(Op, A, B) | if(C, A, B) | seq(A, B)
%     let(Rec, Nome, Rhs, Corpo)

% programa(-Decls)
programa([D|Ds]) --> [kw(let)], !, decl_resto(D), programa(Ds).
programa([]) --> [].

decl_resto(decl(Rec, Nome, Params, Corpo)) -->
    ( [kw(rec)] -> { Rec = true } ; { Rec = false } ),
    [ident(Nome)],
    params(Params),
    [sym('=')],
    expr(Corpo).

params([P|Ps]) --> [ident(P)], !, params(Ps).
params([]) --> [].

% Nenhum separador entre declarações de topo, e o `Parser.hs` explica por quê:
% uma expressão só pode ser ESTENDIDA por operador infixo ou por aplicação, e
% `let` não inicia um átomo. Então encontrar `let` ao fim de um corpo só pode
% ser declaração nova. A gramática fica sem `;;` sem ficar ambígua.

expr(E) --> [kw(if)], !, expr(C), [kw(then)], expr(A), [kw(else)], expr(B),
            { E = if(C, A, B) }.
expr(E) --> [kw(let)], !, let_resto(E).
expr(E) --> [sym('\\')], !, [ident(X)], [sym('->')], expr(B), { E = lam(X, B) }.
expr(E) --> seq_expr(E).

let_resto(let(Rec, Nome, Rhs, Corpo)) -->
    ( [kw(rec)] -> { Rec = true } ; { Rec = false } ),
    [ident(Nome)],
    params(Ps),
    [sym('=')],
    expr(Rhs0),
    [kw(in)],
    expr(Corpo),
    % Os parâmetros são currificados AQUI, ao contrário das declarações de
    % topo: um `let` local nunca é alvo de `CALL` direto, então a aridade não
    % precisa ser preservada. É o que o `Parser.hs` faz com `foldr ELam`.
    { enrola_lams(Ps, Rhs0, Rhs) }.

enrola_lams([], E, E).
enrola_lams([P|Ps], E0, lam(P, E)) :- enrola_lams(Ps, E0, E).

% `;` associa à DIREITA e tem a precedência mais baixa.
seq_expr(E) --> cmp_expr(L), ( [sym(';')] -> expr(R), { E = seq(L, R) } ; { E = L } ).

% Comparações NÃO associam: `a < b < c` é erro de sintaxe, e não um
% encadeamento silenciosamente errado como em C.
rel_op('<', lt). rel_op('<=', le). rel_op('>', gt).
rel_op('>=', ge). rel_op('==', eq). rel_op('!=', ne).

cmp_expr(E) --> add_expr(L),
    (   [sym(S)], { rel_op(S, Op) }
    ->  add_expr(R), { E = bin(Op, L, R) }
    ;   { E = L }
    ).

add_expr(E) --> mul_expr(L), add_loop(L, E).
add_loop(L, E) --> [sym('+')], !, mul_expr(R), add_loop(bin(add, L, R), E).
add_loop(L, E) --> [sym('-')], !, mul_expr(R), add_loop(bin(sub, L, R), E).
add_loop(L, L) --> [].

mul_expr(E) --> unary_expr(L), mul_loop(L, E).
mul_loop(L, E) --> [sym('*')], !, unary_expr(R), mul_loop(bin(mul, L, R), E).
mul_loop(L, E) --> [sym('/')], !, unary_expr(R), mul_loop(bin(dv, L, R), E).
mul_loop(L, E) --> [sym('%')], !, unary_expr(R), mul_loop(bin(md, L, R), E).
mul_loop(L, L) --> [].

unary_expr(neg(E)) --> [sym('-')], !, unary_expr(E).
unary_expr(E) --> app_expr(E).

% Aplicação: justaposição de átomos, associando à ESQUERDA.
app_expr(E) --> atomo(F), args(As), { enrola_apps(F, As, E) }.

enrola_apps(F, [], F).
enrola_apps(F, [A|As], E) :- enrola_apps(app(F, A), As, E).

args([A|As]) --> comeca_atomo, !, atomo(A), args(As).
args([]) --> [].

% `comeca_atomo` olha o próximo token SEM consumi-lo. É o `startsAtom` do
% Haskell, e existe para que `f x` seja aplicação e `f + x` não seja.
comeca_atomo, [T] --> [T], { comeca_atomo_tok(T) }.
comeca_atomo_tok(int(_)).
comeca_atomo_tok(ident(_)).
comeca_atomo_tok(kw(true)).
comeca_atomo_tok(kw(false)).
comeca_atomo_tok(sym('(')).

atomo(lit_int(N))     --> [int(N)], !.
atomo(lit_bool(true)) --> [kw(true)], !.
atomo(lit_bool(false))--> [kw(false)], !.
atomo(var(X))         --> [ident(X)], !.
atomo(E)              --> [sym('(')], !, expr(E), [sym(')')].

% ===========================================================================
% TIPOS, SUBSTITUIÇÕES E UNIFICAÇÃO — espelho de Types.hs
% ===========================================================================

% applyT(+Subst, +Tipo, -Tipo)
applyT(S, tv(V), T)      :- ( memberchk(V-T0, S) -> T = T0 ; T = tv(V) ).
applyT(S, fun(A, B), fun(A2, B2)) :- applyT(S, A, A2), applyT(S, B, B2).
applyT(_, int, int).
applyT(_, bool, bool).

% applyS(+Subst, +Esquema, -Esquema)
%
% As variáveis quantificadas são REMOVIDAS da substituição antes de aplicar:
% elas estão ligadas pelo próprio esquema, e substituí-las seria captura de
% variável. É o `foldr M.delete s vs` do Haskell.
applyS(S, scheme(Vs, T), scheme(Vs, T2)) :-
    exclude([V-_]>>memberchk(V, Vs), S, S2),
    applyT(S2, T, T2).

applyEnv(S, Env, Env2) :-
    maplist([N-Sc, N-Sc2]>>applyS(S, Sc, Sc2), Env, Env2).

% compose(+S1, +S2, -S)  ==  composeSubst s1 s2  ==  aplica s2, depois s1
%
% `M.map (applyT s1) s2 `M.union` s1`, e o `M.union` do Haskell é LEFT-BIASED:
% as entradas de s2 (já mapeadas) vencem as de s1.
%
% Com busca pela primeira ocorrência, `append` dá o mesmo resultado. A ORDEM
% desta composição é o bug clássico de implementações de Hindley-Milner, e o
% comentário do `Types.hs` diz o sintoma: um programa que devia inferir
% `forall a. a -> a` infere `Int -> Int`.
compose(S1, S2, S) :-
    maplist([V-T, V-T2]>>applyT(S1, T, T2), S2, S2m),
    append(S2m, S1, S).

compose_todos([S], S) :- !.
compose_todos([S|Ss], R) :- compose_todos(Ss, R0), compose(S, R0, R).

% ftv(+Tipo, -VarsOrdenadas)
%
% O resultado é ORDENADO e sem repetição, porque o Haskell usa `Data.Set` e o
% `S.toList` dele devolve em ordem crescente. É isso que fixa a ordem do
% `forall t2 t3 t4`, e `sort/2` do Prolog faz o mesmo (ordem padrão de átomos,
% que para `t0`, `t1`, ... é a lexicográfica).
ftv(T, Vs) :- ftv_(T, L), sort(L, Vs).
ftv_(tv(V), [V]).
ftv_(fun(A, B), L) :- ftv_(A, LA), ftv_(B, LB), append(LA, LB, L).
ftv_(int, []).
ftv_(bool, []).

ftv_scheme(scheme(Vs, T), R) :- ftv(T, Fs), subtract(Fs, Vs, R).

ftv_env(Env, Vs) :-
    foldl([_-Sc, Ac, Ac2]>>( ftv_scheme(Sc, F), append(Ac, F, Ac2) ),
          Env, [], L),
    sort(L, Vs).

% generalize(+Env, +Tipo, -Esquema)
%
% Fecha as variáveis livres do tipo que NÃO aparecem no ambiente. A condição
% sobre o ambiente é o que impede generalizar a variável de um parâmetro de
% função — seria incorreto, porque quem escolhe o tipo dela é o chamador.
generalize(Env, T, scheme(Vs, T)) :-
    ftv(T, Ft), ftv_env(Env, Fe), subtract(Ft, Fe, Vs).

% unify(+A, +B, -Subst) — com teste de ocorrência, como o Haskell faz à mão.
%
% Note que NÃO é `A = B`: ver o cabeçalho deste arquivo. A unificação nativa de
% Prolog não faria o teste de ocorrência, e `unify_with_occurs_check/2` faria —
% mas nenhuma das duas produz a SUBSTITUIÇÃO explícita que o `composeSubst`
% exige.
unify(int, int, []) :- !.
unify(bool, bool, []) :- !.
unify(fun(L1, R1), fun(L2, R2), S) :- !,
    unify(L1, L2, S1),
    applyT(S1, R1, R1b), applyT(S1, R2, R2b),
    unify(R1b, R2b, S2),
    compose(S2, S1, S).
unify(tv(V), T, S) :- !, liga_var(V, T, S).
unify(T, tv(V), S) :- !, liga_var(V, T, S).
unify(A, B, _) :-
    pretty_type(A, PA), pretty_type(B, PB),
    format(atom(M), 'nao consegui unificar ~w com ~w', [PA, PB]),
    throw(erro_forge(M)).

liga_var(V, tv(V), []) :- !.
liga_var(V, T, _) :-
    ftv(T, Fs), memberchk(V, Fs), !,
    pretty_type(T, P),
    format(atom(M), 'tipo infinito: ~w ocorre em ~w', [V, P]),
    throw(erro_forge(M)).
liga_var(V, T, [V-T]).

% ===========================================================================
% INFERÊNCIA — Algoritmo W, espelho de Infer.hs
% ===========================================================================
%
% O contador de variáveis frescas é passado explicitamente (N0 -> N), que é o
% que o `StateT Int` faz em Haskell. Ele é ÚNICO para o programa inteiro: o
% `inferProgram` roda todas as declarações num só `runInfer`, e é por isso que
% o primeiro tipo de `composicao.fg` começa em `t2` e não em `t0`.

fresh(N0, tv(V), N) :- N is N0 + 1, atom_concat(t, N0, V).

% instantiate: uma variável fresca por variável quantificada, NA ORDEM da
% lista. É o que permite usar a mesma função polimórfica em dois tipos
% diferentes no mesmo programa.
instantiate(scheme(Vs, T), N0, T2, N) :-
    foldl([V, Ac0-Ni0, [V-Tv|Ac0]-Ni]>>fresh(Ni0, Tv, Ni), Vs, []-N0, Sub-N),
    applyT(Sub, T, T2).

builtins([print-scheme([], fun(int, int)),
          gc-scheme([], fun(int, int))]).

% infer(+Env, +Expr, +N0, -Subst, -Tipo, -N)
infer(_, lit_int(_), N, [], int, N).
infer(_, lit_bool(_), N, [], bool, N).

infer(Env, var(X), N0, [], T, N) :-
    (   memberchk(X-Sc, Env)
    ->  instantiate(Sc, N0, T, N)
    ;   format(atom(M), 'variavel nao definida: ~w', [X]),
        throw(erro_forge(M))
    ).

infer(Env, lam(X, Corpo), N0, S1, fun(TvA, T1), N) :-
    fresh(N0, Tv, N1),
    infer([X-scheme([], Tv)|Env], Corpo, N1, S1, T1, N),
    applyT(S1, Tv, TvA).

infer(Env, app(F, A), N0, S, T, N) :-
    infer(Env, F, N0, S1, Tf, N1),
    applyEnv(S1, Env, Env1),
    infer(Env1, A, N1, S2, Ta, N2),
    fresh(N2, Tv, N),
    applyT(S2, Tf, Tf2),
    unify(Tf2, fun(Ta, Tv), S3),
    compose_todos([S3, S2, S1], S),
    applyT(S3, Tv, T).

infer(Env, neg(A), N0, S, int, N) :-
    infer(Env, A, N0, S1, T1, N),
    unify(T1, int, S2),
    compose(S2, S1, S).

infer(Env, bin(Op, A, B), N0, S, T, N) :-
    infer(Env, A, N0, S1, T1, N1),
    applyEnv(S1, Env, Env1),
    infer(Env1, B, N1, S2, T2, N),
    applyT(S2, T1, T1b),
    (   aritmetico(Op)
    ->  unify(T1b, int, Sa),
        applyT(Sa, T2, T2b), unify(T2b, int, Sb),
        compose_todos([Sb, Sa, S2, S1], S), T = int
    ;   comparacao(Op)
    ->  unify(T1b, int, Sa),
        applyT(Sa, T2, T2b), unify(T2b, int, Sb),
        compose_todos([Sb, Sa, S2, S1], S), T = bool
    ;   % Igualdade UNIFICA os dois lados em vez de exigir Int: permite
        % comparar Bool com Bool, e a instrução EQ do bytecode já faz isso.
        % O que ela não permite é comparar Int com Bool, que é o erro real.
        applyT(S2, T2, T2c),
        unify(T1b, T2c, Sa),
        compose_todos([Sa, S2, S1], S), T = bool
    ).

aritmetico(add). aritmetico(sub). aritmetico(mul). aritmetico(dv). aritmetico(md).
comparacao(lt). comparacao(le). comparacao(gt). comparacao(ge).

infer(Env, if(C, A, B), N0, S, T, N) :-
    infer(Env, C, N0, S1, Tc, N1),
    unify(Tc, bool, S2),
    compose(S2, S1, S12),
    applyEnv(S12, Env, Env1),
    infer(Env1, A, N1, S3, Ta, N2),
    applyEnv(S3, Env1, Env2),
    infer(Env2, B, N2, S4, Tb, N),
    applyT(S4, Ta, Ta2),
    unify(Ta2, Tb, S5),
    compose_todos([S5, S4, S3, S12], S),
    applyT(S5, Tb, T).

infer(Env, seq(A, B), N0, S, T2, N) :-
    infer(Env, A, N0, S1, _, N1),
    applyEnv(S1, Env, Env1),
    infer(Env1, B, N1, S2, T2, N),
    compose(S2, S1, S).

% let NÃO recursivo: generaliza o tipo do rhs ANTES de ligar o nome, o que é
% de onde vem o polimorfismo do let.
infer(Env, let(false, X, Rhs, Corpo), N0, S, T2, N) :-
    infer(Env, Rhs, N0, S1, T1, N1),
    applyEnv(S1, Env, Env1),
    generalize(Env1, T1, Sc),
    infer([X-Sc|Env1], Corpo, N1, S2, T2, N),
    compose(S2, S1, S).

% let rec: o nome entra no ambiente como MONOMÓRFICO (variável fresca)
% enquanto o próprio rhs é inferido, e só depois é generalizado. Generalizar
% antes permitiria que a função usasse a si mesma em dois tipos diferentes, o
% que Hindley-Milner não garante decidível.
infer(Env, let(true, X, Rhs, Corpo), N0, S, T3, N) :-
    fresh(N0, Tv, N1),
    infer([X-scheme([], Tv)|Env], Rhs, N1, S1, T1, N2),
    applyT(S1, Tv, Tv2),
    unify(Tv2, T1, S2),
    compose(S2, S1, Sx),
    applyEnv(Sx, Env, Env1),
    applyT(Sx, T1, T1b),
    generalize(Env1, T1b, Sc),
    infer([X-Sc|Env1], Corpo, N2, S3, T3, N),
    compose(S3, Sx, S).

% ---------------------------------------------------------------- programa
%
% Declarações são processadas EM ORDEM: uma função só vê as anteriores. É
% escolha e não limitação acidental — torna a inferência um passe único e
% obriga a declarar antes de usar.

infer_programa(Decls, Tipos) :-
    builtins(B),
    foldl(infer_uma, Decls, B-0-[], _-_-Rev),
    reverse(Rev, Tipos).

infer_uma(decl(Rec, Nome, Params, Corpo), Env-N0-Ac, Env2-N-[Nome-Sc|Ac]) :-
    catch(
        infer_decl(Env, Rec, Nome, Params, Corpo, N0, Sc, N),
        erro_forge(M),
        ( format(atom(M2), 'em \'~w\': ~w', [Nome, M]),
          throw(erro_forge(M2)) )
    ),
    Env2 = [Nome-Sc|Env].

infer_decl(Env, Rec, Nome, Params, Corpo, N0, Sc, N) :-
    enrola_lams(Params, Corpo, Body),
    (   Rec == true
    ->  fresh(N0, Tv, N1),
        infer([Nome-scheme([], Tv)|Env], Body, N1, S1, T1, N),
        applyT(S1, Tv, Tv2),
        unify(Tv2, T1, S2),
        compose(S2, S1, S),
        applyEnv(S, Env, EnvS), applyT(S, T1, T1b),
        generalize(EnvS, T1b, Sc)
    ;   infer(Env, Body, N0, S1, T1, N),
        applyEnv(S1, Env, EnvS),
        generalize(EnvS, T1, Sc)
    ).

% ===========================================================================
% IMPRESSÃO — byte a byte igual ao prettyType/prettyScheme do Haskell
% ===========================================================================
%
% A regra de parênteses: o lado ESQUERDO de uma função é impresso com
% parênteses se for ele mesmo uma função; o lado direito nunca leva, porque
% `->` associa à direita. É o `go paren` do Haskell.

% ATENCAO: aqui os literais sao ATOMOS entre apostrofos, e nao strings entre
% aspas duplas -- porque o `:- set_prolog_flag(double_quotes, codes)` no topo
% deste arquivo vale para o arquivo INTEIRO.
%
% A primeira versao usava `"Int"` e `string_concat/3`, e quebrou em 11 dos 23
% casos com:
%
%     string_concat/3: Type error: `atomic' expected,
%                      found `[73,110,116]' (a list)
%
% `[73,110,116]` e "Int" em codigos. A flag existe para o LEXER, onde
% `sym_duplo("<=", '<=')` precisa casar uma lista de codigos com `append/3`;
% e o preco e que todo literal de impressao do arquivo tambem virou lista.
%
% E o erro aponta para `string_concat/3` na linha 69, que e o `main/1` -- a
% mensagem fala do tipo errado numa funcao de concatenacao, e nao da diretiva
% no topo que mudou o significado de todas as aspas do arquivo. Usar atomos
% resolve de uma vez: eles nao dependem da flag.
pretty_type(T, A) :- pt(false, T, A).

pt(_, int, 'Int').
pt(_, bool, 'Bool').
pt(_, tv(V), V).
pt(Paren, fun(A, B), S) :-
    pt(true, A, SA), pt(false, B, SB),
    atomic_list_concat([SA, ' -> ', SB], Inner),
    (   Paren == true
    ->  atomic_list_concat(['(', Inner, ')'], S)
    ;   S = Inner
    ).

pretty_scheme(scheme([], T), A) :- !, pretty_type(T, A).
pretty_scheme(scheme(Vs, T), A) :-
    atomic_list_concat(Vs, ' ', Q),
    pretty_type(T, PT),
    format(atom(A), 'forall ~w. ~w', [Q, PT]).

% ===========================================================================
% PONTO DE ENTRADA
% ===========================================================================

main(Argv) :-
    catch(executa(Argv), erro_forge(M), falha(M)).

falha(M) :-
    format(user_error, 'forge: ~w~n', [M]),
    halt(1).

% `version` existe porque o `ports/verifica.sh` o usa como SONDA: antes de
% contar divergencias, ele checa que o porte EXECUTA. Um porte ausente ou que
% nao carrega daria "divergiu em 23 casos", que esconde a causa real.
%
% A saida nao e comparada com a da referencia -- o verifica.sh redireciona --
% mas o formato segue o dela de proposito, para que rodar o porte a mao nao
% surpreenda.
executa([version]) :- !,
    format('forge-prolog (porte do verificador)~n', []).

% `frontend` e o caminho comum de `check` e `types`, e existe separado pelo
% mesmo motivo que no `Main.hs` do Haskell: as duas opcoes leem, lexam,
% parseiam, exigem `main` e inferem -- e so divergem no que IMPRIMEM.
%
% Ter um so lugar para isso importa aqui mais que de costume: o `verifica.sh`
% compara `types` nos 17 casos de sucesso e `check` nos 6 de erro. Se a
% checagem de `main` estivesse so no caminho de `types`, o caso `sem_main.fg`
% -- que roda por `check` -- passaria sem verificar nada.
%
% E foi exatamente esse o defeito da primeira versao deste arquivo: ela
% implementava `types` e nao `check`, entao os 6 casos de erro caiam na
% mensagem de uso. O diff que o verifica.sh mostrou veio VAZIO, porque ele
% compara as saidas de `types` quando mostra o primeiro diff -- e nessas elas
% eram identicas. O relatorio dizia 17/23 com diff vazio, que e a assinatura
% de "o criterio que falhou nao e o que esta sendo mostrado".
frontend(Caminho, Decls, Tipos) :-
    (   catch(read_file_to_codes(Caminho, Cs, []), _, fail)
    ->  true
    ;   format(atom(M), '~w: nao consegui ler o arquivo', [Caminho]),
        throw(erro_forge(M))
    ),
    tokenize(Cs, Toks),
    (   phrase(programa(Decls), Toks, [])
    ->  true
    ;   throw(erro_forge('erro de sintaxe'))
    ),
    % "o programa precisa de main" é regra de boa-formação do PROGRAMA, não do
    % backend — então ela é verificada aqui, antes da inferência, e a mensagem
    % cita o caminho do arquivo. O caso `sem_main.fg` fixa isso.
    (   memberchk(decl(_, main, _, _), Decls)
    ->  true
    ;   format(atom(M2), '~w: o programa precisa de uma declaracao \'main\'',
               [Caminho]),
        throw(erro_forge(M2))
    ),
    catch(infer_programa(Decls, Tipos), erro_forge(E),
          ( format(atom(M3), 'erro de tipo: ~w', [E]),
            throw(erro_forge(M3)) )).

executa([types, Caminho]) :- !,
    frontend(Caminho, _, Tipos),
    forall(member(Nome-Sc, Tipos),
           ( pretty_scheme(Sc, P), format('~w : ~w~n', [Nome, P]) )).

executa([check, Caminho]) :- !,
    frontend(Caminho, Decls, _),
    length(Decls, N),
    format('ok: ~w declaracoes, tipos conferem~n', [N]).

executa(_) :-
    format(user_error, 'uso: forge_types.pl {check|types|version} <prog.fg>~n',
           []),
    halt(64).
