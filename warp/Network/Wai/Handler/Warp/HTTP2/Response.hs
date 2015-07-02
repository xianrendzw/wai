{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Warp.HTTP2.Response where

import Data.ByteString (ByteString)
import qualified Network.HTTP.Types as H
import Network.HTTP2
import Network.HTTP2.Priority
import Network.Wai
import Network.Wai.Handler.Warp.HTTP2.Types
import qualified Network.Wai.Handler.Warp.Response as R
import Network.Wai.Internal (ResponseReceived(..))

----------------------------------------------------------------

type Responder = Stream -> Priority -> Request -> Response -> IO ResponseReceived

output :: Context -> Responder
output Context{..} strm pri req rsp = do
    let hasBody = requestMethod req /= H.methodHead
               || R.hasBody (responseStatus rsp)
    enqueue outputQ (OResponse strm rsp hasBody) pri
    return ResponseReceived

----------------------------------------------------------------

goawayFrame :: StreamId -> ErrorCodeId -> ByteString -> ByteString
goawayFrame sid etype debugmsg = encodeFrame einfo frame
  where
    einfo = encodeInfo id 0
    frame = GoAwayFrame sid etype debugmsg

resetFrame :: ErrorCodeId -> StreamId -> ByteString
resetFrame etype sid = encodeFrame einfo frame
  where
    einfo = encodeInfo id sid
    frame = RSTStreamFrame etype

settingsFrame :: (FrameFlags -> FrameFlags) -> SettingsList -> ByteString
settingsFrame func alist = encodeFrame einfo $ SettingsFrame alist
  where
    einfo = encodeInfo func 0

pingFrame :: ByteString -> ByteString
pingFrame bs = encodeFrame einfo $ PingFrame bs
  where
    einfo = encodeInfo setAck 0
