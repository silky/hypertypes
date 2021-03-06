{-# LANGUAGE TemplateHaskellQuotes #-}

-- | Generate 'ZipMatch' instances via @TemplateHaskell@

module Hyper.TH.ZipMatch
    ( makeZipMatch
    ) where

import Hyper.Class.ZipMatch (ZipMatch(..))
import Hyper.TH.Internal.Utils
import Language.Haskell.TH
import Language.Haskell.TH.Datatype (ConstructorVariant)

import Hyper.Internal.Prelude

-- | Generate a 'ZipMatch' instance
makeZipMatch :: Name -> DecsQ
makeZipMatch typeName =
    do
        info <- makeTypeInfo typeName
        -- (dst, var) <- parts info
        let ctrs = tiConstructors info <&> makeZipMatchCtr
        instanceD
            (simplifyContext (ctrs >>= ccContext))
            (appT (conT ''ZipMatch) (pure (tiInstance info)))
            [ InlineP 'zipMatch Inline FunLike AllPhases & PragmaD & pure
            , funD 'zipMatch
                ( (ctrs <&> pure . ccClause) ++ [pure tailClause]
                )
            ]
            <&> (:[])
    where
        tailClause = Clause [WildP, WildP] (NormalB (ConE 'Nothing)) []

data CtrCase =
    CtrCase
    { ccClause :: Clause
    , ccContext :: [Pred]
    }

makeZipMatchCtr :: (Name, ConstructorVariant, [Either Type CtrTypePattern]) -> CtrCase
makeZipMatchCtr (cName, _, cFields) =
    CtrCase
    { ccClause = Clause [con fst, con snd] body []
    , ccContext = fieldParts >>= zmfContext
    }
    where
        con f = ConP cName (cVars <&> f <&> VarP)
        cVars =
            [0::Int ..] <&> show <&> (\n -> (mkName ('x':n), mkName ('y':n)))
            & take (length cFields)
        body
            | null checks = NormalB bodyExp
            | otherwise = GuardedB [(NormalG (foldl1 mkAnd checks), bodyExp)]
        checks = fieldParts >>= zmfConds
        mkAnd x y = InfixE (Just x) (VarE '(&&)) (Just y)
        fieldParts = zipWith field cVars cFields
        bodyExp = applicativeStyle (ConE cName) (fieldParts <&> zmfResult)
        field (x, y) (Right Node{}) =
            ZipMatchField
            { zmfResult = ConE 'Just `AppE` (ConE '(:*:) `AppE` VarE x `AppE` VarE y)
            , zmfConds = []
            , zmfContext = []
            }
        field (x, y) (Right (GenEmbed t)) = embed t x y
        field (x, y) (Right (FlatEmbed t)) = embed (tiInstance t) x y
        field _ (Right InContainer{}) = error "TODO"
        field (x, y) (Left t) =
            ZipMatchField
            { zmfResult = ConE 'Just `AppE` VarE x
            , zmfConds = [InfixE (Just (VarE x)) (VarE '(==)) (Just (VarE y))]
            , zmfContext = [ConT ''Eq `AppT` t]
            }
        embed t x y =
            ZipMatchField
            { zmfResult = VarE 'zipMatch `AppE` VarE x `AppE` VarE y
            , zmfConds = []
            , zmfContext = [ConT ''ZipMatch `AppT` t]
            }

data ZipMatchField = ZipMatchField
    { zmfResult :: Exp
    , zmfConds :: [Exp]
    , zmfContext :: [Pred]
    }
