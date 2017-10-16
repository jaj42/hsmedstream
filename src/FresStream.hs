{-# LANGUAGE OverloadedStrings #-}

module Main where

import Prelude hiding (takeWhile)

import Common (dropLog)

import           Numeric (showHex)

import qualified System.IO as SysIO

import           Data.Char (ord, toUpper)
import           Data.Attoparsec.Text
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Monoid ((<>))
import           Data.Maybe (catMaybes)

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
             | KeepAliveTx
             | AckTx
    deriving (Show)

data FresData = KeepAliveRx
              | AckRx
              | Correct
              | Incorrect
              | Event Syringe Volume
              | NoData
              | Foo Text
    deriving (Show)

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

-- | Scan the text for the 'ENQ' caracter and send a 'DC4'
-- caracter in response to keep the connection alive.
-- Strip out the 'ENQ' caracter from the text and return
-- the IO action as well as the stripped text.
scanKeepAlive :: SysIO.Handle -> Text -> (IO (), Text)
scanKeepAlive handle txt = 
    let (acts, pretxt) = unzip (fstpass txt)
    in (sequence_ acts, T.pack $ catMaybes pretxt)
  where
    fstpass :: Text -> [(IO (), Maybe Char)]
    fstpass txt = case T.uncons txt of
                       Nothing     -> []
                       Just (h, t) -> (testChar h) : (fstpass t)
    testChar c = if c == '\ENQ' then (sendKeepAlive handle, Nothing)
                                else (return (), Just c)
    sendKeepAlive h = SysIO.hPutChar h '\DC4'

parseFrame :: Parser FresData
parseFrame = do
    char '\STX'
    body <- takeWhile $ inClass " -~"
    char '\ETX'
    return $ Foo body

parseProxy :: Parser FresData -> FresCmd -> Proxy FresCmd Text FresCmd FresData IO ()
parseProxy parser initial = go initial (pure ())
  where
    go :: FresCmd -> Producer Text IO () -> Proxy FresCmd Text FresCmd FresData IO ()
    go cmd previous = do
        input <- request cmd
        let toparse = previous <> yield input
        (result, remainder) <- lift $ PP.runStateT (PA.parse parser) toparse
        let (artifact, newrem) = case result of
                Nothing  -> (NoData, remainder)
                Just sth -> case sth of
                                 Right entry -> (entry,  remainder)
                                 Left err    -> (NoData, remainder >-> dropLog err)
        newcmd <- respond artifact
        isnull <- liftIO $ P.null newrem
        go newcmd newrem
        --if isnull then return ()
        --          else go newcmd newrem

--serveStuff :: SysIO.Handle -> FresCmd -> Server FresCmd Text IO ()
serveStuff :: SysIO.Handle -> FresCmd -> Proxy X () FresCmd Text IO ()
serveStuff handle cmd = do
    txt <- liftIO (T.hGetChunk handle)
    let (sendKeepAlive, txt') = scanKeepAlive handle txt
    liftIO sendKeepAlive
    newcmd <- respond txt'
    liftIO $ print $ buildMessage newcmd
    serveStuff handle newcmd

--eatStuff :: FresData -> Client FresCmd FresData IO ()
eatStuff :: FresData -> Proxy FresCmd FresData () X IO ()
eatStuff dat = do
    newdat <- request $ Connect 1
    eatStuff newdat

proxyline handle = serveStuff handle >+> parseProxy parseFrame >+> eatStuff

main :: IO ()
main = runEffect $ proxyline SysIO.stdin NoData

--ENQ -> DC4
--ACK -> allow new cmd
--NAK -> error handler? allow new cmd
--DC -> C;numser
--FC -> C
--DE -> C
--LE;b -> LE;b00
--Spont -> E;r0000
