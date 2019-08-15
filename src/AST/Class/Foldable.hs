{-# LANGUAGE ScopedTypeVariables, RankNTypes #-}

module AST.Class.Foldable
    ( KFoldable(..)
    , ConvertK(..), _ConvertK
    , foldMapK, foldMapKWith
    , traverseK_, traverseKWith_
    , sequenceLiftK2_, sequenceLiftK2With_
    ) where

import AST.Class
import AST.Class.Combinators (KLiftConstraints(..), liftK2With)
import AST.Knot (Tree, Knot)
import Control.Lens (Iso, iso)
import Control.Lens.Operators
import Data.Foldable (sequenceA_)
import Data.Functor.Const (Const(..))
import Data.Constraint (withDict)
import Data.Constraint.List (ApplyConstraints)
import Data.Proxy (Proxy(..))
import Data.TyFun

import Prelude.Compat

newtype ConvertK a l (k :: Knot) = MkConvertK { runConvertK :: l k -> a }

{-# INLINE _ConvertK #-}
_ConvertK ::
    Iso (Tree (ConvertK a0 l0) k0)
        (Tree (ConvertK a1 l1) k1)
        (Tree l0 k0 -> a0)
        (Tree l1 k1 -> a1)
_ConvertK = iso runConvertK MkConvertK

class KNodes k => KFoldable k where
    foldMapC ::
        Monoid a =>
        Tree (NodeTypesOf k) (ConvertK a l) ->
        Tree k l ->
        a

instance KFoldable (Const a) where
    {-# INLINE foldMapC #-}
    foldMapC _ _ = mempty

{-# INLINE foldMapK #-}
foldMapK ::
    forall a k l.
    (Monoid a, KFoldable k) =>
    (forall c. Tree l c -> a) ->
    Tree k l ->
    a
foldMapK f x =
    withDict (kNodes (Proxy @k)) $
    foldMapC (pureK (MkConvertK f)) x

{-# INLINE foldMapKWith #-}
foldMapKWith ::
    forall a k n constraint.
    (Monoid a, KFoldable k, NodesConstraint k $ constraint) =>
    Proxy constraint ->
    (forall child. constraint child => Tree n child -> a) ->
    Tree k n ->
    a
foldMapKWith p f =
    withDict (kNodes (Proxy @k)) $
    foldMapC (pureKWithConstraint p (_ConvertK # f))

{-# INLINE traverseK_ #-}
traverseK_ ::
    (Applicative f, KFoldable k) =>
    (forall c. Tree m c -> f ()) ->
    Tree k m ->
    f ()
traverseK_ f = sequenceA_ . foldMapK ((:[]) . f)

{-# INLINE traverseKWith_ #-}
traverseKWith_ ::
    forall f k constraint m.
    (Applicative f, KFoldable k, NodesConstraint k $ constraint) =>
    Proxy constraint ->
    (forall c. constraint c => Tree m c -> f ()) ->
    Tree k m ->
    f ()
traverseKWith_ p f =
    sequenceA_ . foldMapKWith @[f ()] p ((:[]) . f)

{-# INLINE sequenceLiftK2_ #-}
sequenceLiftK2_ ::
    (Applicative f, KApply k, KFoldable k) =>
    (forall c. Tree l c -> Tree m c -> f ()) ->
    Tree k l ->
    Tree k m ->
    f ()
sequenceLiftK2_ f x =
    sequenceA_ . foldMapK ((:[]) . getConst) . liftK2 (\a -> Const . f a) x

{-# INLINE sequenceLiftK2With_ #-}
sequenceLiftK2With_ ::
    forall f k constraints l m.
    (Applicative f, KApply k, KFoldable k, KLiftConstraints constraints k) =>
    Proxy constraints ->
    (forall c. ApplyConstraints constraints c => Tree l c -> Tree m c -> f ()) ->
    Tree k l ->
    Tree k m ->
    f ()
sequenceLiftK2With_ p f x =
    sequenceA_ . foldMapK @[f ()] ((:[]) . getConst) . liftK2With p (\a -> Const . f a) x
