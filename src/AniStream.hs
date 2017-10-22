{-# LANGUAGE OverloadedStrings, RecordWildCards #-}

module Main where

import Common (linesFromHandleForever, withSerial, zmqConsumer, parseForever, encodeToMsgPack, getConfigFor)

import Prelude hiding (takeWhile)

import qualified System.IO as SysIO
import qualified System.ZMQ4 as Z
import qualified System.Hardware.Serialport as S

import qualified Data.Time as Time
import qualified Data.Text as T
import           Data.Attoparsec.Text
import qualified Data.MessagePack as M
import qualified Data.HashMap as HM

import           Pipes
import qualified Pipes.Prelude as P
import qualified Pipes.Text.IO as PT

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
    skipSpace -- handle newline
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
    config <- getConfigFor "ani"
    case "device" `HM.lookup` config of
         Just devpath -> withSerial devpath aniSerialSettings pipeline
         Nothing      -> ioError $ userError "No COM device defined"

pipeline :: SysIO.Handle -> IO ()
pipeline hIn = Z.withContext $ \ctx
    -> PT.runSafeT . runEffect $ parseForever parseAniData (linesFromHandleForever hIn)
    >-> P.filter valid >-> encodeToMsgPack "ani" aniMsgPack
    >-> zmqConsumer ctx "tcp://127.0.0.1:4201"

aniMsgPack :: AniData -> M.Assoc [(String, M.Object)]
aniMsgPack AniData{..} = M.Assoc [("instant", M.toObject instant),
                                  ("mean"   , M.toObject mean),
                                  ("energy" , M.toObject energy)]
