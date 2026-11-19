# Portes do verificador de tipos

O mesmo Algoritmo W em **quatro linguagens** — Haskell (a referência), OCaml,
F# e **Prolog** — com saída **byte a byte idêntica** nos 23 casos de `tests/`.

```
bash ports/verifica.sh            # 23 casos × 3 portes contra a referência
bash ports/verifica.sh prolog     # só esse
```

As três primeiras são da mesma família (ML). O Prolog **não é**, e é por isso
que ele entrou: ver [o porte em Prolog](#o-porte-em-prolog-e-a-armadilha-que-eu-esperava-atalho).

## O porte em Prolog, e a armadilha que eu esperava ser atalho

A expectativa era óbvia: o Algoritmo W **é** unificação, unificação é a
operação primitiva de Prolog, então o porte deveria ser quase transcrever as
regras de tipo.

**A expectativa estava errada por dois motivos independentes**, e os dois são
mais interessantes que o atalho que eu esperava.

### 1. A unificação de Prolog é a errada para isto

```prolog
?- X = f(X).
X = f(f(f(f(f(f(f(f(f(f(...)))))))))).
```

O `=/2` **não faz teste de ocorrência**. Ele aceita `t0 = t0 -> t1` e constrói
um termo cíclico — que é exatamente o erro que `tests/err/tipo_infinito.fg`
existe para pegar, e que o `Types.hs` detecta à mão:

```haskell
| v `S.member` ftv t = Left $ "tipo infinito: " ++ v ++ " ocorre em " ++ ...
```

O ISO Prolog tem `unify_with_occurs_check/2`, que faz a coisa certa. **Não é o
padrão**, e a razão é desempenho: o teste é O(tamanho do termo) a cada ligação.

> Prolog dá unificação de graça, mas **a variante que um verificador de tipos
> precisa tem de ser pedida por nome.** Quem escrever um inferidor com `=/2`
> terá um programa que aceita `\x -> x x` e trava ao imprimir o resultado.

### 2. E mesmo a variante certa não serve aqui

O porte **não usa** a unificação de Prolog. As substituições são explícitas,
listas de `Var-Tipo`, espelhando o `Types.hs` linha a linha. A decisão é
deliberada:

* o contrato exige que `t0`, `t1`, `t2` apareçam na **mesma ordem** que o
  Haskell gera, e essa ordem vem de um contador de estado (`StateT Int`)
  percorrido numa sequência precisa. Com variáveis Prolog, a identidade de
  cada uma é do motor — nomeá-las na ordem certa exigiria reconstruir o
  contador de qualquer forma;
* e o `composeSubst` do Haskell tem uma **ordem de composição** que a
  unificação destrutiva de Prolog não expressa. `composeSubst s1 s2` aplica
  s2 e depois s1, com `M.union` *left-biased*; o motor de Prolog liga
  variáveis e não compõe mapas.

### O que Prolog contribuiu de verdade: o parser

| | linhas de código |
|---|---|
| Haskell (`Infer` + `Types` + `Parser` + `Lexer`) | 494 |
| F# | 496 |
| OCaml | 468 |
| **Prolog** | **338** |

*(sem comentários nem linhas vazias, medido com `grep -v`)*

Um terço menos que a referência — e o ganho está quase todo no parser. As DCG
**são** a gramática:

```prolog
expr(E) --> [kw(if)], !, expr(C), [kw(then)], expr(A), [kw(else)], expr(B),
            { E = if(C, A, B) }.

add_expr(E) --> mul_expr(L), add_loop(L, E).
add_loop(L, E) --> [sym('+')], !, mul_expr(R), add_loop(bin(add, L, R), E).
```

No Haskell, o mesmo é descida recursiva com a lista de tokens passada
explicitamente por uma mônada de estado. Aqui a lista é implícita, e as regras
se leem como a gramática que elas são.

> O resumo honesto: **Prolog não ajudou na parte que eu esperava e ajudou
> muito na parte que eu não esperava.** A inferência saiu do mesmo tamanho; o
> parser encolheu pela metade.

### Dois defeitos do caminho, que valem mais que o resultado

**`%` inicia comentário em Prolog.** A regra do operador de módulo era
`mul_loop(L, E) --> [sym(%)], !, ...` — e o `%` apagou o resto da linha. O erro
foi:

```
Syntax error: Operator expected
```

numa coluna onde não há operador nenhum, porque a linha que o parser viu
terminava ali. Todos os símbolos passaram a ser citados (`sym('%')`), inclusive
os que funcionariam — deixar alguns citados e outros não é convidar o próximo
erro.

**E a diretiva do topo mudou o significado de todas as aspas do arquivo.** O
lexer precisa de `:- set_prolog_flag(double_quotes, codes)` para casar
`sym_duplo("<=", '<=')` com `append/3`. A consequência é que `"Int"` no
impressor virou `[73,110,116]`, e 11 dos 23 casos quebraram com:

```
string_concat/3: Type error: `atomic' expected, found `[73,110,116]' (a list)
```

A mensagem fala de tipo errado numa função de concatenação, e aponta a linha do
`main/1`. **Não menciona a diretiva**, que está 60 linhas acima e é a causa. A
correção foi usar átomos (`'Int'`), que não dependem da flag.

## O contrato é mais severo do que "aceita ou recusa"

`forge types` imprime o tipo inferido de cada declaração, **incluindo os nomes
das variáveis de tipo**:

```
compose : forall t2 t3 t4. (t3 -> t4) -> (t2 -> t3) -> t2 -> t4
```

Casar isso byte a byte obriga o porte a gerar variáveis frescas na **mesma
ordem** que o Haskell, o que só acontece se ele percorrer a árvore na mesma
ordem em cada regra do algoritmo. **Um porte que inferisse os tipos corretos
com numeração diferente falha aqui.**

E os seis casos de erro exigem a mensagem idêntica, inclusive o número da
variável:

```
forge: erro de tipo: em 'bad': tipo infinito: t0 ocorre em t0 -> t1
```

É o análogo, no P02, da exigência de `.fbc` byte-idêntico nos portes do P01.

| | tem | não tem |
|---|---|---|
| **portes** | lexer, parser, Algoritmo W, `check`, `types` | codegen, montador, `emit`, `ast` |
| **referência** | tudo | — |

## Os três detalhes que decidiram o casamento

Nenhum é óbvio, e cada um teria produzido tipos *corretos* com saída
*diferente*.

**1. O contador de variáveis frescas é global ao programa.** Em Haskell,
`inferProgram` roda **um** `runInfer` para todas as declarações, então a
numeração continua de uma para a outra. Reiniciar por declaração daria
`main : forall t0. ...` onde a referência diz `t4`.

**2. `generalize` ordena lexicograficamente, não numericamente.**
`Data.Set.toList` devolve em ordem crescente de `Ord String`, então **`t10` vem
antes de `t2`**. Por sorte, `Set.Make(String).elements` do OCaml e `Set.toList`
do F# usam a mesma ordem de bytes — mas num porte para linguagem que ordenasse
numericamente, ou que usasse hash set, a saída divergiria em qualquer programa
com mais de dez variáveis de tipo.

**3. `composeSubst s1 s2` tem união enviesada à esquerda.** Em Haskell,
`M.map (applyT s1) s2 \`M.union\` s1` faz as chaves vindas de `s2` ganharem.
Em OCaml, `Map.union` exige uma função de resolução, então a escolha fica
explícita; em F#, união de mapas **não existe na biblioteca** e virou uma dobra
onde o enviesamento é código, não convenção.

## O que cada linguagem deu e cobrou

### OCaml — a tradução mais direta, e a mais verbosa

O porte é quase linha a linha: tipos algébricos, casamento de padrões
exaustivo verificado pelo compilador, `Map`/`Set` persistentes com a mesma
semântica do Haskell.

**O que cobrou:** o Haskell carrega o contador e o erro em
`StateT Int (Either String)`. OCaml não tem mônadas na biblioteca padrão nem
açúcar de `do`, então aqui o contador é **referência mutável** e o erro é
**exceção**. É menos elegante e igualmente correto — e, para um algoritmo com
estado estritamente linear como este, mais direto de ler.

Também precisou de `match (a, b) with`, com parênteses, onde F# aceita
`match a, b with`.

### F# — o mais compacto dos três, e o mais lento a partir

F# é descendente direto de OCaml rodando sobre .NET, então é a comparação mais
informativa: **mesma família de tipos, plataforma completamente outra.**

Escreveu o verificador em **496 linhas, menos que a referência em Haskell
(533)** — sintaxe leve, indentação significativa, sem `let ... in`.

**O que cobrou, e é o achado da seção:** exaustividade de casamento de padrões
é **aviso** em F# (FS0025), não erro. Sem `<TreatWarningsAsErrors>` no
`.fsproj`, um caso faltando compila e explode em execução — exatamente o que o
sistema de tipos deveria impedir. Em OCaml o mesmo descuido é erro de
compilação por padrão.

E o `.fsproj` não aceita `--` dentro de comentário XML, o que derrubou o
primeiro build com `error MSB4025`.

## A tabela comparativa

Linhas de código do **frontend apenas** (lexer, parser, AST, tipos,
inferência), sem comentários nem linhas vazias. Tempo de `forge types` num
programa pequeno, melhor de 9, **no sistema de arquivos nativo do Linux** — ver
a armadilha abaixo.

| impl | linhas | `types` | dispersão | executável |
|---|---|---|---|---|
| **Haskell** (referência) | 533 | 8 ms | 25% | 2,9 MB |
| **OCaml** | 604 | **7 ms** | 71% | **1,6 MB** |
| **F#** (ReadyToRun) | **496** | 66 ms | 183% | 84 MB |
| **F#** (framework) | — | 118 ms | 128% | — |

### O que a tabela sustenta, e o que não

**Haskell e OCaml são indistinguíveis aqui.** 8 ms contra 7 ms, com dispersão
de 25% e 71% — a diferença está muito dentro do ruído, e afirmar que um é mais
rápido seria invenção. O que se pode dizer é que os dois estão na casa de
**uma dezena de milissegundos**.

**F# é 8x a 17x mais lento a partir, e isso está estabelecido** — 66 ms contra
7–8 ms, com as faixas longe de se tocarem. A causa não é o algoritmo: é
inicialização do runtime .NET mais JIT. `ReadyToRun` corta quase metade
(118 → 66 ms) e não fecha a diferença.

**E isso importa, mas só para este uso.** Um compilador de linha de comando é
invocado uma vez por arquivo, então 60 ms de partida aparecem em cada chamada.
Num processo longo — servidor, IDE — o custo é pago uma vez e desaparece. O
número mede *este* padrão de uso, não a plataforma.

**84 MB contra 1,6 MB** é a outra face da mesma moeda: o build autocontido do
F# carrega o runtime inteiro.

## A armadilha que quase me fez publicar o contrário

A primeira medição deu **ReadyToRun mais LENTO que o framework-dependent**:
366 ms contra 246 ms. Isso contradiz o propósito do ReadyToRun, e eu quase
publiquei assim.

A causa não era o .NET: era **onde os arquivos estavam.** Este repositório fica
em `/mnt/c`, o sistema de arquivos do Windows visto pelo WSL2, que é lento para
abrir muitos arquivos pequenos. O build autocontido tem ~84 MB espalhados em
centenas de DLLs, e paga isso em cada partida.

Copiando os **mesmos binários** para `/root`, no sistema de arquivos nativo:

| | `/mnt/c` | `/root` | fator |
|---|---|---|---|
| F# ReadyToRun | 366 ms | **66 ms** | **5,5x** |
| F# framework | 246 ms | 119 ms | 2,1x |
| OCaml (controle) | 23 ms | 15 ms | 1,5x |

No sistema nativo, **ReadyToRun é mais rápido**, como se espera. A conclusão
original era artefato do local da medição — e o controle com o OCaml é o que
prova: ele também melhorou, mas só 1,5x, porque é **um** arquivo de 1,6 MB.

O confundidor aqui não foi carga de CPU, foi **sistema de arquivos**. É uma
variável que o resto do portfólio não tinha encontrado, e por isso a tabela
acima declara onde foi medida.

## O que os 23 casos cobrem, e o que não cobrem

| grupo | casos | o que exige |
|---|---|---|
| `tests/ok/` | 16 | tipos inferidos byte a byte, inclusive polimórficos e de ordem superior |
| `tests/phase2/` | 1 | `check` aceita (a limitação é do backend, não do sistema de tipos) |
| `tests/err/` | 6 | mensagem idêntica, com nome da declaração e número da variável |

**O que não cobrem:** os portes não geram código, então nada aqui verifica que
a inferência produziu tipos *úteis* para o codegen — só que produziu os
**mesmos** da referência. Se a referência estiver errada, os portes concordam
com o erro.

É a limitação estrutural de verificar por equivalência em vez de por
especificação, e é o que as provas formais do roadmap (Lean, Coq, Agda, Idris)
existem para resolver: elas verificam o algoritmo contra o **teorema**, não
contra outra implementação.
