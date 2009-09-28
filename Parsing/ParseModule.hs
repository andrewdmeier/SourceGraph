{-# LANGUAGE FlexibleInstances #-}

{-
Copyright (C) 2009 Ivan Lazar Miljenovic <Ivan.Miljenovic@gmail.com>

This file is part of SourceGraph.

SourceGraph is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Parsing.ParseModule
   Description : Parse a Haskell module.
   Copyright   : (c) Ivan Lazar Miljenovic 2009
   License     : GPL-3 or later.
   Maintainer  : Ivan.Miljenovic@gmail.com

   Parse a Haskell module.
 -}
module Parsing.ParseModule(parseModule) where

import Parsing.Types
import Parsing.State

import Language.Haskell.Exts.Syntax
import Language.Haskell.Exts.Pretty

import Data.Char(isUpper)
import Data.Maybe(fromMaybe, catMaybes, fromJust)
import qualified Data.Map as M
import Data.Map(Map)
import qualified Data.Set as S
import Data.Set(Set)

import qualified Data.MultiSet as MS
import Data.MultiSet(MultiSet,Occur)

import Control.Arrow((***), second)
import Control.Monad(liftM, liftM2)

-- -----------------------------------------------------------------------------

parseModule       :: ParsedModules -> Module -> ParsedModule
parseModule hms m = pm
    where
      mns = moduleNames hms
      -- Tying the Knot
      el = internalLookup pm
      pm = runPState hms mns el blankPM $ parseInfo m

-- -----------------------------------------------------------------------------

class ModuleItem a where
    parseInfo :: a -> PState ()

instance (ModuleItem a) => ModuleItem [a] where
    parseInfo = mapM_ parseInfo

-- -----------------------------------------------------------------------------
-- Overall Module

instance ModuleItem Module where
    parseInfo (Module _ nm _ _ es is ds)
        = do let mn = createModule' nm
             pm <- getParsedModule
             putParsedModule $ pm { moduleName = mn }
             parseInfo es
             parseInfo is
             parseInfo ds

-- -----------------------------------------------------------------------------
-- Imports

instance ModuleItem ImportDecl where
    parseInfo iDcl
        = do mns <- getModuleNames
             ms  <- getModules
             pm  <- getParsedModule
             let nm  = getModName mns . nameOf $ importModule iDcl
                 md  = M.lookup nm ms
                 es  = imported nm md
                 im  = mi nm es
                 pm' = pm { imports = M.insert nm im (imports pm) }
             putParsedModule pm'
      where
        mi nm es = I { fromModule   = nm
                     , importQuald  = importQualified iDcl
                     , importedAs   = fmap nameOf $ importAs iDcl
                     , importedEnts = es
                     }

        imported nm Nothing
            = case importSpecs iDcl of
                Just (False,is) -> mkSet
                                   $ map (createEnt nm) is
                _               -> S.empty
        imported _  (Just ml)
            = case importSpecs iDcl of
                Nothing         -> exprtd
                Just (False,is) -> lstd is
                Just (True, is) -> exprtd `S.difference` lstd is
            where
              exprtd = exports ml
              exLk = exportLookup ml
              lstd = mkSet . map (listedEnt ml exLk)

-- | Guesstimate the correct 'Entity' designation for those from
--   external modules.
createEnt                      :: ModName -> ImportSpec -> [Entity]
createEnt mn (IVar n)          = [Ent mn (nameOf n) NormalEntity]
createEnt mn (IThingWith n cs) = map (\c -> Ent mn c (eT c)) cs'
    where
      n' = nameOf n
      cs' = map nameOf cs
      isD = isUpper . head
      isData = any (isUpper . head) cs'
      mkData c | isD c     = Constructor n'
               | otherwise = RecordFunction n' -- Nothing
      mkClass _ = ClassFunction n'
      eT = if isData then mkData else mkClass
createEnt _  _                 = []

-- | Determine the correct 'Entity' designation for the listed import item.
listedEnt                         :: ParsedModule -> EntityLookup
                                     -> ImportSpec -> [Entity]
listedEnt _  el (IVar n)          = [lookupEntity' el $ nameOf n]
listedEnt _  _  IAbs{}            = []
listedEnt pm _  (IThingAll n)     = esFrom dataDecls ++ esFrom classDecls
                                    -- one will be empty
    where
      esFrom f = M.elems $ f pm M.! nameOf n
listedEnt pm _  (IThingWith n cs) = esFrom dataDecls ++ esFrom classDecls
    where
      el f = f pm M.! nameOf n
      esFrom f = map (lookupEntity' (el f) . nameOf) cs

-- -----------------------------------------------------------------------------
-- Exports

-- If the export list is unspecified but there is a function called
-- "main" defined, then it is defined as the export list (otherwise
-- all top-level items are exported).
instance ModuleItem (Maybe [ExportSpec]) where
    parseInfo Nothing    = do mn <- getModuleName
                              pm <- getParsedModule
                              el <- getLookup
                              let mainFunc = M.lookup (Nothing,"main") el
                                  es = maybe (exportableEnts pm) S.singleton mainFunc
                              putParsedModule $ pm { exports = es }
    parseInfo (Just eps) = do pm <- getParsedModule
                              let el = exportableLookup pm
                                  es = mkSet $ map (listedExp pm el) eps
                              putParsedModule $ pm { exports = es }

-- Doesn't work on re-exported Class/Data specs.
listedExp                           :: ParsedModule -> EntityLookup
                                       -> ExportSpec -> [Entity]
listedExp _  el (EVar qn)           = maybe [] (return . lookupEntity el)
                                      $ qName qn
listedExp _  _  EAbs{}              = []
listedExp pm _  (EThingAll qn)      = esFrom dataDecls ++ esFrom classDecls
                                      -- one will be empty
    where
      esFrom f = maybe [] (M.elems . (M.!) (f pm) . snd) $ qName qn
listedExp pm _  (EThingWith qn cs)  = esFrom dataDecls ++ esFrom classDecls
    where
      esFrom f = fromMaybe [] $ do mn <- fmap snd $ qName qn
                                   el <- M.lookup mn $ f pm
                                   return $ map (lookupEntity' el . nameOf) cs
listedExp pm _  (EModuleContents m) = fromMaybe []
                                      . fmap (S.toList . importedEnts)
                                      . M.lookup (createModule' m)
                                      $ imports pm

-- -----------------------------------------------------------------------------
-- Main part of the module

instance ModuleItem Decl where
    -- Type alias
    parseInfo TypeDecl{} = return ()
    -- Type Families: don't seem to have any entities.
    parseInfo TypeFamDecl{} = return ()
    -- Data or Newtype
    parseInfo (DataDecl _ _ _ nm _ cs _)
        = do let d = nameOf nm
             els <- mapM (addConstructor d . unQConDecl) cs
             pm <- getParsedModule
             let el = M.unions els
                 dds' = M.insert d el $ dataDecls pm
             putParsedModule $ pm { dataDecls = dds' }
    -- GADT-style Data or Newtype
    parseInfo (GDataDecl _ _ _ n _ _ gds _)
        = do m <- getModuleName
             pm <- getParsedModule
             let d = nameOf n
                 el = addGConstructors m d gds
                 dds' = M.insert d el $ dataDecls pm
             putParsedModule $ pm { dataDecls = dds' }
    -- Data Families: don't seem to have any entities
    parseInfo DataFamDecl{} = return ()
    -- Type families are basically aliases...
    parseInfo TypeInsDecl{} = return ()
    -- Data family instances are pretty much data declarations
    -- Don't add them yet, as can't necessarily go from Type -> Name
    -- todo
    parseInfo DataInsDecl{} = return ()
    -- Same thing as above
    -- todo
    parseInfo GDataInsDecl{} = return ()
    -- Defining a new class
    parseInfo (ClassDecl _ _ n _ _ cds)
        = do let c = nameOf n
             mels <- mapM (addClassDecl c) cds
             pm <- getParsedModule
             let el = M.unions $ catMaybes mels
                 cl' = M.insert c el $ classDecls pm
             putParsedModule $ pm { classDecls = cl' }
    -- Instance of a class
    parseInfo (InstDecl _ _ n ts ids)
        = do let c = snd . fromJust $ qName n
                 d = unwords $ map prettyPrint ts
             mapM_ (addInstDecl c d) ids
    -- Stand-alone deriving
    parseInfo DerivDecl{} = return ()
    -- Fixity of infix operators
    parseInfo InfixDecl{} = return ()
    -- Default types (Integer, etc.)
    parseInfo DefaultDecl{} = return ()
    -- TH Splicing
    parseInfo SpliceDecl{} = return ()
    -- Type sigs... use the actual function
    parseInfo TypeSig{} = return ()
    -- Actual Function
    parseInfo (FunBind ms) = mapM_ addMatch ms
    -- Defining a variable, etc.
    parseInfo pb@PatBind{}
        = do mn <- getModuleName
             el <- getLookup
             pm <- getParsedModule
             (d,c) <- getDecl pb -- Might as well use this
             -- We can have more than one definition from here, unlike
             -- for Matches.
             let vs = S.map snd d
                 mkE v = Ent mn v NormalEntity
                 es = S.map mkE vs
                 es' = MS.fromList $ S.toList es
                 mkFC e o = FC e (lookupEntity el o) NormalCall
                 mkFCs o = MS.map (flip mkFC o) es'
                 cs = MS.unions . map mkFCs $ MS.toList c
                 pm' = pm { topEnts = topEnts pm `S.union` es
                          , funcCalls = funcCalls pm `MS.union` cs
                          }
             putParsedModule pm'
    -- The rest are foreign import/export and pragmas
    parseInfo _ = return ()

-- -----------------------------------------------------------------------------
-- Constructors

unQConDecl                        :: QualConDecl -> ConDecl
unQConDecl (QualConDecl _ _ _ cd) = cd

addConstructor                 :: DataType -> ConDecl -> PState EntityLookup
addConstructor d (ConDecl n _) = do m <- getModuleName
                                    let n' = nameOf n
                                        e = Ent m n' (Constructor d)
                                    return $ M.singleton (Nothing,n') e
addConstructor d (InfixConDecl _ n _) = do m <- getModuleName
                                           let n' = nameOf n
                                               e = Ent m n' (Constructor d)
                                           return $ M.singleton (Nothing,n') e
addConstructor d (RecDecl n rbs) = do m <- getModuleName
                                      pm <- getParsedModule
                                      let n' = nameOf n
                                          ce = Ent m n' (Constructor d)
                                          rs = map nameOf $ concatMap fst rbs
                                          res = map (mkRe m n') rs
                                          es = ce : res
                                          fcs = MS.fromList $ map (mkFc ce) res
                                      putParsedModule $ addFcs pm fcs
                                      return $ mkEl es
    where
      mkRe m c r = Ent m r (RecordFunction d) -- (Just c))
      mkFc c r = FC r c RecordConstructor
      addFcs pm fcs = pm { funcCalls = fcs `MS.union` funcCalls pm }

-- -----------------------------------------------------------------------------
-- GADT constructors

addGConstructors     :: ModName -> DataType -> [GadtDecl] -> EntityLookup
addGConstructors m d = mkEl . map addGConst
    where
      addGConst (GadtDecl _ n _) = Ent m (nameOf n) (Constructor d)

-- -----------------------------------------------------------------------------
-- Class declaration

addClassDecl               :: ClassName -> ClassDecl
                              -> PState (Maybe EntityLookup)
addClassDecl c (ClsDecl d) = addCDecl c d
addClassDecl _ _           = return Nothing

addCDecl                    :: ClassName -> Decl -> PState (Maybe EntityLookup)
addCDecl c (TypeSig _ ns _) = do m <- getModuleName
                                 let ns' = map nameOf ns
                                     eTp = ClassFunction c
                                     es = map (\n -> Ent m n eTp) ns'
                                 return $ Just (mkEl es)
addCDecl c (FunBind ms)     = mapM_ (addCMatch c) ms >> return Nothing
-- Can't have pattern binds in classes
addCDecl _ _                = return Nothing

addCMatch     :: ClassName -> Match -> PState ()
addCMatch c m = do el <- getLookup
                   di <- addFuncCalls (DefaultInstance c) m
                   pm <- getParsedModule
                   let cfn = name di
                       cf = lookupEntity' el cfn
                       dic = FC cf di DefaultInstDeclaration
                       pm' = pm { instDecls = S.insert di $ instDecls pm
                                , funcCalls = MS.insert dic $ funcCalls pm
                                }
                   putParsedModule pm'

-- -----------------------------------------------------------------------------
-- Instance Declaration

addInstDecl                    :: ClassName -> DataType -> InstDecl -> PState ()
addInstDecl c d (InsDecl decl) = do cs <- addIDecl c d decl
                                    mn <- getModuleName
                                    pm <- getParsedModule
                                    let fromThisMod = (==) mn . inModule
                                        cs' = S.filter (not . fromThisMod) cs
                                        pm' = pm { virtualEnts = virtualEnts pm
                                                                 `S.union`
                                                                 cs'
                                                 }
                                    putParsedModule pm'
addInstDecl _ _ _              = return ()

addIDecl                  :: ClassName -> DataType -> Decl -> PState (Set Entity)
addIDecl c d (FunBind ms) = liftM S.fromList $ mapM (addIMatch c d) ms
addIDecl _ _ _            = return S.empty

addIMatch       :: ClassName -> DataType -> Match -> PState Entity
addIMatch c d m = do el <- getLookup
                     fi <- addFuncCalls (ClassInstance c d) m
                     pm <- getParsedModule
                     let cfn = name fi
                         cf = lookupEntity' el cfn
                         ic = FC cf fi InstanceDeclaration
                         pm' = pm { instDecls = S.insert fi $ instDecls pm
                                  , funcCalls = MS.insert ic $ funcCalls pm
                                  }
                     putParsedModule pm'
                     return cf

-- -----------------------------------------------------------------------------
-- For top-level functions

addMatch   :: Match -> PState ()
addMatch m = do e <- addFuncCalls NormalEntity m
                pm <- getParsedModule
                putParsedModule $ pm { topEnts = S.insert e $ topEnts pm }

-- -----------------------------------------------------------------------------

-- Add the appropriate 'FunctionCall' values and return the created
-- 'Entity'.  The 'FunctionCall's have @callType = NormalCall@.
addFuncCalls      :: EntityType -> Match -> PState Entity
addFuncCalls et m = do mn <- getModuleName
                       el <- getLookup
                       pm <- getParsedModule
                       (d,c) <- getMatch m
                       let nm = snd $ S.findMin d
                           f = Ent { inModule = mn
                                   , name     = nm -- Assume non-qualified...
                                   , eType    = et
                                   }
                           cs = MS.map (mkFC el f) c
                           pm' = pm { funcCalls = cs `MS.union` funcCalls pm }
                       putParsedModule pm'
                       return f
    where
      mkFC el l qn = FC l (lookupEntity el qn) NormalCall

-- -----------------------------------------------------------------------------

-- Pulling apart sub-components

-- None of these really need PState... I thought they did mid-write,
-- refactored them all to use it and then after I'd finished realised
-- they didn't.  Too late to change, so they can stay this way.

type Defined = Set QEntityName
type Called = MultiSet QEntityName
type DefCalled = (Defined, Called)

getMatch                         :: Match -> PState DefCalled
getMatch (Match _ n ps _ rhs bs) = do (avs, afs) <- getPats ps
                                      rcs <- getRHS rhs
                                      (bds, bcs) <- getBindings bs
                                      let vs = avs `S.union` bds
                                          fs = MS.unions [afs, rcs, bcs]
                                          cs = defElsewhere fs vs
                                      return (S.singleton $ nameOf' n, cs)

-- In a pattern, all variables are ones that have just been defined to
-- use in that function, etc.
getPat                     :: Pat -> PState DefCalled
-- Variable
getPat (PVar n)            = return $ onlyVar n
-- Literal value
getPat PLit{}              = return noEnts
-- Negation of a Pat value
getPat (PNeg p)            = getPat p
-- n + k pattern
getPat (PNPlusK n _)       = return $ onlyVar n
-- e.g. a : as
getPat (PInfixApp p1 c p2) = do (v1, c1) <- getPat p1
                                (v2, c2) <- getPat p2
                                return ( v1 `S.union` v2
                                       , insQName c $ c1 `MS.union` c2)
-- Data constructor + args
getPat (PApp qn ps)        = liftM (second $ insQName qn) $ getPats ps
-- Tuple
getPat (PTuple ps)         = getPats ps
-- Explicit list
getPat (PList ps)          = getPats ps
-- Parens around a Pat
getPat (PParen p)          = getPat p
-- Record pattern
getPat (PRec q ps)         = liftM (second (insQName q) . sMsUnions)
                             $ mapM getPField ps
-- @-pattern
getPat (PAsPat n p)        = liftM (sMsMerge (onlyVar n)) $ getPat p
-- _
getPat PWildCard           = return noEnts
-- ~pat
getPat (PIrrPat p)         = getPat p
-- pattern with explicit type-sig
getPat (PatTypeSig _ p _)  = getPat p
-- View pattern (function -> constructor) [this avoids an explicit
-- case statement]
getPat (PViewPat e p)      = do ec <- getExp e
                                (pd,pc) <- getPat p
                                return (pd, ec `MS.union` pc)
-- HaRP... no idea now to deal with this
getPat (PRPat prs)         = return noEnts
-- !foo
getPat (PBangPat p)        = getPat p
-- The rest are XML and TH patterns
getPat _                   = return noEnts

getPats :: [Pat] -> PState DefCalled
getPats = liftM sMsUnions . mapM getPat

insQName       :: QName -> Called -> Called
insQName qn sq = maybe sq (flip MS.insert sq) $ qName qn

onlyVar   :: (Named n) => n -> DefCalled
onlyVar n = (S.singleton $ nameOf' n, MS.empty)

-- Punned fields: not registered as variables
-- Record wildcards: nothing returned
getPField                  :: PatField -> PState DefCalled
getPField (PFieldPat qn p) = liftM (second $ insQName qn) $ getPat p
getPField (PFieldPun n)    = return (S.empty, MS.singleton $ nameOf' n)
getPField PFieldWildcard   = return noEnts

-- Still have to take care of function calls here somewhere...
-- Nope: trying to get the overall list of functions called here...
-- and _then_ create function calls to them!

getBindings              :: Binds -> PState DefCalled
getBindings (BDecls ds)  = liftM sMsUnions $ mapM getDecl ds
getBindings (IPBinds is) = liftM sMsUnions $ mapM getIPBinds is

getIPBinds                :: IPBind -> PState DefCalled
getIPBinds (IPBind _ _ e) = liftM noDefs $ getExp e

getDecl                    :: Decl -> PState DefCalled
getDecl (FunBind ms)       = liftM sMsUnions $ mapM getMatch ms
getDecl (PatBind _ p _ r bs) = do (pd,pc) <- getPat p
                                  rc      <- getRHS r
                                  (bd,bc) <- getBindings bs
                                  let fs = MS.unions [pc, rc, bc]
                                      cs = defElsewhere fs bd
                                  return (pd, cs)
getDecl _                  = return noEnts


getRHS                   :: Rhs -> PState Called
getRHS (UnGuardedRhs e)  = getExp e
getRHS (GuardedRhss grs) = liftM MS.unions $ mapM getGRhs grs

getGRhs                     :: GuardedRhs -> PState Called
getGRhs (GuardedRhs _ ss e) = do (sf,sc) <- getStmts ss
                                 ec <- getExp e
                                 return $ defElsewhere' sf (sc `MS.union` ec)

-- Gah, this might be wrong...

getExp          :: Exp -> PState Called
getExp (Var qn) = return $ maybeEnt qn
getExp IPVar{}  = return MS.empty
getExp (Con qn)  = return $ maybeEnt qn
getExp Lit{}              = return MS.empty
getExp (InfixApp e1 o e2) = do e1' <- getExp e1
                               e2' <- getExp e2
                               let o' = maybeEnt o
                               return $ e1' `MS.union` e2' `MS.union` o'
getExp (App ef vf) = liftM2 MS.union (getExp ef) (getExp vf)
getExp (NegApp e)      = getExp e
getExp (Lambda _ ps e) = do (pd,pc) <- getPats ps
                            e' <- getExp e
                            return $ defElsewhere' pd
                                       $ MS.union pc e'
getExp (Let bs e) = do (bd,bc) <- getBindings bs
                       e' <- getExp e
                       return $ defElsewhere' bd (MS.union bc e')
getExp (If i t e)  = liftM MS.unions $ mapM getExp [i,t,e]
getExp (Case e as) = do e' <- getExp e
                        as' <-  mapM getAlt as
                        return $ MS.unions (e':as')

getAlt                  :: Alt -> PState Called
getAlt (Alt _ p gas bs) = do (pd,pc) <- getPat p
                             gc <- getGAlts gas
                             (bd,bc) <- getBindings bs
                             let d = pd `S.union` bd
                                 c = pc `MS.union` gc `MS.union` bc
                             return $ defElsewhere c d

getGAlts                   :: GuardedAlts -> PState Called
getGAlts (UnGuardedAlt e)  = getExp e
getGAlts (GuardedAlts gas) = liftM MS.unions $ mapM getGAlt gas

getGAlt                     :: GuardedAlt -> PState Called
getGAlt (GuardedAlt _ ss e) = do (sf, sc) <- getStmts ss
                                 ec <- getExp e
                                 return $ defElsewhere' sf (MS.union sc ec)

getStmt                   :: Stmt -> PState DefCalled
getStmt (Generator _ p e) = do (pf,pc) <- getPat p
                               ec <- getExp e
                               return (pf, defElsewhere' pf (MS.union pc ec))
getStmt (Qualifier e)     = liftM noDefs $ getExp e
getStmt (LetStmt bs)      = getBindings bs
getStmt (RecStmt ss)      = getStmts ss

getStmts :: [Stmt] -> PState DefCalled
getStmts = liftM sMsUnions . mapM getStmt

noDefs :: Called -> DefCalled
noDefs = (,) S.empty

maybeEnt :: (QNamed a) => a -> Called
maybeEnt = maybe MS.empty MS.singleton . qName

maybeEnt' :: (QNamed a) => a -> Defined
maybeEnt' = maybe S.empty S.singleton . qName

noEnts :: DefCalled
noEnts = (S.empty, MS.empty)

bool       :: a -> a -> Bool -> a
bool t f b = if b then t else f

-- -----------------------------------------------------------------------------

class Named a where
    nameOf :: a -> String

instance Named Name where
    nameOf (Ident n)  = n
    nameOf (Symbol n) = n

nameOf' :: (Named n) => n -> QEntityName
nameOf' = (,) Nothing . nameOf

instance Named CName where
    nameOf (VarName n) = nameOf n
    nameOf (ConName n) = nameOf n

instance Named ModuleName where
    nameOf (ModuleName m) = m

-- | Create the 'ModName'.
createModule' :: ModuleName -> ModName
createModule' = createModule . nameOf

class QNamed a where
    qName :: a -> Maybe QEntityName

instance QNamed QName where
    qName (Qual m n) = Just (Just $ nameOf m, nameOf n)
    qName (UnQual n) = Just (Nothing, nameOf n)
    qName Special{}  = Nothing

instance QNamed QOp where
    qName (QVarOp qn) = qName qn
    qName (QConOp qn) = qName qn

sMsUnions :: (Ord a, Ord b) => [(Set a, MultiSet b)] -> (Set a, MultiSet b)
sMsUnions = (S.unions *** MS.unions) . unzip

sMsMerge           :: (Ord a, Ord b) => (Set a, MultiSet b)
                      -> (Set a, MultiSet b) -> (Set a, MultiSet b)
sMsMerge (s1, ms1) = S.union s1 *** MS.union ms1

defElsewhere      :: Called -> Defined -> Called
defElsewhere ms s = MS.fromMap $ fs `M.difference` ifs
    where
      fs = MS.toMap ms
      ifs = M.fromList . map (flip (,) 1 ) $ S.toList s

defElsewhere' :: Defined -> Called -> Called
defElsewhere' = flip defElsewhere

-- -----------------------------------------------------------------------------
