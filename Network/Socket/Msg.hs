module Network.Socket.Msg
    ( CMsg(..)
    , CMsgable (..)
    , filterCMsgs
    , sendMsg
    , recvMsg
    ) where

import Network.Socket.Msg.CMsg
import Network.Socket.Msg.CMsgHdr
import Network.Socket.Msg.Internal
import Network.Socket.Msg.IOVec
import Network.Socket.Msg.MsgHdr

import Control.Applicative
import Control.Monad (void)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Maybe (isNothing, fromJust)
import Network.Socket
import Network.Socket.Address (sizeOfSocketAddress,peekSocketAddress,pokeSocketAddress,)
import Network.Socket.Internal (throwSocketErrorWaitRead,throwSocketErrorWaitWrite)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Storable (Storable(..),poke)
import Foreign.Ptr (Ptr,castPtr,plusPtr,nullPtr)

isNullPtr :: Ptr a -> Bool
isNullPtr = (==) nullPtr

{-
The buffer in both functions is filled as follows:
-------------
| Data (sz) |
-------------
|  SockAddr |
-------------
|   IOVec   |
-------------
|   MsgHdr  |
-------------
|  Aux Data |
-------------
-}

-- |Sends the data contained in the bytestring to the specified address.
-- The last argument is a list of control parameters (see cmsg(3) for details).
sendMsg :: Socket -> B.ByteString -> SockAddr -> [CMsg] -> IO ()
sendMsg sock bytes sa cmsgs = withFdSocket sock $ \sockfd ->
  void $ allocaBytes bufSz $ \bufPtr -> do
        let saPtr = castPtr bufPtr
        let iovPtr = plusPtr saPtr $ sizeOfSocketAddress sa
        let msgPtr = plusPtr iovPtr $ sizeOf (undefined :: IOVec)
        let auxPtr = plusPtr msgPtr $ sizeOf (undefined :: MsgHdr)

        poke msgPtr MsgHdr { msgName = saPtr
                           , msgNameLen = fromIntegral $ sizeOfSocketAddress sa
                           , msgIov = iovPtr
                           , msgIovLen = 1
                           , msgControl = auxPtr
                           , msgControlLen = fromIntegral auxSz
                           , msgFlags = 0 }
        pokeCMsgs msgPtr cmsgs
        pokeSocketAddress saPtr sa

# if !defined(__HUGS__) 
        throwSocketErrorWaitWrite sock "sendMsg" $
# endif
            BU.unsafeUseAsCStringLen bytes $ \(p,len) ->
                poke iovPtr (IOVec p $ fromIntegral len) >> c_sendmsg sockfd msgPtr 0
    where
        auxSz = sum $ map cmsgSpace cmsgs
        bufSz = sum [auxSz, sizeOfSocketAddress sa, sizeOf (undefined :: MsgHdr), sizeOf (undefined :: IOVec)]

-- |Receive data and put it into a bytestring.
recvMsg :: Socket -> Int -> IO (B.ByteString, SockAddr, [CMsg])
recvMsg sock sz = withFdSocket sock $ \sockfd ->
  allocaBytes bufSz $ \bufPtr -> do
        let addrPtr = plusPtr bufPtr sz
        let iovPtr = plusPtr addrPtr addrSz
        let mhdrPtr = plusPtr iovPtr (sizeOf (undefined :: IOVec))
        let auxPtr = plusPtr mhdrPtr (sizeOf (undefined :: MsgHdr))

        let iov = IOVec bufPtr (fromIntegral sz)
        let msghdr = MsgHdr { msgName = addrPtr 
                            , msgNameLen = fromIntegral addrSz
                            , msgIov = iovPtr
                            , msgIovLen = 1
                            , msgControl = auxPtr
                            , msgControlLen = fromIntegral auxSz
                            , msgFlags = 0 }
        poke iovPtr iov
        poke mhdrPtr msghdr

        rsz <- fmap fromIntegral (
# if !defined(__HUGS__) 
            throwSocketErrorWaitRead sock "recvMsg" $
# endif
            c_recvmsg sockfd mhdrPtr 0)
        (,,) <$> B.packCStringLen (bufPtr,rsz)
             <*> peekSocketAddress addrPtr
             <*> extractCMsgs mhdrPtr
    where
        -- Assume that 1024 bytes is enough for auxillary data
        auxSz = 1024
        -- Reserve 16 bytes for peer address
        addrSz = 16
        bufSz = sum [sz, auxSz, addrSz, sizeOf (undefined :: MsgHdr), sizeOf (undefined :: IOVec)]

extractCMsgs :: Ptr MsgHdr -> IO [CMsg]
extractCMsgs pMsg = extractCMsgs' (c_cmsg_firsthdr pMsg) []
    where
        extractCMsgs' pCMsg resList
            | isNullPtr pCMsg = return resList
            | otherwise = do
                cmsg <- peekCMsg pCMsg
                extractCMsgs' (c_cmsg_nexthdr pMsg pCMsg)
                              (if isNothing cmsg
                                  then resList
                                  else (fromJust cmsg):resList)
