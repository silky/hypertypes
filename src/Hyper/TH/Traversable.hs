{-# LANGUAGE TemplateHaskellQuotes #-}

-- | Generate 'HTraversable' and related instances via @TemplateHaskell@

module Hyper.TH.Traversable
    ( makeHTraversable
    , makeHTraversableAndFoldable
    , makeHTraversableAndBases
    , makeHTraversableApplyAndBases
    ) where

import qualified Control.Lens as Lens
import           Hyper.Class.Traversable
import           Hyper.TH.Apply (makeHApplicativeBases)
import           Hyper.TH.Foldable (makeHFoldable)
import           Hyper.TH.Functor (makeHFunctor)
import           Hyper.TH.Internal.Utils
import           Hyper.TH.Nodes (makeHNodes)
import           Language.Haskell.TH
import           Language.Haskell.TH.Datatype (ConstructorVariant)

import           Hyper.Internal.Prelude

-- | Generate 'HTraversable' and 'Hyper.Class.Apply.HApply' instances along with all of their base classes:
-- 'Hyper.Class.Foldable.HFoldable', 'Hyper.Class.Functor.HFunctor',
-- 'Hyper.Class.Pointed.HPointed', and 'Hyper.Class.Nodes.HNodes'.
makeHTraversableApplyAndBases :: Name -> DecsQ
makeHTraversableApplyAndBases x =
    sequenceA
    [ makeHApplicativeBases x
    , makeHTraversableAndFoldable x
    ] <&> concat

-- | Generate a 'HTraversable' instance along with the instance of its base classes:
-- 'Hyper.Class.Foldable.HFoldable', 'Hyper.Class.Functor.HFunctor', and 'Hyper.Class.Nodes.HNodes'.
makeHTraversableAndBases :: Name -> DecsQ
makeHTraversableAndBases x =
    sequenceA
    [ makeHNodes x
    , makeHFunctor x
    , makeHTraversableAndFoldable x
    ] <&> concat

-- | Generate 'HTraversable' and 'Hyper.Class.Foldable.HFoldable' instances
makeHTraversableAndFoldable :: Name -> DecsQ
makeHTraversableAndFoldable x =
    sequenceA
    [ makeHFoldable x
    , makeHTraversable x
    ] <&> concat

-- | Generate a 'HTraversable' instance
makeHTraversable :: Name -> DecsQ
makeHTraversable typeName = makeTypeInfo typeName >>= makeHTraversableForType

makeHTraversableForType :: TypeInfo -> DecsQ
makeHTraversableForType info =
    instanceD (simplifyContext (makeContext info)) (appT (conT ''HTraversable) (pure (tiInstance info)))
    [ InlineP 'hsequence Inline FunLike AllPhases & PragmaD & pure
    , funD 'hsequence (tiConstructors info <&> pure . makeCons)
    ]
    <&> (:[])

makeContext :: TypeInfo -> [Pred]
makeContext info =
    tiConstructors info ^.. traverse . Lens._3 . traverse . Lens._Right >>= ctxForPat
    where
        ctxForPat (InContainer t pat) = (ConT ''Traversable `AppT` t) : ctxForPat pat
        ctxForPat (GenEmbed t) = [ConT ''HTraversable `AppT` t]
        ctxForPat _ = []

makeCons ::
    (Name, ConstructorVariant, [Either Type CtrTypePattern]) -> Clause
makeCons (cName, _, cFields) =
    Clause [consPat cName consVars] body []
    where
        body =
            consVars <&> f
            & applicativeStyle (ConE cName)
            & NormalB
        consVars = makeConstructorVars "x" cFields
        f (pat, name) = bodyFor pat `AppE` VarE name
        bodyFor (Right x) = bodyForPat x
        bodyFor Left{} = VarE 'pure
        bodyForPat Node{} = VarE 'runContainedH
        bodyForPat FlatEmbed{} = VarE 'hsequence
        bodyForPat GenEmbed{} = VarE 'hsequence
        bodyForPat (InContainer _ pat) = VarE 'traverse `AppE` bodyForPat pat
