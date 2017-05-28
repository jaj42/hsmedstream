{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.Time as Time
import qualified System.IO as SysIO
import System.Environment (getArgs)

import qualified System.Hardware.Serialport as Serial

import Control.Monad (forever)
import Control.Lens
import qualified Control.Exception as Ex

import Pipes
import qualified Pipes.Prelude as P

import qualified Pipes.Text as PT
import qualified Pipes.Text.IO as PT

import Data.Attoparsec.Text
import qualified Pipes.Attoparsec
import qualified Pipes.Parse

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import qualified Data.MessagePack as MsgPack

import qualified System.ZMQ4 as Z
import qualified Pipes.ZMQ4 as PZ
import qualified Pipes.Safe as PS
import qualified Pipes.Group as PG
import qualified Data.List.NonEmpty as NE

type DevPath = String

data AniData = AniData { datetime :: Time.LocalTime
                       , hoth :: Int
                       , instant :: Int
                       , mean :: Int
                       , flt :: Float
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
    return $
      Time.LocalTime { Time.localDay = Time.fromGregorian year month day
                     , Time.localTimeOfDay = Time.TimeOfDay hour minute (read seconds)
                     }

parseAniData :: Parser AniData
parseAniData = do
    dt <- dateTimeParser
    delimiter
    h <- hexadecimal
    delimiter
    instant <- decimal
    delimiter
    skipSpace
    mean <- decimal
    delimiter
    f <- rational
    delimiter
    return $ AniData dt h instant mean f

pipeParser :: (MonadIO m) => Pipes.Parse.Parser Text m (Maybe (Either Pipes.Attoparsec.ParsingError AniData))
pipeParser = Pipes.Attoparsec.parse parseAniData


main :: IO ()
main = do
    args <- getArgs
    let devpath = args !! 0
    dorun devpath
  where
    dorun dev = withSerial dev Serial.defaultSerialSettings pipeline
    --dorun _ = SysIO.withFile "anitest.txt" SysIO.ReadMode pipeline

pipeline :: SysIO.Handle -> IO ()
--pipeline hIn = Z.withContext $ \ctx -> PS.runSafeT . runEffect $ parseForever (linesFromHandleForever hIn) >-> pipeMsgPack >-> singleToNonEmpty >-> zmqConsumer ctx
pipeline hIn = Z.withContext $ \ctx -> PS.runSafeT . runEffect $ parseForever (linesFromHandleForever hIn) >-> pipeMsgPack >-> singleToNonEmpty >-> P.tee P.print >-> zmqConsumer ctx

-- ZMQ related
zmqConsumer ctx = PZ.setupConsumer ctx Z.Pub (`Z.bind` "tcp://127.0.0.1:5555")

-- Parsing related
parseForever :: (MonadIO m) => Producer Text m () -> Producer AniData m ()
parseForever inflow = do 
    (r, p) <- lift $ Pipes.Parse.runStateT pipeParser inflow
    case r of
         Nothing -> return ()
         Just e  -> case e of
                         -- Drop current line on parsing error and continue
                         Left _ -> parseForever (p >-> P.drop 1)
                         Right entry -> yield entry >> parseForever p

singleToNonEmpty :: (MonadIO m) => Pipe a (NE.NonEmpty a) m ()
singleToNonEmpty = P.map (NE.:| [])

pipeMsgPack :: (MonadIO m) => Pipe AniData B.ByteString m ()
--pipeMsgPack = P.map (BL.toStrict . MsgPack.pack . instant)
pipeMsgPack = P.map genMsg


genMsg :: AniData -> B.ByteString
genMsg anidata = "ani " `B.append` (BL.toStrict . MsgPack.pack . preprocess $ anidata)
  where
    preprocess AniData {instant=anival} = MsgPack.Assoc [("ani" :: B.ByteString, anival)]

-- IO related
withSerial :: DevPath -> Serial.SerialPortSettings -> (SysIO.Handle -> IO a) -> IO a
withSerial dev settings = Ex.bracket (Serial.hOpenSerial dev settings) SysIO.hClose

linesFromHandleForever :: (MonadIO m) => SysIO.Handle -> Producer Text m ()
linesFromHandleForever h = lineByLine (forever go) >-> removeEmpty where
    lineByLine = view PT.unlines . view PT.lines
    go = liftIO (T.hGetChunk h) >>= process
    process txt | T.null txt = return ()
                | otherwise  = yield txt
    removeEmpty = P.filter (/= T.singleton '\n')
