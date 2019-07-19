{-# LANGUAGE NoImplicitPrelude, TemplateHaskellQuotes #-}

module AST.Class.Traversable.TH
    ( makeKTraversable
    , makeKTraversableAndFoldable
    , makeKTraversableAndBases
    ) where

import           AST.Class.Foldable.TH (makeKFoldable)
import           AST.Class.Functor.TH (makeKFunctor)
import           AST.Class.Traversable
import           AST.Internal.TH
import           Control.Lens.Operators
import           Language.Haskell.TH
import qualified Language.Haskell.TH.Datatype as D

import           Prelude.Compat

makeKTraversableAndBases :: Name -> DecsQ
makeKTraversableAndBases x =
    sequenceA
    [ makeKFunctor x
    , makeKTraversableAndFoldable x
    ] <&> concat

makeKTraversableAndFoldable :: Name -> DecsQ
makeKTraversableAndFoldable x =
    sequenceA
    [ makeKFoldable x
    , makeKTraversable x
    ] <&> concat

makeKTraversable :: Name -> DecsQ
makeKTraversable typeName = makeTypeInfo typeName >>= makeKTraversableForType

makeKTraversableForType :: TypeInfo -> DecsQ
makeKTraversableForType info =
    instanceD (pure (makeContext info)) (appT (conT ''KTraversable) (pure (tiInstance info)))
    [ InlineP 'sequenceC Inline FunLike AllPhases & PragmaD & pure
    , funD 'sequenceC (tiCons info <&> pure . makeCons (tiVar info))
    ]
    <&> (:[])

makeContext :: TypeInfo -> [Pred]
makeContext info =
    tiCons info
    >>= D.constructorFields
    <&> matchType (tiVar info)
    >>= ctxForPat
    where
        ctxForPat (Tof t pat) = [ConT ''Traversable `AppT` t | isPolymorphicContainer t] <> ctxForPat pat
        ctxForPat (XofF t) = [ConT ''KTraversable `AppT` t | isPolymorphic t]
        ctxForPat _ = []

makeCons ::
    Name -> D.ConstructorInfo -> Clause
makeCons knot cons =
    Clause [consPat cons consVars] body []
    where
        body =
            consVars <&> f
            & applicativeStyle (ConE (D.constructorName cons))
            & NormalB
        consVars = makeConstructorVars "x" cons
        f (typ, name) = bodyForPat (matchType knot typ) `AppE` VarE name
        bodyForPat NodeFofX{} = VarE 'runContainedK
        bodyForPat XofF{} = VarE 'sequenceC
        bodyForPat (Tof _ pat) = VarE 'traverse `AppE` bodyForPat pat
        bodyForPat Other{} = VarE 'pure
