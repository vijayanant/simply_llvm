{-# LANGUAGE RecordWildCards #-}

module Simply.LLVM.Codegen where

import Protolude hiding (Type, local, void, local, one, zero)

import qualified Data.Map as Map
import qualified Data.List as List

import LLVM.AST hiding (callingConvention, functionAttributes)
import LLVM.AST.Global as G
import LLVM.AST.Type

import qualified LLVM.AST as AST
import qualified LLVM.AST.Attribute as A
import qualified LLVM.AST.CallingConvention as CC
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.IntegerPredicate as IP
import qualified LLVM.AST.FloatingPointPredicate as FP
import qualified LLVM.AST.Linkage as L

import Simply.Orphans ()

-------------------------------------------------------------------------------
-- Module Level
-------------------------------------------------------------------------------

newtype LLVM a = LLVM (State AST.Module a)
  deriving (Functor, Applicative, Monad, MonadState AST.Module )

runLLVM :: AST.Module -> LLVM a -> AST.Module
runLLVM llvmAst (LLVM m) = execState m llvmAst

emptyModule :: Text -> AST.Module
emptyModule label = defaultModule { moduleName = toS label }

addDefn :: Definition -> LLVM ()
addDefn d = do
  defs <- gets moduleDefinitions
  modify $ \s -> s { moduleDefinitions = defs ++ [d] }


-- | Define an externally visible function (used for main)
define ::  Type -> Text -> [(Type, Name)] -> Codegen a -> LLVM ()
define retty label argtys body = addDefn $
  GlobalDefinition $ functionDefaults {
    name        = Name $ toS label
  , parameters  = ([Parameter ty nm [] | (ty, nm) <- argtys], False)
  , returnType  = retty
  , basicBlocks = bls
    -- Needs to match calling convention in call
  , callingConvention = CC.Fast
  }
  where
    bls = createBlocks $ execCodegen $ do
      _ <- setBlock =<< addBlock entryBlockName
      body


-- | Define an internal function (can be optimised away)
internal ::  Type -> Text -> [(Type, Name)] -> Codegen a -> LLVM ()
internal retty label argtys body = addDefn $
  GlobalDefinition $ functionDefaults {
    name        = Name $ toS label
  , linkage     = L.Private
  , parameters  = ([Parameter ty nm [] | (ty, nm) <- argtys], False)
  , returnType  = retty
  , basicBlocks = bls
    -- Needs to match calling convention in call
  , callingConvention = CC.Fast
  }
  where
    bls = createBlocks $ execCodegen $ do
      _ <- setBlock =<< addBlock entryBlockName
      body


-- | Declare an external function that is not defined in the module
-- (used for malloc)
external ::  Type -> Text -> [(Type, Name)] -> LLVM ()
external retty label argtys = addDefn $
  GlobalDefinition $ functionDefaults
  { name        = Name $ toS label
  , linkage     = L.External
  , parameters  = ([Parameter ty nm [] | (ty, nm) <- argtys], False)
  , returnType  = retty
  , basicBlocks = []
  }


-- | Define the program entry point
entryPoint :: Word32 -> LLVM ()
entryPoint argc = addDefn $
  GlobalDefinition $ functionDefaults
    { name = Name "__entry_point"
    , parameters = ([Parameter (ptr int) (Name "argv") []], False)
    , returnType = int
    , basicBlocks = body
    }
  where
    body = createBlocks . execCodegen $ do
      _ <- setBlock =<< addBlock entryBlockName
      args <- forM (take argc' [0..]) $ \ i -> do
        p <- getElementPtr (ptr int) argv [cint i]
        load int p
      result <- call int main args
      ret result
    argc' = fromIntegral argc
    argv = LocalReference (ptr int) (Name "argv")
    main = cons $ global (ptr mainty) (Name "simply_main")
    mainty = fn int (replicate argc' int)


-- | Define a global constant
constant :: Type -> Name -> C.Constant -> LLVM ()
constant ty name val = addDefn $
  GlobalDefinition globalVariableDefaults
    { name = name
    , isConstant = True
    , G.type' = ty
    , initializer = Just val
    }


---------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

int :: Type
int = IntegerType 32

ibool :: Type
ibool = IntegerType 1

-- | type of a function
fn :: Type -> [Type] -> Type
fn retty argty = FunctionType retty argty False

-- | like a @void*@ in C
--
-- (used for malloc and closure environment)
anyPtr :: Type
anyPtr = ptr i8

-- | function pointer
fnPtr :: Type -> [Type] -> Type
fnPtr retty argty = ptr $ fn retty argty

-- | closure struct
--
-- holds pointer to the global function
-- and a pointer (@void*@) to the environment
closure :: Type -> [Type] -> Type
closure retty argty =
  StructureType
  { isPacked = False
  , elementTypes = [ fnPtr retty (anyPtr:argty), anyPtr ]
  }

-- | actual type of a closure environment
--
-- a struct that holds each captured value
closureEnv :: [Type] -> Type
closureEnv elemty =
  StructureType
  { isPacked = False
  , elementTypes = elemty
  }

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

cint, cint32 :: Integer -> Operand
cint = cons . C.Int 32
cint32 = cons . C.Int 32

one, zero :: Operand
one = cons $ C.Int 32 1
zero = cons $ C.Int 32 0

false, true :: Operand
false = cons $ C.Int 1 0
true = cons $ C.Int 1 1

-- undefined value
--
-- (used for building a structure)
undef :: Type -> Operand
undef ty = cons (C.Undef ty)

-- null pointer
--
-- (used for closures without capture)
nullP :: Type -> Operand
nullP ty = cons (C.Null ty)

-------------------------------------------------------------------------------
-- Names
-------------------------------------------------------------------------------

type Names = Map.Map Text Int

uniqueName :: Text -> Names -> (Text, Names)
uniqueName nm ns =
  case Map.lookup nm ns of
    Nothing -> (nm,  Map.insert nm 0 ns)
    Just ix -> (nm <> show ix, Map.insert nm (ix+1) ns)

-------------------------------------------------------------------------------
-- Codegen State
-------------------------------------------------------------------------------

type SymbolTable = [(Text, Operand)]

data CodegenState
  = CodegenState
  { currentBlock :: Name                     -- Name of the active block to append to
  , blocks       :: Map.Map Name BlockState  -- Blocks for function
  , symtab       :: SymbolTable              -- Function scope symbol table
  , blockCount   :: Int                      -- Count of basic blocks
  , count        :: Word                     -- Count of unnamed instructions
  , names        :: Names                    -- Name Supply
  } deriving Show

data BlockState
  = BlockState
  { idx   :: Int                            -- Block index
  , stack :: [Named Instruction]            -- Stack of instructions
  , term  :: Maybe (Named Terminator)       -- Block terminator
  } deriving Show

-------------------------------------------------------------------------------
-- Codegen Operations
-------------------------------------------------------------------------------

newtype Codegen a = Codegen { runCodegen :: State CodegenState a }
  deriving (Functor, Applicative, Monad, MonadState CodegenState )

sortBlocks :: [(Name, BlockState)] -> [(Name, BlockState)]
sortBlocks = sortBy (compare `on` (idx . snd))

createBlocks :: CodegenState -> [BasicBlock]
createBlocks m = sortUnnames $ map makeBlock $ sortBlocks $ Map.toList (blocks m)

sortUnnames :: [BasicBlock] -> [BasicBlock]
sortUnnames l = renameUnnames l $ enumerateUnnames l

enumerateUnnames :: [BasicBlock] -> Map.Map Word Word
enumerateUnnames l = snd $ execState (traverse_ enumBlock l) (0, Map.empty)
  where
    enumBlock :: BasicBlock -> State (Word, Map.Map Word Word) ()
    enumBlock (BasicBlock _ is t) = do
      traverse_ enum is
      enum t

    enum :: Named a -> State (Word, Map.Map Word Word) ()
    enum (Do _) = pure ()
    enum (Name _ := _) = pure ()
    enum (UnName n := _) = do
      -- get current counter
      n' <- gets fst
      -- map name to current counter
      modify $ second $ Map.insert n n'
      -- increment counter
      modify $ first succ

renameUnnames :: [BasicBlock] -> Map.Map Word Word -> [BasicBlock]
renameUnnames l m = map renameBlock l
  where
    rename :: Word -> Word
    rename n
      | Just n' <- Map.lookup n m = n'
      | otherwise = panic $
          "[Simply.LLVM.Codegen.renameUnnames.rename] \
          \Undefined name " <> show n

    renameBlock :: BasicBlock -> BasicBlock
    renameBlock (BasicBlock n is t) =
      let
        is' = map (mapNamed renameInstr . renameNamed) is
        t' = (mapNamed renameTerm . renameNamed) t
      in
      BasicBlock n is' t'

    mapNamed :: (a -> b) -> Named a -> Named b
    mapNamed f (Do a) = Do (f a)
    mapNamed f (n := a) = n := f a

    renameName :: Name -> Name
    renameName (UnName n) = UnName (rename n)
    renameName n = n

    renameNamed :: Named a -> Named a
    renameNamed (n := a) = renameName n := a
    renameNamed a = a

    renameOp :: Operand -> Operand
    renameOp = \case
      LocalReference ty n -> LocalReference ty (renameName n)
      op -> op

    renameInstr :: Instruction -> Instruction
    renameInstr = \case
      ins@Add {..} -> ins
        { operand0 = renameOp operand0
        , operand1 = renameOp operand1
        }
      ins@Sub {..} -> ins
        { operand0 = renameOp operand0
        , operand1 = renameOp operand1
        }
      ins@Mul {..} -> ins
        { operand0 = renameOp operand0
        , operand1 = renameOp operand1
        }
      ins@Alloca {..} -> ins
        { numElements = renameOp <$> numElements }
      ins@Load {..} -> ins
        { address = renameOp address
        }
      ins@Store {..} -> ins
        { address = renameOp address
        , value = renameOp value
        }
      ins@GetElementPtr {..} -> ins
        { address = renameOp address
        , indices = renameOp <$> indices
        }
      ins@PtrToInt {..} -> ins
        { operand0 = renameOp operand0 }
      ins@IntToPtr {..} -> ins
        { operand0 = renameOp operand0 }
      ins@BitCast {..} -> ins
        { operand0 = renameOp operand0 }
      ins@ICmp {..} -> ins
        { operand0 = renameOp operand0
        , operand1 = renameOp operand1
        }
      ins@Phi {..} -> ins
        { incomingValues = [ (renameOp op, renameName n) | (op, n) <- incomingValues ] }
      ins@Call {..} -> ins
        { function = renameOp <$> function
        , arguments = [ (renameOp op, attrs) | (op, attrs) <- arguments ]
        }
      ins@ExtractValue {..} -> ins
        { aggregate = renameOp aggregate }
      ins@InsertValue {..} -> ins
        { aggregate = renameOp aggregate
        , element = renameOp element
        }
      ins -> panic $
        "[Simply.LLVM.Codegen.renameUnnames.renameInstr] \
        \Unexpected instruction " <> show ins

    renameTerm :: Terminator -> Terminator
    renameTerm = \case
      Ret mbOp meta ->
        Ret (renameOp <$> mbOp) meta
      CondBr cond then_ else_ meta ->
        CondBr (renameOp cond) (renameName then_) (renameName else_) meta
      Br dst meta ->
        Br (renameName dst) meta
      t -> panic $
        "[Simply.LLVM.Codegen.renameUnnames.renameTerm] \
        \Unexpected terminator " <> show t

makeBlock :: (Name, BlockState) -> BasicBlock
makeBlock (l, BlockState _ s t) = BasicBlock l s (maketerm t)
  where
    maketerm (Just x) = x
    maketerm Nothing = panic $ "Block has no terminator: " <> show l

entryBlockName :: Text
entryBlockName = "entry"

emptyBlock :: Int -> BlockState
emptyBlock i = BlockState i [] Nothing

emptyCodegen :: CodegenState
emptyCodegen = CodegenState (Name $ toS entryBlockName) Map.empty [] 1 0 Map.empty

execCodegen :: Codegen a -> CodegenState
execCodegen m = execState (runCodegen m) emptyCodegen

fresh :: Codegen Word
fresh = do
  i <- gets count
  modify $ \s -> s { count = 1 + i }
  return i

freshName :: Codegen AST.Name
freshName = AST.UnName <$> fresh

instr :: Type -> Instruction -> Codegen Operand
instr ty ins = do
  n <- fresh
  let ref = UnName n
  blk <- current
  let i = stack blk
  modifyBlock (blk { stack = i ++ [ref := ins] } )
  return $ local ty ref

instr_ :: Instruction -> Codegen ()
instr_ ins = do
  blk <- current
  let i = stack blk
  modifyBlock (blk { stack = i ++ [Do ins] } )
  return ()

terminator :: Named Terminator -> Codegen (Named Terminator)
terminator trm = do
  blk <- current
  modifyBlock (blk { term = Just trm })
  return trm

-------------------------------------------------------------------------------
-- Block Stack
-------------------------------------------------------------------------------

entry :: Codegen Name
entry = gets currentBlock

addBlock :: Text -> Codegen Name
addBlock bname = do
  bls <- gets blocks
  ix <- gets blockCount
  nms <- gets names
  let
    new = emptyBlock ix
    (qname, supply) = uniqueName bname nms
  modify $ \s -> s { blocks = Map.insert (Name $ toS qname) new bls
                   , blockCount = ix + 1
                   , names = supply
                   }
  return (Name $ toS qname)

setBlock :: Name -> Codegen Name
setBlock bname = do
  modify $ \s -> s { currentBlock = bname }
  return bname

getBlock :: Codegen Name
getBlock = gets currentBlock

modifyBlock :: BlockState -> Codegen ()
modifyBlock new = do
  active <- gets currentBlock
  modify $ \s -> s { blocks = Map.insert active new (blocks s) }

current :: Codegen BlockState
current = do
  c <- gets currentBlock
  blks <- gets blocks
  case Map.lookup c blks of
    Just x -> return x
    Nothing -> panic $ "No such block: " <> show c

-------------------------------------------------------------------------------
-- Symbol Table
-------------------------------------------------------------------------------

assign :: Text -> Operand -> Codegen ()
assign var x = do
  lcls <- gets symtab
  modify $ \s -> s { symtab = (var, x) : lcls }

getvar :: Text -> Codegen Operand
getvar var = do
  syms <- gets symtab
  case List.lookup var syms of
    Just x  -> return x
    Nothing -> panic $ "Local variable not in scope: " <> show var

scope :: Codegen a -> Codegen a
scope m = do
  lcls <- gets symtab
  r <- m
  modify $ \s -> s { symtab = lcls }
  pure r

-------------------------------------------------------------------------------

-- References
local ::  Type -> Name -> Operand
local = LocalReference

global :: Type -> Name -> C.Constant
global = C.GlobalReference

-- | Refer to global function
externf :: Type -> Name -> Operand
externf ty nm = ConstantOperand (C.GlobalReference ty nm)

-- Arithmetic and Constants
fadd :: Operand -> Operand -> Codegen Operand
fadd a b = instr float $ FAdd NoFastMathFlags a b []

fsub :: Operand -> Operand -> Codegen Operand
fsub a b = instr float $ FSub NoFastMathFlags a b []

fmul :: Operand -> Operand -> Codegen Operand
fmul a b = instr float $ FMul NoFastMathFlags a b []

fdiv :: Operand -> Operand -> Codegen Operand
fdiv a b = instr float $ FDiv NoFastMathFlags a b []

fcmp :: FP.FloatingPointPredicate -> Operand -> Operand -> Codegen Operand
fcmp cond a b = instr float $ FCmp cond a b []

icmp :: IP.IntegerPredicate -> Operand -> Operand -> Codegen Operand
icmp cond a b = instr ibool $ ICmp cond a b []

trunc :: Type -> Operand -> Codegen Operand
trunc ty a = instr ty $ Trunc a ty []

cons :: C.Constant -> Operand
cons = ConstantOperand

nowrap :: Bool
nowrap = False

add :: Operand -> Operand -> Codegen Operand
add a b = instr int $ Add nowrap nowrap a b []

mul :: Operand -> Operand -> Codegen Operand
mul a b = instr int $ Mul nowrap nowrap a b []

sub :: Operand -> Operand -> Codegen Operand
sub a b = instr int $ Sub nowrap nowrap a b []

uitofp :: Type -> Operand -> Codegen Operand
uitofp ty a = instr float $ UIToFP a ty []

toArgs :: [Operand] -> [(Operand, [A.ParameterAttribute])]
toArgs = map (\x -> (x, []))

bitcast :: Type -> Operand -> Codegen Operand
bitcast ty a = instr ty $ BitCast a ty []

ptrtoint :: Type -> Operand -> Codegen Operand
ptrtoint ty a = instr ty $ PtrToInt a ty []

-- | Calculate the byte size of a type
--
-- uses a pointer arithmetic trick:
--
-- getting the pointer to the second element of an array
-- starting at address zero is identical to getting an element's size.
sizeof :: Type -> Codegen Operand
sizeof ty = do
  sizeP <- getElementPtr (ptr ty) (nullP (ptr ty)) [one]
  ptrtoint int sizeP

-- Effects

-- | call according to C calling convention
ccall :: Type -> Operand -> [Operand] -> Codegen Operand
ccall ty fun arglist = instr ty $ Call Nothing CC.C [] (Right fun) (toArgs arglist) [] []

-- | call according to fast calling convention
--
-- needs to match calling convention in function definition
call :: Type -> Operand -> [Operand] -> Codegen Operand
call ty fun arglist = instr ty $ Call Nothing CC.Fast [] (Right fun) (toArgs arglist) [] []

-- | allocate space on the stack
alloca :: Type -> Codegen Operand
alloca ty = instr ty $ Alloca ty Nothing 0 []

-- | allocate space on the heap
malloc :: Type -> Codegen (Operand, Operand)
malloc ty = do
  size <- sizeof ty
  anyP <- ccall anyPtr (cons $ global (ptr $ fn anyPtr [i32]) "malloc") [size]
  valP <- bitcast (ptr ty) anyP
  pure (anyP, valP)

store :: Operand -> Operand -> Codegen ()
store dst val = instr_ $ Store False dst val Nothing 0 []

load :: Type -> Operand -> Codegen Operand
load ty pointer = instr ty $ Load False pointer Nothing 0 []

-- | pointer arithmetic
--
-- first index is like an array index:
--   @int*@ could refer to an array of integers
-- further indices index into structure elements
getElementPtr :: Type -> Operand -> [Operand] -> Codegen Operand
getElementPtr ty addr ix = instr ty $ GetElementPtr False addr ix []

-- | get the environment pointer (with correct type) out of a closure
getClosureEnvPtr :: AST.Name -> [Type] -> Codegen Operand
getClosureEnvPtr envName elemty = do
  let envPtr = local anyPtr envName
  bitcast (ptr $ closureEnv elemty) envPtr

extractValue :: Type -> Operand -> [Word32] -> Codegen Operand
extractValue ty struct ix = instr ty $ ExtractValue struct ix []

insertValue :: Type -> Operand -> Operand -> [Word32] -> Codegen Operand
insertValue ty struct val ix = instr ty $ InsertValue struct val ix []

buildStruct :: Type -> [Operand] -> Codegen Operand
buildStruct ty elems = foldM insert (undef ty) (zip [0..] elems)
  where
    insert struct (i, val) = insertValue ty struct val [i]

-- Control Flow
br :: Name -> Codegen (Named Terminator)
br val = terminator $ Do $ Br val []

cbr :: Operand -> Name -> Name -> Codegen (Named Terminator)
cbr cond tr fl = terminator $ Do $ CondBr cond tr fl []

phi :: Type -> [(Operand, Name)] -> Codegen Operand
phi ty incoming = instr ty $ Phi ty incoming []

ret :: Operand -> Codegen (Named Terminator)
ret val = terminator $ Do $ Ret (Just val) []

retvoid :: Codegen (Named Terminator)
retvoid = terminator $ Do $ Ret Nothing []
