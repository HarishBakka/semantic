  hunks,
  Hunk(..)
import Prelude hiding (fst, snd)
import qualified Prelude
import Data.Functor.Both
data Hunk a = Hunk { offset :: Both (Sum Int), changes :: [Change a], trailingContext :: [Row a] }
hunkLength :: Hunk a -> Both (Sum Int)
changeLength :: Change a -> Both (Sum Int)
rowLength :: Row a -> Both (Sum Int)
rowLength = fmap lineLength . unRow
showHunk :: Both SourceBlob -> Hunk (SplitDiff a Info) -> String
showHunk blobs hunk = header blobs hunk ++ concat (showChange sources <$> changes hunk) ++ showLines (snd sources) ' ' (unRight <$> trailingContext hunk)
  where sources = source <$> blobs
showChange :: Both (Source Char) -> Change (SplitDiff a Info) -> String
showChange sources change = showLines (snd sources) ' ' (unRight <$> context change) ++ deleted ++ inserted
  where (deleted, inserted) = runBoth $ pure showLines <*> sources <*> Both ('-', '+') <*> (pure fmap <*> Both (unLeft, unRight) <*> pure (contents change))
header :: Both SourceBlob -> Hunk a -> String
header blobs hunk = intercalate "\n" [filepathHeader, fileModeHeader, beforeFilepath, afterFilepath, maybeOffsetHeader]
  where filepathHeader = "diff --git a/" ++ pathA ++ " b/" ++ pathB
        fileModeHeader = case (modeA, modeB) of
          (Nothing, Just mode) -> intercalate "\n" [ "new file mode " ++ modeToDigits mode, blobOidHeader ]
          (Just mode, Nothing) -> intercalate "\n" [ "old file mode " ++ modeToDigits mode, blobOidHeader ]
          (Just mode, Just other) | mode == other -> "index " ++ oidA ++ ".." ++ oidB ++ " " ++ modeToDigits mode
          (Just mode1, Just mode2) -> intercalate "\n" [
            "old mode" ++ modeToDigits mode1,
            "new mode " ++ modeToDigits mode2 ++ " " ++ blobOidHeader
            ]
        blobOidHeader = "index " ++ oidA ++ ".." ++ oidB
        modeHeader :: String -> Maybe SourceKind -> String -> String
        modeHeader ty maybeMode path = case maybeMode of
           Just mode -> ty ++ "/" ++ path
           Nothing -> "/dev/null"
        beforeFilepath = "--- " ++ modeHeader "a" modeA pathA
        afterFilepath = "+++ " ++ modeHeader "b" modeB pathB
        maybeOffsetHeader = if lengthA > 0 && lengthB > 0
                            then offsetHeader
                            else mempty
        offsetHeader = "@@ -" ++ offsetA ++ "," ++ show lengthA ++ " +" ++ offsetB ++ "," ++ show lengthB ++ " @@" ++ "\n"
        (lengthA, lengthB) = runBoth . fmap getSum $ hunkLength hunk
        (offsetA, offsetB) = runBoth . fmap (show . getSum) $ offset hunk
        (pathA, pathB) = runBoth $ path <$> blobs
        (oidA, oidB) = runBoth $ oid <$> blobs
        (modeA, modeB) = runBoth $ blobKind <$> blobs
hunks _ blobs | Both (True, True) <- Source.null . source <$> blobs = [Hunk { offset = mempty, changes = [], trailingContext = [] }]
hunks diff blobs = hunksInRows (Both (1, 1)) $ fmap Prelude.fst <$> splitDiffByLines (source <$> blobs) diff

hunksInRows :: Both (Sum Int) -> [Row (SplitDiff a Info)] -> [Hunk (SplitDiff a Info)]
nextHunk :: Both (Sum Int) -> [Row (SplitDiff a Info)] -> Maybe (Hunk (SplitDiff a Info), [Row (SplitDiff a Info)])
nextChange :: Both (Sum Int) -> [Row (SplitDiff a Info)] -> Maybe (Both (Sum Int), Change (SplitDiff a Info), [Row (SplitDiff a Info)])
rowHasChanges (Row lines) = or (lineHasChanges <$> lines)