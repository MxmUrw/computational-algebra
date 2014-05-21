{-# LANGUAGE ConstraintKinds, DataKinds, DeriveDataTypeable, FlexibleContexts  #-}
{-# LANGUAGE GADTs, ImplicitParams, MultiParamTypeClasses, NoImplicitPrelude   #-}
{-# LANGUAGE NoMonomorphismRestriction, ParallelListComp, RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables, TemplateHaskell, TypeOperators, ViewPatterns #-}
module Algebra.Algorithms.Faugere5 (f5Original) where
import           Algebra.Algorithms.Groebner
import           Algebra.Prelude
import           Algebra.Ring.Noetherian
import           Control.Applicative         ((<$>))
import           Control.Arrow               ((>>>))
import           Control.Lens                (makeLenses, view, (%~), (&), (.~))
import           Control.Lens                ((^.), _1, _2)
import           Control.Monad               (filterM, forM_, liftM, when)
import           Control.Monad.Loops         (anyM, whileM_)
import           Control.Monad.ST            (ST, runST)
import           Control.Monad.Trans         (lift)
import           Control.Monad.Trans.Loop    (exit, foreach)
import           Data.Foldable               (foldrM)
import qualified Data.Foldable               as T
import           Data.Function               (on)
import           Data.Heap                   (Entry (..), insert)
import qualified Data.Heap                   as H
import           Data.IntSet                 (IntSet)
import qualified Data.IntSet                 as IS
import           Data.List                   (find, partition)
import           Data.List                   (sort, sortBy)
import           Data.Maybe                  (listToMaybe)
import           Data.Monoid                 ((<>))
import           Data.Ord                    (comparing)
import           Data.Singletons             (SingRep)
import           Data.STRef                  (STRef, modifySTRef', newSTRef)
import           Data.STRef                  (readSTRef, writeSTRef)
import qualified Data.Vector                 as V
import qualified Data.Vector.Mutable         as MV
import           Numeric.Decidable.Zero      (isZero)

type CriticalPair ord n = (OrderedMonomial ord n, OrderedMonomial ord n, Int, OrderedMonomial ord n, Int)
type Rule ord n = [(OrderedMonomial ord n, Int)]

data PolyRepr r ord n = PolyRepr { _signature :: (Int, OrderedMonomial ord n)
                                 , _poly      :: OrderedPolynomial r ord n
                                 } deriving (Show)

type RefVector s a = STRef s (MV.MVector s a)

monoize :: ( DecidableZero r, SingRep n, Division r, Noetherian r, IsMonomialOrder order)
        => OrderedPolynomial r order n -> OrderedPolynomial r order n
monoize f | isZero f  = zero
          | otherwise = recip (leadingCoeff f) .*. f

makeLenses ''PolyRepr

instance (IsMonomialOrder ord, SingRep n) => Eq (PolyRepr r ord n) where
  (==) = (==) `on` view signature

instance (IsMonomialOrder ord, SingRep n) => Ord (PolyRepr r ord n) where
  compare = flip (comparing (view $ signature._1)) <> comparing (view $ signature._2)

(*@) :: (DecidableZero r, Eq r, IsMonomialOrder ord, SingRep n, Noetherian r)
     => OrderedMonomial ord n -> PolyRepr r ord n -> PolyRepr r ord n
(*@) v = (signature._2 %~ (v*)) >>> (poly %~ (toPolynomial (one, v) *))

nf :: (DecidableZero r, Eq r, SingRep n, Division r, Noetherian r, IsMonomialOrder ord)
   => PolyRepr r ord n -> [OrderedPolynomial r ord n] -> PolyRepr r ord n
nf r g = r & poly %~ (`modPolynomial` g)

infixl 7 *@

f5Original :: ( Ord r, Eq r, DecidableZero r, SingRep n, Division r, Noetherian r, IsMonomialOrder ord)
           => Ideal (OrderedPolynomial r ord n) -> Ideal (OrderedPolynomial r ord n)
f5Original = toIdeal . sort . reduceMinimalGroebnerBasis . minimizeGroebnerBasis . generators . mainLoop

{-
setupRedBasis g0 = do
  bs <- reduceMinimalGroebnerBasis . minimizeGroebnerBasis <$>
        mapM (liftM (view poly) . readAt ?labPolys) (IS.toList g0)
  let m  = length bs
  g' <- V.unsafeThaw $ V.generate m id
  writeSTRef ?labPolys
    =<< V.unsafeThaw (V.fromList [ PolyRepr (j, one) bj | j <- [0..] | bj <- bs])
  writeSTRef ?rules =<< MV.replicate m []
  forM_ [0..m-2] $ \j -> do
    let t = leadingMonomial $ bs !! j
    forM_ [j+1..m-1] $ \k -> do
      let lmk = leadingMonomial (bs !! k)
          u = lcmMonomial t lmk / lmk
      writeAt ?rules k . ((one, 0):) =<< readAt ?rules k
  return g'
-}

mainLoop :: ( IsMonomialOrder ord, IsPolynomial r n, Field r)
         => Ideal (OrderedPolynomial r ord n) -> Ideal (OrderedPolynomial r ord n)
mainLoop (filter (not . isZero) . generators -> ideal)
  | null ideal = toIdeal [zero]
  | otherwise = runST $ do
  let gs = sortBy (flip $ comparing totalDegree' <> comparing leadingMonomial) $
            ideal
      m  = length gs
      (f0 : fs) = gs
  lps0 <- newSTRef =<< MV.new m
  writeAt lps0 (m-1) (PolyRepr (m-1, one) $ monoize f0)
  rs0  <- newSTRef =<< MV.replicate m []
  g    <- MV.replicate m IS.empty
  MV.write g (m-1) (IS.singleton $ m-1)
  let ?labPolys = lps0
      ?rules    = rs0
  foreach (zip fs [m-2,m-3..0]) $ \(h, i) -> do
    gi <- lift $ f5Core h i g
    p  <- anyM (liftM ((== one) . view poly) . lift . readAt lps0) $ IS.toList gi
    when p $ do
      lift $ MV.write g 0 IS.empty
      exit
    lift $ MV.write g i gi
  g0 <- MV.read g 0
  if IS.null g0 then return $ toIdeal [one]
    else toIdeal <$> mapM (liftM (view poly) . readAt lps0) (IS.toList g0)

f5Core :: ( ?labPolys :: (RefVector s (PolyRepr r ord n)),
           ?rules :: (RefVector s (Rule ord n)),
           Eq r, Division r, SingRep n, DecidableZero r, Noetherian r, IsMonomialOrder ord)
       => OrderedPolynomial r ord n
       -> Int
       -> MV.MVector s IntSet
       -> ST s IntSet
f5Core f i g = do
  writeAt ?labPolys i $ PolyRepr (i, one) (monoize f)
  gi1 <- MV.read g (i+1)
  g' <- newSTRef $ IS.insert i gi1
  ps <- newSTRef =<< mapMaybeM (\j -> criticalPair i j i gi1) (IS.toList gi1)
  whileM_ (not . null <$> readSTRef ps) $ do
    p <- readSTRef ps
    let d = minimum $ map (totalDegree.view _1) p
        (pd, p') = partition ((== d) . totalDegree . view _1) p
    writeSTRef ps p'
    sd <- spols pd
    g'0 <- readSTRef g'
    rd <- reduction sd g'0 . V.toList =<< V.freeze g
    forM_ (IS.toList rd) $ \k -> do
      pss <- mapMaybeM (\l -> criticalPair k l i gi1) . IS.toList =<< readSTRef g'
      modifySTRef' ps (pss ++)
      modifySTRef' g' (IS.insert k)
  readSTRef g'

mapMaybeM :: Monad m => (t -> m (Maybe a)) -> [t] -> m [a]
mapMaybeM f as = go as id
  where
    go []       acc = return $ acc []
    go (x : xs) acc = do
      ma <- f x
      case ma of
        Nothing -> go xs acc
        Just x' -> go xs (acc . (x' :))

reduction :: (Eq r, ?labPolys :: (RefVector s (PolyRepr r ord n)),
              ?rules :: (RefVector s (Rule ord n)),
              SingRep n, DecidableZero r, Division r, Noetherian r,
              IsMonomialOrder ord)
          => [Int] -> IntSet -> [IntSet] -> ST s IntSet
reduction t0 g' g =
  loop IS.empty . H.fromList =<< mapM (\l -> flip Entry l <$> readAt ?labPolys l) t0
  where
    loop ds t00 = do
      case H.uncons t00 of
        Nothing -> return ds
        Just (Entry rk k, t) -> do
          pgs <- mapM (liftM _poly . readAt ?labPolys) $ IS.toList g'
          writeAt ?labPolys k $ nf rk pgs
          (ks, t'0) <- topReduction k (g' `IS.union` ds) g
          t' <- mapM (\l -> flip Entry l <$> readAt ?labPolys l) t'0
          loop (ds `IS.union` IS.fromList ks) (t `H.union` H.fromList t')


findReductor :: (Eq r, ?labPolys :: RefVector s (PolyRepr r ord n),
                ?rules :: RefVector s (Rule ord n), SingRep n,
                DecidableZero r, Noetherian r, IsMonomialOrder ord)
             => Int -> IntSet -> [IntSet] -> ST s (Maybe Int)
findReductor k g' g = do
  rk <- readAt ?labPolys k
  let t = leadingMonomial $ rk ^. poly
  let cond j = do
        rj <- readAt ?labPolys j
        let t' = leadingMonomial $ rj ^. poly
            (kj, vj) = rj ^. signature
        if t' `divs` t
          then do
            let u = t / t'
            p1 <- isRewritable u j
            p2 <- isTopReducible (u*vj) $ g !! (kj+1)
            return $ view signature (u *@ rj) /= view signature rk
              && not p1 && not p2
          else return False
  listToMaybe <$> filterM cond (IS.toList g')

topReduction :: (Eq r, ?labPolys :: (RefVector s (PolyRepr r ord n)),
                 ?rules :: (RefVector s (Rule ord n)), SingRep n,
                 DecidableZero r, Division r, Noetherian r, IsMonomialOrder ord)
             => Int -> IntSet -> [IntSet] -> ST s ([Int], [Int])
topReduction k g' g = do
  rk <- readAt ?labPolys k
  let p = rk ^. poly
  if isZero p
     then return ([], [])
     else do
  mj <- findReductor k g' g
  case mj of
    Nothing -> do
      let p' = monoize p
      writeAt ?labPolys k $ rk & poly .~ p'
      return ([k], [])
    Just j ->  do
      rj <- readAt ?labPolys j
      let q = rj ^. poly
          u = leadingMonomial p / leadingMonomial q
          p' = p - leadingCoeff p % leadingCoeff q * toPolynomial (one, u) * q
      if u *@ rj < rk
        then do
          writeAt ?labPolys k $ rk & poly .~ p'
          return ([], [k])
        else do
          n <- lengthMV ?labPolys
          snoc ?labPolys $ (u *@ rj) & poly .~ p'
          addRule n
          return ([], [k, n])

spols :: (?labPolys :: (RefVector s (PolyRepr r ord n)),
          ?rules :: (RefVector s (Rule ord n)),
          SingRep n,
          DecidableZero r, Division r, Noetherian r, IsMonomialOrder ord)
      => [CriticalPair ord n] -> ST s [Int]
spols bs = do
  map payload . T.toList <$> foldrM step H.empty bs
  where
    step (_, u,k,v,l) fs = do
      rk <- readAt ?labPolys k
      rl <- readAt ?labPolys l
      let c1 = leadingCoeff $ rk^.poly
          c2 = leadingCoeff $ rl^.poly
          s0  = toPolynomial (one, u) * (rk ^. poly)
               - toPolynomial (one, v) * ((c1/c2).*.(rl ^. poly))
      p1 <- isRewritable u k
      p2 <- isRewritable v l
      if not (isZero s0) && not p1 && not p2
        then do
          let rn = rl & signature._2 %~ (*u)
                      & poly .~ s0
          snoc ?labPolys rn
          n <- lengthMV ?labPolys
          addRule (n-1)
          return $ insert (Entry rn (n-1)) fs
        else return fs

addRule :: (IsMonomialOrder ord, Noetherian r, DecidableZero r, ?labPolys :: (RefVector s (PolyRepr r ord n)),
            ?rules :: (RefVector s (Rule ord n)), SingRep n)
        => Int -> ST s ()
addRule j = do
  (i, t) <- view signature <$> readAt ?labPolys j
  writeAt ?rules i . ((t, j):) =<< readAt ?rules i

isRewritable :: (?labPolys :: (RefVector s (PolyRepr r ord n)),
                 ?rules :: (RefVector s (Rule ord n)))
              => OrderedMonomial ord n -> Int -> ST s Bool
isRewritable u k = do
  k' <- rewrite u k
  return $ k /= k'

rewrite :: (?labPolys :: (RefVector s (PolyRepr r ord n)),
            ?rules :: (RefVector s (Rule ord n)))
        => OrderedMonomial ord n -> Int -> ST s Int
rewrite u k = do
  (l, v) <- view signature <$> readAt ?labPolys k
  rs <- readAt ?rules l
  return $ maybe k snd $ find (\(t, _) -> t `divs` (u * v)) rs

criticalPair :: (?labPolys :: RefVector s (PolyRepr r ord n),
                 Eq r, SingRep n, DecidableZero r, Noetherian r, IsMonomialOrder ord)
             => Int
             -> Int
             -> Int
             -> IntSet
             -> ST s (Maybe (CriticalPair ord n))
criticalPair k0 l0 i g0 = do
  rk <- readAt ?labPolys k0
  rl <- readAt ?labPolys l0
  let t  = lcmMonomial (leadingMonomial $ rk^.poly) (leadingMonomial $ rl^.poly)
      u10 = t / leadingMonomial (rk^.poly)
      u20 = t / leadingMonomial (rl^.poly)
      (k, l, u1, u2)
        | u10 *@ rk < u20 *@ rl = (l0, k0, u20, u10)
        | otherwise = (k0, l0, u10, u20)
  (k1, t1) <- view signature <$> readAt ?labPolys k
  (k2, t2) <- view signature <$> readAt ?labPolys l
  p1 <- isTopReducible (u1 * t1) g0
  p2 <- isTopReducible (u2 * t2) g0
  if k1 > i || p1 || (k2 == i && p2)
    then return Nothing
    else return $ Just (t, u1, k, u2, l)

isTopReducible :: (?labPolys :: RefVector s (PolyRepr r ord n), SingRep n,
                   DecidableZero r, Noetherian r, IsMonomialOrder ord)
               => OrderedMonomial ord n -> IntSet -> ST s Bool
isTopReducible f gs =
  any (\g -> leadingMonomial (g^.poly) `divs` f) <$> mapM (readAt ?labPolys) (IS.toList gs)

readAt :: STRef s (MV.MVector s b) -> Int -> ST s b
readAt m i = flip MV.read i =<< readSTRef m

writeAt :: STRef s (MV.MVector s a) -> Int -> a -> ST s ()
writeAt m i x = do
  v <- readSTRef m
  MV.write v i x

snoc :: STRef s (MV.MVector s a) -> a -> ST s ()
snoc m x = do
  v <- flip MV.grow 1 =<< readSTRef m
  MV.write v (MV.length v - 1) x
  writeSTRef m v

lengthMV :: STRef s1 (MV.MVector s a) -> ST s1 Int
lengthMV = liftM MV.length . readSTRef
