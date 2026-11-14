# Fase 2: closures, e a instrução que falta na VM

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

## Ordem de execução

1. `OP_CALLI` em C, com teste e caso `.fasm` escrito à mão — primeiro na VM,
   para que o compilador tenha um alvo que já funciona.
2. `OP_CALLI` em Rust, verificando que a compatibilidade cruzada segue em 42/42.
3. Análise de variáveis livres no forge, com testes de unidade sobre a AST.
4. Lambda lifting e emissão, liberando os três casos hoje em `tests/phase2/`,
   que passam a ser testes de `tests/ok/`.

O critério de pronto: os arquivos de `tests/phase2/` **mudam de pasta**. É um
critério verificável e não negociável — não há como declarar a fase concluída
sem que os três programas rodem.
