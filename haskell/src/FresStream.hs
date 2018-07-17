{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}

module Main where

import Prelude hiding (takeWhile)

--import Common (withSerial, zmqConsumer, encodeToMsgPack, getConfigFor)
import Common (withSerial, getConfigFor, parseProxy)

import           Numeric (showHex)

import           Control.Applicative
import           Control.Monad (forever)
import           Control.Monad.State
import           Control.Monad.Reader

import           Control.Lens hiding (uncons)

import qualified System.IO as SysIO
import qualified System.Hardware.Serialport as S

import           Data.Attoparsec.Text
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import           Data.Bits (testBit)
import           Data.Char (ord, toUpper)
import qualified Data.HashMap as HM
import           Data.List ((\\), uncons)
import           Data.Maybe (fromMaybe, catMaybes)
import qualified Data.MessagePack as M
import           Data.Monoid ((<>))
import           Data.Time.Clock.POSIX

import           Pipes
import           Pipes.Core
import qualified Pipes.Prelude as P

type Syringe = Int
type Volume  = Float

data Config = Config {
    ioHandle :: SysIO.Handle
}

data FresCmd = Nop
             | AckTx
             | KeepAlive
             | ConnectBase
             | Connect Syringe
             | Disconnect Syringe
             | Subscribe Syringe
             | SubscribeSyringes
             | AckVolumeEvent Syringe
             | AckSyringesEvent
    deriving (Show, Eq)

data FresData = NoData
              | AckRx
              | NakRx Char
              | Correct
              | Incorrect
              | VolumeEvent Syringe Volume
              | SyringesEvent [Syringe]
    deriving (Show, Eq)

data CommState = CommState {
    _readyToSend :: Bool,
    _timeLastSeen :: POSIXTime,
    _syringes :: [Syringe],
    _commands :: [FresCmd],
    _lastCommand :: FresCmd
}
    deriving (Show)

makeLenses ''CommState

defaultState = CommState {
    _readyToSend = True,
    _timeLastSeen = 0,
    _syringes = [],
    _commands = [],
    _lastCommand = Nop
}

newtype App m a = App {
    runApp :: (ReaderT Config (StateT CommState m)) a
}   deriving (Functor, Applicative, Monad, MonadIO, MonadState CommState, MonadReader Config)

fresSerialPortSettings :: S.SerialPortSettings
fresSerialPortSettings = S.SerialPortSettings S.CS19200 7 S.One S.Even S.NoFlowControl 1

sendCommand :: (MonadIO m, MonadReader Config m) => FresCmd -> m ()
sendCommand cmd = do
    handle <- asks ioHandle
    liftIO $ T.hPutStr handle (buildMessage cmd)

buildMessage :: FresCmd -> Text
buildMessage cmd =
    case cmd of
        Nop           -> ""
        AckTx         -> "\ACK"
        KeepAlive     -> "\DC4"
        ConnectBase   -> assemble 0 "DC"
        Connect s     -> assemble s "DC"
        Disconnect s  -> assemble s "FC"
        Subscribe s   -> assemble s "DE;r"
        SubscribeSyringes -> assemble 0 "DE;b"
        AckVolumeEvent s  -> assemble s "E"
        AckSyringesEvent  -> assemble 0 "E"
    where
        assemble syringe msg = generateFrame $ (T.pack . show) syringe <> msg

generateFrame :: Text -> Text
generateFrame msg = "\STX" <> msg <> generateChecksum msg <> "\ETX"

generateChecksum :: Text -> Text
generateChecksum msg =
    let
        sall = sum $ ord <$> T.unpack msg
        low = rem sall 0x100
        checksum = 0xFF - low
    in
        T.pack $ toUpper <$> showHex checksum ""

fresParser :: Parser FresData
fresParser = 
    (char '\ACK' *> pure AckRx)        <|>
    (NakRx <$> (char '\NAK' *> digit)) <|>
    parseFrame

parseFrame :: Parser FresData
parseFrame = do
    char '\STX'
    body <- parseVolumeEvent   <|>
            parseSyringesEvent <|>
            parseCorrect       <|>
            parseIncorrect
    char '\ETX'
    return body

parseCorrect   = digit *> char 'C' *> takeWhile (inClass " -~") *> pure Correct
parseIncorrect = digit *> char 'I' *> takeWhile (inClass " -~") *> pure Incorrect

parseSyringesEvent :: Parser FresData
parseSyringesEvent = do
    string "0E;b"
    hexval <- hexadecimal :: Parser Int
    let (syrbits, _) = quotRem hexval 0x100 -- rem is checksum
    let syrlist = (+1) <$> filter (testBit syrbits) [0..5]
    return $ SyringesEvent syrlist

parseVolumeEvent :: Parser FresData
parseVolumeEvent = do
    syringe <- decimal
    string "E;r"
    hexval <- hexadecimal :: Parser Int
    let (volume, _) = quotRem hexval 0x100 -- rem is checksum
    return $ VolumeEvent syringe (fromIntegral volume / 1000)

--- | Scan the text for the 'ENQ' caracter. Strip out the 'ENQ' caracter
--- from the text and return a keep-alive request indicator as well as
--- the stripped text.
scanKeepAlive :: Text -> (Bool, Text)
scanKeepAlive txt =
    let (reqka, pretxt) = unzip (fstpass txt)
    in (or reqka, T.pack $ catMaybes pretxt)
  where
    fstpass :: Text -> [(Bool, Maybe Char)]
    fstpass txt = case T.uncons txt of
                       Nothing     -> []
                       Just (h, t) -> testChar h : fstpass t
    testChar '\ENQ' = (True, Nothing)
    testChar c = (False, Just c)

ioHandler :: MonadIO m => Server FresCmd Text (App m) ()
ioHandler = forever $ do
    handle <- asks ioHandle
    txt <- liftIO (T.hGetChunk handle)
    let (needKeepAlive, txt') = scanKeepAlive txt
    when needKeepAlive $ do sendCommand KeepAlive
                            curtime <- liftIO getPOSIXTime
                            timeLastSeen .= curtime
    cmd <- respond txt'
    unless (cmd == Nop) (lastCommand .= cmd)
    isready <- use readyToSend
    case cmd of
        Nop              -> return ()
        AckTx            -> sendCommand cmd
        AckSyringesEvent -> sendCommand cmd
        AckVolumeEvent _ -> sendCommand cmd
        _                -> case isready of
                                 True  -> do sendCommand cmd
                                             readyToSend .= False
                                 False -> prependCommand cmd

stateProxy :: MonadIO m => Maybe FresData -> Proxy FresCmd (Maybe FresData) () FresData (App m) ()
stateProxy dat = do
    --liftIO $ print dat --DEBUG
    let ack = prependCommand AckTx
    let ready = readyToSend .= True
    let dat' = fromMaybe NoData dat
    case dat' of
        NoData          -> return ()
        AckRx           -> return ()
        NakRx _         -> use lastCommand >>= prependCommand >> ready
        Correct         -> ack >> ready
        Incorrect       -> ack >> ready
        SyringesEvent s -> do prependCommand AckSyringesEvent
                              ack >> connectNewSyringes s
        VolumeEvent s _ -> do prependCommand (AckVolumeEvent s)
                              ack >> yield dat'
    curtime <- liftIO getPOSIXTime
    seentime <- use timeLastSeen
    -- No news for more than 1 second? We are no longer connected
    when (curtime - seentime > 1) $ do liftIO $ print ("Base timeout. Trying to reconnect.")
                                       put defaultState { _timeLastSeen = curtime,
                                                          _commands = [ConnectBase, SubscribeSyringes]
                                                        }
    --get >>= liftIO.print --DEBUG
    popCommand >>= request >>= stateProxy

prependCommand :: (MonadState CommState m) => FresCmd -> m ()
prependCommand cmd = commands %= \cmds -> cmd:cmds

appendCommand :: (MonadState CommState m) => FresCmd -> m ()
appendCommand cmd = commands %= \cmds -> cmds ++ [cmd]

popCommand :: (MonadState CommState m) => m FresCmd
popCommand = do
    cmdlist <- use commands
    let (cmd, cmds) = fromMaybe (Nop, []) (uncons cmdlist)
    commands .= cmds
    return cmd

connectNewSyringes :: (MonadState CommState m, MonadIO m) => [Syringe] -> m ()
connectNewSyringes newlist = do
    oldlist <- use syringes
    let newsyringes = newlist \\ oldlist
    forM_ newsyringes (appendCommand.Connect)
    forM_ newlist (appendCommand.Subscribe)
    syringes .= newlist

fresMsgPack :: FresData -> M.Assoc [(String, M.Object)]
fresMsgPack (VolumeEvent s vol) = M.Assoc [(show s, M.toObject vol)]
fresMsgPack _                   = M.Assoc [("error", M.ObjectNil)]

pipeline :: MonadIO m => Effect (App m) ()
pipeline = ioHandler >>~ parseProxy fresParser >>~ stateProxy >-> P.print

runPipe :: SysIO.Handle -> IO ()
runPipe handle = do
    let config = Config { ioHandle = handle }
    let initState = defaultState { _commands = [ConnectBase, SubscribeSyringes]}
    (runApp (runEffect pipeline) `runReaderT` config) `evalStateT` initState

main :: IO ()
main = do
    config <- getConfigFor "fres"
    case "device" `HM.lookup` config of
         Nothing      -> ioError $ userError "No COM device defined"
         Just devpath -> do putStrLn ("Connecting to: " <> devpath)
                            withSerial devpath fresSerialPortSettings runPipe
