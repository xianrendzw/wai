{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE CPP #-}

-- | HTTP over SSL/TLS support for Warp via the TLS package.

module Network.Wai.Handler.WarpTLS (
    -- * Settings
      TLSSettings
    , certFile
    , keyFile
    , onInsecure
    , tlsLogging
    , tlsAllowedVersions
    , tlsCiphers
    , tlsWantClientCert
    , tlsServerHooks
    , defaultTlsSettings
    , tlsSettings
    , tlsSettingsMemory
    , tlsSettingsChain
    , tlsSettingsChainMemory
    , OnInsecure (..)
    -- * Runner
    , runTLS
    , runTLSSocket
    -- * Exception
    , WarpTLSException (..)
    ) where

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ((<$>))
#endif
import Control.Exception (Exception, throwIO, bracket, finally, handle, fromException, try, IOException, onException)
import Control.Monad (void)
import qualified Crypto.Random.AESCtr
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import Data.Default.Class (def)
import qualified Data.IORef as I
import Data.Streaming.Network (bindPortTCP, safeRecv)
import Data.Typeable (Typeable)
import Network.Socket (Socket, sClose, withSocketsDo, SockAddr, accept)
import Network.Socket.ByteString (sendAll)
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra as TLSExtra
import Network.Wai (Application)
import Network.Wai.Handler.Warp
import Network.Wai.Handler.Warp.Internal
import System.IO.Error (isEOFError)

----------------------------------------------------------------

data TLSSettings = TLSSettings {
    certFile :: FilePath
    -- ^ File containing the certificate.
  , chainCertFiles :: [FilePath]
    -- ^ Files containing chain certificates.
  , keyFile :: FilePath
    -- ^ File containing the key
  , certMemory :: Maybe S.ByteString
  , chainCertsMemory :: [S.ByteString]
  , keyMemory :: Maybe S.ByteString
  , onInsecure :: OnInsecure
    -- ^ Do we allow insecure connections with this server as well? Default
    -- is a simple text response stating that a secure connection is required.
    --
    -- Since 1.4.0
  , tlsLogging :: TLS.Logging
    -- ^ The level of logging to turn on.
    --
    -- Default: 'TLS.defaultLogging'.
    --
    -- Since 1.4.0
  , tlsAllowedVersions :: [TLS.Version]
    -- ^ The TLS versions this server accepts.
    --
    -- Default: '[TLS.TLS10,TLS.TLS11,TLS.TLS12]'.
    --
    -- Since 1.4.2
  , tlsCiphers :: [TLS.Cipher]
    -- ^ The TLS ciphers this server accepts.
    --
    -- Default: '[TLSExtra.cipher_AES128_SHA1, TLSExtra.cipher_AES256_SHA1, TLSEtra.cipher_RC4_128_MD5, TLSExtra.cipher_RC4_128_SHA1]'
    --
    -- Since 1.4.2
  , tlsWantClientCert :: Bool
    -- ^ Whether or not to demand a certificate from the client.  If this
    -- is set to True, you must handle received certificates in a server hook
    -- or all connections will fail.
    --
    -- Default: False
    --
    -- Since 3.0.2
  , tlsServerHooks :: TLS.ServerHooks
    -- ^ The server-side hooks called by the tls package, including actions
    -- to take when a client certificate is received.  See the "Network.TLS"
    -- module for details.
    --
    -- Default: def
    --
    -- Since 3.0.2
  }

-- | Default 'TLSSettings'. Use this to create 'TLSSettings' with the field record name.
defaultTlsSettings :: TLSSettings
defaultTlsSettings = TLSSettings {
    certFile = "certificate.pem"
  , chainCertFiles = []
  , keyFile = "key.pem"
  , certMemory = Nothing
  , chainCertsMemory = []
  , keyMemory = Nothing
  , onInsecure = DenyInsecure "This server only accepts secure HTTPS connections."
  , tlsLogging = def
  , tlsAllowedVersions = [TLS.TLS10,TLS.TLS11,TLS.TLS12]
  , tlsCiphers = ciphers
  , tlsWantClientCert = False
  , tlsServerHooks = def
  }

-- taken from stunnel example in tls-extra
ciphers :: [TLS.Cipher]
ciphers =
    [ TLSExtra.cipher_ECDHE_RSA_AES128GCM_SHA256
    , TLSExtra.cipher_DHE_RSA_AES128GCM_SHA256
    , TLSExtra.cipher_DHE_RSA_AES256_SHA256
    , TLSExtra.cipher_DHE_RSA_AES128_SHA256
    , TLSExtra.cipher_DHE_RSA_AES256_SHA1
    , TLSExtra.cipher_DHE_RSA_AES128_SHA1
    , TLSExtra.cipher_DHE_DSS_AES128_SHA1
    , TLSExtra.cipher_DHE_DSS_AES256_SHA1
    , TLSExtra.cipher_DHE_DSS_RC4_SHA1
    , TLSExtra.cipher_AES128_SHA1
    , TLSExtra.cipher_AES256_SHA1
    , TLSExtra.cipher_RC4_128_MD5
    , TLSExtra.cipher_RC4_128_SHA1
    ]

----------------------------------------------------------------

-- | An action when a plain HTTP comes to HTTP over TLS/SSL port.
data OnInsecure = DenyInsecure L.ByteString
                | AllowInsecure

----------------------------------------------------------------

-- | A smart constructor for 'TLSSettings'.
tlsSettings :: FilePath -- ^ Certificate file
            -> FilePath -- ^ Key file
            -> TLSSettings
tlsSettings cert key = defaultTlsSettings {
    certFile = cert
  , keyFile = key
  }

-- | A smart constructor for 'TLSSettings' that allows specifying
-- chain certificates.
--
-- Since 3.0.3
tlsSettingsChain
            :: FilePath -- ^ Certificate file
            -> [FilePath] -- ^ Chain certificate files
            -> FilePath -- ^ Key file
            -> TLSSettings
tlsSettingsChain cert chainCerts key = defaultTlsSettings {
    certFile = cert
  , chainCertFiles = chainCerts
  , keyFile = key
  }

-- | A smart constructor for 'TLSSettings', but uses in-memory representations
-- of the certificate and key
--
-- Since 3.0.1
tlsSettingsMemory
    :: S.ByteString -- ^ Certificate bytes
    -> S.ByteString -- ^ Key bytes
    -> TLSSettings
tlsSettingsMemory cert key = defaultTlsSettings
    { certMemory = Just cert
    , keyMemory = Just key
    }

-- | A smart constructor for 'TLSSettings', but uses in-memory representations
-- of the certificate and key
--
-- Since 3.0.3
tlsSettingsChainMemory
    :: S.ByteString -- ^ Certificate bytes
    -> [S.ByteString] -- ^ Chain certificate bytes
    -> S.ByteString -- ^ Key bytes
    -> TLSSettings
tlsSettingsChainMemory cert chainCerts key = defaultTlsSettings
    { certMemory = Just cert
    , chainCertsMemory = chainCerts
    , keyMemory = Just key
    }

----------------------------------------------------------------


-- | Running 'Application' with 'TLSSettings' and 'Settings'.
runTLS :: TLSSettings -> Settings -> Application -> IO ()
runTLS tset set app = withSocketsDo $
    bracket
        (bindPortTCP (getPort set) (getHost set))
        sClose
        (\sock -> runTLSSocket tset set sock app)

----------------------------------------------------------------

-- | Running 'Application' with 'TLSSettings' and 'Settings' using
--   specified 'Socket'.
runTLSSocket :: TLSSettings -> Settings -> Socket -> Application -> IO ()
runTLSSocket tlsset@TLSSettings{..} set sock app = do
    credential <- case (certMemory, keyMemory) of
        (Nothing, Nothing) ->
            either error id <$>
            TLS.credentialLoadX509Chain certFile chainCertFiles keyFile
        (mcert, mkey) -> do
            cert <- maybe (S.readFile certFile) return mcert
            key <- maybe (S.readFile keyFile) return mkey
            either error return $
              TLS.credentialLoadX509ChainFromMemory cert chainCertsMemory key
    runTLSSocket' tlsset set credential sock app

runTLSSocket' :: TLSSettings -> Settings -> TLS.Credential -> Socket -> Application -> IO ()
runTLSSocket' tlsset@TLSSettings{..} set credential sock app =
    runSettingsConnectionMakerSecure set get app
  where
    get = getter tlsset sock params
    params = def {
        TLS.serverWantClientCert = tlsWantClientCert
      , TLS.serverSupported = def {
          TLS.supportedVersions = tlsAllowedVersions
        , TLS.supportedCiphers  = tlsCiphers
        , TLS.supportedHashSignatures = [
            (TLS.HashSHA256, TLS.SignatureRSA)
          , (TLS.HashSHA1, TLS.SignatureRSA)
          ]
        }
      , TLS.serverShared = def {
          TLS.sharedCredentials = TLS.Credentials [credential]
        }
      , TLS.serverHooks = tlsServerHooks {
          TLS.onALPNClientSuggest = Just alpn
        }
      }

alpn :: [S.ByteString] -> IO S.ByteString
alpn xs
  | "h2-16" `elem` xs = return "h2-16"
  | "h2-15" `elem` xs = return "h2-15"
  | "h2-14" `elem` xs = return "h2-14"
  | otherwise         = return "http/1.1"

----------------------------------------------------------------

getter :: TLS.TLSParams params => TLSSettings -> Socket -> params -> IO (IO (Connection, Transport), SockAddr)
getter tlsset@TLSSettings{..} sock params = do
    (s, sa) <- accept sock
    return (mkConn tlsset s params, sa)

mkConn :: TLS.TLSParams params => TLSSettings -> Socket -> params -> IO (Connection, Transport)
mkConn tlsset s params = do
    firstBS <- safeRecv s 4096
    (if not (S.null firstBS) && S.head firstBS == 0x16 then
        httpOverTls tlsset s firstBS params
      else
        plainHTTP tlsset s firstBS) `onException` sClose s

----------------------------------------------------------------

httpOverTls :: TLS.TLSParams params => TLSSettings -> Socket -> S.ByteString -> params -> IO (Connection, Transport)
httpOverTls TLSSettings{..} s bs0 params = do
    recvN <- makePlainReceiveN s bs0
#if MIN_VERSION_tls(1,3,0)
    ctx <- TLS.contextNew (backend recvN) params
#else
    gen <- Crypto.Random.AESCtr.makeSystem
    ctx <- TLS.contextNew (backend recvN) params gen
#endif
    TLS.contextHookSetLogging ctx tlsLogging
    TLS.handshake ctx
    writeBuf <- allocateBuffer bufferSize
    ref <- I.newIORef ""
    tls <- getTLSinfo ctx
    return (conn ctx writeBuf ref, tls)
  where
    backend recvN = TLS.Backend {
        TLS.backendFlush = return ()
      , TLS.backendClose = sClose s
      , TLS.backendSend  = sendAll s
      , TLS.backendRecv  = recvN
      }
    conn ctx writeBuf ref = Connection {
        connSendMany         = TLS.sendData ctx . L.fromChunks
      , connSendAll          = sendall
      , connSendFile         = sendfile
      , connClose            = close
      , connRecv             = recv
      , connRecvBuf          = recvBuf ref
      , connWriteBuffer      = writeBuf
      , connBufferSize       = bufferSize
      }
      where
        sendall = TLS.sendData ctx . L.fromChunks . return
        sendfile fid offset len hook headers =
            readSendFile writeBuf bufferSize sendall fid offset len hook headers

        close = freeBuffer writeBuf `finally`
                void (tryIO $ TLS.bye ctx) `finally`
                TLS.contextClose ctx

        recv = handle onEOF go
          where
            onEOF e
              | Just TLS.Error_EOF <- fromException e       = return S.empty
              | Just ioe <- fromException e, isEOFError ioe = return S.empty                  | otherwise                                   = throwIO e
            go = do
                x <- TLS.recvData ctx
                if S.null x then
                    go
                  else
                    return x

        recvBuf cref buf siz = do
            cached <- I.readIORef cref
            (ret, leftover) <- fill cached buf siz recv
            I.writeIORef cref leftover
            return ret

fill :: S.ByteString -> Buffer -> BufSize -> Recv -> IO (Bool,S.ByteString)
fill bs0 buf0 siz0 recv
  | siz0 <= len0 = do
      let (bs, leftover) = S.splitAt siz0 bs0
      void $ copy buf0 bs
      return (True, leftover)
  | otherwise = do
      buf <- copy buf0 bs0
      loop buf (siz0 - len0)
  where
    len0 = S.length bs0
    loop _   0   = return (True, "")
    loop buf siz = do
      bs <- recv
      if bs == "" then
          return (False, "")
        else do
          buf' <- copy buf bs
          loop buf' (siz - S.length bs)

getTLSinfo :: TLS.Context -> IO Transport
getTLSinfo ctx = do
    proto <- TLS.getNegotiatedProtocol ctx
    minfo <- TLS.contextGetInformation ctx
    case minfo of
        Nothing   -> return TCP
        Just TLS.Information{..} -> do
            let (major, minor) = case infoVersion of
                    TLS.SSL2  -> (2,0)
                    TLS.SSL3  -> (3,0)
                    TLS.TLS10 -> (3,1)
                    TLS.TLS11 -> (3,2)
                    TLS.TLS12 -> (3,3)
            return TLS {
                tlsMajorVersion = major
              , tlsMinorVersion = minor
              , tlsNegotiatedProtocol = proto
              , tlsChiperID = TLS.cipherID infoCipher
              }

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

----------------------------------------------------------------

plainHTTP :: TLSSettings -> Socket -> S.ByteString -> IO (Connection, Transport)
plainHTTP TLSSettings{..} s bs0 = case onInsecure of
    AllowInsecure -> do
        conn' <- socketConnection s
        cachedRef <- I.newIORef bs0
        let conn'' = conn'
                { connRecv = recvPlain cachedRef (connRecv conn')
                }
        return (conn'', TCP)
    DenyInsecure lbs -> do
        sendAll s "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
        mapM_ (sendAll s) $ L.toChunks lbs
        sClose s
        throwIO InsecureConnectionDenied

----------------------------------------------------------------

-- | Modify the given receive function to first check the given @IORef@ for a
-- chunk of data. If present, takes the chunk of data from the @IORef@ and
-- empties out the @IORef@. Otherwise, calls the supplied receive function.
recvPlain :: I.IORef S.ByteString -> IO S.ByteString -> IO S.ByteString
recvPlain ref fallback = do
    bs <- I.readIORef ref
    if S.null bs
        then fallback
        else do
            I.writeIORef ref S.empty
            return bs

----------------------------------------------------------------

data WarpTLSException = InsecureConnectionDenied
    deriving (Show, Typeable)
instance Exception WarpTLSException
