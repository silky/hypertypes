{-# LANGUAGE TemplateHaskellQuotes #-}

module Hyper.TH.Context
    ( makeHContext
    ) where

import qualified Control.Lens as Lens
import           Hyper.Class.Context
import           Hyper.Class.Functor
import           Hyper.Combinator.Func (HFunc(..), _HFunc)
import           Hyper.TH.Internal.Utils
import           Language.Haskell.TH
import           Language.Haskell.TH.Datatype (ConstructorVariant(..))

import           Hyper.Internal.Prelude

makeHContext :: Name -> DecsQ
makeHContext typeName = makeTypeInfo typeName >>= makeHContextForType

makeHContextForType :: TypeInfo -> DecsQ
makeHContextForType info =
    instanceD (simplifyContext (makeContext info)) (appT (conT ''HContext) (pure (tiInstance info)))
    [ InlineP 'hcontext Inline FunLike AllPhases & PragmaD & pure
    , funD 'hcontext (tiConstructors info <&> makeHContextCtr)
    ]
    <&> (:[])

makeContext :: TypeInfo -> [Pred]
makeContext info =
    tiConstructors info ^.. traverse . Lens._3 . traverse . Lens._Right >>= ctxForPat
    where
        ctxForPat (GenEmbed t) = embed t
        ctxForPat (FlatEmbed x) = embed (tiInstance x)
        ctxForPat _ = []
        embed t = [ConT ''HContext `AppT` t, ConT ''HFunctor `AppT` t]

makeHContextCtr ::
    (Name, ConstructorVariant, [Either Type CtrTypePattern]) -> Q Clause
makeHContextCtr (cName, _, []) =
    Clause [ConP cName []] (NormalB (ConE cName)) [] & pure
makeHContextCtr (cName, RecordConstructor fieldNames, cFields) =
    zipWith bodyFor cFields (zip fieldNames cVars)
    & sequenceA
    <&> foldl AppE (ConE cName)
    <&> NormalB
    <&> \x -> Clause [varWhole `AsP` ConP cName (cVars <&> VarP)] x []
    where
        cVars =
            [(0 :: Int) ..] <&> show <&> ("_x" <>) <&> mkName
            & take (length cFields)
        bodyFor Left{} (_, v) = VarE v & pure
        bodyFor (Right Node{}) (f, v) =
            InfixE
            ( Just
                ( ConE 'HFunc `AppE`
                    LamE [VarP varField]
                    ( ConE 'Lens.Const
                        `AppE`
                        RecUpdE (VarE varWhole)
                        [(f, VarE varField)]
                    )
                )
            ) (ConE '(:*:)) (Just (VarE v))
            & pure
        bodyFor _ _ = fail "makeHContext only works for simple record fields"
        varWhole = mkName "_whole"
        varField = mkName "_field"
makeHContextCtr (cName, _, [cField]) =
    bodyFor cField
    <&> AppE (ConE cName)
    <&> NormalB
    <&> \x -> Clause [ConP cName [VarP cVar]] x []
    where
        bodyFor Left{} = VarE cVar & pure
        bodyFor (Right Node{}) =
            InfixE
            (Just (ConE 'HFunc `AppE` (ConE 'Lens.Const `dot` ConE cName)))
            (ConE '(:*:))
            (Just (VarE cVar))
            & pure
        bodyFor (Right GenEmbed{}) = embed
        bodyFor (Right FlatEmbed{}) = embed
        bodyFor _ = fail "makeHContext only works for simple fields"
        embed =
            VarE 'hmap
            `AppE`
            ( VarE 'const `AppE`
                InfixE
                (Just (VarE 'Lens._1 `dot` VarE '_HFunc `dot` VarE 'Lens.mapped `dot` VarE 'Lens._Wrapped))
                (VarE '(Lens.%~))
                (Just (ConE cName))
            ) `AppE` (VarE 'hcontext `AppE` VarE cVar)
            & pure
        cVar = mkName "_c"
makeHContextCtr _ = fail "makeHContext: unsupported constructor"
