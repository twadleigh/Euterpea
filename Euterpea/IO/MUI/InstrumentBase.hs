{-# LANGUAGE Arrows #-}
module Euterpea.IO.MUI.InstrumentBase where
import qualified Codec.Midi as Midi
import Data.Maybe
import Control.Arrow
import Control.Monad
import Control.SF.AuxFunctions
import Euterpea.IO.MUI.SOE
import Euterpea.IO.MUI.UIMonad
import Euterpea.IO.MUI.UISF
import Euterpea.IO.MUI.Widget
import Euterpea.IO.MIDI
import Euterpea.Music.Note.Music hiding (transpose)
import Euterpea.Music.Note.Performance

type EMM  = SEvent [MidiMessage]

data KeyData = KeyData {
    pressed  :: Maybe Bool,
    notation :: Maybe String,
    offset   :: Int
} deriving (Show, Eq)

data KeyState = KeyState {
    keypad:: Bool,
    mouse :: Bool,
    song :: Bool,
    vel  :: Midi.Velocity
} deriving (Show, Eq)

data InstrumentData = InstrumentData {
    showNotation::Bool,
    keyPairs :: Maybe [(AbsPitch, Bool)],
    transpose :: AbsPitch,
    pedal :: Bool
} deriving (Show, Eq)

isKeyDown :: KeyState -> Bool
isKeyDown (KeyState False False False _) = False
isKeyDown _ = True

isKeyPlay :: KeyState -> Bool
isKeyPlay (KeyState False False _ _) = False
isKeyPlay _ = True

defaultInstrumentData :: InstrumentData
defaultInstrumentData = InstrumentData False Nothing 0 False

-----------------------------
-- INSTRUMENT DATA WIDGETS --
-----------------------------

-- Notation Widget
addNotation :: UISF InstrumentData InstrumentData
addNotation = proc inst -> do
    notA <- checkbox "Notation" False -< ()
    returnA -< inst { showNotation = notA }

-- Transpose Widget
addTranspose :: UISF InstrumentData InstrumentData
addTranspose = proc inst -> do
    tp <- withDisplay $ hiSlider 1 (-6,6) 0 -< ()
    returnA -< inst { transpose = tp }

-- Pedal Widget
addPedal :: UISF InstrumentData InstrumentData
addPedal = proc inst -> do
    ped <- checkbox "Pedal" False -< ()
    returnA -< inst { pedal = ped }

-----------------------------
--       ECHO WIDGET       --
-----------------------------

addEcho :: UISF EMM EMM
addEcho = title "Echo" $ leftRight $ proc m -> do
    r <- title "Decay Rate" $ withDisplay (hSlider (0,0.9) 0.5) -< ()
    f <- title "Echoing Frequency" $ withDisplay (hSlider (1,10) 10) -< ()
    rec let m' = removeNull $ m ~++ s
        s <- vdelay -< (1.0/f, fmap (mapMaybe (decay 0.1 r)) m')
    returnA -< m'

removeNull :: Maybe [MidiMessage] -> Maybe [MidiMessage]
removeNull Nothing = Nothing
removeNull (Just []) = Nothing
removeNull mm = mm

decay :: Time -> Double -> MidiMessage -> Maybe MidiMessage
decay dur r m =
    let f c k v d = if v > 0 
                    then Just (ANote c k (truncate (fromIntegral v * r)) d)
                    else Nothing
     in case m of
        ANote c k v d -> f c k v d
        Std (Midi.NoteOn c k v) -> f c k v dur
        _ -> Nothing

-----------------------------
--    INSTRUMENT SELECT    --
-----------------------------

selectInstrument :: Midi.Channel -> Int -> UISF EMM EMM
selectInstrument chn i = title "Instrument" $ proc msg -> do
    instrNum <- hiSlider 1 (0,127) i -< ()
    display -< (toEnum :: Int -> InstrumentName) instrNum
    instrNum' <- unique -< instrNum
    returnA -< fmap (\x -> [Std $ Midi.ProgramChange chn x]) instrNum' ~++ msg

-----------------------------
--     SONG SELECTION      --
-----------------------------

songPlayer :: [(String, Music Pitch)] -> UISF () EMM
songPlayer songList = proc _ -> do
    i <- pickSong songList -< ()
    let song = fmap (\x -> snd $ songList !! x) i
    let msgs = fmap (musicToMsgs False [] . toMusic1) song
    (out, _) <- eventBuffer -< (fmap AddData msgs, True, 1)
    returnA -< out

pickSong :: [(String, Music Pitch)] -> UISF () (SEvent Int)
pickSong [] = title "No Songs Imported" $ proc _ -> returnA -< Nothing
pickSong songList = title "Available Songs" $ leftRight $ proc _ -> do
    i <- topDown $ radio (fst $ unzip songList) 0 -< ()
    playBtn <- edge <<< button "Play" -< ()
    returnA -< fmap (const i) playBtn

-----------------------------
--     OTHER HELPERS       --
-----------------------------

mmToPair :: [MidiMessage] -> [(AbsPitch, Bool)]
mmToPair [] = []
mmToPair (Std (Midi.NoteOn _ k _) : rest) = (k, True)  : mmToPair rest
mmToPair (Std (Midi.NoteOff _ k _) : rest)= (k, False) : mmToPair rest
mmToPair (ANote {} :_) = error "ANote not implemented"
mmToPair (_:rest) = mmToPair rest

pairToMsg :: Midi.Channel -> [(AbsPitch, Bool, Midi.Velocity)] -> [MidiMessage]
pairToMsg ch = map f where
    f (ap, b, vel) | b     = Std (Midi.NoteOn  ch ap vel)
                   | not b = Std (Midi.NoteOff ch ap 0)

getKeyData :: AbsPitch -> InstrumentData -> KeyData
getKeyData ap (InstrumentData isShow pairs trans _) =
    KeyData (if isNothing pairs then Nothing
             else Control.Monad.mplus (lookup ap (fromJust pairs)) Nothing)
            (if isShow then Just (show $ fst $ pitch ap) else Nothing)
            (ap + trans)

detectChannel :: [MidiMessage] -> Maybe Midi.Channel
detectChannel []                            = Nothing
detectChannel (ANote c _ _ _:_)             = Just c
detectChannel (Std (NoteOn c _ _):_)        = Just c
detectChannel (Std (NoteOff c _ _):_)       = Just c
detectChannel (Std (KeyPressure c _ _):_)   = Just c
detectChannel (Std (ControlChange c _ _):_) = Just c
detectChannel (Std (ProgramChange c _):_)   = Just c
detectChannel (Std (ChannelPressure c _):_) = Just c
detectChannel (Std (PitchWheel c _):_)      = Just c
detectChannel (_:as)                        = detectChannel as

setChannel :: Int -> [MidiMessage] -> [MidiMessage]
setChannel c (ANote _ k v d:as) = ANote c k v d : setChannel c as
setChannel c (Std (NoteOn _ k v):as) = Std (NoteOn c k v) : setChannel c as
setChannel c (Std (NoteOff _ k v):as) = Std (NoteOff c k v) : setChannel c as
setChannel c (Std (KeyPressure _ k p):as) = Std (KeyPressure c k p) : setChannel c as
setChannel c (Std (ControlChange _ cn cv):as) = Std (ControlChange c cn cv) : setChannel c as
setChannel c (Std (ProgramChange _ p):as) = Std (ProgramChange c p) : setChannel c as
setChannel c (Std (ChannelPressure _ p):as) = Std (ChannelPressure c p) : setChannel c as
setChannel c (Std (PitchWheel _ p):as) = Std (PitchWheel c p) : setChannel c as
setChannel _ x = x