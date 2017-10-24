{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}

module Main where

import Prelude hiding (takeWhile)

import Common (linesFromHandleForever, withSerial, zmqConsumer, parseForever, encodeToMsgPack, getConfigFor, dropLog)

import           Numeric (showHex)

import           Control.Applicative
import           Control.Concurrent (threadDelay)
import           Control.Monad.State
import           Control.Lens

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
import qualified Pipes.Prelude as P
import qualified Pipes.Parse as PP
import qualified Pipes.Attoparsec as PA

type Syringe = Int
type Volume  = Int

data FresCmd = Nop
             | Connect Syringe
             | Disconnect Syringe
             | Subscribe Syringe
             | ListSyringes
             | KeepAlive
             | AckTx
    deriving (Show)

data FresData = AckRx
              | NakRx
              | Correct
              | Incorrect
              | Event Syringe Volume
              | SyringeEnum [Syringe]
              | NoData
    deriving (Show)

data CommState = CommState {
    _readyToSend :: Bool,
    _timeLastSeen :: POSIXTime,
    _timeLastEnum :: POSIXTime,
    _syringes :: [Syringe],
    _commands :: [FresCmd]
}

--makeLenses ''CommState
initState = CommState True 0 0 [] []

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
        KeepAlive    -> "\DC4"
        ListSyringes -> assemble 0 "LE;b"
        Connect s    -> assemble s "DC"
        Disconnect s -> assemble s "FC"
        Subscribe s  -> assemble s "DE;r"
    where
        assemble syringe msg = generateFrame $ (T.pack . show) syringe <> msg

sendCommand :: SysIO.Handle -> FresCmd -> IO ()
sendCommand h (Connect 0) = T.hPutStr h (buildMessage (Connect 0)) >> threadDelay 1000000
sendCommand h c = T.hPutStr h (buildMessage c)

-- | Scan the text for the 'ENQ' caracter. Strip out the 'ENQ' caracter
-- from the text and return a keep-alive request indicator as well as
-- the stripped text.
scanKeepAlive :: Text -> (Bool, Text)
scanKeepAlive txt = 
    let (reqtx, pretxt) = unzip (fstpass txt)
    in (or reqtx, T.pack $ catMaybes pretxt)
  where
    fstpass :: Text -> [(Bool, Maybe Char)]
    fstpass txt = case T.uncons txt of
                       Nothing     -> []
                       Just (h, t) -> (testChar h) : (fstpass t)
    testChar '\ENQ' = (True, Nothing)
    testChar c = (False, Just c)

parseFrame :: Parser FresData
parseFrame = do
    char '\STX'
    body <- parseCorrect <|> parseIncorrect
    char '\ETX'
    return body

parseCorrect   = digit *> char 'C' *> takeWhile (inClass " -~") *> pure Correct
parseIncorrect = digit *> char 'I' *> takeWhile (inClass " -~") *> pure Incorrect

fresParser :: Parser FresData
fresParser = 
    (char '\ACK' >> return AckRx) <|>
    (char '\NAK' >> anyChar >> return NakRx) <|>
    parseFrame

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
                                 Left _      -> (NoData, remainder)
        nextinput <- respond artifact >>= request
        go newrem nextinput

-- stateProxy:
-- modify state according to Data
-- handle reqlssyringes
-- send Command or Nop upstream
-- send stuff downstream
-- recurse

stateProxy :: FresData -> Proxy FresCmd FresData () FresData App ()
stateProxy dat = do
    case dat of
        Event _ _ -> yield dat
        AckRx     -> modify (\s -> s { _readyToSend = True })
        NakRx     -> modify (\s -> s { _readyToSend = True })
        NoData    -> return ()
        Correct   -> return ()
        Incorrect -> return ()
        SyringeEnum s -> return () -- connectNewSyringes s (update _timeLastEnum)
    seentime <- gets _timeLastSeen
    enumtime <- gets _timeLastEnum
    curtime <- liftIO $ getPOSIXTime
    -- No news for more than 10s? We are no longer connected
    when (curtime - seentime > 10) $ modify (\s -> s { _commands = [Connect 0]})
    -- Update list of connected syringes every 5s.
    --when (curtime - enumtime > 5) $ modify (\s -> s { _commands = [Connect 0]})

    let cmd = Connect 0
    newdat <- request cmd
    stateProxy newdat
  --where
    --popCommand = return ()
    --prependCommand cmd = return ()

--if readytosend:
--take commands or nop
--else nop

ioHandler :: SysIO.Handle -> Server FresCmd Text App ()
ioHandler handle = do
    txt <- liftIO (T.hGetChunk handle)

    curtime <- liftIO getPOSIXTime
    let isnull = T.null txt
    unless isnull $ modify (\s -> s { _timeLastSeen = curtime })

    let (needKeepAlive, txt') = scanKeepAlive txt
    when needKeepAlive (liftIO $ sendCommand handle KeepAlive)
    cmd <- respond txt'
    liftIO $ sendCommand handle cmd
    ioHandler handle

pipeline :: SysIO.Handle -> Effect App ()
pipeline handle = ioHandler handle >>~ parseProxy fresParser >>~ stateProxy >-> P.print

runPipe :: SysIO.Handle -> IO ()
runPipe handle = do
    (runApp $ runEffect $ pipeline handle) `evalStateT` initState

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
