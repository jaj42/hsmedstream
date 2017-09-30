module Main where

import System.ZMQ4.Monadic
import Control.Monad (forever)
import Control.Concurrent (forkIO, threadDelay)

main :: IO ()
main = do
    -- Numerics
    forkIO $ newProxy "tcp://0.0.0.0:4201" "tcp://0.0.0.0:4211"
    -- Waveforms
    forkIO $ newProxy "tcp://0.0.0.0:4202" "tcp://0.0.0.0:4212"
    forever $ threadDelay 1000000

newProxy :: String -> String -> IO ()
newProxy inspec outspec = runZMQ $ do
    frontend <- socket XSub
    bind frontend inspec
    backend <- socket XPub
    bind backend outspec
    proxy frontend backend Nothing
