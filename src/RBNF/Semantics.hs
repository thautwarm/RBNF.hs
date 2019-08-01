{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}

module RBNF.Semantics where

import qualified Data.List as L
import qualified Data.Map as M

import RBNF.Symbols
import RBNF.Grammar

import Control.Monad.State
import Control.Monad.Reader
import Control.Lens (over, view, Lens', makeLenses)



type SlotIdx = Int
data VName =
    Slot SlotIdx
  | Local String
  deriving (Eq, Ord)

instance Show VName where
  show = \case
      Slot i -> "slots["++ show i ++"]"
      Local s -> s

data IR
  = IRAss VName IR
  | IRTuple [IR]
  | IRVar VName
  | IRMkSExp String IR
  | IRCall IR [IR]
  deriving (Eq, Ord)

instance Show IR where
  show = \case
      IRAss i ir ->
          show i ++ " <- " ++ show ir
      IRTuple xs ->
          "(" ++ L.intercalate "," (map show xs) ++ ")"
      IRVar n -> show n
      IRMkSExp n ir -> n ++ "{" ++ show ir ++ "}"
      IRCall f args ->
          let args_str = "(" ++ L.intercalate "," (map show args) ++ ")"
          in show f ++ args_str

type ParsingRoute = [Entity]
data Entity
    = ETerm Case
    | ENonTerm String
    | EPredicate IR
    | EModify IR
    | EBind String IR
    | EProc [IR]
    | EPushScope
    | EPopScope
    deriving (Eq, Ord)

instance Show Entity where
    show = \case
        ETerm c -> show c
        ENonTerm s -> s
        EPredicate p ->
            "pred<" ++ show p ++ ">"
        EModify f ->
            "modify<" ++ show f ++ ">"

maybeShift = \case
    PTerm c -> Just $ ETerm c
    PNonTerm c -> Just $ ENonTerm c
    _ -> Nothing

data Seman = Seman {
        _route    :: ParsingRoute
      , ret       :: SlotIdx
    }
    deriving (Eq, Ord)

makeLenses ''Seman
emptySeman = Seman [] 0

indent n s = replicate n ' ' ++ s
instance Show Seman where
    show Seman {_route, ret} =
        let
            route_Str = unwords $ map (indent 4 . show) _route
        in "parsing route:\n" ++ route_Str ++ "\n" ++
           "return: " ++ show (Slot ret) ++ "\n"

newtype StackObj = SObj Int

data CFG = CFG {
      _pos       :: Int -- >= 0
    , _localN    :: Int -- < 0
    , _stack     :: [StackObj]
}

makeLenses ''CFG
emptyCFG = CFG 0 (-1) []

newObj :: State CFG StackObj
newObj = do
    i <- gets $ view localN
    modify $ over localN (-1 +)
    return $ SObj i

shiftReduce :: State CFG StackObj
shiftReduce = do
    i <- gets $ view pos
    modify $ over pos (+ 1)
    return $ SObj i

push :: StackObj -> State CFG ()
push obj =
    modify $ over stack (obj:)

pop :: State CFG StackObj
pop = do
    stack' <- gets $ view stack
    let hd:tl = stack'
    modify $ over stack $ const tl
    return hd

irOfObj (SObj i) = IRVar $ Slot i
refObj (SObj iL) = IRAss (Slot iL)


miniLangToIR = \case
    MTerm s -> IRVar $ Local s
    MApp f args ->
        let fn = IRVar $ Local f
            args' = map miniLangToIR args
        in IRCall fn args'


analyse' :: Seman -> [P] -> State CFG Seman
analyse' seman = \case
    [] -> do
        stack' <- gets $ view stack
        let [SObj i] = stack'
        return seman {ret = i}
    (maybeShift -> Just x):xs -> do
        obj <- shiftReduce
        push obj
        seman <- analyse' seman xs
        return $ over route (x:) seman
    PBind s:xs -> do
        obj@(SObj i) <- pop
        pos' <- gets $ view pos
        let ir     = irOfObj obj
            seman' = over route (EBind s ir:) seman
        push obj
        analyse' seman' xs
    PModif m:xs -> do
        seman <- analyse' seman xs
        let sideEffect = miniLangToIR m
        return $ over route (EModify sideEffect:) seman
    PPred m:xs -> do
        seman <- analyse' seman xs
        let predProg =  miniLangToIR m
        return $ over route (EPredicate predProg:) seman
    PPushScope:xs ->
        flip analyse' xs $  over route (EPushScope:) seman
    PPopScope:xs ->
        flip analyse' xs $  over route (EPopScope:) seman
    PReduce m n:xs -> do
        tp  <- IRTuple . reverse . map irOfObj <$> replicateM n pop
        obj <- newObj
        push obj
        pos' <- gets $ view pos
        let fn   = miniLangToIR m
            call = IRCall fn [tp]
            prog = EProc [refObj obj call]
            seman' = over route (prog:) seman
        analyse' seman' xs
    PPack n:xs -> do
        tp <- IRTuple . reverse . map irOfObj <$> replicateM n pop
        obj <- newObj
        push obj
        pos' <- gets $ view pos
        let prog   = EProc [refObj obj tp]
            seman' = over route (prog:) seman
        analyse' seman' xs
    PMkSExp s n:xs -> do
        tp <- IRTuple . reverse . map irOfObj <$> replicateM n pop
        obj <- newObj
        push obj
        pos' <- gets $ view pos
        let ir     = IRMkSExp s tp
            prog   = EProc [refObj obj tp]
            seman' = over route (prog:) seman
        analyse' seman' xs

analyse = analyse' emptySeman
pGToSG :: Grammar [P] -> Grammar Seman
pGToSG g =
    let transf lens =
            let f = map $ flip evalState emptyCFG . analyse
            in  M.map f $ view lens g
        prods' = transf prods
        leftR' = transf leftR
    in Grammar prods' leftR'
