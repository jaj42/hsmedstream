{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}

module Main where

import Prelude hiding (takeWhile)

import Common (linesFromHandleForever, withSerial, zmqConsumer, parseForever, encodeToMsgPack, getConfigFor, dropLog)

import           Numeric (showHex)

import           Control.Applicative
import           Control.Concurrent.MVar
import           Control.Monad.State

import qualified System.IO as SysIO
import qualified System.Hardware.Serialport as S

import           Data.Char (ord, toUpper)
import           Data.Attoparsec.Text
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Monoid ((<>))
import           Data.Maybe (catMaybes)
import qualified Data.HashMap as HM
import           Data.Time.Clock.POSIX

import           Pipes
import           Pipes.Core
--import qualified Pipes.Prelude as P
import qualified Pipes.Parse as PP
import qualified Pipes.Attoparsec as PA

type Syringe = Int
type Volume  = Int

data FresCmd = Nop
             | Connect Syringe
             | Disconnect Syringe
             | Subscribe Syringe
             | ListSyringes
             | KeepAliveTx
             | AckTx
    deriving (Show)

data FresData = KeepAliveRx
              | AckRx
              | NakRx
              | Correct
              | Incorrect
              | Event Syringe Volume
              | NoData
              | Foo Text
    deriving (Show)

data CommState = CommState {
    _readytosend :: Bool,
    _timelastseen :: POSIXTime,
    _reqlssyringes :: MVar (),
    _syringes :: [Syringe],
    _commands :: [FresCmd]
}

newtype App a = App {
    runApp :: (StateT CommState IO) a
}   deriving (Functor, Applicative, Monad, MonadIO, MonadState CommState)

fresSerialSettings :: S.SerialPortSettings
fresSerialSettings = S.SerialPortSettings S.CS19200 7 S.One S.Even S.NoFlowControl 1

generateChecksum :: Text -> Text
generateChecksum msg =
    let 
        sall = sum $ ord <$> T.unpack msg
        low = rem sall 0x100
        checksum = 0xFF - low
    in
        T.pack $ toUpper <$> showHex checksum ""

generateFrame :: Text -> Text
generateFrame msg = "\STX" <> msg <> generateChecksum msg <> "\ETX"

buildMessage :: FresCmd -> Text
buildMessage cmd =
    case cmd of
        Nop          -> ""
        AckTx        -> "\ACK"
        KeepAliveTx  -> "\DC4"
        ListSyringes -> assemble 0 "LE;b"
        Connect s    -> assemble s "DC"
        Disconnect s -> assemble s "FC"
        Subscribe s  -> assemble s "DE;r"
    where
        assemble syringe msg = generateFrame $ (T.pack . show) syringe <> msg

sendCommand :: SysIO.Handle -> FresCmd -> IO ()
sendCommand h c = T.hPutStr h (buildMessage c)

-- | Scan the text for the 'ENQ' caracter and send a 'DC4'
-- caracter in response to keep the connection alive.
-- Strip out the 'ENQ' caracter from the text and return
-- the IO action as well as the stripped text.
scanKeepAlive :: Text -> (Bool, Text)
scanKeepAlive txt = 
    let (reqtx, pretxt) = unzip (fstpass txt)
    in (or reqtx, T.pack $ catMaybes pretxt)
  where
    fstpass :: Text -> [(Bool, Maybe Char)]
    fstpass txt = case T.uncons txt of
                       Nothing     -> []
                       Just (h, t) -> (testChar h) : (fstpass t)
    testChar c = if c == '\ENQ' then (True, Nothing)
                                else (False, Just c)

frameParser :: Parser FresData
frameParser = do
    char '\STX'
    body <- takeWhile $ inClass " -~"
    char '\ETX'
    return $ Foo body

fresParser :: Parser FresData
fresParser = 
    (char '\ACK' >> return AckRx) <|>
    (char '\NAK' >> anyChar >> return NakRx) <|>
    frameParser

parseProxy :: (MonadIO m, MonadState CommState m) => Parser FresData -> Text -> Proxy FresCmd Text FresCmd FresData m ()
parseProxy parser initial = go (pure ()) initial
  where
    --go :: Producer Text m () -> Text -> Proxy FresCmd Text FresCmd FresData App ()
    go previous input = do
        let toparse = previous <> yield input
        (result, remainder) <- lift $ PP.runStateT (PA.parse parser) toparse
        let (artifact, newrem) = case result of
                Nothing  -> (NoData, remainder)
                Just sth -> case sth of
                                 Right entry -> (entry,  remainder)
                                 Left err    -> (NoData, remainder)
        nextinput <- respond artifact >>= request
        go newrem nextinput
        --isnull <- liftIO $ P.null newrem
        --if isnull then return ()
        --          else go newcmd newrem

--stateProxy :: (MonadIO m, MonadState CommState m) => FresData -> Proxy FresCmd FresData FresCmd FresData m ()
--stateProxy dat = do
--    case dat of
--        AckRx -> lift $ modify (\s -> s { _readytosend = True })
--    cmd <- respond dat
--    nextdat <- request cmd
--    stateProxy nextdat

--serveStuff :: SysIO.Handle -> () -> Proxy X () FresCmd Text App ()
serveStuff :: SysIO.Handle -> () -> Server FresCmd Text App ()
serveStuff handle () = do
    txt <- liftIO (T.hGetChunk handle)

    newtime <- liftIO getPOSIXTime
    let isnull = T.null txt
    unless isnull $ lift $ modify (\s -> s { _timelastseen = newtime })

    let (needKeepAlive, txt') = scanKeepAlive txt
    when needKeepAlive $ liftIO $ sendCommand handle KeepAliveTx
    cmd <- respond txt'
    liftIO (print cmd >> sendCommand handle cmd)
    serveStuff handle ()

--eatStuff :: FresData -> Proxy FresCmd FresData () X App ()
eatStuff :: FresData -> Client FresCmd FresData App ()
eatStuff dat = do
    liftIO $ print dat
    newdat <- request $ Connect 0
    eatStuff newdat

pipeline :: SysIO.Handle -> (() -> Effect App ())
pipeline handle = serveStuff handle >~> parseProxy fresParser >~> eatStuff

runPipe :: SysIO.Handle -> IO ()
runPipe handle = do
    reqlssyringes <- newEmptyMVar
    let initState = CommState True 0 reqlssyringes [] []
    evalStateT (runApp $ runEffect $ (pipeline handle) ()) initState

main :: IO ()
main = do
    config <- getConfigFor "fres"
    case "device" `HM.lookup` config of
         Just devpath -> withSerial devpath fresSerialSettings runPipe
         Nothing      -> ioError $ userError "No COM device defined"

--ENQ -> DC4
--ACK -> allow new cmd
--NAK -> error handler? allow new cmd
--DC -> C;numser
--FC -> C
--DE -> C
--LE;b -> LE;b00
--Spont -> E;r0000
