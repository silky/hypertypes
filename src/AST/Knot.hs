{-# LANGUAGE NoImplicitPrelude, DataKinds, TypeFamilies #-}

module AST.Knot
    ( Knot(..), RunKnot
    , Tie, Tree
    , asTree
    , ChildrenTypesOf
    ) where

import Data.Kind (Type)

import Prelude.Compat

newtype Knot = Knot (Knot -> Type)

type family RunKnot (knot :: Knot) = (r :: Knot -> Type) where
    RunKnot ('Knot t) = t

-- Notes about `RunKnot`:
-- * Its inputs are constrained to shape of `'Knot a`
-- * It is injective (`| r -> knot`), but due to no support for constrained type families it's not expressible atm:
--   (see https://ghc.haskell.org/trac/ghc/ticket/15691)
--
-- Because `RunKnot` can't declared as bijective, uses of it may block inferences.
-- In those cases wrapping terms with the `asTree` helper makes the type inference
-- overcome the `RunKnot` block.

type Tree k t = k ('Knot t)

asTree :: Tree p q -> Tree p q
asTree = id

type Tie knot ast = Tree (RunKnot knot) ast

-- | A type family for the different types of children a knot has.
-- Maps to a simple knot which has a single child of each child type.
type family ChildrenTypesOf (knot :: Knot -> Type) :: Knot -> Type
