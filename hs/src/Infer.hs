-- | Inferência de tipos: Algoritmo W.
--
-- Nenhum tipo é anotado pelo programador em lugar nenhum da linguagem. Tudo o
-- que aparece em @forge types@ foi deduzido daqui — inclusive os tipos
-- polimórficos e de ordem superior, que o verificador trata corretamente
-- mesmo quando o gerador de código ainda não sabe baixá-los (ver
-- 'Codegen').
--
-- A estrutura é a canônica de Damas-Milner: cada caso devolve um par
-- @(substituição, tipo)@, e a substituição acumulada é composta na ordem
-- correta. Composição na ordem errada é o bug clássico desta implementação —
-- produz um unificador que não é o mais geral, e o sintoma aparece longe da
-- causa.
module Infer
  ( inferProgram
  , inferExpr
  , builtins
  ) where

import Ast
import Types

import Control.Monad.State
import qualified Data.Map as M

type Infer a = StateT Int (Either String) a

runInfer :: Infer a -> Either String a
runInfer m = evalStateT m 0

fresh :: Infer Type
fresh = do
  n <- get
  put (n + 1)
  pure (TVar ("t" ++ show n))

-- | Instancia um esquema com variáveis novas. É o que permite usar a mesma
-- função polimórfica em dois tipos diferentes no mesmo programa.
instantiate :: Scheme -> Infer Type
instantiate (Scheme vs t) = do
  vs' <- mapM (const fresh) vs
  pure (applyT (M.fromList (zip vs vs')) t)

unifyI :: Type -> Type -> Infer Subst
unifyI a b = lift (unify a b)

errI :: String -> Infer a
errI = lift . Left

-- | Ambiente inicial. @print@ devolve o valor impresso para que
-- @print a; print b@ seja tipável sem precisar de um tipo unitário.
builtins :: TypeEnv
builtins = M.fromList
  [ ("print", Scheme [] (TFun TInt TInt)) ]

-- ------------------------------------------------------------------ expressão

infer :: TypeEnv -> Expr -> Infer (Subst, Type)
infer env e = case e of
  ELit (LInt _)  -> pure (emptySubst, TInt)
  ELit (LBool _) -> pure (emptySubst, TBool)

  EVar x -> case M.lookup x env of
    Nothing -> errI $ "variavel nao definida: " ++ x
    Just sc -> do
      t <- instantiate sc
      pure (emptySubst, t)

  ELam x body -> do
    tv <- fresh
    let env' = M.insert x (Scheme [] tv) env
    (s1, t1) <- infer env' body
    pure (s1, TFun (applyT s1 tv) t1)

  EApp f a -> do
    (s1, tf) <- infer env f
    (s2, ta) <- infer (applyEnv s1 env) a
    tv <- fresh
    s3 <- unifyI (applyT s2 tf) (TFun ta tv)
    pure (s3 `composeSubst` s2 `composeSubst` s1, applyT s3 tv)

  ENeg a -> do
    (s1, t1) <- infer env a
    s2 <- unifyI t1 TInt
    pure (s2 `composeSubst` s1, TInt)

  EBin op a b -> do
    (s1, t1) <- infer env a
    (s2, t2) <- infer (applyEnv s1 env) b
    let t1' = applyT s2 t1
    case op of
      _ | op `elem` [Add, Sub, Mul, Div, Mod] -> do
            sa <- unifyI t1' TInt
            sb <- unifyI (applyT sa t2) TInt
            pure (sb `composeSubst` sa `composeSubst` s2 `composeSubst` s1, TInt)

        | op `elem` [Lt, Le, Gt, Ge] -> do
            sa <- unifyI t1' TInt
            sb <- unifyI (applyT sa t2) TInt
            pure (sb `composeSubst` sa `composeSubst` s2 `composeSubst` s1, TBool)

        -- Igualdade unifica os dois lados em vez de exigir Int: permite
        -- comparar Bool com Bool, e a instrução EQ do bytecode já faz isso.
        -- O que ela NÃO permite é comparar Int com Bool, que é o erro real.
        | otherwise -> do
            sa <- unifyI t1' (applyT s2 t2)
            pure (sa `composeSubst` s2 `composeSubst` s1, TBool)

  EIf c a b -> do
    (s1, tc) <- infer env c
    s2 <- unifyI tc TBool
    let s12  = s2 `composeSubst` s1
        env1 = applyEnv s12 env
    (s3, ta) <- infer env1 a
    (s4, tb) <- infer (applyEnv s3 env1) b
    s5 <- unifyI (applyT s4 ta) tb
    pure ( s5 `composeSubst` s4 `composeSubst` s3 `composeSubst` s12
         , applyT s5 tb )

  ESeq a b -> do
    (s1, _) <- infer env a
    (s2, t2) <- infer (applyEnv s1 env) b
    pure (s2 `composeSubst` s1, t2)

  -- let não recursivo: generaliza o tipo do rhs ANTES de ligar o nome, o que
  -- dá o polimorfismo do let.
  ELet False x rhs body -> do
    (s1, t1) <- infer env rhs
    let env1 = applyEnv s1 env
        sc   = generalize env1 t1
    (s2, t2) <- infer (M.insert x sc env1) body
    pure (s2 `composeSubst` s1, t2)

  -- let rec: o nome entra no ambiente como MONOMÓRFICO (variável fresca)
  -- enquanto o próprio rhs é inferido, e só depois é generalizado. Generalizar
  -- antes permitiria que a função usasse a si mesma em dois tipos diferentes,
  -- o que Hindley-Milner não garante decidível.
  ELet True x rhs body -> do
    tv <- fresh
    let envR = M.insert x (Scheme [] tv) env
    (s1, t1) <- infer envR rhs
    s2 <- unifyI (applyT s1 tv) t1
    let s    = s2 `composeSubst` s1
        env1 = applyEnv s env
        sc   = generalize env1 (applyT s t1)
    (s3, t3) <- infer (M.insert x sc env1) body
    pure (s3 `composeSubst` s, t3)

-- | Infere o tipo de uma expressão isolada, no ambiente dos builtins.
inferExpr :: Expr -> Either String Scheme
inferExpr e = runInfer $ do
  (s, t) <- infer builtins e
  pure (generalize M.empty (applyT s t))

-- ------------------------------------------------------------------- programa

-- | Declarações são processadas em ordem: uma função só vê as anteriores.
--
-- É uma escolha, não uma limitação acidental — torna a inferência um passe
-- único e obriga o programa a declarar antes de usar. Mútua recursão entre
-- declarações de topo exigiria um passe de componentes fortemente conexos, que
-- está no roadmap.
inferProgram :: Program -> Either String TypeEnv
inferProgram prog = runInfer (go builtins prog)
  where
    go env [] = pure env
    go env (d : ds) = do
      sc <- withContext (dName d) (inferDecl env d)
      go (M.insert (dName d) sc env) ds

    withContext name m = StateT $ \s ->
      case runStateT m s of
        Left msg      -> Left $ "em '" ++ name ++ "': " ++ msg
        Right (a, s') -> Right (a, s')

inferDecl :: TypeEnv -> Decl -> Infer Scheme
inferDecl env d = do
  let body = foldr ELam (dBody d) (dParams d)
  if dRec d
    then do
      tv <- fresh
      let envR = M.insert (dName d) (Scheme [] tv) env
      (s1, t1) <- infer envR body
      s2 <- unifyI (applyT s1 tv) t1
      let s = s2 `composeSubst` s1
      pure (generalize (applyEnv s env) (applyT s t1))
    else do
      (s1, t1) <- infer env body
      pure (generalize (applyEnv s1 env) t1)
