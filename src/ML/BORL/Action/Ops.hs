module ML.BORL.Action.Ops
  ( NextActions
  , ActionChoice
  , WorkerActionChoice
  , nextAction
  , epsCompareWith
  ) where

import           Control.Lens
import           Control.Monad                  (zipWithM)
import           Control.Monad.IO.Class         (liftIO)
import           Control.Monad.Trans.Class      (lift)
import           Control.Monad.Trans.Reader
import           Data.Function                  (on)
import           Data.List                      (groupBy, partition, sortBy)
import           System.Random


import           ML.BORL.Algorithm
import           ML.BORL.Calculation
import           ML.BORL.Exploration
import           ML.BORL.InftyVector
import           ML.BORL.NeuralNetwork.NNConfig
import           ML.BORL.Parameters
import           ML.BORL.Properties
import           ML.BORL.Proxy.Proxies
import           ML.BORL.Proxy.Type
import           ML.BORL.Type
import           ML.BORL.Types
import           ML.BORL.Workers.Type


import           Debug.Trace

type ActionChoice s = (IsRandomAction, ActionIndexed s)
type WorkerActionChoice s = ActionChoice s
type NextActions s = (ActionChoice s, [WorkerActionChoice s])

-- | This function chooses the next action from the current state s and all possible actions.
nextAction :: (MonadBorl' m) => BORL s -> m (NextActions s)
nextAction borl = do
  mainAgent <- nextActionFor borl (borl ^. s) (params' ^. exploration)
  let nnConfigs = head $ concatMap (\l -> borl ^.. proxies . l . proxyNNConfig) (allProxiesLenses (borl ^. proxies))
  ws <- zipWithM (nextActionFor borl) (borl ^. workers . traversed . workersS) (map maxExpl $ nnConfigs ^. workersMinExploration)
  return (mainAgent, ws)
  where
    params' = (borl ^. decayFunction) (borl ^. t) (borl ^. parameters)
    maxExpl = max (params' ^. exploration)

nextActionFor :: (MonadBorl' m) => BORL s -> s -> Double -> m (ActionChoice s)
nextActionFor borl state explore
  | null as = error "Empty action list"
  | length as == 1 = return (False, head as)
  | otherwise =
    flip runReaderT cfg $
    case borl ^. parameters . explorationStrategy of
      EpsilonGreedy -> chooseAction borl True (\xs -> return $ SelectedActions (head xs) (last xs))
      SoftmaxBoltzmann t0 -> chooseAction borl False (chooseBySoftmax (t0 * explore))
  where
    cfg = ActionPickingConfig state explore
    as = actionsIndexed borl state
    state = borl ^. s

data SelectedActions s = SelectedActions
  { maximised :: [(Double, ActionIndexed s)] -- ^ Choose actions by maximising objective
  , minimised :: [(Double, ActionIndexed s)] -- ^ Choose actions by minimising objective
  }


type UseRand = Bool
type ActionSelection s = [[(Double, ActionIndexed s)]] -> IO (SelectedActions s) -- ^ Incoming actions are sorted with highest value in the head.
type RandomNormValue = Double

chooseBySoftmax :: TemperatureInitFactor -> ActionSelection s
chooseBySoftmax temp xs = do
  r <- liftIO $ randomRIO (0 :: Double, 1)
  return $ SelectedActions (xs !! chooseByProbability r 0 0 probs) (reverse xs !! chooseByProbability r 0 0 probs)
  where
    probs = softmax temp $ map (fst . head) xs

chooseByProbability :: RandomNormValue -> ActionIndex -> Double -> [Double] -> Int
chooseByProbability r idx acc [] = error $ "no more options in chooseByProbability in Action.Ops: " ++ show (r, idx, acc)
chooseByProbability r idx acc (v:vs)
  | acc + v >= r = idx
  | otherwise = chooseByProbability r (idx + 1) (acc + v) vs


data ActionPickingConfig s =
  ActionPickingConfig
    { actPickState :: s
    , actPickExpl  :: Double
    }

chooseAction :: (MonadBorl' m) => BORL s -> UseRand -> ActionSelection s -> ReaderT (ActionPickingConfig s) m (Bool, ActionIndexed s)
chooseAction borl useRand selFromList = do
  rand <- liftIO $ randomRIO (0, 1)
  state <- asks actPickState
  explore <- asks actPickExpl
  let as = actionsIndexed borl state
  lift $
    if useRand && rand < explore
      then do
        r <- liftIO $ randomRIO (0, length as - 1)
        return (True, as !! r)
      else case borl ^. algorithm of
             AlgBORL ga0 ga1 _ _ -> do
               bestRho <-
                 if isUnichain borl
                   then return as
                   else do
                     rhoVals <- mapM (rhoValue borl state . fst) as
                     map snd . maxOrMin <$> liftIO (selFromList $ groupBy (epsCompareN 0 (==) `on` fst) $ sortBy (flip compare `on` fst) (zip rhoVals as))
               bestV <-
                 do vVals <- mapM (vValue borl state . fst) bestRho
                    map snd . maxOrMin <$> liftIO (selFromList $ groupBy (epsCompareN 1 (==) `on` fst) $ sortBy (flip compare `on` fst) (zip vVals bestRho))
               if length bestV == 1
                 then return (False, head bestV)
                 else do
                   bestE <-
                     do eVals <- mapM (eValueAvgCleaned borl state . fst) bestV
                        let (increasing, decreasing) = partition ((0 <) . fst) (zip eVals bestV)
                            actionsToChooseFrom
                              | null decreasing = increasing
                              | otherwise = decreasing
                        map snd . maxOrMin <$> liftIO (selFromList $ groupBy (epsCompareWith (ga1 - ga0) (==) `on` fst) $ sortBy (flip compare `on` fst) actionsToChooseFrom)
                 -- other way of doing it:
                 -- ----------------------
                 -- do eVals <- mapM (eValue borl state . fst) bestV
                 --    rhoVal <- rhoValue borl state (fst $ head bestRho)
                 --    vVal <- vValue decideVPlusPsi borl state (fst $ head bestV) -- all a have the same V(s,a) value!
                 --    r0Values <- mapM (rValue borl RSmall state . fst) bestV
                 --    let rhoPlusV = rhoVal / (1-gamma0) + vVal
                 --        (posErr,negErr) = (map snd *** map snd) $ partition ((rhoPlusV<) . fst) (zip r0Values (zip eVals bestV))
                 --    return $ map snd $ head $ groupBy (epsCompare (==) `on` fst) $ sortBy (flip compare `on` fst) (if null posErr then negErr else posErr)
                 ----
                   if length bestE == 1 -- Uniform distributed as all actions are considered to have the same value!
                     then return (False, headE bestE)
                     else do
                       r <- liftIO $ randomRIO (0, length bestE - 1)
                       return (False, bestE !! r)
             AlgDQNAvgRewAdjusted {} -> do
               bestR1 <-
                 do r1Values <- mapM (rValue borl RBig state . fst) as -- 1. choose highest bias values
                    map snd . maxOrMin <$> liftIO (selFromList $ groupBy (epsCompareN 0 (==) `on` fst) $ sortBy (flip compare `on` fst) (zip r1Values as))
               if length bestR1 == 1
                 then return (False, head bestR1)
                 else do
                   r0Values <- mapM (rValue borl RSmall state . fst) bestR1 -- 2. choose action by epsilon-max R0 (near-Blackwell-optimal algorithm)
                   bestR0ValueActions <- liftIO $ fmap maxOrMin $ selFromList $ groupBy (epsCompareN 1 (==) `on` fst) $ sortBy (flip compare `on` fst) (zip r0Values bestR1)
                   let bestR0 = map snd bestR0ValueActions
                   if length bestR0 == 1
                     then return (False, head bestR0)
                     else do
                       r <- liftIO $ randomRIO (0, length bestR0 - 1) --  3. Uniform selection of leftover actions
                       return (False, bestR0 !! r)
             AlgBORLVOnly {} -> singleValueNextAction as EpsilonSensitive (vValue borl state . fst)
             AlgDQN _ cmp -> singleValueNextAction as cmp (rValue borl RBig state . fst)
  where
    maxOrMin =
      case borl ^. objective of
        Maximise -> maximised
        Minimise -> minimised
    headE []    = error "head: empty input data in nextAction on E Value"
    headE (x:_) = x
    headDqn []    = error "head: empty input data in nextAction on Dqn Value"
    headDqn (x:_) = x
    params' = (borl ^. decayFunction) (borl ^. t) (borl ^. parameters)
    eps = params' ^. epsilon
    -- as = actionsIndexed borl state
    epsCompareN n = epsCompareWithN n 1
    epsCompareWithN n fact = epsCompareWith (fact * getNthElement n eps)
    singleValueNextAction as cmp f = do
      rValues <- mapM f as
      let groupValues =
            case cmp of
              EpsilonSensitive -> groupBy (epsCompareN 0 (==) `on` fst) . sortBy (flip compare `on` fst)
              Exact -> groupBy ((==) `on` fst) . sortBy (flip compare `on` fst)
      bestR <- liftIO $ fmap maxOrMin $ selFromList $ groupValues (zip rValues as)
      if length bestR == 1
        then return (False, snd $ headDqn bestR)
        else do
          r <- liftIO $ randomRIO (0, length bestR - 1)
          return (False, snd $ bestR !! r)


-- | Compare values epsilon-sensitive. Must be used on a sorted list using a standard order.
--
-- > groupBy (epsCompareWith 2 (==)) $ sortBy (compare) [3,5,1]
-- > [[1,3],[5]]
-- > groupBy (epsCompareWith 2 (==)) $ sortBy (flip compare) [3,5,1]
-- > [[5,3],[1]]
--
epsCompareWith :: (Ord t, Num t) => t -> (t -> t -> p) -> t -> t -> p
epsCompareWith eps f x y
  | abs (x - y) <= eps = f 0 0
  | otherwise = y `f` x

