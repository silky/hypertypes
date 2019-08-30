-- | Hindley-Milner type inference with ergonomic blame assignment.
--
-- 'blame' is a type-error blame assignment algorithm for languages with Hindley-Milner type inference,
-- but __/without generalization of intermediate terms/__.
-- This means that it is not suitable for languages with let-generalization.
-- 'AST.Term.Let.Let' is an example of a term that is not suitable for this algorithm.
--
-- With the contemporary knowledge that
-- ["Let Should Not Be Generalised"](https://www.microsoft.com/en-us/research/publication/let-should-not-be-generalised/),
-- as argued by luminaries such as Simon Peyton Jones,
-- optimistically this limitation shouldn't apply to new programming languages.
-- This blame assignment algorithm can also be used in a limited sense for existing languages,
-- which do have let-generalization, to provide better type errors
-- in specific definitions which don't happen to use generalizing terms.
--
-- [Lamdu](https://github.com/lamdu/lamdu) uses this algorithm for its "insist type" feature,
-- which moves around the blame for type mismatches.
--
-- Note: If a similar algorithm already existed somewhere,
-- [I](https://github.com/yairchu/) would very much like to know!

{-# LANGUAGE FlexibleContexts, DefaultSignatures, TemplateHaskell, UndecidableInstances, RankNTypes #-}

module AST.Infer.Blame
    ( blame
    , Blamable(..)
    , BTerm(..), InferOf', bAnn, bRes, bVal
    , bTermToAnn
    ) where

import AST
import AST.Class.Infer
import AST.Class.Recursive (recurseBoth)
import AST.Class.Unify (Unify, UVarOf)
import AST.TH.Internal.Instances (makeCommonInstances)
import AST.Unify.Occurs (occursCheck)
import Control.Lens (makeLenses)
import Control.Lens.Operators
import Control.Monad.Except (MonadError(..))
import Data.Constraint (Dict(..), withDict)
import Data.Foldable (traverse_)
import Data.List (sortOn)
import Data.Proxy (Proxy(..))
import GHC.Generics (Generic)

import Prelude.Compat

-- | Class implementing some primitives needed by the 'blame' algorithm
--
-- The 'blamableRecursive' method represents that 'Blamable' applies to all recursive child nodes.
-- It replaces context for 'Blamable' to avoid `UndecidableSuperClasses`.
class
    (Infer m t, RTraversable t, KTraversable (InferOf t)) =>
    Blamable m t where

    -- | Create a new unbound infer result.
    --
    -- The type or values within should be unbound unification variables.
    inferOfNewUnbound ::
        Proxy t ->
        m (Tree (InferOf t) (UVarOf m))

    -- | Unify the types/values in infer results
    inferOfUnify ::
        Proxy t ->
        Tree (InferOf t) (UVarOf m) ->
        Tree (InferOf t) (UVarOf m) ->
        m ()

    -- | Check whether two infer results are the same
    inferOfMatches ::
        Proxy t ->
        Tree (InferOf t) (UVarOf m) ->
        Tree (InferOf t) (UVarOf m) ->
        m Bool

    -- TODO: Putting documentation here causes duplication in the haddock documentation
    blamableRecursive ::
        Proxy m -> Proxy t -> Dict (NodesConstraint t (Blamable m))
    {-# INLINE blamableRecursive #-}
    default blamableRecursive ::
        NodesConstraint t (Blamable m) =>
        Proxy m -> Proxy t -> Dict (NodesConstraint t (Blamable m))
    blamableRecursive _ _ = Dict

instance Recursive (Blamable m) where
    recurse p =
        blamableRecursive
        ((const Proxy :: p (b m t) -> Proxy m) p)
        ((const Proxy :: p (b m t) -> Proxy t) p)

-- | A type synonym to help 'BTerm' be more succinct
type InferOf' e v = Tree (InferOf (RunKnot e)) v

-- Internal Knot for the blame algorithm
data PTerm a v e = PTerm
    { pAnn :: a
    , pInferResultFromPos :: InferOf' e v
    , pInferResultFromSelf :: InferOf' e v
    , pBody :: Node e (PTerm a v)
    }

prepare ::
    forall m exp a.
    Blamable m exp =>
    Tree (Ann a) exp ->
    m (Tree (PTerm a (UVarOf m)) exp)
prepare (Ann a x) =
    withDict (recurse (Proxy @(Blamable m exp))) $
    do
        resFromPosition <- inferOfNewUnbound (Proxy @exp)
        (xI, r) <-
            mapKWith (Proxy @(Blamable m))
            (InferChild . fmap (\t -> InferredChild t (pInferResultFromPos t)) . prepare)
            x
            & inferBody
        pure PTerm
            { pAnn = a
            , pInferResultFromPos = resFromPosition
            , pInferResultFromSelf = r
            , pBody = xI
            }

tryUnify ::
    forall exp m.
    Blamable m exp =>
    Proxy exp ->
    Tree (InferOf exp) (UVarOf m) ->
    Tree (InferOf exp) (UVarOf m) ->
    m ()
tryUnify p i0 i1 =
    withDict (inferContext (Proxy @m) p) $
    do
        inferOfUnify p i0 i1
        traverseKWith_ (Proxy @(Unify m)) occursCheck i0

toUnifies ::
    forall a m exp.
    Blamable m exp =>
    Tree (PTerm a (UVarOf m)) exp ->
    Tree (Ann (a, m ())) exp
toUnifies (PTerm a i0 i1 b) =
    withDict (recurse (Proxy @(Blamable m exp))) $
    mapKWith (Proxy @(Blamable m)) toUnifies b
    & Ann (a, tryUnify (Proxy @exp) i0 i1)

-- | A 'Knot' for an inferred term with type mismatches - the output of 'blame'
data BTerm a v e = BTerm
    { _bAnn :: a
        -- ^ The node's original annotation as passed to 'blame'
    , _bRes :: Either (InferOf' e v, InferOf' e v) (InferOf' e v)
        -- ^ Either an infer result, or two conflicting results representing a type mismatch
    , _bVal :: Node e (BTerm a v)
        -- ^ The node's body and its inferred child nodes
    } deriving Generic
makeLenses ''BTerm
makeCommonInstances [''BTerm]

finalize ::
    forall a m exp.
    Blamable m exp =>
    Tree (PTerm a (UVarOf m)) exp ->
    m (Tree (BTerm a (UVarOf m)) exp)
finalize (PTerm a i0 i1 x) =
    withDict (recurse (Proxy @(Blamable m exp))) $
    do
        match <- inferOfMatches (Proxy @exp) i0 i1
        let result
                | match = Right i0
                | otherwise = Left (i0, i1)
        traverseKWith (Proxy @(Blamable m)) finalize x
            <&> BTerm a result

-- | Perform Hindley-Milner type inference with prioritised blame for type error,
-- given a prioritisation for the different nodes.
--
-- The purpose of the prioritisation is to place the errors in nodes where
-- the resulting errors will be easier to understand.
--
-- The expected `MonadError` behavior is that catching errors rolls back their state changes
-- (i.e @StateT s (Either e)@ is suitable but @EitherT e (State s)@ is not)
blame ::
    forall priority err m exp a.
    ( Ord priority
    , MonadError err m
    , Blamable m exp
    ) =>
    (a -> priority) ->
    Tree (Ann a) exp ->
    m (Tree (BTerm a (UVarOf m)) exp)
blame order e =
    do
        p <- prepare e
        toUnifies p ^.. annotations & sortOn (order . fst) & traverse_ snd
        finalize p

-- | Convert a 'BTerm' to a simple annotated tree with the same annotation type for all nodes
bTermToAnn ::
    forall f e a v r c.
    (Applicative f, RTraversable e, c e, Recursive c) =>
    Proxy c ->
    (forall n. c n => Proxy n -> Either (Tree (InferOf n) v, Tree (InferOf n) v) (Tree (InferOf n) v) -> f r) ->
    Tree (BTerm a v) e ->
    f (Tree (Ann (a, r)) e)
bTermToAnn p f (BTerm a i x) =
    withDict (recurseBoth (Proxy @(And RTraversable c e))) $
    (\r b -> Ann (a, r) b)
    <$> f (Proxy @e) i
    <*> traverseKWith (Proxy @(And RTraversable c)) (bTermToAnn p f) x
