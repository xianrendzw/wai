{-# LANGUAGE RecordWildCards, OverloadedStrings, ForeignFunctionInterface #-}

module Network.Wai.Handler.Warp.HTTP2.Sender (frameSender) where

import Control.Concurrent (putMVar, forkIO)
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (void)
import qualified Data.ByteString.Builder.Extra as B
import Data.IORef (readIORef, writeIORef)
import Foreign.C.Types
import Foreign.Ptr
import Network.HTTP2
import Network.HTTP2.Priority
import Network.Wai
import Network.Wai.Handler.Warp.Buffer
import Network.Wai.Handler.Warp.FdCache
import Network.Wai.Handler.Warp.HTTP2.HPACK
import Network.Wai.Handler.Warp.HTTP2.Response
import Network.Wai.Handler.Warp.HTTP2.Types
import qualified Network.Wai.Handler.Warp.Settings as S
import Network.Wai.Handler.Warp.Types
import Network.Wai.Internal (Response(..))
import System.Posix.Types

----------------------------------------------------------------

unlessClosed :: Stream -> IO () -> IO ()
unlessClosed Stream{..} body = do
    state <- readIORef streamState
    case state of
        Closed _ -> return ()
        _        -> body

checkWindowSize :: TVar WindowSize -> TVar WindowSize -> PriorityTree Output -> Output -> Priority -> (WindowSize -> IO ()) -> IO ()
checkWindowSize connWindow strmWindow outQ out pri body = do
   cw <- atomically $ do
       w <- readTVar connWindow
       check (w > 0)
       return w
   sw <- atomically $ readTVar strmWindow
   if sw == 0 then
       void $ forkIO $ do
           atomically $ do
               x <- readTVar strmWindow
               check (x > 0)
           enqueue outQ out pri
     else
       body (min cw sw)

frameSender :: Context -> Connection -> InternalInfo -> S.Settings -> IO ()
frameSender ctx@Context{..} conn@Connection{..} ii settings = do
    connSendAll initialFrame
    loop `E.finally` putMVar wait ()
  where
    initialSettings = [(SettingsMaxConcurrentStreams,recommendedConcurrency)]
    initialFrame = settingsFrame id initialSettings
    bufHeaderPayload = connWriteBuffer `plusPtr` frameHeaderLength
    headerPayloadLim = connBufferSize - frameHeaderLength

    loop = dequeue outputQ >>= \(out, pri) -> switch out pri

    switch OFinish         _ = return ()
    switch (OGoaway frame) _ = connSendAll frame
    switch (OFrame frame)  _ = do
        connSendAll frame
        loop
    switch out@(OResponse strm rsp hasBody) pri = unlessClosed strm $ do
        checkWindowSize connectionWindow (streamWindow strm) outputQ out pri $ \lim -> do
            -- Header frame and Continuation frame
            let sid = streamNumber strm
            len <- headerContinue sid rsp hasBody
            let total = len + frameHeaderLength
            if hasBody then do
                -- Data frame payload
                let datPayloadOff = total + frameHeaderLength
                Next datPayloadLen mnext <- fillResponseBodyGetNext conn ii datPayloadOff lim rsp
                fillDataHeaderSend strm total datPayloadLen mnext pri
              else do
                bs <- toBS connWriteBuffer total
                connSendAll bs
        loop
    switch out@(ONext strm curr) pri = unlessClosed strm $ do
        checkWindowSize connectionWindow (streamWindow strm) outputQ out pri $ \lim -> do
            -- Data frame payload
            Next datPayloadLen mnext <- curr lim
            fillDataHeaderSend strm 0 datPayloadLen mnext pri
        loop

    headerContinue sid rsp hasBody = do
        builder <- hpackEncodeHeader ctx ii settings rsp
        (len, signal) <- B.runBuilder builder bufHeaderPayload headerPayloadLim
        let flag0 = case signal of
                B.Done -> setEndHeader defaultFlags
                _      -> defaultFlags
            flag = if hasBody then flag0 else setEndStream flag0
        fillFrameHeader FrameHeaders len sid flag connWriteBuffer
        continue sid len signal

    continue _   len B.Done = return len
    continue sid len (B.More _ writer) = do
        bs <- toBS connWriteBuffer (len + frameHeaderLength)
        connSendAll bs
        (len', signal') <- writer bufHeaderPayload headerPayloadLim
        let flag = case signal' of
                B.Done -> setEndHeader defaultFlags
                _      -> defaultFlags
        fillFrameHeader FrameContinuation len' sid flag connWriteBuffer
        continue sid len' signal'
    continue _ _ (B.Chunk _ _) = error "continue: Chunk"

    fillDataHeaderSend strm otherLen datPayloadLen mnext pri = do
        -- fixme: length check
        -- Data frame payload header
        let sid = streamNumber strm
            buf = connWriteBuffer `plusPtr` otherLen
            total = otherLen + frameHeaderLength + datPayloadLen
            flag = case mnext of
                Nothing -> setEndStream defaultFlags
                Just _  -> defaultFlags
        fillFrameHeader FrameData datPayloadLen sid flag buf
        bs <- toBS connWriteBuffer total
        connSendAll bs
        atomically $ do
           modifyTVar' connectionWindow (subtract datPayloadLen)
           modifyTVar' (streamWindow strm) (subtract datPayloadLen)
        case mnext of
            Nothing   -> writeIORef (streamState strm) (Closed Finished)
            Just next -> enqueue outputQ (ONext strm next) pri

    fillFrameHeader ftyp len sid flag buf = encodeFrameHeaderBuf ftyp hinfo buf
      where
        hinfo = FrameHeader len flag sid

----------------------------------------------------------------

{-
ResponseFile Status ResponseHeaders FilePath (Maybe FilePart)
ResponseBuilder Status ResponseHeaders Builder
ResponseStream Status ResponseHeaders StreamingBody
ResponseRaw (IO ByteString -> (ByteString -> IO ()) -> IO ()) Response
-}

fillResponseBodyGetNext :: Connection -> InternalInfo -> Int -> WindowSize -> Response -> IO Next
fillResponseBodyGetNext Connection{..} _ off lim (ResponseBuilder _ _ bb) = do
    let datBuf = connWriteBuffer `plusPtr` off
        room = min (connBufferSize - off) lim
    (len, signal) <- B.runBuilder bb datBuf room
    nextForBuilder len connWriteBuffer connBufferSize signal

fillResponseBodyGetNext Connection{..} ii off lim (ResponseFile _ _ path mpart) = do
    -- fixme: no fdcache
    let Just fdcache = fdCacher ii
    (fd, refresh) <- getFd fdcache path
    let datBuf = connWriteBuffer `plusPtr` off
        Just part = mpart -- fixme: Nothing
        room = min (connBufferSize - off) lim
        start = filePartOffset part
        bytes = filePartByteCount part
    len <- positionRead fd datBuf (mini room bytes) start
    refresh
    let len' = fromIntegral len
    nextForFile len connWriteBuffer connBufferSize fd (start + len') (bytes - len') refresh

fillResponseBodyGetNext _ _ _ _ _ = error "fillResponseBodyGetNext"

----------------------------------------------------------------

fillBufBuilder :: Buffer -> BufSize -> B.BufferWriter -> WindowSize -> IO Next
fillBufBuilder buf siz writer lim = do
    let payloadBuf = buf `plusPtr` frameHeaderLength
        room = min (siz - frameHeaderLength) lim
    (len, signal) <- writer payloadBuf room
    nextForBuilder len buf siz signal

nextForBuilder :: Int -> Buffer -> BufSize -> B.Next -> IO Next
nextForBuilder len _   _   B.Done = return $ Next len Nothing
nextForBuilder len buf siz (B.More minSize writer)
  | siz < minSize = error "toBufIOWith: fillBufBuilder: minSize"
  | otherwise     = return $ Next len (Just (fillBufBuilder buf siz writer))
nextForBuilder len buf siz (B.Chunk bs writer)
  | bs == ""      = return $ Next len (Just (fillBufBuilder buf siz writer))
  | otherwise     = error "toBufIOWith: fillBufBuilder: bs"

----------------------------------------------------------------

fillBufFile :: Buffer -> BufSize -> Fd -> Integer -> Integer -> IO () -> WindowSize -> IO Next
fillBufFile buf siz fd start bytes refresh lim = do
    let payloadBuf = buf `plusPtr` frameHeaderLength
        room = min (siz - frameHeaderLength) lim
    len <- positionRead fd payloadBuf (mini room bytes) start
    let len' = fromIntegral len
    refresh
    nextForFile len buf siz fd (start + len') (bytes - len') refresh

nextForFile :: Int -> Buffer -> BufSize -> Fd -> Integer -> Integer -> IO () -> IO Next
nextForFile 0   _   _   _  _     _     _       = return $ Next 0 Nothing
nextForFile len _   _   _  _     0     _       = return $ Next len Nothing
nextForFile len buf siz fd start bytes refresh =
    return $ Next len (Just (fillBufFile buf siz fd start bytes refresh))

mini :: Int -> Integer -> Int
mini i n
  | fromIntegral i < n = i
  | otherwise          = fromIntegral n

-- fixme: Windows
positionRead :: Fd -> Buffer -> BufSize -> Integer -> IO Int
positionRead (Fd fd) buf siz off =
    fromIntegral <$> c_pread fd (castPtr buf) (fromIntegral siz) (fromIntegral off)

foreign import ccall unsafe "pread"
  c_pread :: CInt -> Ptr CChar -> ByteCount -> FileOffset -> IO ByteCount -- fixme
