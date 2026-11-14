-- | Bytecode da Forge VM (projeto P01), com montador e emissor de texto.
--
-- Este módulo é a fronteira entre os dois projetos. Os opcodes, os tamanhos de
-- operando e o formato do arquivo @.fbc@ têm de bater **byte a byte** com
-- @p01-metal-vm/c/include/fvm.h@ e @p01-metal-vm/rust/src/chunk.rs@ — as duas
-- implementações independentes da VM que executam o que sai daqui.
--
-- A verificação disso não é por inspeção: o teste de integração monta o mesmo
-- programa aqui e no montador do P01 e compara os bytes.
module Bytecode
  ( Instr (..)
  , Label
  , assemble
  , toFasm
  , instrSize
  ) where

import Data.Bits (shiftR)
import Data.Int (Int32, Int64)
import Data.Word (Word8)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as M

type Label = String

-- | Instruções, na mesma ordem do @enum Op@ do P01. 'ILabel' é pseudo: não
-- emite byte nenhum, só marca posição.
data Instr
  = IHalt
  | IPush Int64
  | IPop
  | IDup
  | ISwap
  | IAdd | ISub | IMul | IDiv | IMod | INeg
  | ILt  | ILe  | IGt  | IGe  | IEq  | INe
  | IJmp Label
  | IJz Label
  | IJnz Label
  | ILoad Int32
  | IStore Int32
  | IReserve Int32
  | ICall Label Int
  | IRet
  | IPrint
  | INewarr | IAget | IAset | IAlen | IGc
  | ILabel Label
  deriving (Show, Eq)

opcode :: Instr -> Word8
opcode i = case i of
  IHalt      -> 0
  IPush _    -> 1
  IPop       -> 2
  IDup       -> 3
  ISwap      -> 4
  IAdd       -> 5
  ISub       -> 6
  IMul       -> 7
  IDiv       -> 8
  IMod       -> 9
  INeg       -> 10
  ILt        -> 11
  ILe        -> 12
  IGt        -> 13
  IGe        -> 14
  IEq        -> 15
  INe        -> 16
  IJmp _     -> 17
  IJz _      -> 18
  IJnz _     -> 19
  ILoad _    -> 20
  IStore _   -> 21
  IReserve _ -> 22
  ICall _ _  -> 23
  IRet       -> 24
  IPrint     -> 25
  INewarr    -> 26
  IAget      -> 27
  IAset      -> 28
  IAlen      -> 29
  IGc        -> 30
  ILabel _   -> error "ILabel nao tem opcode"

-- | Tamanho em bytes. Pseudo-instrução ocupa zero.
instrSize :: Instr -> Int
instrSize i = case i of
  ILabel _   -> 0
  IPush _    -> 1 + 8
  IJmp _     -> 1 + 4
  IJz _      -> 1 + 4
  IJnz _     -> 1 + 4
  ILoad _    -> 1 + 4
  IStore _   -> 1 + 4
  IReserve _ -> 1 + 4
  ICall _ _  -> 1 + 4 + 1
  _          -> 1

le32 :: Int32 -> [Word8]
le32 n = [fromIntegral (n `shiftR` (8 * k)) | k <- [0 .. 3]]

le64 :: Int64 -> [Word8]
le64 n = [fromIntegral (n `shiftR` (8 * k)) | k <- [0 .. 7]]

-- | Monta a lista de instruções num arquivo @.fbc@ completo.
--
-- Dois passes, como qualquer montador: o primeiro calcula a posição de cada
-- rótulo somando tamanhos, o segundo emite os bytes já com os endereços
-- resolvidos. O primeiro passe não precisa emitir nada, e é por isso que
-- 'instrSize' existe separado de 'opcode'.
assemble :: [Instr] -> Label -> Either String B.ByteString
assemble instrs entryLabel = do
    entry <- maybe (Left $ "rotulo de entrada nao encontrado: " ++ entryLabel)
                   Right
                   (M.lookup entryLabel labels)
    code <- concat <$> mapM emit instrs
    let n = length code
    Right $ B.pack $
         [0x46, 0x56, 0x4D, 0x31]            -- "FVM1"
      ++ le32 (fromIntegral entry)
      ++ le32 (fromIntegral n)
      ++ code
  where
    labels :: M.Map Label Int
    labels = snd (foldl step (0, M.empty) instrs)
      where
        step (off, m) (ILabel l) = (off, M.insert l off m)
        step (off, m) i          = (off + instrSize i, m)

    resolve :: Label -> Either String Int32
    resolve l = case M.lookup l labels of
      Just off -> Right (fromIntegral off)
      Nothing  -> Left $ "rotulo nao definido: " ++ l

    emit :: Instr -> Either String [Word8]
    emit i = case i of
      ILabel _    -> Right []
      IPush v     -> Right (opcode i : le64 v)
      ILoad s     -> Right (opcode i : le32 s)
      IStore s    -> Right (opcode i : le32 s)
      IReserve s  -> Right (opcode i : le32 s)
      IJmp l      -> (\a -> opcode i : le32 a) <$> resolve l
      IJz l       -> (\a -> opcode i : le32 a) <$> resolve l
      IJnz l      -> (\a -> opcode i : le32 a) <$> resolve l
      ICall l n
        | n < 0 || n > 255 -> Left $ "CALL com nargs fora de 0..255: " ++ show n
        | otherwise -> (\a -> opcode i : le32 a ++ [fromIntegral n]) <$> resolve l
      _           -> Right [opcode i]

-- | Emite o mesmo programa em texto @.fasm@, que é a linguagem de entrada do
-- montador do P01.
--
-- Serve a dois propósitos: depurar o gerador de código lendo algo legível, e
-- permitir o teste que monta o MESMO programa pelos dois caminhos — aqui e
-- pelo montador em C — e compara os bytes resultantes.
toFasm :: [Instr] -> Label -> String
toFasm instrs entryLabel =
  unlines $ ("; gerado por forge-lang -- nao editar") : (".entry " ++ entryLabel) : map line instrs
  where
    line i = case i of
      ILabel l    -> l ++ ":"
      IPush v     -> "  PUSH " ++ show v
      ILoad s     -> "  LOAD " ++ show s
      IStore s    -> "  STORE " ++ show s
      IReserve s  -> "  RESERVE " ++ show s
      IJmp l      -> "  JMP " ++ l
      IJz l       -> "  JZ " ++ l
      IJnz l      -> "  JNZ " ++ l
      ICall l n   -> "  CALL " ++ l ++ " " ++ show n
      _           -> "  " ++ mnemonic i

    mnemonic i = case i of
      IHalt -> "HALT" ; IPop -> "POP" ; IDup -> "DUP" ; ISwap -> "SWAP"
      IAdd -> "ADD" ; ISub -> "SUB" ; IMul -> "MUL" ; IDiv -> "DIV"
      IMod -> "MOD" ; INeg -> "NEG"
      ILt -> "LT" ; ILe -> "LE" ; IGt -> "GT" ; IGe -> "GE"
      IEq -> "EQ" ; INe -> "NE"
      IRet -> "RET" ; IPrint -> "PRINT"
      INewarr -> "NEWARR" ; IAget -> "AGET" ; IAset -> "ASET"
      IAlen -> "ALEN" ; IGc -> "GC"
      _ -> error "mnemonic: instrucao com operando"
