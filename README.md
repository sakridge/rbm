Restricted Boltzmann Machine
============================

Trying to follow [Hinton's paper](docs/hinton_rbm_guide.pdf) on rbms.

Simple single layer implementation in haskell using lists.  Take a look at [RBM/List.hs](RBM/List.hs).  

Repa based single layer implementation [RBM/Repa.hs](RBM/Repa.hs).

Multi layer implmentation [DBN/Repa.hs](DBN/Repa.hs).

run `make mnist` to test the mnist training.

Todo
----

* console to monitor the recustructions, change rate etc..
* gpu based one using accelrate-cuda 

experiments
-----------
* error and reconstruction is hard to observe

basically, any small shift in the data could cause the generated image look correct, but the actual error rate to be high and useless.

* learning rate recipe from Hinton's paper

so the learning rate should keep the update size to 0.001 of the weights, (sum weights)/(sum update) * (0.001)

* use reconstruction error intead of update amount as the stopping point

how much we update the weights is not a good indicator of how close we are to reconstructin the input

* initialize the weights to be +/- 0.01 of around 0

initial weights that are to big made the results unpredictable, and took to long to train

* mini batches should be no more then number of classes you are learning, and random

using larger batches doesn't train the rbm effectively.
