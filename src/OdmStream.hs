{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Common (linesFromHandleForever, withSerial, zmqConsumer, dropLog)

import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..))
import Data.Time.LocalTime (TimeOfDay(..), timeOfDayToTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)

import qualified System.IO as SysIO
import System.Environment (getArgs)

import qualified System.Hardware.Serialport as S

import Data.Monoid
import Control.Lens
import Control.Monad (forever)
import Control.Applicative
import Control.Exception (bracket)

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Pipes
import qualified Pipes.Prelude as P

import qualified Pipes.Text as PT
import qualified Pipes.Text.IO as PT

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

data OdmCalc = OdmCalc { timestamp :: Double
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
    seconds <- double
    let utctime = UTCTime { utctDay     = fromGregorian  (read year) (read month) (read day)
                          , utctDayTime = timeOfDayToTime $ TimeOfDay (read hour) (read minute) (realToFrac seconds)
                          }
    return $ (realToFrac.utcTimeToPOSIXSeconds) utctime

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

parseEither :: Parser (Either OdmCalc [OdmWave])
parseEither = skipSpace >>
      (parseOdmWave >>= return.Right)
  <|> (parseOdmCalc >>= return.Left)

odmSerialSettings :: S.SerialPortSettings
odmSerialSettings = S.SerialPortSettings S.CS57600 8 S.One S.NoParity S.NoFlowControl 1

main :: IO ()
main = do
    args <- getArgs
    let devpath = args !! 0
    dorun devpath
  where
    dorun dev = withSerial dev odmSerialSettings pipeLine
    --dorun _ = SysIO.withFile "../testdata/odmtest.csv" SysIO.ReadMode $ runReaderT pipeLine

keepCalc :: (MonadIO m) => Pipe (Either OdmCalc [OdmWave]) OdmCalc m ()
keepCalc = forever $ do
    v <- await
    case v of
        Right _ -> return ()
        Left c  -> yield c

keepWave :: (MonadIO m) => Pipe (Either OdmCalc [OdmWave]) [OdmWave] m ()
keepWave = forever $ do
    v <- await
    case v of
        Right c -> yield c
        Left _  -> return ()

consumeCalc ctx = keepCalc >-> numToMsgPack >-> zmqConsumer ctx "tcp://127.0.0.1:4201"
consumeWave ctx = keepWave >-> P.concat >-> waveToMsgPack >-> zmqConsumer ctx "tcp://127.0.0.1:4202"

pipeLine :: SysIO.Handle -> IO ()
pipeLine hIn = Z.withContext $ \ctx
    -> PZ.runSafeT . runEffect $ parseForever (linesFromHandleForever hIn)
    >-> P.tee P.print >-> P.tee (consumeCalc ctx) >-> (consumeWave ctx)

-- Parsing related
parseForever :: (MonadIO m) => Producer Text m () -> Producer (Either OdmCalc [OdmWave]) m ()
parseForever inflow = do
    (r, p) <- lift $ PP.runStateT (PA.parse parseEither) inflow
    case r of
         Nothing -> return ()
         Just e  -> case e of
                         -- Drop current line on parsing error and continue
                         Left err    -> parseForever (p >-> dropLog err)
                         Right entry -> yield entry >> parseForever p

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
