-- | CLI do compilador forge.
--
--   forge check  prog.fg              verifica tipos, nao gera nada
--   forge types  prog.fg              imprime o tipo inferido de cada declaracao
--   forge build  prog.fg -o prog.fbc  compila para bytecode do P01
--   forge emit   prog.fg              imprime o .fasm equivalente
--   forge ast    prog.fg              imprime a arvore sintatica
--
-- A separacao entre @check@ e @build@ nao e cosmetica: o verificador de tipos
-- aceita a linguagem inteira, incluindo ordem superior, e o gerador de codigo
-- ainda nao. @forge types@ num programa que @forge build@ recusa mostra que a
-- recusa e do backend, nao do sistema de tipos.
module Main (main) where

import Ast
import Bytecode
import Codegen
import Infer
import Parser
import Types

import qualified Data.ByteString as B
import qualified Data.Map as M
import System.Environment (getArgs)
import System.Exit (exitFailure, exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)

version :: String
version = "0.1.0"

usage :: IO a
usage = do
  hPutStrLn stderr $ unlines
    [ "forge " ++ version ++ " - compilador da linguagem forge"
    , ""
    , "uso:"
    , "  forge check <prog.fg>                verifica tipos"
    , "  forge types <prog.fg>                tipo inferido de cada declaracao"
    , "  forge build <prog.fg> -o <prog.fbc>  compila para bytecode do P01"
    , "  forge emit  <prog.fg>                imprime o .fasm equivalente"
    , "  forge ast   <prog.fg>                imprime a arvore sintatica"
    , "  forge version"
    ]
  exitWith (ExitFailure 64)

die' :: String -> IO a
die' msg = hPutStrLn stderr ("forge: " ++ msg) >> exitFailure

-- | Pipeline comum: ler, lexar, parsear, inferir. Devolve o programa e o
-- ambiente de tipos.
frontend :: FilePath -> IO (Program, TypeEnv)
frontend path = do
  src <- readFile path
  prog <- case parseProgram src of
    Left e  -> die' (path ++ ":" ++ e)
    Right p -> pure p
  -- "o programa precisa de main" e regra de boa-formacao do PROGRAMA, nao de
  -- geracao de codigo. Ficava no Codegen, e o efeito era 'forge check' aceitar
  -- um programa que 'forge build' recusava por um motivo que nao tem nada a
  -- ver com backend. O teste sem_main.fg pegou isso.
  case filter ((== "main") . dName) prog of
    [] -> die' (path ++ ": o programa precisa de uma declaracao 'main'")
    _  -> pure ()
  env <- case inferProgram prog of
    Left e  -> die' ("erro de tipo: " ++ e)
    Right t -> pure t
  pure (prog, env)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["version"] -> putStrLn ("forge " ++ version)

    ["check", path] -> do
      (prog, _) <- frontend path
      putStrLn $ "ok: " ++ show (length prog) ++ " declaracoes, tipos conferem"

    ["types", path] -> do
      (prog, env) <- frontend path
      mapM_ (printType env) prog

    ["ast", path] -> do
      (prog, _) <- frontend path
      mapM_ print prog

    ["emit", path] -> do
      (prog, _) <- frontend path
      instrs <- lower prog
      putStr (toFasm instrs "main")

    ["build", path, "-o", out] -> do
      (prog, _) <- frontend path
      instrs <- lower prog
      case assemble instrs "main" of
        Left e   -> die' ("erro de montagem: " ++ e)
        Right bs -> do
          B.writeFile out bs
          hPutStrLn stderr $ "forge: " ++ show (B.length bs) ++ " bytes -> " ++ out

    _ -> usage
  where
    lower prog = case compileProgram prog of
      Left e   -> die' ("nao consegui gerar codigo: " ++ e)
      Right is -> pure is

    printType env d = case M.lookup (dName d) env of
      Nothing -> die' ("sem tipo para " ++ dName d)
      Just sc -> putStrLn (dName d ++ " : " ++ prettyScheme sc)
