{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE LambdaCase #-}
module Main where

import           RBNF                           ( parserGen )
import           RBNF.Serialization
import           RBNF.IRs.Marisa
import           RBNF.IRs.Reimu
import           RBNF.TypeSystem
import           RBNF.BackEnds.TargetGen
import           RBNF.FrontEnd
import           System.IO
import           System.Environment
import           System.Exit
import           Control.Lens

import           Data.Text.Prettyprint.Doc      ( Doc
                                                , layoutPretty
                                                , defaultLayoutOptions
                                                )
import           Data.Text.Prettyprint.Doc.Render.Text
                                                ( renderStrict )
import           Data.Text.Prettyprint.Doc.Util
import qualified Data.Text.IO                  as T
import qualified Data.Text                     as T
import qualified Data.Map                      as M

data Flag
    = Aeson String
    | Dump

main = getArgs >>= wain

parseOptsKey m = \case
    "-h"      : xs -> parseOptsKey (M.insert "h" "" m) xs
    "-v"      : xs -> parseOptsKey (M.insert "v" "" m) xs
    "-be"     : xs -> parseOptVal "be" m xs
    "-out"    : xs -> parseOptVal "out" m xs
    "-in"     : xs -> parseOptVal "in" m xs
    "-k"      : xs -> parseOptVal "k" m xs
    "--trace" : xs -> parseOptsKey (M.insert "trace" "" m) xs
    "--noinline":xs -> parseOptsKey (M.insert "noinline" "" m) xs
    k         : xs -> Left k
    []             -> Right m

parseOptVal k m = \case
    v : xs -> parseOptsKey (M.insert k v m) xs
    []     -> Left k

doc2Text :: Doc ann -> T.Text
doc2Text = renderStrict . layoutPretty defaultLayoutOptions


backendGen :: Marisa -> String -> IO T.Text
backendGen marisa backend = case backend of
    "marisa" -> return . doc2Text . seeMarisa $ marisa
    "ocaml" ->
        let ocaml = emit marisa :: Doc OCamlBackEnd in return $ doc2Text ocaml
    "python" ->
        let python = emit marisa :: Doc PythonBackEnd
        in  return $ doc2Text python
    a -> putStrLn ("Unknown back end " ++ a) >> exitFailure

wain xs = case parseOptsKey M.empty xs of
    Left  k -> putStrLn $ "Error in key " ++ k ++ "."
    Right m -> do
        may_print_help
        may_print_ver
        k     <- k
        inStr <- inStr
        ast   <- case parseDoc inStr of
            Left  err    -> putStrLn err >> exitFailure
            Right (a, s) -> return a
        let marisa = parserGen doInline k trace ast
        text <- backendGen marisa $ case M.lookup "be" m of
            Just a  -> a
            Nothing -> "marisa"
        outf <- outf
        if outf == "stdout" then T.putStrLn text else T.writeFile outf text
      where
        doInline | "noinline" `M.member` m = False
                 | otherwise = True
        help = usage >> exit
        may_print_help :: IO ()
        may_print_help | "h" `M.member` m = help >> exitSuccess
                       | otherwise        = return ()
        may_print_ver :: IO ()
        may_print_ver | "v" `M.member` m = version >> exitSuccess
                      | otherwise        = return ()
        inStr :: IO String
        inStr = case M.lookup "in" m of
            Just fname -> readFile fname
            _          -> putStrLn "Input file not specified." >> exitFailure
        outf :: IO String
        outf = case M.lookup "out" m of
            Just a -> return a
            _      -> putStrLn "Output file not specified." >> exitFailure

        k :: IO Int
        k = case fmap read $ M.lookup "k" m of
            Just i  -> return i
            Nothing -> putStrLn "Lookahead K not specified." >> exitFailure

        trace :: Bool
        trace = "trace" `M.member` m


usage =
    putStrLn $
        "Usage: [-v] [-h] [-in filename] [-out filename]\n" ++
        "[-be python|ocaml|marisa(default)]\n" ++
        "[-k lookahead number] [--trace : codegen with tracebacks.]"
version = putStrLn "2.0"
exit = exitSuccess
