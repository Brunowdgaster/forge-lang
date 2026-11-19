(* forge-check.sml — o verificador de tipos do forge em Standard ML.
 *
 *     mlton -output forge_check ports/sml/forge-check.sml
 *     ./forge_check types prog.fg
 *     bash ports/sml/roda.sh types prog.fg
 *
 * Sexto porte. Mesmo contrato: saída **byte a byte idêntica** à referência em
 * Haskell nos 23 casos, incluindo os nomes das variáveis de tipo e o texto
 * exato das mensagens de erro.
 *
 * ## Por que SML, com OCaml e F# já no diretório
 *
 * Porque ele **fecha a família**. Standard ML é o ancestral dos dois: OCaml é
 * um dialeto dele com objetos e um sistema de módulos diferente, F# é um
 * dialeto do OCaml sobre o .NET, e Haskell nasceu da mesma linhagem com
 * avaliação preguiçosa e classes de tipo.
 *
 * Com os quatro no mesmo algoritmo, a comparação deixa de ser "linguagem X
 * contra linguagem Y" e passa a medir **o que cada geração acrescentou ou
 * tirou** — e as diferenças que sobram entre eles são pequenas e precisas, que
 * é exatamente o que torna a comparação útil.
 *
 * ## Uma palavra reservada que custou a primeira compilação
 *
 * `op` é **reservada** em SML — é o prefixo que transforma um operador infixo
 * em função (`op +`, `op ::`). Usá-la como nome de variável dá:
 *
 *     Error: forge-check.sml 253.24-253.24.
 *       Syntax error: inserting  ASTERISK.
 *
 * O compilador esperava um `*` porque, depois de `op`, a gramática espera um
 * operador — e `,` não é um. A mensagem não menciona palavra reservada, e
 * aponta uma coluna onde não há nada de errado.
 *
 * Em OCaml e F# `op` é um identificador comum. É a diferença mais mesquinha
 * entre os três dialetos de ML deste diretório, e a única que impediu o
 * arquivo de compilar.
 *
 * ## As três diferenças concretas em relação ao OCaml
 *
 * **1. Não há operadores de sequenciamento monádico, e nem o OCaml tem.**
 * Haskell escreve a inferência num bloco `do` sobre `StateT Int (Either
 * String)`. OCaml, F# e SML threadam o contador à mão ou usam uma referência
 * mutável. Este porte usa `ref`, como os outros dois — e vale dizer que é a
 * escolha de quem porta, não da linguagem: SML tem o mesmo poder de escrever
 * a mônada à mão, e ela custaria mais linhas do que o problema vale.
 *
 * **2. `ref` e `!` são do núcleo, e não de biblioteca.** Em SML a mutação é
 * explícita no tipo (`int ref`) e o `!` é o desreferenciamento. O OCaml tem o
 * mesmo; a diferença é cultural — em SML isto é mais raro no código idiomático.
 *
 * **3. A biblioteca padrão é MENOR.** Não há `List.sort_uniq`, não há
 * `List.filter_map`, não há módulo `Set` pronto para strings sem instanciar um
 * functor. Este porte ordena e desduplica à mão, e isso está medido em linhas
 * no `ports/README.md`.
 *
 * ## E uma diferença que decide o casamento byte a byte
 *
 * `generalize` tem de devolver as variáveis em ordem **lexicográfica**, porque
 * o `Data.Set.toList` do Haskell devolve em ordem crescente de `Ord String`.
 * Em SML, `String.compare` dá a mesma ordem de bytes — mas `String.<` também
 * existe e compara do mesmo jeito.
 *
 * O que NÃO serve é ordenar numericamente: `t10` tem de vir **antes** de `t2`,
 * porque `"t10" < "t2"` como texto. Nenhum dos 23 casos chega a `t10`, então
 * este arquivo não seria reprovado por errar isso — e é por esse motivo que a
 * ordenação é lexicográfica **de propósito** e está anotada aqui: um caso
 * futuro com onze variáveis de tipo pegaria a diferença, e eu não quero que
 * ela apareça como um erro sem explicação.
 *)

(* ========================================================================= *)
(* TIPOS                                                                     *)
(* ========================================================================= *)

datatype tipo = TInt | TBool | TVar of string | TFun of tipo * tipo

datatype esquema = Esquema of string list * tipo

datatype expr =
    ELitInt of int
  | ELitBool of bool
  | EVar of string
  | ELam of string * expr
  | EApp of expr * expr
  | ENeg of expr
  | EBin of string * expr * expr
  | EIf of expr * expr * expr
  | ESeq of expr * expr
  | ELet of bool * string * expr * expr

datatype decl = Decl of bool * string * string list * expr

exception ErroForge of string

fun falha msg = raise ErroForge msg

(* ========================================================================= *)
(* LÉXICO                                                                    *)
(* ========================================================================= *)

datatype token =
    TkInt of int
  | TkIdent of string
  | TkKw of string
  | TkSym of string
  | TkEof

val palavrasChave =
  ["let", "rec", "in", "if", "then", "else", "true", "false"]

(* A ordem dos símbolos de dois caracteres ANTES dos de um é significativa, e o
 * `Lexer.hs` tem um comentário sobre isso: se `<` fosse testado antes de `<=`,
 * a entrada `<=` lexaria como `<` seguido de `=` e o erro apareceria no
 * parser, longe da causa. *)
val simbolos =
  ["<=", ">=", "==", "!=", "->", "\\", "+", "-", "*", "/", "%",
   "<", ">", "=", "(", ")", ";"]

fun eLetra c = Char.isAlpha c orelse c = #"_"
fun eAlnum c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"

fun tokenize s =
  let
    val n = String.size s
    fun prefixoEm i sym =
      let val m = String.size sym
      in i + m <= n andalso String.substring (s, i, m) = sym
      end
    fun achaSym i =
      List.find (prefixoEm i) simbolos

    fun laco (i, acc) =
      if i >= n then List.rev acc
      else
        let val c = String.sub (s, i) in
          (* Comentário de linha. Vem ANTES do símbolo `-`, e tem de vir: um
           * `--` lido como dois menos faria `-- comentario` virar expressão, e
           * o erro falaria de sintaxe numa linha que é prosa. *)
          if c = #"-" andalso i + 1 < n andalso String.sub (s, i + 1) = #"-"
          then
            let fun pula j =
                  if j >= n then j
                  else if String.sub (s, j) = #"\n" then j
                  else pula (j + 1)
            in laco (pula i, acc)
            end
          else if Char.isSpace c then laco (i + 1, acc)
          else if Char.isDigit c then
            let
              fun digitos j =
                if j < n andalso Char.isDigit (String.sub (s, j))
                then digitos (j + 1) else j
              val j = digitos i
              val txt = String.substring (s, i, j - i)
            in
              case Int.fromString txt of
                  SOME v => laco (j, TkInt v :: acc)
                | NONE => falha ("numero invalido: " ^ txt)
            end
          else if eLetra c then
            let
              fun palavra j =
                if j < n andalso eAlnum (String.sub (s, j))
                then palavra (j + 1) else j
              val j = palavra i
              val w = String.substring (s, i, j - i)
              val tk = if List.exists (fn k => k = w) palavrasChave
                       then TkKw w else TkIdent w
            in laco (j, tk :: acc)
            end
          else
            case achaSym i of
                SOME sym => laco (i + String.size sym, TkSym sym :: acc)
              | NONE => falha ("caractere inesperado " ^ String.str c)
        end
  in laco (0, [])
  end

(* ========================================================================= *)
(* SINTAXE — descida recursiva devolvendo (arvore, tokens restantes)         *)
(* ========================================================================= *)

fun espia [] = TkEof
  | espia (t :: _) = t

fun eSym (TkSym s) v = s = v
  | eSym _ _ = false

fun eKw (TkKw s) v = s = v
  | eKw _ _ = false

fun exigeSym ts v =
  if eSym (espia ts) v then List.tl ts
  else falha ("esperava '" ^ v ^ "'")

fun exigeKw ts v =
  if eKw (espia ts) v then List.tl ts
  else falha ("esperava '" ^ v ^ "'")

fun exigeIdent ts =
  case espia ts of
      TkIdent x => (x, List.tl ts)
    | _ => falha "esperava um identificador"

fun enrolaLams ([], corpo) = corpo
  | enrolaLams (p :: ps, corpo) = ELam (p, enrolaLams (ps, corpo))

val relOps =
  [("<", "lt"), ("<=", "le"), (">", "gt"),
   (">=", "ge"), ("==", "eq"), ("!=", "ne")]

fun procura (chave, []) = NONE
  | procura (chave, (k, v) :: resto) =
      if k = chave then SOME v else procura (chave, resto)

fun parseExpr ts =
  (case espia ts of
       TkKw "if" =>
         let
           val (c, ts1) = parseExpr (List.tl ts)
           val ts2 = exigeKw ts1 "then"
           val (a, ts3) = parseExpr ts2
           val ts4 = exigeKw ts3 "else"
           val (b, ts5) = parseExpr ts4
         in (EIf (c, a, b), ts5)
         end
     | TkKw "let" =>
         let
           val ts0 = List.tl ts
           val rec_ = eKw (espia ts0) "rec"
           val ts1 = if rec_ then List.tl ts0 else ts0
           val (nome, ts2) = exigeIdent ts1
           val (params, ts3) = parseParams ts2
           val ts4 = exigeSym ts3 "="
           val (rhs, ts5) = parseExpr ts4
           val ts6 = exigeKw ts5 "in"
           val (corpo, ts7) = parseExpr ts6
         in
           (* Os parâmetros são currificados AQUI, ao contrário das
            * declarações de topo: um `let` local nunca é alvo de `CALL`
            * direto, então a aridade não precisa ser preservada. *)
           (ELet (rec_, nome, enrolaLams (params, rhs), corpo), ts7)
         end
     | TkSym "\\" =>
         let
           val (x, ts1) = exigeIdent (List.tl ts)
           val ts2 = exigeSym ts1 "->"
           val (corpo, ts3) = parseExpr ts2
         in (ELam (x, corpo), ts3)
         end
     | _ => parseSeq ts)

(* `;` associa à DIREITA e tem a precedência mais baixa. *)
and parseSeq ts =
  let val (l, ts1) = parseCmp ts in
    if eSym (espia ts1) ";"
    then let val (r, ts2) = parseExpr (List.tl ts1) in (ESeq (l, r), ts2) end
    else (l, ts1)
  end

(* Comparações NÃO associam: `a < b < c` é erro de sintaxe, e não um
 * encadeamento silenciosamente errado como em C. *)
and parseCmp ts =
  let val (l, ts1) = parseAdd ts in
    case espia ts1 of
        TkSym s =>
          (case procura (s, relOps) of
               SOME oper =>
                 let val (r, ts2) = parseAdd (List.tl ts1)
                 in (EBin (oper, l, r), ts2)
                 end
             | NONE => (l, ts1))
      | _ => (l, ts1)
  end

and parseAdd ts =
  let
    val (l0, ts0) = parseMul ts
    fun laco (l, ts) =
      case espia ts of
          TkSym "+" =>
            let val (r, ts2) = parseMul (List.tl ts)
            in laco (EBin ("add", l, r), ts2) end
        | TkSym "-" =>
            let val (r, ts2) = parseMul (List.tl ts)
            in laco (EBin ("sub", l, r), ts2) end
        | _ => (l, ts)
  in laco (l0, ts0)
  end

and parseMul ts =
  let
    val (l0, ts0) = parseUnaria ts
    fun laco (l, ts) =
      case espia ts of
          TkSym "*" =>
            let val (r, ts2) = parseUnaria (List.tl ts)
            in laco (EBin ("mul", l, r), ts2) end
        | TkSym "/" =>
            let val (r, ts2) = parseUnaria (List.tl ts)
            in laco (EBin ("dv", l, r), ts2) end
        | TkSym "%" =>
            let val (r, ts2) = parseUnaria (List.tl ts)
            in laco (EBin ("md", l, r), ts2) end
        | _ => (l, ts)
  in laco (l0, ts0)
  end

and parseUnaria ts =
  if eSym (espia ts) "-"
  then let val (e, ts1) = parseUnaria (List.tl ts) in (ENeg e, ts1) end
  else parseApp ts

(* Aplicação: justaposição de átomos, associando à ESQUERDA. *)
and parseApp ts =
  let
    val (f0, ts0) = parseAtomo ts
    (* `comecaAtomo` é o `startsAtom` do Haskell, e existe para que `f x` seja
     * aplicação e `f + x` não seja. *)
    fun comecaAtomo t =
      case t of
          TkInt _ => true
        | TkIdent _ => true
        | TkKw "true" => true
        | TkKw "false" => true
        | TkSym "(" => true
        | _ => false
    fun laco (f, ts) =
      if comecaAtomo (espia ts)
      then let val (a, ts2) = parseAtomo ts in laco (EApp (f, a), ts2) end
      else (f, ts)
  in laco (f0, ts0)
  end

and parseAtomo ts =
  (case espia ts of
       TkInt v => (ELitInt v, List.tl ts)
     | TkKw "true" => (ELitBool true, List.tl ts)
     | TkKw "false" => (ELitBool false, List.tl ts)
     | TkIdent x => (EVar x, List.tl ts)
     | TkSym "(" =>
         let val (e, ts1) = parseExpr (List.tl ts)
         in (e, exigeSym ts1 ")")
         end
     | _ => falha "esperava uma expressao")

and parseParams ts =
  let
    fun laco (acc, ts) =
      case espia ts of
          TkIdent x => laco (x :: acc, List.tl ts)
        | _ => (List.rev acc, ts)
  in laco ([], ts)
  end

(* Nenhum separador entre declarações de topo, e o `Parser.hs` explica por quê:
 * uma expressão só pode ser ESTENDIDA por operador infixo ou por aplicação, e
 * `let` não inicia um átomo. Então encontrar `let` ao fim de um corpo só pode
 * ser declaração nova. *)
fun parseProgramaCompleto ts =
  let
    fun laco (acc, ts) =
      if eKw (espia ts) "let"
      then
        let
          val ts0 = List.tl ts
          val rec_ = eKw (espia ts0) "rec"
          val ts1 = if rec_ then List.tl ts0 else ts0
          val (nome, ts2) = exigeIdent ts1
          val (params, ts3) = parseParams ts2
          val ts4 = exigeSym ts3 "="
          val (corpo, ts5) = parseExpr ts4
        in laco (Decl (rec_, nome, params, corpo) :: acc, ts5)
        end
      else List.rev acc
  in laco ([], ts)
  end

(* ========================================================================= *)
(* SUBSTITUIÇÕES E UNIFICAÇÃO — espelho de Types.hs                          *)
(* ========================================================================= *)
(*
 * A biblioteca padrão de SML é a mais enxuta das quatro linguagens da família:
 * não há `Set` pronto para strings sem instanciar um functor, não há
 * `sort_uniq`, não há `filter_map`. As funções abaixo existem por isso, e são
 * parte do que este porte mede.
 *)

fun ordenaUnico lista =
  let
    (* Ordenação por inserção, que basta para listas de 2 ou 3 elementos — que
     * é o tamanho real aqui. Um `mergesort` seria mais rápido e mais longo, e
     * nada neste projeto mede tempo. *)
    fun insere (x, []) = [x]
      | insere (x, y :: ys) =
          if x = y then y :: ys
          else if String.< (x, y) then x :: y :: ys
          else y :: insere (x, ys)
  in List.foldl insere [] lista
  end

fun semEstes (lista, excluir) =
  List.filter (fn x => not (List.exists (fn y => y = x) excluir)) lista

fun procuraTipo (v, []) = NONE
  | procuraTipo (v, (k, t) :: resto) =
      if k = v then SOME t else procuraTipo (v, resto)

fun applyT (s, t) =
  case t of
      TVar v => (case procuraTipo (v, s) of SOME t2 => t2 | NONE => t)
    | TFun (a, b) => TFun (applyT (s, a), applyT (s, b))
    | _ => t

(* As variáveis quantificadas são REMOVIDAS da substituição antes de aplicar:
 * elas estão ligadas pelo próprio esquema, e substituí-las seria captura de
 * variável. É o `foldr M.delete s vs` do Haskell. *)
fun applyS (s, Esquema (vs, t)) =
  let val s2 = List.filter
                 (fn (k, _) => not (List.exists (fn v => v = k) vs)) s
  in Esquema (vs, applyT (s2, t))
  end

fun applyEnv (s, env) =
  List.map (fn (n, sc) => (n, applyS (s, sc))) env

(* compose (s1, s2) == composeSubst s1 s2 == aplica s2, depois s1
 *
 * `M.map (applyT s1) s2 `M.union` s1`, e o `M.union` do Haskell é
 * LEFT-BIASED: as entradas de s2 (já mapeadas) vencem as de s1. Com a busca
 * achando a PRIMEIRA ocorrência, `@` dá o mesmo resultado.
 *
 * A ORDEM desta composição é o bug clássico de implementações de
 * Hindley-Milner: compor ao contrário produz um unificador que não é o mais
 * geral, e o sintoma aparece longe da causa. *)
fun compose (s1, s2) =
  List.map (fn (v, t) => (v, applyT (s1, t))) s2 @ s1

fun ftvBruto t =
  case t of
      TVar v => [v]
    | TFun (a, b) => ftvBruto a @ ftvBruto b
    | _ => []

(* O resultado é ORDENADO e sem repetição, porque o Haskell usa `Data.Set` e o
 * `S.toList` dele devolve em ordem crescente -- LEXICOGRÁFICA, ver o
 * cabeçalho. É isso que fixa a ordem do `forall t2 t3 t4`. *)
fun ftv t = ordenaUnico (ftvBruto t)

fun ftvEsquema (Esquema (vs, t)) = semEstes (ftv t, vs)

fun ftvEnv env =
  ordenaUnico (List.concat (List.map (fn (_, sc) => ftvEsquema sc) env))

(* Fecha as variáveis livres do tipo que NÃO aparecem no ambiente. A condição
 * sobre o ambiente é o que impede generalizar a variável de um parâmetro de
 * função — seria incorreto, porque quem escolhe o tipo dela é o chamador. *)
fun generalize (env, t) = Esquema (semEstes (ftv t, ftvEnv env), t)

fun prettyType t =
  let
    fun pt (paren, t) =
      case t of
          TInt => "Int"
        | TBool => "Bool"
        | TVar v => v
        | TFun (a, b) =>
            let val interno = pt (true, a) ^ " -> " ^ pt (false, b)
            in if paren then "(" ^ interno ^ ")" else interno
            end
  in pt (false, t)
  end

fun prettyEsquema (Esquema ([], t)) = prettyType t
  | prettyEsquema (Esquema (vs, t)) =
      "forall " ^ String.concatWith " " vs ^ ". " ^ prettyType t

(* Unificação com teste de ocorrência, como o Haskell faz à mão. *)
fun unify (a, b) =
  case (a, b) of
      (TInt, TInt) => []
    | (TBool, TBool) => []
    | (TFun (l1, r1), TFun (l2, r2)) =>
        let
          val s1 = unify (l1, l2)
          val s2 = unify (applyT (s1, r1), applyT (s1, r2))
        in compose (s2, s1)
        end
    | (TVar v, t) => ligaVar (v, t)
    | (t, TVar v) => ligaVar (v, t)
    | _ => falha ("nao consegui unificar " ^ prettyType a
                  ^ " com " ^ prettyType b)

(* O teste de ocorrência é o que impede construir um tipo infinito. Sem ele,
 * `\x -> x x` unificaria `a` com `a -> b` e a inferência entraria em laço — ou
 * devolveria um tipo cíclico que estoura a pilha só na hora de imprimir. *)
and ligaVar (v, t) =
  if t = TVar v then []
  else if List.exists (fn x => x = v) (ftv t)
  then falha ("tipo infinito: " ^ v ^ " ocorre em " ^ prettyType t)
  else [(v, t)]

(* ========================================================================= *)
(* INFERÊNCIA — Algoritmo W, espelho de Infer.hs                             *)
(* ========================================================================= *)
(*
 * O contador de variáveis frescas é um `ref`, e não um parâmetro passado
 * adiante — a mesma decisão dos portes em OCaml, F#, Racket e Common Lisp,
 * pelo mesmo motivo: cada regra já devolve um par (substituição, tipo), e
 * acrescentar o contador faria devolver uma tripla e desempacotar três
 * valores em cada chamada.
 *
 * O contador é ÚNICO para o programa inteiro: o `inferProgram` roda todas as
 * declarações num só `runInfer`, e é por isso que o primeiro tipo de
 * `composicao.fg` começa em `t2` e não em `t0`.
 *)

val contador = ref 0

fun fresh () =
  let val n = !contador
  in contador := n + 1; TVar ("t" ^ Int.toString n)
  end

(* Uma variável fresca por variável quantificada, NA ORDEM da lista. É o que
 * permite usar a mesma função polimórfica em dois tipos diferentes no mesmo
 * programa. *)
fun instantiate (Esquema (vs, t)) =
  applyT (List.map (fn v => (v, fresh ())) vs, t)

val builtins =
  [("print", Esquema ([], TFun (TInt, TInt))),
   ("gc", Esquema ([], TFun (TInt, TInt)))]

fun procuraEsq (x, []) = NONE
  | procuraEsq (x, (k, sc) :: resto) =
      if k = x then SOME sc else procuraEsq (x, resto)

fun infer (env, e) =
  case e of
      ELitInt _ => ([], TInt)
    | ELitBool _ => ([], TBool)

    | EVar x =>
        (case procuraEsq (x, env) of
             NONE => falha ("variavel nao definida: " ^ x)
           | SOME sc => ([], instantiate sc))

    | ELam (x, corpo) =>
        let
          val tv = fresh ()
          val (s1, t1) = infer ((x, Esquema ([], tv)) :: env, corpo)
        in (s1, TFun (applyT (s1, tv), t1))
        end

    | EApp (f, a) =>
        let
          val (s1, tf) = infer (env, f)
          val (s2, ta) = infer (applyEnv (s1, env), a)
          val tv = fresh ()
          val s3 = unify (applyT (s2, tf), TFun (ta, tv))
        in (compose (s3, compose (s2, s1)), applyT (s3, tv))
        end

    | ENeg a =>
        let
          val (s1, t1) = infer (env, a)
          val s2 = unify (t1, TInt)
        in (compose (s2, s1), TInt)
        end

    | EBin (oper, a, b) =>
        let
          val (s1, t1) = infer (env, a)
          val (s2, t2) = infer (applyEnv (s1, env), b)
          val t1' = applyT (s2, t1)
          val aritmetico = List.exists (fn x => x = oper)
                             ["add", "sub", "mul", "dv", "md"]
          val comparacao = List.exists (fn x => x = oper)
                             ["lt", "le", "gt", "ge"]
        in
          if aritmetico then
            let
              val sa = unify (t1', TInt)
              val sb = unify (applyT (sa, t2), TInt)
            in (compose (sb, compose (sa, compose (s2, s1))), TInt)
            end
          else if comparacao then
            let
              val sa = unify (t1', TInt)
              val sb = unify (applyT (sa, t2), TInt)
            in (compose (sb, compose (sa, compose (s2, s1))), TBool)
            end
          else
            (* Igualdade UNIFICA os dois lados em vez de exigir Int: permite
             * comparar Bool com Bool, e a instrução EQ do bytecode já faz
             * isso. O que ela não permite é comparar Int com Bool, que é o
             * erro real. *)
            let val sa = unify (t1', applyT (s2, t2))
            in (compose (sa, compose (s2, s1)), TBool)
            end
        end

    | EIf (c, a, b) =>
        let
          val (s1, tc) = infer (env, c)
          val s2 = unify (tc, TBool)
          val s12 = compose (s2, s1)
          val env1 = applyEnv (s12, env)
          val (s3, ta) = infer (env1, a)
          val (s4, tb) = infer (applyEnv (s3, env1), b)
          val s5 = unify (applyT (s4, ta), tb)
        in
          (compose (s5, compose (s4, compose (s3, s12))), applyT (s5, tb))
        end

    | ESeq (a, b) =>
        let
          val (s1, _) = infer (env, a)
          val (s2, t2) = infer (applyEnv (s1, env), b)
        in (compose (s2, s1), t2)
        end

    (* let NÃO recursivo: generaliza o tipo do rhs ANTES de ligar o nome, o que
     * é de onde vem o polimorfismo do let. *)
    | ELet (false, x, rhs, corpo) =>
        let
          val (s1, t1) = infer (env, rhs)
          val env1 = applyEnv (s1, env)
          val sc = generalize (env1, t1)
          val (s2, t2) = infer ((x, sc) :: env1, corpo)
        in (compose (s2, s1), t2)
        end

    (* let rec: o nome entra no ambiente como MONOMÓRFICO (variável fresca)
     * enquanto o próprio rhs é inferido, e só depois é generalizado.
     * Generalizar antes permitiria que a função usasse a si mesma em dois
     * tipos diferentes, o que Hindley-Milner não garante decidível. *)
    | ELet (true, x, rhs, corpo) =>
        let
          val tv = fresh ()
          val (s1, t1) = infer ((x, Esquema ([], tv)) :: env, rhs)
          val s2 = unify (applyT (s1, tv), t1)
          val s = compose (s2, s1)
          val env1 = applyEnv (s, env)
          val sc = generalize (env1, applyT (s, t1))
          val (s3, t3) = infer ((x, sc) :: env1, corpo)
        in (compose (s3, s), t3)
        end

fun inferDecl (env, Decl (rec_, nome, params, corpoBruto)) =
  let val corpo = enrolaLams (params, corpoBruto) in
    if rec_ then
      let
        val tv = fresh ()
        val (s1, t1) = infer ((nome, Esquema ([], tv)) :: env, corpo)
        val s2 = unify (applyT (s1, tv), t1)
        val s = compose (s2, s1)
      in generalize (applyEnv (s, env), applyT (s, t1))
      end
    else
      let val (s1, t1) = infer (env, corpo)
      in generalize (applyEnv (s1, env), t1)
      end
  end

(* Declarações são processadas EM ORDEM: uma função só vê as anteriores. É
 * escolha e não limitação acidental — torna a inferência um passe único e
 * obriga a declarar antes de usar. *)
fun inferPrograma decls =
  let
    val _ = contador := 0
    fun laco (env, [], acc) = List.rev acc
      | laco (env, d :: ds, acc) =
          let
            val Decl (_, nome, _, _) = d
            val sc = inferDecl (env, d)
                     handle ErroForge m =>
                       falha ("em '" ^ nome ^ "': " ^ m)
          in laco ((nome, sc) :: env, ds, (nome, sc) :: acc)
          end
  in laco (builtins, decls, [])
  end

(* ========================================================================= *)
(* PONTO DE ENTRADA                                                          *)
(* ========================================================================= *)

fun leArquivo caminho =
  let
    val canal = TextIO.openIn caminho
                handle _ => falha (caminho ^ ": nao consegui ler o arquivo")
    val conteudo = TextIO.inputAll canal
  in TextIO.closeIn canal; conteudo
  end

(* `frontend` é o caminho comum de `check` e `types`, pelo mesmo motivo que no
 * `Main.hs`: as duas leem, lexam, parseiam, exigem `main` e inferem — e só
 * divergem no que IMPRIMEM.
 *
 * Ter um só lugar para isso importa aqui mais que de costume: o
 * `ports/verifica.sh` compara `types` nos 17 casos de sucesso e `check` nos 6
 * de erro. Com a checagem de `main` só no caminho de `types`, o caso
 * `sem_main.fg` passaria sem verificar nada — foi o defeito que o porte em
 * Prolog teve. *)
fun frontend caminho =
  let
    val src = leArquivo caminho
    val decls = parseProgramaCompleto (tokenize src)
    val temMain = List.exists (fn Decl (_, n, _, _) => n = "main") decls
    val _ = if temMain then ()
            else falha (caminho ^ ": o programa precisa de uma declaracao 'main'")
    val tipos = inferPrograma decls
                handle ErroForge m => falha ("erro de tipo: " ^ m)
  in (decls, tipos)
  end

fun principal () =
  let
    val args = CommandLine.arguments ()
  in
    (case args of
         ["version"] =>
           print "forge-sml (porte do verificador)\n"
       | ["types", caminho] =>
           let val (_, tipos) = frontend caminho
           in List.app
                (fn (n, sc) => print (n ^ " : " ^ prettyEsquema sc ^ "\n"))
                tipos
           end
       | ["check", caminho] =>
           let val (decls, _) = frontend caminho
           in print ("ok: " ^ Int.toString (List.length decls)
                     ^ " declaracoes, tipos conferem\n")
           end
       | _ =>
           (TextIO.output (TextIO.stdErr,
             "uso: forge_check {check|types|version} <prog.fg>\n");
            OS.Process.exit (OS.Process.failure)))
    handle ErroForge m =>
      (TextIO.output (TextIO.stdErr, "forge: " ^ m ^ "\n");
       OS.Process.exit (OS.Process.failure))
  end

val () = principal ()
