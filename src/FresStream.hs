{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}

module Main where

import Prelude hiding (takeWhile)

--import Common (linesFromHandleForever, withSerial, zmqConsumer, parseForever, encodeToMsgPack, getConfigFor, dropLog)
import Common (withSerial, getConfigFor)

import           Numeric (showHex)

import           Control.Applicative
--import           Control.Concurrent (threadDelay)
import           Control.Monad.State
--import           Control.Lens

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
import           Data.List ((\\), uncons)
import           Data.Bits (testBit)

import           Pipes
import           Pipes.Core
import qualified Pipes.Prelude as P
import qualified Pipes.Parse as PP
import qualified Pipes.Attoparsec as PA

type Syringe = Int
type Volume  = Int

data FresCmd = Nop
             | ConnectBase
             | Connect Syringe
             | Disconnect Syringe
             | Subscribe Syringe
             | EnumSyringes
             | AckTx
             | KeepAlive
             | AckVolEvent Syringe
    deriving (Show, Eq)

data FresData = AckRx
              | NakRx
              | Correct
              | Incorrect
              | VolEvent Syringe Volume
              | SyringeEnum [Syringe]
              | NoData
    deriving (Show, Eq)

data CommState = CommState {
    _readyToSend :: Bool,
    _timeLastSeen :: POSIXTime,
    _timeLastEnum :: POSIXTime,
    _syringes :: [Syringe],
    _commands :: [FresCmd]
}
    deriving (Show)

--makeLenses ''CommState
defaultState = CommState True 0 0 [] []


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
        Nop           -> ""
        AckTx         -> "\ACK"
        KeepAlive     -> "\DC4"
        EnumSyringes  -> assemble 0 "LE;b"
        ConnectBase   -> assemble 0 "DC"
        Connect s     -> assemble s "DC"
        Disconnect s  -> assemble s "FC"
        Subscribe s   -> assemble s "DE;r"
        AckVolEvent s -> assemble s "E;r"
    where
        assemble syringe msg = generateFrame $ (T.pack . show) syringe <> msg

sendCommand :: SysIO.Handle -> FresCmd -> IO ()
sendCommand h c = print ("-> " <> buildMessage c) >> T.hPutStr h (buildMessage c)

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

fresParser :: Parser FresData
fresParser = 
    (char '\ACK' *> pure AckRx)          <|>
    (char '\NAK' *> digit *> pure NakRx) <|>
    parseFrame

parseFrame :: Parser FresData
parseFrame = do
    char '\STX'
    body <- parseCorrect     <|>
            parseSyringeEnum <|>
            parseIncorrect
    char '\ETX'
    return body

parseCorrect   = digit *> char 'C' *> takeWhile (inClass " -~") *> pure Correct
parseIncorrect = digit *> char 'I' *> takeWhile (inClass " -~") *> pure Incorrect

parseSyringeEnum :: Parser FresData
parseSyringeEnum = do
    --Example: 0LE;b03 for syringe 1 and 2
    string "0LE;b"
    hexval <- hexadecimal :: Parser Int
    let (syrbits, _) = quotRem hexval 0x100 -- rem is checksum
    let syrlist = (+1) <$> filter (testBit syrbits) [0..5]
    return $ SyringeEnum syrlist

ioHandler :: SysIO.Handle -> Server FresCmd Text App ()
ioHandler handle = do
    txt <- liftIO (T.hGetChunk handle)
    liftIO $ print ("<- " <> txt)

    curtime <- liftIO getPOSIXTime
    let isnull = T.null txt
    unless isnull $ modify (\s -> s { _timeLastSeen = curtime })

    let (needKeepAlive, txt') = scanKeepAlive txt
    when needKeepAlive (liftIO $ sendCommand handle KeepAlive)
    cmd <- respond txt'

    case cmd of
        Nop           -> return ()
        AckTx         -> liftIO $ sendCommand handle cmd
        AckVolEvent _ -> liftIO $ sendCommand handle cmd
        _             -> do liftIO $ sendCommand handle cmd
                            modify (\s -> s { _readyToSend = False})
    ioHandler handle

parseProxy :: (MonadIO m, MonadState CommState m) => Parser FresData -> Text -> Proxy FresCmd Text FresCmd FresData m ()
parseProxy parser initial = go (pure ()) initial
  where
    --go :: Producer Text m () -> Text -> Proxy FresCmd Text FresCmd FresData App ()
    go previous input = do
        let toparse = previous <> yield input
        (result, remainder) <- lift $ PP.runStateT (PA.parse parser) toparse
        let (fresdat, newrem) = case result of
                Nothing  -> (NoData, remainder)
                Just sth -> case sth of
                                 Right entry -> (entry,  remainder)
                                 Left _      -> (NoData, remainder)
        nextinput <- respond fresdat >>= request
        go newrem nextinput

prependCommand :: (MonadState CommState m) => FresCmd -> m ()
prependCommand cmd = do {xs <- gets _commands; modify (\s -> s { _commands = cmd:xs })}

appendCommand :: (MonadState CommState m) => FresCmd -> m ()
appendCommand cmd = do {xs <- gets _commands; modify (\s -> s { _commands = xs ++ [cmd] })}

popCommand :: (MonadState CommState m) => m FresCmd
popCommand = do
    cmdlist <- gets _commands;
    let (cmd, cmds) = case uncons cmdlist of
            Just lst -> lst
            Nothing  -> (Nop, [])
    modify (\s -> s { _commands = cmds })
    return cmd

connectNewSyringes :: (MonadState CommState m, MonadIO m) => [Syringe] -> m ()
connectNewSyringes newlist = do
    oldlist <- gets _syringes
    let newsyringes = newlist \\ oldlist
    forM_ newsyringes (\s -> appendCommand (Connect s))
    forM_ newsyringes (\s -> appendCommand (Subscribe s))
    modify (\s -> s { _syringes = newlist})

stateProxy :: FresData -> Proxy FresCmd FresData () FresData App ()
stateProxy dat = do
    get >>= liftIO.print
    let ack = prependCommand AckTx
    case dat of
        NoData        -> return ()
        AckRx         -> return ()
        NakRx         -> modify (\s -> s { _readyToSend = True })
        Correct       -> ack >> modify (\s -> s { _readyToSend = True })
        Incorrect     -> ack >> modify (\s -> s { _readyToSend = True })
        SyringeEnum s -> ack >> connectNewSyringes s
        VolEvent s _  -> do prependCommand (AckVolEvent s)
                            ack
                            yield dat
    seentime <- gets _timeLastSeen
    enumtime <- gets _timeLastEnum
    curtime <- liftIO $ getPOSIXTime
    -- No news for more than 10s? We are no longer connected
    when (curtime - seentime > 10) $ modify (\s -> s { _timeLastSeen = curtime,
                                                       _commands = [ConnectBase]
                                                     })
    -- Update list of connected syringes every 5s.
    when (curtime - enumtime > 5) $ do modify (\s -> s { _timeLastEnum = curtime})
                                       appendCommand EnumSyringes
    ready <- gets _readyToSend
    cmd <- if ready then popCommand else return Nop
    request cmd >>= stateProxy

pipeline :: SysIO.Handle -> Effect App ()
pipeline handle = ioHandler handle >>~ parseProxy fresParser >>~ stateProxy >-> P.print

runPipe :: SysIO.Handle -> IO ()
runPipe handle = do
    curtime <- getPOSIXTime
    let initState = defaultState { _timeLastEnum = curtime }
    (runApp $ runEffect $ pipeline handle) `evalStateT` initState

main :: IO ()
main = do
    config <- getConfigFor "fres"
    case "device" `HM.lookup` config of
         Just devpath -> withSerial devpath fresSerialSettings runPipe
         Nothing      -> ioError $ userError "No COM device defined"
