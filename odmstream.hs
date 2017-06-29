{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Prelude hiding (takeWhile)

import qualified Data.Time as Time
import qualified System.IO as SysIO
import System.Environment (getArgs)

import qualified System.Hardware.Serialport as S

import Data.Monoid
import Control.Lens
import Control.Monad (forever, forM)
import Control.Applicative ((<|>))
import Control.Concurrent.Async
import qualified Control.Exception as Ex

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Pipes
import Pipes.Concurrent
import qualified Pipes.Prelude as P

import qualified Pipes.Text as PT
import qualified Pipes.Text.IO as PT

import Data.Attoparsec.Text
import qualified Pipes.Parse as PP
import qualified Pipes.Attoparsec as PA

import qualified Data.MessagePack as MsgPack

import qualified System.ZMQ4 as Z
import qualified Pipes.ZMQ4 as PZ
import Data.List.NonEmpty (NonEmpty(..))

type DevPath = String

type Flow = Integer
type Pressure = Integer
type OdmWave = (Flow, Pressure)

data OdmNomogram = Adult | Paediatric | Dog | None
    deriving (Show)

data OdmCalc = OdmCalc { datetime :: Time.LocalTime
                       , nomogram :: OdmNomogram
                       , co :: Float
                       , sv :: Int
                       , hr :: Int
                       , md :: Int
                       , sd :: Float
                       , ftc :: Int
                       , fttp :: Int
                       , ma :: Float
                       , pv :: Float
                       , ci :: Float
                       , svi :: Float
                       } deriving (Show)

nomogramParser :: Parser OdmNomogram
nomogramParser =
      (char 'A' >> return Adult)
  <|> (char 'C' >> return Paediatric)
  <|> (char 'D' >> return Dog)
  <|> (char 'L' >> return None)

-- #yyyymmddhhmmss:
-- $yyyymmddhhmmss.mmm:
dateTimeParser :: Parser Time.LocalTime
dateTimeParser = do
    year    <- count 4 digit
    month   <- count 2 digit
    day     <- count 2 digit
    hour    <- count 2 digit
    minute  <- count 2 digit
    seconds <- takeWhile1 $ inClass "0-9."
    return Time.LocalTime { Time.localDay       = Time.fromGregorian (read year) (read month) (read day)
                          , Time.localTimeOfDay = Time.TimeOfDay (read hour) (read minute) (read $ T.unpack seconds)
                          }

parseOdmCalc :: Parser OdmCalc
parseOdmCalc = do
    char '#'
    dt <- dateTimeParser
    char ':'
    nom <- nomogramParser
    char ','
    co <- rational
    char ','
    sv <- decimal
    char ','
    hr <- decimal
    char ','
    md <- decimal
    char ','
    sd <- rational
    char ','
    ftc <- decimal
    char ','
    fttp <- decimal
    char ','
    ma <- rational
    char ','
    pv <- rational
    char ','
    ci <- rational
    char ','
    svi <- rational
    return $ OdmCalc dt nom co sv hr md sd ftc fttp ma pv ci svi

parseOdmWave :: Parser [OdmWave]
parseOdmWave = do
    char '$'
    dateTimeParser
    char ':'
    many1 $ do
        char ','
        flow <- decimal
        char ';'
        pressure <- decimal
        return (flow, pressure)

calcParser :: (MonadIO m) => PP.Parser Text m (Maybe (Either PA.ParsingError OdmCalc))
calcParser = PA.parse parseOdmCalc

waveParser :: (MonadIO m) => PP.Parser Text m (Maybe (Either PA.ParsingError [OdmWave]))
waveParser = PA.parse parseOdmWave

odmSerialSettings :: S.SerialPortSettings
odmSerialSettings = S.SerialPortSettings S.CS57600 8 S.One S.NoParity S.NoFlowControl 1

main :: IO ()
main = do
    args <- getArgs
    let devpath = args !! 0
    dorun devpath
  where
    --dorun dev = withSerial dev odmSerialSettings commonPipe
    dorun _ = SysIO.withFile "odmtest.csv" SysIO.ReadMode commonPipe

commonPipe :: SysIO.Handle -> IO ()
--commonPipe hIn = Z.withContext $ \ctx -> PZ.runSafeT . runEffect $ parseNumForever (linesFromHandleForever hIn)
--               >-> P.tee P.print >-> calcToMsgPack >-> zmqNumConsumer ctx
commonPipe hIn = do
    (output1, input1) <- spawn unbounded
    (output2, input2) <- spawn unbounded
    a1 <- async $ do
        runEffect $ linesFromHandleForever hIn >-> toOutput (output1 <> output2)
        performGC
    a2 <- async $ do
        Z.withContext $ \ctx -> PZ.runSafeT . runEffect $ parseWaveForever (fromInput input1) >-> P.tee P.print >-> waveToMsgPack >-> zmqWaveConsumer ctx
    a3 <- async $ do
        Z.withContext $ \ctx -> PZ.runSafeT . runEffect $ parseNumForever (fromInput input2) >-> P.tee P.print >-> numToMsgPack >-> zmqNumConsumer ctx
    mapM_ wait (a1:a2:a3:[])

-- Parsing related
parseNumForever :: (MonadIO m) => Producer Text m () -> Producer OdmCalc m ()
parseNumForever inflow = do
    (r, p) <- lift $ PP.runStateT calcParser inflow
    case r of
         Nothing -> return ()
         Just e  -> case e of
                         -- Drop current line on parsing error and continue
                         Left _      -> parseNumForever (p >-> P.drop 1)
                         Right entry -> yield entry >> parseNumForever p

parseWaveForever :: (MonadIO m) => Producer Text m () -> Producer OdmWave m ()
parseWaveForever inflow = do
    (r, p) <- lift $ PP.runStateT waveParser inflow
    case r of
         Nothing -> return ()
         Just e  -> case e of
                         -- Drop current line on parsing error and continue
                         Left _      -> parseWaveForever (p >-> P.drop 1)
                         Right entry -> forM entry yield >> parseWaveForever p

numToMsgPack :: (MonadIO m) => Pipe OdmCalc B.ByteString m ()
numToMsgPack = P.map $ \odmdata ->
    "odm " `B.append` (BL.toStrict . MsgPack.pack . preprocess $ odmdata)
  where
    preprocess odmval = MsgPack.Assoc [("co"   :: String, show $ co odmval),
                                       ("sv"   :: String, show $ sv odmval),
                                       ("hr"   :: String, show $ hr odmval),
                                       ("md"   :: String, show $ md odmval),
                                       ("sd"   :: String, show $ sd odmval),
                                       ("ftc"  :: String, show $ ftc odmval),
                                       ("fttp" :: String, show $ fttp odmval),
                                       ("ma"   :: String, show $ ma odmval),
                                       ("pv"   :: String, show $ pv odmval),
                                       ("ci"   :: String, show $ ci odmval),
                                       ("svi"  :: String, show $ svi odmval)]

waveToMsgPack :: (MonadIO m) => Pipe OdmWave B.ByteString m ()
waveToMsgPack = P.map $ \odmdata ->
    "odm " `B.append` (BL.toStrict . MsgPack.pack . preprocess $ odmdata)
  where
    preprocess (p, u) = MsgPack.Assoc [("p" :: String, show p),
                                       ("u" :: String, show u)]

-- ZMQ related
zmqNumConsumer :: (PZ.Base m ~ IO, PZ.MonadSafe m) => Z.Context -> Consumer B.ByteString m ()
zmqNumConsumer ctx = P.map (:| []) >-> PZ.setupConsumer ctx Z.Pub (`Z.connect` "tcp://127.0.0.1:4201")

zmqWaveConsumer :: (PZ.Base m ~ IO, PZ.MonadSafe m) => Z.Context -> Consumer B.ByteString m ()
zmqWaveConsumer ctx = P.map (:| []) >-> PZ.setupConsumer ctx Z.Pub (`Z.connect` "tcp://127.0.0.1:4202")

-- IO related
withSerial :: DevPath -> S.SerialPortSettings -> (SysIO.Handle -> IO a) -> IO a
withSerial dev settings = Ex.bracket (S.hOpenSerial dev settings) SysIO.hClose

linesFromHandleForever :: (MonadIO m) => SysIO.Handle -> Producer Text m ()
linesFromHandleForever h = lineByLine (forever go)
  where
    lineByLine = view PT.unlines . view PT.lines
    go = liftIO (T.hGetChunk h) >>= process
    process txt | T.null txt = return ()
                | otherwise  = yield txt
