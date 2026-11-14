# forge-lang — uma linguagem funcional com inferência total, compilando para a VM do P01

Compilador completo em Haskell: léxico, sintaxe, **inferência de tipos de
Hindley-Milner** e geração de bytecode. O que sai daqui roda nas duas
implementações independentes da VM do projeto
[metal-vm](https://github.com/Brunowdgaster/metal-vm), sem modificação nenhuma
nelas.

Projeto 02 de 14 de um portfólio poliglota — índice em
[Brunowdgaster/poliglota](https://github.com/Brunowdgaster/poliglota).

```
$ cat examples/fib.fg
let rec fib n =
  if n < 2 then n
  else fib (n - 1) + fib (n - 2)

let main = print (fib 20)

$ forge types examples/fib.fg          # nenhum tipo foi anotado no fonte
fib : Int -> Int
main : Int

$ forge build examples/fib.fg -o fib.fbc
forge: 104 bytes -> fib.fbc

$ fvm exec fib.fbc                      # a VM em C do P01
6765
$ fvm-rust exec fib.fbc                 # a VM em Rust do P01
6765
```

> **Status:** front-end **completo** (inferência total) e back-end **completo
> para ordem superior** — a Fase 2 foi implementada: closures, captura de
> variável livre, composição e aplicação parcial compilam e rodam. Custou
> **uma** instrução nova na VM do P01. Falta apenas `let rec` local.
> As outras 14 linguagens previstas no plano do P02 (OCaml, F#, Lisps, Prolog,
> Lean, Coq, Agda, Idris, Isabelle, TLA+, WAT) ainda não começaram — ver
> [Estado atual](#estado-atual).

## Objetivo do projeto

Um compilador é o lugar onde teoria de tipos deixa de ser slide e passa a ter
que funcionar. O P02 existe para responder três coisas **escrevendo**, não
lendo:

| pergunta | como o projeto responde |
|---|---|
| Inferência de Hindley-Milner funciona mesmo sem nenhuma anotação? | O fonte da linguagem **não tem sintaxe** para anotar tipo. Se a inferência falhar, não há escapatória |
| O verificador de tipos é independente do gerador de código? | Testes em `tests/phase2/` exigem que o verificador **aceite** e o backend **recuse** o mesmo programa |
| O bytecode do P01 serve de alvo real, ou só de demonstração? | 8 programas compilados aqui rodam nas duas VMs do P01, e os bytes batem com o montador em C dele |

A terceira é a que amarra o portfólio: o P01 afirmou que o bytecode foi
"desenhado para o P02 estender". Este projeto é a verificação dessa afirmação —
e ela se sustentou, com uma limitação identificada e dimensionada.

## Resultado

**39 verificações, todas passando** nas três configurações de VM do P01
(`switch`, computed goto e Rust), em quatro categorias:

| categoria | o que verifica | n |
|---|---|---|
| `tests/ok/` | compila, roda na VM do P01, saída confere | 16 |
| `tests/err/` | o **verificador de tipos** recusa, com a mensagem certa | 6 |
| `tests/phase2/` | o verificador **aceita** e o backend recusa, com motivo | 1 |
| bytes | o `.fbc` do forge é **idêntico** ao do montador em C do P01 | 16 |

### Ordem superior funciona, e custou uma instrução

A Fase 2 testou a afirmação central do portfólio: o P01 dizia que o bytecode
foi "desenhado para o P02 estender". Quando o forge precisou de closures,
quanto da VM precisou mudar?

**Uma instrução.** `CALLI nargs` — chamada indireta, em que o destino vem dos
dados. Closure é um array comum `[endereço, capturados...]`, então o heap e o
coletor do P01 bastaram; `PUSH` passou a aceitar rótulo, o que dispensou um
segundo opcode. Alocar a closure é `NEWARR` + `ASET`, que já existiam.

O que compila agora:

```forge
let compose f g = \x -> f (g x)     -- lambda capturando duas funcoes
let dobra x = x * 2
let mais1 x = x + 1
let main =
  let h = compose dobra mais1 in
  print (h 20)                       -- 42
```

```forge
let soma3 a b c = a + b + c
let main =
  let p = soma3 1 in                 -- aplicacao parcial
  let q = p 2 in                     -- e de novo
  print (q 39)                       -- 42
```

```forge
let aplica f x = f x
let main = aplica print 42           -- builtin como valor
```

O código gerado para uma captura, com `forge emit`:

```
soma_com:              ; soma_com a = \x -> x + a
  PUSH 2
  NEWARR               ; array de 2: [endereco, capturado]
  DUP ; PUSH 0 ; PUSH $lam0 ; ASET
  DUP ; PUSH 1 ; LOAD 0     ; ASET   ; captura 'a'
  RET
main:
  PUSH 10
  CALL soma_com 1      ; chamada DIRETA: aridade exata, sem alocar closure
  LOAD 0
  PUSH 32
  CALLI 1              ; chamada INDIRETA: o destino sai da closure
  DUP ; PRINT
  STORE 0
  HALT
$lam0:                 ; (closure = slot 0, x = slot 1)
  LOAD 1
  LOAD 0 ; PUSH 1 ; AGET    ; le a captura de dentro da closure
  ADD
  RET
```

Note o `CALL soma_com 1` ao lado do `CALLI 1`: chamada direta a função de topo
com aridade exata **não** paga closure. O caminho genérico é currificado —
um argumento por vez — e é o que torna ordem superior, aplicação parcial e
sobre-aplicação o mesmo mecanismo em vez de três.

### Closures são coletadas como qualquer objeto

A VM não tem tipo de closure: tem array. Logo o mark & sweep já as percorre, e
uma closure que capture a si mesma seria coletada sem tratamento extra. O teste
`closure_gc.fg` aloca 5.000 closures descartadas e força uma coleta com a
closure útil ainda alcançável:

```
coletas de GC   : 2
bytes liberados : 320000
pico de heap    : 262144 bytes
42                        <- a closure alcancavel sobreviveu
```

### A inferência funciona, e a prova é o que ela deduz sozinha

```
$ forge types tests/ok/polimorfismo.fg
id : forall t0. t0 -> t0

$ forge types tests/ok/composicao.fg
compose : forall t2 t3 t4. (t3 -> t4) -> (t2 -> t3) -> t2 -> t4
dobra : Int -> Int
mais1 : Int -> Int
main : Int
```

A primeira linha é o tipo de `compose`, deduzido sem nenhuma anotação — e hoje
esse programa **compila e roda**, o que antes da Fase 2 não acontecia.

A categoria `tests/phase2/` continua existindo com a limitação que resta
(`let rec` local): ela exige que o verificador **aceite** e o backend
**recuse**, o que mantém verificada a afirmação de que o limite está no
backend e não no sistema de tipos.

O teste `polimorfismo.fg` usa `id` em `Int` e em `Bool` no mesmo programa,
compila e roda. Sem polimorfismo do `let`, não compilaria.

### O que o verificador recusa

Todas estas falham no `forge check`, com mensagem específica:

| programa | erro |
|---|---|
| `1 + true` | não consegui unificar Int com Bool |
| `let bad x = x x` | **tipo infinito**: t0 ocorre em t0 -> t1 (teste de ocorrência) |
| `if true then 1 else false` | ramos de tipos diferentes |
| `if 1 then 2 else 3` | condição não é Bool |
| `naoExiste 1` | variável não definida |
| programa sem `main` | boa-formação do programa |

### Os bytes batem com o P01

Para cada programa de `tests/ok/`, a suíte faz duas montagens independentes —
o `forge build` direto para `.fbc`, e o `forge emit` gerando `.fasm` que é
montado pelo **montador em C do P01** — e compara byte a byte. 8/8 idênticos.

É o teste que impede o gerador de código de divergir silenciosamente do formato
do bytecode. Divergência aqui não daria erro: daria programa que roda e produz
resultado errado.

## Como rodar

Requer GHC (≥ 9.4) e o P01 compilado ao lado.

```bash
bash build.sh                       # compila o forge com ghc, sem cabal
./build/forge version

# precisa do P01 para os testes de ponta a ponta
bash tests/run_tests.sh             # 39 verificações
bash tests/run_tests.sh build/forge ../p01-metal-vm/build-switch/fvm
```

O compilador **não tem dependências externas** — só `base`, `containers` e
`mtl`, que acompanham o GHC. Por isso `build.sh` é um único comando `ghc`, sem
resolução de pacotes e sem rede. Há um `hs/forge.cabal` para quem preferir
cabal, mas ele é opcional.

Comandos:

```
forge check <prog.fg>                verifica tipos
forge types <prog.fg>                tipo inferido de cada declaração
forge build <prog.fg> -o <prog.fbc>  compila para bytecode do P01
forge emit  <prog.fg>                imprime o .fasm equivalente
forge ast   <prog.fg>                imprime a árvore sintática
```

## Arquitetura

```
  prog.fg
     │
     ▼
  ┌──────────┐   [Token]    ┌──────────┐    Program    ┌──────────────┐
  │  Lexer   │─────────────▶│  Parser  │──────────────▶│    Infer     │
  │ à mão    │  com linha   │ descida  │   AST com     │  Algoritmo W │
  │          │  e coluna    │recursiva │   aridade     │              │
  └──────────┘              └──────────┘   preservada  └──────┬───────┘
                                                              │ TypeEnv
                            aceita a linguagem INTEIRA ───────┤
                                                              ▼
                            ┌──────────┐              ┌──────────────┐
                            │ Bytecode │◀─────────────│   Codegen    │
                            │ montador │   [Instr]    │ 1ª ordem só  │
                            │ 2 passes │              │              │
                            └────┬─────┘              └──────────────┘
                                 │
                   ┌─────────────┴─────────────┐
                   ▼                           ▼
              prog.fbc                    prog.fasm
          (executa na VM do P01)   (montável pelo montador do P01)
```

Quatro decisões estruturais:

1. **A aridade das funções de topo é preservada na AST.** `Decl` guarda os
   parâmetros separados do corpo em vez de currificar em `ELam` aninhada,
   porque o gerador precisa saber a aridade para emitir `CALL rotulo nargs`.
   Currificar e depois tentar recuperar a aridade é trabalho inútil. Já um
   `let` **local** é currificado, pois nunca é alvo de `CALL` direto.
2. **O verificador é independente do backend.** `forge check` aceita ordem
   superior; `forge build` recusa. A fronteira é explícita e testada.
3. **Locais são slots da pilha de operandos**, acima dos argumentos — mesma
   decisão do P01, e aqui ela faz o `let` compilar para três instruções.
4. **Duas saídas do mesmo `[Instr]`**: binário e texto. A saída de texto é o
   que permite o teste de identidade de bytes com o montador do P01.

Referência da linguagem: [docs/LANGUAGE.md](docs/LANGUAGE.md).
Desenho das closures: [docs/PHASE2.md](docs/PHASE2.md).

## Linguagens e ferramentas

| Ferramenta | Onde é usada | Por que ela, e não outra | Alternativa descartada |
|---|---|---|---|
| **Haskell (GHC 9.10)** | o compilador inteiro: léxico, sintaxe, inferência, geração | É a linguagem em que compiladores são escritos, e o motivo é concreto: tipos de dados algébricos descrevem AST sem cerimônia, casamento de padrão exaustivo é verificado pelo compilador, e `Either`/`StateT` dão propagação de erro e geração de nomes frescos sem infraestrutura. Algoritmo W é literalmente mais curto em Haskell que o pseudocódigo do artigo original | **Python** ou **TypeScript**: faria o mesmo em mais linhas e sem exaustividade verificada. Um caso de AST esquecido viraria bug em execução em vez de erro de compilação |
| **`mtl` (`StateT` sobre `Either`)** | contador de variáveis de tipo frescas e de rótulos, propagação de erro | A inferência precisa de duas coisas ao mesmo tempo: estado (próxima variável fresca) e falha (erro de unificação). A pilha `StateT Int (Either String)` dá as duas com `lift`, sem nenhuma plumbing manual | Passar o contador à mão por todos os casos: ~40 pontos de ruído onde o erro de esquecer de propagar é invisível |
| **`containers` (`Data.Map`, `Data.Set`)** | ambiente de tipos, substituições, variáveis livres | Substituição é um mapa e `ftv` é um conjunto — usar as estruturas certas deixa `composeSubst` em uma linha e correta | Listas de pares: `O(n)` e, pior, duplicatas silenciosas |
| **Nenhuma dependência externa** | — | O projeto compila com um `ghc` e nada mais. Zero resolução de pacotes, zero rede, zero `cabal update` quebrando o CI de alguém dois anos depois | **megaparsec** / **alex+happy**: dariam o parser mais rápido de escrever. Descartados porque escrever o lexer e o parser à mão é parte do que o projeto demonstra, e porque controlar linha e coluna nas mensagens de erro é mais fácil sem gerador |
| **Bytecode do P01 como alvo** | `Bytecode.hs`, `Codegen.hs` | Compilar para um alvo **que existe e é verificável** muda o projeto de qualidade: a saída roda em duas VMs independentes escritas em linguagens diferentes. Qualquer erro de layout aparece como resultado errado num teste, não como teoria | **LLVM**: alvo mais sério, mas a cadeia de verificação passaria a depender de uma ferramenta de terceiros gigante. Entra no roadmap como segundo backend |
| **Testes em quatro categorias** | `tests/run_tests.sh` | Testar o que o compilador **recusa** é tão importante quanto o que ele aceita, e a categoria `phase2` codifica uma afirmação arquitetural que de outra forma seria só uma frase no README | Só testes positivos: um verificador que aceita tudo passa em 100% deles |
| **Bash** | build e testes | Mesmo padrão do P01: o CI roda em Linux, e o harness precisa invocar dois binários de projetos diferentes | — |
| **GitHub Actions** | CI que **clona e compila o P01** para rodar os testes de ponta a ponta | A dependência entre os dois projetos é real, então o CI a exercita de verdade: clona o `metal-vm`, compila com cmake, e roda os programas forge nele. Se o P01 mudar o formato do bytecode, este CI quebra — que é exatamente o que se quer | Copiar a VM para dentro deste repo: esconderia justamente o acoplamento que o teste existe para vigiar |

## Decisões e trade-offs

### Por que primeira ordem primeiro

O caminho curto seria restringir a linguagem para que só programas de primeira
ordem fossem **tipáveis** — assim nada seria recusado pelo backend e o projeto
pareceria completo.

Foi o contrário: o verificador implementa Hindley-Milner inteiro, e o backend
recusa o que não sabe baixar, com mensagem que diz exatamente por quê e remete
ao desenho da solução. Isso custa três testes "falhando de propósito", e em
troca o projeto é honesto sobre onde está a fronteira — e a fronteira fica
verificada por teste em vez de descrita em prosa.

### Uma instrução nova resolve closures

O levantamento está em [docs/PHASE2.md](docs/PHASE2.md): closure é um array
`[endereço, livres...]` — e o P01 já tem arrays com coleta de lixo — e falta
**uma** instrução, `CALLI nargs`, para chamada indireta. Nem `OP_CLOSURE` é
necessário: alocar é `NEWARR` + `ASET`, que já existem.

Saber o tamanho exato da mudança (~45 linhas nas duas VMs, ~150 no compilador)
é o que separa "não implementei" de "não implementei ainda".

### `print` devolve o que imprime

`print : Int -> Int` em vez de `Int -> ()`. Assim `print a; print b` tipa sem a
linguagem precisar de tipo unitário, e toda expressão tem valor — o que mantém
a invariante do gerador de código (toda expressão deixa exatamente um valor na
pilha) sem caso especial.

Custo: `print` não é `IO`, e a linguagem não distingue efeito de valor. Para
uma linguagem de 900 linhas cujo objetivo é inferência, é o trade-off certo.

### Comparações não associam

`a < b < c` é erro de sintaxe, decidido na gramática. Em C aquilo compila e
compara um booleano com um inteiro. Preferi que o parser recuse.

### Declarações veem só as anteriores

Sem recursão mútua entre declarações de topo: `inferProgram` processa em ordem e
cada declaração só vê as já processadas. Suportar mútua exigiria calcular
componentes fortemente conexos do grafo de dependências e generalizar por
componente — está no roadmap, e o teste `mutua.fg` contorna com auto-recursão.

### O bug que a invariante de pilha quase deixou passar

O gerador compila o operando direito de uma operação binária com a altura de
pilha **já incrementada**, porque o operando esquerdo ocupa um slot. A primeira
versão não fazia esse ajuste: um `let` dentro do operando direito escolhia o
slot do operando esquerdo e o sobrescrevia.

O sintoma seria resultado numérico errado, **sem nenhum erro** — nem do
compilador, nem da VM, nem do verificador de tipos. Foi pego ao escrever o
comentário que explicava a invariante, antes de rodar. O teste `slots.fg`
existe para que não volte.

## Limites conhecidos

- **`let rec` local não compila.** Recursão local exige uma closure que
  referencia a si mesma: alocar, guardar no slot e só então gravar o próprio
  endereço num campo dela. O coletor do P01 lida com o ciclo sem nada extra,
  então é um incremento pequeno — mas é um incremento. `let rec` de topo
  funciona, e `tests/phase2/let_rec_local.fg` documenta a limitação executando.
- **Sem chamada de cauda.** `let rec` de topo recursiva consome um frame por
  nível, e a VM tem 4.096. Uma recursão de 5.000 níveis estoura — com erro
  reportado, não corrupção. É o que impede o teste de GC de usar recursão
  profunda em vez de alocar várias closures por nível.
- **Closures alocam sempre.** Não há análise de escape nem especialização de
  chamada conhecida: `compose dobra mais1` aloca três closures. O caminho de
  chamada direta evita isso só quando a aridade é exata.
- **Sem recursão mútua** entre declarações de topo.
- **Tipos:** só `Int` e `Bool`. Sem ponto flutuante, string, lista, tupla,
  registro ou tipo de dado do usuário. O P01 tem arrays no heap e o compilador
  ainda não os expõe.
- **Sem otimização alguma.** Nenhuma dobra de constantes, nenhuma eliminação de
  código morto, nenhuma chamada de cauda. `fib 20` gera exatamente o que o
  programa diz.
- **Mensagens de erro de tipo não têm posição.** O léxico e a sintaxe reportam
  linha e coluna; a inferência reporta só o nome da declaração. Carregar
  posição pela unificação exige anotar a AST com spans — é um refactor
  conhecido, não um mistério.
- **As outras 14 linguagens do plano do P02 não começaram.** O que existe é o
  eixo Haskell → bytecode. OCaml, F#, os Lisps, Prolog, as provas em
  Lean/Coq/Agda/Idris/Isabelle, o TLA+ e o backend WebAssembly estão no
  roadmap.

## Roadmap

1. ~~**Fase 2: closures.**~~ **Concluída.** `CALLI` nas duas VMs do P01 e
   conversão de closures no forge. Os três arquivos saíram de `tests/phase2/`,
   que era o critério declarado. Detalhes e as três correções ao desenho
   original em [docs/PHASE2.md](docs/PHASE2.md).
2. **`let rec` local**, a última lacuna do backend: closure que referencia a si
   mesma.
3. **Porte do verificador para OCaml**, com a mesma suíte. É a comparação que
   o P02 promete: o mesmo Algoritmo W em Haskell e em OCaml, medido em linhas,
   em legibilidade e em tempo de compilação.
3. **Posição na AST**, para erros de tipo apontarem a linha.
4. **Prova de soundness em Lean 4**: progresso e preservação para o núcleo da
   linguagem, linkados do README para o código que eles garantem.
5. **Backend WebAssembly** (`.wat` escrito à mão primeiro), para ter dois
   alvos e poder comparar a geração de código.
6. **Recursão mútua** via componentes fortemente conexos.
7. **Regras de tipo em Prolog**, que é a forma declarativa de escrever
   unificação — o algoritmo *é* Prolog.
8. **Interpretador meta-circular em Racket/Scheme/Common Lisp**, para o eixo
   de homoiconicidade e macros.

## Aprendizados

- **"Uma instrução" era mesmo uma instrução.** O documento de desenho da Fase
  2 estimou o custo antes de implementar: 1 opcode novo, ~45 linhas nas duas
  VMs, ~150 no compilador. O real foi 1 opcode, ~45 linhas e ~120. Estimar
  antes e conferir depois é o que transforma "não implementei" em "não
  implementei ainda".
- **O desenho errou três detalhes, e o código os encontrou.** A closure não
  pode ser desempilhada (precisa ficar como slot 0); currificar tudo no caminho
  genérico unifica três casos em um; e provar que o coletor recicla closures
  exigiu um builtin `gc` que não estava previsto. O documento foi corrigido em
  vez de reescrito, para que a diferença fique visível.
- **Um comentário que explica uma invariante encontra bugs antes do teste.** O
  bug de slot do operando direito apareceu enquanto eu escrevia por que a
  invariante valia — e não valia.
- **Testar o que o compilador recusa é metade da suíte.** Seis dos 25 testes
  verificam mensagens de erro. Um verificador de tipos que aceita tudo passa em
  qualquer conjunto de programas válidos.
- **A categoria `phase2` transformou uma frase de README em teste.** "O
  verificador é mais geral que o backend" era uma afirmação; agora é uma
  verificação que quebra se deixar de ser verdade.
- **Compilar para um alvo que existe muda a natureza do projeto.** Não há como
  se enganar sobre o gerador de código quando a saída tem que rodar em duas VMs
  escritas por outra pessoa — ainda que essa pessoa seja você mesmo, dois
  projetos atrás.
- **Hindley-Milner é mais curto do que parece e mais sutil do que parece.** São
  127 linhas de inferência. A ordem de composição das substituições e o momento
  da generalização no `let rec` são os dois pontos onde errar não dá erro: dá um
  tipo menos geral, num programa que ainda compila.

## Estado atual

| Parte | Estado |
|---|---|
| Léxico com linha e coluna | ✅ |
| Parser por descida recursiva, precedência explícita | ✅ |
| Inferência de Hindley-Milner (Algoritmo W) | ✅ completa, com teste de ocorrência |
| Polimorfismo do `let` | ✅ verificado por teste em dois tipos |
| Geração de bytecode, primeira ordem | ✅ |
| **Closures, ordem superior, aplicação parcial** | ✅ Fase 2, com 1 instrução nova na VM |
| Captura de variável livre, composição | ✅ |
| Builtins como valor (`print`, `gc`) | ✅ via invólucro gerado |
| Identidade de bytes com o montador do P01 | ✅ 16/16 |
| Execução nas três configurações de VM do P01 | ✅ switch, goto e Rust |
| Suíte de testes | ✅ 39/39 |
| CI que clona e compila o P01 | ✅ verde |
| `let rec` local | ⬜ última lacuna do backend |
| Porte para OCaml / F# / Lisps / Prolog | ⬜ |
| Provas em Lean / Coq / Agda / Idris / Isabelle | ⬜ |
| Backend WebAssembly | ⬜ |
| Especificação em TLA+ | ⬜ |

## Licença

MIT.
