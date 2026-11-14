-- | Árvore sintática da forge.
--
-- Deliberadamente pequena. A linguagem existe para exercitar inferência de
-- tipos e geração de código, não para ser confortável de programar — cada
-- construção aqui precisa ter uma regra de tipo e uma tradução para o
-- bytecode do P01, e nenhuma está presente "de brinde".
module Ast
  ( Lit (..)
  , BinOp (..)
  , Expr (..)
  , Decl (..)
  , Program
  , opName
  ) where

data Lit
  = LInt Integer
  | LBool Bool
  deriving (Show, Eq)

data BinOp
  = Add | Sub | Mul | Div | Mod
  | Lt  | Le  | Gt  | Ge  | Eq | Ne
  deriving (Show, Eq)

opName :: BinOp -> String
opName o = case o of
  Add -> "+" ; Sub -> "-" ; Mul -> "*" ; Div -> "/" ; Mod -> "%"
  Lt  -> "<" ; Le  -> "<="; Gt  -> ">" ; Ge  -> ">="; Eq  -> "=="
  Ne  -> "!="

data Expr
  = ELit Lit
  | EVar String
  | EBin BinOp Expr Expr
  | ENeg Expr
  | EIf Expr Expr Expr
  | EApp Expr Expr
  | ELam String Expr
  -- | @ELet recursivo nome rhs corpo@
  | ELet Bool String Expr Expr
  -- | @e1 ; e2@ — avalia e1, descarta, devolve e2.
  | ESeq Expr Expr
  deriving (Show, Eq)

-- | Declaração de topo: @let [rec] nome p1 p2 = corpo@.
--
-- Os parâmetros ficam separados do corpo, em vez de virarem 'ELam'
-- aninhada, porque a geração de código precisa saber a **aridade** de cada
-- função de topo para emitir @CALL rotulo nargs@. Essa informação se perde
-- se a definição for currificada na própria AST — e recuperá-la depois
-- exigiria desfazer o currying, que é trabalho inútil.
data Decl = Decl
  { dRec    :: Bool
  , dName   :: String
  , dParams :: [String]
  , dBody   :: Expr
  } deriving (Show, Eq)

type Program = [Decl]
