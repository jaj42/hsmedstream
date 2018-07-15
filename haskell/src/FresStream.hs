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

data FresCmd = Nop
             | AckTx
             | KeepAlive
             | ConnectBase
             | Connect Syringe
             | Disconnect Syringe
             | Subscribe Syringe
             | EnumSyringes
             | AckVolEvent Syringe
    deriving (Show, Eq)

data FresData = NoData
              | AckRx
              | NakRx
              | Correct
              | Incorrect
              | VolEvent Syringe Volume
              | SyringeEnum [Syringe]
    deriving (Show, Eq)

data CommState = CommState {
    _readyToSend :: Bool,
    _timeLastSeen :: POSIXTime,
    _timeLastEnum :: POSIXTime,
    _syringes :: [Syringe],
    _commands :: [FresCmd],
    _currentCommand :: FresCmd
}
    deriving (Show)

makeLenses ''CommState
defaultState = CommState True 0 0 [] [] Nop

newtype App a = App {
    runApp :: (StateT CommState IO) a
}   deriving (Functor, Applicative, Monad, MonadIO, MonadState CommState)

fresSerialPortSettings :: S.SerialPortSettings
fresSerialPortSettings = S.SerialPortSettings S.CS19200 7 S.One S.Even S.NoFlowControl 1

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
        Nop           -> ""
        AckTx         -> "\ACK"
        KeepAlive     -> "\DC4"
        EnumSyringes  -> assemble 0 "LE;b"
        ConnectBase   -> assemble 0 "DC"
        Connect s     -> assemble s "DC"
        Disconnect s  -> assemble s "FC"
        Subscribe s   -> assemble s "DE;r"
        AckVolEvent s -> assemble s "E"
    where
        assemble syringe msg = generateFrame $ (T.pack . show) syringe <> msg

sendCommand :: SysIO.Handle -> FresCmd -> IO ()
sendCommand h c = T.hPutStr h (buildMessage c)

fresParser :: Parser FresData
fresParser = 
    (char '\ACK' *> pure AckRx)          <|>
    (char '\NAK' *> digit *> pure NakRx) <|>
    parseFrame

parseFrame :: Parser FresData
parseFrame = do
    char '\STX'
    body <- parseVolEvent    <|>
            parseSyringeEnum <|>
            parseCorrect     <|>
            parseIncorrect
    char '\ETX'
    return body

parseCorrect   = digit *> char 'C' *> takeWhile (inClass " -~") *> pure Correct
parseIncorrect = digit *> char 'I' *> takeWhile (inClass " -~") *> pure Incorrect

parseSyringeEnum :: Parser FresData
parseSyringeEnum = do
    string "0C;b"
    hexval <- hexadecimal :: Parser Int
    let (syrbits, _) = quotRem hexval 0x100 -- rem is checksum
    let syrlist = (+1) <$> filter (testBit syrbits) [0..5]
    return $ SyringeEnum syrlist

parseVolEvent :: Parser FresData
parseVolEvent = do
    syringe <- decimal
    string "E;r"
    hexval <- hexadecimal :: Parser Int
    let (volume, _) = quotRem hexval 0x100 -- rem is checksum
    return $ VolEvent syringe (fromIntegral volume / 1000)

--- | Scan the text for the 'ENQ' caracter. Strip out the 'ENQ' caracter
--- from the text and return a keep-alive request indicator as well as
--- the stripped text.
scanKeepAlive :: Text -> (Bool, Text)
scanKeepAlive txt =
    let (reqtx, pretxt) = unzip (fstpass txt)
    in (or reqtx, T.pack $ catMaybes pretxt)
  where
    fstpass :: Text -> [(Bool, Maybe Char)]
    fstpass txt = case T.uncons txt of
                       Nothing     -> []
                       Just (h, t) -> testChar h : fstpass t
    testChar '\ENQ' = (True, Nothing)
    testChar c = (False, Just c)

ioHandler :: SysIO.Handle -> Server FresCmd Text App ()
ioHandler handle = forever $ do
    txt <- liftIO (T.hGetChunk handle)
    let (needKeepAlive, txt') = scanKeepAlive txt
    when needKeepAlive $ liftIO $ sendCommand handle KeepAlive
    cmd <- respond txt'
    currentCommand .= cmd
    case cmd of
        Nop           -> return ()
        AckTx         -> liftIO $ sendCommand handle cmd
        AckVolEvent _ -> liftIO $ sendCommand handle cmd
        _             -> do liftIO $ sendCommand handle cmd
                            readyToSend .= False

stateProxy :: Maybe FresData -> Proxy FresCmd (Maybe FresData) () FresData App ()
stateProxy dat = do
    curtime <- liftIO getPOSIXTime
    let ack = prependCommand AckTx
    let ready = readyToSend .= True
    let seen = timeLastSeen .= curtime
    --liftIO $ print dat
    let dat' = fromMaybe NoData dat
    case dat' of
        NoData        -> return ()
        AckRx         -> return ()
        NakRx         -> use currentCommand >>= prependCommand >> ready
        Correct       -> seen >> ack >> ready
        Incorrect     -> ack >> ready
        SyringeEnum s -> seen >> ack >> ready >> connectNewSyringes s
        VolEvent s _  -> do prependCommand (AckVolEvent s)
                            seen >> ack >> ready
                            yield dat'
    seentime <- use timeLastSeen
    enumtime <- use timeLastEnum
    -- No news for more than 10s? We are no longer connected
    when (curtime - seentime > 10) $ put defaultState { _timeLastSeen = curtime,
                                                        _commands = [ConnectBase]
                                                      }
    -- Update list of connected syringes every 5s.
    when (curtime - enumtime > 5) $ do timeLastEnum .= curtime
                                       appendCommand EnumSyringes
    --get >>= liftIO.print --DEBUG
    isready <- use readyToSend
    cmd <- if isready then popCommand else return Nop
    request cmd >>= stateProxy

prependCommand :: (MonadState CommState m) => FresCmd -> m ()
prependCommand cmd = commands %= (:) cmd

appendCommand :: (MonadState CommState m) => FresCmd -> m ()
appendCommand cmd = commands %= flip (++) [cmd]

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
fresMsgPack (VolEvent s vol) = M.Assoc [(show s, M.toObject vol)]
fresMsgPack _                = M.Assoc [("error", M.ObjectNil)]

pipeline :: SysIO.Handle -> Effect App ()
pipeline handle = ioHandler handle >>~ parseProxy fresParser >>~ stateProxy >-> P.print

runPipe :: SysIO.Handle -> IO ()
runPipe handle = do
    curtime <- getPOSIXTime
    let initState = defaultState { _timeLastEnum = curtime }
    runApp (runEffect $ pipeline handle) `evalStateT` initState

main :: IO ()
main = do
    config <- getConfigFor "fres"
    case "device" `HM.lookup` config of
         Nothing      -> ioError $ userError "No COM device defined"
         Just devpath -> do putStrLn ("Connecting to: " <> devpath)
                            withSerial devpath fresSerialPortSettings runPipe
