# A linguagem forge

Funcional, estrita, de tipagem estática **totalmente inferida**. Não existe
sintaxe para anotar tipo: tudo que `forge types` imprime foi deduzido.

## Gramática

```
programa  := decl+
decl      := 'let' ['rec'] ident ident* '=' expr

expr      := 'if' expr 'then' expr 'else' expr
           | 'let' ['rec'] ident ident* '=' expr 'in' expr
           | '\' ident+ '->' expr
           | seq

seq       := cmp [';' expr]                     -- associa à direita
cmp       := add [relop add]                    -- NÃO associa
add       := mul (('+' | '-') mul)*             -- associa à esquerda
mul       := unary (('*' | '/' | '%') unary)*   -- associa à esquerda
unary     := '-' unary | app
app       := atom atom*                         -- associa à esquerda
atom      := int | 'true' | 'false' | ident | '(' expr ')'

relop     := '<' | '<=' | '>' | '>=' | '==' | '!='
comentário := '--' até o fim da linha
```

Duas decisões de gramática que valem explicação:

**Não há separador entre declarações de topo.** Nem `;;`, nem indentação
significativa. Isso funciona sem ambiguidade porque uma expressão só pode ser
*estendida* por um operador infixo ou por aplicação, e `let` não inicia um
átomo — então, ao terminar o corpo de uma declaração, encontrar `let` só pode
significar declaração nova.

**Comparações não associam.** `a < b < c` é erro de sintaxe. Em C isso compila
e faz outra coisa (`(a<b)<c`, comparando um booleano com `c`); aqui o parser
recusa antes de o programador descobrir sozinho.

## Tipos

```
Int                  inteiro de 64 bits
Bool                 true | false
t -> u               função
forall a b. t        esquema (só aparece na saída de `forge types`)
```

Sem tipos de ordem superior, sem classes de tipo, sem tipos de dados do
usuário. É Hindley-Milner puro, e é o suficiente para o que o projeto quer
medir: inferência total, polimorfismo do `let`, unificação com teste de
ocorrência.

### O `let` dá polimorfismo; o parâmetro não

```forge
let id x = x
-- id : forall t0. t0 -> t0     -- usável em Int e em Bool no mesmo programa
```

Já um parâmetro é monomórfico dentro do corpo da função — quem escolhe o tipo
dele é o chamador. Essa distinção é o que a condição sobre o ambiente, na
generalização, implementa (ver `Types.generalize`).

### `let rec` é monomórfico durante a própria definição

Dentro do corpo de `let rec f`, a referência a `f` tem tipo monomórfico; a
generalização só acontece depois. Generalizar antes permitiria *polimorfismo
polimórfico recursivo*, que não é decidível em Hindley-Milner.

## Semântica

Avaliação **estrita**, da esquerda para a direita.

| construção | significado |
|---|---|
| `e1 ; e2` | avalia `e1`, descarta o valor, devolve `e2` |
| `if c then a else b` | `c : Bool`; os dois ramos têm o mesmo tipo |
| `let x = e in b` | liga `x` ao valor de `e` em `b` |
| `f a b` | aplicação; estrita nos argumentos |
| `-e` | negação aritmética |

`/` e `%` são divisão inteira truncada e resto, com o sinal do dividendo — é o
que a instrução `DIV`/`MOD` do bytecode faz, que por sua vez é o que o C faz.
Divisão por zero é **erro em tempo de execução**, reportado pela VM, não
comportamento indefinido.

## Builtins

| nome | tipo | o que faz |
|---|---|---|
| `print` | `Int -> Int` | imprime o inteiro e **devolve** o valor |

`print` devolver o argumento é deliberado: permite `print a; print b` sem a
linguagem precisar de um tipo unitário, e mantém toda expressão com valor.

## O ponto de entrada

Todo programa precisa de uma declaração `main`, de qualquer tipo. Ela é
avaliada pelo seu efeito; o valor é descartado.

## Exemplo completo

```forge
-- Fibonacci. Nenhum tipo anotado.
let rec fib n =
  if n < 2 then n
  else fib (n - 1) + fib (n - 2)

let main = print (fib 20)
```

```
$ forge types examples/fib.fg
fib : Int -> Int
main : Int

$ forge build examples/fib.fg -o fib.fbc
forge: 104 bytes -> fib.fbc

$ fvm exec fib.fbc        # a VM do projeto P01
6765
```

## O que a linguagem aceita e o compilador ainda não baixa

Funções de ordem superior **tipam** e não **compilam**:

```forge
let aplica f x = f x
-- aplica : forall t1 t2. (t1 -> t2) -> t1 -> t2    <- inferido corretamente
```

`forge check` aceita. `forge build` recusa, porque o bytecode do P01 só tem
chamada para endereço fixo. O desenho da instrução que falta está em
[PHASE2.md](PHASE2.md).

Essa separação é verificada por testes: `tests/phase2/` exige que o
verificador aceite **e** que o backend recuse. Se um dia o verificador passar a
recusar, a suíte acusa.
