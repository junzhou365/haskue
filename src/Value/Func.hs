{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Value.Func where

import qualified AST
import Control.Monad.Except (throwError)
import Control.Monad.Reader (MonadReader, ask, runReaderT)
import Path
import Value.Class
import Value.Env
import Value.TMonad

data Func t = Func
  { fncName :: String
  , fncType :: FuncType
  , -- Args stores the arguments that may or may not need to be evaluated.
    fncArgs :: [t]
  , fncExprGen :: forall m c. (Env m) => m AST.Expression
  , -- Note that the return value of the function should be stored in the tree.
    fncFunc :: forall s m. (TMonad s m t) => [t] -> m Bool
  , -- fncTempRes stores the temporary non-atom, non-function (isTreeValue true) result of the function.
    -- It is only used for showing purpose. It is not used for evaluation.
    fncTempRes :: Maybe t
  }

data FuncType = RegularFunc | DisjFunc | RefFunc | IndexFunc
  deriving (Eq, Show)

instance (Eq t) => Eq (Func t) where
  (==) f1 f2 =
    fncName f1 == fncName f2
      && fncType f1 == fncType f2
      && fncArgs f1 == fncArgs f2
      && fncTempRes f1 == fncTempRes f2

instance (BuildASTExpr t) => BuildASTExpr (Func t) where
  buildASTExpr c fn = do
    if c || requireFuncConcrete fn
      -- If the expression must be concrete, but due to incomplete evaluation, we need to use original expression.
      then fncExprGen fn
      else maybe (fncExprGen fn) (buildASTExpr c) (fncTempRes fn)

isFuncRef :: Func t -> Bool
isFuncRef fn = fncType fn == RefFunc

isFuncIndex :: Func t -> Bool
isFuncIndex fn = fncType fn == IndexFunc

requireFuncConcrete :: Func t -> Bool
requireFuncConcrete fn = case fncType fn of
  RegularFunc -> fncName fn `elem` map show [AST.Add, AST.Sub, AST.Mul, AST.Div]
  _ -> False

mkStubFunc :: c -> (forall s m. (TMonad s m t, MonadReader c m) => [t] -> m Bool) -> Func t
mkStubFunc cfg f =
  Func
    { fncName = ""
    , fncType = RegularFunc
    , fncArgs = []
    , fncExprGen = return $ AST.litCons AST.BottomLit
    , fncFunc = \ts -> runReaderT (f ts) cfg
    , fncTempRes = Nothing
    }

mkUnaryOp ::
  forall c t.
  (BuildASTExpr t) =>
  AST.UnaryOp ->
  c ->
  (forall s m. (TMonad s m t, MonadReader c m) => t -> m Bool) ->
  t ->
  Func t
mkUnaryOp op cfg f n =
  Func
    { fncFunc = g
    , fncType = RegularFunc
    , fncExprGen = gen
    , fncName = show op
    , fncArgs = [n]
    , fncTempRes = Nothing
    }
 where
  g :: (TMonad s m t) => [t] -> m Bool
  g [x] = runReaderT (f x) cfg
  g _ = throwError "invalid number of arguments for unary function"

  gen :: (Env m) => m AST.Expression
  gen = buildUnaryExpr n

  buildUnaryExpr :: (Env m) => t -> m AST.Expression
  buildUnaryExpr t = do
    let c = show op `elem` map show [AST.Add, AST.Sub, AST.Mul, AST.Div]
    te <- buildASTExpr c t
    case te of
      (AST.ExprUnaryExpr ue) -> return $ AST.ExprUnaryExpr $ AST.UnaryExprUnaryOp op ue
      e ->
        return $
          AST.ExprUnaryExpr $
            AST.UnaryExprUnaryOp
              op
              (AST.UnaryExprPrimaryExpr . AST.PrimExprOperand $ AST.OpExpression e)

mkBinaryOp ::
  forall c t.
  (BuildASTExpr t) =>
  AST.BinaryOp ->
  c ->
  (forall s m. (TMonad s m t, MonadReader c m) => t -> t -> m Bool) ->
  t ->
  t ->
  Func t
mkBinaryOp op cfg f l r =
  Func
    { fncFunc = g
    , fncType = case op of
        AST.Disjunction -> DisjFunc
        _ -> RegularFunc
    , fncExprGen = gen
    , fncName = show op
    , fncArgs = [l, r]
    , fncTempRes = Nothing
    }
 where
  g :: (TMonad s m t) => [t] -> m Bool
  g [x, y] = runReaderT (f x y) cfg
  g _ = throwError "invalid number of arguments for binary function"

  gen :: (Env e) => e AST.Expression
  gen = do
    let c = show op `elem` map show [AST.Add, AST.Sub, AST.Mul, AST.Div]
    xe <- buildASTExpr c l
    ye <- buildASTExpr c r
    return $ AST.ExprBinaryOp op xe ye

mkBinaryOpDir ::
  forall c t.
  (BuildASTExpr t) =>
  AST.BinaryOp ->
  c ->
  (forall s m. (TMonad s m t, MonadReader c m) => t -> t -> m Bool) ->
  (BinOpDirect, t) ->
  (BinOpDirect, t) ->
  Func t
mkBinaryOpDir rep op cfg (d1, t1) (_, t2) =
  case d1 of
    L -> mkBinaryOp rep op cfg t1 t2
    R -> mkBinaryOp rep op cfg t2 t1
