{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Common (linesFromHandleForever, withSerial, zmqConsumer, dropLog, parseForever)

import Prelude hiding (takeWhile)

import qualified Data.Time as Time
import qualified System.IO as SysIO
import System.Environment (getArgs)

import qualified System.Hardware.Serialport as S

import Control.Monad (forever)

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

type DevPath = String

data AniData = AniData { datetime :: Time.LocalTime
                       , valid :: Bool
                       , instant :: Int
                       , mean :: Int
                       , energy :: Float
                       , event :: String
                       } deriving (Show)

delimiter :: Parser ()
delimiter = char '|' *> skipSpace

--09/21/2016|15:08:27
dateTimeParser :: Parser Time.LocalTime
dateTimeParser = do
    month <- count 2 digit
    char '/'
    day <- count 2 digit
    char '/'
    year <- count 4 digit
    delimiter
    hour <- count 2 digit
    char ':'
    minute <- count 2 digit
    char ':'
    seconds <- count 2 digit
    return Time.LocalTime { Time.localDay = Time.fromGregorian (read year) (read month) (read day)
                          , Time.localTimeOfDay = Time.TimeOfDay (read hour) (read minute) (read seconds)
                          }

parseAniData :: Parser AniData
parseAniData = do
    skipSpace -- handle LF after CR
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
    event <- takeWhile (not.isEndOfLine)
    let valid = sqi == 1 || sqi == 0xAA
    return $ AniData dt valid instant mean energy (T.unpack event)

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
pipeline hIn = Z.withContext $ \ctx
    -> PT.runSafeT . runEffect $ parseForever parseAniData (linesFromHandleForever hIn)
    >-> P.tee P.print >-> P.filter valid >-> toMsgPack
    >-> zmqConsumer ctx "tcp://127.0.0.1:4201"

toMsgPack :: (MonadIO m) => Pipe AniData B.ByteString m ()
toMsgPack = P.map $ \anidata ->
    "ani " `B.append` (BL.toStrict . M.pack . preprocess $ anidata)
  where
    preprocess AniData{..} = M.Assoc [("instant", M.toObject instant),
                                      ("mean"   , M.toObject mean),
                                      ("energy" , M.toObject energy) :: (String, M.Object)]
