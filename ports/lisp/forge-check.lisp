;;;; forge-check.lisp — o verificador de tipos do forge em Common Lisp.
;;;;
;;;;     sbcl --script ports/lisp/forge-check.lisp types prog.fg
;;;;     bash ports/lisp/roda.sh types prog.fg
;;;;
;;;; Quinto porte, depois de OCaml, F#, Prolog e Racket. Mesmo contrato: saída
;;;; **byte a byte idêntica** à referência em Haskell nos 23 casos, incluindo
;;;; os nomes das variáveis de tipo e o texto exato das mensagens de erro.
;;;;
;;;; ## O que este porte mede: o preço de não ter casamento de padrão
;;;;
;;;; Os quatro portes anteriores têm `match` ou equivalente. Haskell, OCaml e
;;;; F# têm casamento exaustivo verificado em compilação; Racket tem
;;;; `racket/match`; Prolog tem unificação de termos na própria cabeça da
;;;; cláusula.
;;;;
;;;; **ANSI Common Lisp não tem nada disso.** Há `trivia` e `optima` como
;;;; bibliotecas, e usá-las aqui responderia "quanto custa adicionar uma
;;;; dependência", que não é a pergunta. Este porte usa só o padrão — e o que
;;;; ele usa no lugar é `etypecase` com os acessores que `defstruct` gera.
;;;;
;;;; A diferença concreta, na regra de aplicação:
;;;;
;;;;     Haskell:  EApp f a -> ...                 (destrutura no padrão)
;;;;     Racket:   [(e-app f a) ...]               (idem)
;;;;     CL:       (e-app (let ((f (e-app-f e))    (acessor por acessor)
;;;;                            (a (e-app-a e)))
;;;;                        ...))
;;;;
;;;; O custo está medido em linhas no `ports/README.md`. O ganho é nenhum —
;;;; este é o único porte em que a ausência de um recurso não compra nada em
;;;; troca.
;;;;
;;;; ## E a exaustividade, que muda de natureza
;;;;
;;;; `etypecase` **erra em tempo de execução** se nenhuma cláusula casar, com
;;;; um `type-error`. Em Haskell, um `case` sem um construtor é avisado em
;;;; compilação por `-Wincomplete-patterns`.
;;;;
;;;; Então a garantia existe nos dois, e a diferença é *quando*: no Haskell
;;;; antes de rodar, aqui no caso de teste que exercitar aquele construtor. É
;;;; melhor que o Racket, onde um `match` sem o ramo certo cai no `_` se
;;;; houver um — ou falha com uma mensagem sobre padrão.
;;;;
;;;; ## O que Common Lisp dá de melhor que todos os outros
;;;;
;;;; O **sistema de condições**. O erro deste porte é uma condição de verdade:
;;;;
;;;;     (define-condition erro-forge (error) ((msg :initarg :msg ...)))
;;;;
;;;; e o `handler-case` que acrescenta "em 'nome':" não captura-e-relança como
;;;; nas outras linguagens: ele trata a condição e sinaliza uma nova, com o
;;;; contexto. A diferença é invisível neste programa — mas o sistema de
;;;; condições permitiria *reiniciar* a inferência de outra declaração sem
;;;; desfazer a pilha, que é algo que nenhuma das outras quatro tem.
;;;;
;;;; ## Uma armadilha de ANSI que merece o aviso
;;;;
;;;; `assoc` usa `eql` por padrão, e `eql` em strings compara **identidade**:
;;;;
;;;;     (assoc "x" '(("x" . 1)))        => NIL
;;;;     (assoc "x" '(("x" . 1)) :test #'string=)  => ("x" . 1)
;;;;
;;;; Toda busca de ambiente e de substituição aqui passa `:test #'string=`. A
;;;; primeira versão não passava, e o sintoma foi "variavel nao definida" para
;;;; *todas* as variáveis — um erro que parece de lógica e é de comparação.

(declaim (optimize (speed 1) (safety 3) (debug 1)))

;;; ===========================================================================
;;; ESTRUTURAS
;;; ===========================================================================

(defstruct (tv (:constructor tv (nome))) nome)
(defstruct (fn-t (:constructor fn-t (de para))) de para)
(defstruct (esquema (:constructor esquema (vars tipo))) vars tipo)

;; A AST. Os nomes levam prefixo `e-` por disciplina herdada do porte em
;; Racket, onde `var` e `app` colidiram com formas de padrão do `match`. Em CL
;; não há essa colisão, mas manter o mesmo prefixo nos dois portes deixa os
;; arquivos comparáveis lado a lado — que é o ponto deste diretório.
(defstruct (e-lit-int (:constructor e-lit-int (v))) v)
(defstruct (e-lit-bool (:constructor e-lit-bool (v))) v)
(defstruct (e-var (:constructor e-var (nome))) nome)
(defstruct (e-lam (:constructor e-lam (param corpo))) param corpo)
(defstruct (e-app (:constructor e-app (f a))) f a)
(defstruct (e-neg (:constructor e-neg (e))) e)
(defstruct (e-bin (:constructor e-bin (op a b))) op a b)
(defstruct (e-if (:constructor e-if (c a b))) c a b)
(defstruct (e-seq (:constructor e-seq (a b))) a b)
(defstruct (e-let (:constructor e-let (rec nome rhs corpo))) rec nome rhs corpo)
(defstruct (decl (:constructor decl (rec nome params corpo))) rec nome params corpo)

(define-condition erro-forge (error)
  ((msg :initarg :msg :reader erro-forge-msg)))

(defun falha (fmt &rest args)
  (error 'erro-forge :msg (apply #'format nil fmt args)))

;;; ===========================================================================
;;; LÉXICO
;;; ===========================================================================
;;;
;;; Tokens: (:int n) | (:ident "x") | (:kw "let") | (:sym "+")
;;;
;;; A ordem dos símbolos de dois caracteres ANTES dos de um é significativa, e
;;; o `Lexer.hs` tem um comentário sobre isso: se `<` fosse testado antes de
;;; `<=`, a entrada `<=` lexaria como `<` seguido de `=` e o erro apareceria no
;;; parser, longe da causa.

(defparameter *simbolos-duplos* '("<=" ">=" "==" "!=" "->"))
(defparameter *simbolos-simples*
  '("\\" "+" "-" "*" "/" "%" "<" ">" "=" "(" ")" ";"))
(defparameter *palavras-chave*
  '("let" "rec" "in" "if" "then" "else" "true" "false"))

(defun letra-p (c) (or (alpha-char-p c) (char= c #\_)))
(defun alnum-p (c) (or (alphanumericp c) (char= c #\_) (char= c #\')))

(defun tokenize (s)
  (let ((n (length s)) (i 0) (acc '()))
    (loop while (< i n) do
      (let ((c (char s i)))
        (cond
          ;; Comentário de linha. Vem ANTES do símbolo `-`, e tem de vir: um
          ;; `--` lido como dois menos faria `-- comentario` virar expressão, e
          ;; o erro falaria de sintaxe numa linha que é prosa.
          ((and (< (1+ i) n) (char= c #\-) (char= (char s (1+ i)) #\-))
           (loop while (and (< i n) (char/= (char s i) #\Newline))
                 do (incf i)))

          ((member c '(#\Space #\Tab #\Newline #\Return #\Page))
           (incf i))

          ((digit-char-p c)
           (let ((j i))
             (loop while (and (< j n) (digit-char-p (char s j))) do (incf j))
             (push (list :int (parse-integer (subseq s i j))) acc)
             (setf i j)))

          ((letra-p c)
           (let ((j i))
             (loop while (and (< j n) (alnum-p (char s j))) do (incf j))
             (let ((w (subseq s i j)))
               (push (list (if (member w *palavras-chave* :test #'string=)
                               :kw :ident)
                           w)
                     acc))
             (setf i j)))

          (t
           (let ((achou nil))
             (dolist (sym (append *simbolos-duplos* *simbolos-simples*))
               (when (and (not achou)
                          (<= (+ i (length sym)) n)
                          (string= sym (subseq s i (+ i (length sym)))))
                 (setf achou sym)))
             (if achou
                 (progn (push (list :sym achou) acc)
                        (incf i (length achou)))
                 (falha "caractere inesperado ~a" c)))))))
    (nreverse acc)))

;;; ===========================================================================
;;; SINTAXE — descida recursiva com `values` de dois valores
;;; ===========================================================================
;;;
;;; Cada função devolve (values arvore tokens-restantes). É o que o `Parser.hs`
;;; faz com uma mônada de estado, e `multiple-value-bind` deixa isso legível
;;; sem a mônada — é o recurso de CL que mais se aproxima do `do`.

(defun espia (ts) (if (null ts) (list :eof nil) (first ts)))
(defun tok-tipo (t0) (first t0))
(defun tok-val (t0) (second t0))

(defun sym-p (t0 v) (and (eq (tok-tipo t0) :sym) (string= (tok-val t0) v)))
(defun kw-p (t0 v) (and (eq (tok-tipo t0) :kw) (string= (tok-val t0) v)))

(defun exige-sym (ts v)
  (if (sym-p (espia ts) v) (rest ts) (falha "esperava '~a'" v)))

(defun exige-kw (ts v)
  (if (kw-p (espia ts) v) (rest ts) (falha "esperava '~a'" v)))

(defun exige-ident (ts)
  (if (eq (tok-tipo (espia ts)) :ident)
      (values (tok-val (espia ts)) (rest ts))
      (falha "esperava um identificador")))

(defun enrola-lams (params corpo)
  (if (null params)
      corpo
      (e-lam (first params) (enrola-lams (rest params) corpo))))

;; Nenhum separador entre declarações de topo, e o `Parser.hs` explica por quê:
;; uma expressão só pode ser ESTENDIDA por operador infixo ou por aplicação, e
;; `let` não inicia um átomo. Então encontrar `let` ao fim de um corpo só pode
;; ser declaração nova.
(defun parse-programa (ts)
  (let ((acc '()))
    (loop while (kw-p (espia ts) "let") do
      (multiple-value-bind (d ts2) (parse-decl (rest ts))
        (push d acc)
        (setf ts ts2)))
    (nreverse acc)))

(defun parse-decl (ts)
  (let* ((rec (kw-p (espia ts) "rec"))
         (ts1 (if rec (rest ts) ts)))
    (multiple-value-bind (nome ts2) (exige-ident ts1)
      (multiple-value-bind (params ts3) (parse-params ts2)
        (let ((ts4 (exige-sym ts3 "=")))
          (multiple-value-bind (corpo ts5) (parse-expr ts4)
            (values (decl rec nome params corpo) ts5)))))))

(defun parse-params (ts)
  (let ((acc '()))
    (loop while (eq (tok-tipo (espia ts)) :ident) do
      (push (tok-val (espia ts)) acc)
      (setf ts (rest ts)))
    (values (nreverse acc) ts)))

(defun parse-expr (ts)
  (let ((t0 (espia ts)))
    (cond
      ((kw-p t0 "if")
       (multiple-value-bind (c ts1) (parse-expr (rest ts))
         (let ((ts2 (exige-kw ts1 "then")))
           (multiple-value-bind (a ts3) (parse-expr ts2)
             (let ((ts4 (exige-kw ts3 "else")))
               (multiple-value-bind (b ts5) (parse-expr ts4)
                 (values (e-if c a b) ts5)))))))

      ((kw-p t0 "let")
       (let* ((ts0 (rest ts))
              (rec (kw-p (espia ts0) "rec"))
              (ts1 (if rec (rest ts0) ts0)))
         (multiple-value-bind (nome ts2) (exige-ident ts1)
           (multiple-value-bind (params ts3) (parse-params ts2)
             (let ((ts4 (exige-sym ts3 "=")))
               (multiple-value-bind (rhs ts5) (parse-expr ts4)
                 (let ((ts6 (exige-kw ts5 "in")))
                   (multiple-value-bind (corpo ts7) (parse-expr ts6)
                     ;; Os parâmetros são currificados AQUI, ao contrário das
                     ;; declarações de topo: um `let` local nunca é alvo de
                     ;; `CALL` direto, então a aridade não precisa ser
                     ;; preservada.
                     (values (e-let rec nome (enrola-lams params rhs) corpo)
                             ts7)))))))))

      ((sym-p t0 "\\")
       (multiple-value-bind (x ts1) (exige-ident (rest ts))
         (let ((ts2 (exige-sym ts1 "->")))
           (multiple-value-bind (corpo ts3) (parse-expr ts2)
             (values (e-lam x corpo) ts3)))))

      (t (parse-seq ts)))))

;; `;` associa à DIREITA e tem a precedência mais baixa.
(defun parse-seq (ts)
  (multiple-value-bind (l ts1) (parse-cmp ts)
    (if (sym-p (espia ts1) ";")
        (multiple-value-bind (r ts2) (parse-expr (rest ts1))
          (values (e-seq l r) ts2))
        (values l ts1))))

(defparameter *rel-ops*
  '(("<" . :lt) ("<=" . :le) (">" . :gt) (">=" . :ge) ("==" . :eq) ("!=" . :ne)))

;; Comparações NÃO associam: `a < b < c` é erro de sintaxe, e não um
;; encadeamento silenciosamente errado como em C.
(defun parse-cmp (ts)
  (multiple-value-bind (l ts1) (parse-add ts)
    (let* ((t0 (espia ts1))
           (par (and (eq (tok-tipo t0) :sym)
                     (assoc (tok-val t0) *rel-ops* :test #'string=))))
      (if par
          (multiple-value-bind (r ts2) (parse-add (rest ts1))
            (values (e-bin (cdr par) l r) ts2))
          (values l ts1)))))

(defun parse-binaria-esquerda (ts proximo tabela)
  (multiple-value-bind (l ts1) (funcall proximo ts)
    (loop
      (let* ((t0 (espia ts1))
             (par (and (eq (tok-tipo t0) :sym)
                       (assoc (tok-val t0) tabela :test #'string=))))
        (if par
            (multiple-value-bind (r ts2) (funcall proximo (rest ts1))
              (setf l (e-bin (cdr par) l r))
              (setf ts1 ts2))
            (return (values l ts1)))))))

(defun parse-add (ts)
  (parse-binaria-esquerda ts #'parse-mul '(("+" . :add) ("-" . :sub))))

(defun parse-mul (ts)
  (parse-binaria-esquerda ts #'parse-unaria
                          '(("*" . :mul) ("/" . :dv) ("%" . :md))))

(defun parse-unaria (ts)
  (if (sym-p (espia ts) "-")
      (multiple-value-bind (e ts1) (parse-unaria (rest ts))
        (values (e-neg e) ts1))
      (parse-app ts)))

;; `comeca-atomo-p` é o `startsAtom` do Haskell, e existe para que `f x` seja
;; aplicação e `f + x` não seja.
(defun comeca-atomo-p (t0)
  (or (eq (tok-tipo t0) :int)
      (eq (tok-tipo t0) :ident)
      (kw-p t0 "true")
      (kw-p t0 "false")
      (sym-p t0 "(")))

;; Aplicação: justaposição de átomos, associando à ESQUERDA.
(defun parse-app (ts)
  (multiple-value-bind (f ts1) (parse-atomo ts)
    (loop while (comeca-atomo-p (espia ts1)) do
      (multiple-value-bind (a ts2) (parse-atomo ts1)
        (setf f (e-app f a))
        (setf ts1 ts2)))
    (values f ts1)))

(defun parse-atomo (ts)
  (let ((t0 (espia ts)))
    (cond
      ((eq (tok-tipo t0) :int) (values (e-lit-int (tok-val t0)) (rest ts)))
      ((kw-p t0 "true") (values (e-lit-bool t) (rest ts)))
      ((kw-p t0 "false") (values (e-lit-bool nil) (rest ts)))
      ((eq (tok-tipo t0) :ident) (values (e-var (tok-val t0)) (rest ts)))
      ((sym-p t0 "(")
       (multiple-value-bind (e ts1) (parse-expr (rest ts))
         (values e (exige-sym ts1 ")"))))
      (t (falha "esperava uma expressao")))))

;;; ===========================================================================
;;; TIPOS, SUBSTITUIÇÕES E UNIFICAÇÃO — espelho de Types.hs
;;; ===========================================================================
;;;
;;; Os tipos base são os keywords `:int` e `:bool`; os compostos são structs.
;;; `etypecase` dispara em qualquer um dos três.

(defun apply-t (s tipo)
  (etypecase tipo
    (keyword tipo)
    (tv (let ((par (assoc (tv-nome tipo) s :test #'string=)))
          (if par (cdr par) tipo)))
    (fn-t (fn-t (apply-t s (fn-t-de tipo)) (apply-t s (fn-t-para tipo))))))

;; As variáveis quantificadas são REMOVIDAS da substituição antes de aplicar:
;; elas estão ligadas pelo próprio esquema, e substituí-las seria captura de
;; variável. É o `foldr M.delete s vs` do Haskell.
(defun apply-s (s sc)
  (esquema (esquema-vars sc)
           (apply-t (remove-if (lambda (par)
                                 (member (car par) (esquema-vars sc)
                                         :test #'string=))
                               s)
                    (esquema-tipo sc))))

(defun apply-env (s env)
  (mapcar (lambda (par) (cons (car par) (apply-s s (cdr par)))) env))

;; compose s1 s2 == composeSubst s1 s2 == aplica s2, depois s1
;;
;; `M.map (applyT s1) s2 `M.union` s1`, e o `M.union` do Haskell é
;; LEFT-BIASED: as entradas de s2 (já mapeadas) vencem as de s1. Com `assoc`
;; achando a PRIMEIRA ocorrência, `append` dá o mesmo resultado.
;;
;; A ORDEM desta composição é o bug clássico de implementações de
;; Hindley-Milner: compor ao contrário produz um unificador que não é o mais
;; geral, e o sintoma aparece longe da causa.
(defun compose (s1 s2)
  (append (mapcar (lambda (par) (cons (car par) (apply-t s1 (cdr par)))) s2)
          s1))

(defun compose* (&rest ss)
  (reduce #'compose ss :from-end t :initial-value '()))

(defun ftv-bruto (tipo)
  (etypecase tipo
    (keyword '())
    (tv (list (tv-nome tipo)))
    (fn-t (append (ftv-bruto (fn-t-de tipo)) (ftv-bruto (fn-t-para tipo))))))

;; O resultado é ORDENADO e sem repetição, porque o Haskell usa `Data.Set` e o
;; `S.toList` dele devolve em ordem crescente. É isso que fixa a ordem do
;; `forall t2 t3 t4`.
(defun ftv (tipo)
  (sort (remove-duplicates (ftv-bruto tipo) :test #'string=) #'string<))

(defun ftv-esquema (sc)
  (remove-if (lambda (v) (member v (esquema-vars sc) :test #'string=))
             (ftv (esquema-tipo sc))))

(defun ftv-env (env)
  (sort (remove-duplicates
         (loop for par in env append (ftv-esquema (cdr par)))
         :test #'string=)
        #'string<))

;; Fecha as variáveis livres do tipo que NÃO aparecem no ambiente. A condição
;; sobre o ambiente é o que impede generalizar a variável de um parâmetro de
;; função — seria incorreto, porque quem escolhe o tipo dela é o chamador.
(defun generalize (env tipo)
  (let ((livres (ftv-env env)))
    (esquema (remove-if (lambda (v) (member v livres :test #'string=))
                        (ftv tipo))
             tipo)))

(defun pt (paren tipo)
  (etypecase tipo
    (keyword (if (eq tipo :int) "Int" "Bool"))
    (tv (tv-nome tipo))
    (fn-t (let ((interno (concatenate 'string
                                      (pt t (fn-t-de tipo))
                                      " -> "
                                      (pt nil (fn-t-para tipo)))))
            (if paren
                (concatenate 'string "(" interno ")")
                interno)))))

(defun pretty-type (tipo) (pt nil tipo))

(defun pretty-esquema (sc)
  (if (null (esquema-vars sc))
      (pretty-type (esquema-tipo sc))
      (format nil "forall ~{~a~^ ~}. ~a"
              (esquema-vars sc)
              (pretty-type (esquema-tipo sc)))))

;; Unificação com teste de ocorrência, como o Haskell faz à mão.
(defun unify (a b)
  (cond
    ((and (eq a :int) (eq b :int)) '())
    ((and (eq a :bool) (eq b :bool)) '())
    ((and (fn-t-p a) (fn-t-p b))
     (let* ((s1 (unify (fn-t-de a) (fn-t-de b)))
            (s2 (unify (apply-t s1 (fn-t-para a))
                       (apply-t s1 (fn-t-para b)))))
       (compose s2 s1)))
    ((tv-p a) (liga-var (tv-nome a) b))
    ((tv-p b) (liga-var (tv-nome b) a))
    (t (falha "nao consegui unificar ~a com ~a"
              (pretty-type a) (pretty-type b)))))

;; O teste de ocorrência é o que impede construir um tipo infinito. Sem ele,
;; `\x -> x x` unificaria `a` com `a -> b` e a inferência entraria em laço — ou
;; devolveria um tipo cíclico que estoura a pilha só na hora de imprimir.
(defun liga-var (v tipo)
  (cond
    ((and (tv-p tipo) (string= (tv-nome tipo) v)) '())
    ((member v (ftv tipo) :test #'string=)
     (falha "tipo infinito: ~a ocorre em ~a" v (pretty-type tipo)))
    (t (list (cons v tipo)))))

;;; ===========================================================================
;;; INFERÊNCIA — Algoritmo W, espelho de Infer.hs
;;; ===========================================================================
;;;
;;; O contador de variáveis frescas é uma variável especial, e não um parâmetro
;;; passado adiante — a mesma decisão do porte em Racket, pelo mesmo motivo:
;;; com `values` devolvendo (substituição, tipo), acrescentar o contador faria
;;; cada regra devolver três valores e cada chamada desempacotar três.
;;;
;;; O contador é ÚNICO para o programa inteiro: o `inferProgram` roda todas as
;;; declarações num só `runInfer`, e é por isso que o primeiro tipo de
;;; `composicao.fg` começa em `t2` e não em `t0`.

(defparameter *contador* 0)

(defun fresh ()
  (let ((n *contador*))
    (incf *contador*)
    (tv (format nil "t~a" n))))

;; Uma variável fresca por variável quantificada, NA ORDEM da lista. É o que
;; permite usar a mesma função polimórfica em dois tipos diferentes no mesmo
;; programa.
(defun instantiate (sc)
  (apply-t (mapcar (lambda (v) (cons v (fresh))) (esquema-vars sc))
           (esquema-tipo sc)))

(defparameter *builtins*
  (list (cons "print" (esquema '() (fn-t :int :int)))
        (cons "gc" (esquema '() (fn-t :int :int)))))

;; infer : env expr -> (values subst tipo)
;;
;; `etypecase` no lugar de casamento de padrão. Cada ramo tem de extrair os
;; campos com os acessores que `defstruct` gerou, e é aí que este porte paga o
;; preço de não ter `match`.
(defun infer (env e)
  (etypecase e
    (e-lit-int (values '() :int))
    (e-lit-bool (values '() :bool))

    (e-var
     (let ((par (assoc (e-var-nome e) env :test #'string=)))
       (unless par (falha "variavel nao definida: ~a" (e-var-nome e)))
       (values '() (instantiate (cdr par)))))

    (e-lam
     (let ((t-v (fresh)))
       (multiple-value-bind (s1 t1)
           (infer (cons (cons (e-lam-param e) (esquema '() t-v)) env)
                  (e-lam-corpo e))
         (values s1 (fn-t (apply-t s1 t-v) t1)))))

    (e-app
     (multiple-value-bind (s1 tf) (infer env (e-app-f e))
       (multiple-value-bind (s2 ta) (infer (apply-env s1 env) (e-app-a e))
         (let* ((t-v (fresh))
                (s3 (unify (apply-t s2 tf) (fn-t ta t-v))))
           (values (compose* s3 s2 s1) (apply-t s3 t-v))))))

    (e-neg
     (multiple-value-bind (s1 t1) (infer env (e-neg-e e))
       (let ((s2 (unify t1 :int)))
         (values (compose s2 s1) :int))))

    (e-bin
     (multiple-value-bind (s1 t1) (infer env (e-bin-a e))
       (multiple-value-bind (s2 t2) (infer (apply-env s1 env) (e-bin-b e))
         (let ((t1p (apply-t s2 t1))
               (op (e-bin-op e)))
           (cond
             ((member op '(:add :sub :mul :dv :md))
              (let* ((sa (unify t1p :int))
                     (sb (unify (apply-t sa t2) :int)))
                (values (compose* sb sa s2 s1) :int)))
             ((member op '(:lt :le :gt :ge))
              (let* ((sa (unify t1p :int))
                     (sb (unify (apply-t sa t2) :int)))
                (values (compose* sb sa s2 s1) :bool)))
             (t
              ;; Igualdade UNIFICA os dois lados em vez de exigir Int: permite
              ;; comparar Bool com Bool, e a instrução EQ do bytecode já faz
              ;; isso. O que ela não permite é comparar Int com Bool, que é o
              ;; erro real.
              (let ((sa (unify t1p (apply-t s2 t2))))
                (values (compose* sa s2 s1) :bool))))))))

    (e-if
     (multiple-value-bind (s1 tc) (infer env (e-if-c e))
       (let* ((s2 (unify tc :bool))
              (s12 (compose s2 s1))
              (env1 (apply-env s12 env)))
         (multiple-value-bind (s3 ta) (infer env1 (e-if-a e))
           (multiple-value-bind (s4 tb) (infer (apply-env s3 env1) (e-if-b e))
             (let ((s5 (unify (apply-t s4 ta) tb)))
               (values (compose* s5 s4 s3 s12) (apply-t s5 tb))))))))

    (e-seq
     (multiple-value-bind (s1 ignorado) (infer env (e-seq-a e))
       (declare (ignore ignorado))
       (multiple-value-bind (s2 t2) (infer (apply-env s1 env) (e-seq-b e))
         (values (compose s2 s1) t2))))

    (e-let
     (if (e-let-rec e)
         ;; let rec: o nome entra no ambiente como MONOMÓRFICO (variável
         ;; fresca) enquanto o próprio rhs é inferido, e só depois é
         ;; generalizado. Generalizar antes permitiria que a função usasse a si
         ;; mesma em dois tipos diferentes, o que Hindley-Milner não garante
         ;; decidível.
         (let ((t-v (fresh)))
           (multiple-value-bind (s1 t1)
               (infer (cons (cons (e-let-nome e) (esquema '() t-v)) env)
                      (e-let-rhs e))
             (let* ((s2 (unify (apply-t s1 t-v) t1))
                    (s (compose s2 s1))
                    (env1 (apply-env s env))
                    (sc (generalize env1 (apply-t s t1))))
               (multiple-value-bind (s3 t3)
                   (infer (cons (cons (e-let-nome e) sc) env1) (e-let-corpo e))
                 (values (compose s3 s) t3)))))
         ;; let NÃO recursivo: generaliza o tipo do rhs ANTES de ligar o nome,
         ;; o que é de onde vem o polimorfismo do let.
         (multiple-value-bind (s1 t1) (infer env (e-let-rhs e))
           (let* ((env1 (apply-env s1 env))
                  (sc (generalize env1 t1)))
             (multiple-value-bind (s2 t2)
                 (infer (cons (cons (e-let-nome e) sc) env1) (e-let-corpo e))
               (values (compose s2 s1) t2))))))))

;; Declarações são processadas EM ORDEM: uma função só vê as anteriores. É
;; escolha e não limitação acidental — torna a inferência um passe único e
;; obriga a declarar antes de usar.
(defun infer-programa (decls)
  (setf *contador* 0)
  (let ((env *builtins*) (acc '()))
    (dolist (d decls)
      (let ((sc (handler-case (infer-decl env d)
                  ;; O sistema de condições: a condição é TRATADA e uma nova é
                  ;; sinalizada com o contexto. Não é captura-e-relança — o
                  ;; `handler-case` desfaz a pilha, mas um `handler-bind` com
                  ;; `restart-case` poderia retomar a inferência da declaração
                  ;; seguinte sem desfazê-la, que é algo que nenhum dos outros
                  ;; quatro portes tem.
                  (erro-forge (c)
                    (falha "em '~a': ~a" (decl-nome d) (erro-forge-msg c))))))
        (push (cons (decl-nome d) sc) acc)
        (setf env (cons (cons (decl-nome d) sc) env))))
    (nreverse acc)))

(defun infer-decl (env d)
  (let ((corpo (enrola-lams (decl-params d) (decl-corpo d))))
    (if (decl-rec d)
        (let ((t-v (fresh)))
          (multiple-value-bind (s1 t1)
              (infer (cons (cons (decl-nome d) (esquema '() t-v)) env) corpo)
            (let* ((s2 (unify (apply-t s1 t-v) t1))
                   (s (compose s2 s1)))
              (generalize (apply-env s env) (apply-t s t1)))))
        (multiple-value-bind (s1 t1) (infer env corpo)
          (generalize (apply-env s1 env) t1)))))

;;; ===========================================================================
;;; PONTO DE ENTRADA
;;; ===========================================================================

(defun le-arquivo (caminho)
  (handler-case
      (with-open-file (in caminho :direction :input
                                  :external-format :utf-8)
        (let ((s (make-string (file-length in))))
          (let ((lidos (read-sequence s in)))
            (subseq s 0 lidos))))
    (error () (falha "~a: nao consegui ler o arquivo" caminho))))

;; `frontend` é o caminho comum de `check` e `types`, pelo mesmo motivo que no
;; `Main.hs`: as duas leem, lexam, parseiam, exigem `main` e inferem — e só
;; divergem no que IMPRIMEM.
;;
;; Ter um só lugar para isso importa aqui mais que de costume: o
;; `ports/verifica.sh` compara `types` nos 17 casos de sucesso e `check` nos 6
;; de erro. Com a checagem de `main` só no caminho de `types`, o caso
;; `sem_main.fg` passaria sem verificar nada — foi o defeito que o porte em
;; Prolog teve.
(defun frontend (caminho)
  (let* ((src (le-arquivo caminho))
         (decls (parse-programa (tokenize src))))
    ;; "o programa precisa de main" é regra de boa-formação do PROGRAMA, não do
    ;; backend — então é verificada aqui, antes da inferência, e a mensagem
    ;; cita o caminho do arquivo. O caso `sem_main.fg` fixa isso.
    (unless (find "main" decls :key #'decl-nome :test #'string=)
      (falha "~a: o programa precisa de uma declaracao 'main'" caminho))
    (let ((tipos (handler-case (infer-programa decls)
                   (erro-forge (c)
                     (falha "erro de tipo: ~a" (erro-forge-msg c))))))
      (values decls tipos))))

(defun principal ()
  (let ((args (rest sb-ext:*posix-argv*)))
    (handler-case
        (cond
          ((and (= (length args) 1) (string= (first args) "version"))
           (format t "forge-lisp (porte do verificador)~%"))

          ((and (= (length args) 2) (string= (first args) "types"))
           (multiple-value-bind (decls tipos) (frontend (second args))
             (declare (ignore decls))
             (dolist (par tipos)
               (format t "~a : ~a~%" (car par) (pretty-esquema (cdr par))))))

          ((and (= (length args) 2) (string= (first args) "check"))
           (multiple-value-bind (decls tipos) (frontend (second args))
             (declare (ignore tipos))
             (format t "ok: ~a declaracoes, tipos conferem~%" (length decls))))

          (t
           (format *error-output*
                   "uso: forge-check.lisp {check|types|version} <prog.fg>~%")
           (sb-ext:exit :code 64)))
      (erro-forge (c)
        (format *error-output* "forge: ~a~%" (erro-forge-msg c))
        (finish-output *error-output*)
        (sb-ext:exit :code 1)))
    (finish-output)))

(principal)
