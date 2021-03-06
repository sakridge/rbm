{-|
Module      : Data.DNN.Trainer
Description : Monad for training DNNs
Copyright   : (c) Anatoly Yakovenko, 2015-2016
License     : MIT
Maintainer  : aeyakovenko@gmail.com
Stability   : experimental
Portability : POSIX

This module implements a monad for training a DNN using back-propagation or contrastive divergence.
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
module Data.DNN.Trainer(Trainer
                       ,finish
                       ,finish_
                       ,run
                       ,backward
                       ,feedForward
                       ,backProp
                       ,contraDiv
                       ,forwardErr
                       ,reconErr
                       ,reconstruct
                       ,getCount
                       ,incCount
                       ,putDNN
                       ,getDNN
                       ,popLastLayer
                       ,pushLastLayer
                       ,nextSeed
                       ,setLearnRate
                       ,getLearnRate
                       )where



import qualified Data.RBM as R
import qualified Data.MLP as P
import qualified Control.Monad.State.Strict as S
import qualified Control.Monad.Except as E
import qualified Data.Matrix as M
import Control.Monad(foldM) 
import Data.Matrix(Matrix(..)
                  ,(-^)
                  ,U
                  ,I
                  ,H
                  ,B
                  )

-- | network type
type DNN = [Matrix U I H]
-- | internal state
data DNNS = DNNS { _nn :: DNN
                 , _seed :: Int
                 , _count :: Int
                 , _lr :: Double
                 }

-- | training monad type
type Trainer m a = E.ExceptT a (S.StateT DNNS m) a

-- | terminate the training script
finish :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
       => a -> m ()
finish v = E.throwError v

-- | terminate the training script with ()
finish_ :: (Monad m, E.MonadError () m, S.MonadState DNNS m) 
        => m ()
finish_ = finish ()

-- |Run the script over the DNN.
run :: Monad m => DNN -> Trainer m a -> m (a, DNN)
run nn action = do
   (a,dnns) <- S.runStateT (E.runExceptT action) (DNNS nn 0 0 0.001)
   let unEither (Left v) = v
       unEither (Right v) = v
   return (unEither a, _nn dnns)

-- |Run RBM algorithm backward
backward :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
            => Matrix U B H -> m (Matrix U B I)
backward !bxh = do
   nn <- getDNN
   M.cast2 <$> foldM R.backward bxh (reverse nn)


-- |Run feedForward MLP algorithm over the entire DNN.
feedForward :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
            => Matrix U B I -> m (Matrix U B H)
feedForward !bxi = do
   nn <- getDNN
   P.feedForward nn bxi

-- |Run Back Propagation training over the entire DNN.
backProp :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
         => Matrix U B I -> Matrix U B H -> m ()
backProp !bxi !bxh= do
   _ <- incCount
   lr <- getLearnRate
   dnn <- getDNN
   !(unn,_) <- P.backPropagate dnn lr bxi bxh
   putDNN unn

-- |Run Constrastive Divergance on the last layer in the DNN
-- |This will first run the input through the layers to generate
-- |the probability vector as the input for the last layer.
contraDiv :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
          => Matrix U B I -> m ()
contraDiv !bxi = do 
   seed <- nextSeed
   _ <- incCount
   lr <- getLearnRate
   ixh <- popLastLayer
   nns <- getDNN
   bxi' <- foldM R.forward bxi nns
   !uixh <- R.contraDiv lr ixh seed bxi'
   pushLastLayer uixh

-- |Run feedForward MLP algorithm over the entire DNN.
forwardErr :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
           => Matrix U B I -> Matrix U B H -> m Double
forwardErr !bxi !bxh = do
   !bxh' <- feedForward bxi
   M.mse $ bxh -^ bxh'

-- |Compute the input reconstruction error with the current RBM in the state.
reconErr :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
         => Matrix U B I -> m Double
reconErr bxi = do
   bxi' <- reconstruct bxi
   M.mse $ bxi' -^ bxi

-- |Reconstruct the input with the current RBM
reconstruct :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
            => Matrix U B I -> m (Matrix U B I)
reconstruct bxi = do
   dnn <- getDNN
   R.reconstruct bxi dnn

-- |Return how many times we have executed contraDiv or backProp
getCount :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
      => m Int
getCount = do
   dnns <- S.get
   return $ _count dnns

-- |Increment the count and the return the previous value.
incCount :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
        => m Int
incCount = do
   v <- S.get
   S.put v { _count = (_count v) + 1 }
   return $ _count v

-- |Set the DNN
putDNN :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
        => [Matrix U I H] -> m ()
putDNN nn = S.get >>= \ x -> S.put x { _nn = nn }


-- |Return the DNN
getDNN :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
        => m ([Matrix U I H])
getDNN = _nn <$> S.get

-- |Pop the last layer of the DNN.
popLastLayer :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
        => m (Matrix U I H)
popLastLayer = do
   v <- S.get
   let (ll:rest) = reverse $ check $ _nn v
       check [] = error "Data.DNN.Trainer.popLastLayer: empty dnn, did you forget to pushLastLayer?"
       check ls = ls
   S.put v { _nn = reverse $ rest }
   return $ ll

-- |Push the updated layer as the last in the DNN.
pushLastLayer :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
              => Matrix U I H -> m ()
pushLastLayer ixh = do
   v <- S.get
   S.put v { _nn = reverse $ ixh:(reverse (_nn v)) }

-- |Get the next random seed.
nextSeed :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
         => m Int
nextSeed = do
   S.get >>= \ x -> S.put x { _seed = (_seed x) + 1 }
   _seed <$> S.get

-- |Set the learning rate used in backProp and contraDiv.
setLearnRate :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
             => Double -> m ()
setLearnRate d = S.get >>= \ x -> S.put x { _lr = d }

-- |Get the current learning rate.
getLearnRate :: (Monad m, E.MonadError a m, S.MonadState DNNS m) 
             => m Double
getLearnRate = _lr <$> S.get 
