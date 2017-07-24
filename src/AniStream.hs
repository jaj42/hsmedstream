{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Prelude hiding (takeWhile)

import qualified Data.Time as Time
import qualified System.IO as SysIO
import System.Environment (getArgs)

import qualified System.Hardware.Serialport as S

import Control.Lens
import Control.Monad (forever)
import qualified Control.Exception as Ex

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Pipes
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

data AniData = AniData { datetime :: Time.LocalTime
                       , valid :: Bool
                       , instant :: Int
                       , mean :: Int
                       , energy :: Float
                       , event :: String
                       } deriving (Show)

delimiter :: Parser ()
delimiter = char '|' >> skipSpace

--09/21/2016|15:08:27
dateTimeParser :: Parser Time.LocalTime
dateTimeParser = do
    month <- decimal
    char '/'
    day <- decimal
    char '/'
    year <- decimal
    delimiter
    hour <- decimal
    char ':'
    minute <- decimal
    char ':'
    seconds <- count 2 digit
    return Time.LocalTime { Time.localDay = Time.fromGregorian year month day
                          , Time.localTimeOfDay = Time.TimeOfDay hour minute (read seconds)
                          }

parseAniData :: Parser AniData
parseAniData = do
    dt <- dateTimeParser
    delimiter
    sqi <- hexadecimal :: Parser Int
    delimiter
    instant <- decimal
    delimiter
    mean <- decimal
    delimiter
    energy <- rational
    char '|'
    event <- takeWhile (/= '\n')
    skipSpace
    let valid = sqi == 1 || sqi == 0xAA
    return $ AniData dt valid instant mean energy (T.unpack event)

pipeParser :: (MonadIO m) => PP.Parser Text m (Maybe (Either PA.ParsingError AniData))
pipeParser = PA.parse parseAniData

aniSerialSettings :: S.SerialPortSettings
aniSerialSettings = S.SerialPortSettings S.CS9600 8 S.One S.NoParity S.NoFlowControl 1

main :: IO ()
main = do
    args <- getArgs
    let devpath = args !! 0
    dorun devpath
  where
    dorun dev = withSerial dev aniSerialSettings pipeline
    --dorun _ = SysIO.withFile "anitest.csv" SysIO.ReadMode pipeline

pipeline :: SysIO.Handle -> IO ()
pipeline hIn = Z.withContext $ \ctx -> PZ.runSafeT . runEffect $ parseForever (linesFromHandleForever hIn)
               >-> P.tee P.print >-> dropInvalid >-> toMsgPack >-> zmqConsumer ctx

-- ZMQ related
zmqConsumer ctx = P.map (:| []) >-> PZ.setupConsumer ctx Z.Pub (`Z.connect` "tcp://127.0.0.1:4201")

-- Parsing related
parseForever :: (MonadIO m) => Producer Text m () -> Producer AniData m ()
parseForever inflow = do 
    (r, p) <- lift $ PP.runStateT pipeParser inflow
    case r of
         Nothing -> return ()
         Just e  -> case e of
                         -- Drop current line on parsing error and continue
                         Left _      -> parseForever (p >-> P.drop 1)
                         Right entry -> yield entry >> parseForever p

dropInvalid :: (MonadIO m) => Pipe AniData AniData m ()
dropInvalid = P.filter $ \anidata -> valid anidata

toMsgPack :: (MonadIO m) => Pipe AniData B.ByteString m ()
toMsgPack = P.map $ \anidata ->
    "ani " `B.append` (BL.toStrict . M.pack . preprocess $ anidata)
  where
    preprocess AniData{..} = M.Assoc [("instant", M.toObject instant),
                                      ("mean"   , M.toObject mean),
                                      ("energy" , M.toObject energy) :: (String, M.Object)]

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
