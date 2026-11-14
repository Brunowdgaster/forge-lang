-- | Geração de código para o bytecode do P01.
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
-- operandos, acima dos argumentos. É a mesma decisão do P01 (ver o ISA dele), e
-- aqui ela compensa duas vezes — o @let@ compila para três instruções e o
-- conjunto de raízes do coletor continua sendo só a pilha.
--
-- = O limite desta fase
--
-- O bytecode do P01 só tem @CALL endereço nargs@: chamada direta, para um
-- endereço fixo, conhecido em tempo de montagem. Isso basta para funções de
-- primeira ordem e __não basta para closures__. Programas de ordem superior
-- são aceitos pelo verificador de tipos (que é geral) e recusados aqui, com
-- mensagem explícita. Fechar essa lacuna exige uma instrução nova na VM; o
-- desenho está no README, seção Fase 2.
module Codegen
  ( compileProgram
  ) where

import Ast
import Bytecode

import Control.Monad.State
import qualified Data.Map as M

data CgEnv = CgEnv
  { ceLocals :: M.Map String Int   -- ^ nome -> slot, relativo à base do frame
  , ceTop    :: M.Map String Int   -- ^ nome -> aridade
  , ceSize   :: Int                -- ^ altura atual do frame
  }

type Cg a = StateT Int (Either String) a

freshLabel :: String -> Cg Label
freshLabel base = do
  n <- get
  put (n + 1)
  pure ("." ++ base ++ show n)

cgErr :: String -> Cg a
cgErr = lift . Left

-- | Recusa de Fase 2: mensagem única, para que o usuário saiba que o programa
-- é válido e o compilador é que ainda não baixa.
phase2 :: String -> Cg a
phase2 what = cgErr $
  what ++ ".\n"
  ++ "       O programa e bem tipado — o verificador o aceita — mas o bytecode\n"
  ++ "       do P01 so tem chamada direta (CALL endereco nargs), sem closures.\n"
  ++ "       Use 'forge types' para ver o tipo inferido. Suporte a ordem\n"
  ++ "       superior exige uma instrucao nova na VM: ver README, Fase 2."

-- | Separa a espinha de aplicação: @f a b c@ -> @(f, [a,b,c])@.
spine :: Expr -> (Expr, [Expr])
spine = go []
  where
    go acc (EApp f a) = go (a : acc) f
    go acc e          = (e, acc)

-- ------------------------------------------------------------------ programa

compileProgram :: Program -> Either String [Instr]
compileProgram prog
  | not (any ((== "main") . dName) prog) =
      Left "o programa precisa de uma declaracao 'main'"
  | otherwise = evalStateT (concat <$> mapM (compileDecl tops) prog) 0
  where
    tops = M.fromList [ (dName d, length (dParams d)) | d <- prog ]

compileDecl :: M.Map String Int -> Decl -> Cg [Instr]
compileDecl tops d = do
  let ps    = dParams d
      nargs = length ps
      env   = CgEnv
                { ceLocals = M.fromList (zip ps [0 ..])
                , ceTop    = tops
                , ceSize   = nargs
                }
  body <- compileExpr env (dBody d)
  -- 'main' encerra o programa; qualquer outra declaração devolve ao chamador.
  let final = if dName d == "main" then IHalt else IRet
  pure (ILabel (dName d) : body ++ [final])

-- ---------------------------------------------------------------- expressões

compileExpr :: CgEnv -> Expr -> Cg [Instr]
compileExpr env expr0 = case expr0 of

  -- altura: +1
  ELit (LInt n)  -> pure [IPush (fromIntegral n)]
  ELit (LBool b) -> pure [IPush (if b then 1 else 0)]

  -- altura: +1
  EVar x
    | Just slot <- M.lookup x (ceLocals env) -> pure [ILoad (fromIntegral slot)]
    | Just 0    <- M.lookup x (ceTop env)    -> pure [ICall x 0]
    | Just n    <- M.lookup x (ceTop env)    ->
        phase2 $ "a funcao '" ++ x ++ "' (aridade " ++ show n
              ++ ") foi usada como valor, sem ser aplicada"
    | x == "print" -> phase2 "'print' foi usado como valor, sem ser aplicado"
    | otherwise    -> cgErr $ "variavel nao definida na geracao de codigo: " ++ x

  -- altura: +1 (dois operandos empilhados, instrução consome os dois)
  --
  -- O operando direito é compilado com a altura JÁ incrementada, porque o
  -- esquerdo ocupa um slot. Sem esse ajuste, um @let@ dentro do operando
  -- direito escolheria o slot do operando esquerdo e o sobrescreveria — e o
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
    lElse <- freshLabel "else"
    lEnd  <- freshLabel "end"
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

  ELet True x _ _ ->
    phase2 $ "'let rec " ++ x ++ "' local define uma funcao recursiva aninhada"

  ELam _ _ ->
    phase2 "ha uma funcao anonima (lambda) em posicao de valor"

  -- altura: +1. Os argumentos são empilhados em ordem; CALL consome nargs e
  -- devolve um valor.
  EApp _ _ -> do
    let (hd, args) = spine expr0
    case hd of
      EVar "print"
        | [a] <- args -> do
            ca <- compileExpr env a
            -- DUP antes de PRINT porque 'print : Int -> Int' devolve o valor
            -- impresso, e PRINT consome o seu operando.
            pure (ca ++ [IDup, IPrint])
        | otherwise ->
            cgErr $ "'print' espera exatamente 1 argumento, recebeu "
                 ++ show (length args)

      EVar f
        | Just arity <- M.lookup f (ceTop env) ->
            if arity == length args
              then do
                cargs <- compileArgs env args
                pure (cargs ++ [ICall f (length args)])
              else phase2 $ "a funcao '" ++ f ++ "' tem aridade " ++ show arity
                         ++ " mas foi aplicada a " ++ show (length args)
                         ++ " argumento(s)"
        | Just _ <- M.lookup f (ceLocals env) ->
            phase2 $ "'" ++ f ++ "' e um parametro ou local sendo chamado como funcao"
        | otherwise -> cgErr $ "funcao nao definida: " ++ f

      _ -> phase2 "a posicao de funcao da aplicacao nao e um nome de topo"

  where
    -- Cada argumento já empilhado desloca a altura disponível para o próximo.
    compileArgs _ [] = pure []
    compileArgs e (a : as) = do
      ca   <- compileExpr e a
      rest <- compileArgs e { ceSize = ceSize e + 1 } as
      pure (ca ++ rest)

binInstr :: BinOp -> Instr
binInstr o = case o of
  Add -> IAdd ; Sub -> ISub ; Mul -> IMul ; Div -> IDiv ; Mod -> IMod
  Lt  -> ILt  ; Le  -> ILe  ; Gt  -> IGt  ; Ge  -> IGe
  Eq  -> IEq  ; Ne  -> INe
