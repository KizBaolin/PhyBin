{-# LANGUAGE ScopedTypeVariables, CPP, BangPatterns #-}

module Bio.Phylogeny.PhyBin.RFDistance
       (
         -- * Types
         DenseLabelSet, DistanceMatrix,

         -- * Bipartition (Bip) utilities
         allBips, foldBips, dispBip,
         consensusTree, bipsToTree, filterCompatible, compatibleWith,

         -- * ADT for dense sets
         mkSingleDense, mkEmptyDense, bipSize,
         denseUnions, denseDiff, invertDense, markLabel,

        -- * Methods for computing distance matrices
        naiveDistMatrix, hashRF,

        -- * Output
        printDistMat)
       where

import           Control.Monad
import           Control.Monad.ST
import           Control.Monad.ST.Unsafe (unsafeIOToST)
import           Data.Function       (on)
import           Data.Word
import qualified Data.Vector                 as V
import qualified Data.Vector.Mutable         as MV
import qualified Data.Vector.Unboxed.Mutable as MU
import qualified Data.Vector.Unboxed         as U
import           Text.PrettyPrint.HughesPJClass hiding (char, Style)
import           System.IO      (hPutStrLn, hPutStr, Handle)
import           System.IO.Unsafe

-- import           Control.LVish
-- import qualified Data.LVar.Set   as IS
-- import qualified Data.LVar.SLSet as SL

-- import           Data.LVar.Map   as IM
-- import           Data.LVar.NatArray as NA

import           Bio.Phylogeny.PhyBin.CoreTypes
import           Bio.Phylogeny.PhyBin.PreProcessor (pruneTreeLeaves)
-- import           Data.BitList
import qualified Data.Set as S
import qualified Data.List as L
import qualified Data.IntSet as SI
import qualified Data.Map.Strict as M
import qualified Data.Foldable as F
import qualified Data.Traversable as T
import           Data.Monoid
import           Prelude as P
import           Debug.Trace

#ifdef BITVEC_BIPS
import qualified Data.Vector.Unboxed.Bit     as UB
import qualified Data.Bit                    as B
#endif

-- I don't understand WHY, but I seem to get the same answers WITHOUT this.
-- Normalization and symmetric difference do make things somewhat slower (e.g. 1.8
-- seconds vs. 2.2 seconds for 150 taxa / 100 trees)
#define NORMALIZATION
-- define BITVEC_BIPS

--------------------------------------------------------------------------------
-- A data structure choice
--------------------------------------------------------------------------------

-- type DenseLabelSet s = BitList


-- | Dense sets of taxa, aka Bipartitions or BiPs
--   We assume that taxa labels have been mapped onto a dense, contiguous range of integers [0,N).
--
--   NORMALIZATION Rule: Bipartitions are really two disjoint sets.  But as long as
--   the parent set (the union of the partitions, aka "all taxa") then a bipartition
--   can be represented just by *one* subset.  Yet we must choose WHICH subset for
--   consistency.  We use the rule that we always choose the SMALLER.  Thus the
--   DenseLabelSet should always be half the size or less, compared to the total
--   number of taxa.
--
--   A set that is more than a majority of the taxa can be normalized by "flipping",
--   i.e. taking the taxa that are NOT in that set.
#ifdef BITVEC_BIPS

#  if 1
type DenseLabelSet = UB.Vector B.Bit
markLabel lab = UB.modify (\vec -> MU.write vec lab (B.fromBool True))
mkEmptyDense  size = UB.replicate size (B.fromBool False)
mkSingleDense size ind = markLabel ind (mkEmptyDense size)
denseUnions        = UB.unions
bipSize            = UB.countBits
denseDiff          = UB.difference
invertDense size bip = UB.invert bip
dispBip labs bip = show$ map (\(ix,_) -> (labs M.! ix)) $
                        filter (\(_,bit) -> B.toBool bit) $
                        zip [0..] (UB.toList bip)
denseIsSubset a b = UB.or (UB.difference b a)
traverseDense_ fn bip =
  U.ifoldr' (\ ix bit acc ->
              (if B.toBool bit
               then fn ix
               else return ()) >> acc)
        (return ()) bip

#  else
-- TODO: try tracking the size:
data DenseLabelSet = DLS {-# UNPACK #-} !Int (UB.Vector B.Bit)
markLabel lab (DLS _ vec)= DLS (UB.modify (\vec -> return (MU.write vec lab (B.fromBool True))) ) vec
-- ....
#  endif

#else
type DenseLabelSet = SI.IntSet
markLabel lab set   = SI.insert lab set
mkEmptyDense _size  = SI.empty
mkSingleDense _size = SI.singleton
denseUnions _size   = SI.unions
bipSize             = SI.size
denseDiff           = SI.difference
denseIsSubset       = SI.isSubsetOf

dispBip labs bip = "[" ++ unwords strs ++ "]"
  where strs = map (labs M.!) $ SI.toList bip
invertDense size bip = loop SI.empty (size-1)
  where -- There's nothing for it but to iterate and test for membership:
    loop !acc ix | ix < 0           = acc
                 | SI.member ix bip = loop acc (ix-1)
                 | otherwise        = loop (SI.insert ix acc) (ix-1)
traverseDense_ fn bip =
  -- FIXME: need guaranteed non-allocating way to do this.
  SI.foldr' (\ix acc ->  fn ix >> acc) (return ()) bip
#endif

markLabel    :: Label -> DenseLabelSet -> DenseLabelSet
mkEmptyDense :: Int -> DenseLabelSet
mkSingleDense :: Int -> Label -> DenseLabelSet
denseUnions  :: Int -> [DenseLabelSet] -> DenseLabelSet
bipSize      :: DenseLabelSet -> Int

-- | Print a BiPartition in a pretty form
dispBip      :: LabelTable -> DenseLabelSet -> String

-- | Assume that total taxa are 0..N-1, invert membership:
invertDense  :: Int -> DenseLabelSet -> DenseLabelSet

traverseDense_ :: Monad m => (Int -> m ()) -> DenseLabelSet -> m ()


--------------------------------------------------------------------------------
-- Dirt-simple reference implementation
--------------------------------------------------------------------------------

type DistanceMatrix = V.Vector (U.Vector Int)

-- | Returns a triangular distance matrix encoded as a vector.
--   Also return the set-of-BIPs representation for each tree.
--
--   This uses a naive method, directly computing the pairwise
--   distance between each pair of trees.
--
--   This method is TOLERANT of differences in the laba/taxa sets between two trees.
--   It simply prunes to the intersection before doing the distance comparison.
--   Other scoring methods may be added in the future.  (For example, penalizing for
--   missing taxa.)
naiveDistMatrix :: [NewickTree DefDecor] -> (DistanceMatrix, V.Vector (S.Set DenseLabelSet))
naiveDistMatrix lst =
   let sz = P.length lst
       treeVect  = V.fromList lst
       labelSets = V.map treeLabels treeVect
       eachbips  = V.map allBips    treeVect
       mat = V.generate sz $ \ i ->
             U.generate i  $ \ j ->
             let
                 inI = (labelSets V.! i)
                 inJ = (labelSets V.! j)
                 inBoth = S.intersection inI inJ

                 -- Match will always succeed due to size==0 test below:
                 Just prI = pruneTreeLeaves inBoth (treeVect V.! i)
                 Just prJ = pruneTreeLeaves inBoth (treeVect V.! j)

                 -- Memoization: If we are using it at its full size we can use the cached one:
                 bipsI = if S.size inBoth == S.size inI
                         then (eachbips V.! i)
                         else allBips prI
                 bipsJ = if S.size inBoth == S.size inJ
                         then (eachbips V.! j)
                         else allBips prJ

                 diff1 = S.size (S.difference bipsI bipsJ)
                 diff2 = S.size (S.difference bipsJ bipsI) -- symettric difference
             in if S.size inBoth == 0
                then 0 -- This is weird, but what other answer could we give?
                else diff1 + diff2
   in (mat, eachbips)

 where
   treeLabels :: NewickTree a -> S.Set Label
   treeLabels (NTLeaf _ lab)  = S.singleton lab
   treeLabels (NTInterior _ ls) = S.unions (map treeLabels ls)

-- | The number of bipartitions implied by a tree is one per EDGE in the tree.  Thus
-- each interior node carries a list of BiPs the same length as its list of children.
labelBips :: NewickTree a -> NewickTree (a, [DenseLabelSet])
labelBips tr =
--    trace ("labelbips "++show allLeaves++" "++show size) $
#ifdef NORMALIZATION
    fmap (\(a,ls) -> (a,map (normBip size) ls)) $
#endif
    loop tr
  where
    size = numLeaves tr
    zero = mkEmptyDense size
    loop (NTLeaf dec lab) = NTLeaf (dec, [markLabel lab zero]) lab
    loop (NTInterior dec chlds) =
      let chlds' = map loop chlds
          sets   = map (denseUnions size . snd . get_dec) chlds' in
      NTInterior (dec, sets) chlds'

    allLeaves = leafSet tr
    leafSet (NTLeaf _ lab)    = mkSingleDense size lab
    leafSet (NTInterior _ ls) = denseUnions size $ map leafSet ls

-- normBip :: DenseLabelSet -> DenseLabelSet -> DenseLabelSet
--    normBip allLeaves bip =
normBip :: Int -> DenseLabelSet -> DenseLabelSet
normBip totsize bip =
  let -- size     = bipSize allLeaves
      halfSize = totsize `quot` 2
--      flipped  = denseDiff allLeaves bip
      flipped  = invertDense totsize bip
  in
  case compare (bipSize bip) halfSize of
    LT -> bip
    GT -> flipped -- Flip it
    EQ -> min bip flipped -- This is a painful case, we need a tie-breaker


foldBips :: Monoid m => (DenseLabelSet -> m) -> NewickTree a -> m
foldBips f tr = F.foldMap f' (labelBips tr)
 where f' (_,bips) = F.foldMap f bips

-- | Get all non-singleton BiPs implied by a tree.
allBips :: NewickTree a -> S.Set DenseLabelSet
allBips tr = S.filter ((> 1) . bipSize) $ foldBips S.insert tr S.empty

--------------------------------------------------------------------------------
-- Optimized, LVish version
--------------------------------------------------------------------------------
-- First, necessary types:

-- UNFINISHED:
#if 0
-- | A collection of all observed bipartitons (bips) with a mapping of which trees
-- contain which Bips.
type BipTable s = IMap DenseLabelSet s (SparseTreeSet s)
-- type BipTable = IMap BitList (U.Vector Bool)
-- type BipTable s = IMap BitList s (NA.NatArray s Word8)

-- | Sets of taxa (BiPs) that are expected to be sparse.
type SparseTreeSet s = IS.ISet s TreeID
-- TODO: make this a set of numeric tree IDs...
-- NA.NatArray s Word8

type TreeID = AnnotatedTree
-- | Tree's are identified simply by their order within the list of input trees.
-- type TreeID = Int
#endif

--------------------------------------------------------------------------------
-- Alternate way of slicing the problem: HashRF
--------------------------------------------------------------------------------

-- The distance matrix is an atomically-bumped matrix of numbers.
-- type DistanceMat s = NA.NatArray s Word32
-- Except... bump isn't supported by our idempotent impl.

-- | This version slices the problem a different way.  A single pass over the trees
-- populates the table of bipartitions.  Then the table can be processed (locally) to
-- produce (non-localized) increments to a distance matrix.
hashRF :: Int -> [NewickTree a] -> DistanceMatrix
hashRF num_taxa trees = build M.empty (zip [0..] trees)
  where
    num_trees = length trees
    -- First build the table:
    build acc [] = ingest acc
    build acc ((ix,hd):tl) =
      let bips = allBips hd
          acc' = S.foldl' fn acc bips
          fn acc bip = M.alter fn2 bip acc
          fn2 (Just membs) = Just (markLabel ix membs)
          fn2 Nothing      = Just (mkSingleDense num_taxa ix)
      in
      build acc' tl

    -- Second, ingest the table to construct the distance matrix:
    ingest :: M.Map DenseLabelSet DenseLabelSet -> DistanceMatrix
    ingest bipTable = runST theST
      where
       theST :: forall s0 . ST s0 DistanceMatrix
       theST = do
        -- Triangular matrix, starting narrow and widening:
        matr <- MV.new num_trees
        -- Too bad MV.replicateM is insufficient.  It should pass index.
        -- Instead we write this C-style:
        for_ (0,num_trees) $ \ ix -> do
          row <- MU.replicate ix (0::Int)
          MV.write matr ix row
          return ()

        unsafeIOToST$ putStrLn$" Built matrix for dim "++show num_trees

        let bumpMatr i j | j < i     = incr i j
                         | otherwise = incr j i
            incr :: Int -> Int -> ST s0 ()
            incr i j = do -- Not concurrency safe yet:
--                          unsafeIOToST$ putStrLn$" Reading at position "++show(i,j)
                          row <- MV.read matr i
                          elm <- MU.read row j
                          MU.write row j (elm+1)
                          return ()
            fn bipMembs =
              -- Here we quadratically consider all pairs of trees and ask whether
              -- their edit distance is increased based on this particular BiP.
              -- Actually, as an optimization, it is sufficient to consider only the
              -- cartesian product of those that have and those that don't.
              let haveIt   = bipMembs
                  -- Depending on how invertDense is written, it could be useful to
                  -- fuse this in and deforest "dontHave".
                  dontHave = invertDense num_trees bipMembs
                  fn1 trId = traverseDense_ (fn2 trId) dontHave
                  fn2 trId1 trId2 = bumpMatr trId1 trId2
              in
--                 trace ("Computed donthave "++ show dontHave) $
                 traverseDense_ fn1 haveIt
        F.traverse_ fn bipTable
        v1 <- V.unsafeFreeze matr
        T.traverse (U.unsafeFreeze) v1


--------------------------------------------------------------------------------
-- Miscellaneous Helpers
--------------------------------------------------------------------------------

instance Pretty a => Pretty (S.Set a) where
 pPrint s = pPrint (S.toList s)


printDistMat :: Handle -> V.Vector (U.Vector Int) -> IO ()
printDistMat h mat = do
  hPutStrLn h "Robinson-Foulds distance (matrix format):"
  hPutStrLn h "-----------------------------------------"
  V.forM_ mat $ \row -> do
    U.forM_ row $ \elem -> do
      hPutStr h (show elem)
      hPutStr h " "
    hPutStr h "0\n"
  hPutStrLn h "-----------------------------------------"

-- My own forM for numeric ranges (not requiring deforestation optimizations).
-- Inclusive start, exclusive end.
{-# INLINE for_ #-}
for_ :: Monad m => (Int, Int) -> (Int -> m ()) -> m ()
for_ (start, end) _fn | start > end = error "for_: start is greater than end"
for_ (start, end) fn = loop start
  where
   loop !i | i == end  = return ()
           | otherwise = do fn i; loop (i+1)

-- | Which of a set of trees are compatible with a consensus?
filterCompatible :: NewickTree a -> [NewickTree b] -> [NewickTree b]
filterCompatible consensus trees =
    let cbips = allBips consensus in
    [ tr | tr <- trees
         , cbips `S.isSubsetOf` allBips tr ]

-- | `compatibleWith consensus tree` -- Is a tree compatible with a consensus?
--   This is more efficient if partially applied then used repeatedly.
--
-- Note, tree compatibility is not the same as an exact match.  It's
-- like (<=) rather than (==).  The "star topology" is consistent with the
-- all trees, because it induces the empty set of bipartitions.
compatibleWith :: NewickTree a -> NewickTree b -> Bool
compatibleWith consensus =
  let consBips = allBips consensus in
  \ newTr -> S.isSubsetOf consBips (allBips newTr)

-- | Consensus between two trees, which may even have different label maps.
consensusTreeFull (FullTree n1 l1 t1) (FullTree n2 l2 t2) =
  error "FINISHME - consensusTreeFull"

-- | Take only the bipartitions that are agreed on by all trees.
consensusTree :: Int -> [NewickTree a] -> NewickTree ()
consensusTree _ [] = error "Cannot take the consensusTree of the empty list"
consensusTree num_taxa (hd:tl) = bipsToTree num_taxa intersection
  where
    intersection = L.foldl' S.intersection (allBips hd) (map allBips tl)
--     intersection = loop (allBips hd) tl
--     loop :: S.Set DenseLabelSet -> [NewickTree a] -> S.Set DenseLabelSet
--     loop !remain []      = remain
--     -- Was attempting to use foldBips here as an optimization:
-- --     loop !remain (hd:tl) = loop (foldBips S.delete hd remain) tl
--     loop !remain (hd:tl) = loop (S.difference remain (allBips hd)) tl

-- | Convert from bipartitions BACK to a single tree.
bipsToTree :: Int -> S.Set DenseLabelSet -> NewickTree ()
bipsToTree num_taxa origbip =
--  trace ("Doing bips in order: "++show sorted++"\n") $
  loop lvl0 sorted
  where
    -- We consider each subset in increasing size order.
    -- FIXME: If we tweak the order on BIPs, then we can just use S.toAscList here:
    sorted = L.sortBy (compare `on` bipSize) (S.toList origbip)

    lvl0 = [ (mkSingleDense num_taxa ix, NTLeaf () ix)
           | ix <- [0..num_taxa-1] ]

    -- VERY expensive!  However, due to normalization issues this is necessary for now:
    -- TODO: in the future make it possible to definitively denormalize.
    -- isMatch bip x = denseIsSubset x bip || denseIsSubset x (invertDense num_taxa bip)
    isMatch bip x = denseIsSubset x bip

    -- We recursively glom together subtrees until we have a complete tree.
    -- We only process larger subtrees after we have processed all the smaller ones.
    loop !subtrees [] =
      case subtrees of
        []    -> error "bipsToTree: internal error"
        [(_,one)] -> one
        lst   -> NTInterior () (map snd lst)
    loop !subtrees (bip:tl) =
--      trace (" -> looping, subtrees "++show subtrees) $
      let (in_,out) = L.partition (isMatch bip. fst) subtrees in
      case in_ of
        [] -> error $"bipsToTree: Internal error!  No match for bip: "++show bip
              ++" out is\n "++show out++"\n and remaining bips "++show (length tl)
              ++"\n when processing orig bip set:\n  "++show origbip
          -- loop out tl
        _ ->
         -- Here all subtrees that match the current bip get merged:
         loop ((denseUnions num_taxa (map fst in_),
                NTInterior ()        (map snd in_)) : out) tl
