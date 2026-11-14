-- | Geração de código para o bytecode do P01, com conversão de closures.
--
-- = A invariante que sustenta tudo
--
-- __Compilar uma expressão aumenta a altura da pilha em exatamente 1.__
--
-- Toda a tradução depende disso. Os dois ramos de um @if@ precisam terminar na
-- mesma altura, senão o @JMP@ que os une encontra pilhas diferentes e os
-- @LOAD@ seguintes leem o slot errado — um bug que não dá erro, só resultado
-- errado. Cada caso abaixo mantém a invariante, e o comentário de cada um diz
-- como.
--
-- = Onde os locais moram
--
-- Não há área de locais separada: os locais são slots da própria pilha de
-- operandos, acima dos argumentos. É a mesma decisão do P01, e aqui ela
-- compensa duas vezes — o @let@ compila para três instruções e o conjunto de
-- raízes do coletor continua sendo só a pilha.
--
-- = Closures (Fase 2)
--
-- Uma closure é um array @[endereço, capturado1, ...]@ — nada de novo no
-- modelo de memória, e o coletor do P01 já percorre arrays e já coleta ciclos.
--
-- A chamada usa @CALLI nargs@, a única instrução que a Fase 2 acrescentou à
-- VM. Convenção: a closure fica abaixo dos argumentos e permanece como
-- __slot 0__ do frame, de modo que as capturas são lidas com
-- @LOAD 0; PUSH i; AGET@ e os argumentos ficam nos slots 1..N.
--
-- Toda função que vira valor é __unária__: aplicar @f a b@ por um caminho
-- genérico é @CALLI 1@ duas vezes. É o que torna aplicação parcial, ordem
-- superior e sobre-aplicação o mesmo mecanismo em vez de três. Uma função de
-- topo de aridade @n@ usada como valor ganha uma cadeia de @n@ invólucros
-- @f$1 .. f$n@ que acumulam argumentos até poder emitir o @CALL@ direto.
--
-- Chamada direta a função de topo com aridade exata continua emitindo
-- @CALL rotulo nargs@: closures custam alocação, e o caminho comum não paga.
module Codegen
  ( compileProgram
  , freeVars
  ) where

import Ast
import Bytecode

import Control.Monad (unless)
import Control.Monad.State
import qualified Data.Map as M
import qualified Data.Set as S

data CgEnv = CgEnv
  { ceLocals   :: M.Map String Int   -- ^ nome -> slot, relativo à base do frame
  , ceCaptured :: M.Map String Int   -- ^ nome -> índice no array da closure
  , ceTop      :: M.Map String Int   -- ^ nome -> aridade
  , ceSize     :: Int                -- ^ altura atual do frame
  }

data CgState = CgState
  { csNext   :: Int          -- ^ contador de rótulos
  , csLifted :: [[Instr]]    -- ^ funções levantadas, emitidas no fim
  , csDone   :: S.Set String -- ^ invólucros já gerados
  }

type Cg a = StateT CgState (Either String) a

fresh :: String -> Cg Label
fresh base = do
  st <- get
  put st { csNext = csNext st + 1 }
  pure ("$" ++ base ++ show (csNext st))

emitLifted :: [Instr] -> Cg ()
emitLifted block = modify $ \st -> st { csLifted = csLifted st ++ [block] }

cgErr :: String -> Cg a
cgErr = lift . Left

-- | Variáveis livres. Usada para decidir o que uma closure captura.
freeVars :: Expr -> S.Set String
freeVars e = case e of
  ELit _            -> S.empty
  EVar x            -> S.singleton x
  EBin _ a b        -> freeVars a `S.union` freeVars b
  ENeg a            -> freeVars a
  EIf a b c         -> S.unions [freeVars a, freeVars b, freeVars c]
  EApp a b          -> freeVars a `S.union` freeVars b
  ESeq a b          -> freeVars a `S.union` freeVars b
  ELam x b          -> S.delete x (freeVars b)
  ELet False x r b  -> freeVars r `S.union` S.delete x (freeVars b)
  ELet True  x r b  -> S.delete x (freeVars r `S.union` freeVars b)

-- | Separa a espinha de aplicação: @f a b c@ -> @(f, [a,b,c])@.
spine :: Expr -> (Expr, [Expr])
spine = go []
  where
    go acc (EApp f a) = go (a : acc) f
    go acc ex         = (ex, acc)

-- | Monta uma closure @[endereço, capturas...]@ na pilha. Altura: +1.
--
-- @ASET@ consome @[arr, idx, val]@, por isso o @DUP@ antes de cada campo: o
-- array tem de sobreviver para o campo seguinte e para o fim.
buildClosure :: Label -> [[Instr]] -> [Instr]
buildClosure lbl caps =
     [IPush (fromIntegral (length caps + 1)), INewarr]
  ++ [IDup, IPush 0, IPushAddr lbl, IAset]
  ++ concat [ [IDup, IPush (fromIntegral i)] ++ c ++ [IAset]
            | (i, c) <- zip [(1 :: Int) ..] caps ]

-- ------------------------------------------------------------------ programa

compileProgram :: Program -> Either String [Instr]
compileProgram prog = do
    (blocks, st) <- runStateT (mapM (compileDecl tops) prog) st0
    Right (concat blocks ++ concat (csLifted st))
  where
    st0  = CgState { csNext = 0, csLifted = [], csDone = S.empty }
    tops = M.fromList [ (dName d, length (dParams d)) | d <- prog ]

compileDecl :: M.Map String Int -> Decl -> Cg [Instr]
compileDecl tops d = do
  let ps  = dParams d
      env = CgEnv
              { ceLocals   = M.fromList (zip ps [0 ..])
              , ceCaptured = M.empty
              , ceTop      = tops
              , ceSize     = length ps
              }
  body <- compileExpr env (dBody d)
  -- 'main' encerra o programa; qualquer outra declaração devolve ao chamador.
  let final = if dName d == "main" then IHalt else IRet
  pure (ILabel (dName d) : body ++ [final])

-- ----------------------------------------------- funções de topo como valor

-- | Garante que a cadeia de invólucros de @f@ exista e devolve o rótulo do
-- primeiro.
--
-- Para @f@ de aridade @n@, gera @f$1 .. f$n@:
--
-- * @f$k(clo, x)@ com @k < n@ devolve a closure @[f$(k+1), clo[1..k-1], x]@ —
--   acumula um argumento e espera o próximo;
-- * @f$n(clo, x)@ já tem todos: carrega @clo[1..n-1]@ mais @x@ e emite
--   @CALL f n@.
--
-- É currificação explícita. O custo é uma alocação por argumento aplicado,
-- pago só por quem usa a função como valor.
ensureWrappers :: M.Map String Int -> String -> Int -> Cg Label
ensureWrappers tops f n = do
  st <- get
  unless (S.member f (csDone st)) $ do
    modify $ \s -> s { csDone = S.insert f (csDone s) }
    mapM_ gen [1 .. n]
  pure (wrapperLabel f 1)
  where
    gen k
      | k < n =
          -- acumula: [f$(k+1), clo[1..k-1], x]
          let caps = [ [ILoad 0, IPush (fromIntegral j), IAget] | j <- [1 .. k - 1] ]
                     ++ [[ILoad 1]]
          in emitLifted $ ILabel (wrapperLabel f k)
                        : buildClosure (wrapperLabel f (k + 1)) caps
                       ++ [IRet]
      | otherwise =
          -- completo: carrega as capturas e o último argumento, chama direto
          let loads = concat [ [ILoad 0, IPush (fromIntegral j), IAget] | j <- [1 .. n - 1] ]
                      ++ [ILoad 1]
          in emitLifted $ [ILabel (wrapperLabel f n)]
                       ++ loads
                       ++ [ICall f n, IRet]
    _unused = tops

wrapperLabel :: String -> Int -> Label
wrapperLabel f k = f ++ "$" ++ show k

-- | Um builtin usado como VALOR precisa de uma função de verdade, porque
-- @PRINT@ e @GC@ são instruções e não rótulos. O invólucro recebe
-- @(closure, x)@, executa a instrução e devolve @x@ — mesma assinatura de
-- qualquer closure unária.
ensureBuiltinWrapper :: String -> Instr -> Cg Label
ensureBuiltinWrapper name instr = do
  let lbl = "$" ++ name
  st <- get
  unless (S.member lbl (csDone st)) $ do
    modify $ \s -> s { csDone = S.insert lbl (csDone s) }
    emitLifted [ILabel lbl, ILoad 1, IDup, instr, IRet]
  pure lbl

-- ---------------------------------------------------------------- expressões

compileExpr :: CgEnv -> Expr -> Cg [Instr]
compileExpr env expr0 = case expr0 of

  -- altura: +1
  ELit (LInt n)  -> pure [IPush (fromIntegral n)]
  ELit (LBool b) -> pure [IPush (if b then 1 else 0)]

  -- altura: +1
  EVar x
    | Just slot <- M.lookup x (ceLocals env) -> pure [ILoad (fromIntegral slot)]
    -- captura: slot 0 é a closure deste frame
    | Just idx  <- M.lookup x (ceCaptured env) ->
        pure [ILoad 0, IPush (fromIntegral idx), IAget]
    | Just 0    <- M.lookup x (ceTop env)    -> pure [ICall x 0]
    -- função de topo usada como VALOR: vira closure sobre o invólucro
    | Just n    <- M.lookup x (ceTop env) -> do
        lbl <- ensureWrappers (ceTop env) x n
        pure (buildClosure lbl [])
    | x == "print" -> do
        lbl <- ensureBuiltinWrapper "print" IPrint
        pure (buildClosure lbl [])
    | x == "gc" -> do
        lbl <- ensureBuiltinWrapper "gc" IGc
        pure (buildClosure lbl [])
    | otherwise -> cgErr $ "variavel nao definida na geracao de codigo: " ++ x

  -- altura: +1. O operando direito é compilado com a altura JÁ incrementada,
  -- porque o esquerdo ocupa um slot. Sem esse ajuste, um @let@ dentro do
  -- operando direito escolheria o slot do esquerdo e o sobrescreveria — e o
  -- programa daria resultado errado sem nenhum erro.
  EBin op a b -> do
    ca <- compileExpr env a
    cb <- compileExpr env { ceSize = ceSize env + 1 } b
    pure (ca ++ cb ++ [binInstr op])

  ENeg a -> do
    ca <- compileExpr env a
    pure (ca ++ [INeg])

  -- altura: +1. Os dois ramos terminam na mesma altura, o que mantém a
  -- invariante válida depois do ponto de junção.
  EIf c a b -> do
    lElse <- fresh "else"
    lEnd  <- fresh "end"
    cc <- compileExpr env c
    ca <- compileExpr env a
    cb <- compileExpr env b
    pure $ cc ++ [IJz lElse] ++ ca ++ [IJmp lEnd, ILabel lElse] ++ cb ++ [ILabel lEnd]

  -- altura: +1 no total. Avalia o primeiro, descarta, avalia o segundo.
  ESeq a b -> do
    ca <- compileExpr env a
    cb <- compileExpr env b
    pure (ca ++ [IPop] ++ cb)

  -- altura: +1 no total.
  --
  -- O rhs é avaliado e fica no slot s = altura atual. O corpo é compilado com
  -- x ligado a s, e termina com STORE s: isso sobrescreve x — que já não é
  -- mais necessário — com o resultado, e deixa a pilha com um único valor
  -- novo, no slot s. Três instruções e nenhuma limpeza.
  ELet False x rhs body -> do
    let s    = ceSize env
        env' = env { ceLocals = M.insert x s (ceLocals env), ceSize = s + 1 }
    crhs  <- compileExpr env rhs
    cbody <- compileExpr env' body
    pure (crhs ++ cbody ++ [IStore (fromIntegral s)])

  -- Recursão local exige que a closure referencie a si mesma: alocar, guardar
  -- no slot e só então gravar o próprio endereço num campo dela. O coletor do
  -- P01 lida com o ciclo resultante sem nada extra, então é um incremento
  -- pequeno — mas é um incremento, e está no roadmap. Funções recursivas de
  -- topo funcionam.
  ELet True x _ _ -> cgErr $
    "'let rec " ++ x ++ "' local ainda nao e suportado.\n"
    ++ "       Recursao local precisa de closure que referencia a si mesma.\n"
    ++ "       Use uma declaracao 'let rec' de topo. Ver README, roadmap."

  -- altura: +1. Lambda vira função de topo; o valor é a closure sobre ela.
  ELam x body -> do
    let fvs  = S.toList (S.delete x (freeVars body))
        -- Só variáveis que existem no escopo ATUAL precisam ser capturadas:
        -- nomes de topo e `print` são alcançáveis de qualquer lugar.
        caps = filter (\v -> M.member v (ceLocals env) || M.member v (ceCaptured env)) fvs
    lbl <- fresh "lam"
    let envIn = CgEnv
                  { ceLocals   = M.singleton x 1       -- slot 0 = closure
                  , ceCaptured = M.fromList (zip caps [1 ..])
                  , ceTop      = ceTop env
                  , ceSize     = 2
                  }
    bodyCode <- compileExpr envIn body
    emitLifted (ILabel lbl : bodyCode ++ [IRet])
    -- as capturas são lidas no escopo de FORA
    capCode <- mapM (compileExpr env . EVar) caps
    pure (buildClosure lbl capCode)

  EApp _ _ -> do
    let (hd, args) = spine expr0
    case hd of
      -- print aplicado: caminho direto, sem closure
      -- 'gc n' emite a instrucao GC e deixa n na pilha: GC nao mexe na pilha,
      -- entao a altura continua +1 e a invariante se mantem.
      EVar "gc"
        | [a] <- args -> do
            ca <- compileExpr env a
            pure (ca ++ [IGc])
        | otherwise ->
            cgErr $ "'gc' espera exatamente 1 argumento, recebeu "
                 ++ show (length args)

      EVar "print"
        | [a] <- args -> do
            ca <- compileExpr env a
            -- DUP porque 'print : Int -> Int' devolve o valor e PRINT consome
            pure (ca ++ [IDup, IPrint])
        | otherwise ->
            cgErr $ "'print' espera exatamente 1 argumento, recebeu "
                 ++ show (length args)

      -- chamada direta: função de topo com aridade exata, sem alocar closure
      EVar f
        | Just arity <- M.lookup f (ceTop env)
        , arity == length args
        , arity > 0 -> do
            cargs <- compileArgs env args
            pure (cargs ++ [ICall f arity])

      -- caminho genérico: avalia o alvo como valor e aplica um argumento por
      -- vez. Cobre ordem superior, aplicação parcial e sobre-aplicação com um
      -- único mecanismo.
      _ -> do
        chd <- compileExpr env hd
        let h = ceSize env + 1     -- altura com a closure já empilhada
        rest <- applyOneByOne h args
        pure (chd ++ rest)

  where
    compileArgs _ [] = pure []
    compileArgs e (a : as) = do
      ca   <- compileExpr e a
      rest <- compileArgs e { ceSize = ceSize e + 1 } as
      pure (ca ++ rest)

    -- Cada CALLI 1 consome closure + 1 argumento e devolve 1 valor, então a
    -- altura volta a `h` a cada passo e a próxima iteração usa a mesma.
    applyOneByOne _ [] = pure []
    applyOneByOne h (a : as) = do
      ca   <- compileExpr env { ceSize = h } a
      rest <- applyOneByOne h as
      pure (ca ++ [ICalli 1] ++ rest)

binInstr :: BinOp -> Instr
binInstr o = case o of
  Add -> IAdd ; Sub -> ISub ; Mul -> IMul ; Div -> IDiv ; Mod -> IMod
  Lt  -> ILt  ; Le  -> ILe  ; Gt  -> IGt  ; Ge  -> IGe
  Eq  -> IEq  ; Ne  -> INe
