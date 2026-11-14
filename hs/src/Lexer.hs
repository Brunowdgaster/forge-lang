-- | Analisador léxico.
--
-- Escrito à mão, sem gerador. Não é masoquismo: um lexer de 120 linhas para
-- uma linguagem deste tamanho é mais legível que uma gramática de Alex, e
-- posições de linha e coluna corretas nas mensagens de erro ficam sob controle
-- direto — que é o que separa um compilador utilizável de um exercício.
module Lexer
  ( Token (..)
  , Tok (..)
  , tokenize
  ) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)

data Tok
  = TInt_ Integer
  | TIdent String
  | TKw String        -- ^ palavra reservada
  | TSym String       -- ^ operador ou pontuação
  | TEOF
  deriving (Eq, Show)

-- | Token com posição, para que o erro aponte o lugar certo.
data Token = Token
  { tTok  :: Tok
  , tLine :: Int
  , tCol  :: Int
  } deriving (Eq, Show)

keywords :: [String]
keywords = ["let", "rec", "in", "if", "then", "else", "true", "false"]

-- | Símbolos de dois caracteres vêm primeiro: a ordem desta lista é
-- significativa. Se @"<"@ fosse testado antes de @"<="@, a entrada @"<="@
-- lexaria como @"<"@ seguido de @"="@ e o parser daria um erro sem relação com
-- a causa.
symbols :: [String]
symbols = ["<=", ">=", "==", "!=", "->", "\\", "+", "-", "*", "/", "%"
          , "<", ">", "=", "(", ")", ";"]

tokenize :: String -> Either String [Token]
tokenize = go 1 1
  where
    go :: Int -> Int -> String -> Either String [Token]
    go ln col s = case s of
      [] -> Right [Token TEOF ln col]

      ('-':'-':rest) ->                       -- comentário de linha
        let rest' = dropWhile (/= '\n') rest
        in go ln col rest'

      ('\n':rest) -> go (ln + 1) 1 rest

      (c:rest)
        | isSpace c -> go ln (col + 1) rest

        | isDigit c ->
            let (ds, rest') = span isDigit (c : rest)
                n           = read ds :: Integer
            in (Token (TInt_ n) ln col :) <$> go ln (col + length ds) rest'

        | isAlpha c || c == '_' ->
            let (ws, rest') = span (\x -> isAlphaNum x || x == '_' || x == '\'') (c : rest)
                tk | ws `elem` keywords = TKw ws
                   | otherwise          = TIdent ws
            in (Token tk ln col :) <$> go ln (col + length ws) rest'

        | otherwise ->
            case matchSym (c : rest) of
              Just sym ->
                (Token (TSym sym) ln col :)
                  <$> go ln (col + length sym) (drop (length sym) (c : rest))
              Nothing ->
                Left $ show ln ++ ":" ++ show col
                    ++ ": caractere inesperado " ++ show c

    matchSym :: String -> Maybe String
    matchSym s = case filter (`prefixOf` s) symbols of
      (x:_) -> Just x
      []    -> Nothing

    prefixOf :: String -> String -> Bool
    prefixOf p s = take (length p) s == p
