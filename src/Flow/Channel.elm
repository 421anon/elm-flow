module Flow.Channel exposing
    ( ChannelSpec, Channel, ChannelKey
    , connect, join, filter
    , open, next
    )

{-| Channel primitives for connecting external event sources to `Flow`.

Describe an event source with a `ChannelSpec`: use `connect` when you have both
a subscription source and a command to kick it off, or `join` when
subscriptions alone are enough. Then consume events with `Flow.await`,
`Flow.subscribe`, or `Flow.subscribeWhile`, each of which opens a live
`Channel` from the spec.

@docs ChannelSpec, Channel, ChannelKey
@docs connect, join, filter
@docs open, next

-}

import Flow.Internal exposing (ChannelRequest(..), Flow(..))


{-| A description of how to connect an external event source to a `Flow`
pipeline. A spec does nothing by itself and can be opened any number of times,
including concurrently; each opening is a separate `Channel`.
-}
type ChannelSpec s a
    = ChannelSpec
        { cmdPort : ChannelKey -> Cmd Never
        , subPort : ChannelKey -> (a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))
        }


{-| One live opening of a `ChannelSpec`. Receive further values from it with
`next`.
-}
type Channel s a
    = Channel ChannelKey (ChannelSpec s a)


{-| Key identifying a `Channel`.

Opening a spec creates a fresh key and passes it to the spec's command. The
channel keeps that key for its whole lifetime, so the external source can tag
its values with it and `filter` can match them.

-}
type alias ChannelKey =
    String


{-| Build a spec from a subscription source and a command that opens or
attaches it. The command fires each time the spec is opened, receiving the key
of the new channel; `next` does not fire it again.

    -- Port declarations:
    --   port onMessage : (String -> msg) -> Sub msg
    --   port subscribe : String -> Cmd msg
    myChannel : ChannelSpec Model String
    myChannel =
        Flow.Channel.connect
            (\callback -> Ports.onMessage callback)
            (\_ -> Ports.subscribe "myTopic")

-}
connect : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> (ChannelKey -> Cmd Never) -> ChannelSpec s a
connect subPort cmdPort =
    ChannelSpec
        { cmdPort = cmdPort
        , subPort = \_ -> subPort
        }


{-| Build a spec from a subscription source when no startup command is needed.

    -- Port declaration:
    --   port onKeyDown : (String -> msg) -> Sub msg
    keyChannel : ChannelSpec Model String
    keyChannel =
        Flow.Channel.join (\callback -> Ports.onKeyDown callback)

-}
join : ((a -> Maybe (Flow s a)) -> Sub (Maybe (Flow s a))) -> ChannelSpec s a
join subPort =
    ChannelSpec
        { cmdPort = \_ -> Cmd.none
        , subPort = \_ -> subPort
        }


{-| Filter events for a spec. Only events for which the predicate returns
`True` are forwarded; others are silently dropped.

The predicate receives the `ChannelKey` of the channel and the event payload.
Match on the key when the source tags values with it; otherwise you only need
the payload:

    Flow.Channel.filter (\_ msg -> msg /= "") myChannel

-}
filter : (ChannelKey -> a -> Bool) -> ChannelSpec s a -> ChannelSpec s a
filter predicate (ChannelSpec spec) =
    ChannelSpec
        { spec
            | subPort =
                \key callback ->
                    spec.subPort key
                        (\a ->
                            if predicate key a then
                                callback a

                            else
                                Nothing
                        )
        }


{-| Open a channel from a spec, firing the spec's command, and suspend until the
first value arrives. The callback receives the opened `Channel` and each value:
`Just flow` resumes with `flow`, `Nothing` ignores the value and keeps waiting.

This is the low-level primitive that `Flow.await` and `Flow.subscribe` are
built on. Prefer those unless you need custom continuation logic.

-}
open : ChannelSpec s a -> (Channel s a -> a -> Maybe (Flow s a)) -> Flow s a
open ((ChannelSpec spec) as channelSpec) callback =
    Await
        (Open spec.cmdPort)
        (\key -> spec.subPort key (callback (Channel key channelSpec)))


{-| Wait for the next value on an already opened channel, without firing the
spec's command again.
-}
next : Channel s a -> (a -> Maybe (Flow s a)) -> Flow s a
next (Channel key (ChannelSpec spec)) callback =
    Await
        (Resume key)
        (\resumed -> spec.subPort resumed callback)
