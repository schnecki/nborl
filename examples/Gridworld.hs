{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
module Main where

import           ML.BORL

import           Helper

import           Control.Arrow   (first, second)
import           Control.DeepSeq (NFData)
import           Control.Lens    (set, (^.))
import           Control.Monad   (foldM, unless, when)
import           GHC.Generics
import           Grenade
import           System.IO
import           System.Random

maxX,maxY :: Int
maxX = 4                        -- [0..maxX]
maxY = 4                        -- [0..maxY]


type NN = Network  '[ FullyConnected 3 10, Relu, FullyConnected 10 8, Relu, FullyConnected 8 4, Relu, FullyConnected 4 1, Tanh] '[ 'D1 3, 'D1 10, 'D1 10, 'D1 8, 'D1 8, 'D1 4, 'D1 4, 'D1 1, 'D1 1]

nnConfig :: NNConfig St
nnConfig = NNConfig
  { _toNetInp             = netInp
  , _replayMemory         = mkReplayMemory 10000
  , _trainBatchSize       = 32
  , _learningParams       = LearningParameters 0.01 0.9 0.0001
  , _prettyPrintElems     = [minBound .. maxBound] :: [St]
  , _scaleParameters      = scalingByMaxReward False 8
  , _updateTargetInterval = 1000
  , _trainMSEMax          = 0.05
  }

netInp :: St -> [Double]
netInp st = [scaleNegPosOne (0, fromIntegral maxX) $ fromIntegral $ fst (getCurrentIdx st), scaleNegPosOne (0, fromIntegral maxY) $ fromIntegral $ snd (getCurrentIdx st)]


main :: IO ()
main = do

  net <- randomNetworkInitWith UniformInit :: IO NN
  let rl = mkBORLUnichainGrenade initState actions actFilter params decay net nnConfig
  let rl = mkBORLUnichainTabular initState actions actFilter params decay
  askUser True usage cmds rl   -- maybe increase learning by setting estimate of rho

  where cmds = zipWith3 (\n (s,a) na -> (s, (n, Action a na))) [0..] [("i",moveUp),("j",moveDown), ("k",moveLeft), ("l", moveRight) ] (tail names)
        usage = [("i","Move up") , ("j","Move left") , ("k","Move down") , ("l","Move right")]

names = ["random", "up   ", "down ", "left ", "right"]

-- | BORL Parameters.
params :: Parameters
params = Parameters
  { _alpha            = 0.2
  , _beta             = 0.25
  , _delta            = 0.25
  , _epsilon          = 1.0
  , _exploration      = 1.0
  , _learnRandomAbove = 0.1
  , _zeta             = 1.0
  , _xi               = 0.5
  }

-- | Decay function of parameters.
decay :: Period -> Parameters -> Parameters
decay t p@(Parameters alp bet del eps exp rand zeta xi)
  | t `mod` 200 == 0 = Parameters (max 0.0001 $ slower * alp) (f $ slower * bet) (f $ slower * del) (max 0.1 $ slow * eps) (f $ slower * exp) rand zeta xi
  | otherwise = p

  where slower = 0.995
        slow = 0.95
        faster = 1.0/0.995
        f = max 0.001


-- | Decay function of parameters.
-- decay :: Period -> Parameters -> Parameters
-- decay t p@(Parameters alp bet del eps exp rand zeta xi)
--   | t `mod` 200 == 0 = Parameters (f alp) (f bet) (f del) eps (max 0.1 $ slower * exp) rand zeta (min 1 $ fromIntegral t / 20000 * xi)
--   | otherwise = p

--   where slower = 0.995

--         slow = 0.95
--         f x = max 0.001 (slower * x)


initState :: St
initState = fromIdx (2,2)


-- State
newtype St = St [[Integer]] deriving (Eq,NFData,Generic)

instance Ord St where
  x <= y = fst (getCurrentIdx x) < fst (getCurrentIdx y) || (fst (getCurrentIdx x) == fst (getCurrentIdx y) && snd (getCurrentIdx x) < snd (getCurrentIdx y))

instance Show St where
  show xs = show (getCurrentIdx xs)

instance Enum St where
  fromEnum st = let (x,y) = getCurrentIdx st
                in x * (maxX + 1) + y
  toEnum x = fromIdx (x `div` (maxX+1), x `mod` (maxX+1))

instance Bounded St where
  minBound = fromIdx (0,0)
  maxBound = fromIdx (maxX, maxY)


-- Actions
actions :: [Action St]
actions = zipWith Action
  (map goalState [moveRand, moveUp, moveDown, moveLeft, moveRight])
  names

actFilter :: St -> [Bool]
actFilter st | st == fromIdx (0,2) = True : repeat False
actFilter _  = False : repeat True


moveRand :: St -> IO (Reward, St)
moveRand = moveUp


-- goalState :: Action St -> Action St
goalState f st = do
  x <- randomRIO (0, maxX :: Int)
  y <- randomRIO (0, maxY :: Int)
  case getCurrentIdx st of
    -- (0, 1) -> return [(1, (10, fromIdx (x,y)))]
    (0, 2) -> return (10, fromIdx (x,y))
    -- (0, 3) -> return [(1, (5, fromIdx (x,y)))]
    _      -> stepRew <$> f st
  where stepRew = first (+ 0)


moveUp :: St -> IO (Reward,St)
moveUp st
    | m == 0 = return (-1, st)
    | otherwise = return (0, fromIdx (m-1,n))
  where (m,n) = getCurrentIdx st

moveDown :: St -> IO (Reward,St)
moveDown st
    | m == maxX = return (-1, st)
    | otherwise = return (0, fromIdx (m+1,n))
  where (m,n) = getCurrentIdx st

moveLeft :: St -> IO (Reward,St)
moveLeft st
    | n == 0 = return (-1, st)
    | otherwise = return (0, fromIdx (m,n-1))
  where (m,n) = getCurrentIdx st

moveRight :: St -> IO (Reward,St)
moveRight st
    | n == maxY = return (-1, st)
    | otherwise = return (0, fromIdx (m,n+1))
  where (m,n) = getCurrentIdx st


-- Conversion from/to index for state

fromIdx :: (Int, Int) -> St
fromIdx (m,n) = St $ zipWith (\nr xs -> zipWith (\nr' ys -> if m == nr && n == nr' then 1 else 0) [0..] xs) [0..] base
  where base = replicate 5 [0,0,0,0,0]


getCurrentIdx :: St -> (Int,Int)
getCurrentIdx (St st) = second (fst . head . filter ((==1) . snd)) $
  head $ filter ((1 `elem`) . map snd . snd) $
  zip [0..] $ map (zip [0..]) st


