{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedLists            #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeFamilies               #-}

-- | !!! IMPORTANT !!!
--
-- REQUIREMENTS: python 3.4 and gym (https://gym.openai.com/docs/#installation)
--
--
--  ArchLinux Commands:
--  --------------------
--  $ yay -S python                # for yay see https://wiki.archlinux.org/index.php/AUR_helpers
--  $ curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
--  $ python get-pip.py --user
--  $ pip install gym --user
--
--
--
--
module Main where

import           ML.BORL
import           ML.Gym

import           Helper

import           Control.Arrow          (first, second, (***))
import           Control.DeepSeq        (NFData)
import qualified Control.Exception      as E
import           Control.Lens
import           Control.Lens           (set, (^.))
import           Control.Monad          (foldM_, forM, forM_, void)
import           Control.Monad          (foldM, unless, when)
import           Control.Monad.IO.Class (liftIO)
import           Data.List              (genericLength)
import qualified Data.Text              as T
import           Debug.Trace
import           GHC.Generics
import           GHC.Int                (Int32, Int64)
import           Grenade
import           System.Environment     (getArgs)
import           System.Exit
import           System.IO
import           System.Random

import qualified TensorFlow.Build       as TF (addNewOp, evalBuildT, explicitName, opDef,
                                               opDefWithName, opType, runBuildT, summaries)
import qualified TensorFlow.Core        as TF hiding (value)
import qualified TensorFlow.GenOps.Core as TF (abs, add, approximateEqual,
                                               approximateEqual, assign, cast,
                                               getSessionHandle, getSessionTensor,
                                               identity', identityN', lessEqual, matMul,
                                               mul, readerSerializeState, relu, relu',
                                               shape, square, sub, tanh, tanh',
                                               truncatedNormal)
import qualified TensorFlow.Minimize    as TF
import qualified TensorFlow.Ops         as TF (initializedVariable, initializedVariable',
                                               placeholder, placeholder', reduceMean,
                                               reduceSum, restore, save, scalar, vector,
                                               zeroInitializedVariable,
                                               zeroInitializedVariable')
import qualified TensorFlow.Tensor      as TF (Ref (..), collectAllSummaries,
                                               tensorNodeName, tensorRefFromName,
                                               tensorValueFromName)


newtype St = St [Double]
  deriving (Show, Eq, Ord, Generic, NFData)


maxX,maxY :: Int
maxX = 4                        -- [0..maxX]
maxY = 4                        -- [0..maxY]


type NN = Network  '[ FullyConnected 2 20, Relu, FullyConnected 20 10, Relu, FullyConnected 10 10, Relu, FullyConnected 10 5, Tanh] '[ 'D1 2, 'D1 20, 'D1 20, 'D1 10, 'D1 10, 'D1 10, 'D1 10, 'D1 5, 'D1 5]


modelBuilder :: (TF.MonadBuild m) => Integer -> Integer -> Int64 -> m TensorflowModel
modelBuilder nrInp nrOut outCols =
  buildModel $
  inputLayer1D (fromIntegral nrInp) >>
  fullyConnected [5 * (fromIntegral (nrOut `div` 3) + fromIntegral nrInp)] TF.relu' >>
  fullyConnected [3 * (fromIntegral (nrOut `div` 2) + fromIntegral (nrInp `div` 2))] TF.relu' >>
  -- fullyConnected (1 * (fromIntegral nrOut + fromIntegral (nrInp `div` 3))) TF.relu' >>
  fullyConnected [fromIntegral nrOut, outCols] TF.tanh' >>
  trainingByAdamWith TF.AdamConfig {TF.adamLearningRate = 0.001, TF.adamBeta1 = 0.9, TF.adamBeta2 = 0.999, TF.adamEpsilon = 1e-8}


nnConfig :: Gym -> Double -> NNConfig
nnConfig gym maxRew =
  NNConfig
    { _replayMemoryMaxSize = 30000
    , _trainBatchSize = 24
    , _grenadeLearningParams = LearningParameters 0.01 0.9 0.0001
    , _learningParamsDecay = ExponentialDecay Nothing 0.5 100000
    , _prettyPrintElems = ppSts
    , _scaleParameters = scalingByMaxAbsReward False maxRew
    , _stabilizationAdditionalRho = 0.0
    , _stabilizationAdditionalRhoDecay = ExponentialDecay Nothing 0.05 100000
    , _updateTargetInterval = 1
    , _trainMSEMax = Nothing -- Just 0.05
    , _setExpSmoothParamsTo1 = True
    }
  where
    range = getGymRangeFromSpace $ observationSpace gym
    (lows, highs) = (map (max (-5)) *** map (min 5)) (gymRangeToDoubleLists range)
    vals = zipWith (\lo hi -> map rnd [lo,lo + (hi - lo) / 3 .. hi]) lows highs
    rnd x = fromIntegral (round (100 * x)) / 100
    ppSts = take 150 $ combinations vals


combinations :: [[a]] -> [[a]]
combinations []       = []
combinations [xs] = map return xs
combinations (xs:xss) = concatMap (\x -> map (x:) ys) xs
  where ys = combinations xss


action :: Gym -> Integer -> Action St
action gym idx =
  flip Action (T.pack $ show idx) $ \_ -> do
    res <- stepGym gym idx
    (rew, obs) <-
      if episodeDone res
        then do
          obs <- resetGym gym
          return (rewardFunction gym res, obs)
        else return (rewardFunction gym res, observation res)
    return (Reward rew, St $ gymObservationToDoubleList obs, episodeDone res)

-- | Scales values to (-1, 1).
netInp :: Bool -> Gym -> St -> [Double]
netInp isTabular gym (St st) = cutValues $ zipWith3 scaleValues lowerBounds upperBounds (stSelector st)
  where
    scaleValues l u (x, norm)
      | norm == False = x
      | otherwise = scaleValue (Just (l, u)) x
    cutValues
      | isTabular = map (\x -> fromIntegral (round (x * 10)) / 10)
      | otherwise = id
    (lowerBounds, upperBounds) = gymRangeToDoubleLists $ getGymRangeFromSpace $ observationSpace gym
    stSelector xs
      | name gym == "MountainCar-v0" = [(head xs, True), (signum (xs !! 1), False)]
      | otherwise = zip xs (repeat True)


maxReward :: Gym -> Double
maxReward gym | name gym == "CartPole-v1" = 24
              | name gym == "MountainCar-v0" = 1.0
maxReward _   = error "(Max) Reward function not yet defined for this environment"

rewardFunction :: Gym -> GymResult -> Double
rewardFunction gym (GymResult obs rew eps)
  | name gym == "CartPole-v1" = 24 - abs (xs !! 3) -- angle
  | name gym == "MountainCar-v0" = max (-0.3) (head xs) -- [position, velocity]; position [-1.2, 0.6]. goal: 0.5; velocity max: 0.07
  where xs = gymObservationToDoubleList obs
rewardFunction _ _ = error "(Max) Reward function not yet defined for this environment"


stGen :: ([Double], [Double]) -> St -> St
stGen (lows, highs) (St xs) = St $ zipWith3 splitInto lows highs xs
  where
    splitInto lo hi x = -- x * scale
      fromIntegral (round (gran * x)) / gran
      where scale = 1/(hi - lo)
            gran = 2

instance RewardFuture St where
  type StoreType St = ()


alg :: Algorithm St
alg =
  -- algDQN
  AlgDQNAvgRewAdjusted 0.85 1 ByStateValues


main :: IO ()
main = do

  args <- getArgs
  putStrLn $ "Received arguments: " ++ show args
  let name | not (null args) = head args
           | otherwise = "MountainCar-v0"
             -- "CartPole-v1"
  (obs, gym) <- initGym (T.pack name)
  let maxRew | length args >= 2  = read (args!!1)
             | otherwise = maxReward gym
  putStrLn $ "Gym: " ++ show gym
  setMaxEpisodeSteps gym 10000
  let inputNodes = spaceSize (observationSpace gym)
      actionNodes = spaceSize (actionSpace gym)
      ranges = gymRangeToDoubleLists $ getGymRangeFromSpace $ observationSpace gym
      initState = St (gymObservationToDoubleList obs)
      actions = map (action gym) [0..actionNodes-1]
      initValues = Just $ defInitValues { defaultRho = 0, defaultRhoMinimum = 0, defaultR1 = 1 }
  putStrLn $ "Actions: " ++ show actions
  -- nn <- randomNetworkInitWith UniformInit :: IO NN
  -- rl <- mkUnichainGrenade initState actions actFilter params decay nn (nnConfig gym maxRew)
  -- rl <- mkUnichainTensorflow alg initState (netInp gym) actions actFilter params decay (modelBuilder inputNodes actionNodes) (nnConfig gym maxRew) initValues
  let rl = mkUnichainTabular alg initState (netInp True gym) actions actFilter params decay initValues
  askUser Nothing True usage cmds rl   -- maybe increase learning by setting estimate of rho

  where cmds = []
        usage = []

-- | BORL Parameters.
params :: ParameterInitValues
params =
  Parameters
    { _alpha               = 0.03
    , _beta                = 0.01
    , _delta               = 0.005
    , _gamma               = 0.01
    , _epsilon             = 1.0
    , _explorationStrategy = EpsilonGreedy -- SoftmaxBoltzmann 10 -- EpsilonGreedy
    , _exploration         = 1.0
    , _learnRandomAbove    = 0.5
    , _zeta                = 0.03
    , _xi                  = 0.005
    , _disableAllLearning  = False
    -- ANN
    , _alphaANN            = 0.5 -- only used for multichain
    , _betaANN             = 0.5
    , _deltaANN            = 0.5
    , _gammaANN            = 0.5
    }

decay :: Decay
decay =
  decaySetupParameters
    Parameters
      { _alpha            = ExponentialDecay (Just 1e-5) 0.15 30000
      , _beta             = ExponentialDecay (Just 1e-4) 0.5 150000
      , _delta            = ExponentialDecay (Just 5e-4) 0.5 150000
      , _gamma            = ExponentialDecay (Just 1e-3) 0.5 150000
      , _zeta             = ExponentialDecay (Just 0) 0.5 150000
      , _xi               = NoDecay
      -- Exploration
      , _epsilon          = ExponentialDecay (Just 0.10) 0.05 15000
      , _exploration      = ExponentialDecay (Just 0.075) 0.50 40000
      , _learnRandomAbove = NoDecay
      -- ANN
      , _alphaANN         = ExponentialDecay Nothing 0.75 150000
      , _betaANN          = ExponentialDecay Nothing 0.75 150000
      , _deltaANN         = ExponentialDecay Nothing 0.75 150000
      , _gammaANN         = ExponentialDecay Nothing 0.75 150000
      }


actFilter :: St -> [Bool]
actFilter _  = repeat True
