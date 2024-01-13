module E2E where

import           Data.ByteString.Builder
import qualified Data.Map.Strict         as Map
import qualified Data.Set                as Set
import           Eval                    (eval)
import           Parser
import           System.IO               (readFile)
import           Test.Tasty
import           Test.Tasty.HUnit
import           Value

newStruct :: [String] -> Map.Map String Value -> Set.Set String -> Value
newStruct lbls fds ids = Struct (StructValue lbls fds ids)

startEval :: String -> Either String Value
startEval s = eval (parseCUE s) []

e2eTests :: TestTree
e2eTests =
  testGroup
    "e2e tests"
    [ testCase "basic" $
        do
          s <- readFile "tests/e2efiles/basic.cue"
          let val = startEval s
          case val of
            Left err -> assertFailure err
            Right val' ->
              val'
                @?= newStruct
                  ["x1", "x2", "y1", "y2", "z1"]
                  ( Map.fromList
                      [ ("x1", Bool True),
                        ("x2", Bool False),
                        ("y1", Top),
                        ("y2", Bottom ""),
                        ("z1", Null)
                      ]
                  )
                  Set.empty,
      testCase "unaryop" $
        do
          s <- readFile "tests/e2efiles/unaryop.cue"
          let val = startEval s
          case val of
            Left err -> assertFailure err
            Right val' ->
              val'
                @?= newStruct
                  ["x", "y", "z"]
                  ( Map.fromList
                      [ ("x", Int 1),
                        ("y", Int (-1)),
                        ("z", Bool False)
                      ]
                  )
                  Set.empty,
      testCase "binop" $
        do
          s <- readFile "tests/e2efiles/binop.cue"
          let val = startEval s
          case val of
            Left err -> assertFailure err
            Right val' ->
              val'
                @?= newStruct
                  (map (\i -> "x" ++ show i) [1 .. 8])
                  ( Map.fromList
                      [ ("x1", Int 3),
                        ("x2", Int 8),
                        ("x3", Int 2),
                        ("x4", Int 5),
                        ("x5", Bottom ""),
                        ("x6", Int (-3)),
                        ("x7", Int 7),
                        ("x8", Int 5)
                      ]
                  )
                  Set.empty,
      testCase
        "disjunction"
        $ do
          s <- readFile "tests/e2efiles/disjunct.cue"
          let val = startEval s
          case val of
            Left err -> assertFailure err
            Right val' ->
              val'
                @?= newStruct
                  (map (\i -> "x" ++ show i) [1 .. 6] ++ ["y0", "y1", "y2"])
                  ( Map.fromList
                      [ ("x1", Disjunction [String "tcp"] [String "tcp", String "udp"]),
                        ("x2", Disjunction [Int 1] [Int 1, Int 2, Int 3]),
                        ("x3", Disjunction [Int 1, Int 2] [Int 1, Int 2, Int 3]),
                        ("x4", Disjunction [Int 2] [Int 1, Int 2, Int 3]),
                        ("x5", Disjunction [Int 1, Int 2] [Int 1, Int 2, Int 3]),
                        ("x6", Disjunction [] [Int 1, Int 2]),
                        ("y0", Disjunction [] [Int 1, Int 2, Int 3]),
                        ("y1", Disjunction [Int 2] [Int 1, Int 2, Int 3]),
                        ("y2", Disjunction [Int 3] [Int 1, Int 2, Int 3])
                      ]
                  )
                  Set.empty,
      testCase
        "disjunction-2"
        $ do
          s <- readFile "tests/e2efiles/disjunct2.cue"
          let val = startEval s
          case val of
            Left err -> assertFailure err
            Right val' ->
              val'
                @?= newStruct
                  ["x"]
                  ( Map.fromList
                      [ ( "x",
                          Disjunction
                            []
                            [ newStruct ["y", "z"] (Map.fromList [("y", Int 1), ("z", Int 3)]) Set.empty,
                              newStruct ["y"] (Map.fromList [("y", Int 2)]) Set.empty
                            ]
                        )
                      ]
                  )
                  Set.empty,
      testCase
        "unify-structs"
        $ do
          s <- readFile "tests/e2efiles/unify_structs.cue"
          let val = startEval s
          case val of
            Left err -> assertFailure err
            Right val' ->
              val'
                @?= newStruct
                  ["a", "b", "d", "z"]
                  ( Map.fromList
                      [ ("a", Int 123),
                        ("b", Int 456),
                        ("d", String "hello"),
                        ("z", Int 4321)
                      ]
                  )
                  Set.empty,
      testCase
        "vars"
        $ do
          s <- readFile "tests/e2efiles/vars.cue"
          let val = startEval s
          case val of
            Left err -> assertFailure err
            Right val' ->
              val'
                @?= newStruct
                  ["z", "x", "y"]
                  ( Map.fromList
                      [ ("z", Int 1),
                        ("x", Int 1),
                        ("y", Int 1)
                      ]
                  )
                  Set.empty
    ]
