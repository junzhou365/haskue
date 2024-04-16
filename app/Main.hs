module Main where

import AST (exprBld)
import Control.Monad.Except (MonadError, runExceptT, throwError)
import Data.ByteString.Builder (hPutBuilder)
import Eval (runIO)
import Parser (parseCUE)
import Path (emptyPath)
import System.Environment (getArgs)
import System.IO (readFile, stdout)
import Transform (transform)
import Value (Value (Int, String), exprIO)

main :: IO ()
main = do
  args <- getArgs
  f <- readFile (head args)
  x <- runExceptT $ runIO f >>= exprIO
  case x of
    Left err -> putStrLn err
    Right expr -> hPutBuilder stdout (exprBld expr)
