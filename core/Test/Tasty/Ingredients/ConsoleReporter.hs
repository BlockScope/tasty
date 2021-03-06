-- vim:fdm=marker:foldtext=foldtext()
{-# LANGUAGE BangPatterns, ImplicitParams, MultiParamTypeClasses, DeriveDataTypeable, FlexibleContexts #-}
-- | Console reporter ingredient
module Test.Tasty.Ingredients.ConsoleReporter
  ( consoleTestReporter
  , Quiet(..)
  , HideSuccesses(..)
  -- * Internals
  -- | The following functions and datatypes are internals that are exposed to
  -- simplify the task of rolling your own custom console reporter UI.

  -- ** Output colouring
  , UseColor(..)
  , useColor
  -- ** Test failure statistics
  , Statistics(..)
  , printStatistics
  , printStatisticsNoTime
  -- ** Outputting results
  , TestOutput(..)
  , buildTestOutput
  , foldTestOutput
  ) where

import Control.Monad.State hiding (fail)
import Control.Monad.Reader hiding (fail,reader)
import Control.Concurrent.STM
import Control.Exception
import Control.Applicative
import Test.Tasty.Core
import Test.Tasty.Run
import Test.Tasty.Ingredients
import Test.Tasty.Options
import Test.Tasty.Options.Core
import Test.Tasty.Runners.Reducers
import Test.Tasty.Runners.Utils
import Text.Printf
import qualified Data.IntMap as IntMap
import Data.Char
import Data.Maybe
import Data.Monoid
import Data.Proxy
import Data.Tagged
import Data.Typeable
import Data.Foldable hiding (concatMap,elem,sequence_)
import Options.Applicative
import Prelude hiding (fail)  -- Silence AMP and FTP import warnings
import System.IO
import System.Console.ANSI

--------------------------------------------------
-- TestOutput base definitions
--------------------------------------------------
-- {{{
-- | 'TestOutput' is an intermediary between output formatting and output
-- printing. It lets us have several different printing modes (normal; print
-- failures only; quiet).
--
-- @since 0.12
data TestOutput
  = PrintTest
      {- test name         -} String
      {- print test name   -} (IO ())
      {- print test result -} (Result -> IO ())
      -- ^ Name of a test, an action that prints the test name, and an action
      -- that renders the result of the action.
  | PrintHeading String (IO ()) TestOutput
      -- ^ Name of a test group, an action that prints the heading of a test
      -- group and the 'TestOutput' for that test group.
  | Skip -- ^ Inactive test (e.g. not matching the current pattern)
  | Seq TestOutput TestOutput -- ^ Two sets of 'TestOuput' on the same level

-- The monoid laws should hold observationally w.r.t. the semantics defined
-- in this module
instance Monoid TestOutput where
  mempty = Skip
  mappend = Seq

type Level = Int

-- | Build the 'TestOutput' for a 'TestTree' and 'OptionSet'. The @colors@
-- ImplicitParam controls whether the output is colored.
--
-- @since 0.11.3
buildTestOutput :: (?colors :: Bool) => OptionSet -> TestTree -> TestOutput
buildTestOutput opts tree =
  let
    -- Do not retain the reference to the tree more than necessary
    !alignment = computeAlignment opts tree

    runSingleTest
      :: (IsTest t, ?colors :: Bool)
      => OptionSet -> TestName -> t -> Ap (Reader Level) TestOutput
    runSingleTest _opts name _test = Ap $ do
      level <- ask

      let
        printTestName = do
          printf "%s%s: %s" (indent level) name
            (replicate (alignment - indentSize * level - length name) ' ')
          hFlush stdout

        printTestResult result = do
          rDesc <- formatMessage $ resultDescription result

          -- use an appropriate printing function
          let
            printFn =
              if resultSuccessful result
                then ok
                else fail
            time = resultTime result
          printFn (resultShortDescription result)
          -- print time only if it's significant
          when (time >= 0.01) $
            printFn (printf " (%.2fs)" time)
          printFn "\n"

          when (not $ null rDesc) $
            (if resultSuccessful result then infoOk else infoFail) $
              printf "%s%s\n" (indent $ level + 1) (formatDesc (level+1) rDesc)

      return $ PrintTest name printTestName printTestResult

    runGroup :: TestName -> Ap (Reader Level) TestOutput -> Ap (Reader Level) TestOutput
    runGroup name grp = Ap $ do
      level <- ask
      let
        printHeading = printf "%s%s\n" (indent level) name
        printBody = runReader (getApp grp) (level + 1)
      return $ PrintHeading name printHeading printBody

  in
    flip runReader 0 $ getApp $
      foldTestTree
        trivialFold
          { foldSingle = runSingleTest
          , foldGroup = runGroup
          }
          opts tree

-- | Fold function for the 'TestOutput' tree into a 'Monoid'.
--
-- @since 0.12
foldTestOutput
  :: Monoid b
  => (String -> IO () -> IO Result -> (Result -> IO ()) -> b)
  -- ^ Eliminator for test cases. The @IO ()@ prints the testname. The
  -- @IO Result@ blocks until the test is finished, returning it's 'Result'.
  -- The @Result -> IO ()@ function prints the formatted output.
  -> (String -> IO () -> b -> b)
  -- ^ Eliminator for test groups. The @IO ()@ prints the test group's name.
  -- The @b@ is the result of folding the test group.
  -> TestOutput -- ^ The @TestOutput@ being rendered.
  -> StatusMap -- ^ The @StatusMap@ received by the 'TestReporter'
  -> b
foldTestOutput foldTest foldHeading outputTree smap =
  flip evalState 0 $ getApp $ go outputTree where
  go (PrintTest name printName printResult) = Ap $ do
    ix <- get
    put $! ix + 1
    let
      statusVar =
        fromMaybe (error "internal error: index out of bounds") $
        IntMap.lookup ix smap
      readStatusVar = getResultFromTVar statusVar
    return $ foldTest name printName readStatusVar printResult
  go (PrintHeading name printName printBody) = Ap $
    foldHeading name printName <$> getApp (go printBody)
  go (Seq a b) = mappend (go a) (go b)
  go Skip = mempty

-- }}}

--------------------------------------------------
-- TestOutput modes
--------------------------------------------------
-- {{{
consoleOutput :: (?colors :: Bool) => TestOutput -> StatusMap -> IO ()
consoleOutput output smap =
  getTraversal . fst $ foldTestOutput foldTest foldHeading output smap
  where
    foldTest _name printName getResult printResult =
      ( Traversal $ do
          printName
          r <- getResult
          printResult r
      , Any True)
    foldHeading _name printHeading (printBody, Any nonempty) =
      ( Traversal $ do
          when nonempty $ do printHeading; getTraversal printBody
      , Any nonempty
      )

consoleOutputHidingSuccesses :: (?colors :: Bool) => TestOutput -> StatusMap -> IO ()
consoleOutputHidingSuccesses output smap =
  void . getApp $ foldTestOutput foldTest foldHeading output smap
  where
    foldTest _name printName getResult printResult =
      Ap $ do
          printName
          r <- getResult
          if resultSuccessful r
            then do clearThisLine; return $ Any False
            else do printResult r; return $ Any True

    foldHeading _name printHeading printBody =
      Ap $ do
        printHeading
        Any failed <- getApp printBody
        unless failed clearAboveLine
        return $ Any failed

    clearAboveLine = do cursorUpLine 1; clearThisLine
    clearThisLine = do clearLine; setCursorColumn 0

streamOutputHidingSuccesses :: (?colors :: Bool) => TestOutput -> StatusMap -> IO ()
streamOutputHidingSuccesses output smap =
  void . flip evalStateT [] . getApp $
    foldTestOutput foldTest foldHeading output smap
  where
    foldTest _name printName getResult printResult =
      Ap $ do
          r <- liftIO $ getResult
          if resultSuccessful r
            then return $ Any False
            else do
              stack <- get
              put []

              liftIO $ do
                sequence_ $ reverse stack
                printName
                printResult r

              return $ Any True

    foldHeading _name printHeading printBody =
      Ap $ do
        modify (printHeading :)
        Any failed <- getApp printBody
        unless failed $
          modify $ \stack ->
            case stack of
              _:rest -> rest
              [] -> [] -- shouldn't happen anyway
        return $ Any failed

-- }}}

--------------------------------------------------
-- Statistics
--------------------------------------------------
-- {{{

-- | Track the number of tests that were run and failures of a 'TestTree' or
-- sub-tree.
--
-- @since 0.11.3
data Statistics = Statistics
  { statTotal :: !Int -- ^ Number of active tests (e.g., that match the
                      -- pattern specified on the commandline), inactive tests
                      -- are not counted.
  , statFailures :: !Int -- ^ Number of active tests that failed.
  }

instance Monoid Statistics where
  Statistics t1 f1 `mappend` Statistics t2 f2 = Statistics (t1 + t2) (f1 + f2)
  mempty = Statistics 0 0

computeStatistics :: StatusMap -> IO Statistics
computeStatistics = getApp . foldMap (\var -> Ap $
  (\r -> Statistics 1 (if resultSuccessful r then 0 else 1))
    <$> getResultFromTVar var)

reportStatistics :: (?colors :: Bool) => Statistics -> IO ()
reportStatistics st = case statFailures st of
    0 -> ok $ printf "All %d tests passed" (statTotal st)
    fs -> fail $ printf "%d out of %d tests failed" fs (statTotal st)

-- | @printStatistics@ reports test success/failure statistics and time it took
-- to run. The 'Time' results is intended to be filled in by the 'TestReporter'
-- callback. The @colors@ ImplicitParam controls whether coloured output is
-- used.
--
-- @since 0.11.3
printStatistics :: (?colors :: Bool) => Statistics -> Time -> IO ()
printStatistics st time = do
  printf "\n"
  reportStatistics st
  case statFailures st of
    0 -> ok $ printf " (%.2fs)\n" time
    _ -> fail $ printf " (%.2fs)\n" time

-- | @printStatisticsNoTime@ reports test success/failure statistics
-- The @colors@ ImplicitParam controls whether coloured output is used.
--
-- @since 0.12
printStatisticsNoTime :: (?colors :: Bool) => Statistics -> IO ()
printStatisticsNoTime st = reportStatistics st >> printf "\n"

-- | Wait until
--
-- * all tests have finished successfully, and return 'True', or
--
-- * at least one test has failed, and return 'False'
statusMapResult
  :: Int -- ^ lookahead
  -> StatusMap
  -> IO Bool
statusMapResult lookahead0 smap
  | IntMap.null smap = return True
  | otherwise =
      join . atomically $
        IntMap.foldrWithKey f finish smap mempty lookahead0
  where
    f :: Int
      -> TVar Status
      -> (IntMap.IntMap () -> Int -> STM (IO Bool))
      -> (IntMap.IntMap () -> Int -> STM (IO Bool))
    -- ok_tests is a set of tests that completed successfully
    -- lookahead is the number of unfinished tests that we are allowed to
    -- look at
    f key tvar k ok_tests lookahead
      | lookahead <= 0 =
          -- We looked at too many unfinished tests.
          next_iter ok_tests
      | otherwise = do
          this_status <- readTVar tvar
          case this_status of
            Done r ->
              if resultSuccessful r
                then k (IntMap.insert key () ok_tests) lookahead
                else return $ return False
            _ -> k ok_tests (lookahead-1)

    -- next_iter is called when we end the current iteration,
    -- either because we reached the end of the test tree
    -- or because we exhausted the lookahead
    next_iter :: IntMap.IntMap () -> STM (IO Bool)
    next_iter ok_tests =
      -- If we made no progress at all, wait until at least some tests
      -- complete.
      -- Otherwise, reduce the set of tests we are looking at.
      if IntMap.null ok_tests
        then retry
        else return $ statusMapResult lookahead0 (IntMap.difference smap ok_tests)

    finish :: IntMap.IntMap () -> Int -> STM (IO Bool)
    finish ok_tests _ = next_iter ok_tests

-- }}}

--------------------------------------------------
-- Console test reporter
--------------------------------------------------
-- {{{

-- | A simple console UI
consoleTestReporter :: Ingredient
consoleTestReporter =
  TestReporter
    [ Option (Proxy :: Proxy Quiet)
    , Option (Proxy :: Proxy HideSuccesses)
    , Option (Proxy :: Proxy UseColor)
    ] $
  \opts tree -> Just $ \smap -> do

  let
    whenColor = lookupOption opts
    Quiet quiet = lookupOption opts
    HideSuccesses hideSuccesses = lookupOption opts
    NumThreads numThreads = lookupOption opts

  if quiet
    then do
      b <- statusMapResult numThreads smap
      return $ \_time -> return b
    else

      do
      isTerm <- hSupportsANSI stdout

      (\k -> if isTerm
        then (do hideCursor; k) `finally` showCursor
        else k) $ do

          hSetBuffering stdout LineBuffering

          let
            ?colors = useColor whenColor isTerm

          let
            output = buildTestOutput opts tree

          case () of { _
            | hideSuccesses && isTerm ->
                consoleOutputHidingSuccesses output smap
            | hideSuccesses && not isTerm ->
                streamOutputHidingSuccesses output smap
            | otherwise -> consoleOutput output smap
          }

          return $ \time -> do
            stats <- computeStatistics smap
            printStatistics stats time
            return $ statFailures stats == 0

-- | Do not print test results (see README for details)
newtype Quiet = Quiet Bool
  deriving (Eq, Ord, Typeable)
instance IsOption Quiet where
  defaultValue = Quiet False
  parseValue = fmap Quiet . safeRead
  optionName = return "quiet"
  optionHelp = return "Do not produce any output; indicate success only by the exit code"
  optionCLParser = mkFlagCLParser (short 'q') (Quiet True)

-- | Report only failed tests
newtype HideSuccesses = HideSuccesses Bool
  deriving (Eq, Ord, Typeable)
instance IsOption HideSuccesses where
  defaultValue = HideSuccesses False
  parseValue = fmap HideSuccesses . safeRead
  optionName = return "hide-successes"
  optionHelp = return "Do not print tests that passed successfully"
  optionCLParser = mkFlagCLParser mempty (HideSuccesses True)

-- | When to use color on the output
--
-- @since 0.11.3
data UseColor
  = Never
  | Always
  | Auto -- ^ Only if stdout is an ANSI color supporting terminal
  deriving (Eq, Ord, Typeable)

-- | Control color output
instance IsOption UseColor where
  defaultValue = Auto
  parseValue = parseUseColor
  optionName = return "color"
  optionHelp = return "When to use colored output. Options are 'never', 'always' and 'auto' (default: 'auto')"

-- | @useColor when isTerm@ decides if colors should be used,
--   where @isTerm@ indicates whether @stdout@ is a terminal device.
--
--   @since 0.11.3
useColor :: UseColor -> Bool -> Bool
useColor when isTerm =
  case when of
    Never  -> False
    Always -> True
    Auto   -> isTerm

parseUseColor :: String -> Maybe UseColor
parseUseColor s =
  case map toLower s of
    "never"  -> return Never
    "always" -> return Always
    "auto"   -> return Auto
    _        -> Nothing

-- }}}

--------------------------------------------------
-- Various utilities
--------------------------------------------------
-- {{{
getResultFromTVar :: TVar Status -> IO Result
getResultFromTVar var =
  atomically $ do
    status <- readTVar var
    case status of
      Done r -> return r
      _ -> retry

-- }}}

--------------------------------------------------
-- Formatting
--------------------------------------------------
-- {{{

indentSize :: Int
indentSize = 2

indent :: Int -> String
indent n = replicate (indentSize * n) ' '

-- handle multi-line result descriptions properly
formatDesc
  :: Int -- indent
  -> String
  -> String
formatDesc n desc =
  let
    -- remove all trailing linebreaks
    chomped = reverse . dropWhile (== '\n') . reverse $ desc

    multiline = '\n' `elem` chomped

    -- we add a leading linebreak to the description, to start it on a new
    -- line and add an indentation
    paddedDesc = flip concatMap chomped $ \c ->
      if c == '\n'
        then c : indent n
        else [c]
  in
    if multiline
      then paddedDesc
      else chomped

data Maximum a
  = Maximum a
  | MinusInfinity

instance Ord a => Monoid (Maximum a) where
  mempty = MinusInfinity

  Maximum a `mappend` Maximum b = Maximum (a `max` b)
  MinusInfinity `mappend` a = a
  a `mappend` MinusInfinity = a

-- | Compute the amount of space needed to align "OK"s and "FAIL"s
computeAlignment :: OptionSet -> TestTree -> Int
computeAlignment opts =
  fromMonoid .
  foldTestTree
    trivialFold
      { foldSingle = \_ name _ level -> Maximum (length name + level)
      , foldGroup = \_ m -> m . (+ indentSize)
      }
    opts
  where
    fromMonoid m =
      case m 0 of
        MinusInfinity -> 0
        Maximum x -> x

-- (Potentially) colorful output
ok, fail, infoOk, infoFail :: (?colors :: Bool) => String -> IO ()
fail     = output BoldIntensity   Vivid Red
ok       = output NormalIntensity Dull  Green
infoOk   = output NormalIntensity Dull  White
infoFail = output NormalIntensity Dull  Red

output
  :: (?colors :: Bool)
  => ConsoleIntensity
  -> ColorIntensity
  -> Color
  -> String
  -> IO ()
output bold intensity color str
  | ?colors =
    (do
      setSGR
        [ SetColor Foreground intensity color
        , SetConsoleIntensity bold
        ]
      putStr str
    ) `finally` setSGR []
  | otherwise = putStr str

-- }}}
