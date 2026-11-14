-- | Analisador sintático: descida recursiva com precedência explícita.
--
-- Nenhum separador é exigido entre declarações de topo, e isso não é
-- descuido: uma expressão só pode ser **estendida** por um operador infixo ou
-- por aplicação, e @let@ não inicia um átomo. Logo, ao terminar o corpo de uma
-- declaração, encontrar @let@ só pode significar uma declaração nova. A
-- gramática fica sem @;;@ sem ficar ambígua.
module Parser
  ( parseProgram
  , parseExprString
  ) where

import Ast
import Lexer

-- | Parser com estado (lista de tokens) e erro.
newtype P a = P { runP :: [Token] -> Either String (a, [Token]) }

instance Functor P where
  fmap f (P g) = P $ \ts -> do
    (a, ts') <- g ts
    Right (f a, ts')

instance Applicative P where
  pure a = P $ \ts -> Right (a, ts)
  P f <*> P g = P $ \ts -> do
    (h, ts1) <- f ts
    (a, ts2) <- g ts1
    Right (h a, ts2)

instance Monad P where
  P g >>= f = P $ \ts -> do
    (a, ts') <- g ts
    runP (f a) ts'

failP :: String -> P a
failP msg = P $ \ts -> case ts of
  (t:_) -> Left $ show (tLine t) ++ ":" ++ show (tCol t) ++ ": " ++ msg
                ++ ", veio " ++ describe (tTok t)
  []    -> Left $ "fim inesperado da entrada: " ++ msg

describe :: Tok -> String
describe tk = case tk of
  TInt_ n  -> "o numero " ++ show n
  TIdent i -> "o identificador " ++ show i
  TKw k    -> "a palavra reservada " ++ show k
  TSym s   -> show s
  TEOF     -> "o fim do arquivo"

peek :: P Tok
peek = P $ \ts -> case ts of
  (t:_) -> Right (tTok t, ts)
  []    -> Right (TEOF, [])

advance :: P ()
advance = P $ \ts -> case ts of
  (_:rest) -> Right ((), rest)
  []       -> Right ((), [])

-- | Consome o token se ele casar, sem consumir caso contrário.
accept :: Tok -> P Bool
accept tk = do
  t <- peek
  if t == tk then advance >> pure True else pure False

expectSym :: String -> P ()
expectSym s = do
  ok <- accept (TSym s)
  if ok then pure () else failP ("esperava " ++ show s)

expectKw :: String -> P ()
expectKw k = do
  ok <- accept (TKw k)
  if ok then pure () else failP ("esperava " ++ show k)

ident :: P String
ident = do
  t <- peek
  case t of
    TIdent i -> advance >> pure i
    _        -> failP "esperava um identificador"

-- ---------------------------------------------------------------- programa

parseProgram :: String -> Either String Program
parseProgram src = do
  ts <- tokenize src
  (ds, rest) <- runP decls ts
  case rest of
    (t : _) | tTok t /= TEOF ->
      Left $ show (tLine t) ++ ":" ++ show (tCol t)
          ++ ": lixo apos o fim do programa: " ++ describe (tTok t)
    _ -> if null ds then Left "programa vazio" else Right ds

-- | Usado pelos testes e pelo subcomando @types@.
parseExprString :: String -> Either String Expr
parseExprString src = do
  ts <- tokenize src
  (e, _) <- runP expr ts
  Right e

decls :: P [Decl]
decls = do
  t <- peek
  case t of
    TKw "let" -> do
      d  <- decl
      ds <- decls
      pure (d : ds)
    _ -> pure []

decl :: P Decl
decl = do
  expectKw "let"
  isRec <- accept (TKw "rec")
  name  <- ident
  ps    <- params
  expectSym "="
  body  <- expr
  pure (Decl isRec name ps body)
  where
    params = do
      t <- peek
      case t of
        TIdent _ -> do { p <- ident; ps <- params; pure (p : ps) }
        _        -> pure []

-- ---------------------------------------------------------------- expressões

expr :: P Expr
expr = do
  t <- peek
  case t of
    TKw "if"  -> ifExpr
    TKw "let" -> letExpr
    TSym "\\" -> lamExpr
    _         -> seqExpr

ifExpr :: P Expr
ifExpr = do
  expectKw "if"
  c <- expr
  expectKw "then"
  a <- expr
  expectKw "else"
  b <- expr
  pure (EIf c a b)

-- | @let [rec] nome p1 p2 = rhs in corpo@
--
-- Os parâmetros são currificados em 'ELam' aqui, ao contrário das declarações
-- de topo: um @let@ local nunca é alvo de @CALL@ direto, então a aridade não
-- precisa ser preservada.
letExpr :: P Expr
letExpr = do
  expectKw "let"
  isRec <- accept (TKw "rec")
  name  <- ident
  ps    <- paramList
  expectSym "="
  rhs   <- expr
  expectKw "in"
  body  <- expr
  pure (ELet isRec name (foldr ELam rhs ps) body)
  where
    paramList = do
      t <- peek
      case t of
        TIdent _ -> do { p <- ident; ps <- paramList; pure (p : ps) }
        _        -> pure []

lamExpr :: P Expr
lamExpr = do
  expectSym "\\"
  ps <- some1
  expectSym "->"
  b  <- expr
  pure (foldr ELam b ps)
  where
    some1 = do
      p  <- ident
      ps <- rest
      pure (p : ps)
    rest = do
      t <- peek
      case t of
        TIdent _ -> do { p <- ident; ps <- rest; pure (p : ps) }
        _        -> pure []

-- | @;@ associa à direita e tem a precedência mais baixa.
seqExpr :: P Expr
seqExpr = do
  l <- cmpExpr
  ok <- accept (TSym ";")
  if ok then ESeq l <$> expr else pure l

-- | Comparações não associam: @a < b < c@ é erro de sintaxe, não um
-- encadeamento silenciosamente errado como em C.
cmpExpr :: P Expr
cmpExpr = do
  l <- addExpr
  t <- peek
  case t of
    TSym s | Just o <- lookup s relOps -> do
      advance
      r <- addExpr
      pure (EBin o l r)
    _ -> pure l
  where
    relOps = [("<", Lt), ("<=", Le), (">", Gt), (">=", Ge), ("==", Eq), ("!=", Ne)]

addExpr :: P Expr
addExpr = mulExpr >>= loop
  where
    loop l = do
      t <- peek
      case t of
        TSym "+" -> advance >> mulExpr >>= \r -> loop (EBin Add l r)
        TSym "-" -> advance >> mulExpr >>= \r -> loop (EBin Sub l r)
        _        -> pure l

mulExpr :: P Expr
mulExpr = unaryExpr >>= loop
  where
    loop l = do
      t <- peek
      case t of
        TSym "*" -> advance >> unaryExpr >>= \r -> loop (EBin Mul l r)
        TSym "/" -> advance >> unaryExpr >>= \r -> loop (EBin Div l r)
        TSym "%" -> advance >> unaryExpr >>= \r -> loop (EBin Mod l r)
        _        -> pure l

unaryExpr :: P Expr
unaryExpr = do
  t <- peek
  case t of
    TSym "-" -> advance >> (ENeg <$> unaryExpr)
    _        -> appExpr

-- | Aplicação: justaposição de átomos, associando à esquerda.
appExpr :: P Expr
appExpr = do
  f  <- atom
  as <- argsLoop
  pure (foldl EApp f as)
  where
    argsLoop = do
      t <- peek
      if startsAtom t
        then do { a <- atom; as <- argsLoop; pure (a : as) }
        else pure []

startsAtom :: Tok -> Bool
startsAtom t = case t of
  TInt_ _     -> True
  TIdent _    -> True
  TKw "true"  -> True
  TKw "false" -> True
  TSym "("    -> True
  _           -> False

atom :: P Expr
atom = do
  t <- peek
  case t of
    TInt_ n     -> advance >> pure (ELit (LInt n))
    TKw "true"  -> advance >> pure (ELit (LBool True))
    TKw "false" -> advance >> pure (ELit (LBool False))
    TIdent i    -> advance >> pure (EVar i)
    TSym "("    -> do
      advance
      e <- expr
      expectSym ")"
      pure e
    _ -> failP "esperava uma expressao"
