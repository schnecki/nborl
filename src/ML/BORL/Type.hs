{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

module ML.BORL.Type
  ( -- objective
    Objective (..)
  , setObjective
  , flipObjective
    -- common
  , RewardFutureData (..)
  , futurePeriod
  , futureState
  , futureActionNr
  , futureRandomAction
  , futureReward
  , futureStateNext
  , futureEpisodeEnd
  , mapRewardFutureData
  , idxStart
    -- BORL
  , BORL (..)
  , actionList
  , actionFilter
  , s
  , workers
  , featureExtractor
  , t
  , episodeNrStart
  , parameters
  , settings
  , decaySetting
  , decayedParameters
  , futureRewards
  , algorithm
  , expSmoothedReward
  , objective
  , lastVValues
  , lastRewards
  , psis
  , proxies
    -- actions
  , actionIndicesFiltered
  , actionsFiltered
    -- initial values
  , InitValues (..)
  , defInitValues
    -- constructors
  , mkUnichainTabular
  , mkMultichainTabular

  , mkUnichainGrenade
  , mkUnichainGrenadeCombinedNet
  , mkMultichainGrenade

    -- scaling
  , scalingByMaxAbsReward
  , scalingByMaxAbsRewardAlg
    -- proxy/proxies helpers
  , overAllProxies
  , setAllProxies
  , allProxies
  ) where

import           Control.DeepSeq
import           Control.Lens
import           Control.Monad                (join, replicateM)
import           Control.Monad.IO.Class       (liftIO)
import           Data.Default                 (def)
import           Data.List                    (foldl', zipWith3)
import           Data.Maybe                   (catMaybes, fromMaybe)
import qualified Data.Proxy                   as Type
import           Data.Serialize
import           Data.Singletons              (SingI, sing)
import           Data.Singletons.Prelude.List
import qualified Data.Text                    as T
import           Data.Typeable                (Typeable)
import qualified Data.Vector                  as VB
import qualified Data.Vector.Mutable          as VM
import qualified Data.Vector.Storable         as V
import           GHC.Generics
import           GHC.TypeLits
import           Grenade


import           ML.BORL.Action.Type
import           ML.BORL.Algorithm
import           ML.BORL.Decay
import           ML.BORL.NeuralNetwork
import           ML.BORL.Parameters
import           ML.BORL.Proxy.Proxies
import           ML.BORL.Proxy.Type
import           ML.BORL.RewardFuture
import           ML.BORL.Settings
import           ML.BORL.Types
import           ML.BORL.Workers.Type


import           Debug.Trace


-------------------- Main RL Datatype --------------------

-- type ActionIndexed s = ([ActionIndex], Action s)     -- ^ One action index for each agent is associated to one action transition.
-- -- type FilteredActions s = VB.Vector (ActionIndexed s) -- ^ A list of actions


-- [ActionIndex] -> Action s
-- [[ActionIndex]]


data Objective
  = Minimise
  | Maximise
  deriving (Eq, Ord, NFData, Generic, Show, Serialize)

data BORL s as = BORL
  { _actionList        :: !(VB.Vector (Action as)) -- ^ List of possible actions each agent. All agents can do the same actions!
  , _actionFunction    :: !(ActionFunction s as)   -- ^ Action function that traverses the system from s to s' using a list of actions, one for each agent.
  , _actionFilter      :: !(ActionFilter s)        -- ^ Function to filter actions in state s.
  , _s                 :: !s                       -- ^ Current state.
  , _workers           :: !(Workers s)             -- ^ Additional workers. (Workers s = [WorkerState s])

  , _featureExtractor  :: !(FeatureExtractor s)    -- ^ Function that extracts the features of a state.
  , _t                 :: !Int                     -- ^ Current time t.
  , _episodeNrStart    :: !(Int, Int)              -- ^ Nr of Episode and start period.
  , _parameters        :: !ParameterInitValues     -- ^ Parameter setup.
  , _decaySetting      :: !ParameterDecaySetting   -- ^ Decay Setup
  , _settings          :: !Settings                -- ^ Parameter setup.
  , _futureRewards     :: ![RewardFutureData s]    -- ^ List of future reward.

  -- define algorithm to use
  , _algorithm         :: !(Algorithm StateFeatures) -- ^ What algorithm to use.
  , _objective         :: !Objective                 -- ^ Objective to minimise or maximise.

  -- Values:
  , _expSmoothedReward :: !Float                 -- ^ Exponentially smoothed reward value (with rate 0.0001).
  , _lastVValues       :: ![Value]               -- ^ List of X last V values (head is last seen value)
  , _lastRewards       :: ![Float]               -- ^ List of X last rewards (head is last received reward)
  , _psis              :: !(Float, Float, Float) -- ^ Exponentially smoothed psi values.
  , _proxies           :: !Proxies               -- ^ Scalar, Tables and Neural Networks
  }
makeLenses ''BORL

instance (NFData as, NFData s) => NFData (BORL s as) where
  rnf (BORL as _ af st ws ftExt time epNr par setts dec fut alg ph expSmth lastVs lastRews psis' proxies') =
    rnf as `seq` rnf af `seq` rnf st `seq` rnf ws `seq` rnf ftExt `seq` rnf time `seq`
    rnf epNr `seq` rnf par `seq` rnf dec `seq` rnf setts `seq` rnf1 fut `seq` rnf alg `seq` rnf ph `seq` rnf expSmth `seq`
    rnf1 lastVs `seq` rnf1 lastRews  `seq` rnf psis' `seq` rnf proxies'


decayedParameters :: BORL s as -> ParameterDecayedValues
decayedParameters borl
  | borl ^. t < repMemSubSize = mkStaticDecayedParams decayedParams
  | otherwise = decayedParams
  where
    decayedParams = decaySettingParameters (borl ^. decaySetting) (borl ^. t - repMemSubSize) (borl ^. parameters)
    repMemSubSize = maybe 0 replayMemoriesSubSize (borl ^. proxies . replayMemory)

------------------------------ Indexed Action ------------------------------

-- | Get the filtered actions of the current given state and with the ActionFilter set in BORL.
actionIndicesFiltered :: BORL s as -> s -> FilteredActionIndices
actionIndicesFiltered borl state = map (\fil -> V.ifilter (\idx _ -> fil V.! idx) actionIndices) filterVals
  where
    filterVals :: [V.Vector Bool]
    filterVals = (borl ^. actionFilter) state
    actionIndices = V.fromList [0 .. length (borl ^. actionList) - 1]


-- | Get the filtered actions of the current given state and with the ActionFilter set in BORL.
actionsFiltered :: BORL s as -> s -> FilteredActions as
actionsFiltered borl state = map (\fil -> VB.ifilter (\idx _ -> fil V.! idx) (borl ^. actionList)) filterVals
  where
    filterVals :: [V.Vector Bool]
    filterVals = (borl ^. actionFilter) state


-- -- | Get a list of filtered actions with the actions list and the filter function for the current given state.
-- filteredActions :: [Action a] -> (s -> V.Vector Bool) -> s -> [Action a]
-- filteredActions actions actFilter state = map snd $ filter (\(idx, _) -> actFilter state V.! idx) $ zip [(0 :: Int) ..] actions

-- -- | Get a list of filtered action indices with the actions list and the filter function for the current given state.
-- filteredActionIndexes :: [Action a] -> (s -> V.Vector Bool) -> s -> [ActionIndex]
-- filteredActionIndexes actions actFilter state = map fst $ filter (\(idx,_) -> actFilter state V.! idx) $ zip [(0::Int)..] actions


------------------------------ Initial Values ------------------------------

idxStart :: Int
idxStart = 0

data InitValues = InitValues
  { defaultRho        :: !Float -- ^ Starting rho value [Default: 0]
  , defaultRhoMinimum :: !Float -- ^ Starting minimum value (when objective is Maximise, otherwise if the objective is Minimise it's the Maximum rho value) [Default: 0]
  , defaultV          :: !Float -- ^ Starting V value [Default: 0]
  , defaultW          :: !Float -- ^ Starting W value [Default: 0]
  , defaultR0         :: !Float -- ^ Starting R0 value [Default: 0]
  , defaultR1         :: !Float -- ^ starting R1 value [Default: 0]
  }


defInitValues :: InitValues
defInitValues = InitValues 0 0 0 0 0 0


-------------------- Objective --------------------

setObjective :: Objective -> BORL s as -> BORL s as
setObjective obj = objective .~ obj

-- | Default objective is Maximise.
flipObjective :: BORL s as -> BORL s as
flipObjective borl = case borl ^. objective of
  Minimise -> objective .~ Maximise $ borl
  Maximise -> objective .~ Minimise $ borl


-------------------- Constructors --------------------

-- Tabular representations

convertAlgorithm :: FeatureExtractor s -> Algorithm s -> Algorithm StateFeatures
convertAlgorithm ftExt (AlgBORL g0 g1 avgRew (Just (s, a))) = AlgBORL g0 g1 avgRew (Just (ftExt s, a))
convertAlgorithm ftExt (AlgBORLVOnly avgRew (Just (s, a))) = AlgBORLVOnly avgRew (Just (ftExt s, a))
convertAlgorithm _ (AlgBORL g0 g1 avgRew Nothing) = AlgBORL g0 g1 avgRew Nothing
convertAlgorithm _ (AlgBORLVOnly avgRew Nothing) = AlgBORLVOnly avgRew Nothing
convertAlgorithm _ (AlgDQN ga cmp) = AlgDQN ga cmp
convertAlgorithm _ (AlgDQNAvgRewAdjusted ga1 ga2 avgRew) = AlgDQNAvgRewAdjusted ga1 ga2 avgRew

mkUnichainTabular ::
     forall s as. (Enum as, Bounded as, Eq as, Ord as, NFData as)
  => Algorithm s
  -> InitialStateFun s
  -> FeatureExtractor s
  -> ActionFunction s as
  -> ActionFilter s
  -> ParameterInitValues
  -> ParameterDecaySetting
  -> Settings
  -> Maybe InitValues
  -> IO (BORL s as)
mkUnichainTabular alg initialStateFun ftExt asFun asFilter params decayFun settings initVals = do
  st <- initialStateFun MainAgent
  let proxies' = Proxies (Scalar $ V.replicate agents defRhoMin) (Scalar $ V.replicate agents defRho) (tabSA 0) (tabSA defV) (tabSA 0) (tabSA defW) (tabSA defR0) (tabSA defR1) Nothing
  workers' <- liftIO $ mkWorkers initialStateFun as Nothing settings
  return $ BORL
    (VB.fromList as)
    asFun
    asFilter
    st
    workers'
    ftExt
    0
    (0, 0)
    params
    decayFun
    settings
    mempty
    (convertAlgorithm ftExt alg)
    Maximise
    defRhoMin
    mempty
    mempty
    (0, 0, 0)
    proxies'
  where
    as = [minBound .. maxBound] :: [Action as]
    tabSA def = Table mempty def (length as)
    defRhoMin = defaultRhoMinimum (fromMaybe defInitValues initVals)
    defRho = defaultRho (fromMaybe defInitValues initVals)
    defV = V.replicate agents $ defaultV (fromMaybe defInitValues initVals)
    defW = V.replicate agents $ defaultW (fromMaybe defInitValues initVals)
    defR0 = V.replicate agents $ defaultR0 (fromMaybe defInitValues initVals)
    defR1 = V.replicate agents $ defaultR1 (fromMaybe defInitValues initVals)
    agents = settings ^. independentAgents

mkMultichainTabular ::
     forall s as. (Bounded as, Enum as, Eq as, Ord as, NFData as) =>
     Algorithm s
  -> InitialStateFun s
  -> FeatureExtractor s
  -> ActionFunction s as
  -> ActionFilter s
  -> ParameterInitValues
  -> ParameterDecaySetting
  -> Settings
  -> Maybe InitValues
  -> IO (BORL s as)
mkMultichainTabular alg initialStateFun ftExt asFun asFilter params decayFun settings initValues = do
  initialState <- initialStateFun MainAgent
  return $
    BORL
      (VB.fromList as)
      asFun
      asFilter
      initialState
      []
      ftExt
      0
      (0, 0)
      params
      decayFun
      settings
      mempty
      (convertAlgorithm ftExt alg)
      Maximise
      0
      mempty
      mempty
      (0, 0, 0)
      (Proxies (tabSA defRhoMin) (tabSA defRho) (tabSA 0) (tabSA defV) (tabSA 0) (tabSA defW) (tabSA defR0) (tabSA defR1) Nothing)
  where
    as = [minBound .. maxBound] :: [Action as]
    tabSA def = Table mempty def (length as)
    defRhoMin = V.replicate agents $ defaultRhoMinimum (fromMaybe defInitValues initValues)
    defRho = V.replicate agents $ defaultRho (fromMaybe defInitValues initValues)
    defV = V.replicate agents $ defaultV (fromMaybe defInitValues initValues)
    defW = V.replicate agents $ defaultW (fromMaybe defInitValues initValues)
    defR0 = V.replicate agents $ defaultR0 (fromMaybe defInitValues initValues)
    defR1 = V.replicate agents $ defaultR1 (fromMaybe defInitValues initValues)
    agents = settings ^. independentAgents

-- Neural network approximations

mkUnichainGrenade ::
  forall s as . (Eq as, NFData as, Ord as, Bounded as, Enum as) =>
     Algorithm s
  -> InitialStateFun s
  -> FeatureExtractor s
  -> ActionFunction s as
  -> ActionFilter s
  -> ParameterInitValues
  -> ParameterDecaySetting
  -> (Integer -> IO SpecConcreteNetwork)
  -> NNConfig
  -> Settings
  -> Maybe InitValues
  -> IO (BORL s as)
mkUnichainGrenade alg initialStateFun ftExt as asFilter params decayFun netFun nnConfig settings initValues = do
  specNet <- netFun 1
  case specNet of
    SpecConcreteNetwork1D1D{} -> netFun 1 >>= (\(SpecConcreteNetwork1D1D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig settings initValues net)
    SpecConcreteNetwork1D2D{} -> netFun 1 >>= (\(SpecConcreteNetwork1D2D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig settings initValues net)
    SpecConcreteNetwork1D3D{} -> netFun 1 >>= (\(SpecConcreteNetwork1D3D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig settings initValues net)
    _ -> error "BORL currently requieres a 1D input and either 1D our 2D output"
    -- also fix in Serialisable if enabled!!!
    -- SpecConcreteNetwork2D1D{} -> netFun 1 >>= (\(SpecConcreteNetwork2D1D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork2D2D{} -> netFun 1 >>= (\(SpecConcreteNetwork2D2D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork2D3D{} -> netFun 1 >>= (\(SpecConcreteNetwork2D3D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork3D1D{} -> netFun 1 >>= (\(SpecConcreteNetwork3D1D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork3D2D{} -> netFun 1 >>= (\(SpecConcreteNetwork3D2D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork3D3D{} -> netFun 1 >>= (\(SpecConcreteNetwork3D3D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)


-- | Modelbuilder takes the number of output columns, which determins if the ANN is 1D or 2D! (#actions, #columns, 1)
mkUnichainGrenadeCombinedNet ::
     forall as s . (Eq as, Ord as, NFData as, Enum as, Bounded as) =>
     Algorithm s
  -> InitialStateFun s
  -> FeatureExtractor s
  -> ActionFunction s as
  -> ActionFilter s
  -> ParameterInitValues
  -> ParameterDecaySetting
  -> (Integer -> IO SpecConcreteNetwork)
  -> NNConfig
  -> Settings
  -> Maybe InitValues
  -> IO (BORL s as)
mkUnichainGrenadeCombinedNet alg initialStateFun ftExt as asFilter params decayFun netFun nnConfig settings initValues = do
  let nrNets | isAlgDqn alg = 1
             | isAlgDqnAvgRewardAdjusted alg = 2
             | otherwise = 6
  specNet <- netFun nrNets
  case specNet of
    SpecConcreteNetwork1D1D{} -> netFun nrNets >>= (\(SpecConcreteNetwork1D1D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig settings initValues net)
    SpecConcreteNetwork1D2D{} -> netFun nrNets >>= (\(SpecConcreteNetwork1D2D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig settings initValues net)
    SpecConcreteNetwork1D3D{} -> netFun nrNets >>= (\(SpecConcreteNetwork1D3D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig settings initValues net)
    _ -> error "BORL currently requieres a 1D input and either 1D our 2D output"
    -- SpecConcreteNetwork2D1D{} -> netFun nrNets >>= (\(SpecConcreteNetwork2D1D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork2D2D{} -> netFun nrNets >>= (\(SpecConcreteNetwork2D2D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork2D3D{} -> netFun nrNets >>= (\(SpecConcreteNetwork2D3D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork3D1D{} -> netFun nrNets >>= (\(SpecConcreteNetwork3D1D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork3D2D{} -> netFun nrNets >>= (\(SpecConcreteNetwork3D2D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)
    -- SpecConcreteNetwork3D3D{} -> netFun nrNets >>= (\(SpecConcreteNetwork3D3D net) -> mkUnichainGrenadeHelper alg initialStateFun ftExt as asFilter params decayFun nnConfig initValues net)


mkUnichainGrenadeHelper ::
     forall as s layers shapes nrH.
     ( Enum as, Bounded as, Eq as, Ord as, NFData as
     , GNum (Gradients layers)
     , FoldableGradient (Gradients layers)
     , KnownNat nrH
     , Typeable layers
     , Typeable shapes
     , Head shapes ~ 'D1 nrH
     , SingI (Last shapes)
     , NFData (Tapes layers shapes)
     , NFData (Gradients layers)
     , NFData (Network layers shapes)
     , Serialize (Gradients layers)
     , Serialize (Network layers shapes)
     , Show (Network layers shapes)
     , FromDynamicLayer (Network layers shapes)
     , GNum (Network layers shapes)
     )
  => Algorithm s
  -> InitialStateFun s
  -> FeatureExtractor s
  -> ActionFunction s as
  -> ActionFilter s
  -> ParameterInitValues
  -> ParameterDecaySetting
  -> NNConfig
  -> Settings
  -> Maybe InitValues
  -> Network layers shapes
  -> IO (BORL s as)
mkUnichainGrenadeHelper alg initialStateFun ftExt asFun asFilter params decayFun nnConfig settings initValues net = do
  putStrLn "Using following Greande Specification: "
  print $ networkToSpecification net
  putStrLn "Net: "
  print net
  repMem <- mkReplayMemories as settings nnConfig
  let nnConfig' = set replayMemoryMaxSize (maybe 1 replayMemoriesSize repMem) nnConfig
  let nnSA tp = Grenade net net tp nnConfig' (length as) (settings ^. independentAgents)
  let nnSAVTable = nnSA VTable
  let nnSAWTable = nnSA WTable
  let nnSAR0Table = nnSA R0Table
  let nnSAR1Table = nnSA R1Table
  let nnPsiV = nnSA PsiVTable
  let nnPsiW = nnSA PsiWTable
  let nnType
        | isAlgDqnAvgRewardAdjusted alg = CombinedUnichain -- ScaleAs VTable
        | otherwise = CombinedUnichain
  let nnComb = nnSA nnType
  initialState <- initialStateFun MainAgent
  let proxies' =
        case (sing :: Sing (Last shapes)) of
          D1Sing SNat -> Proxies (Scalar $ V.replicate agents defRhoMin) (Scalar $ V.replicate agents defRho) nnPsiV nnSAVTable nnPsiW nnSAWTable nnSAR0Table nnSAR1Table repMem
          D2Sing SNat SNat -> ProxiesCombinedUnichain (Scalar $ V.replicate agents defRhoMin) (Scalar $ V.replicate agents defRho) nnComb repMem
          _ -> error "3D output is not supported by BORL!"
  workers' <- liftIO $ mkWorkers initialStateFun as (Just nnConfig) settings
  return $
    BORL
      (VB.fromList as)
      asFun
      asFilter
      initialState
      workers'
      ftExt
      0
      (0, 0)
      params
      decayFun
      settings
      []
      (convertAlgorithm ftExt alg)
      Maximise
      defRhoMin
      mempty
      mempty
      (0, 0, 0)
      proxies'
  where
    as = [minBound..maxBound] :: [Action as]
    defRho = defaultRho (fromMaybe defInitValues initValues)
    defRhoMin = defaultRhoMinimum (fromMaybe defInitValues initValues)
    agents = settings ^. independentAgents

mkMultichainGrenade ::
     forall as nrH nrL s layers shapes.
     ( Enum as, Bounded as, Eq as, Ord as, NFData as
     , GNum (Gradients layers)
     , GNum (Network layers shapes)
     , FoldableGradient (Gradients layers)
     , Typeable layers
     , Typeable shapes
     , KnownNat nrH
     , Head shapes ~ 'D1 nrH
     , KnownNat nrL
     , Last shapes ~ 'D1 nrL
     , NFData (Tapes layers shapes)
     , NFData (Gradients layers)
     , NFData (Network layers shapes)
     , Serialize (Network layers shapes)
     , Serialize (Gradients layers)
     , FromDynamicLayer (Network layers shapes)
     , NFData s
     )
  => Algorithm s
  -> InitialStateFun s
  -> FeatureExtractor s
  -> ActionFunction s as
  -> ActionFilter s
  -> ParameterInitValues
  -> ParameterDecaySetting
  -> Network layers shapes
  -> NNConfig
  -> Settings
  -> Maybe InitValues
  -> IO (BORL s as)
mkMultichainGrenade alg initialStateFun ftExt asFun asFilter params decayFun net nnConfig settings initVals = do
  repMem <- mkReplayMemories as settings nnConfig
  let nnConfig' = set replayMemoryMaxSize (maybe 1 replayMemoriesSize repMem) nnConfig
  let nnSA tp = Grenade net net tp nnConfig' (length as) (settings ^. independentAgents)
  let nnSAMinRhoTable = nnSA VTable
  let nnSARhoTable = nnSA VTable
  let nnSAVTable = nnSA VTable
  let nnSAWTable = nnSA WTable
  let nnSAR0Table = nnSA R0Table
  let nnSAR1Table = nnSA R1Table
  let nnPsiV = nnSA PsiVTable
  let nnPsiW = nnSA PsiWTable
  initialState <- initialStateFun MainAgent
  let proxies' = Proxies nnSAMinRhoTable nnSARhoTable nnPsiV nnSAVTable nnPsiW nnSAWTable nnSAR0Table nnSAR1Table repMem
  workers <- liftIO $ mkWorkers initialStateFun as (Just nnConfig) settings
  return $! force $
    BORL
      (VB.fromList as)
      asFun
      asFilter
      initialState
      workers
      ftExt
      0
      (0, 0)
      params
      decayFun
      settings
      []
      (convertAlgorithm ftExt alg)
      Maximise
      defRhoMin
      mempty
      mempty
      (0, 0, 0)
      proxies'
  where
    as = [minBound..maxBound] :: [Action as]
    defRhoMin = defaultRhoMinimum (fromMaybe defInitValues initVals)

------------------------------ Replay Memory/Memories ------------------------------

mkReplayMemories :: [Action as] -> Settings -> NNConfig -> IO (Maybe ReplayMemories)
mkReplayMemories = mkReplayMemories' False

mkReplayMemories' :: Bool -> [Action as] -> Settings -> NNConfig -> IO (Maybe ReplayMemories)
mkReplayMemories' allowSz1 as setts nnConfig =
  case nnConfig ^. replayMemoryStrategy of
    ReplayMemorySingle -> fmap ReplayMemoriesUnified <$> mkReplayMemory allowSz1 repMemSizeSingle
    ReplayMemoryPerAction -> do
      tmpRepMem <- mkReplayMemory allowSz1 (setts ^. nStep)
      fmap (ReplayMemoriesPerActions tmpRepMem) . sequence . VB.fromList <$> replicateM (length as) (mkReplayMemory allowSz1 repMemSizePerAction)
  where
    repMemSizeSingle = max (nnConfig ^. replayMemoryMaxSize) (setts ^. nStep * nnConfig ^. trainBatchSize)
    repMemSizePerAction = (size `div` (setts ^. nStep)) * (setts ^. nStep)
      where
        size = -- repMemSizeSingle

          max (ceiling $ fromIntegral (nnConfig ^. replayMemoryMaxSize) / fromIntegral (length as)) (setts ^. nStep)


mkReplayMemory :: Bool -> Int -> IO (Maybe ReplayMemory)
mkReplayMemory allowSz1 sz | sz <= 1 && not allowSz1 = return Nothing
mkReplayMemory _ sz = do
  vec <- VM.new sz
  return $ Just $ ReplayMemory vec sz 0 (-1)


-------------------- Other Constructors --------------------

-- | Infer scaling by maximum reward.
scalingByMaxAbsReward :: Bool -> Float -> ScalingNetOutParameters
scalingByMaxAbsReward onlyPositive maxR = ScalingNetOutParameters (-maxV) maxV (-maxW) maxW (if onlyPositive then 0 else -maxR0) maxR0 (if onlyPositive then 0 else -maxR1) maxR1
  where maxDiscount g = sum $ take 10000 $ map (\p -> (g^p) * maxR) [(0::Int)..]
        maxV = 1.0 * maxR
        maxW = 50 * maxR
        maxR0 = 2 * maxDiscount defaultGamma0
        maxR1 = 1.0 * maxDiscount defaultGamma1

scalingByMaxAbsRewardAlg :: Algorithm s -> Bool -> Float -> ScalingNetOutParameters
scalingByMaxAbsRewardAlg alg onlyPositive maxR =
  case alg of
    AlgDQNAvgRewAdjusted{} -> ScalingNetOutParameters (-maxR1) maxR1 (-maxW) maxW (-maxR1) maxR1 (-maxR1) maxR1
    _ -> scalingByMaxAbsReward onlyPositive maxR
  where
    maxW = 50 * maxR
    maxR1 = 1.0 * maxR

-- | Creates the workers data structure if applicable (i.e. there is a replay memory of size >1 AND the minimum
-- expoloration rates are configured in NNConfig).
mkWorkers :: InitialStateFun s -> [Action as] -> Maybe NNConfig -> Settings -> IO (Workers s)
mkWorkers state as mNNConfig setts = do
  let nr = length $ setts ^. workersMinExploration
      workerTypes = map WorkerAgent [1 .. nr]
  if nr <= 0
    then return []
    else do
      repMems <- replicateM nr (maybe (fmap ReplayMemoriesUnified <$> mkReplayMemory True (setts ^. nStep)) (mkReplayMemories' True as setts) mNNConfig)
      states <- mapM state workerTypes
      return $ zipWith3 (\wNr st rep -> WorkerState wNr st (fromMaybe err rep) [] 0) [1..] states repMems
        where err = error $ "Could not create replay memory for workers with nStep=" ++ show (setts ^. nStep) ++ " and memMaxSize=" ++ show (view replayMemoryMaxSize <$> mNNConfig)

-------------------- Helpers --------------------


-- | Perform an action over all proxies (combined proxies are seen once only).
overAllProxies :: ((a -> Identity b) -> Proxy -> Identity Proxy) -> (a -> b) -> BORL s as -> BORL s as
overAllProxies l f borl = foldl' (\b p -> over (proxies . p . l) f b) borl (allProxiesLenses (borl ^. proxies))

setAllProxies :: ((a -> Identity b) -> Proxy -> Identity Proxy) -> b -> BORL s as -> BORL s as
setAllProxies l = overAllProxies l . const

allProxies :: Proxies -> [Proxy]
allProxies pxs = map (pxs ^. ) (allProxiesLenses pxs)
