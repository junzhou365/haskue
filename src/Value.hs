{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module Value where

import Control.Monad.Except (MonadError, throwError)
import Control.Monad.State.Strict (MonadState, get, modify, put)
import Control.Monad.Trans.Maybe (MaybeT (..))
import Data.ByteString.Builder
  ( Builder,
    char7,
    integerDec,
    string7,
  )
import Data.Graph
  ( SCC (CyclicSCC),
    graphFromEdges,
    reverseTopSort,
    stronglyConnComp,
  )
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)
import qualified Data.Set as Set
import Debug.Trace
import Text.Printf (printf)

-- TODO: IntSelector
data Selector = StringSelector String deriving (Eq, Ord)

instance Show Selector where
  show (StringSelector s) = s

-- | Path is full path to a value.
newtype Path = Path [Selector] deriving (Eq, Ord)

showPath :: Path -> String
showPath (Path sels) = intercalate "." $ map (\(StringSelector s) -> s) (reverse sels)

instance Show Path where
  show = showPath

emptyPath :: Path
emptyPath = Path []

pathFromList :: [Selector] -> Path
pathFromList sels = Path (reverse sels)

appendSel :: Selector -> Path -> Path
appendSel sel (Path xs) = Path (sel : xs)

initPath :: Path -> Maybe Path
initPath (Path []) = Nothing
initPath (Path xs) = Just $ Path (tail xs)

lastSel :: Path -> Maybe Selector
lastSel (Path []) = Nothing
lastSel (Path xs) = Just $ head xs

-- -- relPath p base returns the relative path from base to p.
-- -- If base is not a prefix of p, then p is returned.
-- relPath :: Path -> Path -> Path
-- relPath (Path p) (Path base) = Path $ go (reverse p) (reverse base) []
--   where
--     go :: [Selector] -> [Selector] -> [Selector] -> [Selector]
--     go [] _ acc = acc
--     go _ [] acc = acc
--     go (x : xs) (y : ys) acc =
--       if x == y
--         then go xs ys (x : acc)
--         else acc

mergePaths :: [(Path, Path)] -> [(Path, Path)] -> [(Path, Path)]
mergePaths p1 p2 = Set.toList $ Set.fromList (p1 ++ p2)

-- | TreeCrumb is a pair of a name and an environment. The name is the name of the field in the parent environment.
type TreeCrumb = (Selector, StructValue)

type TreeCursor = (StructValue, [TreeCrumb])

goUp :: TreeCursor -> Maybe TreeCursor
goUp (_, []) = Nothing
goUp (_, (_, v') : vs) = Just (v', vs)

goDown :: Path -> TreeCursor -> Maybe TreeCursor
goDown (Path sels) = go (reverse sels)
  where
    next :: Selector -> TreeCursor -> Maybe TreeCursor
    next n@(StringSelector name) (sv@(StructValue _ fields _), vs) = do
      val <- Map.lookup name fields
      newSv <- svFromVal val
      return (newSv, (n, sv) : vs)

    go :: [Selector] -> TreeCursor -> Maybe TreeCursor
    go [] cursor = Just cursor
    go (x : xs) cursor = do
      nextCur <- next x cursor
      go xs nextCur

attach :: StructValue -> TreeCursor -> TreeCursor
attach sv (_, vs) = (sv, vs)

addSubBlock :: Maybe Selector -> StructValue -> TreeCursor -> TreeCursor
addSubBlock Nothing newSv (sv, vs) = (mergeStructValues newSv sv, vs)
addSubBlock (Just (StringSelector sel)) newSv (sv, vs) =
  (sv {structFields = Map.insert sel (Struct newSv) (structFields sv)}, vs)

searchUpVar :: String -> TreeCursor -> Maybe (Value, TreeCursor)
searchUpVar var = go
  where
    go :: TreeCursor -> Maybe (Value, TreeCursor)
    go cursor@(StructValue _ fields _, []) = case Map.lookup var fields of
      Just v -> Just (v, cursor)
      Nothing -> Nothing
    go cursor@(StructValue _ fields _, _) =
      case Map.lookup var fields of
        Just v -> Just (v, cursor)
        Nothing -> goUp cursor >>= go

pathFromBlock :: TreeCursor -> Path
pathFromBlock (_, crumbs) = Path . reverse $ go crumbs []
  where
    go :: [TreeCrumb] -> [Selector] -> [Selector]
    go [] acc = acc
    go ((n, _) : cs) acc = go cs (n : acc)

svFromVal :: Value -> Maybe StructValue
svFromVal (Struct sv) = Just sv
svFromVal _ = Nothing

-- -- | Takes a list of paths and returns a list of paths in the dependency order.
-- -- In the returned list, the first element is the path that has can be evaluated.
-- depEdgesOrder :: [(Path, Path)] -> Maybe [Path]
-- depEdgesOrder ps = depsOrder edges
--   where
--     depMap = Map.fromListWith (++) (map (\(k, v) -> (k, [v])) ps)
--     edges = Map.toList depMap
--
-- depsOrder :: [(Path, [Path])] -> Maybe [Path]
-- depsOrder dps =
--   if hasCycle edgesForGraph
--     then Nothing
--     else Just $ map (\v -> let (_, p, _) = nodeFromVertex v in p) (reverseTopSort graph)
--   where
--     edgesForGraph = map (\(k, vs) -> ((), k, vs)) dps
--     (graph, nodeFromVertex, _) = graphFromEdges edgesForGraph
depsHasCycle :: [(Path, Path)] -> Bool
depsHasCycle ps = hasCycle edges
  where
    depMap = Map.fromListWith (++) (map (\(k, v) -> (k, [v])) ps)
    edges = Map.toList depMap

hasCycle :: [(Path, [Path])] -> Bool
hasCycle edges = any isCycle (stronglyConnComp edgesForGraph)
  where
    edgesForGraph = map (\(k, vs) -> ((), k, vs)) edges

    isCycle (CyclicSCC _) = True
    isCycle _ = False

-- structPenOrder :: Path -> Map.Map String Value -> Maybe [String]
-- structPenOrder curPath xs = undefined
--   where
--     penSubGraph :: String -> Value -> Maybe (Path, String, [Path])
--     penSubGraph k (Pending dps _) = Just (curPath ++ [StringSelector k], k, map snd dps)
--     penSubGraph _ _ = Nothing
--
--     penFields :: [(Path, String, [Path])]
--     penFields = Map.foldrWithKey (\k field acc -> case penSubGraph k field of Just res -> res : acc; Nothing -> acc) [] xs
--
--     penOrder :: Maybe [Path]
--     penOrder = depsOrder $ map (\(p, _, dps) -> (p, dps)) penFields

-- | Context
data Context = Context
  { -- curBlock is the current block that contains the variables.
    -- A new block will replace the current one when a new block is entered.
    -- A new block is entered when one of the following is encountered:
    -- - The "{" token
    -- - for and let clauses
    ctxCurBlock :: TreeCursor,
    ctxReverseDeps :: Map.Map Path Path
  }

type EvalMonad a = forall m. (MonadError String m, MonadState Context m) => m a

-- | Evaluator is a function that takes a list of tuples values and their paths and returns a value.
type Evaluator = [(Path, Value)] -> EvalMonad Value

data Value
  = Top
  | String String
  | Int Integer
  | Bool Bool
  | Struct StructValue
  | Disjunction
      { defaults :: [Value],
        disjuncts :: [Value]
      }
  | Null
  | Bottom String
  | Pending PendingValue

data StructValue = StructValue
  { structOrderedLabels :: [String],
    structFields :: Map.Map String Value,
    structIDs :: Set.Set String
  }
  deriving (Show, Eq)

data PendingValue
  = PendingValue
      { -- pendPath is the path to the pending value.
        pendPath :: Path,
        -- depEdges is a list of paths to the unresolved references.
        -- path should be the full path.
        -- The edges are primarily used to detect cycles.
        -- the first element of the tuple is the path to a pending value.
        -- the second element of the tuple is the path to a value that the pending value depends on.
        pendDeps :: [(Path, Path)],
        pendArgs :: [(Path, Value)],
        -- evaluator is a function that takes a list of values and returns a value.
        -- The order of the values in the list is the same as the order of the paths in deps.
        pendEvaluator :: Evaluator
      }
  | Unevaluated {unevalPath :: Path}

instance Show PendingValue where
  show (PendingValue p d a _) = printf "(Pending, path: %s edges: %s, args: %s)" (show p) (show d) (show a)
  show (Unevaluated p) = printf "(Unevaluated, path: %s)" (show p)

-- TODO: merge same keys handler
-- two embeded structs can have same keys
mergeStructValues :: StructValue -> StructValue -> StructValue
mergeStructValues (StructValue ols1 fields1 ids1) (StructValue ols2 fields2 ids2) =
  StructValue (ols1 ++ ols2) (Map.union fields1 fields2) (Set.union ids1 ids2)

mergeArgs :: [(Path, Value)] -> [(Path, Value)] -> [(Path, Value)]
mergeArgs xs ys = Map.toList $ Map.fromList (xs ++ ys)

-- | The binFunc is used to evaluate a binary function with two arguments.
binFunc :: (MonadError String m, MonadState Context m) => (Value -> Value -> EvalMonad Value) -> Value -> Value -> m Value
binFunc bin (Pending (PendingValue p1 d1 a1 e1)) (Pending (PendingValue p2 d2 a2 e2))
  | p1 == p2 =
      return $
        Pending $
          PendingValue
            p1
            (mergePaths d1 d2)
            (mergeArgs a1 a2)
            ( \xs -> do
                v1 <- e1 xs
                v2 <- e2 xs
                bin v1 v2
            )
  | otherwise =
      throwError $
        printf "binFunc: two pending values have different paths, p1: %s, p2: %s" (show p1) (show p2)
binFunc bin v1@(Pending {}) v2 = unaFunc (`bin` v2) v1
binFunc bin v1 v2@(Pending {}) = unaFunc (bin v1) v2
binFunc bin v1 v2 = bin v1 v2

-- | The unaFunc is used to evaluate a unary function.
-- The first argument is the function that takes the value and returns a value.
unaFunc :: (MonadError String m, MonadState Context m) => (Value -> EvalMonad Value) -> Value -> m Value
unaFunc f (Pending (PendingValue p d a e)) = return $ Pending $ PendingValue p d a (bindEval e f)
unaFunc f v = f v

-- | Binds the evaluator to a function that uses the value as the argument.
bindEval :: Evaluator -> (Value -> EvalMonad Value) -> Evaluator
bindEval evalf f xs = evalf xs >>= f

mkUnevaluated :: Path -> Value
mkUnevaluated = Pending . Unevaluated

-- | Creates a new pending value.
mkPending :: Path -> Path -> Value
mkPending src dst = Pending $ newPendingValue src dst

newPendingValue :: Path -> Path -> PendingValue
newPendingValue src dst = PendingValue src [(src, dst)] [] f
  where
    f xs = do
      case lookup dst xs of
        Just v -> return v
        Nothing ->
          throwError $
            printf
              "Pending value can not find its dependent value, path: %s, depPath: %s, args: %s"
              (show src)
              (show dst)
              (show xs)

goToBlock :: (MonadError String m) => TreeCursor -> Path -> m TreeCursor
goToBlock block p = do
  topBlock <- propagateBack block
  case goDown p topBlock of
    Just b -> return b
    Nothing ->
      throwError $
        "value block, path: "
          ++ show p
          ++ " is not found"

-- | Go to the block that contains the value.
-- The path should be the full path to the value.
goToValBlock :: (MonadError String m) => TreeCursor -> Path -> m TreeCursor
goToValBlock cursor p = goToBlock cursor (fromJust $ initPath p)

propagateBack :: (MonadError String m) => TreeCursor -> m TreeCursor
propagateBack (sv, cs) = go cs sv
  where
    go :: (MonadError String m) => [TreeCrumb] -> StructValue -> m TreeCursor
    go [] acc = return (acc, [])
    go ((StringSelector sel, parSV) : restCS) acc =
      go restCS (parSV {structFields = Map.insert sel (Struct acc) (structFields parSV)})

locateGetValue :: (MonadError String m) => TreeCursor -> Path -> m Value
locateGetValue block path = goToValBlock block path >>= getVal (fromJust $ lastSel path)
  where
    getVal :: (MonadError String m) => Selector -> TreeCursor -> m Value
    getVal (StringSelector name) (StructValue _ fields _, _) =
      case Map.lookup name fields of
        Nothing -> throwError $ "pending value, name: " ++ show name ++ " is not found"
        Just penVal -> return penVal

locateSetValue :: (MonadError String m) => TreeCursor -> Path -> Value -> m TreeCursor
locateSetValue block path val = goToValBlock block path >>= updateVal (fromJust $ lastSel path) val
  where
    updateVal :: (MonadError String m) => Selector -> Value -> TreeCursor -> m TreeCursor
    updateVal (StringSelector name) newVal (StructValue ols fields ids, vs) =
      return (StructValue ols (Map.insert name newVal fields) ids, vs)

modifyValueInCtx :: (MonadError String m, MonadState Context m) => Path -> Value -> m ()
modifyValueInCtx path val = do
  ctx@(Context block _) <- get
  newBlock <- locateSetValue block path val
  updatedOrig <- goToBlock newBlock (pathFromBlock block)
  put $ ctx {ctxCurBlock = updatedOrig}

-- | Checks whether the given value can be applied to the pending value that depends on the given value. If it can, then
-- apply the value to the pending value.
checkEvalPen ::
  (MonadError String m, MonadState Context m) => (Path, Value) -> m ()
checkEvalPen (valPath, val) = do
  Context curBlock revDeps <- get
  case Map.lookup valPath revDeps of
    Nothing -> pure ()
    Just penPath -> do
      penVal <- locateGetValue curBlock penPath
      newPenVal <- applyPen (penPath, penVal) (valPath, val)
      case newPenVal of
        Pending {} -> pure ()
        -- Once the pending value is evaluated, we should trigger the fillPen for other pending values that depend
        -- on this value.
        v -> checkEvalPen (penPath, v)
      -- update the pending block.
      modifyValueInCtx
        penPath
        ( trace
            ( printf
                "checkEvalPen: penPath: %s, penVal: %s, valPath: %s, val: %s, newPenVal: %s"
                (show penPath)
                (show penVal)
                (show valPath)
                (show val)
                (show newPenVal)
            )
            newPenVal
        )

-- | Apply value to the pending value. It returns the new updated value.
-- It keeps applying the value to the pending value until the pending value is evaluated.
applyPen :: (MonadError String m, MonadState Context m) => (Path, Value) -> (Path, Value) -> m Value
applyPen (penPath, penV@(Pending {})) pair = go penV pair
  where
    go :: (MonadError String m, MonadState Context m) => Value -> (Path, Value) -> m Value
    go (Pending (PendingValue selfPath deps args f)) (valPath, val) =
      let newDeps = filter (\(_, depPath) -> depPath /= valPath) deps
          newArgs = ((valPath, val) : args)
       in do
            modify (\ctx -> ctx {ctxReverseDeps = Map.delete valPath (ctxReverseDeps ctx)})
            trace
              ( printf
                  "applyPen: valPath: %s, penPath: %s, args: %s, newDeps: %s"
                  (show valPath)
                  (show penPath)
                  (show newArgs)
                  (show newDeps)
              )
              pure
              ()
            if null newDeps
              then f newArgs >>= \v -> go v pair
              else return $ Pending $ PendingValue selfPath newDeps newArgs f
    go v _ = return v
applyPen (_, v) _ = throwError $ printf "applyPen expects a pending value, but got %s" (show v)

-- | Looks up the variable denoted by the name in the current block or the parent blocks.
-- If the variable is not evaluated yet or pending, a new pending value is created and returned.
-- Parameters:
--   var denotes the variable name.
--   path is the path to the current expression that contains the selector.
-- For example,
--  { a: b: x+y }
-- If the name is "y", and the path is "a.b".
lookupVar :: (MonadError String m, MonadState Context m) => String -> Path -> m Value
lookupVar var path = do
  Context block _ <- get
  case searchUpVar var block of
    Just (Pending v, _) -> Pending <$> depend path v
    Just (v, _) -> do
      trace (printf "lookupVar found var %s, block: %s, found: %s" (show var) (show block) (show v)) pure ()
      pure v
    Nothing ->
      throwError $
        printf "variable %s is not found, path: %s, block: %s" var (show path) (show block)

-- | access the named field of the struct.
-- Parameters:
--   s is the name of the field.
--   path is the path to the current expression that contains the selector.
dot :: (MonadError String m, MonadState Context m) => String -> Path -> Value -> m Value
dot field path value = case value of
  Struct (StructValue _ fields _) -> case Map.lookup field fields of
    -- The referenced value could be a pending value. Once the pending value is evaluated, the selector should be
    -- populated with the value.
    Just (Pending v) -> Pending <$> depend path v
    Just v -> return v
    Nothing -> return $ Bottom $ field ++ " is not found"
  _ ->
    throwError $
      printf
        "evalSelector: path: %s, sel: %s, value: %s is not a struct"
        (show path)
        (show field)
        (show value)

-- -- | Creates a dependency between the current value of the curPath to the value of the depPath.
depend :: (MonadError String m, MonadState Context m) => Path -> PendingValue -> m PendingValue
depend path (Unevaluated depPath) = do
  modify (\ctx -> ctx {ctxReverseDeps = Map.insert depPath path (ctxReverseDeps ctx)})
  trace (printf "Unevaluated depend: path: %s, depPath: %s" (show path) (show depPath)) pure ()
  return $ newPendingValue path depPath
depend path (PendingValue depPath _ _ _) = do
  modify (\ctx -> ctx {ctxReverseDeps = Map.insert depPath path (ctxReverseDeps ctx)})
  trace (printf "PendingValue depend: path: %s, depPath: %s" (show path) (show depPath)) pure ()
  return $ newPendingValue path depPath

emptyStruct :: StructValue
emptyStruct = StructValue [] Map.empty Set.empty

-- | Show is only used for debugging.
instance Show Value where
  show (String s) = s
  show (Int i) = show i
  show (Bool b) = show b
  show Top = "_"
  show Null = "null"
  show (Struct (StructValue ols fds _)) = "{ labels:" ++ show ols ++ ", fields: " ++ show fds ++ "}"
  show (Disjunction dfs djs) = "Disjunction: " ++ show dfs ++ ", " ++ show djs
  show (Bottom msg) = "_|_: " ++ msg
  show (Pending v) = show v

instance Eq Value where
  (==) (String s1) (String s2) = s1 == s2
  (==) (Int i1) (Int i2) = i1 == i2
  (==) (Bool b1) (Bool b2) = b1 == b2
  (==) (Struct (StructValue orderedLabels1 edges1 _)) (Struct (StructValue orderedLabels2 edges2 _)) =
    orderedLabels1 == orderedLabels2 && edges1 == edges2
  (==) (Disjunction defaults1 disjuncts1) (Disjunction defaults2 disjuncts2) =
    disjuncts1 == disjuncts2 && defaults1 == defaults2
  (==) (Bottom _) (Bottom _) = True
  (==) Top Top = True
  (==) Null Null = True
  (==) _ _ = False

buildCUEStr :: Value -> Builder
buildCUEStr = buildCUEStr' 0

buildCUEStr' :: Int -> Value -> Builder
buildCUEStr' _ (String s) = char7 '"' <> string7 s <> char7 '"'
buildCUEStr' _ (Int i) = integerDec i
buildCUEStr' _ (Bool b) = if b then string7 "true" else string7 "false"
buildCUEStr' _ Top = string7 "_"
buildCUEStr' _ Null = string7 "null"
buildCUEStr' ident (Struct (StructValue ols fds _)) =
  buildStructStr ident (map (\label -> (label, fds Map.! label)) ols)
buildCUEStr' ident (Disjunction dfs djs) =
  if null dfs
    then buildList djs
    else buildList dfs
  where
    buildList xs = foldl1 (\x y -> x <> string7 " | " <> y) (map (\d -> buildCUEStr' ident d) xs)
buildCUEStr' _ (Bottom _) = string7 "_|_"
buildCUEStr' _ (Pending {}) = string7 "_|_"

buildStructStr :: Int -> [(String, Value)] -> Builder
buildStructStr ident xs =
  if null xs
    then string7 "{}"
    else
      char7 '{'
        <> char7 '\n'
        <> buildFieldsStr ident xs
        <> string7 (replicate (ident * 2) ' ')
        <> char7 '}'

buildFieldsStr :: Int -> [(String, Value)] -> Builder
buildFieldsStr _ [] = string7 ""
buildFieldsStr ident (x : xs) =
  f x <> buildFieldsStr ident xs
  where
    f (label, val) =
      string7 (replicate ((ident + 1) * 2) ' ')
        <> string7 label
        <> string7 ": "
        <> buildCUEStr' (ident + 1) val
        <> char7 '\n'
