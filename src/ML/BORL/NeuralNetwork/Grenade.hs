{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

module ML.BORL.NeuralNetwork.Grenade
    ( trainGrenade
    , runGrenade
    ) where

import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.DeepSeq
import           Control.Lens                     (set, (^.))
import           Control.Monad                    (unless, void, when)
import           Control.Parallel.Strategies
import           Data.IORef
import           Data.List                        (foldl', foldl1, genericLength)
import qualified Data.Map.Strict                  as M
import           Data.Maybe                       (fromMaybe)
import           Data.Proxy
import           Data.Singletons
import           Data.Singletons.Prelude.List
import           Data.Time.Clock
import qualified Data.Vector.Storable             as V
import           GHC.TypeLits
import           Grenade
import           System.IO.Unsafe                 (unsafePerformIO)

import           ML.BORL.Fork
import           ML.BORL.NeuralNetwork.Conversion
import           ML.BORL.NeuralNetwork.NNConfig
import           ML.BORL.Types


import           Debug.Trace

executionTimeMVar :: MVar NominalDiffTime
executionTimeMVar = unsafePerformIO $ newMVar 0
{-# NOINLINE executionTimeMVar #-}


gradientsMVar :: MVar [IORef (ThreadState (Gradients layers))]
gradientsMVar = unsafePerformIO $ newMVar []
{-# NOINLINE gradientsMVar #-}

-- | Add some gradients to the shared list of gradients.
putGradients :: IORef (ThreadState (Gradients layers)) -> IO ()
putGradients val = modifyMVar_ gradientsMVar (return . (++ [val]))

-- | Retrieve the ready gradients for updating the network.
getGradients :: IO [Gradients layers]
getGradients = modifyMVar gradientsMVar collectAllReadyGradients
  where
    collectAllReadyGradients grads = do
      ready <- collRess grads
      return (drop (length ready) grads, ready)
    collRess [] = return []
    collRess (ref:xs) = do
      mRes <- readIORef ref
      case mRes of
        Ready a -> do
          rs <- collRess xs
          return (a : rs)
        NotReady -> return []

-- | Train grenade network.
trainGrenade ::
     forall layers shapes nrH opt.
     ( GNum (Gradients layers)
     , NFData (Network layers shapes)
     , NFData (Tapes layers shapes)
     , KnownNat nrH
     , 'D1 nrH ~ Head shapes
     , SingI (Last shapes)
     , NFData (Gradients layers)
     , FoldableGradient (Gradients layers)
     )
  => Period
  -> Optimizer opt
  -> NNConfig
  -> Network layers shapes
  -> [[((StateFeatures, ActionIndex), Double)]]
  -> IO (Network layers shapes)
trainGrenade period opt nnConfig net chs = do
  let trainIter = nnConfig ^. trainingIterations
      cropFun = maybe id (\x -> max (-x) . min x) (nnConfig ^. cropTrainMaxValScaled)
      ~batchGradients = parMap (rparWith rdeepseq) (makeGradients cropFun net) chs
      ~clipGrads =
        case nnConfig ^. clipGradients of
          NoClipping         -> id
          ClipByGlobalNorm v -> clipByGlobalNorm v
          ClipByValue v      -> clipByValue v
      -- res = foldl' (applyUpdate opt) net batchGradients
      ~res =
        -- applyUpdate opt net $
        clipGrads $
        -- 1/sum (map genericLength batchGradients) |* -- better to use avg?!!? also for RL?: https://stats.stackexchange.com/questions/183840/sum-or-average-of-gradients-in-mini-batch-gradient-decent
        -- foldl1 (zipVectorsWithInPlaceReplSnd (+)) batchGradients
        -- foldl1 (|+) batchGradients
        sumG batchGradients

  execTime0 <- fromMaybe 0 <$> tryReadMVar executionTimeMVar
  if execTime0 < 0.2 || period `mod` 3000 == 0
    then do
      start <- getCurrentTime
      let !net' = force $ applyUpdate opt net res
      end <- getCurrentTime
      let execTime = diffUTCTime end start
      modifyMVar_ executionTimeMVar (\_ -> return execTime)
      return $! net'
    else do
    doFork (return res) >>= putGradients
    grads <- getGradients
    if null grads
      then return net
      else return $! foldl (applyUpdate opt) net grads
    -- if trainIter <= 1
    --     then return res
    --     else trainGrenade period opt (set trainingIterations (trainIter - 1) nnConfig) res chs

-- | Accumulate gradients for a list of n-step updates. The arrising gradients are summed up.
makeGradients ::
     forall layers shapes nrH. (GNum (Gradients layers), NFData (Tapes layers shapes), NFData (Gradients layers), KnownNat nrH, 'D1 nrH ~ Head shapes, SingI (Last shapes))
  => (Double -> Double)
  -> Network layers shapes
  -> [((StateFeatures, ActionIndex), Double)]
  -> Gradients layers
makeGradients _ _ [] = error "Empty list of n-step updates in NeuralNetwork.Grenade"
makeGradients cropFun net chs
  | length chs == 1 =
    -- trace ("chs: " ++ show chs ++ "inputs: " ++ show inputs ++ "\noutputs: " ++ show outputs ++ "\nlabels:" ++ show labels)
    head $ parMap (rparWith rdeepseq) (\(tape, output, label) -> fst $ runGradient net tape (mkLoss (toLastShapes net output) (toLastShapes net label))) (zip3 tapes outputs labels)
  | otherwise =
    -- foldl1 (zipVectorsWithInPlaceReplSnd (+)) $
    -- foldl1 (|+) $
    sumG $
    parMap (rparWith rdeepseq) (\(tape, output, label) -> fst $ runGradient net tape (mkLoss (toLastShapes net output) (toLastShapes net label))) (zip3 tapes outputs labels)
  where
    -- valueMap = foldl' (\m ((inp, acts), AgentValue outs) -> M.insertWith (++) inp (zipWith (\act out -> (act, cropFun out)) acts outs) m) mempty chs
    -- valueMap :: M.Map StateFeatures [(ActionIndex, Double)]
    -- valueMap = foldl' (\m ((inp, act), out) -> M.insertWith (++) inp [(act, cropFun out)] m) mempty chs
    -- inputs = M.keys valueMap
    -- (tapes, outputs) = unzip $ parMap (rparWith rdeepseq) (fromLastShapesVector net . runNetwork net . toHeadShapes net) inputs
    -- labels = zipWith (V.//) outputs (M.elems valueMap)
    -- valueMap :: M.Map StateFeatures [(ActionIndex, Double)]
    -- valueMap = foldl' (\m ((inp, act), out) -> M.insertWith (++) inp [(act, cropFun out)] m) mempty chs
    inputs = map (fst.fst) chs
    (tapes, outputs) = unzip $ parMap (rparWith rdeepseq) (fromLastShapesVector net . runNetwork net . toHeadShapes net) inputs
    labels = zipWith (V.//) outputs (map (\((_,act),out) -> [(act, cropFun out)]) chs)

runGrenade :: (KnownNat nr, Head shapes ~ 'D1 nr) => Network layers shapes -> NrActions -> NrAgents -> StateFeatures -> [Values]
runGrenade net nrAs nrAgents st = snd $ fromLastShapes net nrAs nrAgents $ runNetwork net (toHeadShapes net st)


mkLoss :: (Show a, Fractional a) => a -> a -> a
mkLoss o t =

  let l = o-t in
     -- trace ("o: " ++ show o ++ "\n" ++
     -- "t: " ++ show t ++ "\n" ++
     -- "l: " ++ show l ++ "\n" ++
     -- "r: " ++ show (0.5 * signum l * l^(2::Int))) undefined $


    -- 0.5 * signum l * l^(2::Int)
    signum l * l^(2::Int)
