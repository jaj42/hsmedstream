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
                Nothing  -> (NoData, pure ())
                Just sth -> case sth of
                                 Right entry -> (entry,  remainder)
                                 Left err    -> (NoData, remainder >-> dropLog err)
        newcmd <- respond artifact
        isnull <- liftIO $ P.null newrem
        if isnull then return ()
                  else go newcmd newrem

--serveStuff :: FresCmd -> Server FresCmd Text IO ()
serveStuff :: FresCmd -> Proxy X () FresCmd Text IO ()
serveStuff cmd = do
    liftIO $ print cmd
    newcmd <- respond $ buildMessage (Connect 16)
    serveStuff newcmd

--eatStuff :: FresData -> Client FresCmd FresData IO ()
eatStuff :: FresData -> Proxy FresCmd FresData () X IO ()
eatStuff dat = do
    liftIO $ print dat
    newdat <- request $ Connect 1
    eatStuff newdat

proxyline = serveStuff >+> parseProxy parseFrame >+> eatStuff

main :: IO ()
main = runEffect $ proxyline NoData
--main = T.hPutStr SysIO.stdout $ buildMessage (Subscribe 2)


--CHROK = [chr(c) for c in range(0x20 , 0x7E)]
--
--ENQ -> DC4
--DC -> C;numser
--FC -> C
--DE -> C
--LE;b -> LE;b00
--Spont -> E;r0000
