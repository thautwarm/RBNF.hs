{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE TemplateHaskell #-}
module RBNF.LookAHead where

import RBNF.Graph
import RBNF.Semantics
import RBNF.Symbols (Case)
import RBNF.Grammar (groupBy)

import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Maybe
import Control.Arrow
import Control.Lens (over, view, Lens', makeLenses)

import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Maybe as Maybe
import qualified Data.Vector as V
import qualified Data.Set as S

type Map = M.Map

data Travel = Travel { par :: Maybe Travel , cur :: Int }
    deriving (Eq, Ord, Show)

data LAEdge = LAShift Case | LAReduce
    deriving (Eq, Ord, Show)
data LATree a
    = LA1 (Map LAEdge (LATree a))
    | LAEnd [a]
    deriving (Eq, Ord, Show, Functor)

dispLATree :: Show a => Int -> LATree a -> String
dispLATree i = \case
    LAEnd xs -> indent i $ show xs
    LA1 m    -> body ++ "\n"
        where body = L.intercalate "\n"     $
                      flip map (M.toList m) $
                       \(case', la) ->
                            indent i $ (
                                show case' ++
                                "\n" ++
                                dispLATree (i + 4) la)
data Coro a o r
    = Coro { fp :: a -> Either r (o, Coro a o r) }

type Generator a o = MaybeT (State (Coro a o ())) o

yield :: a -> Generator a o
yield a = do
    fp <- lift $ gets fp
    let either = fp a
    case either of
        Left () -> mzero
        Right (o, coro) -> do
            lift $ put coro
            return o


getNode :: Int -> Reader Graph Node
getNode i = asks $ (M.! i) . view nodes

getStartIdx :: String -> Reader Graph Int
getStartIdx i = asks $ (M.! i) . view starts


uniqueCat :: Eq a => [a] -> [a] -> [a]
uniqueCat a b = L.nub $ a ++ b

nextBrs :: Node -> [Int]
nextBrs n = Maybe.maybeToList (view optionBr n) ++ view thenBrs n

next1 :: Graph -> Travel -> Map Case [Travel]
next1 graph travel =
    case kind curNode of
        NEntity (ENonTerm s) ->
            let idx      = startIndices M.! s
                descTrvl = Travel (Just travel) idx
            in frec descTrvl
        NEntity (ETerm c) ->
            let newTrvls = [travel {cur = nextIdx} | nextIdx <- nextIndices]
            in M.singleton c $ newTrvls
        _ ->
            case (nextIndices, par travel) of
                ([], Nothing) -> M.empty
                ([], Just parent) ->
                    let parNode = nodeStore M.! cur parent
                        trvls   = [parent {cur = i} | i <- nextBrs parNode]
                    in M.unionsWith uniqueCat $ map frec trvls
                (xs, _) ->
                    let trvls = [travel {cur = i} | i <- nextIndices]
                    in M.unionsWith uniqueCat $ map frec trvls
    where
        frec         = next1 graph
        endIndices   = view ends graph
        startIndices = view starts graph
        nodeStore    = view nodes graph

        curIdx       = cur travel
        curNode      = nodeStore M.! curIdx
        nextIndices  = nextBrs curNode

isRec Travel {cur, par=Just par} = frec cur par
        where
            frec i Travel {cur, par}
             | i == cur = True
             | otherwise = case par of
                Nothing -> False
                Just par -> frec i par

data Nat' = NZ | NS Nat'
nextK :: Graph -> Travel -> Nat' -> LATree Travel
nextK graph trvl n =
    case n of
        _ | M.null xs -> LAEnd [trvl]
        NZ     -> LA1 . M.mapKeys LAShift $
                  M.map LAEnd xs
        NS n'  -> LA1 . M.mapKeys LAShift $
                  M.map (mergeLATrees . L.nub . map nextDec1) xs

            where nextDec1 :: Travel -> LATree Travel
                  nextDec1 trvl =
                    let n'' = case kind $ view nodes graph M.! cur trvl of
                            NEntity (ENonTerm _) -> n'
                            -- avoid infinite recursing for productions
                            -- referring no nonterminals other than itself.
                            Stop                 -> n'
                            _                    -> n

                    in nextK graph trvl n''
    where xs = next1 graph trvl

mergeLATrees ::  [LATree a] -> LATree a

mergeLATrees [] = error "invalid"
mergeLATrees [a] = a
mergeLATrees las = LA1 cases
    where
        frec :: [LATree a] -> [(LAEdge, LATree a)]
        frec  = \case
            []        -> []
            LA1 mp:xs -> (M.toList mp ++) $ frec xs
            a:xs      -> (LAReduce, a):frec xs

        cases = M.map mergeLATrees       $
                M.fromListWith (++)      $
                map (fst &&& pure . snd) $ frec las

intToNat :: Int -> Nat'
intToNat i
    | i < 0 = error "invalid" -- TODO
    | otherwise = intToNat' i
    where intToNat' = \case
            0 -> NZ
            n -> NS $ intToNat' $ n-1

type LANum = Int
lookAHeadRoot :: LANum -> Graph -> Int -> LATree Int
lookAHeadRoot k graph idx =
    let root  = Travel {cur=idx, par=Nothing}
        nexts = nextBrs $ view nodes graph M.! idx
        trvls = [root {par=Nothing, cur=next} | next <- nexts]
        n     = intToNat k
    in
    mergeLATrees [cur trvl <$ nextK graph trvl n | trvl <- trvls]

makeLATables :: LANum -> Graph -> Map Int (LATree Int)
makeLATables k graph =
    flip execState M.empty $
    forM_ (M.toList        $
    view nodes graph)      $
    \case
    (idx, node)
        | L.length (nextBrs node) > 1 ->
        modify $ M.insert idx (lookAHeadRoot k graph idx)
    _ -> return ()


flattenLATree :: LATree a -> [([LAEdge], a)]
flattenLATree = \case
    LAEnd xs -> [([], x) | x <- xs]
    LA1 m     ->
        let groups = M.toList m
        in flip concatMap groups $ \(case', la) ->
            let xs = flattenLATree la
            in flip map xs $ ((case':) . fst) &&& snd

data ID3Decision elt cls
    = ID3Split Int [(elt, ID3Decision elt cls)]
    | ID3Leaf [cls]
    deriving (Show, Eq, Ord)

type Offsets = [Int]
type Numbers = [Int]
type PathsOfElements elt = V.Vector (V.Vector elt)
type States cls = V.Vector cls
data DecisionProcess
    = DP {
        _offsets :: [Int],
        _numbers :: [Int]
    }

makeLenses ''DecisionProcess

argmaxBy :: (Foldable f,  Eq o, Ord o) => (a -> o) -> f a -> Int
argmaxBy fn xs =
    let (_, _, selected) = foldl max2 (Nothing, 0, 0) xs
    in fromInteger selected
    where max2 old@(prev, i, selected) new =
            let new' = fn new
            in case prev of
                Nothing -> (Just new', i + 1, i)
                Just prev
                    | new' > prev -> (Just new', i + 1, i)
                    | otherwise -> old

classifInfo :: (Eq cls, Ord elt) => [cls] -> [elt] -> Double
classifInfo clses elts =
    let separated = map (map snd) $ M.elems $ groupBy fst $ zip elts clses
    in sum $ map distinctness separated
    where
        lengthf = fromIntegral . length
        distinctness xs = lengthf (L.nub xs) /  lengthf xs

decideID3 :: (Ord elt, Ord cls) => StateT DecisionProcess (Reader (States cls, PathsOfElements elt)) (ID3Decision elt cls)
decideID3 = do
    offsets' <- gets $ view offsets
    let validOffsets = offsets' -- TODO : necessary
    numbers' <- gets $ view numbers
    (states, paths) <- lift ask
    let states' = V.toList states
    let a = argmaxBy (\j -> classifInfo states' [(paths V.! i) V.! j | i <- numbers']) validOffsets
    error ""

