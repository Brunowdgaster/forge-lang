-- | Tipos, substituições e unificação.
--
-- O sistema é Hindley-Milner clássico: tipos monomórficos de primeira ordem
-- mais quantificação universal apenas no topo de um esquema (@forall a. t@).
-- Não há tipos de ordem superior, nem classes, nem anotações do usuário — a
-- inferência é total, e isso é o ponto do projeto: nada aqui é anotado à mão.
module Types
  ( Type (..)
  , Scheme (..)
  , Subst
  , TypeEnv
  , emptySubst
  , applyT
  , applyS
  , applyEnv
  , composeSubst
  , ftv
  , ftvScheme
  , ftvEnv
  , unify
  , generalize
  , prettyType
  , prettyScheme
  ) where

import qualified Data.Map as M
import qualified Data.Set as S
import Data.List (intercalate)

data Type
  = TInt
  | TBool
  | TVar String
  | TFun Type Type
  deriving (Eq, Show)

-- | @Scheme vars tipo@ é @forall vars. tipo@.
data Scheme = Scheme [String] Type deriving (Eq, Show)

type Subst   = M.Map String Type
type TypeEnv = M.Map String Scheme

emptySubst :: Subst
emptySubst = M.empty

-- | Aplica uma substituição a um tipo.
applyT :: Subst -> Type -> Type
applyT s t = case t of
  TVar v    -> M.findWithDefault (TVar v) v s
  TFun a b  -> TFun (applyT s a) (applyT s b)
  _         -> t

applyS :: Subst -> Scheme -> Scheme
applyS s (Scheme vs t) =
  -- As variáveis quantificadas são removidas da substituição: elas estão
  -- ligadas pelo próprio esquema, e substituí-las seria captura de variável.
  Scheme vs (applyT (foldr M.delete s vs) t)

applyEnv :: Subst -> TypeEnv -> TypeEnv
applyEnv s = M.map (applyS s)

-- | @composeSubst s1 s2@ aplica s2 e depois s1.
--
-- A ordem importa e é a fonte clássica de bug em implementações de
-- Hindley-Milner: compor na ordem errada produz um unificador que não é mais
-- geral, e o sintoma aparece longe da causa — tipicamente num programa que
-- devia inferir @forall a. a -> a@ e infere @Int -> Int@.
composeSubst :: Subst -> Subst -> Subst
composeSubst s1 s2 = M.map (applyT s1) s2 `M.union` s1

-- | Variáveis de tipo livres.
ftv :: Type -> S.Set String
ftv t = case t of
  TVar v   -> S.singleton v
  TFun a b -> ftv a `S.union` ftv b
  _        -> S.empty

ftvScheme :: Scheme -> S.Set String
ftvScheme (Scheme vs t) = ftv t `S.difference` S.fromList vs

ftvEnv :: TypeEnv -> S.Set String
ftvEnv env = S.unions (map ftvScheme (M.elems env))

-- | Generalização: fecha as variáveis livres do tipo que **não** aparecem no
-- ambiente. É o que dá polimorfismo ao @let@ — e a condição sobre o ambiente é
-- o que impede generalizar a variável de um parâmetro de função, que seria
-- incorreto (o chamador é quem escolhe o tipo dela, não a função).
generalize :: TypeEnv -> Type -> Scheme
generalize env t = Scheme (S.toList (ftv t `S.difference` ftvEnv env)) t

-- | Unificação com teste de ocorrência.
unify :: Type -> Type -> Either String Subst
unify a b = case (a, b) of
  (TInt,  TInt)  -> Right emptySubst
  (TBool, TBool) -> Right emptySubst

  (TFun l1 r1, TFun l2 r2) -> do
    s1 <- unify l1 l2
    s2 <- unify (applyT s1 r1) (applyT s1 r2)
    Right (composeSubst s2 s1)

  (TVar v, t) -> bindVar v t
  (t, TVar v) -> bindVar v t

  _ -> Left $ "nao consegui unificar " ++ prettyType a ++ " com " ++ prettyType b

-- | O teste de ocorrência é o que impede construir um tipo infinito.
--
-- Sem ele, @\\x -> x x@ unificaria @a@ com @a -> b@ e a inferência entraria
-- em laço — ou pior, devolveria um tipo cíclico que estoura a pilha só na
-- hora de imprimir. O teste existe por isso, e o teste `tipo_infinito.fg`
-- cobre exatamente este caso.
bindVar :: String -> Type -> Either String Subst
bindVar v t
  | t == TVar v        = Right emptySubst
  | v `S.member` ftv t = Left $ "tipo infinito: " ++ v ++ " ocorre em " ++ prettyType t
  | otherwise          = Right (M.singleton v t)

prettyType :: Type -> String
prettyType = go False
  where
    go _ TInt       = "Int"
    go _ TBool      = "Bool"
    go _ (TVar v)   = v
    go paren (TFun a b)
      | paren     = "(" ++ inner ++ ")"
      | otherwise = inner
      where inner = go True a ++ " -> " ++ go False b

prettyScheme :: Scheme -> String
prettyScheme (Scheme [] t) = prettyType t
prettyScheme (Scheme vs t) =
  "forall " ++ intercalate " " vs ++ ". " ++ prettyType t
