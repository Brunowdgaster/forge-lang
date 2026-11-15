(* forge_check.ml — porte do verificador de tipos da forge para OCaml.
 *
 * ## O que este arquivo é, e o que ele não é
 *
 * Um **porte do verificador**, não um compilador. Ele faz lexer, parser e
 * inferência de tipos, e tem de produzir a **saída byte a byte idêntica** à
 * implementação em Haskell nos subcomandos `check` e `types`, sobre os 22
 * programas de `tests/`.
 *
 * O que ele deliberadamente **não** tem: geração de código, montador, `emit`,
 * `ast`. Essas partes ficam na implementação de referência.
 *
 * ## O alvo de verificação é mais severo do que "aceita/recusa"
 *
 * `forge types` imprime o tipo inferido de cada declaração, incluindo os
 * **nomes das variáveis de tipo**:
 *
 *     compose : forall t2 t3 t4. (t3 -> t4) -> (t2 -> t3) -> t2 -> t4
 *
 * Casar isso byte a byte obriga este porte a gerar variáveis frescas na
 * **mesma ordem** que o Haskell — ou seja, a percorrer a árvore na mesma ordem
 * em cada regra do Algoritmo W. Qualquer divergência de travessia aparece como
 * um número diferente.
 *
 * É o análogo, aqui, da exigência de bytecode byte-idêntico nos portes do P01.
 *
 * ## Três detalhes que decidem o casamento, e que eu não teria adivinhado
 *
 * 1. **O contador de variáveis frescas é global ao programa.** Em Haskell,
 *    `inferProgram` roda UM `runInfer` para todas as declarações, então a
 *    numeração continua de uma para a outra. Reiniciar por declaração daria
 *    tipos corretos com nomes diferentes.
 *
 * 2. **`generalize` ordena lexicograficamente, não numericamente.**
 *    `Data.Set.toList` devolve em ordem crescente de `Ord String`, então
 *    `t10` vem **antes** de `t2`. O `Set.Make(String).elements` do OCaml usa
 *    `String.compare`, que é a mesma ordem de bytes — por sorte, e está
 *    anotado aqui para quem portar para uma linguagem onde não seja.
 *
 * 3. **`composeSubst s1 s2` tem união enviesada à esquerda.** Em Haskell,
 *    `M.map (applyT s1) s2 \`M.union\` s1` faz as chaves vindas de `s2`
 *    ganharem. O `Map.union` do OCaml recebe uma função de resolução, então
 *    aqui a escolha é explícita em vez de implícita na biblioteca.
 *
 * ## O que o OCaml deu, e o que cobrou
 *
 * **Deu:** tipos algébricos com casamento de padrões exaustivo verificado pelo
 * compilador — a mesma garantia do Haskell, e a razão pela qual este porte é
 * uma tradução quase linha a linha em vez de uma reescrita.
 *
 * **Cobrou:** o Haskell usa `StateT Int (Either String)` para carregar o
 * contador e o erro. OCaml não tem mônadas na biblioteca padrão nem açúcar de
 * `do`, então aqui o contador é uma **referência mutável** e o erro é uma
 * **exceção**. É menos elegante e igualmente correto — e, para um algoritmo
 * com estado linear como este, mais direto de ler.
 *
 * uso: forge_check check <prog.fg>
 *      forge_check types <prog.fg>
 *)

(* ------------------------------------------------------------------ erros *)

exception Erro of string

let erro fmt = Printf.ksprintf (fun s -> raise (Erro s)) fmt

(* ------------------------------------------------------------------ tipos *)

type tipo =
  | TInt
  | TBool
  | TVar of string
  | TFun of tipo * tipo

(* [Scheme (vars, tipo)] é [forall vars. tipo]. *)
type esquema = Scheme of string list * tipo

module SMap = Map.Make (String)
module SSet = Set.Make (String)

type subst = tipo SMap.t
type ambiente = esquema SMap.t

let subst_vazia : subst = SMap.empty

let rec aplica_t (s : subst) (t : tipo) : tipo =
  match t with
  | TVar v -> (match SMap.find_opt v s with Some t' -> t' | None -> TVar v)
  | TFun (a, b) -> TFun (aplica_t s a, aplica_t s b)
  | TInt | TBool -> t

let aplica_e (s : subst) (Scheme (vs, t)) : esquema =
  (* As variáveis quantificadas saem da substituição: estão ligadas pelo
     próprio esquema, e substituí-las seria captura de variável. *)
  Scheme (vs, aplica_t (List.fold_left (fun acc v -> SMap.remove v acc) s vs) t)

let aplica_amb (s : subst) (env : ambiente) : ambiente = SMap.map (aplica_e s) env

(* [compoe s1 s2] aplica s2 e depois s1.
 *
 * A ordem importa e é a fonte clássica de bug em Hindley-Milner: compor na
 * ordem errada produz um unificador que não é o mais geral, e o sintoma
 * aparece longe da causa.
 *
 * O enviesamento também importa: em Haskell, `M.union` é enviesado à
 * ESQUERDA, e a expressão é `M.map (applyT s1) s2 \`M.union\` s1` — logo as
 * chaves de s2 ganham das de s1. Aqui isso fica explícito na função de
 * resolução, porque `Map.union` do OCaml exige uma. *)
let compoe (s1 : subst) (s2 : subst) : subst =
  let s2' = SMap.map (aplica_t s1) s2 in
  SMap.union (fun _ do_s2 _do_s1 -> Some do_s2) s2' s1

let rec ftv (t : tipo) : SSet.t =
  match t with
  | TVar v -> SSet.singleton v
  | TFun (a, b) -> SSet.union (ftv a) (ftv b)
  | TInt | TBool -> SSet.empty

let ftv_esquema (Scheme (vs, t)) : SSet.t =
  SSet.diff (ftv t) (SSet.of_list vs)

let ftv_amb (env : ambiente) : SSet.t =
  SMap.fold (fun _ sc acc -> SSet.union (ftv_esquema sc) acc) env SSet.empty

(* Impressão. Precisa casar com `prettyType` do Haskell exatamente: o
   argumento ESQUERDO de uma seta ganha parênteses, o direito não, porque a
   seta associa à direita. *)
let rec pretty_tipo_p (paren : bool) (t : tipo) : string =
  match t with
  | TInt -> "Int"
  | TBool -> "Bool"
  | TVar v -> v
  | TFun (a, b) ->
      let dentro = pretty_tipo_p true a ^ " -> " ^ pretty_tipo_p false b in
      if paren then "(" ^ dentro ^ ")" else dentro

let pretty_tipo (t : tipo) : string = pretty_tipo_p false t

let pretty_esquema (Scheme (vs, t)) : string =
  match vs with
  | [] -> pretty_tipo t
  | _ -> "forall " ^ String.concat " " vs ^ ". " ^ pretty_tipo t

(* Generalização: fecha as variáveis livres do tipo que NÃO aparecem no
   ambiente. É o que dá polimorfismo ao `let`, e a condição sobre o ambiente é
   o que impede generalizar a variável de um parâmetro — o chamador é quem
   escolhe o tipo dela.
 *
 * `SSet.elements` devolve em ordem crescente de `String.compare`, igual ao
 * `Data.Set.toList` do Haskell: ordem de BYTES, então "t10" < "t2". É por isso
 * que a saída de `forge types` casa. *)
let generaliza (env : ambiente) (t : tipo) : esquema =
  Scheme (SSet.elements (SSet.diff (ftv t) (ftv_amb env)), t)

(* Unificação com teste de ocorrência. *)
let rec unifica (a : tipo) (b : tipo) : subst =
  match (a, b) with
  | TInt, TInt -> subst_vazia
  | TBool, TBool -> subst_vazia
  | TFun (l1, r1), TFun (l2, r2) ->
      let s1 = unifica l1 l2 in
      let s2 = unifica (aplica_t s1 r1) (aplica_t s1 r2) in
      compoe s2 s1
  | TVar v, t -> liga v t
  | t, TVar v -> liga v t
  | _ ->
      erro "nao consegui unificar %s com %s" (pretty_tipo a) (pretty_tipo b)

(* O teste de ocorrência impede construir um tipo infinito.
 *
 * Sem ele, `\x -> x x` unificaria `a` com `a -> b` e a inferência entraria em
 * laço — ou devolveria um tipo cíclico que estoura a pilha só na hora de
 * imprimir. O teste `tipo_infinito.fg` cobre exatamente este caso. *)
and liga (v : string) (t : tipo) : subst =
  if t = TVar v then subst_vazia
  else if SSet.mem v (ftv t) then
    erro "tipo infinito: %s ocorre em %s" v (pretty_tipo t)
  else SMap.singleton v t

(* -------------------------------------------------------------------- AST *)

type lit = LInt of string | LBool of bool

(* O literal inteiro guarda a STRING, não um int.
 *
 * O Haskell usa `Integer`, que é arbitrariamente grande, e o `describe` do
 * parser imprime `show n`. Um `int` de 63 bits do OCaml truncaria silenciosamente
 * um literal grande, e o verificador de tipos não precisa do valor — só do
 * fato de ser Int. Guardar a string preserva a mensagem de erro e evita o
 * truncamento. *)

type binop = Add | Sub | Mul | Div | Mod | Lt | Le | Gt | Ge | Eq | Ne

type expr =
  | ELit of lit
  | EVar of string
  | EBin of binop * expr * expr
  | ENeg of expr
  | EIf of expr * expr * expr
  | EApp of expr * expr
  | ELam of string * expr
  | ELet of bool * string * expr * expr  (* recursivo, nome, rhs, corpo *)
  | ESeq of expr * expr

type decl = { d_rec : bool; d_name : string; d_params : string list; d_body : expr }

(* ------------------------------------------------------------------ lexer *)

type tok =
  | TkInt of string
  | TkIdent of string
  | TkKw of string
  | TkSym of string
  | TkEOF

type token = { tk : tok; linha : int; col : int }

let palavras_chave = [ "let"; "rec"; "in"; "if"; "then"; "else"; "true"; "false" ]

(* Símbolos de dois caracteres vêm PRIMEIRO: a ordem desta lista é
   significativa. Se "<" fosse testado antes de "<=", a entrada "<=" lexaria
   como "<" seguido de "=" e o parser daria um erro sem relação com a causa. *)
let simbolos =
  [ "<="; ">="; "=="; "!="; "->"; "\\"; "+"; "-"; "*"; "/"; "%"; "<"; ">"; "="
  ; "("; ")"; ";" ]

let eh_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
let eh_digito c = c >= '0' && c <= '9'
let eh_alfanum c = eh_alpha c || eh_digito c
let eh_espaco c = c = ' ' || c = '\t' || c = '\r' || c = '\n' || c = '\012'

let tokenize (src : string) : token list =
  let n = String.length src in
  let acc = ref [] in
  let i = ref 0 and ln = ref 1 and col = ref 1 in
  let emite tk l c = acc := { tk; linha = l; col = c } :: !acc in

  let casa_simbolo pos =
    List.find_opt
      (fun s ->
        let m = String.length s in
        pos + m <= n && String.sub src pos m = s)
      simbolos
  in

  while !i < n do
    let c = src.[!i] in
    if c = '-' && !i + 1 < n && src.[!i + 1] = '-' then begin
      (* comentário de linha *)
      while !i < n && src.[!i] <> '\n' do incr i done
    end
    else if c = '\n' then begin incr i; incr ln; col := 1 end
    else if eh_espaco c then begin incr i; incr col end
    else if eh_digito c then begin
      let ini = !i in
      while !i < n && eh_digito src.[!i] do incr i done;
      let s = String.sub src ini (!i - ini) in
      emite (TkInt s) !ln !col;
      col := !col + String.length s
    end
    else if eh_alpha c || c = '_' then begin
      let ini = !i in
      while
        !i < n && (eh_alfanum src.[!i] || src.[!i] = '_' || src.[!i] = '\'')
      do incr i done;
      let s = String.sub src ini (!i - ini) in
      let t = if List.mem s palavras_chave then TkKw s else TkIdent s in
      emite t !ln !col;
      col := !col + String.length s
    end
    else
      match casa_simbolo !i with
      | Some s ->
          emite (TkSym s) !ln !col;
          i := !i + String.length s;
          col := !col + String.length s
      | None -> erro "%d:%d: caractere inesperado %C" !ln !col c
  done;

  emite TkEOF !ln !col;
  List.rev !acc

(* ----------------------------------------------------------------- parser *)

(* Estado do parser: array de tokens e um índice.
 *
 * O Haskell usa uma mônada de estado sobre lista de tokens. Em OCaml, índice
 * mutável sobre array é o equivalente direto e dispensa definir a mônada —
 * mesma semântica, menos cerimônia. *)
type ps = { toks : token array; mutable pos : int }

let descreve (t : tok) : string =
  match t with
  | TkInt n -> "o numero " ^ n
  | TkIdent i -> "o identificador " ^ "\"" ^ i ^ "\""
  | TkKw k -> "a palavra reservada " ^ "\"" ^ k ^ "\""
  | TkSym s -> "\"" ^ s ^ "\""
  | TkEOF -> "o fim do arquivo"

let espia (p : ps) : tok =
  if p.pos < Array.length p.toks then p.toks.(p.pos).tk else TkEOF

let atual (p : ps) : token =
  if p.pos < Array.length p.toks then p.toks.(p.pos)
  else p.toks.(Array.length p.toks - 1)

let avanca (p : ps) : unit = if p.pos < Array.length p.toks then p.pos <- p.pos + 1

let falha (p : ps) (msg : string) : 'a =
  let t = atual p in
  erro "%d:%d: %s, veio %s" t.linha t.col msg (descreve t.tk)

let aceita (p : ps) (t : tok) : bool =
  if espia p = t then begin avanca p; true end else false

let espera_sym (p : ps) (s : string) : unit =
  if not (aceita p (TkSym s)) then falha p (Printf.sprintf "esperava \"%s\"" s)

let espera_kw (p : ps) (k : string) : unit =
  if not (aceita p (TkKw k)) then falha p (Printf.sprintf "esperava \"%s\"" k)

let ident (p : ps) : string =
  match espia p with
  | TkIdent i -> avanca p; i
  | _ -> falha p "esperava um identificador"

(* `foldr ELam` do Haskell: o primeiro parâmetro fica na lambda mais externa. *)
let rec curry_params (ps_ : string list) (corpo : expr) : expr =
  match ps_ with [] -> corpo | x :: resto -> ELam (x, curry_params resto corpo)

let comeca_atomo (t : tok) : bool =
  match t with
  | TkInt _ | TkIdent _ -> true
  | TkKw "true" | TkKw "false" -> true
  | TkSym "(" -> true
  | _ -> false

let rec p_expr (p : ps) : expr =
  match espia p with
  | TkKw "if" -> p_if p
  | TkKw "let" -> p_let p
  | TkSym "\\" -> p_lam p
  | _ -> p_seq p

and p_if (p : ps) : expr =
  espera_kw p "if";
  let c = p_expr p in
  espera_kw p "then";
  let a = p_expr p in
  espera_kw p "else";
  let b = p_expr p in
  EIf (c, a, b)

(* `let [rec] nome p1 p2 = rhs in corpo`
 *
 * Os parâmetros são currificados aqui, ao contrário das declarações de topo:
 * um `let` local nunca é alvo de CALL direto, então a aridade não precisa ser
 * preservada. *)
and p_let (p : ps) : expr =
  espera_kw p "let";
  let is_rec = aceita p (TkKw "rec") in
  let nome = ident p in
  let ps_ = p_param_list p in
  espera_sym p "=";
  let rhs = p_expr p in
  espera_kw p "in";
  let corpo = p_expr p in
  ELet (is_rec, nome, curry_params ps_ rhs, corpo)

and p_param_list (p : ps) : string list =
  match espia p with
  | TkIdent _ ->
      let x = ident p in
      x :: p_param_list p
  | _ -> []

and p_lam (p : ps) : expr =
  espera_sym p "\\";
  let primeiro = ident p in
  let resto = p_param_list p in
  espera_sym p "->";
  let b = p_expr p in
  curry_params (primeiro :: resto) b

(* `;` associa à direita e tem a precedência mais baixa. *)
and p_seq (p : ps) : expr =
  let l = p_cmp p in
  if aceita p (TkSym ";") then ESeq (l, p_expr p) else l

(* Comparações NÃO associam: `a < b < c` é erro de sintaxe, não um
   encadeamento silenciosamente errado como em C. *)
and p_cmp (p : ps) : expr =
  let l = p_add p in
  let rel =
    match espia p with
    | TkSym "<" -> Some Lt
    | TkSym "<=" -> Some Le
    | TkSym ">" -> Some Gt
    | TkSym ">=" -> Some Ge
    | TkSym "==" -> Some Eq
    | TkSym "!=" -> Some Ne
    | _ -> None
  in
  match rel with
  | Some o -> avanca p; EBin (o, l, p_add p)
  | None -> l

and p_add (p : ps) : expr =
  let rec laco l =
    match espia p with
    | TkSym "+" -> avanca p; laco (EBin (Add, l, p_mul p))
    | TkSym "-" -> avanca p; laco (EBin (Sub, l, p_mul p))
    | _ -> l
  in
  laco (p_mul p)

and p_mul (p : ps) : expr =
  let rec laco l =
    match espia p with
    | TkSym "*" -> avanca p; laco (EBin (Mul, l, p_unary p))
    | TkSym "/" -> avanca p; laco (EBin (Div, l, p_unary p))
    | TkSym "%" -> avanca p; laco (EBin (Mod, l, p_unary p))
    | _ -> l
  in
  laco (p_unary p)

and p_unary (p : ps) : expr =
  match espia p with
  | TkSym "-" -> avanca p; ENeg (p_unary p)
  | _ -> p_app p

(* Aplicação: justaposição de átomos, associando à esquerda. *)
and p_app (p : ps) : expr =
  let f = p_atomo p in
  let rec args acc =
    if comeca_atomo (espia p) then args (EApp (acc, p_atomo p)) else acc
  in
  args f

and p_atomo (p : ps) : expr =
  match espia p with
  | TkInt n -> avanca p; ELit (LInt n)
  | TkKw "true" -> avanca p; ELit (LBool true)
  | TkKw "false" -> avanca p; ELit (LBool false)
  | TkIdent i -> avanca p; EVar i
  | TkSym "(" ->
      avanca p;
      let e = p_expr p in
      espera_sym p ")";
      e
  | _ -> falha p "esperava uma expressao"

let p_decl (p : ps) : decl =
  espera_kw p "let";
  let is_rec = aceita p (TkKw "rec") in
  let nome = ident p in
  let ps_ = p_param_list p in
  espera_sym p "=";
  let corpo = p_expr p in
  { d_rec = is_rec; d_name = nome; d_params = ps_; d_body = corpo }

(* Nenhum separador é exigido entre declarações de topo, e isso não é
   descuido: uma expressão só pode ser ESTENDIDA por um operador infixo ou por
   aplicação, e `let` não inicia um átomo. Logo, ao terminar o corpo de uma
   declaração, encontrar `let` só pode significar declaração nova. *)
let parse_program (src : string) : decl list =
  let toks = Array.of_list (tokenize src) in
  let p = { toks; pos = 0 } in
  let rec decls () =
    match espia p with
    | TkKw "let" ->
        let d = p_decl p in
        d :: decls ()
    | _ -> []
  in
  let ds = decls () in
  (match espia p with
  | TkEOF -> ()
  | t ->
      let tk = atual p in
      erro "%d:%d: lixo apos o fim do programa: %s" tk.linha tk.col (descreve t));
  if ds = [] then erro "programa vazio";
  ds

(* -------------------------------------------------------------- inferência *)

(* O contador é GLOBAL ao programa, não por declaração.
 *
 * Em Haskell, `inferProgram` roda um único `runInfer` para todas as
 * declarações, então a numeração continua de uma para a outra. Reiniciar aqui
 * daria tipos corretos com NOMES diferentes, e a saída de `forge types`
 * deixaria de casar byte a byte. *)
let contador = ref 0

let fresca () : tipo =
  let n = !contador in
  incr contador;
  TVar ("t" ^ string_of_int n)

(* Instancia um esquema com variáveis novas. É o que permite usar a mesma
   função polimórfica em dois tipos diferentes no mesmo programa. *)
let instancia (Scheme (vs, t)) : tipo =
  let pares = List.map (fun v -> (v, fresca ())) vs in
  aplica_t (List.fold_left (fun m (k, v) -> SMap.add k v m) SMap.empty pares) t

(* Ambiente inicial. `print` devolve o valor impresso para que
   `print a; print b` seja tipável sem precisar de um tipo unitário. *)
let builtins : ambiente =
  SMap.empty
  |> SMap.add "print" (Scheme ([], TFun (TInt, TInt)))
  |> SMap.add "gc" (Scheme ([], TFun (TInt, TInt)))

let eh_aritmetico o = List.mem o [ Add; Sub; Mul; Div; Mod ]
let eh_relacional o = List.mem o [ Lt; Le; Gt; Ge ]

let rec infere (env : ambiente) (e : expr) : subst * tipo =
  match e with
  | ELit (LInt _) -> (subst_vazia, TInt)
  | ELit (LBool _) -> (subst_vazia, TBool)
  | EVar x -> (
      match SMap.find_opt x env with
      | None -> erro "variavel nao definida: %s" x
      | Some sc -> (subst_vazia, instancia sc))
  | ELam (x, corpo) ->
      let tv = fresca () in
      let env' = SMap.add x (Scheme ([], tv)) env in
      let s1, t1 = infere env' corpo in
      (s1, TFun (aplica_t s1 tv, t1))
  | EApp (f, a) ->
      let s1, tf = infere env f in
      let s2, ta = infere (aplica_amb s1 env) a in
      let tv = fresca () in
      let s3 = unifica (aplica_t s2 tf) (TFun (ta, tv)) in
      (compoe s3 (compoe s2 s1), aplica_t s3 tv)
  | ENeg a ->
      let s1, t1 = infere env a in
      let s2 = unifica t1 TInt in
      (compoe s2 s1, TInt)
  | EBin (op, a, b) ->
      let s1, t1 = infere env a in
      let s2, t2 = infere (aplica_amb s1 env) b in
      let t1' = aplica_t s2 t1 in
      if eh_aritmetico op then begin
        let sa = unifica t1' TInt in
        let sb = unifica (aplica_t sa t2) TInt in
        (compoe sb (compoe sa (compoe s2 s1)), TInt)
      end
      else if eh_relacional op then begin
        let sa = unifica t1' TInt in
        let sb = unifica (aplica_t sa t2) TInt in
        (compoe sb (compoe sa (compoe s2 s1)), TBool)
      end
      else begin
        (* Igualdade unifica os dois lados em vez de exigir Int: permite
           comparar Bool com Bool, e a instrução EQ do bytecode já faz isso. O
           que ela NÃO permite é comparar Int com Bool, que é o erro real. *)
        let sa = unifica t1' (aplica_t s2 t2) in
        (compoe sa (compoe s2 s1), TBool)
      end
  | EIf (c, a, b) ->
      let s1, tc = infere env c in
      let s2 = unifica tc TBool in
      let s12 = compoe s2 s1 in
      let env1 = aplica_amb s12 env in
      let s3, ta = infere env1 a in
      let s4, tb = infere (aplica_amb s3 env1) b in
      let s5 = unifica (aplica_t s4 ta) tb in
      (compoe s5 (compoe s4 (compoe s3 s12)), aplica_t s5 tb)
  | ESeq (a, b) ->
      let s1, _ = infere env a in
      let s2, t2 = infere (aplica_amb s1 env) b in
      (compoe s2 s1, t2)
  (* let não recursivo: generaliza o tipo do rhs ANTES de ligar o nome, o que
     dá o polimorfismo do let. *)
  | ELet (false, x, rhs, corpo) ->
      let s1, t1 = infere env rhs in
      let env1 = aplica_amb s1 env in
      let sc = generaliza env1 t1 in
      let s2, t2 = infere (SMap.add x sc env1) corpo in
      (compoe s2 s1, t2)
  (* let rec: o nome entra no ambiente como MONOMÓRFICO (variável fresca)
     enquanto o próprio rhs é inferido, e só depois é generalizado.
     Generalizar antes permitiria que a função usasse a si mesma em dois tipos
     diferentes, o que Hindley-Milner não garante decidível. *)
  | ELet (true, x, rhs, corpo) ->
      let tv = fresca () in
      let env_r = SMap.add x (Scheme ([], tv)) env in
      let s1, t1 = infere env_r rhs in
      let s2 = unifica (aplica_t s1 tv) t1 in
      let s = compoe s2 s1 in
      let env1 = aplica_amb s env in
      let sc = generaliza env1 (aplica_t s t1) in
      let s3, t3 = infere (SMap.add x sc env1) corpo in
      (compoe s3 s, t3)

let infere_decl (env : ambiente) (d : decl) : esquema =
  let corpo = curry_params d.d_params d.d_body in
  if d.d_rec then begin
    let tv = fresca () in
    let env_r = SMap.add d.d_name (Scheme ([], tv)) env in
    let s1, t1 = infere env_r corpo in
    let s2 = unifica (aplica_t s1 tv) t1 in
    let s = compoe s2 s1 in
    generaliza (aplica_amb s env) (aplica_t s t1)
  end
  else begin
    let s1, t1 = infere env corpo in
    generaliza (aplica_amb s1 env) t1
  end

(* Declarações são processadas em ordem: uma função só vê as anteriores.
 *
 * É uma escolha, não limitação acidental — torna a inferência um passe único e
 * obriga o programa a declarar antes de usar. *)
let infere_programa (prog : decl list) : ambiente =
  List.fold_left
    (fun env d ->
      let sc =
        try infere_decl env d
        with Erro msg -> erro "em '%s': %s" d.d_name msg
      in
      SMap.add d.d_name sc env)
    builtins prog

(* --------------------------------------------------------------------- CLI *)

let versao = "0.2.0"

let uso () =
  prerr_endline
    ("forge_check " ^ versao ^ " - porte do verificador de tipos da forge (OCaml)");
  prerr_newline ();
  prerr_endline "uso:";
  prerr_endline "  forge_check check <prog.fg>   verifica tipos";
  prerr_endline "  forge_check types <prog.fg>   tipo inferido de cada declaracao";
  exit 64

let morre msg =
  prerr_endline ("forge: " ^ msg);
  exit 1

let le_arquivo caminho =
  try
    let ic = open_in_bin caminho in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  with Sys_error m -> morre m

(* Pipeline comum: ler, lexar, parsear, inferir.
 *
 * A checagem de `main` é regra de boa-formação do PROGRAMA, não de geração de
 * código. Na referência em Haskell ela já esteve no Codegen, e o efeito era
 * `forge check` aceitar um programa que `forge build` recusava por um motivo
 * sem relação com backend. O teste `sem_main.fg` pegou isso, e o porte tem de
 * reproduzir o comportamento corrigido. *)
let frontend caminho =
  let src = le_arquivo caminho in
  let prog =
    try parse_program src with Erro e -> morre (caminho ^ ":" ^ e)
  in
  if not (List.exists (fun d -> d.d_name = "main") prog) then
    morre (caminho ^ ": o programa precisa de uma declaracao 'main'");
  let env =
    try infere_programa prog with Erro e -> morre ("erro de tipo: " ^ e)
  in
  (prog, env)

let () =
  match Array.to_list Sys.argv with
  | _ :: [ "version" ] -> print_endline ("forge_check " ^ versao)
  | _ :: [ "check"; caminho ] ->
      let prog, _ = frontend caminho in
      Printf.printf "ok: %d declaracoes, tipos conferem\n"
        (List.length prog)
  | _ :: [ "types"; caminho ] ->
      let prog, env = frontend caminho in
      List.iter
        (fun d ->
          match SMap.find_opt d.d_name env with
          | Some sc -> Printf.printf "%s : %s\n" d.d_name (pretty_esquema sc)
          | None -> ())
        prog
  | _ -> uso ()
