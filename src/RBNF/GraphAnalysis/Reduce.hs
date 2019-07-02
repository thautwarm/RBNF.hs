{-# LANGUAGE LambdaCase #-}
module RBNF.GraphAnalysis.Reduce where
import RBNF.Semantics
import RBNF.GraphAnalysis.IRs

import qualified Data.Map as M
import qualified Data.Set as S
import Control.Monad.State
import Control.Arrow

groupNodes =
    let f = \case
            [] -> errorWithoutStackTrace "Invalid groupNodes"
            x:xs -> (x, [xs])
    in M.fromListWith (++) . map f

unique [] = []
unique (x : xs) =
    unique' (S.singleton x) [x] xs
    where
        unique' occurred xs [] = reverse xs
        unique' occurred xs (hd:tl) =
            let
                (occurred', xs') =
                    if hd `notElem` occurred
                    then (S.insert hd occurred, hd:xs)
                    else (occurred, xs)
            in unique' occurred' xs' tl

reduce :: ExpandedGraph -> State ReducedGraph ()
reduce ctx =
    forM_ (M.toList ctx) reduceRoot
    where
        reduceRoot :: (String, [ExpandedNodes]) -> State ReducedGraph ()
        reduceRoot (rootName, branches) =
            let
                reduceEach :: [ExpandedNodes] -> State ReducedGraph ()
                reduceEach = \case
                    [] -> errorWithoutStackTrace  "Cannot reduce an empty node chain"
                    xs ->
                        let groups = M.toList $ groupNodes xs
                        in  forM_ groups $ genRule rootName
            in reduceEach branches

        genRule :: String -> (ExpandedNode, [ExpandedNodes]) -> State ReducedGraph ReducedNode
        genRule rootName (RefE rootName', branches) = do
            rgraph <- get
            if M.member rootName rgraph
                
            -- already been generated
            then
                return ()
            else if rootName' == rootName
            -- left recursion
            then
                addLRRule rootName branches
            else error ""

            -- addEps . unique $ branches

        addLRRule = error ""
        addEps :: [ExpandedNodes] -> [ExpandedNodes]
        addEps = \case
            []    -> []
            []:xs -> [EpsE]:addEps xs
            x:xs  -> x:addEps xs

        mergeCases = error ""
        mergeCase EpsE elts = error ""


