module ML.BORL.Action where

import qualified Data.Text as T

-- | A reward is a Double.
type Reward = Double

-- | An action is a function returning a reward and a new state, and has a name for pretty printing.
data Action s = Action
  { actionFunction :: s -> IO (Reward, s) -- ^ An action which returns a reward r and a new state s'
  , actionName     :: T.Text              -- ^ Name of the action.
  }


instance Eq (Action s) where
  (Action _ t1) == (Action _ t2) = t1 == t2


instance Ord (Action s) where
  compare a1 a2 = compare (actionName a1) (actionName a2)


instance Show (Action s) where
  show a = show (actionName a)