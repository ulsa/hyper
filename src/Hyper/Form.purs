module Hyper.Form
       ( Form(..)
       , parseForm
       , fromForm
       , toForm
       , class FromForm
       , class ToForm
       ) where

import Prelude
import Control.IxMonad (ibind, ipure)
import Control.Monad.Eff.Exception (error, Error)
import Control.Monad.Error.Class (throwError)
import Data.Array (head)
import Data.Either (Either)
import Data.Generic (class Generic)
import Data.Maybe (Maybe(Just, Nothing))
import Data.MediaType (MediaType(MediaType))
import Data.MediaType.Common (applicationFormURLEncoded)
import Data.Monoid (class Monoid)
import Data.StrMap (lookup, StrMap)
import Data.String (split, joinWith, Pattern(Pattern))
import Data.Traversable (sequence)
import Data.Tuple (Tuple(Tuple))
import Global (decodeURIComponent)
import Hyper.Conn (Conn)
import Hyper.Middleware (Middleware)
import Hyper.Middleware.Class (getConn)
import Hyper.Request (class RequestBodyReader, readBody)

newtype Form = Form (Array (Tuple String String))

derive instance genericForm :: Generic Form
derive newtype instance eqForm :: Eq Form
derive newtype instance ordForm :: Ord Form
derive newtype instance showForm :: Show Form
derive newtype instance monoidForm :: Monoid Form


parseContentMediaType :: String -> Maybe MediaType
parseContentMediaType = split (Pattern ";")
                        >>> head
                        >>> map MediaType

toTuple :: Array String -> Either Error (Tuple String String)
toTuple kv =
  case kv of
    [key, value] ->
      pure (Tuple (decodeURIComponent key) (decodeURIComponent value))
    parts ->
      throwError (error ("Invalid form key-value pair: " <> joinWith " " parts))

splitPairs :: String → Either Error (Array (Tuple String String))
splitPairs = split (Pattern "&")
             >>> map (split (Pattern "="))
             >>> map toTuple
             >>> sequence

parseForm ∷ forall m req res c r.
            ( Monad m
            , RequestBodyReader r m String
            ) =>
            Middleware
            m
            (Conn { body :: r
                  , headers :: StrMap String
                  | req
                  } res c)
            (Conn { body ∷ r
                  , headers :: StrMap String
                  | req
                  }
                  res
                  c)
            (Either Error Form)
parseForm = do
  conn <- getConn
  body <- readBody
  case lookup "content-type" conn.request.headers >>= parseContentMediaType of
    Nothing ->
      ipure (throwError (error "Missing or invalid content-type header."))
    Just mediaType | mediaType == applicationFormURLEncoded ->
      ipure (Form <$> splitPairs body)
    Just mediaType ->
      ipure (throwError (error ("Cannot parse media of type: " <> show mediaType)))
  where bind = ibind

class ToForm a where
  toForm ∷ a → Form

class FromForm a where
  fromForm ∷ Form → Either Error a
