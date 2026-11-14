# Fase 2: closures — **concluída**

> **Status: implementada e verificada.** Os três programas que viviam em
> `tests/phase2/` passaram para `tests/ok/`, que era o critério de pronto
> declarado neste documento. A suíte foi de 25 para 39 verificações.
>
> O que mudou em relação ao desenho original está em
> [Correções ao desenho](#correções-ao-desenho) — três coisas que o plano
> previa diferente e o código descobriu.

## O que ficou pronto

| | |
|---|---|
| Instruções novas na VM | **1** (`CALLI nargs`), nas duas implementações |
| Opcodes de apoio | nenhum — `PUSH` passou a aceitar rótulo |
| Linhas somadas nas duas VMs | ~45, mais ~10 no montador de cada |
| Conversão de closures no compilador | ~120 linhas em `Codegen.hs` |
| Testes do P01 | 7 → 9 casos; compatibilidade cruzada 42 → 54 |
| Testes do P02 | 25 → 39 verificações |

O que o forge compila agora e não compilava:

```forge
let aplica f x = f x                    -- ordem superior
let compose f g = \x -> f (g x)         -- lambda capturando duas funcoes
let soma_com a = \x -> x + a            -- captura de variavel livre
let inc = soma 1                        -- aplicacao parcial
let p = soma3 1 in let q = p 2 in q 39  -- cadeia de aplicacao parcial
let main = aplica print 42              -- builtin como valor
```

E o coletor trata closure como qualquer objeto: num teste que aloca 5.000
delas, **2 coletas, 320.000 bytes reciclados, e a closure ainda alcançável
sobreviveu**.

## Correções ao desenho

O plano acertou o tamanho da mudança e errou três detalhes. Todos apareceram
escrevendo o código, e o documento foi corrigido em vez de reescrito, para que
a diferença fique visível.

### 1. A closure não é desempilhada

O plano dizia: *"desempilha a closure; lê `arr[0]`; empilha um frame com
`base = sp - nargs`"*. Isso deixaria a closure **fora** do frame, e as capturas
inacessíveis.

O que foi implementado: a closure fica **abaixo** dos argumentos e permanece
como **slot 0** do frame (`base = sp - nargs - 1`). Assim `LOAD 0` é a closure
e `LOAD 1..N` são os argumentos — sem registrador de ambiente e sem instrução
de acesso a captura.

### 2. Toda função que vira valor é unária

O plano tratava aplicação parcial como um caso à parte. Na prática, currificar
tudo no caminho genérico — aplicar **um argumento por vez** com `CALLI 1` —
transforma ordem superior, aplicação parcial e sobre-aplicação **no mesmo
mecanismo** em vez de três. Uma função de topo de aridade `n` usada como valor
ganha uma cadeia `f$1 .. f$n` que acumula argumentos até poder emitir o `CALL`
direto.

Chamada direta a função de topo com aridade exata continua emitindo
`CALL rotulo nargs`: closures custam alocação, e o caminho comum não paga.

### 3. Um builtin a mais, não previsto

Provar que o coletor recicla closures exigia forçar uma coleta de dentro da
linguagem. Entrou um builtin `gc : Int -> Int`, que emite a instrução `GC` e
devolve seu argumento. Sem ele, o teste de coleta precisaria ser escrito em
bytecode à mão — ou seja, não testaria o compilador.

---

# Desenho original (mantido para referência)

Este documento existe para que a limitação atual seja um **projeto de
engenharia com desenho pronto**, e não uma desculpa.

## O problema, exatamente

O bytecode do P01 tem uma única forma de chamada:

```
CALL <endereço i32> <nargs u8>
```

O endereço é **fixo, resolvido em tempo de montagem**. Isso basta para toda
função cujo alvo é conhecido estaticamente — ou seja, para linguagens de
primeira ordem.

Não basta para:

```forge
let aplica f x = f x        -- f é um parâmetro: o alvo só é conhecido em execução
let main = print (aplica dobra 21)
```

Nem para funções que capturam variáveis do escopo:

```forge
let main =
  let n = 10 in
  let soma_n = \x -> x + n in    -- captura n
  print (soma_n 5)
```

O primeiro caso precisa de **chamada indireta**. O segundo precisa de
**ambiente capturado**. Juntos, são closures.

## O desenho

### Representação da closure

Uma closure é um **array no heap** — estrutura que o P01 já tem, com coleta de
lixo funcionando:

```
closure = [ endereço_do_código, livre_0, livre_1, ... ]
           ^ slot 0, inteiro     ^ valores capturados
```

Nada de novo no modelo de memória: o coletor mark & sweep do P01 já percorre
arrays e já trata ciclos, então uma closure que capture a si mesma é coletada
sem nenhum tratamento extra.

### A instrução nova: uma só

```
CALLI <nargs u8>     -- chamada indireta
```

Semântica:

1. desempilha a closure (um array);
2. lê `arr[0]` como inteiro → endereço de destino;
3. empilha um frame com `base = sp - nargs`, exatamente como `CALL`;
4. salta para o endereço.

**Convenção de chamada:** o compilador passa a closure como **argumento 0**.
Dentro do corpo, as variáveis livres são lidas com `LOAD 0` seguido de
`AGET i` — instruções que já existem. Os argumentos reais ficam nos slots
`1..n`.

Não é preciso `OP_CLOSURE`: alocar a closure é `PUSH tamanho; NEWARR` seguido
de `ASET` para cada campo, tudo com instruções existentes. **Uma instrução
nova resolve o problema inteiro.**

### Por que `CALLI` e não um ponteiro de função cru

Porque o alvo passa a vir de dados em tempo de execução, e dado pode estar
errado. `CALLI` precisa validar que `arr[0]` é um endereço dentro do código —
caso contrário um programa mal compilado saltaria para lugar arbitrário. A
verificação é a mesma que o `CALL` já faz (`target < 0 || target >= code.len()`),
e custa uma comparação por chamada indireta.

## O que muda em cada lugar

| Onde | Mudança | Tamanho estimado |
|---|---|---|
| `p01/c/include/fvm.h` | `OP_CALLI` no enum e na tabela de opcodes | 2 linhas |
| `p01/c/src/vm.c` | caso `OP_CALLI` nos dois modos de dispatch | ~20 linhas |
| `p01/rust/src/chunk.rs` | constante e entrada na tabela | 2 linhas |
| `p01/rust/src/vm.rs` | braço do `match` | ~20 linhas |
| `p01/tests/cases/` | caso `.fasm` exercitando chamada indireta | 1 arquivo |
| `p02/hs/src/Bytecode.hs` | `ICalli Int` | 4 linhas |
| `p02/hs/src/Codegen.hs` | conversão de closures + lambda lifting | ~150 linhas |

O trabalho real está na última linha: **conversão de closures** no compilador.
A VM é a parte fácil.

## Conversão de closures, em três passes

1. **Análise de variáveis livres.** Para cada lambda, calcular o conjunto de
   variáveis que ela usa e que não são seus parâmetros.
2. **Lambda lifting.** Cada lambda vira uma função de topo, com um parâmetro
   extra na posição 0 para a closure, e as ocorrências das variáveis livres
   trocadas por `AGET` sobre esse parâmetro.
3. **Alocação no ponto de criação.** Onde a lambda aparecia, emitir a criação
   do array com o endereço da função levantada e os valores capturados.

Aplicação parcial (`soma 1`, com `soma` de aridade 2) cai no mesmo mecanismo:
gera-se uma função levantada que recebe a closure com o argumento já aplicado.

## Como a compatibilidade é preservada

`OP_CALLI` é **aditiva**: todo `.fbc` existente continua válido, e o formato
não muda (o magic segue `FVM1`). Um `.fbc` que use `CALLI` executado numa VM
antiga falha com "opcode invalido" — erro detectado e reportado, não corrupção
silenciosa. A suíte de compatibilidade cruzada do P01 (42 verificações) passa a
cobrir a instrução nova automaticamente, nas duas implementações.

## Ordem de execução (cumprida nesta ordem)

1. ✅ `OP_CALLI` em C, com dois casos `.fasm` escritos à mão — primeiro na VM,
   para que o compilador tivesse um alvo que já funcionava.
2. ✅ `OP_CALLI` em Rust; a compatibilidade cruzada passou de 42 para 54
   verificações, todas verdes.
3. ✅ Análise de variáveis livres no forge (`Codegen.freeVars`).
4. ✅ Lambda lifting e emissão. Os três casos de `tests/phase2/` mudaram de
   pasta.

O critério de pronto era: os arquivos de `tests/phase2/` **mudam de pasta**.
Mudaram. A pasta não ficou vazia — recebeu a limitação que resta, `let rec`
local, que precisa de uma closure referenciando a si mesma.
