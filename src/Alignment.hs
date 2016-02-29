module Alignment where

import Category
import Control.Comonad.Cofree
import Control.Monad.Free
import Data.Either
import Data.Functor.Identity
import qualified Data.OrderedMap as Map
import qualified Data.Set as Set
import Diff
import Line
import Patch
import Range
import Row
import Source hiding ((++))
import SplitDiff
import Syntax
import Term

-- | Split a diff, which may span multiple lines, into rows of split diffs.
splitDiffByLines :: Diff leaf Info -> (Int, Int) -> (Source Char, Source Char) -> ([Row (SplitDiff leaf Info)], (Range, Range))
splitDiffByLines diff (prevLeft, prevRight) sources = case diff of
  Free (Annotated annotation syntax) -> (splitAnnotatedByLines sources (ranges annotation) (categories annotation) syntax, ranges annotation)
  Pure (Insert term) -> let (lines, range) = splitTermByLines term (snd sources) in
    (Row EmptyLine . fmap (Pure . SplitInsert) <$> lines, (Range prevLeft prevLeft, range))
  Pure (Delete term) -> let (lines, range) = splitTermByLines term (fst sources) in
    (flip Row EmptyLine . fmap (Pure . SplitDelete) <$> lines, (range, Range prevRight prevRight))
  Pure (Replace leftTerm rightTerm) -> let (leftLines, leftRange) = splitTermByLines leftTerm (fst sources)
                                           (rightLines, rightRange) = splitTermByLines rightTerm (snd sources) in
                                           (zipWithDefaults Row EmptyLine EmptyLine (fmap (Pure . SplitReplace) <$> leftLines) (fmap (Pure . SplitReplace) <$> rightLines), (leftRange, rightRange))
  where categories (Info _ left, Info _ right) = (left, right)
        ranges (Info left _, Info right _) = (left, right)

-- | A functor that can return its content.
class Functor f => Has f where
  get :: f a -> a

instance Has Identity where
  get = runIdentity

instance Has ((,) a) where
  get = snd

-- | Takes a term and a source and returns a list of lines and their range within source.
splitTermByLines :: Term leaf Info -> Source Char -> ([Line (Term leaf Info)], Range)
splitTermByLines (Info range categories :< syntax) source = flip (,) range $ case syntax of
  Leaf a -> pure . (:< Leaf a) . (`Info` categories) <$> actualLineRanges range source
  Indexed children -> adjoinChildLines (Indexed . fmap get) (Identity <$> children)
  Fixed children -> adjoinChildLines (Fixed . fmap get) (Identity <$> children)
  Keyed children -> adjoinChildLines (Keyed . Map.fromList) (Map.toList children)
  where adjoin :: Has f => [Line (Either Range (f (Term leaf Info)))] -> [Line (Either Range (f (Term leaf Info)))]
        adjoin = reverse . foldl (adjoinLinesBy $ openEither (openRange source) (openTerm source)) []

        adjoinChildLines :: Has f => ([f (Term leaf Info)] -> Syntax leaf (Term leaf Info)) -> [f (Term leaf Info)] -> [Line (Term leaf Info)]
        adjoinChildLines constructor children = let (lines, previous) = foldl childLines ([], start range) children in
          fmap (wrapLineContents $ wrap constructor) . adjoin $ lines ++ (pure . Left <$> actualLineRanges (Range previous $ end range) source)

        wrap :: Has f => ([f (Term leaf Info)] -> Syntax leaf (Term leaf Info)) -> [Either Range (f (Term leaf Info))] -> Term leaf Info
        wrap constructor children = (Info (unionRanges $ getRange <$> children) categories :<) . constructor $ rights children

        getRange :: Has f => Either Range (f (Term leaf Info)) -> Range
        getRange (Right term) = case get term of (Info range _ :< _) -> range
        getRange (Left range) = range

        childLines :: Has f => ([Line (Either Range (f (Term leaf Info)))], Int) -> f (Term leaf Info) -> ([Line (Either Range (f (Term leaf Info)))], Int)
        childLines (lines, previous) child = let (childLines, childRange) = splitTermByLines (get child) source in
          (adjoin $ lines ++ (pure . Left <$> actualLineRanges (Range previous $ start childRange) source) ++ (fmap (Right . (<$ child)) <$> childLines), end childRange)

-- | Split a annotated diff into rows of split diffs.
splitAnnotatedByLines :: (Source Char, Source Char) -> (Range, Range) -> (Set.Set Category, Set.Set Category) -> Syntax leaf (Diff leaf Info) -> [Row (SplitDiff leaf Info)]
splitAnnotatedByLines sources ranges categories syntax = case syntax of
  Leaf a -> wrapRowContents (Free . (`Annotated` Leaf a) . (`Info` fst categories) . unionRanges) (Free . (`Annotated` Leaf a) . (`Info` snd categories) . unionRanges) <$> contextRows ranges sources
  Indexed children -> adjoinChildRows (Indexed . fmap get) (Identity <$> children)
  Fixed children -> adjoinChildRows (Fixed . fmap get) (Identity <$> children)
  Keyed children -> adjoinChildRows (Keyed . Map.fromList) (Map.toList children)
  where contextRows :: (Range, Range) -> (Source Char, Source Char) -> [Row Range]
        contextRows ranges sources = zipWithDefaults Row EmptyLine EmptyLine
          (pure <$> actualLineRanges (fst ranges) (fst sources))
          (pure <$> actualLineRanges (snd ranges) (snd sources))

        adjoin :: Has f => [Row (Either Range (f (SplitDiff leaf Info)))] -> [Row (Either Range (f (SplitDiff leaf Info)))]
        adjoin = reverse . foldl (adjoinRowsBy (openEither (openRange $ fst sources) (openDiff $ fst sources)) (openEither (openRange $ snd sources) (openDiff $ snd sources))) []

        adjoinChildRows :: (Has f) => ([f (SplitDiff leaf Info)] -> Syntax leaf (SplitDiff leaf Info)) -> [f (Diff leaf Info)] -> [Row (SplitDiff leaf Info)]
        adjoinChildRows constructor children = let (rows, previous) = foldl childRows ([], starts ranges) children in
          fmap (wrapRowContents (wrap constructor (fst categories)) (wrap constructor (snd categories))) . adjoin $ rows ++ (fmap Left <$> contextRows (makeRanges previous (ends ranges)) sources)

        wrap :: Has f => ([f (SplitDiff leaf Info)] -> Syntax leaf (SplitDiff leaf Info)) -> Set.Set Category -> [Either Range (f (SplitDiff leaf Info))] -> SplitDiff leaf Info
        wrap constructor categories children = Free . Annotated (Info (unionRanges $ getRange <$> children) categories) . constructor $ rights children

        getRange :: Has f => Either Range (f (SplitDiff leaf Info)) -> Range
        getRange (Right diff) = case get diff of
          (Pure patch) -> let Info range _ :< _ = getSplitTerm patch in range
          (Free (Annotated (Info range _) _)) -> range
        getRange (Left range) = range

        childRows :: (Has f) => ([Row (Either Range (f (SplitDiff leaf Info)))], (Int, Int)) -> f (Diff leaf Info) -> ([Row (Either Range (f (SplitDiff leaf Info)))], (Int, Int))
        childRows (rows, previous) child = let (childRows, childRanges) = splitDiffByLines (get child) previous sources in
          (adjoin $ rows ++ (fmap Left <$> contextRows (makeRanges previous (starts childRanges)) sources) ++ (fmap (Right . (<$ child)) <$> childRows), ends childRanges)

        starts (left, right) = (start left, start right)
        ends (left, right) = (end left, end right)
        makeRanges (leftStart, rightStart) (leftEnd, rightEnd) = (Range leftStart leftEnd, Range rightStart rightEnd)

-- | Returns a function that takes an Either, applies either the left or right
-- | MaybeOpen, and returns Nothing or the original either.
openEither :: MaybeOpen a -> MaybeOpen b -> MaybeOpen (Either a b)
openEither ifLeft ifRight which = either (fmap (const which) . ifLeft) (fmap (const which) . ifRight) which

-- | Given a source and a range, returns nothing if it ends with a `\n`;
-- | otherwise returns the range.
openRange :: Source Char -> MaybeOpen Range
openRange source range = case (source `at`) <$> maybeLastIndex range of
  Just '\n' -> Nothing
  _ -> Just range

-- | Given a source and something that has a term, returns nothing if the term
-- | ends with a `\n`; otherwise returns the term.
openTerm :: Has f => Source Char -> MaybeOpen (f (Term leaf Info))
openTerm source term = const term <$> openRange source (case get term of (Info range _ :< _) -> range)

-- | Given a source and something that has a split diff, returns nothing if the
-- | diff ends with a `\n`; otherwise returns the diff.
openDiff :: Has f => Source Char -> MaybeOpen (f (SplitDiff leaf Info))
openDiff source diff = const diff <$> case get diff of
  (Free (Annotated (Info range _) _)) -> openRange source range
  (Pure patch) -> let Info range _ :< _ = getSplitTerm patch in openRange source range

-- | Zip two lists by applying a function, using the default values to extend
-- | the shorter list.
zipWithDefaults :: (a -> b -> c) -> a -> b -> [a] -> [b] -> [c]
zipWithDefaults f da db a b = take (max (length a) (length b)) $ zipWith f (a ++ repeat da) (b ++ repeat db)