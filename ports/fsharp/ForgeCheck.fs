// ForgeCheck.fs — porte do verificador de tipos da forge para F#.
//
// ## O que este arquivo é
//
// Um **porte do verificador**, não um compilador: lexer, parser e inferência
// de tipos, com saída **byte a byte idêntica** à implementação em Haskell nos
// subcomandos `check` e `types`, sobre os 23 casos de `tests/`. Ver
// `ports/README.md`.
//
// ## A comparação que este porte existe para fazer
//
// F# é a terceira das "linguagens em que compiladores são escritos" do plano
// (Haskell, OCaml, F#), e é a mais interessante das três de comparar com
// OCaml, porque **F# é um descendente direto de OCaml** rodando sobre .NET.
// A pergunta é o que muda quando a mesma família de tipos vai para uma
// plataforma com GC geracional, genéricos reificados e interoperabilidade com
// uma biblioteca imperativa gigante.
//
// Três diferenças apareceram no porte:
//
// **1. Casamento de padrões sobre tuplas é mais limpo.** O `unifica` do OCaml
// precisa de `match (a, b) with`; em F#, `match a, b with` sem parênteses. É
// cosmético, e é o tipo de coisa que F# arrumou.
//
// **2. `Map` de F# é persistente e tem `Map.change`/`Map.add` com a mesma
// semântica do OCaml — mas a união enviesada NÃO existe pronta.** `Map.union`
// não é da biblioteca; aqui ela é uma dobra explícita, e o enviesamento fica
// visível em vez de depender de qual argumento vem primeiro.
//
// **3. A exaustividade é um AVISO, não um erro.** Em OCaml, casamento não
// exaustivo é erro com `-w +a -warn-error +a`; em F#, é o aviso FS0025, e o
// projeto abaixo o promove a erro com `<TreatWarningsAsErrors>`. Sem isso, um
// caso faltando compilaria e explodiria em execução — exatamente o que o
// sistema de tipos devia impedir.
//
// ## Os três detalhes que decidem o casamento byte a byte
//
// Iguais aos do porte em OCaml, e valem repetir porque nenhum é óbvio:
//
// 1. **o contador de variáveis frescas é global ao programa** — o Haskell roda
//    um `runInfer` para todas as declarações, e reiniciar por declaração daria
//    tipos certos com nomes diferentes;
// 2. **`generaliza` ordena LEXICOGRAFICAMENTE** — `Set.toList` do Haskell usa
//    `Ord String`, então `t10` vem antes de `t2`. O `Set` de F# usa
//    `compare` sobre string, que é ordinal: mesma ordem;
// 3. **`compoe s1 s2` é enviesado à esquerda** — as chaves vindas de `s2`
//    ganham das de `s1`.

module ForgeCheck

open System

// ------------------------------------------------------------------- erros

exception Erro of string

let erro fmt = Printf.kprintf (fun s -> raise (Erro s)) fmt

// ------------------------------------------------------------------- tipos

type Tipo =
    | TInt
    | TBool
    | TVar of string
    | TFun of Tipo * Tipo

/// [Scheme (vars, tipo)] é [forall vars. tipo].
type Esquema = Scheme of string list * Tipo

type Subst = Map<string, Tipo>
type Ambiente = Map<string, Esquema>

let substVazia: Subst = Map.empty

let rec aplicaT (s: Subst) (t: Tipo) : Tipo =
    match t with
    | TVar v ->
        match Map.tryFind v s with
        | Some t' -> t'
        | None -> TVar v
    | TFun(a, b) -> TFun(aplicaT s a, aplicaT s b)
    | TInt
    | TBool -> t

let aplicaE (s: Subst) (Scheme(vs, t)) : Esquema =
    // As variáveis quantificadas saem da substituição: estão ligadas pelo
    // próprio esquema, e substituí-las seria captura de variável.
    Scheme(vs, aplicaT (List.fold (fun acc v -> Map.remove v acc) s vs) t)

let aplicaAmb (s: Subst) (env: Ambiente) : Ambiente = Map.map (fun _ sc -> aplicaE s sc) env

/// [compoe s1 s2] aplica s2 e depois s1.
///
/// A ordem importa e é a fonte clássica de bug em Hindley-Milner: compor na
/// ordem errada produz um unificador que não é o mais geral, e o sintoma
/// aparece longe da causa.
///
/// O enviesamento também importa. Em Haskell, `M.map (applyT s1) s2 \`M.union\` s1`
/// é enviesado à ESQUERDA, logo as chaves de s2 ganham. F# não tem união de
/// mapas na biblioteca, então aqui é uma dobra explícita — e o enviesamento
/// fica visível em vez de depender da ordem dos argumentos.
let compoe (s1: Subst) (s2: Subst) : Subst =
    let s2' = Map.map (fun _ t -> aplicaT s1 t) s2
    // Começa de s2' e acrescenta de s1 apenas o que s2' não tem.
    Map.fold (fun acc k v -> if Map.containsKey k acc then acc else Map.add k v acc) s2' s1

let rec ftv (t: Tipo) : Set<string> =
    match t with
    | TVar v -> Set.singleton v
    | TFun(a, b) -> Set.union (ftv a) (ftv b)
    | TInt
    | TBool -> Set.empty

let ftvEsquema (Scheme(vs, t)) : Set<string> = Set.difference (ftv t) (Set.ofList vs)

let ftvAmb (env: Ambiente) : Set<string> =
    Map.fold (fun acc _ sc -> Set.union (ftvEsquema sc) acc) Set.empty env

/// Impressão. Casa com `prettyType` do Haskell: o argumento ESQUERDO de uma
/// seta ganha parênteses, o direito não, porque a seta associa à direita.
let rec prettyTipoP (paren: bool) (t: Tipo) : string =
    match t with
    | TInt -> "Int"
    | TBool -> "Bool"
    | TVar v -> v
    | TFun(a, b) ->
        let dentro = prettyTipoP true a + " -> " + prettyTipoP false b
        if paren then "(" + dentro + ")" else dentro

let prettyTipo (t: Tipo) : string = prettyTipoP false t

let prettyEsquema (Scheme(vs, t)) : string =
    match vs with
    | [] -> prettyTipo t
    | _ -> "forall " + String.Join(" ", vs) + ". " + prettyTipo t

/// Generalização: fecha as variáveis livres do tipo que NÃO aparecem no
/// ambiente. É o que dá polimorfismo ao `let`, e a condição sobre o ambiente é
/// o que impede generalizar a variável de um parâmetro — o chamador é quem
/// escolhe o tipo dela.
///
/// `Set.toList` de F# devolve em ordem crescente de `compare`, que para string
/// é ordinal: mesma ordem do `Data.Set.toList` do Haskell. É por isso que
/// "t10" vem antes de "t2" e a saída de `forge types` casa.
let generaliza (env: Ambiente) (t: Tipo) : Esquema =
    Scheme(Set.toList (Set.difference (ftv t) (ftvAmb env)), t)

/// Unificação com teste de ocorrência.
let rec unifica (a: Tipo) (b: Tipo) : Subst =
    match a, b with
    | TInt, TInt -> substVazia
    | TBool, TBool -> substVazia
    | TFun(l1, r1), TFun(l2, r2) ->
        let s1 = unifica l1 l2
        let s2 = unifica (aplicaT s1 r1) (aplicaT s1 r2)
        compoe s2 s1
    | TVar v, t -> liga v t
    | t, TVar v -> liga v t
    | _ -> erro "nao consegui unificar %s com %s" (prettyTipo a) (prettyTipo b)

/// O teste de ocorrência impede construir um tipo infinito.
///
/// Sem ele, `\x -> x x` unificaria `a` com `a -> b` e a inferência entraria em
/// laço — ou devolveria um tipo cíclico que estoura a pilha só na hora de
/// imprimir. O teste `tipo_infinito.fg` cobre exatamente este caso.
and liga (v: string) (t: Tipo) : Subst =
    if t = TVar v then substVazia
    elif Set.contains v (ftv t) then
        erro "tipo infinito: %s ocorre em %s" v (prettyTipo t)
    else
        Map.ofList [ v, t ]

// --------------------------------------------------------------------- AST

/// O literal inteiro guarda a STRING, não um int.
///
/// O Haskell usa `Integer`, arbitrariamente grande. Um `int64` truncaria um
/// literal maior, e o verificador de tipos não precisa do valor — só do fato
/// de ser Int. Guardar a string preserva a mensagem de erro do parser e evita
/// o truncamento.
type Lit =
    | LInt of string
    | LBool of bool

type BinOp =
    | Add
    | Sub
    | Mul
    | Div
    | Mod
    | Lt
    | Le
    | Gt
    | Ge
    | Eq
    | Ne

type Expr =
    | ELit of Lit
    | EVar of string
    | EBin of BinOp * Expr * Expr
    | ENeg of Expr
    | EIf of Expr * Expr * Expr
    | EApp of Expr * Expr
    | ELam of string * Expr
    /// ELet (recursivo, nome, rhs, corpo)
    | ELet of bool * string * Expr * Expr
    | ESeq of Expr * Expr

type Decl =
    { DRec: bool
      DName: string
      DParams: string list
      DBody: Expr }

// ------------------------------------------------------------------- lexer

type Tok =
    | TkInt of string
    | TkIdent of string
    | TkKw of string
    | TkSym of string
    | TkEOF

type Token = { Tk: Tok; Linha: int; Col: int }

let palavrasChave = [ "let"; "rec"; "in"; "if"; "then"; "else"; "true"; "false" ]

/// Símbolos de dois caracteres vêm PRIMEIRO: a ordem desta lista é
/// significativa. Se "<" fosse testado antes de "<=", a entrada "<=" lexaria
/// como "<" seguido de "=" e o parser daria um erro sem relação com a causa.
let simbolos =
    [ "<="; ">="; "=="; "!="; "->"; "\\"; "+"; "-"; "*"; "/"; "%"; "<"; ">"; "="; "("; ")"; ";" ]

let ehAlpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
let ehDigito c = c >= '0' && c <= '9'
let ehAlfanum c = ehAlpha c || ehDigito c
let ehEspaco (c: char) = c = ' ' || c = '\t' || c = '\r' || c = '\n' || c = '\012'

let tokenize (src: string) : Token list =
    let n = src.Length
    let acc = ResizeArray<Token>()
    let mutable i = 0
    let mutable ln = 1
    let mutable col = 1

    let casaSimbolo pos =
        simbolos
        |> List.tryFind (fun s -> pos + s.Length <= n && src.Substring(pos, s.Length) = s)

    while i < n do
        let c = src.[i]

        if c = '-' && i + 1 < n && src.[i + 1] = '-' then
            // comentário de linha
            while i < n && src.[i] <> '\n' do
                i <- i + 1
        elif c = '\n' then
            i <- i + 1
            ln <- ln + 1
            col <- 1
        elif ehEspaco c then
            i <- i + 1
            col <- col + 1
        elif ehDigito c then
            let ini = i
            while i < n && ehDigito src.[i] do
                i <- i + 1
            let s = src.Substring(ini, i - ini)
            acc.Add { Tk = TkInt s; Linha = ln; Col = col }
            col <- col + s.Length
        elif ehAlpha c || c = '_' then
            let ini = i
            while i < n && (ehAlfanum src.[i] || src.[i] = '_' || src.[i] = '\'') do
                i <- i + 1
            let s = src.Substring(ini, i - ini)
            let t = if List.contains s palavrasChave then TkKw s else TkIdent s
            acc.Add { Tk = t; Linha = ln; Col = col }
            col <- col + s.Length
        else
            match casaSimbolo i with
            | Some s ->
                acc.Add { Tk = TkSym s; Linha = ln; Col = col }
                i <- i + s.Length
                col <- col + s.Length
            | None -> erro "%d:%d: caractere inesperado %A" ln col c

    acc.Add { Tk = TkEOF; Linha = ln; Col = col }
    List.ofSeq acc

// ------------------------------------------------------------------ parser

/// Estado do parser: array de tokens e um índice mutável.
///
/// O Haskell usa mônada de estado sobre lista de tokens. Aqui, índice mutável
/// sobre array é o equivalente direto — mesma semântica, sem definir a mônada.
type Ps = { Toks: Token[]; mutable Pos: int }

let descreve (t: Tok) : string =
    match t with
    | TkInt n -> "o numero " + n
    | TkIdent i -> "o identificador \"" + i + "\""
    | TkKw k -> "a palavra reservada \"" + k + "\""
    | TkSym s -> "\"" + s + "\""
    | TkEOF -> "o fim do arquivo"

let espia (p: Ps) : Tok =
    if p.Pos < p.Toks.Length then p.Toks.[p.Pos].Tk else TkEOF

let atual (p: Ps) : Token =
    if p.Pos < p.Toks.Length then p.Toks.[p.Pos] else p.Toks.[p.Toks.Length - 1]

let avanca (p: Ps) = if p.Pos < p.Toks.Length then p.Pos <- p.Pos + 1

let falha (p: Ps) (msg: string) : 'a =
    let t = atual p
    erro "%d:%d: %s, veio %s" t.Linha t.Col msg (descreve t.Tk)

let aceita (p: Ps) (t: Tok) : bool =
    if espia p = t then
        avanca p
        true
    else
        false

let esperaSym (p: Ps) (s: string) =
    if not (aceita p (TkSym s)) then
        falha p (sprintf "esperava \"%s\"" s)

let esperaKw (p: Ps) (k: string) =
    if not (aceita p (TkKw k)) then
        falha p (sprintf "esperava \"%s\"" k)

let ident (p: Ps) : string =
    match espia p with
    | TkIdent i ->
        avanca p
        i
    | _ -> falha p "esperava um identificador"

/// `foldr ELam` do Haskell: o primeiro parâmetro fica na lambda mais externa.
let rec curryParams (ps: string list) (corpo: Expr) : Expr =
    match ps with
    | [] -> corpo
    | x :: resto -> ELam(x, curryParams resto corpo)

let comecaAtomo (t: Tok) : bool =
    match t with
    | TkInt _
    | TkIdent _ -> true
    | TkKw "true"
    | TkKw "false" -> true
    | TkSym "(" -> true
    | _ -> false

let rec pExpr (p: Ps) : Expr =
    match espia p with
    | TkKw "if" -> pIf p
    | TkKw "let" -> pLet p
    | TkSym "\\" -> pLam p
    | _ -> pSeq p

and pIf (p: Ps) : Expr =
    esperaKw p "if"
    let c = pExpr p
    esperaKw p "then"
    let a = pExpr p
    esperaKw p "else"
    let b = pExpr p
    EIf(c, a, b)

/// `let [rec] nome p1 p2 = rhs in corpo`
///
/// Os parâmetros são currificados aqui, ao contrário das declarações de topo:
/// um `let` local nunca é alvo de CALL direto, então a aridade não precisa ser
/// preservada.
and pLet (p: Ps) : Expr =
    esperaKw p "let"
    let isRec = aceita p (TkKw "rec")
    let nome = ident p
    let ps = pParamList p
    esperaSym p "="
    let rhs = pExpr p
    esperaKw p "in"
    let corpo = pExpr p
    ELet(isRec, nome, curryParams ps rhs, corpo)

and pParamList (p: Ps) : string list =
    match espia p with
    | TkIdent _ ->
        let x = ident p
        x :: pParamList p
    | _ -> []

and pLam (p: Ps) : Expr =
    esperaSym p "\\"
    let primeiro = ident p
    let resto = pParamList p
    esperaSym p "->"
    let b = pExpr p
    curryParams (primeiro :: resto) b

/// `;` associa à direita e tem a precedência mais baixa.
and pSeq (p: Ps) : Expr =
    let l = pCmp p
    if aceita p (TkSym ";") then ESeq(l, pExpr p) else l

/// Comparações NÃO associam: `a < b < c` é erro de sintaxe, não um
/// encadeamento silenciosamente errado como em C.
and pCmp (p: Ps) : Expr =
    let l = pAdd p

    let rel =
        match espia p with
        | TkSym "<" -> Some Lt
        | TkSym "<=" -> Some Le
        | TkSym ">" -> Some Gt
        | TkSym ">=" -> Some Ge
        | TkSym "==" -> Some Eq
        | TkSym "!=" -> Some Ne
        | _ -> None

    match rel with
    | Some o ->
        avanca p
        EBin(o, l, pAdd p)
    | None -> l

and pAdd (p: Ps) : Expr =
    let rec laco l =
        match espia p with
        | TkSym "+" ->
            avanca p
            laco (EBin(Add, l, pMul p))
        | TkSym "-" ->
            avanca p
            laco (EBin(Sub, l, pMul p))
        | _ -> l

    laco (pMul p)

and pMul (p: Ps) : Expr =
    let rec laco l =
        match espia p with
        | TkSym "*" ->
            avanca p
            laco (EBin(Mul, l, pUnary p))
        | TkSym "/" ->
            avanca p
            laco (EBin(Div, l, pUnary p))
        | TkSym "%" ->
            avanca p
            laco (EBin(Mod, l, pUnary p))
        | _ -> l

    laco (pUnary p)

and pUnary (p: Ps) : Expr =
    match espia p with
    | TkSym "-" ->
        avanca p
        ENeg(pUnary p)
    | _ -> pApp p

/// Aplicação: justaposição de átomos, associando à esquerda.
and pApp (p: Ps) : Expr =
    let f = pAtomo p

    let rec args acc =
        if comecaAtomo (espia p) then args (EApp(acc, pAtomo p)) else acc

    args f

and pAtomo (p: Ps) : Expr =
    match espia p with
    | TkInt n ->
        avanca p
        ELit(LInt n)
    | TkKw "true" ->
        avanca p
        ELit(LBool true)
    | TkKw "false" ->
        avanca p
        ELit(LBool false)
    | TkIdent i ->
        avanca p
        EVar i
    | TkSym "(" ->
        avanca p
        let e = pExpr p
        esperaSym p ")"
        e
    | _ -> falha p "esperava uma expressao"

let pDecl (p: Ps) : Decl =
    esperaKw p "let"
    let isRec = aceita p (TkKw "rec")
    let nome = ident p
    let ps = pParamList p
    esperaSym p "="
    let corpo = pExpr p

    { DRec = isRec
      DName = nome
      DParams = ps
      DBody = corpo }

/// Nenhum separador é exigido entre declarações de topo, e isso não é
/// descuido: uma expressão só pode ser ESTENDIDA por um operador infixo ou por
/// aplicação, e `let` não inicia um átomo. Logo, ao terminar o corpo de uma
/// declaração, encontrar `let` só pode significar declaração nova.
let parseProgram (src: string) : Decl list =
    let p = { Toks = Array.ofList (tokenize src); Pos = 0 }

    let rec decls () =
        match espia p with
        | TkKw "let" ->
            let d = pDecl p
            d :: decls ()
        | _ -> []

    let ds = decls ()

    match espia p with
    | TkEOF -> ()
    | t ->
        let tk = atual p
        erro "%d:%d: lixo apos o fim do programa: %s" tk.Linha tk.Col (descreve t)

    if List.isEmpty ds then erro "programa vazio"
    ds

// -------------------------------------------------------------- inferência

/// O contador é GLOBAL ao programa, não por declaração.
///
/// Em Haskell, `inferProgram` roda um único `runInfer` para todas as
/// declarações, então a numeração continua de uma para a outra. Reiniciar aqui
/// daria tipos corretos com NOMES diferentes, e a saída de `forge types`
/// deixaria de casar byte a byte.
let mutable contador = 0

let fresca () : Tipo =
    let n = contador
    contador <- contador + 1
    TVar("t" + string n)

/// Instancia um esquema com variáveis novas. É o que permite usar a mesma
/// função polimórfica em dois tipos diferentes no mesmo programa.
let instancia (Scheme(vs, t)) : Tipo =
    let pares = vs |> List.map (fun v -> v, fresca ())
    aplicaT (Map.ofList pares) t

/// Ambiente inicial. `print` devolve o valor impresso para que
/// `print a; print b` seja tipável sem precisar de um tipo unitário.
let builtins: Ambiente =
    Map.ofList
        [ "print", Scheme([], TFun(TInt, TInt))
          "gc", Scheme([], TFun(TInt, TInt)) ]

let ehAritmetico o = List.contains o [ Add; Sub; Mul; Div; Mod ]
let ehRelacional o = List.contains o [ Lt; Le; Gt; Ge ]

let rec infere (env: Ambiente) (e: Expr) : Subst * Tipo =
    match e with
    | ELit(LInt _) -> substVazia, TInt
    | ELit(LBool _) -> substVazia, TBool
    | EVar x ->
        match Map.tryFind x env with
        | None -> erro "variavel nao definida: %s" x
        | Some sc -> substVazia, instancia sc
    | ELam(x, corpo) ->
        let tv = fresca ()
        let env' = Map.add x (Scheme([], tv)) env
        let s1, t1 = infere env' corpo
        s1, TFun(aplicaT s1 tv, t1)
    | EApp(f, a) ->
        let s1, tf = infere env f
        let s2, ta = infere (aplicaAmb s1 env) a
        let tv = fresca ()
        let s3 = unifica (aplicaT s2 tf) (TFun(ta, tv))
        compoe s3 (compoe s2 s1), aplicaT s3 tv
    | ENeg a ->
        let s1, t1 = infere env a
        let s2 = unifica t1 TInt
        compoe s2 s1, TInt
    | EBin(op, a, b) ->
        let s1, t1 = infere env a
        let s2, t2 = infere (aplicaAmb s1 env) b
        let t1' = aplicaT s2 t1

        if ehAritmetico op then
            let sa = unifica t1' TInt
            let sb = unifica (aplicaT sa t2) TInt
            compoe sb (compoe sa (compoe s2 s1)), TInt
        elif ehRelacional op then
            let sa = unifica t1' TInt
            let sb = unifica (aplicaT sa t2) TInt
            compoe sb (compoe sa (compoe s2 s1)), TBool
        else
            // Igualdade unifica os dois lados em vez de exigir Int: permite
            // comparar Bool com Bool, e a instrução EQ do bytecode já faz
            // isso. O que ela NÃO permite é comparar Int com Bool.
            let sa = unifica t1' (aplicaT s2 t2)
            compoe sa (compoe s2 s1), TBool
    | EIf(c, a, b) ->
        let s1, tc = infere env c
        let s2 = unifica tc TBool
        let s12 = compoe s2 s1
        let env1 = aplicaAmb s12 env
        let s3, ta = infere env1 a
        let s4, tb = infere (aplicaAmb s3 env1) b
        let s5 = unifica (aplicaT s4 ta) tb
        compoe s5 (compoe s4 (compoe s3 s12)), aplicaT s5 tb
    | ESeq(a, b) ->
        let s1, _ = infere env a
        let s2, t2 = infere (aplicaAmb s1 env) b
        compoe s2 s1, t2
    // let não recursivo: generaliza o tipo do rhs ANTES de ligar o nome, o
    // que dá o polimorfismo do let.
    | ELet(false, x, rhs, corpo) ->
        let s1, t1 = infere env rhs
        let env1 = aplicaAmb s1 env
        let sc = generaliza env1 t1
        let s2, t2 = infere (Map.add x sc env1) corpo
        compoe s2 s1, t2
    // let rec: o nome entra no ambiente como MONOMÓRFICO (variável fresca)
    // enquanto o próprio rhs é inferido, e só depois é generalizado.
    // Generalizar antes permitiria que a função usasse a si mesma em dois
    // tipos diferentes, o que Hindley-Milner não garante decidível.
    | ELet(true, x, rhs, corpo) ->
        let tv = fresca ()
        let envR = Map.add x (Scheme([], tv)) env
        let s1, t1 = infere envR rhs
        let s2 = unifica (aplicaT s1 tv) t1
        let s = compoe s2 s1
        let env1 = aplicaAmb s env
        let sc = generaliza env1 (aplicaT s t1)
        let s3, t3 = infere (Map.add x sc env1) corpo
        compoe s3 s, t3

let infereDecl (env: Ambiente) (d: Decl) : Esquema =
    let corpo = curryParams d.DParams d.DBody

    if d.DRec then
        let tv = fresca ()
        let envR = Map.add d.DName (Scheme([], tv)) env
        let s1, t1 = infere envR corpo
        let s2 = unifica (aplicaT s1 tv) t1
        let s = compoe s2 s1
        generaliza (aplicaAmb s env) (aplicaT s t1)
    else
        let s1, t1 = infere env corpo
        generaliza (aplicaAmb s1 env) t1

/// Declarações são processadas em ordem: uma função só vê as anteriores.
///
/// É uma escolha, não limitação acidental — torna a inferência um passe único
/// e obriga o programa a declarar antes de usar.
let infereProgramaMut (prog: Decl list) : Ambiente =
    prog
    |> List.fold
        (fun env d ->
            let sc =
                try
                    infereDecl env d
                with Erro msg ->
                    erro "em '%s': %s" d.DName msg

            Map.add d.DName sc env)
        builtins

// --------------------------------------------------------------------- CLI

let versao = "0.2.0"

let uso () =
    eprintfn "forge_check %s - porte do verificador de tipos da forge (F#)" versao
    eprintfn ""
    eprintfn "uso:"
    eprintfn "  forge_check check <prog.fg>   verifica tipos"
    eprintfn "  forge_check types <prog.fg>   tipo inferido de cada declaracao"
    64

let morre (msg: string) : 'a =
    eprintfn "forge: %s" msg
    exit 1

/// Pipeline comum: ler, lexar, parsear, inferir.
///
/// A checagem de `main` é regra de boa-formação do PROGRAMA, não de geração de
/// código. Na referência em Haskell ela já esteve no Codegen, e o efeito era
/// `forge check` aceitar um programa que `forge build` recusava por um motivo
/// sem relação com backend. O teste `sem_main.fg` pegou isso, e o porte tem de
/// reproduzir o comportamento corrigido.
let frontend (caminho: string) =
    let src =
        try
            IO.File.ReadAllText caminho
        with :? IO.IOException as ex ->
            morre ex.Message

    let prog =
        try
            parseProgram src
        with Erro e ->
            morre (caminho + ":" + e)

    if not (prog |> List.exists (fun d -> d.DName = "main")) then
        morre (caminho + ": o programa precisa de uma declaracao 'main'")

    let env =
        try
            infereProgramaMut prog
        with Erro e ->
            morre ("erro de tipo: " + e)

    prog, env

[<EntryPoint>]
let main argv =
    match List.ofArray argv with
    | [ "version" ] ->
        printfn "forge_check %s" versao
        0
    | [ "check"; caminho ] ->
        let prog, _ = frontend caminho
        printfn "ok: %d declaracoes, tipos conferem" (List.length prog)
        0
    | [ "types"; caminho ] ->
        let prog, env = frontend caminho

        prog
        |> List.iter (fun d ->
            match Map.tryFind d.DName env with
            | Some sc -> printfn "%s : %s" d.DName (prettyEsquema sc)
            | None -> ())

        0
    | _ -> uso ()
