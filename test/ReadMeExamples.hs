{-# LANGUAGE OverloadedStrings, TemplateHaskell, UndecidableInstances, GADTs, FlexibleInstances #-}

module ReadMeExamples where

import AST
import AST.Diff
import Data.Text
import Generics.Constraints (makeDerivings)
import GHC.Generics (Generic)

import Prelude

data Expr k
    = Var Text
    | App (k # Expr) (k # Expr)
    | Lam Text (k # Typ) (k # Expr)
    deriving Generic

data Typ k
    = IntT
    | FuncT (k # Typ) (k # Typ)
    deriving Generic

makeDerivings [''Eq, ''Ord, ''Show] [''Expr, ''Typ]
makeKTraversableAndBases ''Expr
makeKTraversableAndBases ''Typ
makeZipMatch ''Expr
makeZipMatch ''Typ
makeKHasPlain [''Expr, ''Typ]

instance RNodes Expr
instance RNodes Typ
instance (c Expr, c Typ) => Recursively c Expr
instance c Typ => Recursively c Typ
instance RTraversable Expr
instance RTraversable Typ

exprA :: KPlain Expr
exprA = LamP "x" IntTP (VarP "x")

exprB :: KPlain Expr
exprB = LamP "x" (FuncTP IntTP IntTP) (VarP "x")

d :: Tree DiffP Expr
d = diffP exprA exprB
