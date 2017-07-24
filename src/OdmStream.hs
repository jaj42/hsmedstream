{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..))
import Data.Time.LocalTime (TimeOfDay(..), timeOfDayToTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)

import qualified System.IO as SysIO
import System.Environment (getArgs)

import qualified System.Hardware.Serialport as S

import Data.Monoid
import Control.Lens
import Control.Monad (forever, forM_)
import Control.Applicative
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

import Pipes.Group (concats)

import Data.Attoparsec.Text
import qualified Pipes.Parse as PP
import qualified Pipes.Attoparsec as PA

import qualified Data.MessagePack as M

import qualified System.ZMQ4 as Z
import qualified Pipes.ZMQ4 as PZ
import Data.List.NonEmpty (NonEmpty(..))

type DevPath = String

type Velocity = Int
type Pressure = Int
type OdmWave = (Double, Velocity, Pressure)

data OdmNomogram = Adult | Paediatric | Dog | None
    deriving (Show)

data OdmCalc = OdmCalc { datetime :: Double
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
dateTimeParser :: Parser Double
dateTimeParser = do
    year    <- count 4 digit
    month   <- count 2 digit
    day     <- count 2 digit
    hour    <- count 2 digit
    minute  <- count 2 digit
    seconds <- rational
    let utctime = UTCTime { utctDay     = fromGregorian  (read year) (read month) (read day)
                          , utctDayTime = timeOfDayToTime $ TimeOfDay (read hour) (read minute) (fromRational seconds)
                          }
    return $ (realToFrac.utcTimeToPOSIXSeconds) utctime

parseOdmCalc :: Parser OdmCalc
parseOdmCalc = do
    skipSpace
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
    skipSpace
    char '$'
    dt <- dateTimeParser
    char ':'
    pudata <- many1 $ do
        char ','
        velocity <- decimal
        char ';'
        pressure <- decimal
        -- Bug makes ODM spit out velocity * 4
        let velcorr = quot velocity 4
        return (velcorr, pressure)
    let timedeltas = (+ dt) . (/ 180) <$> [0..]
    let injecttime d (v, p) = zip3 d v p
    return $ injecttime timedeltas (unzip pudata)

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
    dorun dev = withSerial dev odmSerialSettings pipeLine
    --dorun _ = SysIO.withFile "../testdata/odmtest.csv" SysIO.ReadMode pipeLine

pipeLine :: SysIO.Handle -> IO ()
pipeLine hIn = do
    (output1, input1) <- spawn unbounded
    (output2, input2) <- spawn unbounded
    a1 <- async $ do
        runEffect $ linesFromHandleForever hIn >-> toOutput (output1 <> output2)
        performGC
    a2 <- async $ do
        Z.withContext $ \ctx -> PZ.runSafeT . runEffect $ parseWaveForever (fromInput input1) >-> waveToMsgPack >-> zmqWaveConsumer ctx
        performGC
    a3 <- async $ do
        Z.withContext $ \ctx -> PZ.runSafeT . runEffect $ parseNumForever (fromInput input2) >-> P.tee P.print >-> numToMsgPack >-> zmqNumConsumer ctx
        performGC
    mapM_ wait [a1, a2, a3]

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
                         Right entry -> forM_ entry yield >> parseWaveForever p

numToMsgPack :: (MonadIO m) => Pipe OdmCalc B.ByteString m ()
numToMsgPack = P.map $ \odmdata ->
    "odm " `B.append` (BL.toStrict . M.pack . preprocess $ odmdata)
  where
    preprocess OdmCalc{..} = M.Assoc [("co",   M.toObject co),
                                      ("sv",   M.toObject sv ),
                                      ("hr",   M.toObject hr),
                                      ("md",   M.toObject md),
                                      ("sd",   M.toObject sd),
                                      ("ftc",  M.toObject ftc),
                                      ("fttp", M.toObject fttp),
                                      ("ma",   M.toObject ma),
                                      ("pv",   M.toObject pv),
                                      ("ci",   M.toObject ci),
                                      ("svi",  M.toObject svi) :: (String, M.Object)]

waveToMsgPack :: (MonadIO m) => Pipe OdmWave B.ByteString m ()
waveToMsgPack = P.map $ \odmdata ->
    "odm " `B.append` (BL.toStrict . M.pack . preprocess $ odmdata)
  where
    preprocess (dt, u, p) = M.Assoc [("epoch", M.toObject dt),
                                     ("p", M.toObject p),
                                     ("u", M.toObject u) :: (String, M.Object)]

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
    lineByLine = concats . view PT.lines
    go = liftIO (T.hGetChunk h) >>= process
    process txt | T.null txt = return ()
                | otherwise  = yield txt
