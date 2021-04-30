{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

module NvFetcher
  ( module NvFetcher.NixFetcher,
    module NvFetcher.Nvchecker,
    module NvFetcher.PackageSet,
    module NvFetcher.Types,
    nvfetcherRules,
    generateNixSources,
    Args (..),
    defaultArgs,
    defaultMain,
    defaultMainWith,
    VersionChange (..),
    getVersionChanges,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Data.Coerce (coerce)
import Data.Maybe (fromJust, fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text as T
import Development.Shake
import NeatInterpolation (trimming)
import NvFetcher.NixFetcher
import NvFetcher.Nvchecker
import NvFetcher.PackageSet
import NvFetcher.Types
import System.Console.GetOpt (OptDescr)

-- | Arguments for running nvfetcher
data Args = Args
  { argShakeOptions :: ShakeOptions -> ShakeOptions,
    argOutputFilePath :: FilePath,
    argRules :: Rules (),
    argActionAfterBuild :: Action (),
    argActionAfterClean :: Action ()
  }

-- | Default arguments of 'defaultMain'
defaultArgs :: Args
defaultArgs =
  Args
    ( \x ->
        x
          { shakeTimings = True,
            shakeProgress = progressSimple
          }
    )
    "sources.nix"
    (pure ())
    (pure ())
    (pure ())

-- | Entry point of nvfetcher
defaultMain :: Args -> PackageSet () -> IO ()
defaultMain args packageSet = defaultMainWith [] $ const $pure (args, packageSet)

-- | Like 'defaultMain' but allows to define custom cli flags
defaultMainWith :: [OptDescr (Either String a)] -> ([a] -> IO (Args, PackageSet ())) -> IO ()
defaultMainWith flags f = do
  var <- newMVar mempty
  shakeArgsOptionsWith
    shakeOptions
    flags
    $ \opts flagValues argValues -> case argValues of
      [] -> pure Nothing
      files -> do
        (args@Args {..}, packageSet) <- f flagValues
        let opts' = argShakeOptions opts
        pure $
          Just
            ( opts'
                { shakeExtra = addShakeExtra (VersionChanges var) (shakeExtra opts')
                },
              want files >> mainRules args packageSet
            )

mainRules :: Args -> PackageSet () -> Rules ()
mainRules Args {..} packageSet = do
  "clean" ~> do
    removeFilesAfter ".shake" ["//*"]
    removeFilesAfter "." [argOutputFilePath]
    argActionAfterClean

  "build" ~> do
    pkgs <- runPackageSet packageSet
    generateNixSources argOutputFilePath $ Set.toList pkgs
    argActionAfterBuild

  argRules
  nvfetcherRules

--------------------------------------------------------------------------------

-- | Record version changes between runs, relying on shake database
data VersionChange = VersionChange
  { vcName :: PackageName,
    vcOld :: Maybe Version,
    vcNew :: Version
  }
  deriving (Eq)

instance Show VersionChange where
  show VersionChange {..} =
    T.unpack $ vcName <> ": " <> fromMaybe "∅" (coerce vcOld) <> " → " <> coerce vcNew

newtype VersionChanges = VersionChanges (MVar [VersionChange])

recordVersionChange :: PackageName -> Maybe Version -> Version -> Action ()
recordVersionChange vcName vcOld vcNew = do
  VersionChanges var <- fromJust <$> getShakeExtra @VersionChanges
  liftIO $ modifyMVar_ var (pure . (++ [VersionChange {..}]))

-- | Get version changes. Use this function in 'argActionAfterBuild' to produce external changelog
getVersionChanges :: Action [VersionChange]
getVersionChanges = do
  VersionChanges var <- fromJust <$> getShakeExtra @VersionChanges
  liftIO $ readMVar var

--------------------------------------------------------------------------------

-- | Rules of nvfetcher
nvfetcherRules :: Rules ()
nvfetcherRules = do
  nvcheckerRule
  prefetchRule

-- | Main action, given a set of packages, generating nix sources expr in a file
generateNixSources :: FilePath -> [Package] -> Action ()
generateNixSources fp pkgs = do
  body <- fmap genOne <$> actions
  getVersionChanges >>= \changes ->
    if null changes
      then putInfo "Up to date"
      else do
        putInfo "Changes:"
        putInfo $ unlines $ show <$> changes
  writeFileChanged fp $ T.unpack $ srouces $ T.unlines body
  putInfo $ "Generate " <> fp
  where
    single Package {..} = do
      (NvcheckerResult version mOld) <- checkVersion pversion
      prefetched <- prefetch $ pfetcher version
      case mOld of
        Nothing ->
          recordVersionChange pname Nothing version
        Just old
          | old /= version ->
            recordVersionChange pname (Just old) version
        _ -> pure ()
      pure (pname, version, prefetched)
    genOne (name, coerce @Version -> ver, toNixExpr -> srcP) =
      [trimming|
        $name = {
          pname = "$name";
          version = "$ver";
          src = $srcP;
        };
      |]
    actions = parallel $ map single pkgs
    srouces body =
      [trimming|
        # This file was generated by nvfetcher, please do not modify it manually.
        { fetchgit, fetchurl }:
        {
          $body
        }
      |]
