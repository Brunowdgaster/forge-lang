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
| `gc` | `Int -> Int` | força uma coleta de lixo e devolve o valor |

Os dois devolverem o argumento é deliberado: permite `print a; print b` sem a
linguagem precisar de um tipo unitário, e mantém toda expressão com valor — o
que por sua vez mantém a invariante do gerador de código (toda expressão deixa
exatamente um valor na pilha) sem nenhum caso especial.

`gc` existe para que o coletor do P01 seja testável de dentro da linguagem.
Sem ele, provar que uma closure alcançável sobrevive a uma coleta exigiria
escrever bytecode à mão — ou seja, não testaria o compilador.

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
## Ordem superior e closures

Funções são valores de primeira classe. Tudo abaixo compila e roda na VM do
P01, desde a Fase 2:

```forge
-- funcao recebendo funcao
let aplica f x = f x

-- lambda capturando variavel livre
let soma_com a = \x -> x + a

-- composicao: a lambda captura duas funcoes
let compose f g = \x -> f (g x)

-- aplicacao parcial, encadeada
let soma3 a b c = a + b + c
let main =
  let p = soma3 1 in
  let q = p 2 in
  print (q 39)                -- 42
```

Builtins também são valores: `aplica print 42` funciona, porque o compilador
gera um invólucro para `print` quando ele aparece sem ser aplicado.

Como isso é implementado — closure como array `[endereço, capturados...]`,
chamada indireta com `CALLI`, currificação no caminho genérico e chamada
direta preservada quando a aridade é exata — está em [PHASE2.md](PHASE2.md).

## A limitação que resta: `let rec` local

```forge
let main =
  let rec go n = if n == 0 then 0 else n + go (n - 1) in
  print (go 10)
```

`forge check` **aceita** — é bem tipado. `forge build` **recusa**: recursão
local precisa de uma closure que referencia a si mesma, o que exige alocar,
guardar no slot e só então gravar o próprio endereço num campo dela. O coletor
do P01 lida com o ciclo resultante sem nada extra, então é um incremento
pequeno — mas é um incremento.

`let rec` de **topo** funciona e resolve o caso na prática:

```forge
let rec go n = if n == 0 then 0 else n + go (n - 1)
let main = print (go 10)      -- 55
```

Essa separação é verificada por teste: `tests/phase2/let_rec_local.fg` exige
que o verificador aceite **e** que o backend recuse. Se um dia o verificador
passar a recusar, a suíte acusa.

## Sem chamada de cauda

A VM do P01 tem 4.096 frames e o forge não faz otimização de chamada de cauda,
então uma função recursiva de topo consome um frame por nível. Recursão de
5.000 níveis estoura a pilha de chamadas — com **erro reportado pela VM**, não
corrupção silenciosa.
