{-# LANGUAGE BangPatterns #-}
module Data.RBM(rbm
               ,learn
               ,energy
               ,generate
               ,regenerate
               ,hiddenProbs
               ,inputProbs
               ,Params(..)
               ,params
               ,RBM
               ,perf
               ,test
               ,run_prop_learned
               ) where

--benchmark modules
import Criterion.Main(defaultMainWith,defaultConfig,bgroup,bench,whnf)
import Criterion.Types(reportFile,timeLimit)
--test modules
import System.Exit (exitFailure)
import Test.QuickCheck(verboseCheckWithResult)
import Test.QuickCheck.Test(isSuccess,stdArgs,maxSuccess,maxSize)
import Data.Word(Word8)
--impl modules
--
import qualified Data.Array.Repa as R
import qualified Data.Array.Repa.Unsafe as Unsafe
import qualified Data.Array.Repa.Algorithms.Randomish as R
import qualified Data.Array.Repa.Algorithms.Matrix as R
import System.Random(RandomGen
                    ,random
                    ,randomRs
                    ,mkStdGen
                    ,split
                    )

import Control.Monad.Identity(runIdentity)
import Control.Monad(foldM)
import Control.DeepSeq(NFData)
import Debug.Trace(trace)
import qualified Data.Matrix as M
import Data.Matrix(Matrix(..)
                  ,(*^)
                  ,(+^)
                  ,(-^)
                  ,U
                  ,D
                  )



data H -- ^ num hidden nodes
data I -- ^ num input nodes
data B -- ^ batch size

{-|
 - weight matrix with 1 bias nodes in each layer, numHidden + 1 x numInputs  + 1
 --}
type RBM = Matrix H I

weights :: RBM -> Matrix H I
weights wws = wws
{-# INLINE weights #-}

type MSE = Double

data Params = Params { rate :: Double      -- rate of learning each input
                     , minMSE :: MSE       -- min MSE before done
                     , minBatches :: Int   -- min number of times to repeat
                     , maxBatches :: Int   -- max number of times to repeat
                     , miniBatch :: Int
                     , seed :: Int         -- random seed
                     }

params :: Params
params = Params 0.01 0.001 10 10000 5 0

-- |create an rbm with some randomized weights
rbm :: RandomGen r => r -> Int -> Int -> RBM
rbm r ni nh = M.newRandomish (nh, ni) (-0.01, 0.01) (fst $ random r)

infinity :: Double
infinity = read "Infinity"

-- |update the rbm weights from each batch
learn :: (Monad m) => Params -> RBM -> [m (Matrix B I)]-> m RBM
learn prm rb batches = do
   let 
       ins = cycle batches
       loop bnum crb _ _
         | bnum > (maxBatches prm) = "maxbatches" `trace` return crb
       loop bnum crb mse _
         | bnum >= (minBatches prm) && mse < (minMSE prm) = "minmse" `trace` return crb
       loop bnum crb _ r0
         | ((fst $ random r0) `mod` (10::Int) == 0) = do
            let (r1,r2) = split r0
                rbxi = head $ drop (head $ randomRs (0::Int, (length batches)) r1) ins
            bxi <- rbxi
            mse <- reconErr r1 crb [return bxi]
            (show (mse, bnum)) `trace` loop bnum crb mse r2
       loop bnum crb mse r0 = do
            let (r1,r2) = split r0
                rbxi = head $ drop (head $ randomRs (0::Int, (length batches)) r1) ins
                par = prm { seed = (fst $ random r1) }
            bxi <- rbxi
            let nbnum = bnum + (R.row bxi)
            nrb <- batch par crb [return bxi]
            loop nbnum nrb mse r2
       rr = (mkStdGen $ seed prm)
   loop 0 rb infinity rr
{-# INLINE learn #-}

{-|
 - given an rbm and a biased input array, generate the energy
 --}
energy :: (Monad m) => RBM -> (Matrix B I) -> m Double
energy rb bxi = do
   hxb <- hiddenProbs rb bxi
   hxi <- hxb `M.mmult` bxi
   enr <- (M.sum $ rb *^ hxi)
   return $ negate enr

{-|
 - given a biased input generate probabilities of the hidden layer
 - incuding the biased probability
 -
 - map sigmoid $ biased `mmult` weights
 -
 --}
hiddenProbs :: (Monad m) => RBM -> (Matrix B I) -> m (Matrix H B)
hiddenProbs wws iis = do
   !hxb <- wws `M.mmultT` iis
   R.d2u $ R.map sigmoid hxb
{-# INLINE hiddenProbs #-}

{-|
 - given a batch biased hidden sample generate probabilities of the input layer
 - incuding the biased probability
 -
 - transpose of the hiddenProbs function
 -
 - map sigmoid $ (transpose inputs) `mmult` weights
 -
 --}
inputProbs :: (Monad m) => (Matrix I H) -> (Matrix B H) -> m (Matrix I B)
inputProbs wws hhs = do
   !ixb <- wws `M.mmultT` hhs
   d2u $ R.map sigmoid ixb
{-# INLINE inputProbs #-}

 -- |given a batch of unbiased inputs, update the rbm weights from the batch at once
batch :: (Monad m) => Params -> RBM -> [m (Matrix B I)] -> m RBM
batch par hxi ins = foldM (weightUpdate par) hxi ins
{-# INLINE batch #-}

-- |given an unbiased input batch, generate the the RBM weight updates
weightUpdate:: (Monad m) => Params-> Matrix H I -> m (Matrix B I) -> m (Matrix H I)
weightUpdate par hxi mbxi = do
   bxi <- mbxi
   let cols = M.col bxi
       rows = M.row bxi
       rand = mkStdGen (seed par)
       loop rbm' (rr,rix) = do
            let sz | ((miniBatch par) + rix) > rows = rows - rix
                   | otherwise = (miniBatch par)
                vxi = M.extractRows (rix,sz) bxi
            bxi' <- M.d2u vxi
            !wd <- weightDiff rr rbm' bxi'
            !diffsum <- M.sum $ M.map abs wd
            !weightsum <- M.sum $ M.map abs hxi
            let lrate'
                  | diffsum == 0 = rate par
                  | otherwise = (rate par) * weightsum / diffsum
            let wd' = M.map ((*) lrate') wd
            M.d2u $ rbm' +^ wd'
   foldM loop hxi $ zip (splits rand) [0..((rows) `div` (miniBatch par))]
{-# INLINE weightUpdate #-}

weightDiff :: (Monad m, RandomGen r) => r -> Matrix H I -> Matrix B I -> m (Matrix H I)
weightDiff rand hxi bxi = do
   let (r1,r2) = split rand
   hxb <- generate r1 hxi bxi
   bxh <- M.transpose hxb
   ixb <- M.transpose bxi
   ixh <- M.transpose hxi
   ixb' <- regenerate r2 ixh bxh
   w1 <- (hxb) `M.mmultT` (ixb)
   w2 <- (hxb) `M.mmultT` (ixb')
   M.d2u $ w1 -^ w2
{-# INLINE weightDiff #-}

reconErr :: (Monad m, RandomGen r) => r -> HxI -> [m BxI] -> m Double
reconErr rand hxi mbxis = do
   let loop !total mbxi = do
         bxi <- mbxi
         hxb <- generate rand hxi bxi
         bxh <- BxH <$> (R.transpose2P (unHxB hxb))
         ixh <- IxH <$> (R.transpose2P (unHxI hxi))
         ixb <- regenerate rand ixh bxh
         bxi' <- BxI <$> (R.transpose2P (unIxB ixb)) 
         wd <- d2u $ (unBxI bxi') -^ (unBxI bxi)
         !mse <- R.sumAllP $ R.map (\ xx -> xx ** 2) wd
         let sz = 1 + (row $ R.extent wd) * (col $ R.extent wd)
         return (total +  (mse / (fromIntegral sz)))
   !mse <- foldM loop 0 mbxis
   return $ (mse / (fromIntegral $ length mbxis))
{-# INLINE reconErr #-}

splits :: RandomGen r => r -> [r]
splits rp = rc : splits rn
   where
      (rc,rn) = split rp

-- given a biased input batch [(1:input)], generate a biased hidden layer sample batch
generate :: (Monad m, RandomGen r) => r -> HxI -> BxI -> m HxB
generate rand rb biased = do
   hhs <- unHxB <$> hiddenProbs rb biased
   rands <- unHxB <$> randomArrayHxB (fst $ random rand) (R.extent hhs)
   HxB <$> (d2u $ R.zipWith checkP hhs rands)
{-# INLINE generate #-}

-- given a batch of biased hidden layer samples, generate a batch of biased input layer samples
regenerate :: (Monad m, RandomGen r) => r -> IxH -> BxH -> m IxB
regenerate rand rb hidden = do
   iis <- unIxB <$> inputProbs rb hidden
   rands <- unIxB <$> (randomArrayIxB (fst $ random rand) (R.extent iis))
   IxB <$> (d2u $ R.zipWith checkP iis rands)
{-# INLINE regenerate #-}

randomArrayIxB :: (Monad m) => Int -> DIM2 -> m IxB
randomArrayIxB rseed sh = IxB <$> (d2u $ R.traverse rands id set)
   where
      rands = R.randomishDoubleArray sh 0 1 rseed
      set _ (Z :. 0 :. _) = 0
      set ff sh' = ff sh'
{-# INLINE randomArrayIxB #-}

randomArrayHxB :: (Monad m) => Int -> DIM2 -> m HxB
randomArrayHxB rseed sh = HxB <$> (d2u $ R.traverse rands id set)
   where
      rands = R.randomishDoubleArray sh 0 1 rseed
      set _ (Z :. 0 :. _) = 0
      set ff sh' = ff sh'
{-# INLINE randomArrayHxB #-}

--sample is 0 if generated number gg is greater then probabiliy pp
--so the higher pp the more likely that it will generate a 1
checkP ::  Double -> Double -> Double
checkP gen rand
   | gen > rand = 1
   | otherwise = 0
{-# INLINE checkP #-}

-- sigmoid function
sigmoid :: Double -> Double
sigmoid d = 1 / (1 + (exp (negate d)))
{-# INLINE sigmoid #-}

-- test to see if we can learn a random string
run_prop_learned :: Double -> Int -> Int -> Double
run_prop_learned lrate ni nh = runIdentity $ do
   let rb = rbm (mr 0) (fi ni) (fi nh)
       inputbatchL = concat $ replicate batchsz inputlst
       inputbatch = BxI $ R.fromListUnboxed (Z:. batchsz :.fi ni) $ inputbatchL
       geninputs = randomRs (0::Int,1::Int) (mr 4)
       inputlst = map fromIntegral $ take (fi ni) $ 1:geninputs
       fi ww = 1 + ww
       mr i = mkStdGen (fi ni + fi nh + i)
       batchsz = 2000
       par = params { rate = 0.1 * lrate, miniBatch = 5, maxBatches = 2000  }
   lrb <- learn par rb [return inputbatch]
   reconErr (mr 2) lrb [return inputbatch]

prop_learned :: Word8 -> Word8 -> Bool
prop_learned ni nh = 0.1 > (run_prop_learned 1.0 (fi ni) (fi nh))
   where
      fi = fromIntegral

prop_not_learned :: Word8 -> Word8 -> Bool
prop_not_learned ni nh = 0.1 < (run_prop_learned (-1.0) (fi ni) (fi nh))
   where
      fi ii = 2 + (fromIntegral ii)

prop_learn :: Word8 -> Word8 -> Bool
prop_learn ni nh = runIdentity $ do
   let inputs = R.fromListUnboxed (Z:.fi nh:.fi ni) $ take ((fi ni) * (fi nh)) $ cycle [0,1]
       rand = mkStdGen $ fi nh
       rb = rbm rand (fi ni) (fi nh)
       fi ww = 1 + (fromIntegral ww)
       par = params { rate = 1.0 , miniBatch = 5, maxBatches = 2000 }
   lrb <- learn par rb [return $ BxI inputs]
   return $ (R.extent $ unHxI $ weights rb) == (R.extent $ unHxI $ weights $ lrb)

prop_batch :: Word8 -> Word8 -> Word8 -> Bool
prop_batch ix ni nh = runIdentity $ do
   let rb = rbm rand (fi ni) (fi nh)
       rand = mkStdGen $ fi ix
       inputs = R.fromListUnboxed (Z:.fi ix:.fi ni) $ take ((fi ni) * (fi ix)) $ cycle [0,1]
       fi ww = 1 + (fromIntegral ww)
       par = params { rate = 1.0 , miniBatch = 5, maxBatches = 2000  }
   lrb <- batch par rb [return $ BxI inputs]
   return $ (R.extent $ unHxI $ weights rb) == (R.extent $ unHxI $ weights $ lrb)

prop_init :: Int -> Word8 -> Word8 -> Bool
prop_init gen ni nh = (fi ni) * (fi nh)  == (length $ R.toList $ unHxI $ weights rb)
   where
      rb = rbm (mkStdGen gen) (fi ni) (fi nh)
      fi :: Word8 -> Int
      fi ww = 1 + (fromIntegral ww)

prop_hiddenProbs :: Int -> Word8 -> Word8 -> Bool
prop_hiddenProbs gen ni nh = runIdentity $ do
   let rb = rbm (mkStdGen gen) (fi ni) (fi nh)
       fi ww = 1 + (fromIntegral ww)
       input = BxI $ (R.randomishDoubleArray (Z :. 1 :. (fi ni)) 0 1 gen)
   pp <- hiddenProbs rb input
   return $ (fi nh) == (row $ R.extent $ unHxB pp)

prop_hiddenProbs2 :: Bool
prop_hiddenProbs2 = runIdentity $ do
   let h0 = w00 * i0 + w01 * i1 + w02 * i2
       h1 = w10 * i0 + w11 * i1 + w12 * i2
       i0:i1:i2:_ = [1..]
       w00:w01:w02:w10:w11:w12:_ = [1..]
       wws = [w00,w01,w02,w10,w11,w12]
       input = BxI $ R.fromListUnboxed (Z:.1:.3) $ [i0,i1,i2]
       rb = HxI $ R.fromListUnboxed (Z:.2:.3) $ wws
   pp <- R.toList <$> unHxB <$> hiddenProbs rb input
   return $ pp == map sigmoid [h0, h1]

prop_inputProbs :: Int -> Word8 -> Word8 -> Bool
prop_inputProbs gen ni nh = runIdentity $ do
   let hidden = BxH $ R.randomishDoubleArray (Z :. 1 :. (fi nh)) 0 1 gen
       rb = rbm (mkStdGen gen) (fi ni) (fi nh)
       fi ww = 1 + (fromIntegral ww)
   rb' <- IxH <$> (R.transpose2P (unHxI rb))
   pp <- unIxB <$> inputProbs rb' hidden
   return $ (fi ni) == (row $ R.extent pp)

prop_inputProbs2 :: Bool
prop_inputProbs2 = runIdentity $ do
   let i0 = w00 * h0 + w10 * h1
       i1 = w01 * h0 + w11 * h1
       i2 = w02 * h0 + w12 * h1
       h0:h1:_ = [1..]
       w00:w01:w02:w10:w11:w12:_ = [1..]
       wws = [w00,w01,w02,w10,w11,w12]
       hiddens = BxH $ R.fromListUnboxed (Z:.1:.2) [h0,h1]
       rb = HxI $ R.fromListUnboxed (Z:.2:.3) $ wws
   rb' <- IxH <$> (R.transpose2P (unHxI rb))
   pp <- inputProbs rb' hiddens
   pp' <- R.toList <$> R.transpose2P (unIxB pp)
   return $ pp' == map sigmoid [i0,i1,i2]

prop_energy :: Int -> Word8 -> Word8 -> Bool
prop_energy gen ni nh = runIdentity $ do
   let input = R.randomishDoubleArray (Z :. 1 :. (fi ni)) 0 1 gen
       rb = rbm (mkStdGen gen) (fi ni) (fi nh)
       fi ww = 1 + (fromIntegral ww)
   ee <- energy rb (BxI input)
   return $ not $ isNaN ee

test :: IO ()
test = do
   let check rr = if (isSuccess rr) then return () else exitFailure
       cfg = stdArgs { maxSuccess = 100, maxSize = 10 }
       runtest tst p =  do putStrLn tst; check =<< verboseCheckWithResult cfg p
   runtest "init"         prop_init
   runtest "energy"       prop_energy
   runtest "hiddenp"      prop_hiddenProbs
   runtest "hiddenp2"     prop_hiddenProbs2
   runtest "inputp"       prop_inputProbs
   runtest "inputp2"      prop_inputProbs2
   runtest "batch"        prop_batch
   runtest "learn"        prop_learn
   runtest "notlearnred"  prop_not_learned
   runtest "learned"      prop_learned

perf :: IO ()
perf = do
   let file = "dist/perf-repa-RBM.html"
       cfg = defaultConfig { reportFile = Just file, timeLimit = 1.0 }
   defaultMainWith cfg [
       bgroup "energy" [ bench "63x63"  $ whnf (prop_energy 0 63) 63
                       , bench "127x127"  $ whnf (prop_energy 0 127) 127
                       , bench "255x255"  $ whnf (prop_energy 0 255) 255
                       ]
      ,bgroup "hidden" [ bench "63x63"  $ whnf (prop_hiddenProbs 0 63) 63
                       , bench "127x127"  $ whnf (prop_hiddenProbs 0 127) 127
                       , bench "255x255"  $ whnf (prop_hiddenProbs 0 255) 255
                       ]
      ,bgroup "input" [ bench "63x63"  $ whnf (prop_inputProbs 0 63) 63
                      , bench "127x127"  $ whnf (prop_inputProbs 0 127) 127
                      , bench "255x255"  $ whnf (prop_inputProbs 0 255) 255
                      ]
      ,bgroup "batch" [ bench "15"  $ whnf (prop_batch 15 15) 15
                      , bench "63x63"  $ whnf (prop_batch 63 63) 63
                      , bench "127x127"  $ whnf (prop_batch 127 127) 127
                      , bench "255x255"  $ whnf (prop_batch 255 255) 255
                      ]
      ]
   putStrLn $ "perf log written to " ++ file