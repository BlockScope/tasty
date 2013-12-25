-- | Core types and definitions
{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleContexts,
             ExistentialQuantification, RankNTypes, DeriveDataTypeable #-}
module Test.Tasty.Core where

import Control.Applicative
import Control.Exception
import Test.Tasty.Options
import Test.Tasty.Patterns
import Data.Foldable
import Data.Monoid
import Data.Typeable
import qualified Data.Map as Map
import Data.Tagged
import Text.Printf

-- | A test result
data Result = Result
  { resultSuccessful :: Bool
    -- ^
    -- 'resultSuccessful' should be 'True' for a passed test and 'False' for
    -- a failed one.
  , resultDescription :: String
    -- ^
    -- 'resultDescription' may contain some details about the test. For
    -- a passed test it's ok to leave it empty. Providers like SmallCheck and
    -- QuickCheck use it to provide information about how many tests were
    -- generated.
    --
    -- For a failed test, 'resultDescription' should typically provide more
    -- information about the failure.
  }

-- | Test progress information.
--
-- This may be used by a runner to provide some feedback to the user while
-- a long-running test is executing.
data Progress = Progress
  { progressText :: String
    -- ^ textual information about the test's progress
  , progressPercent :: Float
    -- ^
    -- 'progressPercent' should be a value between 0 and 1. If it's impossible
    -- to compute the estimate, use 0.
  }

-- | The interface to be implemented by a test provider.
--
-- The type @t@ is the concrete representation of the test which is used by
-- the provider.
class Typeable t => IsTest t where
  -- | Run the test
  run
    :: OptionSet -- ^ options
    -> t -- ^ the test to run
    -> (Progress -> IO ()) -- ^ a callback to report progress
    -> IO Result

  -- | The list of options that affect execution of tests of this type
  testOptions :: Tagged t [OptionDescription]

-- | The name of a test or a group of tests
type TestName = String

-- | 'ResourceSpec' describes how to acquire a resource (the first field)
-- and how to release it (the second field).
data ResourceSpec a = ResourceSpec (IO a) (a -> IO ())

data ResourceError
  = NotRunningTests
  | UnexpectedState String
  deriving Typeable

instance Show ResourceError where
  show NotRunningTests =
    "Unhandled resource. Probably a bug in the runner you're using."
  show (UnexpectedState state) =
    printf "Unexpected state of the resource (%s). Report as a tasty bug."
      state

instance Exception ResourceError

-- | The main data structure defining a test suite.
--
-- It consists of individual test cases and properties, organized in named
-- groups which form a tree-like hierarchy.
--
-- There is no generic way to create a test case. Instead, every test
-- provider (tasty-hunit, tasty-smallcheck etc.) provides a function to
-- turn a test case into a 'TestTree'.
--
-- Groups can be created using 'testGroup'.
data TestTree
  = forall t . IsTest t => SingleTest TestName t
    -- ^ A single test of some particular type
  | TestGroup TestName [TestTree]
    -- ^ Assemble a number of tests into a cohesive group
  | PlusTestOptions (OptionSet -> OptionSet) TestTree
    -- ^ Add some options to child tests
  | forall a . WithResource (ResourceSpec a) (IO a -> TestTree)
  | AskOptions (OptionSet -> TestTree)

-- | Create a named group of test cases or other groups
testGroup :: TestName -> [TestTree] -> TestTree
testGroup = TestGroup

data TreeFold b = TreeFold
  { foldSingle :: forall t . IsTest t => OptionSet -> TestName -> t -> b
  , foldGroup :: TestName -> b -> b
  , foldResource :: forall a . ResourceSpec a -> (IO a -> b) -> b
  }

-- | 'trivialFold' can serve as the basis for custom folds. Just override
-- the fields you need.
--
-- Here's what it does:
--
-- * single tests are mapped to `mempty` (you probably do want to override that)
--
-- * test group is returned unmodified
--
-- * for a resource, an IO action that throws an exception is passed (you
-- want to override this for runners/ingredients that execute tests)
trivialFold :: Monoid b => TreeFold b
trivialFold = TreeFold
  { foldSingle = \_ _ _ -> mempty
  , foldGroup = const id
  , foldResource = \_ f -> f $ throwIO NotRunningTests
  }

-- | Fold a test tree into a single value.
--
-- Apart from pure convenience, this function also does the following
-- useful things:
--
-- 1. Keeping track of the current options (which may change due to
-- `PlusTestOptions` nodes)
--
-- 2. Filtering out the tests which do not match the patterns
--
-- Thus, it is preferred to an explicit recursive traversal of the tree.
--
-- Note: right now, the patterns are looked up only once, and won't be
-- affected by the subsequent option changes. This shouldn't be a problem
-- in practice; OTOH, this behaviour may be changed later.
foldTestTree
  :: Monoid b
  => TreeFold b
     -- ^ the algebra
  -> OptionSet
     -- ^ initial options
  -> TestTree -> b
foldTestTree (TreeFold fTest fGroup fResource) opts tree =
  let pat = lookupOption opts
  in go pat [] opts tree
  where
    go pat path opts tree =
      case tree of
        SingleTest name test
          | testPatternMatches pat (path ++ [name])
            -> fTest opts name test
          | otherwise -> mempty
        TestGroup name trees ->
          fGroup name $ foldMap (go pat (path ++ [name]) opts) trees
        PlusTestOptions f tree -> go pat path (f opts) tree
        WithResource res tree -> fResource res $ \res -> go pat path opts (tree res)
        AskOptions f -> go pat path opts (f opts)

-- | Useful wrapper for use with foldTestTree
newtype AppMonoid f = AppMonoid { getApp :: f () }
instance Applicative f => Monoid (AppMonoid f) where
  mempty = AppMonoid $ pure ()
  AppMonoid f1 `mappend` AppMonoid f2 = AppMonoid $ f1 *> f2

-- | Get the list of options that are relevant for a given test tree
treeOptions :: TestTree -> [OptionDescription]
treeOptions =

  Prelude.concat .
  Map.elems .

  foldTestTree
    trivialFold { foldSingle = \_ _ -> getTestOptions }
    mempty

  where
    getTestOptions
      :: forall t . IsTest t
      => t -> Map.Map TypeRep [OptionDescription]
    getTestOptions t =
      Map.singleton (typeOf t) $
          witness testOptions t
