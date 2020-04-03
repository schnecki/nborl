{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Unsafe              #-}


module ML.BORL.SaveRestore where


import           Control.Lens
import           Control.Monad
import           Data.List             (find)
import qualified HighLevelTensorflow   as TF

import           ML.BORL.NeuralNetwork
import           ML.BORL.Proxy.Type
import           ML.BORL.Type
import           ML.BORL.Types


saveTensorflowModels :: (MonadBorl' m) => BORL s -> m (BORL s)
saveTensorflowModels borl = liftTf $ do
  mapM_ saveProxy (allProxies $ borl ^. proxies)
  return borl
  where
    saveProxy px =
      case px of
        TensorflowProxy netT netW _ _ _ -> TF.saveModelWithLastIO netT >> TF.saveModelWithLastIO netW >> return ()
        _ -> return ()

type BuildModels = Bool

restoreTensorflowModels :: (MonadBorl' m) => BuildModels -> BORL s -> m ()
restoreTensorflowModels build borl = liftTf $ do
  when build buildModels
  mapM_ restoreProxy (allProxies $ borl ^. proxies)
  where
    restoreProxy px =
      case px of
        TensorflowProxy netT netW _ _ _ -> TF.restoreModelWithLastIO netT >> TF.restoreModelWithLastIO netW >> return ()
        _ -> return ()
    buildModels =
      case find isTensorflow (allProxies $ borl ^. proxies) of
        Just (TensorflowProxy netT _ _ _ _) -> TF.buildTensorflowModel netT
        _                                   -> return ()
