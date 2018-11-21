{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}


module ML.BORL.NeuralNetwork
    ( toHeadShapes
    , fromLastShapes

    ) where

-- import qualified CLaSH.Promoted.Nat as SV
-- import qualified CLaSH.Sized.Vector as SV
import           Data.Proxy
import           Data.Reflection
import           Data.Singletons
import           Data.Singletons.Prelude.List
import qualified Data.Vector.Storable         as DV
import           GHC.TypeLits
import           Grenade
import qualified Numeric.LinearAlgebra        as LA
import           Numeric.LinearAlgebra.Static
import           Unsafe.Coerce

data NNBorl net = NNBorl { net :: forall layers shapes . (Network layers shapes ~ net) => net
                         , nrInp :: Int
                         }

type family HeadShape (iShape :: Shape) (nr :: Nat) :: Shape
type instance HeadShape ('D1 x) nr = 'D2 x (nr+1)


-- newtype MagicHeadShapes r = MagicHeadShapes (forall (n :: Nat) . KnownNat n => Proxy n -> r)

-- runNetwork :: forall layers shapes. Network layers shapes -> S (Head shapes) -> (Tapes layers shapes, S (Last shapes))

data KnownNet layers shapes = forall (n :: Nat) net . (Network layers shapes ~ net, KnownNat n, Head shapes ~ 'D1 n) => KnownNet net

toHeadShapes :: (KnownNat nr, 'D1 nr ~ Head shapes) => Network layers shapes -> [Double] -> S (Head shapes)
toHeadShapes _ inp = S1D $ vector inp

fromLastShapes :: Network layers shapes -> (Tapes layers shapes, S (Last shapes)) -> (Tapes layers shapes, [Double])
fromLastShapes _ (tapes, S1D out) = (tapes, DV.toList $ extract out)
fromLastShapes _ _                = error "NN output currently not supported."

-- -- | Create Vec from a list.


-- newtype MR n = MR (Dim n (LA.Vector Double))

-- newtype Dim (n :: Nat) t = Dim t
--   deriving (Show)

-- mkR :: LA.Vector ℝ -> MR n
-- mkR = MR . Dim

-- -- | Create Vec from a list.
-- reifySVec :: (KnownNat nr) => [a] -> SV.Vec nr a
-- reifySVec xs = head <$> SV.iterateI tail xs

-- -- | Create SNat from Integer >= 0, otherwise SNat 0.
-- reifySNat :: Integer -> SV.SNat a
-- reifySNat n | n < 0 = reifyNat 0 (unsafeCoerce . SV.snatProxy)
--             | otherwise = reifyNat n (unsafeCoerce . SV.snatProxy)

