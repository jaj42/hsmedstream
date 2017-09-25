{-# LANGUAGE GADTs #-}

module Common where

import qualified System.IO as SysIO

import qualified System.Hardware.Serialport as S

import Control.Lens
import Control.Monad (forever)
import qualified Control.Exception as Ex

import Data.Text (Text)
import qualified Data.Text.IO as T

import Pipes
import qualified Pipes.Prelude as P

import qualified Pipes.Text as PT

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
    printErr e s = SysIO.hPutStrLn SysIO.stderr (show e ++ ": " ++ show s)


parseForever :: (MonadIO m) => Parser a -> Producer Text m () -> Producer a m ()
parseForever parser inflow = do
    (result, remainder) <- lift $ PP.runStateT (PA.parse parser) inflow
    case result of
         Nothing -> return ()
         Just e  -> case e of
                         -- Drop current line on parsing error and continue
                         Left err    -> parseForever parser (remainder >-> dropLog err)
                         Right entry -> yield entry >> parseForever parser remainder
