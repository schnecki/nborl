module ML.BORL.Step
    ( step
    , stepExecute
    , nextAction
    ) where

import           ML.BORL.Action
import           ML.BORL.Parameters
import           ML.BORL.Properties
import           ML.BORL.Proxy       as P
import           ML.BORL.Type

import           Control.Applicative ((<|>))
import           Control.Lens
import           Control.Monad
import           Data.Function       (on)
import           Data.List           (groupBy, sortBy)
import qualified Data.Map.Strict     as M
import           System.Random

step :: (Ord s) => BORL s -> IO (BORL s)
step borl = nextAction borl >>= stepExecute borl

stepExecute :: (Ord s) => BORL s -> (Bool, ActionIndexed s) -> IO (BORL s)
stepExecute borl (randomAction, act@(aNr, Action action _)) = do
  let state = borl ^. s
  (reward, stateNext) <- action state
  let mv = borl ^. v
      mw = borl ^. w
      mr0 = borl ^. r0
      mr1 = borl ^. r1
  let bta = borl ^. parameters . beta
      alp = borl ^. parameters . alpha
      dlt = borl ^. parameters . delta
      (ga0, ga1) = borl ^. gammas
      period = borl ^. t
  let vValState = vValue borl state act
      vValStateNext = vStateValue borl stateNext
      rhoVal = rhoValue borl state act
      wValState = wValue borl state act
      wValStateNext = wStateValue borl state
      r0ValState = rValue borl RSmall state act
      r1ValState = rValue borl RBig state act
  let label = (state,aNr)


  let rhoState | isUnichain borl  = reward + vValStateNext - vValState
               | otherwise = (100 * rhoStateValue borl stateNext + reward) / 101 -- approximation
      -- rhoState = reward
      rhoVal' = (1 - alp) * rhoVal + alp * rhoState

      -- multichain use exponential smoothing with g + Pg = 0
      rhoNew = case borl ^. rho of
        Left _  -> Left rhoVal'
        Right m -> Right (P.insert period label rhoVal' m)
      psiRho = rhoVal' - rhoVal                                         -- should converge to 0

  let vValState'  = (1 - bta) * vValState + bta * (reward - rhoVal' + vValStateNext)
      psiV = - reward + rhoVal' + vValState' - vValStateNext             -- should converge to 0

  let wValState' = (1 - dlt) * wValState + dlt * (-vValState' + wValStateNext)
      psiW = vValState' + wValState' - wValStateNext                    -- should converge to 0

  let r0ValState' = (1 - bta) * r0ValState + bta * (reward + ga0 * rStateValue borl RSmall stateNext)
      r1ValState' = (1 - bta) * r1ValState + bta * (reward + ga1 * rStateValue borl RBig stateNext)
      params' = (borl ^. decayFunction) (period + 1) (borl ^. parameters)

  let (psiValRho,psiValV,psiValW) = borl ^. psis
      psiValRho' = (1-0.03) * psiValRho + 0.03 * abs psiRho
      psiValV' = (1-0.03) * psiValV + 0.03 * abs psiV
      psiValW' = (1-0.03) * psiValW + 0.03 * abs psiW

  -- enforce values
  let vValStateNew = vValState' - if randomAction || psiValV' > borl ^. parameters.zeta then 0 else borl ^. parameters.xi * psiW
      -- wValStateNew = wValState' - if randomAction then 0 else (1-borl ^. parameters.xi) * psiW

  let borl' | randomAction && borl ^. parameters.exploration <= borl ^. parameters.learnRandomAbove = borl -- multichain ?
            | otherwise = set v (P.insert period label vValStateNew mv) $ set w (P.insert period label wValState' mw) $ set rho rhoNew $
                          set r0 (P.insert period label r0ValState' mr0) $ set r1 (P.insert period label r1ValState' mr1) borl

  -- update values
  return $
    set psis (psiValRho', psiValV', psiValW' ) $
    set visits (M.alter (\mV -> ((+1) <$> mV) <|> Just 1) state (borl ^. visits)) $
    set s stateNext $
    set t (period + 1) $
    set parameters params' borl'

-- | This function chooses the next action from the current state s and all possible actions.
nextAction :: (Ord s) => BORL s -> IO (Bool, ActionIndexed s)
nextAction borl = do
  let explore = borl ^. parameters . exploration
  let state = borl ^. s
  let as = actionsIndexed borl state
  when (null as) (error "Empty action list")
  rand <- randomRIO (0, 1)
  if rand < explore
    then do
      r <- randomRIO (0, length as - 1)
      return (True,  as !! r)
    else do
      let bestRho | isUnichain borl = as
                  | otherwise = head $ groupBy (epsCompare (==) `on` rhoValue borl state) $ sortBy (epsCompare compare `on` rhoValue borl state) as
          bestV = head $ groupBy (epsCompare (==) `on` vValue borl state) $ sortBy (epsCompare compare `on` vValue borl state) bestRho
          bestE = sortBy (epsCompare compare `on` eValue borl state) bestV
          bestR = sortBy (epsCompare compare `on` rValue borl RBig state) bestV
      -- return (False, head bestR)
      if length bestE > 1
        then do
          r <- randomRIO (0, length bestE - 1)
          return (False, bestE !! r)
        else return (False, head bestE)
  where
    eps = borl ^. parameters . epsilon
    epsCompare f x y
      | abs (x - y) <= eps = f 0 0
      | otherwise = y `f` x

-- actions :: BORL s -> s -> [Action s]
-- actions borl state = map snd (actionsIndexed borl state)

actionsIndexed :: BORL s -> s -> [ActionIndexed s]
actionsIndexed borl state = map snd $ filter fst $ zip ((borl ^. actionFilter) state) (borl ^. actionList)


reduce :: [Double] -> Double
reduce = maximum
-- reduce xs = sum xs / fromIntegral (length xs)
{-# INLINE reduce #-}


-- | Expected average value of state-action tuple, that is y_{-1}(s,a).
rhoValue :: (Ord s) => BORL s -> s -> ActionIndexed s -> Double
rhoValue = rhoValueWith Worker

rhoValueWith :: (Ord s) => LookupType -> BORL s -> s -> ActionIndexed s -> Double
rhoValueWith lkTp borl state (a,_) =
  case borl ^. rho of
    Left r  -> r
    Right m -> P.lookupProxy (borl ^. t) lkTp (state,a) m

rhoStateValue :: (Ord s) => BORL s -> s -> Double
rhoStateValue borl state = case borl ^. rho of
  Left r  -> r
  Right _ -> reduce $ map (rhoValueWith Target borl state) (actionsIndexed borl state)

vValue :: (Ord s) => BORL s -> s -> ActionIndexed s -> Double
vValue = vValueWith Worker

vValueWith :: (Ord s) => LookupType -> BORL s -> s -> ActionIndexed s -> Double
vValueWith lkTp borl state (a,_) = P.lookupProxy (borl ^. t) lkTp (state, a) mv
  where
    mv = borl ^. v

vStateValue :: (Ord s) => BORL s -> s -> Double
vStateValue borl state = reduce $ map (vValueWith Target borl state) (actionsIndexed borl state)


wValue :: (Ord s) => BORL s -> s -> ActionIndexed s -> Double
wValue = wValueWith Worker

wValueWith :: (Ord s) => LookupType -> BORL s -> s -> ActionIndexed s -> Double
wValueWith lkTp borl state (a,_) = P.lookupProxy (borl ^. t) lkTp (state, a) mw
  where
    mw = borl ^. w

wStateValue :: (Ord s) => BORL s -> s -> Double
wStateValue borl state = reduce $ map (wValueWith Target borl state) (actionsIndexed borl state)


-- | Used to select a discount factor.
data RSize
  = RSmall
  | RBig


-- | Calculates the expected discounted value with the provided gamma (small/big).
rValue :: (Ord s) => BORL s -> RSize -> s -> ActionIndexed s -> Double
rValue = rValueWith Worker

-- | Calculates the expected discounted value with the provided gamma (small/big).
rValueWith :: (Ord s) => LookupType -> BORL s -> RSize -> s -> ActionIndexed s -> Double
rValueWith lkTp borl size state (a, _) = P.lookupProxy (borl ^. t) lkTp (state, a) mr
  where
    mr =
      case size of
        RSmall -> borl ^. r0
        RBig   -> borl ^. r1

rStateValue :: (Ord s) => BORL s -> RSize -> s -> Double
rStateValue borl size state = reduce $ map (rValueWith Target borl size state) (actionsIndexed borl state)

-- | Calculates the difference between the expected discounted values.
eValue :: (Ord s) => BORL s -> s -> ActionIndexed s -> Double
eValue borl state act = rValueWith Target borl RBig state act - rValueWith Target borl RSmall state act

--  | Calculates the difference between the expected discounted values.
-- eStateValue :: (Ord s) => BORL s -> s -> Double
-- eStateValue borl state = reduce (map (rValueWith Target borl RBig state) as) - reduce (map (rValueWith Target borl RSmall state) as)
--   where as = actionsIndexed borl state
