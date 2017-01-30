module Hyper.Routing.TypeLevelRouterSpec (spec) where

import Prelude
import Control.Monad.Except (ExceptT)
import Data.Argonaut (class EncodeJson, Json, jsonEmptyObject, (:=), (~>))
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), maybe)
import Data.MediaType.Common (textPlain)
import Data.String (joinWith, trim)
import Data.Tuple (Tuple(..))
import Data.URI (printURI)
import Hyper.Core (class ResponseWriter, Conn, Middleware, ResponseEnded, StatusLineOpen, closeHeaders, writeStatus)
import Hyper.HTML (class EncodeHTML, HTML, h1, text)
import Hyper.Method (Method(..))
import Hyper.Response (class Response, contentType, headers, respond)
import Hyper.Routing.PathPiece (class FromPathPiece, class ToPathPiece)
import Hyper.Routing.TypeLevelRouter (type (:/), type (:<|>), type (:>), Capture, CaptureAll, Raw, RoutingError, linksTo, router, (:<|>))
import Hyper.Routing.TypeLevelRouter.Method (Get)
import Hyper.Status (statusBadRequest, statusMethodNotAllowed, statusOK)
import Hyper.Test.TestServer (testHeaders, testResponseWriter, testServer, testStatus, testStringBody)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Type.Proxy (Proxy(..))

data Home = Home

instance encodeHTMLHome :: EncodeHTML Home where
  encodeHTML Home = h1 [] [text "Home"]

newtype UserID = UserID String

instance fromPathPieceUserID :: FromPathPiece UserID where
  fromPathPiece s =
    case trim s of
      "" -> Left "UserID must not be blank."
      s' -> Right (UserID s')

instance toPathPieceUserID :: ToPathPiece UserID where
  toPathPiece (UserID s) = s

data User = User UserID

instance encodeUser :: EncodeJson User where
  encodeJson (User (UserID userId)) =
    "userId" := userId
    ~> jsonEmptyObject

data WikiPage = WikiPage String

instance encodeHTMLWikiPage :: EncodeHTML WikiPage where
  encodeHTML (WikiPage title) = text ("Viewing page: " <> title)

type TestAPI =
  Get HTML Home
  -- nested routes with capture
  :<|> "users" :/ Capture "user-id" UserID :> ("profile" :/ Get Json User
                                               :<|> "friends" :/ Get Json (Array User))
  -- capture all
  :<|> "wiki" :/ CaptureAll "segments" String :> Get HTML WikiPage
  -- raw middleware
  :<|> "about" :/ Raw "GET"

testSite :: Proxy TestAPI
testSite = Proxy

type Handler m a = ExceptT RoutingError m a

home :: forall m. Monad m => Handler m Home
home = pure Home

profile :: forall m. Monad m => UserID -> Handler m User
profile userId = pure (User userId)

friends :: forall m. Monad m => UserID -> Handler m (Array User)
friends (UserID uid) =
  pure [ User (UserID "foo")
       , User (UserID "bar")
       ]

wiki :: forall m. Monad m => Array String -> Handler m WikiPage
wiki segments = pure (WikiPage (joinWith "/" segments))

about :: forall m req res c rw rb.
         ( Monad m
         , ResponseWriter rw (ExceptT RoutingError m) rb
         , Response rb (ExceptT RoutingError m) String
         )
         => Middleware
            (ExceptT RoutingError m)
            (Conn { method :: Method, url :: String | req } { writer :: rw StatusLineOpen | res } c)
            (Conn { method :: Method, url :: String | req } { writer :: rw ResponseEnded | res } c)
about =
  writeStatus statusOK
  >=> contentType textPlain
  >=> closeHeaders
  >=> respond "This is a test."

spec :: forall e. Spec e Unit
spec = do
  let userHandlers userId = profile userId :<|> friends userId
      handlers = home
                 :<|> userHandlers
                 :<|> wiki
                 :<|> about

      onRoutingError status msg =
        writeStatus status
        >=> headers []
        >=> respond (maybe "" id msg)

      makeRequest method path =
        { request: { method: method
                   , url: path
                   }
        , response: { writer: testResponseWriter }
        , components: {}
        }
        # (router testSite handlers onRoutingError)
        # testServer

  describe "Hyper.Routing.TypeLevelRouter" do
    pure unit

    describe "links" $

      case linksTo testSite of
        (homeUri :<|> userLinks :<|> wikiUri :<|> aboutUri) -> do

          it "returns link for Lit" $
            printURI homeUri `shouldEqual` "/"

          it "returns link for nested routes" $
            case userLinks (UserID "owi") of
              (profileUri :<|> friendsUri) -> do
                  printURI profileUri `shouldEqual` "/users/owi/profile"
                  printURI friendsUri `shouldEqual` "/users/owi/friends"

          it "returns link for CaptureAll" $
            printURI (wikiUri ["foo", "bar", "baz.txt"]) `shouldEqual` "/wiki/foo/bar/baz.txt"

          it "returns link for Raw" $
            printURI aboutUri `shouldEqual` "/about"

    describe "route" do
      it "matches root" do
        conn <- makeRequest GET "/"
        testStringBody conn `shouldEqual` "<h1>Home</h1>"

      it "validates based on custom Capture instance" do
        conn <- makeRequest GET "/users/ /profile"
        testStatus conn `shouldEqual` Just statusBadRequest
        testStringBody conn `shouldEqual` "UserID must not be blank."

      it "matches nested routes" do
        conn <- makeRequest GET "/users/owi/profile"
        testStringBody conn `shouldEqual` "{\"userId\":\"owi\"}"

      it "supports arrays of JSON values" do
        conn <- makeRequest GET "/users/owi/friends"
        testStringBody conn `shouldEqual` "[{\"userId\":\"foo\"},{\"userId\":\"bar\"}]"

      it "matches CaptureAll route" do
        conn <- makeRequest GET "/wiki/foo/bar/baz.txt"
        testStringBody conn `shouldEqual` "Viewing page: foo/bar/baz.txt"

      it "matches Raw route" do
        conn <- makeRequest GET "/about"
        testHeaders conn `shouldEqual` [ Tuple "Content-Type" "text/plain" ]
        testStringBody conn `shouldEqual` "This is a test."

      it "checks HTTP method" do
        conn <- makeRequest POST "/"
        testStatus conn `shouldEqual` Just statusMethodNotAllowed
