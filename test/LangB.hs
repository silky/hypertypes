{-# LANGUAGE TemplateHaskell, MultiParamTypeClasses, TypeFamilies, LambdaCase #-}
{-# LANGUAGE FlexibleInstances, UndecidableInstances, TupleSections, DataKinds #-}
{-# LANGUAGE ScopedTypeVariables, GeneralizedNewtypeDeriving, ConstraintKinds #-}
{-# LANGUAGE StandaloneDeriving, DerivingStrategies #-}

module LangB where

import           TypeLang

import           AST
import           AST.Class.Unify
import           AST.Knot.Flip
import           AST.Infer
import           AST.Term.Apply
import           AST.Term.Lam
import           AST.Term.Let
import           AST.Term.Nominal
import           AST.Term.Row
import           AST.Term.Var
import           AST.Unify
import           AST.Unify.Binding
import           AST.Unify.Binding.ST
import           AST.Unify.Generalize
import           AST.Unify.Term
import           Control.Applicative
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Control.Monad.Except
import           Control.Monad.RWS
import           Control.Monad.Reader
import           Control.Monad.ST
import           Control.Monad.ST.Class (MonadST(..))
import           Data.Constraint
import           Data.Map (Map)
import           Data.Proxy
import           Data.STRef
import           Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

data LangB k
    = BLit Int
    | BApp (Apply LangB k)
    | BVar (Var Name LangB k)
    | BLam (Lam Name LangB k)
    | BLet (Let Name LangB k)
    | BRecEmpty
    | BRecExtend (RowExtend Name LangB LangB k)
    | BGetField (Tie k LangB) Name
    | BToNom (ToNom Name LangB k)

makeChildren ''LangB
instance Recursive Children LangB

type instance TypeOf LangB = Typ
type instance ScopeOf LangB = ScopeTypes

instance Pretty (Tree LangB Pure) where
    pPrintPrec _ _ (BLit i) = pPrint i
    pPrintPrec _ _ BRecEmpty = Pretty.text "{}"
    pPrintPrec lvl p (BRecExtend (RowExtend k v r)) =
        pPrintPrec lvl 20 k <+>
        Pretty.text "=" <+>
        (pPrintPrec lvl 2 v <> Pretty.text ",") <+>
        pPrintPrec lvl 1 r
        & maybeParens (p > 1)
    pPrintPrec lvl p (BApp x) = pPrintPrec lvl p x
    pPrintPrec lvl p (BVar x) = pPrintPrec lvl p x
    pPrintPrec lvl p (BLam x) = pPrintPrec lvl p x
    pPrintPrec lvl p (BLet x) = pPrintPrec lvl p x
    pPrintPrec lvl p (BGetField w k) =
        pPrintPrec lvl p w <> Pretty.text "." <> pPrint k
    pPrintPrec lvl p (BToNom n) = pPrintPrec lvl p n

instance VarType Name LangB where
    varType _ k (ScopeTypes t) = t ^?! Lens.ix k & instantiate

instance
    ( MonadScopeLevel m
    , LocalScopeType Name (Tree (UVarOf m) Typ) m
    , LocalScopeType Name (Tree (GTerm (UVarOf m)) Typ) m
    , Unify m Typ, Unify m Row
    , HasScope m ScopeTypes
    , MonadNominals Name Typ m
    ) =>
    Infer m LangB where

    inferBody (BApp x) = inferBody x <&> _2 %~ BApp
    inferBody (BVar x) = inferBody x <&> _2 %~ BVar
    inferBody (BLam x) = inferBody x <&> _2 %~ BLam
    inferBody (BLet x) = inferBody x <&> _2 %~ BLet
    inferBody (BLit x) = newTerm TInt <&> (, BLit x)
    inferBody (BToNom x) = inferBody x <&> _2 %~ BToNom
    inferBody (BRecExtend (RowExtend k v r)) =
        withDict (recursive :: RecursiveDict (Unify m) Typ) $
        do
            vI <- infer v
            rI <- infer r
            restR <-
                scopeConstraints <&> rForbiddenFields . Lens.contains k .~ True
                >>= newVar binding . UUnbound
            _ <- TRec restR & newTerm >>= unify (rI ^. iType)
            RowExtend k (vI ^. iType) restR & RExtend & newTerm
                >>= newTerm . TRec
                <&> (, BRecExtend (RowExtend k vI rI))
    inferBody BRecEmpty =
        withDict (recursive :: RecursiveDict (Unify m) Typ) $
        newTerm REmpty >>= newTerm . TRec <&> (, BRecEmpty)
    inferBody (BGetField w k) =
        do
            (rT, wR) <- rowElementInfer RExtend k
            wI <- infer w
            _ <- TRec wR & newTerm >>= unify (wI ^. iType)
            pure (rT, BGetField wI k)

instance (c Typ, c Row) => Recursive (InferChildConstraints (Recursive c)) LangB

-- Monads for inferring `LangB`:

newtype ScopeTypes v = ScopeTypes (Map Name (Tree (GTerm (RunKnot v)) Typ))
    deriving newtype (Semigroup, Monoid)
Lens.makePrisms ''ScopeTypes

instance Children ScopeTypes where
    type ChildrenConstraint ScopeTypes c = (c Typ, c Row)
    children p f =
        children p f
        & Lens.from _Flip
        & traverse
        & _ScopeTypes

data InferScope v = InferScope
    { _varSchemes :: Tree ScopeTypes v
    , _scopeLevel :: ScopeLevel
    , _nominals :: Map Name (Tree (LoadedNominalDecl Typ) v)
    }
Lens.makeLenses ''InferScope

emptyInferScope :: InferScope v
emptyInferScope = InferScope mempty (ScopeLevel 0) mempty

newtype PureInferB a =
    PureInferB
    ( RWST (InferScope UVar) () PureInferState
        (Either (Tree TypeError Pure)) a
    )
    deriving newtype
    ( Functor, Applicative, Monad
    , MonadError (Tree TypeError Pure)
    , MonadReader (InferScope UVar)
    , MonadState PureInferState
    )

Lens.makePrisms ''PureInferB

execPureInferB :: PureInferB a -> Either (Tree TypeError Pure) a
execPureInferB act =
    runRWST (act ^. _PureInferB) emptyInferScope emptyPureInferState
    <&> (^. Lens._1)

type instance UVarOf PureInferB = UVar

instance MonadNominals Name Typ PureInferB where
    getNominalDecl name = Lens.view nominals <&> (^?! Lens.ix name)

instance HasScope PureInferB ScopeTypes where
    getScope = Lens.view varSchemes

instance LocalScopeType Name (Tree UVar Typ) PureInferB where
    localScopeType k v = local (varSchemes . _ScopeTypes . Lens.at k ?~ GMono v)

instance LocalScopeType Name (Tree (GTerm UVar) Typ) PureInferB where
    localScopeType k v = local (varSchemes . _ScopeTypes . Lens.at k ?~ v)

instance MonadScopeLevel PureInferB where
    localLevel = local (scopeLevel . _ScopeLevel +~ 1)

instance MonadScopeConstraints ScopeLevel PureInferB where
    scopeConstraints = Lens.view scopeLevel

instance MonadScopeConstraints RConstraints PureInferB where
    scopeConstraints = Lens.view scopeLevel <&> RowConstraints mempty

instance MonadQuantify ScopeLevel Name PureInferB where
    newQuantifiedVariable _ =
        Lens._2 . tTyp . _UVar <<+= 1 <&> Name . ('t':) . show

instance MonadQuantify RConstraints Name PureInferB where
    newQuantifiedVariable _ =
        Lens._2 . tRow . _UVar <<+= 1 <&> Name . ('r':) . show

instance Unify PureInferB Typ where
    binding = bindingDict (Lens._1 . tTyp)
    unifyError e =
        children (Proxy :: Proxy (Recursive (Unify PureInferB))) applyBindings e
        >>= throwError . TypError

instance Unify PureInferB Row where
    binding = bindingDict (Lens._1 . tRow)
    structureMismatch = rStructureMismatch
    unifyError e =
        children (Proxy :: Proxy (Recursive (Unify PureInferB))) applyBindings e
        >>= throwError . RowError

newtype STInferB s a =
    STInferB
    (ReaderT (InferScope (STUVar s), STNameGen s)
        (ExceptT (Tree TypeError Pure) (ST s)) a)
    deriving newtype
    ( Functor, Applicative, Monad, MonadST
    , MonadError (Tree TypeError Pure)
    , MonadReader (InferScope (STUVar s), STNameGen s)
    )

Lens.makePrisms ''STInferB

execSTInferB :: STInferB s a -> ST s (Either (Tree TypeError Pure) a)
execSTInferB act =
    do
        qvarGen <- Types <$> (newSTRef 0 <&> Const) <*> (newSTRef 0 <&> Const)
        runReaderT (act ^. _STInferB) (emptyInferScope, qvarGen) & runExceptT

type instance UVarOf (STInferB s) = STUVar s

instance MonadNominals Name Typ (STInferB s) where
    getNominalDecl name = Lens.view (Lens._1 . nominals) <&> (^?! Lens.ix name)

instance HasScope (STInferB s) ScopeTypes where
    getScope = Lens.view (Lens._1 . varSchemes)

instance LocalScopeType Name (Tree (STUVar s) Typ) (STInferB s) where
    localScopeType k v = local (Lens._1 . varSchemes . _ScopeTypes . Lens.at k ?~ GMono v)

instance LocalScopeType Name (Tree (GTerm (STUVar s)) Typ) (STInferB s) where
    localScopeType k v = local (Lens._1 . varSchemes . _ScopeTypes . Lens.at k ?~ v)

instance MonadScopeLevel (STInferB s) where
    localLevel = local (Lens._1 . scopeLevel . _ScopeLevel +~ 1)

instance MonadScopeConstraints ScopeLevel (STInferB s) where
    scopeConstraints = Lens.view (Lens._1 . scopeLevel)

instance MonadScopeConstraints RConstraints (STInferB s) where
    scopeConstraints = Lens.view (Lens._1 . scopeLevel) <&> RowConstraints mempty

instance MonadQuantify ScopeLevel Name (STInferB s) where
    newQuantifiedVariable _ = newStQuantified (Lens._2 . tTyp) <&> Name . ('t':) . show

instance MonadQuantify RConstraints Name (STInferB s) where
    newQuantifiedVariable _ = newStQuantified (Lens._2 . tRow) <&> Name . ('r':) . show

instance Unify (STInferB s) Typ where
    binding = stBinding
    unifyError e =
        children (Proxy :: Proxy (Recursive (Unify (STInferB s)))) applyBindings e
        >>= throwError . TypError

instance Unify (STInferB s) Row where
    binding = stBinding
    structureMismatch = rStructureMismatch
    unifyError e =
        children (Proxy :: Proxy (Recursive (Unify (STInferB s)))) applyBindings e
        >>= throwError . RowError

deriving instance Show (Tie k LangB) => Show (LangB k)
deriving instance (Show (Tie k Typ), Show (Tie k Row)) => Show (ScopeTypes k)
