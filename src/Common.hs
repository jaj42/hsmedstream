{-# LANGUAGE GADTs #-}

module Common where

import qualified System.IO as SysIO
import System.Environment (getArgs)

import qualified System.Hardware.Serialport as S

import Control.Lens
import Control.Monad (forever)
import qualified Control.Exception as Ex

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import Pipes
import qualified Pipes.Prelude as P

import qualified Pipes.Text as PT
import qualified Pipes.Text.IO as PT

import Pipes.Group (concats)

import Data.Attoparsec.Text
import qualified Pipes.Parse as PP
import qualified Pipes.Attoparsec as PA

import qualified System.ZMQ4 as Z
import qualified Pipes.ZMQ4 as PZ
import Data.List.NonEmpty (NonEmpty(..))

type DevPath = String

withSerial :: DevPath -> S.SerialPortSettings -> (SysIO.Handle -> IO a) -> IO a
withSerial dev settings = Ex.bracket (S.hOpenSerial dev settings) SysIO.hClose

linesFromHandleForever :: (MonadIO m) => SysIO.Handle -> Producer Text m ()
linesFromHandleForever h = lineByLine (forever go)
  where
    lineByLine = view PT.unlines . view PT.lines
    go = liftIO (T.hGetChunk h) >>= yield

zmqConsumer :: (PZ.MonadSafe m, PZ.Base m ~ IO)
    => Z.Context -> String -> Consumer PT.ByteString m ()
zmqConsumer ctx dest = P.map (:| []) >-> PZ.setupConsumer ctx Z.Pub (`Z.connect` dest)

dropLog :: (Show a, MonadIO m) => PA.ParsingError -> Pipe a a m ()
dropLog errmsg = await >>= liftIO.printErr errmsg >> cat
  where
    printErr e s = putStr ((show e) ++ ": ") >> print s
