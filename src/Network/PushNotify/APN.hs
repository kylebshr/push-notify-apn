-- |
-- Module: APN
-- Copyright: (C) 2017, memrange UG
-- License: BSD3
-- Maintainer: Hans-Christian Esperer <hc@memrange.io>
-- Stability: experimental
-- Portability: portable
--
-- Send push notifications using Apple's HTTP2 APN API
{-# LANGUAGE CPP               #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports    #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE NumericUnderscores     #-}

module Network.PushNotify.APN
    ( newSession
    , newMessage
    , newMessageWithCustomPayload
    , hexEncodedToken
    , rawToken
    , sendMessage
    , sendSilentMessage
    , sendRawMessage
    , alertMessage
    , bodyMessage
    , emptyMessage
    , setAlertMessage
    , setMessageBody
    , setBadge
    , setCategory
    , setSound
    , clearAlertMessage
    , clearBadge
    , clearCategory
    , setMutableContent
    , clearMutableContent
    , setInterruptionLevel
    , clearInterruptionLevel
    , clearSound
    , addSupplementalField
    , closeSession
    , isConnectionOpen
    , isSessionOpen
    , isOpen
    , sendWidgetNotification
    , newWidgetMessage
    , ApnSession
    , JsonAps(..)
    , JsonApsAlert
    , JsonApsMessage
    , ApnMessageResult(..)
    , ApnFatalError(..)
    , ApnTemporaryError(..)
    , ApnToken(..)
    , InterruptionLevel(..)
    , ApnPushType(..)
    , ApnPriority(..)
    ) where

import           Control.Applicative
import           Control.Concurrent
import           Control.Exception.Lifted (Exception, try, bracket_, throw, throwIO)
import           Control.Monad
import           Control.Monad.Except
import           Data.Aeson
import           Data.Aeson.Types
import           Data.ByteString                      (ByteString)
import           Data.Char                            (toLower)
import           Data.Default                         (def)
import           Data.Either
import           Data.IORef
import           Data.Map.Strict                      (Map)
import           Data.Maybe
import           Data.Pool
import           Data.Text                            (Text)
import           Data.Time.Clock
import           Data.Typeable                        (Typeable)
import           Data.X509.CertificateStore
import           GHC.Generics
import           Network.HTTP2.Frame                  (ErrorCode)
import "http2-client" Network.HTTP2.Client
import "http2-client" Network.HTTP2.Client.Helpers
import           Network.TLS                          hiding (sendData)
import           Network.TLS.Extra.Cipher
import           System.IO.Error
import           System.Timeout (timeout)
import           System.X509

import qualified Data.ByteString                      as S
import qualified Data.ByteString.Base16               as B16
import qualified Data.ByteString.Lazy                 as L
import qualified Data.List                            as DL
import qualified Data.Map.Strict                      as M
import qualified Data.Text                            as T
import qualified Data.Text.Encoding                   as TE

import qualified Network.HPACK                        as HTTP2
import qualified Network.HTTP2.Frame                  as HTTP2
import qualified Network.HTTP.Types                   as HTTP

-- | A session that manages connections to Apple's push notification service
data ApnSession = ApnSession
    { apnSessionPool :: !(Pool ApnConnection)
    , apnSessionOpen :: !(IORef Bool)
    }

-- | Information about an APN connection
data ApnConnectionInfo = ApnConnectionInfo
    { aciCertPath             :: !(Maybe FilePath)
    , aciCertKey              :: !(Maybe FilePath)
    , aciCaPath               :: !(Maybe FilePath)
    , aciHostname             :: !Text
    , aciMaxConcurrentStreams :: !Int
    , aciTopic                :: !ByteString
    , aciUseJWT               :: !Bool }

-- | A connection to an APN API server
data ApnConnection = ApnConnection
    { apnConnectionConnection        :: !Http2Client
    , apnConnectionInfo              :: !ApnConnectionInfo
    , apnConnectionWorkerPool        :: !QSem
    , apnConnectionFlowControlWorker :: !ThreadId
    , apnConnectionOpen              :: !(IORef Bool)}

-- | An APN token used to uniquely identify a device
newtype ApnToken = ApnToken { unApnToken :: ByteString }

-- | Create a token from a raw bytestring
rawToken
    :: ByteString
    -- ^ The bytestring that uniquely identifies a device (APN token)
    -> ApnToken
    -- ^ The resulting token
rawToken = ApnToken . B16.encode

-- | Create a token from a hex encoded text
hexEncodedToken
    :: Text
    -- ^ The base16 (hex) encoded unique identifier for a device (APN token)
    -> ApnToken
    -- ^ The resulting token
hexEncodedToken = ApnToken . B16.encode . B16.decodeLenient . TE.encodeUtf8

-- | Exceptional responses to a send request
data ApnException = ApnExceptionHTTP ErrorCode
                  | ApnExceptionJSON String
                  | ApnExceptionMissingHeader HTTP.HeaderName
                  | ApnExceptionUnexpectedResponse
                  | ApnExceptionConnectionClosed
                  | ApnExceptionSessionClosed
    deriving (Show, Typeable)

instance Exception ApnException

-- | The result of a send request
data ApnMessageResult = ApnMessageResultOk
                      | ApnMessageResultBackoff
                      | ApnMessageResultFatalError ApnFatalError
                      | ApnMessageResultTemporaryError ApnTemporaryError
                      | ApnMessageResultIOError IOError
                      | ApnMessageResultClientError ClientError
    deriving (Eq, Show)

-- | The specification of a push notification's message body
data JsonApsAlert = JsonApsAlert
    { jaaTitle :: !(Maybe Text)
    -- ^ A short string describing the purpose of the notification.
    , jaaBody  :: !Text
    -- ^ The text of the alert message.
    , jaaSubtitle :: !(Maybe Text)
    -- ^ Additional information that explains the purpose of the notification.
    } deriving (Generic, Show)

instance ToJSON JsonApsAlert where
    toJSON     = genericToJSON     defaultOptions
        { fieldLabelModifier = drop 3 . map toLower
        , omitNothingFields  = True
        }

instance FromJSON JsonApsAlert where
    parseJSON = genericParseJSON defaultOptions
        { fieldLabelModifier = drop 3 . map toLower
        , omitNothingFields  = True
        }

-- | The interruption level (urgency) of the notification.
data InterruptionLevel = InterruptionLevelPassive
                      | InterruptionLevelActive
                      | InterruptionLevelTimeSensitive
                      | InterruptionLevelCritical
                      deriving (Enum, Eq, Show, Generic)

instance ToJSON InterruptionLevel where
    toJSON = String . T.pack . hyphenate . drop 17 . show
      where
        hyphenate "TimeSensitive" = "time-sensitive"
        hyphenate other = map toLower other

instance FromJSON InterruptionLevel where
    parseJSON = withText "InterruptionLevel" $ \t -> case t of
        "passive" -> pure InterruptionLevelPassive
        "active" -> pure InterruptionLevelActive
        "time-sensitive" -> pure InterruptionLevelTimeSensitive
        "critical" -> pure InterruptionLevelCritical
        _ -> fail "Invalid interruption level"

-- | The push type for the notification (for HTTP/2 apns-push-type header).
data ApnPushType = ApnPushTypeAlert
                 | ApnPushTypeBackground
                 | ApnPushTypeWidgets
                 deriving (Enum, Eq, Show, Generic)

-- | The priority of the notification (for HTTP/2 apns-priority header).
data ApnPriority = ApnPriorityImmediate    -- ^ 10: Send immediately, triggers alerts/sounds/badges
                 | ApnPriorityPowerEfficient -- ^ 5: Send based on power considerations, required for background notifications
                 | ApnPriorityLow          -- ^ 1: Prioritize device power over delivery
                 deriving (Enum, Eq, Show, Generic)

-- | Get the default priority for a push type according to APNS spec
-- Returns Nothing for widgets (no priority header should be sent)
defaultPriorityForPushType :: ApnPushType -> Maybe ApnPriority
defaultPriorityForPushType ApnPushTypeBackground = Just ApnPriorityPowerEfficient  -- Required by spec
defaultPriorityForPushType ApnPushTypeAlert = Just ApnPriorityImmediate
defaultPriorityForPushType ApnPushTypeWidgets = Nothing  -- No priority header for widgets

instance ToJSON ApnPushType where
    toJSON ApnPushTypeAlert = String "alert"
    toJSON ApnPushTypeBackground = String "background"  
    toJSON ApnPushTypeWidgets = String "widgets"

instance FromJSON ApnPushType where
    parseJSON = withText "ApnPushType" $ \t -> case t of
        "alert" -> pure ApnPushTypeAlert
        "background" -> pure ApnPushTypeBackground
        "widgets" -> pure ApnPushTypeWidgets
        _ -> fail "Invalid push type"

-- | Push notification message's content
data JsonApsMessage
    -- | Push notification message's content
    = JsonApsMessage
    { jamAlert    :: !(Maybe JsonApsAlert)
    -- ^ A text to display in the notification
    , jamBadge    :: !(Maybe Int)
    -- ^ A number to display next to the app's icon. If set to (Just 0), the number is removed.
    , jamSound    :: !(Maybe Text)
    -- ^ A sound to play, that's located in the Library/Sounds directory of the app
    -- This should be the name of a sound file in the application's main bundle, or
    -- in the Library/Sounds directory of the app.
    , jamCategory :: !(Maybe Text)
    -- ^ The category of the notification. Must be registered by the app beforehand.
    , jamMutableContent :: !(Maybe Int)
    -- ^ Whether the message has mutable content.
    , jamInterruptionLevel :: !(Maybe InterruptionLevel)
    -- ^ The interruption level of the notification.
    , jamContentChanged :: !(Maybe Bool)
    -- ^ Whether the content has changed (for widgets).
    } deriving (Generic, Show)

-- | Create an empty apn message
emptyMessage :: JsonApsMessage
emptyMessage = JsonApsMessage Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | Set a sound for an APN message
setSound
    :: Text
    -- ^ The sound to use (either "default" or something in the application's bundle)
    -> JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
setSound s a = a { jamSound = Just s }

-- | Clear the sound for an APN message
clearSound
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearSound a = a { jamSound = Nothing }

-- | Set the category part of an APN message
setCategory
    :: Text
    -- ^ The category to set
    -> JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
setCategory c a = a { jamCategory = Just c }

-- | Clear the category part of an APN message
clearCategory
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearCategory a = a { jamCategory = Nothing }

-- | Set the mutable content part of an APN message
setMutableContent
    :: Int
    -- ^ The number of mutable content to set
    -> JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
setMutableContent i a = a { jamMutableContent = Just i }

-- | Clear the mutable content part of an APN message
clearMutableContent
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearMutableContent a = a { jamMutableContent = Nothing }

-- | Set the interruption level part of an APN message
setInterruptionLevel
    :: InterruptionLevel
    -- ^ The interruption level to set
    -> JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
setInterruptionLevel i a = a { jamInterruptionLevel = Just i }

-- | Clear the interruption level part of an APN message
clearInterruptionLevel
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearInterruptionLevel a = a { jamInterruptionLevel = Nothing }

-- | Set the badge part of an APN message
setBadge
    :: Int
    -- ^ The badge number to set. The badge number is displayed next to your app's icon. Set to 0 to remove the badge number.
    -> JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
setBadge i a = a { jamBadge = Just i }

-- | Clear the badge part of an APN message
clearBadge
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearBadge a = a { jamBadge = Nothing }

-- | Create a new APN message with an alert part
alertMessage
    :: Text
    -- ^ The title of the message
    -> Text
    -- ^ The body of the message
    -> Maybe Text
    -- ^ The subtitle of the message
    -> JsonApsMessage
    -- ^ The modified message
alertMessage title text subtitle = setAlertMessage title text subtitle emptyMessage

-- | Create a new APN message with a body and no title
bodyMessage
    :: Text
    -- ^ The body of the message
    -> JsonApsMessage
    -- ^ The modified message
bodyMessage text = setMessageBody text emptyMessage

-- | Set the alert part of an APN message
setAlertMessage
    :: Text
    -- ^ The title of the message
    -> Text
    -- ^ The body of the message
    -> Maybe Text
    -- ^ The subtitle of the message
    -> JsonApsMessage
    -- ^ The message to alter
    -> JsonApsMessage
    -- ^ The modified message
setAlertMessage title text subtitle a = a { jamAlert = Just jam }
  where
    jam = JsonApsAlert (Just title) text subtitle

-- | Set the body of an APN message without affecting the title
setMessageBody
    :: Text
    -- ^ The body of the message
    -> JsonApsMessage
    -- ^ The message to alter
    -> JsonApsMessage
    -- ^ The modified message
setMessageBody text a = a { jamAlert = Just newJaa }
  where
    newJaa = case jamAlert a of
                Nothing  -> JsonApsAlert Nothing text Nothing
                Just jaa -> jaa { jaaBody = text }

-- | Remove the alert part of an APN message
clearAlertMessage
    :: JsonApsMessage
    -- ^ The message to modify
    -> JsonApsMessage
    -- ^ The modified message
clearAlertMessage a = a { jamAlert = Nothing }

instance ToJSON JsonApsMessage where
    toJSON     = genericToJSON     defaultOptions
        { fieldLabelModifier = \s -> case drop 3 s of
            "MutableContent" -> "mutable-content"
            "InterruptionLevel" -> "interruption-level"
            "ContentChanged" -> "content-changed"
            other -> map toLower other
        }

instance FromJSON JsonApsMessage where
    parseJSON = genericParseJSON defaultOptions
        { fieldLabelModifier = \s -> case drop 3 s of
            "mutable-content" -> "MutableContent"
            "interruption-level" -> "InterruptionLevel"
            "content-changed" -> "ContentChanged"
            other -> map toLower other
        }

-- | A push notification message
data JsonAps
    -- | A push notification message
    = JsonAps
    { jaAps                :: !JsonApsMessage
    -- ^ The main content of the message
    , jaAppSpecificContent :: !(Maybe Text)
    -- ^ Extra information to be used by the receiving app
    , jaSupplementalFields :: !(Map Text Value)
    -- ^ Additional fields to be used by the receiving app
    } deriving (Generic, Show)

instance FromJSON JsonAps where
    parseJSON = withObject "JsonAps" $ \o ->
      JsonAps <$> o .: "aps"
        <*> o .:? "appspecificcontent"
        <*> o .:  "data"

instance ToJSON JsonAps where
    toJSON JsonAps{..} = object (staticFields <> dynamicFields)
        where
            dynamicFields = [ "data" .= jaSupplementalFields ]
            staticFields = [ "aps" .= jaAps
                           , "appspecificcontent" .= jaAppSpecificContent
                           ]

-- | Prepare a new apn message consisting of a
-- standard message without a custom payload
newMessage
    :: JsonApsMessage
    -- ^ The standard message to include
    -> JsonAps
    -- ^ The resulting APN message
newMessage aps = JsonAps aps Nothing M.empty

-- | Prepare a new apn message consisting of a
-- standard message and a custom payload
newMessageWithCustomPayload
    :: JsonApsMessage
    -- ^ The message
    -> Text
    -- ^ The custom payload
    -> JsonAps
    -- ^ The resulting APN message
newMessageWithCustomPayload message payload =
    JsonAps message (Just payload) M.empty

-- | Create a new APN message for widget notifications with content-changed flag
newWidgetMessage :: JsonAps
newWidgetMessage = JsonAps widgetMessage Nothing M.empty
  where
    widgetMessage = emptyMessage { jamContentChanged = Just True }

-- | Add a supplemental field to be sent over with the notification
--
-- NB: The field 'aps' must not be modified; attempting to do so will
-- cause a crash.
addSupplementalField :: ToJSON record =>
       Text
    -- ^ The field name
    -> record
    -- ^ The value
    -> JsonAps
    -- ^ The APN message to modify
    -> JsonAps
    -- ^ The resulting APN message
addSupplementalField "aps"     _          _      = error "The 'aps' field may not be overwritten by user code"
addSupplementalField fieldName fieldValue oldAPN = oldAPN { jaSupplementalFields = newSupplemental }
    where
        oldSupplemental = jaSupplementalFields oldAPN
        newSupplemental = M.insert fieldName (toJSON fieldValue) oldSupplemental

-- | Start a new session for sending APN messages. A session consists of a
-- connection pool of connections to the APN servers, while each connection has a
-- pool of workers that create HTTP2 streams to send individual push
-- notifications.
newSession
    :: Maybe FilePath
    -- ^ Path to the client certificate key
    -> Maybe FilePath
    -- ^ Path to the client certificate
    -> Maybe FilePath
    -- ^ Path to the CA
    -> Bool
    -- ^ Whether to use JWT as a bearer token
    -> Bool
    -- ^ True if the apn development servers should be used, False to use the production servers
    -> Int
    -- ^ How many messages will be sent in parallel? This corresponds to the number of http2 streams open in parallel; 100 seems to be a default value.
    -> Int
    -- ^ How many connections to be opened at maximum.
    -> ByteString
    -- ^ Topic (bundle name of the app)
    -> IO ApnSession
    -- ^ The newly created session
newSession certKey certPath caPath useJwt dev maxparallel maxConnectionCount topic = do
    let hostname = if dev
            then "api.sandbox.push.apple.com"
            else "api.push.apple.com"
        connInfo = ApnConnectionInfo certPath certKey caPath hostname maxparallel topic useJwt
    unless useJwt $ do
      certsOk <- checkCertificates connInfo
      unless certsOk $ error "Unable to load certificates and/or the private key"

    isOpen <- newIORef True

    let connectionUnusedTimeout :: NominalDiffTime
        connectionUnusedTimeout = 300
    pool <-
        createPool
            (newConnection connInfo) closeApnConnection 1 connectionUnusedTimeout maxConnectionCount
    let session =
            ApnSession
            { apnSessionPool = pool
            , apnSessionOpen = isOpen
            }
    return session

-- | Manually close a session. The session must not be used anymore
-- after it has been closed. Calling this function will close
-- the worker thread, and all open connections to the APN service
-- that belong to the given session. Note that sessions will be closed
-- automatically when they are garbage collected, so it is not necessary
-- to call this function.
closeSession :: ApnSession -> IO ()
closeSession s = do
    isOpen <- atomicModifyIORef' (apnSessionOpen s) (False,)
    unless isOpen $ error "Session is already closed"
    destroyAllResources (apnSessionPool s)

-- | Check whether a session is open or has been closed
-- by a call to closeSession
isSessionOpen :: ApnSession -> IO Bool
isSessionOpen = readIORef . apnSessionOpen

-- | Check whether a session is open or has been closed
-- by a call to closeSession
{-# DEPRECATED isOpen "Use isSessionOpen instead." #-}
isOpen :: ApnSession -> IO Bool
isOpen = isSessionOpen

-- | Check whether the connection is open or has been closed.
isConnectionOpen :: ApnConnection -> IO Bool
isConnectionOpen = readIORef . apnConnectionOpen

timeoutSeconds :: Int
timeoutSeconds = 300 * 1_000_000 -- 300 seconds to microseconds

withConnection :: ApnSession -> (ApnConnection -> ClientIO a) -> ClientIO a
withConnection s action = do
    lift $ ensureSessionOpen s
    ExceptT . try $
        withResource (apnSessionPool s) $ \conn -> do
        ensureConnectionOpen conn
        mRes <- timeout timeoutSeconds (runClientIO (action conn))
        case mRes of
          Nothing -> do
            throw EarlyEndOfStream
          Just eRes -> do
            case eRes of
              Left clientError ->
                  -- When there is a clientError, we think that the connetion is broken.
                  -- Throwing an exception is the way we inform the resource pool.
                  throw clientError
              Right res -> return res

checkCertificates :: ApnConnectionInfo -> IO Bool
checkCertificates aci = do
  case (aciUseJWT aci) of
    True -> pure False
    False -> do
      castore <- maybe (pure Nothing) readCertificateStore $ aciCaPath aci
      credential <- loadCredentials aci
      return $ isJust castore && isRight credential

loadCredentials :: ApnConnectionInfo -> IO (Either String Credential)
loadCredentials aci =
    case (aciCertPath aci, aciCertKey aci) of
        (Just cert, Just key) -> credentialLoadX509 cert key
        (Just _, Nothing) -> pure $ Left "no cert"
        (Nothing, Just _) -> pure $ Left "no key"
        (Nothing, Nothing) -> pure $ Left "no creds"

newConnection :: ApnConnectionInfo -> IO ApnConnection
newConnection aci = do
    let maxConcurrentStreams = aciMaxConcurrentStreams aci
        conf = [ (HTTP2.SettingsMaxFrameSize, 16384)
               , (HTTP2.SettingsMaxConcurrentStreams, maxConcurrentStreams)
#if MIN_VERSION_http2(5,0,0)
               , (HTTP2.SettingsMaxHeaderListSize, 4096)
#else
               , (HTTP2.SettingsMaxHeaderBlockSize, 4096)
#endif
               , (HTTP2.SettingsInitialWindowSize, 65536)
               , (HTTP2.SettingsEnablePush, 1)
               ]
        hostname = aciHostname aci

    clip <- case (aciUseJWT aci) of
        True -> do
          castore <- getSystemCertificateStore
          let clip = (defaultParamsClient (T.unpack hostname) "")
                  { clientUseMaxFragmentLength=Nothing
                  , clientUseServerNameIndication=True
                  , clientWantSessionResume=Nothing
                  , clientShared=def
                      { sharedCAStore=castore }
                  , clientHooks=def
                      { onCertificateRequest = const . return $ Nothing }
                  , clientDebug=def
                      { debugSeed=Nothing, debugPrintSeed=const $ return (), debugVersionForced=Nothing, debugKeyLogger=const $ return () }
                  , clientSupported=def
                      { supportedVersions=[ TLS12 ]
                      , supportedCiphers=ciphersuite_strong }
#if MIN_VERSION_tls(2, 0, 0)
                  , clientUseEarlyData=False
#else
                  , clientEarlyData=Nothing
#endif
                  }
          pure clip
        False -> do
          Just castore <- maybe (pure Nothing) readCertificateStore $ aciCaPath aci
          Right credential <- loadCredentials aci
          let credentials = Credentials [credential]
              shared      = def { sharedCredentials = credentials
                                , sharedCAStore=castore }

              clip = (defaultParamsClient (T.unpack hostname) "")
                  { clientUseMaxFragmentLength=Nothing
                  , clientUseServerNameIndication=True
                  , clientWantSessionResume=Nothing
                  , clientShared=shared
                  , clientHooks=def
                      { onCertificateRequest=const . return . Just $ credential }
                  , clientDebug=def
                      { debugSeed=Nothing, debugPrintSeed=const $ return (), debugVersionForced=Nothing, debugKeyLogger=const $ return () }
                  , clientSupported=def
                      { supportedVersions=[ TLS12 ]
                      , supportedCiphers=ciphersuite_strong }
#if MIN_VERSION_tls(2, 0, 0)
                  , clientUseEarlyData=False
#else
                  , clientEarlyData=Nothing
#endif
                  }
          pure clip

    isOpen <- newIORef True
    let handleGoAway _rsgaf = do
            lift $ writeIORef isOpen False
            return ()
    client <-
        fmap (either throw id) . runClientIO $ do
        httpFrameConnection <- newHttp2FrameConnection (T.unpack hostname) 443 (Just clip)
        client <-
            newHttp2Client httpFrameConnection 4096 4096 conf handleGoAway ignoreFallbackHandler
        linkAsyncs client
        return client
    flowWorker <- forkIO $ forever $ do
        _updated <- runClientIO $ _updateWindow $ _incomingFlowControl client
        threadDelay 1000000
    workersem <- newQSem maxConcurrentStreams
    return $ ApnConnection client aci workersem flowWorker isOpen


closeApnConnection :: ApnConnection -> IO ()
closeApnConnection connection =
    -- Ignoring ClientErrors in this place. We want to close our session, so we do not need to
    -- fail on this kind of errors.
    void $ runClientIO $ do
    lift $ writeIORef (apnConnectionOpen connection) False
    let flowWorker = apnConnectionFlowControlWorker connection
    lift $ killThread flowWorker
    _gtfo (apnConnectionConnection connection) HTTP2.NoError ""
    _close (apnConnectionConnection connection)


-- | Send a raw payload as a push notification message (advanced)
sendRawMessage
    :: ApnSession
    -- ^ Session to use
    -> ApnToken
    -- ^ Device to send the message to
    -> Maybe ByteString
    -- ^ JWT Bearer Token
    -> Maybe ApnPriority
    -- ^ Priority (Nothing uses default)
    -> ByteString
    -- ^ The message to send
    -> IO ApnMessageResult
    -- ^ The response from the APN server
sendRawMessage s deviceToken mJwtToken mPriority payload = catchErrors $
    withConnection s $ \c ->
        sendApnRaw c deviceToken mJwtToken ApnPushTypeAlert mPriority payload

-- | Send a push notification message.
sendMessage
    :: ApnSession
    -- ^ Session to use
    -> ApnToken
    -- ^ Device to send the message to
    -> Maybe ByteString
    -- ^ JWT Bearer Token
    -> Maybe ApnPriority
    -- ^ Priority (Nothing uses default)
    -> JsonAps
    -- ^ The message to send
    -> IO ApnMessageResult
    -- ^ The response from the APN server
sendMessage s token mJwt mPriority payload = catchErrors $
    withConnection s $ \c ->
        sendApnRaw c token mJwt ApnPushTypeAlert mPriority message
  where message = L.toStrict $ encode payload

-- | Send a silent push notification
-- Note: This function automatically uses priority 5 as required by APNS spec for background notifications
sendSilentMessage
    :: ApnSession
    -- ^ Session to use
    -> ApnToken
    -- ^ Device to send the message to
    -> Maybe ByteString
    -- ^ JWT Bearer Token
    -> IO ApnMessageResult
    -- ^ The response from the APN server
sendSilentMessage s token mJwt = catchErrors $
    withConnection s $ \c ->
        sendApnRaw c token mJwt ApnPushTypeBackground (Just ApnPriorityPowerEfficient) message
  where message = "{\"aps\":{\"content-available\":1}}"

-- | Send a widget notification
-- Note: This function omits priority header by default (as per Apple's widget documentation)
sendWidgetNotification
    :: ApnSession
    -- ^ Session to use
    -> ApnToken
    -- ^ Device to send the message to
    -> Maybe ByteString
    -- ^ JWT Bearer Token
    -> Maybe ApnPriority
    -- ^ Priority (Nothing omits priority header, following Apple's widget example)
    -> IO ApnMessageResult
    -- ^ The response from the APN server
sendWidgetNotification s token mJwt mPriority = catchErrors $
    withConnection s $ \c ->
        sendApnRaw c token mJwt ApnPushTypeWidgets mPriority message
  where message = L.toStrict $ encode newWidgetMessage

ensureSessionOpen :: ApnSession -> IO ()
ensureSessionOpen s = do
    open <- isSessionOpen s
    unless open $ throwIO ApnExceptionConnectionClosed

ensureConnectionOpen :: ApnConnection -> IO ()
ensureConnectionOpen c = do
    open <- isConnectionOpen c
    unless open $ throwIO ApnExceptionConnectionClosed

-- | Send a push notification message.
sendApnRaw
    :: ApnConnection
    -- ^ Connection to use
    -> ApnToken
    -- ^ Device to send the message to
    -> Maybe ByteString
    -- ^ JWT Bearer Token
    -> ApnPushType
    -- ^ Push type (alert, background, widgets)
    -> Maybe ApnPriority
    -- ^ Priority (Nothing uses default for push type)
    -> ByteString
    -- ^ The message to send
    -> ClientIO ApnMessageResult
sendApnRaw connection deviceToken mJwtBearerToken pushType mPriority message = bracket_
  (lift $ waitQSem (apnConnectionWorkerPool connection))
  (lift $ signalQSem (apnConnectionWorkerPool connection)) $ do
    let aci = apnConnectionInfo connection
        priority = mPriority <|> (defaultPriorityForPushType pushType)
        requestHeaders = maybe (defaultHeaders hostname token1 topic pushType priority)
                         (\bearerToken -> (defaultHeaders hostname token1 topic pushType priority) <> [ ( "authorization", "bearer " <> bearerToken ) ])
                         mJwtBearerToken
        hostname = aciHostname aci
        topic = aciTopic aci
        client = apnConnectionConnection connection
        token1 = unApnToken deviceToken

    res <- _startStream client $ \stream ->
        let init = headers stream requestHeaders id
            handler isfc osfc = do
                -- sendData client stream (HTTP2.setEndStream) message
                upload message (HTTP2.setEndHeader . HTTP2.setEndStream) client (_outgoingFlowControl client) stream osfc
                let pph _hStreamId _hStream hHeaders _hIfc _hOfc =
                        lift $ print hHeaders
#if MIN_VERSION_http2_client(0, 10, 0)
                response <- waitStream client stream isfc pph
#else
                response <- waitStream stream isfc pph
#endif
                let (errOrHeaders, frameResponses, _) = response
                case errOrHeaders of
                    Left err -> throwIO (ApnExceptionHTTP err)
                    Right hdrs1 -> do
                        let status       = getHeaderEx ":status" hdrs1
                            -- apns-id      = getHeaderEx "apns-id" hdrs1
                            [Right body] = frameResponses

                        return $ case status of
                            "200" -> ApnMessageResultOk
                            "400" -> decodeReason ApnMessageResultFatalError body
                            "403" -> decodeReason ApnMessageResultFatalError body
                            "405" -> decodeReason ApnMessageResultFatalError body
                            "410" -> decodeReason ApnMessageResultFatalError body
                            "413" -> decodeReason ApnMessageResultFatalError body
                            "429" -> decodeReason ApnMessageResultTemporaryError body
                            "500" -> decodeReason ApnMessageResultTemporaryError body
                            "503" -> decodeReason ApnMessageResultTemporaryError body
                            unknown ->
                                ApnMessageResultFatalError $
                                ApnFatalErrorOther (T.pack $ "unhandled status: " ++ show unknown)
        in StreamDefinition init handler
    case res of
        Left _     -> return ApnMessageResultBackoff -- Too much concurrency
        Right res1 -> return res1

    where
        decodeReason :: FromJSON response => (response -> ApnMessageResult) -> ByteString -> ApnMessageResult
        decodeReason ctor = either (throw . ApnExceptionJSON) id . decodeBody . L.fromStrict
            where
                decodeBody body =
                    eitherDecode body
                        >>= parseEither (\obj -> ctor <$> obj .: "reason")

        getHeaderEx :: HTTP.HeaderName -> [HTTP2.Header] -> ByteString
        getHeaderEx name headers = fromMaybe (throw $ ApnExceptionMissingHeader name) (DL.lookup name headers)

        defaultHeaders :: Text -> ByteString -> ByteString -> ApnPushType -> Maybe ApnPriority -> [(HTTP.HeaderName, ByteString)]
        defaultHeaders hostname token topic pushType mPriority = 
            [ ( ":method", "POST" )
            , ( ":scheme", "https" )
            , ( ":authority", TE.encodeUtf8 hostname )
            , ( ":path", "/3/device/" `S.append` token )
            , ( "apns-topic", adjustedTopic )
            , ( "apns-push-type", pushTypeHeader )
            ] <> maybe [] (\p -> [("apns-priority", priorityValue p)]) mPriority
          where
            pushTypeHeader = case pushType of
                ApnPushTypeAlert -> "alert"
                ApnPushTypeBackground -> "background"  
                ApnPushTypeWidgets -> "widgets"
            adjustedTopic = case pushType of
                ApnPushTypeWidgets -> topic `S.append` ".push-type.widgets"
                ApnPushTypeAlert -> topic
                ApnPushTypeBackground -> topic
            priorityValue :: ApnPriority -> ByteString
            priorityValue ApnPriorityImmediate = "10"
            priorityValue ApnPriorityPowerEfficient = "5"
            priorityValue ApnPriorityLow = "1"


catchErrors :: ClientIO ApnMessageResult -> IO ApnMessageResult
catchErrors = catchIOErrors . catchClientErrors
    where
        catchIOErrors :: IO ApnMessageResult -> IO ApnMessageResult
        catchIOErrors = flip catchIOError (return . ApnMessageResultIOError)

        catchClientErrors :: ClientIO ApnMessageResult -> IO ApnMessageResult
        catchClientErrors act =
            either ApnMessageResultClientError id <$> runClientIO act


-- The type of permanent error indicated by APNS
-- See https://apple.co/2RDCdWC table 8-6 for the meaning of each value.
data ApnFatalError = ApnFatalErrorBadCollapseId
                   | ApnFatalErrorBadDeviceToken
                   | ApnFatalErrorBadExpirationDate
                   | ApnFatalErrorBadMessageId
                   | ApnFatalErrorBadPriority
                   | ApnFatalErrorBadTopic
                   | ApnFatalErrorDeviceTokenNotForTopic
                   | ApnFatalErrorDuplicateHeaders
                   | ApnFatalErrorIdleTimeout
                   | ApnFatalErrorMissingDeviceToken
                   | ApnFatalErrorMissingTopic
                   | ApnFatalErrorPayloadEmpty
                   | ApnFatalErrorTopicDisallowed
                   | ApnFatalErrorBadCertificate
                   | ApnFatalErrorBadCertificateEnvironment
                   | ApnFatalErrorExpiredProviderToken
                   | ApnFatalErrorForbidden
                   | ApnFatalErrorInvalidProviderToken
                   | ApnFatalErrorMissingProviderToken
                   | ApnFatalErrorBadPath
                   | ApnFatalErrorMethodNotAllowed
                   | ApnFatalErrorUnregistered
                   | ApnFatalErrorPayloadTooLarge
                   | ApnFatalErrorOther Text
    deriving (Eq, Show, Generic)

instance FromJSON ApnFatalError where
    parseJSON json =
        let result = parse genericParser json
        in
            case result of
                Success success -> return success
                Error err -> case json of
                                String other -> return $ ApnFatalErrorOther other
                                _            -> fail err

        where
            genericParser = genericParseJSON defaultOptions {
                                constructorTagModifier = drop 13,
                                sumEncoding = UntaggedValue
                            }

-- The type of transient error indicated by APNS
-- See https://apple.co/2RDCdWC table 8-6 for the meaning of each value.
data ApnTemporaryError = ApnTemporaryErrorTooManyProviderTokenUpdates
                       | ApnTemporaryErrorTooManyRequests
                       | ApnTemporaryErrorInternalServerError
                       | ApnTemporaryErrorServiceUnavailable
                       | ApnTemporaryErrorShutdown
    deriving (Enum, Eq, Show, Generic, ToJSON)

instance FromJSON ApnTemporaryError where
    parseJSON = genericParseJSON defaultOptions { constructorTagModifier = drop 17 }
