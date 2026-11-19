#lang racket/base
;; forge-check.rkt — o verificador de tipos do forge em Racket.
;;
;;     racket ports/racket/forge-check.rkt types prog.fg
;;     bash   ports/racket/roda.sh types prog.fg
;;
;; Quarto porte, depois de OCaml, F# e Prolog. Mesmo contrato: saída **byte a
;; byte idêntica** à referência em Haskell nos 23 casos, incluindo os nomes das
;; variáveis de tipo e o texto exato das mensagens de erro.
;;
;; ## O que este porte mede, e por que não é "mais um do mesmo"
;;
;; OCaml e F# são da mesma família do Haskell: têm tipos algébricos, casamento
;; de padrão exaustivo e inferência própria. Nos três, o Algoritmo W se escreve
;; quase igual — e os números confirmam (468, 496 e 494 linhas).
;;
;; Racket é a primeira linguagem **dinamicamente tipada** a entrar aqui, e a
;; pergunta que ela responde é concreta:
;;
;;   > Quanto do Algoritmo W é sustentado pelo sistema de tipos de quem o
;;   > escreve, e quanto é só a estrutura do algoritmo?
;;
;; A resposta medida está no `ports/README.md`. O resumo: a estrutura sobrevive
;; inteira, e o que se perde é a **rede de segurança** — em Haskell, esquecer
;; um construtor no `case` é erro de compilação; aqui é um `match` que falha em
;; tempo de execução, num caso de teste específico, com uma mensagem que fala
;; de padrão e não de tipo.
;;
;; ## E o que Racket dá em troca
;;
;; `match` com padrões aninhados e literais de estrutura. A regra de aplicação
;; em Haskell é:
;;
;;     EApp f a -> do
;;       (s1, tf) <- infer env f
;;       (s2, ta) <- infer (applyEnv s1 env) a
;;       ...
;;
;; e aqui é a mesma forma, com `define-values` no lugar do `do`. A diferença
;; é que o `(e-app f a)` do padrão é o mesmo texto que o `(e-app f a)` do
;; construtor: em Lisp, construir e desconstruir se escrevem igual.
;;
;; ## O defeito que custou a primeira execução, e que vale mais que o porte
;;
;; As structs da AST chamavam-se `var` e `app`. **As duas são formas de padrão
;; do `racket/match`**, e o resultado foi silencioso e catastrófico:
;;
;;     (struct var (nome) #:transparent)
;;     (match (seq (var "x") (var "y"))
;;       [(var x) (format "CASOU -- x = ~a" x)]   ; <- casou!
;;       [(seq a b) "o correto"])
;;
;;     => CASOU -- x = #(struct:seq #(struct:var x) #(struct:var y))
;;
;; O `(var id)` do `match` **liga `id` ao valor inteiro** — é a forma de dizer
;; "ligue uma variável" sem ambiguidade com palavras-chave de padrão. Ela
;; sombreou a struct, e o terceiro ramo do `match` passou a ser um curinga onde
;; eu havia escrito um teste de tipo.
;;
;; O sintoma: `erro de tipo: em 'main': variavel nao definida:
;; #(struct:seq ...)`. A mensagem é da MINHA regra de variável não definida,
;; aplicada a uma expressão que nunca deveria ter chegado nela — e não
;; menciona `match`, nem padrão, nem sombreamento.
;;
;; **Em Haskell isso não acontece:** um construtor que colidisse com outro nome
;; seria erro de nome, e um `case` com ramo inalcançável é avisado por
;; `-Woverlapping-patterns`. Aqui o compilador não tem como saber que eu quis
;; a struct e não a forma de padrão, porque as duas são sintaticamente iguais.
;;
;; Por isso as structs de expressão levam o prefixo `e-`. E a lista de nomes a
;; evitar, que é o que eu gostaria de ter lido antes:
;;
;;     app  var  struct  and  or  not  list  list*  vector  cons  box
;;     quote  quasiquote  ?  regexp  pregexp  hash-table  list-no-order
;;
;; Qualquer struct com um desses nomes vira um padrão com outro significado,
;; sem aviso.

;; ## Representação
;;
;;     tipo     ::= 'int | 'bool | (tv nome) | (fun a b)
;;     esquema  ::= (scheme (lista de nomes) tipo)
;;     subst    ::= lista associativa de (nome . tipo), busca na PRIMEIRA
;;     ambiente ::= lista associativa de (nome . esquema)
;;
;; Listas associativas e não `hash`, de propósito: o `composeSubst` do Haskell
;; é um `M.union` *left-biased*, e com busca pela primeira ocorrência o
;; `append` dá exatamente isso. Um `hash` exigiria decidir a ordem de fusão à
;; mão, que é o bug clássico desta implementação.

(require racket/match
         racket/list
         racket/string
         racket/port)

;; ===========================================================================
;; ESTRUTURAS
;; ===========================================================================

(struct tv (nome) #:transparent)
(struct fun (de para) #:transparent)
(struct scheme (vars tipo) #:transparent)

;; AST
(struct lit-int (v) #:transparent)
(struct lit-bool (v) #:transparent)
(struct e-var (nome) #:transparent)
(struct lam (param corpo) #:transparent)
(struct e-app (f a) #:transparent)
(struct neg (e) #:transparent)
(struct bin (op a b) #:transparent)
(struct if-e (c a b) #:transparent)
(struct seq (a b) #:transparent)
(struct let-e (rec? nome rhs corpo) #:transparent)
(struct decl (rec? nome params corpo) #:transparent)

;; O erro é uma struct e não um `error` direto, porque ele atravessa duas
;; camadas de contexto: a inferência de uma declaração acrescenta "em 'nome':",
;; e o topo acrescenta "forge: ". Um `error` de Racket traria o nome do
;; procedimento na mensagem, que a referência não tem.
(struct erro-forge (msg) #:transparent)

(define (falha msg) (raise (erro-forge msg)))

;; ===========================================================================
;; LÉXICO
;; ===========================================================================
;;
;; Tokens: (int n) | (ident sym) | (kw sym) | (sym s)
;;
;; A ordem dos símbolos de dois caracteres ANTES dos de um é significativa, e o
;; `Lexer.hs` tem um comentário sobre isso: se `<` fosse testado antes de `<=`,
;; a entrada `<=` lexaria como `<` seguido de `=` e o erro apareceria no
;; parser, longe da causa.

(define simbolos-duplos '("<=" ">=" "==" "!=" "->"))
(define simbolos-simples '("\\" "+" "-" "*" "/" "%" "<" ">" "=" "(" ")" ";"))
(define palavras-chave '("let" "rec" "in" "if" "then" "else" "true" "false"))

(define (alpha? c) (or (char-alphabetic? c) (char=? c #\_)))
(define (alnum? c) (or (char-alphabetic? c) (char-numeric? c)
                       (char=? c #\_) (char=? c #\')))

(define (tokenize s)
  (define n (string-length s))
  (let laco ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]

      ;; Comentário de linha. Vem ANTES do símbolo `-`, e tem de vir: um `--`
      ;; lido como dois menos faria `-- comentario` virar expressão, e o erro
      ;; falaria de sintaxe numa linha que é prosa.
      [(and (< (+ i 1) n) (char=? (string-ref s i) #\-)
            (char=? (string-ref s (+ i 1)) #\-))
       (let pula ([j i])
         (cond [(>= j n) (laco j acc)]
               [(char=? (string-ref s j) #\newline) (laco j acc)]
               [else (pula (+ j 1))]))]

      [(char-whitespace? (string-ref s i)) (laco (+ i 1) acc)]

      [(char-numeric? (string-ref s i))
       (let digitos ([j i])
         (if (and (< j n) (char-numeric? (string-ref s j)))
             (digitos (+ j 1))
             (laco j (cons (list 'int (string->number (substring s i j))) acc))))]

      [(alpha? (string-ref s i))
       (let palavra ([j i])
         (if (and (< j n) (alnum? (string-ref s j)))
             (palavra (+ j 1))
             (let ([w (substring s i j)])
               (laco j (cons (if (member w palavras-chave)
                                 (list 'kw w)
                                 (list 'ident w))
                             acc)))))]

      [else
       (define (casa lista)
         (for/first ([sym (in-list lista)]
                     #:when (and (<= (+ i (string-length sym)) n)
                                 (string=? sym (substring s i (+ i (string-length sym))))))
           sym))
       (define achou (or (casa simbolos-duplos) (casa simbolos-simples)))
       (if achou
           (laco (+ i (string-length achou)) (cons (list 'sym achou) acc))
           (falha (format "caractere inesperado ~a" (string-ref s i))))])))

;; ===========================================================================
;; SINTAXE — descida recursiva sobre a lista de tokens
;; ===========================================================================
;;
;; Cada função devolve dois valores: a árvore e os tokens restantes. É o que o
;; `Parser.hs` faz com uma mônada de estado, escrito à mão — e `define-values`
;; deixa isso legível sem a mônada.

(define (tok-tipo t) (and (pair? t) (car t)))
(define (tok-val t) (and (pair? t) (cadr t)))

(define (espia ts) (if (null? ts) '(eof) (car ts)))

(define (e-sym? t v) (and (eq? (tok-tipo t) 'sym) (string=? (tok-val t) v)))
(define (e-kw? t v) (and (eq? (tok-tipo t) 'kw) (string=? (tok-val t) v)))

(define (exige-sym ts v)
  (if (e-sym? (espia ts) v)
      (cdr ts)
      (falha (format "esperava '~a'" v))))

(define (exige-kw ts v)
  (if (e-kw? (espia ts) v)
      (cdr ts)
      (falha (format "esperava '~a'" v))))

(define (exige-ident ts)
  (if (eq? (tok-tipo (espia ts)) 'ident)
      (values (tok-val (espia ts)) (cdr ts))
      (falha "esperava um identificador")))

;; Nenhum separador entre declarações de topo, e o `Parser.hs` explica por quê:
;; uma expressão só pode ser ESTENDIDA por operador infixo ou por aplicação, e
;; `let` não inicia um átomo. Então encontrar `let` ao fim de um corpo só pode
;; ser declaração nova.
(define (parse-programa ts)
  (let laco ([ts ts] [acc '()])
    (if (e-kw? (espia ts) "let")
        (let-values ([(d ts2) (parse-decl (cdr ts))])
          (laco ts2 (cons d acc)))
        (reverse acc))))

(define (parse-decl ts)
  (define rec? (e-kw? (espia ts) "rec"))
  (define ts1 (if rec? (cdr ts) ts))
  (define-values (nome ts2) (exige-ident ts1))
  (define-values (params ts3) (parse-params ts2))
  (define ts4 (exige-sym ts3 "="))
  (define-values (corpo ts5) (parse-expr ts4))
  (values (decl rec? nome params corpo) ts5))

(define (parse-params ts)
  (let laco ([ts ts] [acc '()])
    (if (eq? (tok-tipo (espia ts)) 'ident)
        (laco (cdr ts) (cons (tok-val (espia ts)) acc))
        (values (reverse acc) ts))))

(define (enrola-lams params corpo)
  (foldr (lambda (p c) (lam p c)) corpo params))

(define (parse-expr ts)
  (define t (espia ts))
  (cond
    [(e-kw? t "if")
     (define-values (c ts1) (parse-expr (cdr ts)))
     (define ts2 (exige-kw ts1 "then"))
     (define-values (a ts3) (parse-expr ts2))
     (define ts4 (exige-kw ts3 "else"))
     (define-values (b ts5) (parse-expr ts4))
     (values (if-e c a b) ts5)]

    [(e-kw? t "let")
     (define ts0 (cdr ts))
     (define rec? (e-kw? (espia ts0) "rec"))
     (define ts1 (if rec? (cdr ts0) ts0))
     (define-values (nome ts2) (exige-ident ts1))
     (define-values (params ts3) (parse-params ts2))
     (define ts4 (exige-sym ts3 "="))
     (define-values (rhs ts5) (parse-expr ts4))
     (define ts6 (exige-kw ts5 "in"))
     (define-values (corpo ts7) (parse-expr ts6))
     ;; Os parâmetros são currificados AQUI, ao contrário das declarações de
     ;; topo: um `let` local nunca é alvo de `CALL` direto, então a aridade
     ;; não precisa ser preservada.
     (values (let-e rec? nome (enrola-lams params rhs) corpo) ts7)]

    [(e-sym? t "\\")
     (define-values (x ts1) (exige-ident (cdr ts)))
     (define ts2 (exige-sym ts1 "->"))
     (define-values (corpo ts3) (parse-expr ts2))
     (values (lam x corpo) ts3)]

    [else (parse-seq ts)]))

;; `;` associa à DIREITA e tem a precedência mais baixa.
(define (parse-seq ts)
  (define-values (l ts1) (parse-cmp ts))
  (if (e-sym? (espia ts1) ";")
      (let-values ([(r ts2) (parse-expr (cdr ts1))])
        (values (seq l r) ts2))
      (values l ts1)))

(define rel-ops '(("<" . lt) ("<=" . le) (">" . gt)
                  (">=" . ge) ("==" . eq) ("!=" . ne)))

;; Comparações NÃO associam: `a < b < c` é erro de sintaxe, e não um
;; encadeamento silenciosamente errado como em C.
(define (parse-cmp ts)
  (define-values (l ts1) (parse-add ts))
  (define t (espia ts1))
  (define par (and (eq? (tok-tipo t) 'sym) (assoc (tok-val t) rel-ops)))
  (if par
      (let-values ([(r ts2) (parse-add (cdr ts1))])
        (values (bin (cdr par) l r) ts2))
      (values l ts1)))

(define (parse-binaria-esquerda ts proximo tabela)
  (define-values (l ts1) (proximo ts))
  (let laco ([l l] [ts ts1])
    (define t (espia ts))
    (define par (and (eq? (tok-tipo t) 'sym) (assoc (tok-val t) tabela)))
    (if par
        (let-values ([(r ts2) (proximo (cdr ts))])
          (laco (bin (cdr par) l r) ts2))
        (values l ts))))

(define (parse-add ts)
  (parse-binaria-esquerda ts parse-mul '(("+" . add) ("-" . sub))))

(define (parse-mul ts)
  (parse-binaria-esquerda ts parse-unaria '(("*" . mul) ("/" . dv) ("%" . md))))

(define (parse-unaria ts)
  (if (e-sym? (espia ts) "-")
      (let-values ([(e ts1) (parse-unaria (cdr ts))])
        (values (neg e) ts1))
      (parse-app ts)))

;; `comeca-atomo?` é o `startsAtom` do Haskell, e existe para que `f x` seja
;; aplicação e `f + x` não seja.
(define (comeca-atomo? t)
  (or (eq? (tok-tipo t) 'int)
      (eq? (tok-tipo t) 'ident)
      (e-kw? t "true")
      (e-kw? t "false")
      (e-sym? t "(")))

;; Aplicação: justaposição de átomos, associando à ESQUERDA.
(define (parse-app ts)
  (define-values (f ts1) (parse-atomo ts))
  (let laco ([f f] [ts ts1])
    (if (comeca-atomo? (espia ts))
        (let-values ([(a ts2) (parse-atomo ts)])
          (laco (e-app f a) ts2))
        (values f ts))))

(define (parse-atomo ts)
  (define t (espia ts))
  (cond
    [(eq? (tok-tipo t) 'int) (values (lit-int (tok-val t)) (cdr ts))]
    [(e-kw? t "true") (values (lit-bool #t) (cdr ts))]
    [(e-kw? t "false") (values (lit-bool #f) (cdr ts))]
    [(eq? (tok-tipo t) 'ident) (values (e-var (tok-val t)) (cdr ts))]
    [(e-sym? t "(")
     (define-values (e ts1) (parse-expr (cdr ts)))
     (values e (exige-sym ts1 ")"))]
    [else (falha "esperava uma expressao")]))

;; ===========================================================================
;; TIPOS, SUBSTITUIÇÕES E UNIFICAÇÃO — espelho de Types.hs
;; ===========================================================================

(define (apply-t s t)
  (match t
    [(tv v) (let ([par (assoc v s)]) (if par (cdr par) t))]
    [(fun a b) (fun (apply-t s a) (apply-t s b))]
    [_ t]))

;; As variáveis quantificadas são REMOVIDAS da substituição antes de aplicar:
;; elas estão ligadas pelo próprio esquema, e substituí-las seria captura de
;; variável. É o `foldr M.delete s vs` do Haskell.
(define (apply-s s sc)
  (match sc
    [(scheme vs t)
     (scheme vs (apply-t (filter (lambda (par) (not (member (car par) vs))) s) t))]))

(define (apply-env s env)
  (map (lambda (par) (cons (car par) (apply-s s (cdr par)))) env))

;; compose s1 s2 == composeSubst s1 s2 == aplica s2, depois s1
;;
;; `M.map (applyT s1) s2 `M.union` s1`, e o `M.union` do Haskell é
;; LEFT-BIASED: as entradas de s2 (já mapeadas) vencem as de s1. Com busca
;; pela primeira ocorrência, `append` dá o mesmo resultado.
;;
;; A ORDEM desta composição é o bug clássico de implementações de
;; Hindley-Milner: compor ao contrário produz um unificador que não é o mais
;; geral, e o sintoma aparece longe da causa — tipicamente num programa que
;; devia inferir `forall a. a -> a` e infere `Int -> Int`.
(define (compose s1 s2)
  (append (map (lambda (par) (cons (car par) (apply-t s1 (cdr par)))) s2) s1))

(define (compose* . ss)
  (foldr compose '() ss))

;; O resultado é ORDENADO e sem repetição, porque o Haskell usa `Data.Set` e o
;; `S.toList` dele devolve em ordem crescente. É isso que fixa a ordem do
;; `forall t2 t3 t4`.
(define (ftv t)
  (sort (remove-duplicates
         (match t
           [(tv v) (list v)]
           [(fun a b) (append (ftv-bruto a) (ftv-bruto b))]
           [_ '()]))
        string<?))

(define (ftv-bruto t)
  (match t
    [(tv v) (list v)]
    [(fun a b) (append (ftv-bruto a) (ftv-bruto b))]
    [_ '()]))

(define (ftv-scheme sc)
  (match sc
    [(scheme vs t) (filter (lambda (v) (not (member v vs))) (ftv t))]))

(define (ftv-env env)
  (sort (remove-duplicates
         (append* (map (lambda (par) (ftv-scheme (cdr par))) env)))
        string<?))

;; Fecha as variáveis livres do tipo que NÃO aparecem no ambiente. A condição
;; sobre o ambiente é o que impede generalizar a variável de um parâmetro de
;; função — seria incorreto, porque quem escolhe o tipo dela é o chamador.
(define (generalize env t)
  (define livres (ftv-env env))
  (scheme (filter (lambda (v) (not (member v livres))) (ftv t)) t))

(define (pretty-type t) (pt #f t))

(define (pt paren t)
  (match t
    ['int "Int"]
    ['bool "Bool"]
    [(tv v) v]
    [(fun a b)
     (define interno (string-append (pt #t a) " -> " (pt #f b)))
     (if paren (string-append "(" interno ")") interno)]))

(define (pretty-scheme sc)
  (match sc
    [(scheme '() t) (pretty-type t)]
    [(scheme vs t)
     (format "forall ~a. ~a" (string-join vs " ") (pretty-type t))]))

;; Unificação com teste de ocorrência, como o Haskell faz à mão.
(define (unify a b)
  (match* (a b)
    [('int 'int) '()]
    [('bool 'bool) '()]
    [((fun l1 r1) (fun l2 r2))
     (define s1 (unify l1 l2))
     (define s2 (unify (apply-t s1 r1) (apply-t s1 r2)))
     (compose s2 s1)]
    [((tv v) t) (liga-var v t)]
    [(t (tv v)) (liga-var v t)]
    [(_ _) (falha (format "nao consegui unificar ~a com ~a"
                          (pretty-type a) (pretty-type b)))]))

;; O teste de ocorrência é o que impede construir um tipo infinito. Sem ele,
;; `\x -> x x` unificaria `a` com `a -> b` e a inferência entraria em laço — ou
;; devolveria um tipo cíclico que estoura a pilha só na hora de imprimir.
(define (liga-var v t)
  (cond
    [(equal? t (tv v)) '()]
    [(member v (ftv t))
     (falha (format "tipo infinito: ~a ocorre em ~a" v (pretty-type t)))]
    [else (list (cons v t))]))

;; ===========================================================================
;; INFERÊNCIA — Algoritmo W, espelho de Infer.hs
;; ===========================================================================
;;
;; O contador de variáveis frescas é uma caixa mutável, e não um parâmetro
;; passado adiante.
;;
;; É a diferença mais visível em relação ao Haskell, onde ele é um `StateT Int`
;; — e é uma escolha, não um descuido: com `define-values` devolvendo
;; (substituição, tipo), acrescentar o contador faria cada regra devolver três
;; valores e cada chamada desempacotar três. A caixa é mutação local, invisível
;; de fora de `infer-programa`, e o resultado é o mesmo porque a ordem de
;; avaliação dos `define-values` é sequencial e determinada.
;;
;; O contador é ÚNICO para o programa inteiro: o `inferProgram` roda todas as
;; declarações num só `runInfer`, e é por isso que o primeiro tipo de
;; `composicao.fg` começa em `t2` e não em `t0`.

(define contador (box 0))

(define (fresh!)
  (define n (unbox contador))
  (set-box! contador (+ n 1))
  (tv (format "t~a" n)))

;; Uma variável fresca por variável quantificada, NA ORDEM da lista. É o que
;; permite usar a mesma função polimórfica em dois tipos diferentes no mesmo
;; programa.
(define (instantiate sc)
  (match sc
    [(scheme vs t)
     (apply-t (map (lambda (v) (cons v (fresh!))) vs) t)]))

(define builtins
  (list (cons "print" (scheme '() (fun 'int 'int)))
        (cons "gc" (scheme '() (fun 'int 'int)))))

;; infer : env expr -> (values subst tipo)
(define (infer env e)
  (match e
    [(lit-int _) (values '() 'int)]
    [(lit-bool _) (values '() 'bool)]

    [(e-var x)
     (define par (assoc x env))
     (unless par (falha (format "variavel nao definida: ~a" x)))
     (values '() (instantiate (cdr par)))]

    [(lam x corpo)
     (define t-v (fresh!))
     (define-values (s1 t1) (infer (cons (cons x (scheme '() t-v)) env) corpo))
     (values s1 (fun (apply-t s1 t-v) t1))]

    [(e-app f a)
     (define-values (s1 tf) (infer env f))
     (define-values (s2 ta) (infer (apply-env s1 env) a))
     (define t-v (fresh!))
     (define s3 (unify (apply-t s2 tf) (fun ta t-v)))
     (values (compose* s3 s2 s1) (apply-t s3 t-v))]

    [(neg a)
     (define-values (s1 t1) (infer env a))
     (define s2 (unify t1 'int))
     (values (compose s2 s1) 'int)]

    [(bin op a b)
     (define-values (s1 t1) (infer env a))
     (define-values (s2 t2) (infer (apply-env s1 env) b))
     (define t1p (apply-t s2 t1))
     (cond
       [(memq op '(add sub mul dv md))
        (define sa (unify t1p 'int))
        (define sb (unify (apply-t sa t2) 'int))
        (values (compose* sb sa s2 s1) 'int)]
       [(memq op '(lt le gt ge))
        (define sa (unify t1p 'int))
        (define sb (unify (apply-t sa t2) 'int))
        (values (compose* sb sa s2 s1) 'bool)]
       [else
        ;; Igualdade UNIFICA os dois lados em vez de exigir Int: permite
        ;; comparar Bool com Bool, e a instrução EQ do bytecode já faz isso.
        ;; O que ela não permite é comparar Int com Bool, que é o erro real.
        (define sa (unify t1p (apply-t s2 t2)))
        (values (compose* sa s2 s1) 'bool)])]

    [(if-e c a b)
     (define-values (s1 tc) (infer env c))
     (define s2 (unify tc 'bool))
     (define s12 (compose s2 s1))
     (define env1 (apply-env s12 env))
     (define-values (s3 ta) (infer env1 a))
     (define-values (s4 tb) (infer (apply-env s3 env1) b))
     (define s5 (unify (apply-t s4 ta) tb))
     (values (compose* s5 s4 s3 s12) (apply-t s5 tb))]

    [(seq a b)
     (define-values (s1 _) (infer env a))
     (define-values (s2 t2) (infer (apply-env s1 env) b))
     (values (compose s2 s1) t2)]

    ;; let NÃO recursivo: generaliza o tipo do rhs ANTES de ligar o nome, o que
    ;; é de onde vem o polimorfismo do let.
    [(let-e #f x rhs corpo)
     (define-values (s1 t1) (infer env rhs))
     (define env1 (apply-env s1 env))
     (define sc (generalize env1 t1))
     (define-values (s2 t2) (infer (cons (cons x sc) env1) corpo))
     (values (compose s2 s1) t2)]

    ;; let rec: o nome entra no ambiente como MONOMÓRFICO (variável fresca)
    ;; enquanto o próprio rhs é inferido, e só depois é generalizado.
    ;; Generalizar antes permitiria que a função usasse a si mesma em dois
    ;; tipos diferentes, o que Hindley-Milner não garante decidível.
    [(let-e #t x rhs corpo)
     (define t-v (fresh!))
     (define-values (s1 t1) (infer (cons (cons x (scheme '() t-v)) env) rhs))
     (define s2 (unify (apply-t s1 t-v) t1))
     (define s (compose s2 s1))
     (define env1 (apply-env s env))
     (define sc (generalize env1 (apply-t s t1)))
     (define-values (s3 t3) (infer (cons (cons x sc) env1) corpo))
     (values (compose s3 s) t3)]))

;; Declarações são processadas EM ORDEM: uma função só vê as anteriores. É
;; escolha e não limitação acidental — torna a inferência um passe único e
;; obriga a declarar antes de usar.
(define (infer-programa decls)
  (set-box! contador 0)
  (let laco ([env builtins] [ds decls] [acc '()])
    (cond
      [(null? ds) (reverse acc)]
      [else
       (define d (car ds))
       (define sc
         (with-handlers ([erro-forge?
                          (lambda (ex)
                            (falha (format "em '~a': ~a"
                                           (decl-nome d) (erro-forge-msg ex))))])
           (infer-decl env d)))
       (laco (cons (cons (decl-nome d) sc) env)
             (cdr ds)
             (cons (cons (decl-nome d) sc) acc))])))

(define (infer-decl env d)
  (define corpo (enrola-lams (decl-params d) (decl-corpo d)))
  (cond
    [(decl-rec? d)
     (define t-v (fresh!))
     (define-values (s1 t1)
       (infer (cons (cons (decl-nome d) (scheme '() t-v)) env) corpo))
     (define s2 (unify (apply-t s1 t-v) t1))
     (define s (compose s2 s1))
     (generalize (apply-env s env) (apply-t s t1))]
    [else
     (define-values (s1 t1) (infer env corpo))
     (generalize (apply-env s1 env) t1)]))

;; ===========================================================================
;; PONTO DE ENTRADA
;; ===========================================================================

;; `frontend` é o caminho comum de `check` e `types`, pelo mesmo motivo que no
;; `Main.hs`: as duas leem, lexam, parseiam, exigem `main` e inferem — e só
;; divergem no que IMPRIMEM.
;;
;; Ter um só lugar para isso importa aqui mais que de costume: o
;; `ports/verifica.sh` compara `types` nos 17 casos de sucesso e `check` nos 6
;; de erro. Com a checagem de `main` só no caminho de `types`, o caso
;; `sem_main.fg` passaria sem verificar nada — foi exatamente o defeito que o
;; porte em Prolog teve.
(define (frontend caminho)
  (define src
    (with-handlers ([exn:fail? (lambda (_)
                                 (falha (format "~a: nao consegui ler o arquivo"
                                                caminho)))])
      (call-with-input-file caminho port->string)))
  (define decls (parse-programa (tokenize src)))
  ;; "o programa precisa de main" é regra de boa-formação do PROGRAMA, não do
  ;; backend — então é verificada aqui, antes da inferência, e a mensagem cita
  ;; o caminho do arquivo. O caso `sem_main.fg` fixa isso.
  (unless (findf (lambda (d) (string=? (decl-nome d) "main")) decls)
    (falha (format "~a: o programa precisa de uma declaracao 'main'" caminho)))
  (define tipos
    (with-handlers ([erro-forge?
                     (lambda (ex)
                       (falha (format "erro de tipo: ~a" (erro-forge-msg ex))))])
      (infer-programa decls)))
  (values decls tipos))

(define (main args)
  (with-handlers ([erro-forge?
                   (lambda (ex)
                     (eprintf "forge: ~a\n" (erro-forge-msg ex))
                     (exit 1))])
    (match args
      [(vector "version")
       (printf "forge-racket (porte do verificador)\n")]
      [(vector "types" caminho)
       (define-values (_ tipos) (frontend caminho))
       (for ([par (in-list tipos)])
         (printf "~a : ~a\n" (car par) (pretty-scheme (cdr par))))]
      [(vector "check" caminho)
       (define-values (decls _) (frontend caminho))
       (printf "ok: ~a declaracoes, tipos conferem\n" (length decls))]
      [_
       (eprintf "uso: forge-check.rkt {check|types|version} <prog.fg>\n")
       (exit 64)])))

(module+ main
  (main (current-command-line-arguments)))
