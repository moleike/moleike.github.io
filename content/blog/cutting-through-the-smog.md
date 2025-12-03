---
title: "Cutting through the Smog: Making an Air Quality Bot with Haskell"
date: 2019-05-30
description: "A Haskell tutorial where I show you how a vigilant bot can help you slash your pollution intake."
tags:
  - haskell
  - taiwan
  - chatbots
  - tutorial
---

_This tutorial was cross-posted to the [LINE
Engineering](https://engineering.linecorp.com/en) blog, [here][original-post]._

[original-post]: https://engineering.linecorp.com/en/blog/cutting-through-the-smog-making-an-air-quality-bot-with-haskell

Long and (gasp!) short-term exposure to air pollution can result in significant
health problems[^1]. When air quality is appallingly poor, you should refrain
from doing any sort of physical activity outdoors. Poor air quality is
unfortunately a common theme in Taipei over the winter. In very bad days, it is
easy to tell---[Taipei 101][101] nowhere to be seen---but oftentimes we just can't tell.
Can we then get somehow alerted when air quality is bad, without having to
resort to looking at the 101?

In this tutorial, I want to show you how to build a chatbot in Haskell to do just that:
help you to reduce your pollution intake. This tutorial assumes some familiarity with Haskell.

[^1]: https://www.eea.europa.eu/en/topics/in-depth/air-pollution/eow-it-affects-our-health

## Why using a chatbot?

[LINE](https://line.me/en/) has an impressive market penetration across the APAC
region; in Taiwan, 86% of the population are monthly active users[^2]. Not
surpringly, most of my online communication here in Taiwan is _on_ LINE. Being
an instant messaging service, the way to integrate 3rd party services with LINE,
is through the use of chatbots. Chatbots are conversational tools that make it
easy to automate tasks, from simple chores like translating messages, to
scheduling meetings or do fact-checking.

So, whether you are part of a running club, or joined a local hiking community,
having a chatbot informing everyone when the air is second-rate, sounds fitting.

[^2]: https://www.infocubic.co.jp/en/blog/taiwan/how-to-win-the-hearts-and-trust-of-taiwanese-consumers/

We are going to be using the [line-bot-sdk][line-bot-sdk], a Haskell SDK for the
LINE messaging platform. You can read an overview of the LINE Messaging API
[here][overview].

> This blog post was generated from literate Haskell sources. For those who
> prefer to read the code, an extraction version can be found [here][source].

The [line-bot-sdk][line-bot-sdk] uses the [servant][servant] framework, a set of
packages for declaring web APIs at the type-level. Here are the GHC language
extensions we need for this example to work:

```haskell
{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeOperators     #-}
```

## Imports

```haskell
import           Control.Concurrent.Lifted   (fork, threadDelay)
import           Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVar,
                                              readTVar)
import           Control.Exception           (try)
import           Control.Monad               (forM, forM_, forever)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Control.Monad.Reader
import           Control.Monad.STM           (atomically, retry)
import           Control.Monad.Trans.Class   (lift)
import           Control.Monad.Trans.Control (MonadBaseControl)
import           Control.Monad.Trans.Maybe   (runMaybeT, MaybeT(..))
import           Data.Aeson
import           Data.Aeson.QQ               (aesonQQ)
import           Data.Aeson.Types
import           Data.Bifunctor
import           Data.List.Extra             (minimumOn)
import           Data.Maybe                  (catMaybes)
import           Data.String                 (fromString)
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import qualified Data.Vector                 as V
import           Line.Bot.Client
import           Line.Bot.Types              as B
import           Line.Bot.Webhook            as W
import           Network.HTTP.Simple         hiding (Proxy)
import           Network.Wai.Handler.Warp    (runEnv)
import           Servant
import           Servant.Server              (Context ((:.), EmptyContext))
import           System.Environment          (getEnv)
import           Text.Read                   (readMaybe)
```

## Parsing measurement data

The Taiwan's [Environmental Protection Administration][epa] monitors air
pollution in major cities and counties across Taiwan. They have a public API
with the latest registered air pollution:

```sh
curl https://opendata.epa.gov.tw/ws/Data/AQI/?\$format=json | jq .
```

```json
[
  {
    "SiteName": "基隆",
    "County": "基隆市",
    "AQI": "40",
    "Pollutant": "",
    "Status": "良好",
    "SO2": "3.7",
    "CO": "0.24",
    "CO_8hr": "0.2",
    "O3": "44",
    "O3_8hr": "43",
    "PM10": "25",
    "PM2.5": "10",
    "NO2": "",
    "NOx": "",
    "NO": "",
    "WindSpeed": "1.1",
    "WindDirec": "90",
    "PublishTime": "2019-04-29 16:00",
    "PM2.5_AVG": "12",
    "PM10_AVG": "27",
    "SO2_AVG": "2",
    "Longitude": "121.760056",
    "Latitude": "25.129167"
  }
]
```

This API returns a JSON array with measured data from all the monitoring
stations in Taiwan, typically updated every hour.

An [AQI][aqi] number under 100 signifies good or acceptable air quality, while a
number over 100 is cause for concern. Among the reported pollutants there are
particulate matter, ground level ozone, carbon monoxide and sulfur dioxide.

We will additionally need the location of the measurement, which we will use to
find the closest available data to our users:

```haskell
data AQData = AQData
    { aqi    :: Int
    , county :: Text
    , lat    :: Double
    , lng    :: Double
    , status :: Text
    , pm25   :: Int
    , pm10   :: Int
    , o3     :: Int
    , co     :: Double
    , so2    :: Double
    }
  deriving (Eq, Show)
```

However, first we need to do some data preprocessing:

- note that all the JSON fields are strings, but our `AQData` type requires
  numeric values
- there are some data points missing relevant details, such as the AQI or the
  location:

```json
{
    "SiteName": "彰化(大城)",
    "County": "彰化縣",
    "AQI": "",
    "Pollutant": "",
    ...
}
```

So we need to remove such data points, since they amount to noise. One possible
way to do this, is by wrapping `[AQData]` in a `newtype`:

```haskell
newtype AQDataResult = AQDataResult { result :: [AQData] }
```

And then provide an instance of the `FromJSON` class to decode and _filter_ bad
values:

```haskell
instance FromJSON AQDataResult where
  parseJSON = undefined
```

However, there is another possibility. `FromJSON` has another method we can
implement:

```haskell
parseJSONList :: Value -> Parser [a]
```

```haskell
instance FromJSON AQData where
  parseJSONList = withArray "[AQData]" $ \arr ->
    catMaybes <$> forM (V.toList arr) parseAQData

  parseJSON _   = fail "not an array"
```

Array items go through `parseAQData`. Here the `MaybeT` monad transformer
produces a value only if all items are present:

```haskell
parseAQData :: Value -> Parser (Maybe AQData)
parseAQData = withObject "AQData" $ \o -> runMaybeT $ do
  aqi    <- MaybeT $ readMaybe <$> o .: "AQI"
  county <- lift   $               o .: "County"
  lat    <- MaybeT $ readMaybe <$> o .: "Latitude"
  lng    <- MaybeT $ readMaybe <$> o .: "Longitude"
  status <- lift   $               o .: "Status"
  pm25   <- MaybeT $ readMaybe <$> o .: "PM2.5"
  pm10   <- MaybeT $ readMaybe <$> o .: "PM10"
  o3     <- MaybeT $ readMaybe <$> o .: "O3"
  co     <- MaybeT $ readMaybe <$> o .: "CO"
  so2    <- MaybeT $ readMaybe <$> o .: "SO2"
  return AQData {..}
```

We then use `catMaybes :: [Maybe a] -> [a]` function to weed out the `Nothing`s
and return a list of `AQData`. Now that we have a `FromJSON` instance, we can
write a client function to call this API:

```haskell
getAQData :: IO [AQData]
getAQData = do
  eresponse <- try $ httpJSON opendata
  case eresponse of
    Left e -> do
      print (e :: HttpException)
      getAQData -- retry
    Right response -> return $ getResponseBody response
  where
    opendata = "https://opendata.epa.gov.tw/ws/Data/AQI?$format=json"
```

Here we only intercept exceptions of type `HTTPException`. For simplicity we
just retry if the request fails, in practice you should inspect the error and
implement retries with exponential backoff.

## Distance between two geo points

We want our bot to notify users of unhealthy air in the regions where they live
and work, so first we need to know which monitor is the closest to the users.
For that, we will use the [harvesine formula][harvesine], which determines the
great-circle distance between two points on a sphere given their longitudes and
latitudes.

First let's define a type alias for latitude/longitude pairs (in degrees):

```haskell
type Coord = (Double, Double)
```

```haskell
distRad :: Double -> Coord -> Coord -> Double
distRad radius (lat1, lng1) (lat2, lng2) = 2 * radius * asin (min 1.0 root)
  where
    hlat = hsin (lat2 - lat1)
    hlng = hsin (lng2 - lng1)
    root = sqrt (hlat + cos lat1 * cos lat2 * hlng)
    hsin = (^ 2) . sin . (/ 2) -- harvesine of an angle
```

```haskell
distDeg :: Double -> Coord -> Coord -> Double
distDeg radius p1 p2 = distRad radius (deg2rad p1) (deg2rad p2)
  where
    d2r = (/ 180) . (* pi)
    deg2rad = bimap d2r d2r
```

```haskell
distance :: Coord -> Coord -> Double
distance = distDeg 6371 -- mean earth radius
```

With `distance` we can calculate the distance in kilometers between any two
given geo points. Now only reminds extract the air quality data point that is
closest to a given location:

```haskell
getCoord :: AQData -> Coord
getCoord AQData{..} = (lat, lng)

closestTo :: [AQData] -> Coord -> AQData
closestTo xs coord = (distance coord . getCoord) `minimumOn` xs
```

`minimumOn :: Ord b => (a -> b) -> [a] -> a` is defined in the package
[extra][extra].

[extra]: https://hackage.haskell.org/package/extra

## App environment

To use the Messaging API, you must create a channel. Most of the computations we
are going to define require access to the channel token, for issuing requests to
the LINE platform, and a channel secret, to keep your bot safe. We will put them
in a shared environment:

```haskell
data Env = Env
  { token  :: ChannelToken
  , secret :: ChannelSecret
  , users  :: TVar [(Source, Coord)]
  }
```

Additionally, we need the list of users, which are represented as `(Source, Coord)`. `Source` is defined in `Line.Bot.Webhook.Events` and it contains the
`Id` of the user, group or room where push messages will be sent.

We need to synchronize access to the `users` list, since it will be concurrently
read and updated from separate threads, and so we place it in a transactional
variable, `Control.Concurrent.STM.TVar`, from the [stm][stm] package, which
provides synchronization primitives for running actions atomically.

## Handling webhook events

In order to interact with users, we will register a webhook URL with the
channel. Events like user messages or joining a chatroom, will be send to
our server via HTTP. Here we are interested in three types of events (other
events are just ignored):

- when our bot is added as a friend (or unblocked)
- joins a group or room
- receives a [location message][location-message] from a user

For the remaining of the tutorial, we will use [mtl][mtl] type classes[^4] for
modularity. The main type classes we need are `MonadIO`, for actions where IO
computations can be embedded, and `MonadReader` for functions that access the
shared environment `Env`.

[^4]: The so-called mtl-style programming

```haskell
webhook :: (MonadReader Env m, MonadIO m) => [Event] -> m NoContent
webhook events = do
  forM_ events $ \case
    EventFollow  {..} -> askLoc replyToken
    EventJoin    {..} -> askLoc replyToken
    EventMessage { message = W.MessageLocation {..}
                 , source
                 }    -> addUser source (latitude, longitude)
    _                 -> return ()
  return NoContent
```

For the first two events, `EventFollow` and `EventJoin`, we reply with a text
message that contains a quick reply button, with a location action: this allows
the users to easily share their location for air monitoring.

> There are also _dual_ events, `EventUnfollow` and `EventLeave` that we omit
> but you should probably handle.

We are using `Line.Bot.Types.ReplyToken`, which is included in events that can
be replied:

```haskell
replyMessage :: ReplyToken -> [Message] -> Line NoContent
```

[Line][line-client] is the monad to send requests to the LINE bot platform.

[line-client]: http://hackage.haskell.org/package/line-bot-sdk/docs/Line-Bot-Client.html

```haskell
askLoc :: (MonadReader Env m, MonadIO m) => ReplyToken -> m ()
askLoc rt = do
  Env {token} <- ask
  _ <- liftIO $ runLine comp token
  return ()
    where
      welcome = "Where are you?"
      qr      = QuickReply [QuickReplyButton Nothing (ActionLocation "location")]
      comp    = replyMessage rt [B.MessageText welcome (Just qr)]
```

`MessageText` is a data constructor from `Line.Bot.Types.Message`. All messages
can be sent with an optional `QuickReply`; Quick replies allow users to select
from a predefined set of possible replies, see [here][using-quick-replies] for
more details on using quick replies.

Finally `runLine` runs the given request with the channel token from the
environment[^5]:

```haskell
runLine :: Line a -> ChannelToken -> IO (Either ClientError a)
```

[^5]:
    Note that in order to keep this tutorial concise, we are not checking for
    possible errors, but you should pattern match the result of `runLine`. `Line`
    has an instance of [`MonadError ClientError`][monad-error] so you can catch
    errors there, too.

[using-quick-replies]: https://developers.line.biz/en/docs/messaging-api/using-quick-reply/
[monad-error]: http://hackage.haskell.org/package/mtl-2.2.2/docs/Control-Monad-Error.html

Once we receive a location message event, handled in the equation for
`EventMessage`, we add the user and her location to the shared list of users:

```haskell
addUser :: (MonadReader Env m, MonadIO m) => Source -> Coord -> m ()
addUser source coord = do
  Env {users} <- ask
  liftIO $ atomically $ modifyTVar users ((source, coord) :)
  return ()
```

We add the source of the event, so if the message was sent from a group, we will
notify the group, not the user who shared the location.

## Serving the webhook: WAI application

To serve our webhook API we need to produce a [WAI][wai] app.

The line-bot-sdk exports a type synonym defined in `Line.Bot.Webhook` that
encodes the LINE webhook API:

```haskell
newtype Events :: Events { events :: [Event] }
type Webhook = LineReqBody '[JSON] Events :> Post '[JSON] NoContent
```

The `LineReqBody` combinator will validate that incoming requests originate from
the LINE platform.

```haskell
aqServer :: ServerT Webhook (ReaderT Env Handler)
aqServer = webhook . events
```

Servant handlers run by default in the `Handler` monad. In order to let our
webhook handler to read the environment `Env` (which is enforced by the type
constraint in `webhook`) we are going to stack the Reader monad.

> It is beyond the scope of this tutorial to cover the type wizardry of the
> Servant web framework, which is done rather nicely in the [servant tutorials][servant-tutorial].

```haskell
api = Proxy :: Proxy Webhook
ctx = Proxy :: Proxy '[ChannelSecret]

app :: MonadReader Env m => m Application
app = ask >>= \env ->
  let server = hoistServerWithContext api ctx (`runReaderT` env) aqServer
  in  return $ serveWithContext api (secret env :. EmptyContext) server
```

The final step is to turn our `aqServer` into a WAI `Application`.

Servant allows to pass values to combinators by using a `Context`. The
`LineReqBody` combinator requires a `Context` with the channel secret. This is
enforced by the type-level list `'[ChannelSecret]`.

## Periodic updates

We previously defined `getAQData`, which is an `IO` action that returns the list
of (valid) data points. Our goal now is to call this API every hour to get the
latest measured data and map it to our users, based on the location:

```haskell
processAQData :: (MonadReader Env m, MonadIO m) => m ()
processAQData = do
  Env {users, token} <- ask
  users' <- liftIO $ atomically $ do
    xs <- readTVar users
    case xs of
      [] -> retry
      _  -> return xs
  liftIO $ getAQData >>= \aqData ->
    let users'' = [(user, aqData `closestTo` coord) | (user, coord) <- users']
    in  forM_ users'' $ flip runLine token . notifyChat
  return ()
```

`processAQData` does serveral things[^6]:

- read the list stored in the transactional variable `users` in the environment:
  if the list is empty, `retry`, blocking the thread until users are added
- call `getAQData` to get the most recently available air quality data
- we then run a list comprehension where we map each user, of type `(Source, Coord)` to `(Source, AQData)`
- for each user, call `notifyChat`

[^6]:
    The naive solution we are building here to associate users to monitoring
    stations would be impractical for a real application, where it would make more
    sense to filter out those data points where pollution is of concern, and then
    for each data point retrieve all users that are within a given distance e.g.
    using a geospatial index, and notify them with [multicast
    messages][multicast-messages].

[multicast-messages]: https://developers.line.biz/en/reference/messaging-api/#send-multicast-message

```haskell
notifyChat :: (Source, AQData) -> Line NoContent
notifyChat (Source a, x)
  | unhealthy x = pushMessage a [mkMessage x]
  | otherwise   = return NoContent
```

To alert users, we will push messages to those users whose closest monitoring
station reports an AQI over 100:

```haskell
unhealthy :: AQData -> Bool
unhealthy AQData{..} = aqi > 100
```

`processAQData` needs to be called periodically, at least once every hour. We
will run it in a separate thread, so that it runs concurrently with our webhook
server:

```haskell
loop :: (MonadReader Env m, MonadIO m, MonadBaseControl IO m) => m ()
loop = do
  fork $ forever $ do
    processAQData
    threadDelay (3600 * 10^6)
  return ()
```

## Air quality alerts

To inform users of pollution levels, we will use a [Flex
Message][flex-messages], which are messages with customizable layouts written in
JSON format.

```haskell
mkMessage :: AQData -> B.Message
mkMessage x = B.MessageFlex "air quality alert!" (flexContent x) Nothing
```

A Flex message is constructed from an alternative text (for clients not
supporting the feature), a `Data.Aeson.Value` which contains the message layout
and content, and an optional quick reply:

```haskell
MessageFlex :: Text -> Value -> Maybe QuickReply -> Message
```

To design the layout of the alert message we used the [Flex Message
Simulator][simulator]. We will use the JSON quasiquoter [`aesonQQ`][aeson-qq],
which converts (at compile time) a string representation of a JSON value into a
`Value`:

[aeson-qq]: http://hackage.haskell.org/package/aeson-qq
[simulator]: https://developers.line.biz/console/fx/

{{< details "JSON Flex message" >}}

````haskell
flexContent :: AQData -> Value
flexContent AQData{..} = [aesonQQ|
  {
    "type": "bubble",
    "styles": {
      "footer": {
        "separator": true
      }
    },
    "header": {
      "type": "box",
      "layout": "vertical",
      "contents": [
        {
          "type": "text",
          "text": "AIR QUALITY ALERT",
          "weight": "bold",
          "size": "xl",
          "color": "#ff0000",
          "margin": "md"
        },
        {
          "type": "text",
          "text": "Unhealthy air reported in your area",
          "size": "xs",
          "color": "#aaaaaa",
          "wrap": true
        }
      ]
    },
    "body": {
      "type": "box",
      "layout": "vertical",
      "contents": [
        {
          "type": "box",
          "layout": "vertical",
          "margin": "xxl",
          "spacing": "sm",
          "contents": [
            {
              "type": "box",
              "layout": "horizontal",
              "contents": [
                {
                  "type": "text",
                  "text": "County",
                  "size": "sm",
                  "color": "#555555",
                  "flex": 0
                },
                {
                  "type": "text",
                  "text": #{county},
                  "size": "sm",
                  "color": "#111111",
                  "align": "end"
                }
              ]
            },
            {
              "type": "box",
              "layout": "horizontal",
              "contents": [
                {
                  "type": "text",
                  "text": "Status",
                  "size": "sm",
                  "color": "#555555",
                  "flex": 0
                },
                {
                  "type": "text",
                  "text": #{status},
                  "size": "sm",
                  "color": "#111111",
                  "align": "end"
                }
              ]
            },
            {
              "type": "box",
              "layout": "horizontal",
              "contents": [
                {
                  "type": "text",
                  "text": "AQI",
                  "weight": "bold",
                  "size": "sm",
                  "color": "#ff0000",
                  "flex": 0
                },
                {
                  "type": "text",
                  "text": #{show aqi},
                  "weight": "bold",
                  "size": "sm",
                  "color": "#ff0000",
                  "align": "end"
                }
              ]
            },
            {
              "type": "box",
              "layout": "horizontal",
              "contents": [
                {
                  "type": "text",
                  "text": "PM2.5",
                  "size": "sm",
                  "color": "#555555",
                  "flex": 0
                },
                {
                  "type": "text",
                  "text": #{show pm25},
                  "size": "sm",
                  "color": "#111111",
                  "align": "end"
                }
              ]
            },
            {
              "type": "box",
              "layout": "horizontal",
              "contents": [
                {
                  "type": "text",
                  "text": "PM10",
                  "size": "sm",
                  "color": "#555555",
                  "flex": 0
                },
                {
                  "type": "text",
                  "text": #{show pm10},
                  "size": "sm",
                  "color": "#111111",
                  "align": "end"
                }
              ]
            },
            {
              "type": "box",
              "layout": "horizontal",
              "contents": [
                {
                  "type": "text",
                  "text": "O3",
                  "size": "sm",
                  "color": "#555555",
                  "flex": 0
                },
                {
                  "type": "text",
                  "text": #{show o3},
                  "size": "sm",
                  "color": "#111111",
                  "align": "end"
                }
              ]
            },
            {
              "type": "box",
              "layout": "horizontal",
              "contents": [
                {
                  "type": "text",
                  "text": "CO",
                  "size": "sm",
                  "color": "#555555",
                  "flex": 0
                },
                {
                  "type": "text",
                  "text": #{show co},
                  "size": "sm",
                  "color": "#111111",
                  "align": "end"
                }
              ]
            },
            {
              "type": "box",
              "layout": "horizontal",
              "contents": [
                {
                  "type": "text",
                  "text": "SO2",
                  "size": "sm",
                  "color": "#555555",
                  "flex": 0
                },
                {
                  "type": "text",
                  "text": #{show so2},
                  "size": "sm",
                  "color": "#111111",
                  "align": "end"
                }
              ]
            }
          ]
        }
      ]
    },
    "footer": {
      "type": "box",
      "layout": "horizontal",
      "contents": [
        {
          "type": "button",
          "action": {
            "type": "uri",
            "label": "More info",
            "uri": "https://www.epa.gov.tw/"
          }
        }
      ]
    }
  }
|] ``` {{< /details >}}

{{< figure src="/images/alert.jpg" class="center" alt="centering" width="30%">}}

## Putting it all together

We are almost done! The only remaining part is to run our server and main loop:

  * We read from the environment the channel token and secret
  * create an initial `Env`.
  * thread the inital environment to our `app` and `loop`.
  * call `Network.Wai.Handler.Warp.run` to run the webhook in port `3000`

```haskell
main :: IO ()
main = do
  token  <- fromString <$> getEnv "CHANNEL_TOKEN"
  secret <- fromString <$> getEnv "CHANNEL_SECRET"
  env    <- atomically $ Env token secret <$> newTVar []
  runReaderT loop env
  run 3000 $ runReader app env
````

Here you can see we are actually instantiating `loop` and `app` to concrete
monads.

## Wanna be friends?

If you live in Taiwan, you can follow this bot server and see how it
works:

{{< figure src="/images/qr-code.png" class="center" alt="centering" width="30%">}}

It's the same bot as we have detailed in the tutorial with the exception that it
uses PostGIS instead of the in-memory solution we proposed earlier. You can find
the repository for the code here: https://github.com/moleike/taiwan-aqi-bot

## Conclusion

In this tutorial we have covered the development of a simple but practical
chatbot. I hope you enjoyed reading (and perhaps coding along) and maybe help
you getting started with your own chatbot ideas!

_Updates: reworded almost all sections, added additional links._

[101]: https://en.wikipedia.org/wiki/Taipei_101
[overview]: https://developers.line.biz/en/docs/messaging-api/overview/
[aqi]: https://en.wikipedia.org/wiki/Air_quality_index
[source]: https://gist.github.com/moleike/eb28b363ba7fb9478c9045036460fdd7
[line-bot-sdk]: http://hackage.haskell.org/package/line-bot-sdk
[servant]: https://github.com/haskell-servant/servant
[epa]: https://opendata.epa.gov.tw/home/
[stm]: http://hackage.haskell.org/package/stm
[mtl]: http://hackage.haskell.org/package/mtl
[harvesine]: https://en.wikipedia.org/wiki/Haversine_formula
[join-event]: https://developers.line.biz/en/reference/messaging-api/#join-event
[location-message]: https://developers.line.biz/en/reference/messaging-api/#wh-location
[flex-messages]: https://developers.line.biz/en/docs/messaging-api/using-flex-messages/
[wai]: http://hackage.haskell.org/package/wai
[servant-tutorial]: https://haskell-servant.readthedocs.io/en/stable/tutorial/index.html
[servant-server]: http://hackage.haskell.org/package/servant-server-0.16/docs/Servant-Server.html
