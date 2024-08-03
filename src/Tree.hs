{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Tree (
  Atom (..),
  BdNumCmp (..),
  BdNumCmpOp (..),
  BdStrMatch (..),
  BdType (..),
  Bound (..),
  Config (..),
  EvalEnv,
  EvalEnvState,
  EvalMonad,
  FuncType (..),
  Number (..),
  TNAtom (..),
  TNBounds (..),
  TNConstraint (..),
  TNDisj (..),
  TNFunc (..),
  TNLink (..),
  TNList (..),
  TNScope (..),
  TNBottom (..),
  Tree (..),
  TreeNode (..),
  LabelAttr (..),
  ScopeLabelType (..),
  StaticScopeField (..),
  DynamicScopeField (..),
  ScopeFieldAdder (..),
  TreeCursor (..),
  EvalState (..),
  aToLiteral,
  bdRep,
  buildASTExpr,
  defaultLabelAttr,
  dump,
  emptyTNScope,
  evalTC,
  getScalarValue,
  goDownTCPath,
  goDownTCSel,
  goDownTCSelErr,
  goUpTC,
  indexBySel,
  indexByTree,
  insertUnifyScope,
  isTreeBottom,
  isValueAtom,
  isValueConcrete,
  isValueNode,
  mergeAttrs,
  mkBinaryOp,
  mkBinaryOpDir,
  mkBottom,
  mkBounds,
  mkList,
  mkNewTree,
  mkScope,
  mkSubTC,
  mkTNConstraint,
  mkTNFunc,
  mkTreeAtom,
  mkTreeDisj,
  mkUnaryOp,
  newEvalEnvMaybe,
  pathFromTC,
  propUpTCSel,
  runEnvMaybe,
  searchTCVar,
  setOrigNodesTC,
  setTCFocus,
  showTreeCursor,
  substLinkTC,
  substTreeNode,
  updateTNConstraintAtom,
  updateTNConstraintCnstr,
  emptyEvalState,
)
where

import qualified AST
import Control.Monad (foldM)
import Control.Monad.Except (MonadError, throwError)
import Control.Monad.Logger (
  MonadLogger,
  logDebugN,
 )
import Control.Monad.Reader (MonadReader)
import Control.Monad.State.Strict (MonadState)
import Control.Monad.Trans.Class (MonadTrans, lift)
import Data.ByteString.Builder (
  Builder,
  char7,
  integerDec,
  string7,
  toLazyByteString,
 )
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.List (intercalate, (!?))
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust, isJust, isNothing)
import Data.Text (empty, pack)
import Debug.Trace
import Path
import Text.Printf (printf)

dump :: (MonadLogger m) => String -> m ()
dump = logDebugN . pack

type EvalEnvState s m = (MonadError String m, MonadLogger m, MonadReader Config m, MonadState s m)

type EvalEnv m = EvalEnvState EvalState m

data EvalState = EvalState
  { esNotifierMap :: Map.Map Path Path
  }

emptyEvalState :: EvalState
emptyEvalState =
  EvalState
    { esNotifierMap = Map.empty
    }

data Config = Config
  { cfUnify :: forall m. (EvalEnv m) => Tree -> Tree -> TreeCursor -> m TreeCursor
  , cfCreateCnstr :: Bool
  }

type EvalMonad a = forall m. (EvalEnv m) => m a

newtype EnvMaybe m a = EnvMaybe {runEnvMaybe :: m (Maybe a)}

instance (Monad m) => Functor (EnvMaybe m) where
  fmap f (EnvMaybe ma) = EnvMaybe $ do
    a <- ma
    return $ fmap f a

instance (Monad m) => Applicative (EnvMaybe m) where
  pure = EnvMaybe . return . Just
  (EnvMaybe mf) <*> (EnvMaybe ma) = EnvMaybe $ do
    f <- mf
    a <- ma
    return $ f <*> a

instance (Monad m) => Monad (EnvMaybe m) where
  return = pure
  (>>=) :: EnvMaybe m a -> (a -> EnvMaybe m b) -> EnvMaybe m b
  (EnvMaybe ma) >>= f = EnvMaybe $ do
    am <- ma
    case am of
      Nothing -> return Nothing
      Just a -> runEnvMaybe $ f a

instance MonadTrans EnvMaybe where
  lift :: (Monad m) => m a -> EnvMaybe m a
  lift = EnvMaybe . fmap Just

newEvalEnvMaybe :: (EvalEnv m) => Maybe a -> EnvMaybe m a
newEvalEnvMaybe = EnvMaybe . return

data Atom
  = String String
  | Int Integer
  | Float Double
  | Bool Bool
  | Null
  deriving (Ord)

-- | Show is only used for debugging.
instance Show Atom where
  show (String s) = s
  show (Int i) = show i
  show (Float f) = show f
  show (Bool b) = show b
  show Null = "null"

instance Eq Atom where
  (==) (String s1) (String s2) = s1 == s2
  (==) (Int i1) (Int i2) = i1 == i2
  (==) (Int i1) (Float i2) = fromIntegral i1 == i2
  (==) (Float i1) (Int i2) = i1 == fromIntegral i2
  (==) (Float f1) (Float f2) = f1 == f2
  (==) (Bool b1) (Bool b2) = b1 == b2
  (==) Null Null = True
  (==) _ _ = False

instance BuildASTExpr Atom where
  buildASTExpr = AST.litCons . aToLiteral

aToLiteral :: Atom -> AST.Literal
aToLiteral a = case a of
  String s -> AST.StringLit $ AST.SimpleStringLit (show AST.DoubleQuote ++ s ++ show AST.DoubleQuote)
  Int i -> AST.IntLit i
  Float f -> AST.FloatLit f
  Bool b -> AST.BoolLit b
  Null -> AST.NullLit

class ValueNode a where
  isValueNode :: a -> Bool
  isValueAtom :: a -> Bool
  isValueConcrete :: a -> Bool
  getScalarValue :: a -> Maybe Atom

class BuildASTExpr a where
  buildASTExpr :: a -> AST.Expression

class TreeRepBuilder a where
  repTree :: Int -> a -> Builder

data Tree = Tree
  { treeNode :: TreeNode
  , treeOrig :: Maybe Tree
  }

setTreeNode :: TreeNode -> Tree -> Tree
setTreeNode n t = t{treeNode = n}

modifyTreeNode :: (TreeNode -> TreeNode) -> Tree -> Tree
modifyTreeNode f t = t{treeNode = f (treeNode t)}

instance Eq Tree where
  (==) t1 t2 = treeNode t1 == treeNode t2

instance TreeRepBuilder Tree where
  repTree = tnStrBldr

tnStrBldr :: Int -> Tree -> Builder
tnStrBldr i t = case treeNode t of
  TNAtom leaf -> content t i (string7 (show $ trAmAtom leaf)) emptyTreeFields
  TNLink _ -> content t i mempty emptyTreeFields
  TNScope s ->
    let ordLabels =
          string7 "ord:"
            <> char7 '['
            <> string7 (intercalate ", " (map show $ trsOrdLabels s))
            <> char7 ']'
        attr :: LabelAttr -> Builder
        attr a = case lbAttrType a of
          SLRegular -> mempty
          SLRequired -> string7 "!"
          SLOptional -> string7 "?"
        isVar :: LabelAttr -> Builder
        isVar a =
          if lbAttrIsVar a
            then string7 ",v"
            else mempty
        slabel :: ScopeSelector -> Builder
        slabel k =
          let sf = trsSubs s Map.! k
           in string7 (show k)
                <> attr (ssfAttr sf)
                <> isVar (ssfAttr sf)
        dlabel :: Int -> Builder
        dlabel j =
          let sf = trsDynSubs s !! j
           in string7 (show j)
                <> attr (dsfAttr sf)
                <> isVar (dsfAttr sf)
                <> string7 ",e"
        fields =
          map (\k -> (slabel k, ssfField $ trsSubs s Map.! k)) (scopeStaticLabels s)
            ++ map
              (\j -> (dlabel j, dsfField $ trsDynSubs s !! j))
              (scopeDynIndexes s)
     in content t i ordLabels fields
  TNList vs ->
    let fields = map (\(j, v) -> (integerDec j, v)) (zip [0 ..] (trLstSubs vs))
     in content t i mempty fields
  TNDisj d ->
    let dfField = maybe [] (\v -> [(string7 (show $ DisjDefaultSelector), v)]) (trdDefault d)
        djFields = map (\(j, v) -> (string7 (show $ DisjDisjunctSelector j), v)) (zip [0 ..] (trdDisjuncts d))
     in content t i mempty (dfField ++ djFields)
  TNConstraint c ->
    content
      t
      i
      mempty
      [ (string7 "Atom", mkNewTree (TNAtom $ trCnAtom c))
      , (string7 "Cond", trCnCnstr c)
      ]
  TNBounds b -> content t i mempty (map (\(j, v) -> (integerDec j, v)) (zip [0 ..] (trBdList b)))
  TNRefCycleVar -> content t i mempty emptyTreeFields
  TNFunc f ->
    let args = map (\(j, v) -> (integerDec j, v)) (zip [0 ..] (trfnArgs f))
     in content t i (string7 $ trfnName f) args
  TNBottom b -> content t i (string7 $ show b) emptyTreeFields
  TNTop -> content t i mempty emptyTreeFields
 where
  emptyTreeFields :: [(Builder, Tree)]
  emptyTreeFields = []

  content :: (TreeRepBuilder a) => Tree -> Int -> Builder -> [(Builder, a)] -> Builder
  content tree j meta fields =
    char7 '('
      <> string7 (showTreeSymbol tree)
      <> char7 ' '
      <> string7 "O:"
      <> (if isNothing (treeOrig tree) then string7 "N" else string7 "J")
      <> (char7 ' ' <> meta)
      <> if null fields
        then char7 ')'
        else
          char7 '\n'
            <> foldl
              ( \b (label, sub) ->
                  b
                    <> string7 (replicate (j + 1) ' ')
                    <> char7 '('
                    <> label
                    <> char7 ' '
                    <> repTree (j + 2) sub
                    <> char7 ')'
                    <> char7 '\n'
              )
              mempty
              fields
            <> string7 (replicate j ' ')
            <> char7 ')'

showTreeIdent :: Tree -> Int -> String
showTreeIdent t i = LBS.unpack $ toLazyByteString $ tnStrBldr i t

showTreeType :: Tree -> String
showTreeType t = case treeNode t of
  TNAtom _ -> "Leaf"
  TNBounds _ -> "Bounds"
  TNScope{} -> "Scope"
  TNList{} -> "List"
  TNLink{} -> "Link"
  TNDisj{} -> "Disj"
  TNConstraint{} -> "Cnstr"
  TNRefCycleVar -> "RefCycleVar"
  TNFunc{} -> "Func"
  TNBottom _ -> "Bottom"
  TNTop -> "Top"

showTreeSymbol :: Tree -> String
showTreeSymbol t = case treeNode t of
  TNAtom _ -> "v"
  TNBounds _ -> "b"
  TNScope{} -> "{}"
  TNList{} -> "[]"
  TNLink l -> printf "-> %s" (show $ trlTarget l)
  TNDisj{} -> "dj"
  TNConstraint{} -> "Cnstr"
  TNRefCycleVar -> "RefCycleVar"
  TNFunc{} -> "fn"
  TNBottom _ -> "_|_"
  TNTop -> "_"

instance Show Tree where
  show tree = showTreeIdent tree 0

instance BuildASTExpr Tree where
  buildASTExpr t = case treeNode t of
    TNScope s -> buildASTExpr s
    TNList l -> buildASTExpr l
    TNDisj d -> buildASTExpr d
    TNLink l -> buildASTExpr l
    TNAtom s -> buildASTExpr s
    TNBounds b -> buildASTExpr b
    TNConstraint _ -> buildASTExpr (fromJust $ treeOrig t)
    TNRefCycleVar -> AST.litCons AST.TopLit
    TNFunc fn -> if isJust (treeOrig t) then buildASTExpr (fromJust $ treeOrig t) else buildASTExpr fn
    TNBottom _ -> AST.litCons AST.BottomLit
    TNTop -> AST.litCons AST.TopLit

mkNewTree :: TreeNode -> Tree
mkNewTree n = Tree n Nothing

substTreeNode :: TreeNode -> Tree -> Tree
substTreeNode n t = t{treeNode = n}

-- | Tree represents a tree structure that contains values.
data TreeNode
  = -- | TNScope is a struct that contains a value and a map of selectors to Tree.
    TNScope TNScope
  | TNList TNList
  | TNDisj TNDisj
  | -- | Unless the target is a scalar, the TNLink should not be pruned.
    TNLink TNLink
  | -- | TNAtom contains an atom value.
    TNAtom TNAtom
  | TNBounds TNBounds
  | TNConstraint TNConstraint
  | TNRefCycleVar
  | TNFunc TNFunc
  | TNTop
  | TNBottom TNBottom

instance Eq TreeNode where
  (==) (TNScope s1) (TNScope s2) = s1 == s2
  (==) (TNList ts1) (TNList ts2) = ts1 == ts2
  (==) (TNDisj d1) (TNDisj d2) = d1 == d2
  (==) (TNLink l1) (TNLink l2) = l1 == l2
  (==) (TNAtom l1) (TNAtom l2) = l1 == l2
  (==) (TNConstraint c1) (TNConstraint c2) = c1 == c2
  (==) TNRefCycleVar TNRefCycleVar = True
  (==) (TNDisj dj1) n2@(TNAtom _) =
    if isNothing (trdDefault dj1)
      then False
      else treeNode (fromJust $ trdDefault dj1) == n2
  (==) (TNAtom a1) (TNDisj dj2) = (==) (TNDisj dj2) (TNAtom a1)
  (==) (TNFunc f1) (TNFunc f2) = f1 == f2
  (==) (TNBounds b1) (TNBounds b2) = b1 == b2
  (==) (TNBottom _) (TNBottom _) = True
  (==) TNTop TNTop = True
  (==) _ _ = False

instance ValueNode TreeNode where
  isValueNode n = case n of
    TNAtom _ -> True
    TNBounds _ -> True
    TNScope _ -> True
    TNList _ -> True
    TNDisj _ -> True
    TNConstraint _ -> True
    TNRefCycleVar -> False
    TNLink _ -> False
    TNFunc _ -> False
    TNBottom _ -> True
    TNTop -> True
  isValueAtom n = case n of
    TNAtom _ -> True
    _ -> False
  isValueConcrete n = case n of
    TNScope scope -> isScopeConcrete scope
    _ -> isValueAtom n
  getScalarValue n = case n of
    TNAtom s -> Just (trAmAtom s)
    TNConstraint c -> Just (trAmAtom $ trCnAtom c)
    _ -> Nothing

newtype TNList = TreeList
  { trLstSubs :: [Tree]
  }

instance Eq TNList where
  (==) l1 l2 = trLstSubs l1 == trLstSubs l2

instance BuildASTExpr TNList where
  buildASTExpr l =
    AST.litCons . AST.ListLit . AST.EmbeddingList $ map buildASTExpr (trLstSubs l)

mkList :: [Tree] -> Tree
mkList ts = mkNewTree (TNList $ TreeList{trLstSubs = ts})

data LabelAttr = LabelAttr
  { lbAttrType :: ScopeLabelType
  , lbAttrIsVar :: Bool
  }
  deriving (Show, Eq)

defaultLabelAttr :: LabelAttr
defaultLabelAttr = LabelAttr SLRegular True

mergeAttrs :: LabelAttr -> LabelAttr -> LabelAttr
mergeAttrs a1 a2 =
  LabelAttr
    { lbAttrType = min (lbAttrType a1) (lbAttrType a2)
    , lbAttrIsVar = lbAttrIsVar a1 || lbAttrIsVar a2
    }

data ScopeLabelType = SLRegular | SLRequired | SLOptional
  deriving (Eq, Ord, Enum, Show)

data StaticScopeField = StaticScopeField
  { ssfField :: Tree
  , ssfAttr :: LabelAttr
  }
  deriving (Show)

instance Eq StaticScopeField where
  (==) f1 f2 = ssfField f1 == ssfField f2 && ssfAttr f1 == ssfAttr f2

data DynamicScopeField = DynamicScopeField
  { dsfField :: Tree
  , dsfAttr :: LabelAttr
  , dsfSelExpr :: AST.Expression
  , dsfSelTree :: Tree
  }
  deriving (Show)

instance Eq DynamicScopeField where
  (==) f1 f2 = dsfField f1 == dsfField f2 && dsfAttr f1 == dsfAttr f2 && dsfSelExpr f1 == dsfSelExpr f2

data TNScope = TreeScope
  { trsOrdLabels :: [ScopeSelector] -- Should only contain string labels.
  , trsSubs :: Map.Map ScopeSelector StaticScopeField
  , trsDynSubs :: [DynamicScopeField]
  }

instance Eq TNScope where
  (==) s1 s2 =
    trsOrdLabels s1 == trsOrdLabels s2
      && trsSubs s1 == trsSubs s2
      && trsDynSubs s1 == trsDynSubs s2

instance BuildASTExpr TNScope where
  buildASTExpr s =
    let
      processStaticField :: (ScopeSelector, StaticScopeField) -> AST.Declaration
      processStaticField (label, sf) = case label of
        StringSelector sel ->
          AST.FieldDecl $
            AST.Field
              [ labelCons (ssfAttr sf) $
                  if lbAttrIsVar (ssfAttr sf)
                    then AST.LabelID sel
                    else AST.LabelString sel
              ]
              (buildASTExpr (ssfField sf))
        DynamicSelector _ -> error "impossible"

      processDynField :: DynamicScopeField -> AST.Declaration
      processDynField sf =
        AST.FieldDecl $
          AST.Field
            [ labelCons (dsfAttr sf) $ AST.LabelNameExpr (dsfSelExpr sf)
            ]
            (buildASTExpr (dsfField sf))

      labelCons :: LabelAttr -> AST.LabelName -> AST.Label
      labelCons attr =
        AST.Label . case lbAttrType attr of
          SLRegular -> AST.RegularLabel
          SLRequired -> AST.RequiredLabel
          SLOptional -> AST.OptionalLabel
     in
      AST.litCons $
        AST.StructLit $
          [processStaticField (l, trsSubs s Map.! l) | l <- scopeStaticLabels s]
            ++ [processDynField sf | sf <- trsDynSubs s]

emptyTNScope :: TNScope
emptyTNScope = TreeScope{trsOrdLabels = [], trsSubs = Map.empty, trsDynSubs = []}

data ScopeFieldAdder = Static ScopeSelector StaticScopeField | Dynamic DynamicScopeField
  deriving (Show)

mkScope :: [ScopeFieldAdder] -> Tree
mkScope as =
  mkNewTree . TNScope $
    TreeScope
      { trsOrdLabels = ordLabels
      , trsSubs = Map.fromList statics
      , trsDynSubs = dynamics
      }
 where
  ordLabels = [l | Static l _ <- as]
  statics = [(s, sf) | Static s sf <- as]
  dynamics = [df | Dynamic df <- as]

-- Insert a new field into the scope. If the field is already in the scope, then unify the field with the new field.
insertUnifyScope :: ScopeFieldAdder -> (Tree -> Tree -> TreeCursor -> EvalMonad TreeCursor) -> TNScope -> TNScope
insertUnifyScope (Static sel sf) unify scope = case subs Map.!? sel of
  Just extSF ->
    let
      unifySFOp =
        StaticScopeField
          { ssfField = mkNewTree (TNFunc $ mkBinaryOp AST.Unify unify (ssfField extSF) (ssfField sf))
          , ssfAttr = mergeAttrs (ssfAttr extSF) (ssfAttr sf)
          }
     in
      scope{trsSubs = Map.insert sel unifySFOp subs}
  Nothing ->
    scope
      { trsOrdLabels = trsOrdLabels scope ++ [sel]
      , trsSubs = Map.insert sel sf subs
      }
 where
  subs = trsSubs scope
insertUnifyScope (Dynamic sf) _ scope = scope{trsDynSubs = trsDynSubs scope ++ [sf]}

scopeStaticLabels :: TNScope -> [ScopeSelector]
scopeStaticLabels = filter (\x -> viewScopeSelector x == 0) . trsOrdLabels

scopeDynIndexes :: TNScope -> [Int]
scopeDynIndexes s = [0 .. length (trsDynSubs s) - 1]

isScopeConcrete :: TNScope -> Bool
isScopeConcrete s =
  foldl
    ( \acc
       (StaticScopeField{ssfField = Tree{treeNode = x}}) -> acc && isValueConcrete x
    )
    True
    (Map.elems (trsSubs s))

data TNLink = TreeLink
  { trlTarget :: Path
  , trlExpr :: AST.UnaryExpr
  }

instance Eq TNLink where
  (==) l1 l2 = trlTarget l1 == trlTarget l2

instance BuildASTExpr TNLink where
  buildASTExpr l = AST.ExprUnaryExpr $ trlExpr l

{- | Substitute the link node with the referenced node.
link should be the node that is currently being evaluated.
1. Find the target TC in the original tree.
2. Define the scope, which is the path of the target node.
3. Evaluate links that are outside the scope.
-}
substLinkTC :: (EvalEnv m) => TNLink -> TreeCursor -> m TreeCursor
substLinkTC link tc = do
  dump $ printf "substLinkTC: link (%s), path: %s starts" (show $ trlTarget link) (show $ pathFromTC tc)
  dump $ printf "substLinkTC, tc:\n%s" (showTreeCursor tc)
  res <- runEnvMaybe $ do
    tarTC <- EnvMaybe (followLink link tc)
    lift $
      dump $
        printf
          "substLinkTC: link (%s) target is found in the eval tree, tree: %s"
          (show $ trlTarget link)
          (show (tcFocus tarTC))
    case treeNode (tcFocus tarTC) of
      -- The link leads to a cycle head, which does not have the original node.
      TNRefCycleVar -> return tarTC
      _ -> do
        origTarTree <- newEvalEnvMaybe $ treeOrig (tcFocus tarTC)
        return (TreeCursor origTarTree (tcCrumbs tarTC))
  case res of
    Nothing -> do
      dump $ printf "substLinkTC: original target of the link (%s) is not found" (show $ trlTarget link)
      return tc
    Just tarOTC -> do
      dump $
        printf
          "substLinkTC: link (%s) target is found, path: %s, tree node:\n%s"
          (show $ trlTarget link)
          (show $ pathFromTC tarOTC)
          (show $ tcFocus tarOTC)
      substTC <- evalOutScopeLinkTC (pathFromTC tarOTC) tarOTC
      dump $ printf "substLinkTC: link (%s) target is evaluated to:\n%s" (show $ trlTarget link) (show $ tcFocus substTC)
      return substTC
 where
  -- substitute out-scope links with evaluated nodes.
  evalOutScopeLinkTC :: (EvalEnv m) => Path -> TreeCursor -> m TreeCursor
  evalOutScopeLinkTC p = traverseTC $ \x -> case treeNode (tcFocus x) of
    -- Use the first var to determine if the link is in the scope. Then search the whole path.
    -- This handles the x.a case correctly.
    TNLink l -> do
      varPathMaybe <- runEnvMaybe $ do
        fstSel <- newEvalEnvMaybe $ headSel p
        -- If the variable is outside of the scope, then no matter what the following selectors are, the link is
        -- outside of the scope.
        varTC <- EnvMaybe $ searchTCVar fstSel x
        _ <- EnvMaybe $ searchTCPath (trlTarget l) x
        return $ pathFromTC varTC

      case varPathMaybe of
        Nothing -> return x
        Just varPath ->
          -- If the first selector of the link references the scope or nodes outside the scope, then evaluate the
          -- link.
          if p == varPath || not (isPrefix p varPath)
            then evalTC x
            else return x
    _ -> return x

newtype TNAtom = TreeAtom
  { trAmAtom :: Atom
  }

instance Show TNAtom where
  show (TreeAtom v) = show v

instance Eq TNAtom where
  (==) (TreeAtom v1) (TreeAtom v2) = v1 == v2

instance BuildASTExpr TNAtom where
  buildASTExpr (TreeAtom v) = buildASTExpr v

mkTreeAtom :: Atom -> Tree
mkTreeAtom v = mkNewTree (TNAtom $ TreeAtom{trAmAtom = v})

isTreeBottom :: Tree -> Bool
isTreeBottom (Tree (TNBottom _) _) = True
isTreeBottom _ = False

data TNDisj = TreeDisj
  { trdDefault :: Maybe Tree
  , trdDisjuncts :: [Tree]
  }

instance Eq TNDisj where
  (==) (TreeDisj ds1 js1) (TreeDisj ds2 js2) = ds1 == ds2 && js1 == js2

instance BuildASTExpr TNDisj where
  buildASTExpr dj =
    if isJust (trdDefault dj)
      then buildASTExpr $ fromJust (trdDefault dj)
      else foldr1 (\x y -> AST.ExprBinaryOp AST.Disjunction x y) (map buildASTExpr (trdDisjuncts dj))

mkTreeDisj :: Maybe Tree -> [Tree] -> Tree
mkTreeDisj m js = mkNewTree (TNDisj $ TreeDisj{trdDefault = m, trdDisjuncts = js})

-- TNConstraint does not need to implement the BuildASTExpr.
data TNConstraint = TreeConstraint
  { trCnAtom :: TNAtom
  , trCnOrigAtom :: TNAtom
  -- ^ trCnOrigNode is the original atom value that was unified with other expression. Notice that the atom value can be
  -- changed by binary operations.
  , trCnCnstr :: Tree
  , trCnUnify :: forall m. (EvalEnv m) => Tree -> Tree -> TreeCursor -> m TreeCursor
  }

instance Eq TNConstraint where
  (==) (TreeConstraint a1 o1 c1 _) (TreeConstraint a2 o2 c2 _) =
    a1 == a2 && c1 == c2 && o1 == o2

mkTNConstraint :: TNAtom -> Tree -> (Tree -> Tree -> TreeCursor -> EvalMonad TreeCursor) -> TNConstraint
mkTNConstraint atom cnstr unify =
  TreeConstraint
    { trCnAtom = atom
    , trCnOrigAtom = atom
    , trCnCnstr = cnstr
    , trCnUnify = unify
    }

updateTNConstraintCnstr ::
  (BinOpDirect, Tree) ->
  (Tree -> Tree -> TreeCursor -> EvalMonad TreeCursor) ->
  TNConstraint ->
  TNConstraint
updateTNConstraintCnstr (d, t) unify c =
  let newBinOp =
        if d == L
          then TNFunc $ mkBinaryOp AST.Unify unify t (trCnCnstr c)
          else TNFunc $ mkBinaryOp AST.Unify unify (trCnCnstr c) t
   in c{trCnCnstr = mkNewTree newBinOp}

updateTNConstraintAtom :: TNAtom -> TNConstraint -> TNConstraint
updateTNConstraintAtom atom c = c{trCnAtom = atom}

data Number = NumInt Integer | NumFloat Double
  deriving (Eq)

instance Ord Number where
  compare (NumInt i1) (NumInt i2) = compare i1 i2
  compare (NumFloat f1) (NumFloat f2) = compare f1 f2
  compare (NumInt i) (NumFloat f) = compare (fromIntegral i) f
  compare (NumFloat f) (NumInt i) = compare f (fromIntegral i)

data BdNumCmpOp
  = BdLT
  | BdLE
  | BdGT
  | BdGE
  deriving (Eq, Enum, Ord)

instance Show BdNumCmpOp where
  show o = show $ case o of
    BdLT -> AST.LT
    BdLE -> AST.LE
    BdGT -> AST.GT
    BdGE -> AST.GE

data BdNumCmp = BdNumCmpCons BdNumCmpOp Number
  deriving (Eq)

data BdStrMatch
  = BdReMatch String
  | BdReNotMatch String
  deriving (Eq)

data BdType
  = BdBool
  | BdInt
  | BdFloat
  | BdNumber
  | BdString
  deriving (Eq, Enum, Bounded)

instance Show BdType where
  show BdBool = "bool"
  show BdInt = "int"
  show BdFloat = "float"
  show BdNumber = "number"
  show BdString = "string"

data Bound
  = BdNE Atom
  | BdNumCmp BdNumCmp
  | BdStrMatch BdStrMatch
  | BdType BdType
  | BdIsAtom Atom -- helper type
  deriving (Eq)

instance Show Bound where
  show b = AST.exprStr $ buildASTExpr b

instance TreeRepBuilder Bound where
  repTree _ b = char7 '(' <> string7 (show b) <> char7 ')'

instance BuildASTExpr Bound where
  buildASTExpr = buildBoundASTExpr

bdRep :: Bound -> String
bdRep b = case b of
  BdNE _ -> show $ AST.NE
  BdNumCmp (BdNumCmpCons o _) -> show o
  BdStrMatch m -> case m of
    BdReMatch _ -> show AST.ReMatch
    BdReNotMatch _ -> show AST.ReNotMatch
  BdType t -> show t
  BdIsAtom _ -> "="

buildBoundASTExpr :: Bound -> AST.Expression
buildBoundASTExpr b = case b of
  BdNE a -> litOp AST.NE (aToLiteral a)
  BdNumCmp (BdNumCmpCons o n) -> case o of
    BdLT -> numOp AST.LT n
    BdLE -> numOp AST.LE n
    BdGT -> numOp AST.GT n
    BdGE -> numOp AST.GE n
  BdStrMatch m -> case m of
    BdReMatch s -> litOp AST.ReMatch (AST.StringLit $ AST.SimpleStringLit s)
    BdReNotMatch s -> litOp AST.ReNotMatch (AST.StringLit $ AST.SimpleStringLit s)
  BdType t -> AST.idCons (show t)
  BdIsAtom a -> AST.litCons (aToLiteral a)
 where
  litOp :: AST.RelOp -> AST.Literal -> AST.Expression
  litOp op l =
    AST.ExprUnaryExpr $
      AST.UnaryExprUnaryOp
        (AST.UnaRelOp op)
        (AST.UnaryExprPrimaryExpr . AST.PrimExprOperand . AST.OpLiteral $ l)

  numOp :: AST.RelOp -> Number -> AST.Expression
  numOp op n =
    AST.ExprUnaryExpr $
      AST.UnaryExprUnaryOp
        (AST.UnaRelOp op)
        ( AST.UnaryExprPrimaryExpr . AST.PrimExprOperand . AST.OpLiteral $ case n of
            NumInt i -> AST.IntLit i
            NumFloat f -> AST.FloatLit f
        )

newtype TNBounds = TreeBounds
  { trBdList :: [Bound]
  }
  deriving (Eq)

instance BuildASTExpr TNBounds where
  buildASTExpr b = foldr1 (\x y -> AST.ExprBinaryOp AST.Unify x y) (map buildASTExpr (trBdList b))

mkBounds :: [Bound] -> Tree
mkBounds bs = mkNewTree (TNBounds $ TreeBounds{trBdList = bs})

data FuncType = UnaryOpFunc | BinaryOpFunc | DisjFunc | Function
  deriving (Eq, Enum)

data TNFunc = TreeFunc
  { trfnName :: String
  , trfnType :: FuncType
  , trfnArgs :: [Tree]
  , trfnExprGen :: [Tree] -> AST.Expression
  , trfnFunc :: forall m. (EvalEnv m) => [Tree] -> TreeCursor -> m TreeCursor
  }

instance BuildASTExpr TNFunc where
  buildASTExpr fn = trfnExprGen fn (trfnArgs fn)

instance Eq TNFunc where
  (==) f1 f2 = trfnName f1 == trfnName f2 && trfnArgs f1 == trfnArgs f2 && trfnType f1 == trfnType f2

mkTNFunc ::
  String -> FuncType -> ([Tree] -> TreeCursor -> EvalMonad TreeCursor) -> ([Tree] -> AST.Expression) -> [Tree] -> TNFunc
mkTNFunc name typ f g args =
  TreeFunc
    { trfnFunc = f
    , trfnType = typ
    , trfnExprGen = g
    , trfnName = name
    , trfnArgs = args
    }

mkUnaryOp :: AST.UnaryOp -> (Tree -> TreeCursor -> EvalMonad TreeCursor) -> Tree -> TNFunc
mkUnaryOp op f n =
  TreeFunc
    { trfnFunc = g
    , trfnType = UnaryOpFunc
    , trfnExprGen = gen
    , trfnName = show op
    , trfnArgs = [n]
    }
 where
  g :: [Tree] -> TreeCursor -> EvalMonad TreeCursor
  g (x : []) = f x
  g _ = \_ -> throwError "mkTNUnaryOp: invalid number of arguments"

  gen :: [Tree] -> AST.Expression
  gen (x : []) = buildUnaryExpr x
  gen _ = AST.litCons AST.BottomLit

  buildUnaryExpr :: Tree -> AST.Expression
  buildUnaryExpr t = case buildASTExpr t of
    (AST.ExprUnaryExpr ue) -> AST.ExprUnaryExpr $ AST.UnaryExprUnaryOp op ue
    e ->
      AST.ExprUnaryExpr $
        AST.UnaryExprUnaryOp
          op
          (AST.UnaryExprPrimaryExpr . AST.PrimExprOperand $ AST.OpExpression e)

mkBinaryOp ::
  AST.BinaryOp -> (Tree -> Tree -> TreeCursor -> EvalMonad TreeCursor) -> Tree -> Tree -> TNFunc
mkBinaryOp op f l r =
  TreeFunc
    { trfnFunc = g
    , trfnType = case op of
        AST.Disjunction -> DisjFunc
        _ -> BinaryOpFunc
    , trfnExprGen = gen
    , trfnName = show op
    , trfnArgs = [l, r]
    }
 where
  g :: [Tree] -> TreeCursor -> EvalMonad TreeCursor
  g [x, y] = f x y
  g _ = \_ -> throwError "mkTNUnaryOp: invalid number of arguments"

  gen :: [Tree] -> AST.Expression
  gen [x, y] = AST.ExprBinaryOp op (buildASTExpr x) (buildASTExpr y)
  gen _ = AST.litCons AST.BottomLit

mkBinaryOpDir ::
  AST.BinaryOp ->
  (Tree -> Tree -> TreeCursor -> EvalMonad TreeCursor) ->
  (BinOpDirect, Tree) ->
  (BinOpDirect, Tree) ->
  TNFunc
mkBinaryOpDir rep op (d1, t1) (_, t2) =
  case d1 of
    L -> mkBinaryOp rep op t1 t2
    R -> mkBinaryOp rep op t2 t1

newtype TNBottom = TreeBottom
  { trBmMsg :: String
  }

instance Eq TNBottom where
  (==) _ _ = True

instance BuildASTExpr TNBottom where
  buildASTExpr _ = AST.litCons AST.BottomLit

instance Show TNBottom where
  show (TreeBottom m) = m

mkBottom :: String -> Tree
mkBottom msg = mkNewTree (TNBottom $ TreeBottom{trBmMsg = msg})

-- -- --

-- step down the tree with the given selector.
-- This should only be used by TreeCursor.
goTreeSel :: Selector -> Tree -> Maybe Tree
goTreeSel sel t =
  case sel of
    RootSelector -> Just t
    ScopeSelector s -> case node of
      TNScope scope -> case s of
        StringSelector _ -> ssfField <$> Map.lookup s (trsSubs scope)
        DynamicSelector i -> Just $ dsfField $ trsDynSubs scope !! i
      _ -> Nothing
    IndexSelector i -> case node of
      TNList vs -> trLstSubs vs !? i
      _ -> Nothing
    FuncArgSelector i -> case node of
      TNFunc fn -> trfnArgs fn !? i
      _ -> Nothing
    DisjDefaultSelector -> case node of
      TNDisj d -> trdDefault d
      _ -> Nothing
    DisjDisjunctSelector i -> case node of
      TNDisj d -> trdDisjuncts d !? i
      _ -> Nothing
    ParentSelector -> Nothing
 where
  node = treeNode t

-- | TreeCrumb is a pair of a name and an environment. The name is the name of the field in the parent environment.
type TreeCrumb = (Selector, Tree)

{- | TreeCursor is a pair of a value and a list of crumbs.
For example,
{
a: {
  b: {
    c: 42
  } // struct_c
} // struct_b
} // struct_a
Suppose the cursor is at the struct that contains the value 42. The cursor is
(struct_c, [("b", struct_b), ("a", struct_a)]).
-}
data TreeCursor = TreeCursor
  { tcFocus :: Tree
  , tcCrumbs :: [TreeCrumb]
  }
  deriving (Eq)

instance Show TreeCursor where
  show = showTreeCursor

viewTC :: TreeCursor -> TreeNode
viewTC tc = treeNode (tcFocus tc)

tcNodeSetter :: TreeCursor -> TreeNode -> TreeCursor
tcNodeSetter (TreeCursor t cs) n = TreeCursor (substTreeNode n t) cs

showTreeCursor :: TreeCursor -> String
showTreeCursor tc = LBS.unpack $ toLazyByteString $ prettyBldr tc
 where
  prettyBldr :: TreeCursor -> Builder
  prettyBldr (TreeCursor t cs) =
    string7 "-- ():\n"
      <> string7 (show t)
      <> char7 '\n'
      <> foldl
        ( \b (sel, n) ->
            b
              <> string7 "-- "
              <> string7 (show sel)
              <> char7 ':'
              <> char7 '\n'
              <> string7 (show n)
              <> char7 '\n'
        )
        mempty
        cs

setTCFocus :: Tree -> TreeCursor -> TreeCursor
setTCFocus t (TreeCursor _ cs) = (TreeCursor t cs)

modifyTCFocus :: (Tree -> Tree) -> TreeCursor -> TreeCursor
modifyTCFocus f (TreeCursor t cs) = TreeCursor (f t) cs

mkSubTC :: Selector -> Tree -> TreeCursor -> TreeCursor
mkSubTC sel node tc = TreeCursor node ((sel, tcFocus tc) : tcCrumbs tc)

-- | Go up the tree cursor and return the new cursor.
goUpTC :: TreeCursor -> Maybe TreeCursor
goUpTC (TreeCursor _ []) = Nothing
goUpTC (TreeCursor _ ((_, v) : vs)) = Just $ TreeCursor v vs

goDownTCPath :: Path -> TreeCursor -> Maybe TreeCursor
goDownTCPath (Path sels) = go (reverse sels)
 where
  go :: [Selector] -> TreeCursor -> Maybe TreeCursor
  go [] cursor = Just cursor
  go (x : xs) cursor = do
    nextCur <- goDownTCSel x cursor
    go xs nextCur

{- | Go down the TreeCursor with the given selector and return the new cursor.
It handles the case when the current node is a disjunction node.
-}
goDownTCSel :: Selector -> TreeCursor -> Maybe TreeCursor
goDownTCSel sel tc = case go sel tc of
  Just c -> Just c
  Nothing -> case treeNode (tcFocus tc) of
    TNDisj d ->
      if isJust (trdDefault d)
        then goDownTCSel DisjDefaultSelector tc >>= go sel
        else Nothing
    _ -> Nothing
 where
  go :: Selector -> TreeCursor -> Maybe TreeCursor
  go s x = do
    nextTree <- goTreeSel s (tcFocus x)
    return $ mkSubTC s nextTree x

goDownTCSelErr :: (MonadError String m) => Selector -> TreeCursor -> m TreeCursor
goDownTCSelErr sel tc = case goDownTCSel sel tc of
  Just c -> return c
  Nothing -> throwError $ printf "cannot go down tree with selector %s, tree: %s" (show sel) (show $ tcFocus tc)

pathFromTC :: TreeCursor -> Path
pathFromTC (TreeCursor _ crumbs) = Path . reverse $ go crumbs []
 where
  go :: [TreeCrumb] -> [Selector] -> [Selector]
  go [] acc = acc
  go ((n, _) : cs) acc = go cs (n : acc)

{- | propUp propagates the changes made to the tip of the block to the parent block.
The structure of the tree is not changed.
-}
propUpTC :: (EvalEnv m) => TreeCursor -> m TreeCursor
propUpTC tc@(TreeCursor _ []) = return tc
propUpTC tc@(TreeCursor subT ((sel, parT) : cs)) = case sel of
  ScopeSelector s -> updateParScope parT s subT
  IndexSelector i -> case parNode of
    TNList vs ->
      let subs = trLstSubs vs
          l = TNList $ vs{trLstSubs = take i subs ++ [subT] ++ drop (i + 1) subs}
       in return (TreeCursor (substTreeNode l parT) cs)
    _ -> throwError insertErrMsg
  FuncArgSelector i -> case parNode of
    TNFunc fn ->
      let args = trfnArgs fn
          l = TNFunc $ fn{trfnArgs = take i args ++ [subT] ++ drop (i + 1) args}
       in return (TreeCursor (substTreeNode l parT) cs)
    _ -> throwError insertErrMsg
  DisjDefaultSelector -> case parNode of
    TNDisj d ->
      return
        (TreeCursor (substTreeNode (TNDisj $ d{trdDefault = (trdDefault d)}) parT) cs)
    _ -> throwError insertErrMsg
  DisjDisjunctSelector i -> case parNode of
    TNDisj d ->
      return
        ( TreeCursor
            ( substTreeNode (TNDisj $ d{trdDisjuncts = take i (trdDisjuncts d) ++ [subT] ++ drop (i + 1) (trdDisjuncts d)}) parT
            )
            cs
        )
    _ -> throwError insertErrMsg
  ParentSelector -> throwError "propUpTC: ParentSelector is not allowed"
  RootSelector -> throwError "propUpTC: RootSelector is not allowed"
 where
  parNode = treeNode parT
  updateParScope :: (MonadError String m) => Tree -> ScopeSelector -> Tree -> m TreeCursor
  updateParScope par label newSub = case treeNode par of
    TNScope parScope ->
      if
        | isTreeBottom newSub -> return (TreeCursor newSub cs)
        | Map.member label (trsSubs parScope) ->
            let
              sf = trsSubs parScope Map.! label
              newSF = sf{ssfField = newSub}
              newScope = parScope{trsSubs = Map.insert label newSF (trsSubs parScope)}
             in
              return (TreeCursor (substTreeNode (TNScope newScope) parT) cs)
        | otherwise -> throwError insertErrMsg
    _ -> throwError insertErrMsg

  insertErrMsg :: String
  insertErrMsg =
    printf
      "propUpTC: cannot insert child %s to parent %s, path: %s, selector: %s, child:\n%s\nparent:\n%s"
      (showTreeType subT)
      (showTreeType parT)
      (show $ pathFromTC tc)
      (show sel)
      (show subT)
      (show parT)

propUpTCSel :: (EvalEnv m) => Selector -> TreeCursor -> m TreeCursor
propUpTCSel _ tc@(TreeCursor _ []) = return tc
propUpTCSel sel tc@(TreeCursor _ ((s, _) : _)) =
  if s == sel
    then propUpTC tc
    else propUpTC tc >>= propUpTCSel sel

-- | Traverse all the sub nodes of the tree.
traverseSubNodes :: (EvalEnv m) => (TreeCursor -> EvalMonad TreeCursor) -> TreeCursor -> m TreeCursor
traverseSubNodes f tc = case treeNode (tcFocus tc) of
  TNScope scope ->
    let
      goSub :: (EvalEnv m) => TreeCursor -> ScopeSelector -> m TreeCursor
      goSub acc k =
        if isTreeBottom (tcFocus acc)
          then return acc
          else getSubTC (ScopeSelector k) acc >>= f >>= levelUp (ScopeSelector k)
     in
      foldM goSub tc (Map.keys (trsSubs scope))
  TNDisj d ->
    let
      goSub :: (EvalEnv m) => TreeCursor -> Selector -> m TreeCursor
      goSub acc sel = getSubTC sel acc >>= f >>= levelUp sel
     in
      do
        utc <- maybe (return tc) (\_ -> goSub tc DisjDefaultSelector) (trdDefault d)
        foldM goSub utc (map DisjDisjunctSelector [0 .. length (trdDisjuncts d) - 1])
  TNList l ->
    let
      goSub :: (EvalEnv m) => TreeCursor -> Int -> m TreeCursor
      goSub acc i =
        if isTreeBottom (tcFocus acc)
          then return acc
          else getSubTC (IndexSelector i) acc >>= f >>= levelUp (IndexSelector i)
     in
      foldM goSub tc [0 .. length (trLstSubs l) - 1]
  TNFunc fn ->
    let
      goSub :: (EvalEnv m) => TreeCursor -> Int -> m TreeCursor
      goSub acc i =
        if isTreeBottom (tcFocus acc)
          then return acc
          else getSubTC (FuncArgSelector i) acc >>= f >>= levelUp (FuncArgSelector i)
     in
      foldM goSub tc [0 .. length (trfnArgs fn) - 1]
  TNAtom _ -> return tc
  TNBounds _ -> return tc
  TNConstraint _ -> return tc
  TNRefCycleVar -> return tc
  TNLink _ -> return tc
  TNBottom _ -> return tc
  TNTop -> return tc
 where
  levelUp :: (EvalEnv m) => Selector -> TreeCursor -> m TreeCursor
  levelUp = propUpTCSel

  getSubTC :: (EvalEnv m) => Selector -> TreeCursor -> m TreeCursor
  getSubTC sel cursor = goDownTCSelErr sel cursor

{- | Traverse the leaves of the tree cursor in the following order
1. Traverse the current node.
2. Traverse the sub-tree with the selector.
-}
traverseTC :: (EvalEnv m) => (TreeCursor -> EvalMonad TreeCursor) -> TreeCursor -> m TreeCursor
traverseTC f tc = case treeNode n of
  TNScope _ -> f tc >>= traverseSubNodes (traverseTC f)
  TNDisj _ -> f tc >>= traverseSubNodes (traverseTC f)
  TNFunc _ -> f tc >>= traverseSubNodes (traverseTC f)
  TNList _ -> f tc >>= traverseSubNodes (traverseTC f)
  TNAtom _ -> f tc
  TNBounds _ -> f tc
  TNConstraint _ -> f tc
  TNRefCycleVar -> f tc
  TNLink _ -> f tc
  TNBottom _ -> f tc
  TNTop -> f tc
 where
  n = tcFocus tc

setOrigNodesTC :: (EvalEnv m) => TreeCursor -> m TreeCursor
setOrigNodesTC = traverseTC f
 where
  f :: (EvalEnv m) => TreeCursor -> m TreeCursor
  f tc =
    let cur = tcFocus tc
        updated = if isNothing (treeOrig cur) then cur{treeOrig = Just cur} else cur
     in return (TreeCursor updated (tcCrumbs tc))

evalTC :: (EvalEnv m) => TreeCursor -> m TreeCursor
evalTC tc = case treeNode (tcFocus tc) of
  TNFunc fn -> do
    dump $ printf "evalTC: path: %s, evaluate function, tip:%s" (show $ pathFromTC tc) (show $ tcFocus tc)
    trfnFunc fn (trfnArgs fn) tc
  TNConstraint c ->
    let
      origAtom = mkNewTree (TNAtom $ trCnOrigAtom c)
      op = mkNewTree (TNFunc $ mkBinaryOp AST.Unify (trCnUnify c) origAtom (trCnCnstr c))
      unifyTC = TreeCursor op (tcCrumbs tc)
     in
      do
        dump $ printf "evalTC: constraint unify tc:\n%s" (showTreeCursor unifyTC)
        x <- evalTC unifyTC
        if tcFocus x == origAtom
          then return (TreeCursor origAtom (tcCrumbs tc))
          else throwError $ printf "evalTC: constraint not satisfied, %s != %s" (show (tcFocus x)) (show origAtom)
  TNLink l -> do
    dump $
      printf "evalTC: path: %s, evaluate link %s" (show $ pathFromTC tc) (show $ trlTarget l)
    res <- followLink l tc
    case res of
      Nothing -> return tc
      Just tarTC -> do
        u <- evalTC tarTC
        return (TreeCursor (tcFocus u) (tcCrumbs tc))
  TNScope scope ->
    let
      evalSub :: (EvalEnv m) => TreeCursor -> ScopeSelector -> m TreeCursor
      evalSub acc sel = case treeNode (tcFocus acc) of
        TNBottom _ -> return acc
        TNScope x -> evalTCScopeField sel x (tcNodeSetter acc)
        _ -> return $ setTCFocus (mkBottom "not a struct") acc
     in
      foldM evalSub tc (Map.keys (trsSubs scope))
  TNList _ -> traverseSubNodes evalTC tc
  TNDisj _ -> traverseSubNodes evalTC tc
  TNRefCycleVar -> return tc
  TNAtom _ -> return tc
  TNBounds _ -> return tc
  TNBottom _ -> return tc
  TNTop -> return tc

evalTCScopeField :: (EvalEnv m) => ScopeSelector -> TNScope -> (TreeNode -> TreeCursor) -> m TreeCursor
evalTCScopeField sel scope setter = case sel of
  StringSelector _ ->
    let sf = trsSubs scope Map.! sel
     in evalTC (mkSubTC (ScopeSelector sel) (ssfField sf) tc) >>= propUpTCSel (ScopeSelector sel)
  DynamicSelector i ->
    let sf = trsDynSubs scope !! i
     in do
          selTC <- evalTC (mkSubTC (ScopeSelector sel) (dsfSelTree sf) tc)
          case selTC of
            (viewTC -> (TNAtom (TreeAtom (String s)))) -> do
              subTC <- evalTC (mkSubTC (ScopeSelector sel) (dsfField sf) tc)
              return $ modifyTCFocus (insertEvaledDyn s (dsfAttr sf) (tcFocus subTC)) (fromJust $ goUpTC subTC)
            _ -> return $ setter (TNBottom $ TreeBottom "selector can only be a string")
 where
  tc = setter (TNScope scope)

  insertEvaledDyn :: String -> LabelAttr -> Tree -> Tree -> Tree
  insertEvaledDyn s a sub t@(treeNode -> (TNScope x)) =
    setTreeNode
      ( TNScope $
          x
            { trsSubs =
                ( Map.delete sel
                    . Map.insert
                      (StringSelector s)
                      ( StaticScopeField
                          { ssfField = sub
                          , ssfAttr = a
                          }
                      )
                )
                  (trsSubs x)
            , trsOrdLabels = filter (/= sel) (trsOrdLabels x) ++ [StringSelector s]
            }
      )
      t
  insertEvaledDyn _ _ _ _ = mkBottom "not a struct"

-- TODO: Update the substituted tree cursor.
followLink :: (EvalEnv m) => TNLink -> TreeCursor -> m (Maybe TreeCursor)
followLink link tc = do
  res <- searchTCPath (trlTarget link) tc
  case res of
    Nothing -> return Nothing
    Just tarTC ->
      let tarAbsPath = canonicalizePath $ pathFromTC tarTC
       in if
            | tarAbsPath == selfAbsPath -> do
                dump $
                  printf
                    "%s: reference cycle detected: %s == %s."
                    header
                    (show $ pathFromTC tc)
                    (show $ pathFromTC tarTC)
                return $ Just (TreeCursor (mkNewTree TNRefCycleVar) (tcCrumbs tc))
            | isPrefix tarAbsPath selfAbsPath ->
                throwError $
                  printf
                    "structural cycle detected. %s is a prefix of %s"
                    (show tarAbsPath)
                    (show selfAbsPath)
            | otherwise ->
                let tarNode = tcFocus tarTC
                    substTC = TreeCursor tarNode (tcCrumbs tc)
                 in case treeNode tarNode of
                      TNLink newLink -> do
                        dump $ printf "%s: substitutes to another link. go to %s" header (show $ trlTarget newLink)
                        followLink newLink substTC
                      TNConstraint c -> do
                        dump $ printf "%s: substitutes to the atom value of the constraint" header
                        return $ Just (TreeCursor (mkNewTree (TNAtom $ trCnAtom c)) (tcCrumbs tc))
                      _ -> do
                        dump $ printf "%s: resolves to tree node:\n%s" header (show tarNode)
                        return $ Just substTC
 where
  header :: String
  header = printf "followLink, link %s, path: %s" (show $ trlTarget link) (show $ pathFromTC tc)
  selfAbsPath = canonicalizePath $ pathFromTC tc

{- | Search the tree cursor up to the root and return the tree cursor that points to the variable.
The cursor will also be propagated to the parent block.
-}
searchTCVar :: (EvalEnv m) => Selector -> TreeCursor -> m (Maybe TreeCursor)
searchTCVar sel@(ScopeSelector ssel@(StringSelector _)) tc = case treeNode (tcFocus tc) of
  TNScope scope -> case Map.lookup ssel (trsSubs scope) of
    Just sf ->
      if lbAttrIsVar (ssfAttr sf)
        then return . Just $ mkSubTC sel (ssfField sf) tc
        else goUp tc
    _ -> goUp tc
  _ -> goUp tc
 where
  goUp :: (EvalEnv m) => TreeCursor -> m (Maybe TreeCursor)
  goUp (TreeCursor _ [(RootSelector, _)]) = return Nothing
  goUp utc = propUpTC utc >>= searchTCVar sel
searchTCVar _ _ = return Nothing

-- | Search the tree cursor up to the root and return the tree cursor that points to the path.
searchTCPath :: (EvalEnv m) => Path -> TreeCursor -> m (Maybe TreeCursor)
searchTCPath p tc = runEnvMaybe $ do
  fstSel <- newEvalEnvMaybe $ headSel p
  base <- EnvMaybe $ searchTCVar fstSel tc
  tailP <- newEvalEnvMaybe $ tailPath p
  -- TODO: what if the base contains unevaluated nodes?
  newEvalEnvMaybe $ goDownTCPath tailP (trace (printf "base is %s, tail is %s" (show base) (show tailP)) base)

data ExtendTCLabel = ExtendTCLabel
  { exlSelector :: Selector
  , exlAttr :: LabelAttr
  }
  deriving (Show)

-- {- | Update the tree node to the tree cursor with the given selector and returns the new cursor that focuses on the
-- updated value.
-- -}
-- extendTC :: Selector -> Tree -> TreeCursor -> TreeCursor
-- extendTC sel sub (tip, cs) = (sub, (sel, tip) : cs)

indexBySel :: (EvalEnv m) => Selector -> AST.UnaryExpr -> Tree -> m Tree
indexBySel sel ue t = case treeNode t of
  -- The tree is an evaluated, final scope, which could be formed by an in-place expression, like ({}).a.
  TNScope scope -> case sel of
    ScopeSelector s -> case Map.lookup s (trsSubs scope) of
      Just sf -> return (ssfField sf)
      Nothing ->
        return $
          mkNewTree
            ( TNFunc $
                mkTNFunc "indexBySel" Function constFunc (\_ -> AST.ExprUnaryExpr ue) [t]
            )
    s -> throwError $ printf "invalid selector: %s" (show s)
  TNList list -> case sel of
    IndexSelector i ->
      return $
        if i < length (trLstSubs list)
          then trLstSubs list !! i
          else mkBottom $ "index out of bound: " ++ show i
    _ -> throwError "invalid list selector"
  TNLink link ->
    return $
      mkNewTree
        ( TNLink $
            link
              { trlTarget = appendSel sel (trlTarget link)
              , trlExpr = ue
              }
        )
  TNDisj dj ->
    if isJust (trdDefault dj)
      then indexBySel sel ue (fromJust (trdDefault dj))
      else throwError insertErr
  TNFunc _ ->
    return $
      mkNewTree
        ( TNFunc $
            mkTNFunc
              "indexBySel"
              Function
              ( \ts tc -> do
                  utc <- evalTC (mkSubTC unaryOpSelector (ts !! 0) tc)
                  r <- indexBySel sel ue (tcFocus utc)
                  evalTC $ setTCFocus r tc
              )
              (\_ -> AST.ExprUnaryExpr ue)
              [t]
        )
  _ -> throwError insertErr
 where
  insertErr = printf "index: cannot index %s with sel: %s" (show t) (show sel)

  constFunc :: (EvalEnv m) => [Tree] -> TreeCursor -> m TreeCursor
  constFunc _ = return

indexByTree :: (EvalEnv m) => Tree -> AST.UnaryExpr -> Tree -> m Tree
indexByTree sel ue tree =
  case treeNode sel of
    TNAtom ta -> do
      idxsel <- selFromAtom ta
      indexBySel idxsel ue tree
    TNDisj dj -> case trdDefault dj of
      Just df -> do
        dump $ printf "indexByTree: default disjunct: %s" (show df)
        indexByTree df ue tree
      Nothing -> return invalidSelector
    TNConstraint c -> do
      idxsel <- selFromAtom (trCnOrigAtom c)
      indexBySel idxsel ue tree
    TNLink link ->
      return $
        mkNewTree
          ( TNFunc $
              TreeFunc
                { trfnName = "indexByTree"
                , trfnType = Function
                , trfnArgs = [sel]
                , trfnExprGen = \_ -> AST.ExprUnaryExpr (trlExpr link)
                , trfnFunc = \ts tc -> do
                    idx <- evalTC (mkSubTC (FuncArgSelector 0) (ts !! 0) tc)
                    dump $ printf "indexByTree TNLink: index resolved to %s" (show $ tcFocus idx)
                    t <- indexByTree (tcFocus idx) ue tree
                    dump $ printf "indexByTree TNLink: index result created %s" (show $ t)
                    u <- evalTC $ setTCFocus t tc
                    dump $ printf "indexByTree TNLink: index result resolved to %s" (show $ tcFocus u)
                    return u
                }
          )
    TNFunc _ ->
      return $
        mkNewTree
          ( TNFunc $
              mkTNFunc
                "indexByTree"
                Function
                ( \ts tc -> do
                    selTC <- evalTC (mkSubTC (FuncArgSelector 0) (ts !! 0) tc)
                    dump $ printf "indexByTree: path: %s, sel: %s, tree: %s" (show $ pathFromTC tc) (show $ tcFocus selTC) (show $ ts !! 1)
                    t <- indexByTree (tcFocus selTC) ue (ts !! 1)
                    dump $ printf "indexByTree TNFunc: resolved to %s" (show t)
                    evalTC $ setTCFocus t tc
                )
                (\_ -> AST.ExprUnaryExpr ue)
                [sel, tree]
          )
    _ -> return invalidSelector
 where
  selFromAtom :: (EvalEnv m) => TNAtom -> m Selector
  selFromAtom a = case trAmAtom a of
    (String s) -> return (ScopeSelector $ StringSelector s)
    (Int i) -> return $ IndexSelector $ fromIntegral i
    _ -> throwError "extendTCIndex: invalid selector"

  invalidSelector :: Tree
  invalidSelector = mkNewTree (TNBottom $ TreeBottom $ printf "invalid selector: %s" (show sel))
