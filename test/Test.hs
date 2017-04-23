import Protolude

import Test.Hspec

import qualified Simply.Surface.AST as Simply
import qualified Simply.Surface.TypeCheck as Simply
import qualified Simply.Intermediate.FromSurface as Intermediate
import qualified Simply.LLVM.FromIntermediate as LLVM
import qualified Simply.LLVM.JIT as JIT

import qualified Simply.Examples as Example


withProgram :: Simply.Program -> (([Int32] -> IO Int32) -> IO a) -> IO a
withProgram = JIT.withExec . LLVM.fromIntermediate . Intermediate.fromSurface

run0 :: Simply.Program -> IO Int32
run0 prog = withProgram prog apply0
  where apply0 f = f []

run1 :: Simply.Program -> [Int32] -> IO [Int32]
run1 prog args = withProgram prog $ for args . apply1
  where apply1 f x = f [x]


verifyProgram :: Simply.Program -> IO (Either JIT.VerifyException ())
verifyProgram = JIT.verifyModule . LLVM.fromIntermediate . Intermediate.fromSurface


factorial :: Integral a => a -> a
factorial = go 1
  where
    go acc 0 = acc
    go acc n = go (acc * n) (n - 1)


main :: IO ()
main = hspec $ do

  describe "Example.ex01a_factorial" $ do
    let prog = Example.ex01a_factorial
    it "type-checks" $ do
      Simply.checkProgram prog `shouldBe` Right ()
    it "verifies" $ do
      verifyProgram prog `shouldReturn` Right ()
    it "compiles and runs" $ do
      run0 prog `shouldReturn` factorial 5

  describe "Example.ex01b_factorial" $ do
    let prog = Example.ex01b_factorial
    it "type-checks" $ do
      Simply.checkProgram prog `shouldBe` Right ()
    it "verifies" $ do
      verifyProgram prog `shouldReturn` Right ()
    it "compiles and runs" $ do
      prog `run1` [0..7] `shouldReturn` map factorial [0..7]

  describe "Example.ex01c_factorial" $ do
    let prog = Example.ex01c_factorial
    it "type-checks" $ do
      Simply.checkProgram prog `shouldBe` Right ()
    it "verifies" $ do
      verifyProgram prog `shouldReturn` Right ()
    it "compiles and runs" $ do
      run0 prog `shouldReturn` factorial 5

  describe "Example.ex01d_factorial" $ do
    let prog = Example.ex01d_factorial
    it "type-checks" $ do
      Simply.checkProgram prog `shouldBe` Right ()
    it "verifies" $ do
      verifyProgram prog `shouldReturn` Right ()
    it "compiles and runs" $ do
      prog `run1` [0..7] `shouldReturn` map factorial [0..7]

  describe "Example.ex02a_higher_order" $ do
    let prog = Example.ex02a_higher_order
    it "type-checks" $ do
      Simply.checkProgram prog `shouldBe` Right ()
    it "verifies" $ do
      verifyProgram prog `shouldReturn` Right ()
    it "compiles and runs" $ do
      run0 prog `shouldReturn` 7

  describe "Example.ex02b_higher_order" $ do
    let prog = Example.ex02b_higher_order
    it "type-checks" $ do
      Simply.checkProgram prog `shouldBe` Right ()
    it "verifies" $ do
      verifyProgram prog `shouldReturn` Right ()
    it "compiles and runs" $ do
      prog `run1` [0..7] `shouldReturn` map (+3) [0..7]

  describe "Example.ex03_factorial_fix" $ do
    let prog = Example.ex03_factorial_fix
    it "type-checks" $ do
      Simply.checkProgram prog `shouldBe` Right ()
    it "verifies" $ do
      verifyProgram prog `shouldReturn` Right ()
    it "compiles and runs" $ do
      prog `run1` [0..7] `shouldReturn` map factorial [0..7]
