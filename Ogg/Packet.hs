--
-- Module      : Packet
-- Copyright   : (c) Conrad Parker 2006
-- License     : BSD-style
-- Maintainer  : conradp@cse.unsw.edu.au
-- Stability   : experimental
-- Portability : portable

module Ogg.Packet (
  OggPacket (..),
  packetsToPages,
  pagesToPackets,
  packetIsType
) where

import Ogg.Dump
import Ogg.Granulepos
import Ogg.Page
import Ogg.Track

import Data.List as List
import Data.Map as Map
import Data.Word (Word8, Word32)

------------------------------------------------------------
-- Data
--

data OggPacket =
  OggPacket {
    packetData :: [Word8],
    packetTrack :: OggTrack,
    packetGranulepos :: Granulepos,
    packetBOS :: Bool,
    packetEOS :: Bool,
    packetSegments :: Maybe [OggSegment]
  }

data OggSegment =
  OggSegment {
    segmentLength :: Int,
    segmentEndsPage :: Bool -- ^ whether or not the segment ends a page
  }

------------------------------------------------------------
-- Predicates
--

packetIsType :: OggType -> OggPacket -> Bool
packetIsType t p = trackIsType t (packetTrack p)

------------------------------------------------------------
-- packetsToPages
--

-- A map from serialno to seqno
type SeqnoMap = Map.Map OggTrack Word32

packetsToPages :: [OggPacket] -> [OggPage]
packetsToPages = packetsToPages_ Nothing Map.empty

packetsToPages_ :: Maybe OggPage -> SeqnoMap -> [OggPacket] -> [OggPage]

packetsToPages_ Nothing _ [] = []
packetsToPages_ (Just g) _ [] = [g]

packetsToPages_ carry sqMap (p:ps)
  = newPages ++ packetsToPages_ newCarry newSqMap ps
  where
    (newPages, newCarry) = segsToPages [] carry False seqno p
    n = fromIntegral (length newPages)
    track = packetTrack p
    seqno = Map.findWithDefault 0 track sqMap
    newSqMap = Map.insert track (seqno+n) sqMap

-- | Convert segments of a packet into pages, and maybe a carry page
segsToPages :: [OggPage] -> Maybe OggPage -> Bool -> Word32 -> OggPacket
               -> ([OggPage], Maybe OggPage)

segsToPages pages _ _ _ (OggPacket _ _ _ _ _ Nothing) = (pages, Nothing)
segsToPages pages _ _ _ (OggPacket _ _ _ _ _ (Just [])) = (pages, Nothing)

segsToPages pages carry cont seqno p@(OggPacket _ _ _ _ _ (Just [s]))
  | segmentEndsPage s = (pages++[newPage], Nothing)
  | otherwise         = (pages, Just newPage)
  where
    newPage = appendToCarry carry cont seqno p

segsToPages pages carry cont seqno
            p@(OggPacket d track gp _ eos (Just (s:ss)))
  = segsToPages (pages++[newPage]) Nothing True (seqno+1) dropPacket
  where
    dropPacket = OggPacket rest track gp False eos (Just ss)
    rest = drop (segmentLength s) d
    newPage = appendToCarry carry cont seqno p

-- | Append the first segment of a packet to the carry page
appendToCarry :: Maybe OggPage -> Bool -> Word32 -> OggPacket -> OggPage

-- Case of no carry page, packet has only one segment
appendToCarry Nothing cont seqno (OggPacket d track gp bos eos (Just [_]))
  = OggPage 0 track cont True bos eos gp seqno [d]

-- Case of no carry page, packet has >1 segment
appendToCarry Nothing cont seqno (OggPacket d track _ bos _ (Just (s:_)))
  = OggPage 0 track cont False bos False (Granulepos Nothing) seqno [seg]
  where seg = take (segmentLength s) d

-- Case of a carry page, packet has only one segment
appendToCarry (Just (OggPage o track cont _ bos _ _ seqno segs)) _ _
              (OggPacket d _ gp _ eos (Just [_]))
  = OggPage o track cont True bos eos gp seqno (segs++[d])

-- Case of a carry page, packet has >1 segment
appendToCarry (Just (OggPage o track cont _ bos _ gp seqno segs)) _ _
              (OggPacket d _ _ _ eos (Just (s:_)))
  = OggPage o track cont False bos eos gp seqno (segs++[seg])
  where seg = take (segmentLength s) d
        
-- For completeness
appendToCarry _ _ _ _ = error "appendToCarry{Ogg.Packet}: nothing to append"

------------------------------------------------------------
-- pagesToPackets
--

pagesToPackets :: [OggPage] -> [OggPacket]
pagesToPackets = _pagesToPackets []

_pagesToPackets :: [OggPacket] -> [OggPage] -> [OggPacket]
_pagesToPackets [] [] = []
_pagesToPackets [cps] [] = [cps]

_pagesToPackets carry [g] = s
    where s = prependCarry carry (pageToPackets g)

_pagesToPackets carry (g:gs) =
    if (incplt && length ps == 1) then
        _pagesToPackets (carryCarry carry newcarry) gs
    else
        s ++ _pagesToPackets newcarry gs
    where s = prependCarry carry ns
          newcarry = updateCarry ++ thisCarry
          updateCarry = List.filter (\x -> packetTrack x /= (pageTrack g)) carry
          thisCarry = if incplt then [last ps] else []
          ns = if incplt then init ps else ps
          ps = pageToPackets g
          incplt = pageIncomplete g

-- | Construct (partial) packets from the segments of a page
pageToPackets :: OggPage -> [OggPacket]
pageToPackets page = setLastSegmentEnds p3
    where p3 = setGranulepos p2 (pageGranulepos page) (pageIncomplete page)
          p2 = setEOS p1 (pageEOS page)
          p1 = setBOS p0 (pageBOS page)
          p0 = List.map (packetBuild (pageTrack page)) (pageSegments page)

setLastSegmentEnds :: [OggPacket] -> [OggPacket]
setLastSegmentEnds [] = []
setLastSegmentEnds ps = (init ps) ++ [setSegmentEnds (last ps)]

setSegmentEnds :: OggPacket -> OggPacket
setSegmentEnds p@(OggPacket _ _ _ _ _ (Just [s])) =
  p{packetSegments = (Just [s{segmentEndsPage = True}])}
setSegmentEnds p = p

setGranulepos :: [OggPacket] -> Granulepos -> Bool -> [OggPacket]
setGranulepos [] _ _ = []
setGranulepos [p] gp False = [p{packetGranulepos = gp}]
setGranulepos [p] _ True = [p] -- singleton segment, continued
setGranulepos [p,pl] gp True = [p{packetGranulepos = gp}]++[pl]
setGranulepos (p:ps) gp co = [p] ++ setGranulepos ps gp co

setBOS :: [OggPacket] -> Bool -> [OggPacket]
setBOS [] _ = []
setBOS ps False = ps
setBOS (p:ps) True = p{packetBOS = True}:ps

setEOS :: [OggPacket] -> Bool -> [OggPacket]
setEOS [] _ = []
setEOS ps False = ps
setEOS ps True = (init ps)++[(last ps){packetEOS = True}]

-- | Build a partial packet given a track and a segment
packetBuild :: OggTrack -> [Word8] -> OggPacket
packetBuild track r = OggPacket r track (Granulepos Nothing) False False (Just [seg])
    where seg = OggSegment l False
          l = length r

-- | Concatenate data of two (partial) packets into one (partial) packet
packetConcat :: OggPacket -> OggPacket -> OggPacket
packetConcat (OggPacket r1 s1 _ b1 _ (Just x1)) (OggPacket r2 _ g2 _ e2 (Just x2)) =
    OggPacket (r1++r2) s1 g2 b1 e2 (Just (x1++x2))

-- If either of the packets have unknown segmentation, ditch all segmentation
packetConcat (OggPacket r1 s1 _ b1 _ _) (OggPacket r2 _ g2 _ e2 _) =
    OggPacket (r1++r2) s1 g2 b1 e2 Nothing

carryCarry :: [OggPacket] -> [OggPacket] -> [OggPacket]
carryCarry [] [] = []
carryCarry [] [p] = [p]
carryCarry oldCarry [] = oldCarry
carryCarry (c:cs) [p]
  | packetTrack c == packetTrack p = (packetConcat c p):cs
  | otherwise                      = c:(carryCarry cs [p])

prependCarry :: [OggPacket] -> [OggPacket] -> [OggPacket]
prependCarry [] s = s
prependCarry oldCarry [] = oldCarry
prependCarry (c:cs) (s:ss)
  | packetTrack c == packetTrack s = (packetConcat c s):ss
  | otherwise                      = prependCarry cs (s:ss)

------------------------------------------------------------
-- Show
--

instance Show OggPacket where
  show (OggPacket d track gp bos eos _) =
    ": serialno " ++ show (trackSerialno track) ++ ", granulepos " ++ show gp ++ flags ++ ": " ++ show (length d) ++ " bytes\n" ++ hexDump d
    where flags = ifb ++ ife
          ifb = if bos then " *** bos" else ""
          ife = if eos then " *** eos" else ""
