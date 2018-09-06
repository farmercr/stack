{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE FlexibleContexts      #-}
-- | Cache information about previous builds
module Stack.Build.Cache
    ( tryGetBuildCache
    , tryGetConfigCache
    , tryGetCabalMod
    , getInstalledExes
    , tryGetFlagCache
    , deleteCaches
    , markExeInstalled
    , markExeNotInstalled
    , writeFlagCache
    , writeBuildCache
    , writeConfigCache
    , writeCabalMod
    , setTestSuccess
    , unsetTestSuccess
    , checkTestSuccess
    , writePrecompiledCache
    , readPrecompiledCache
    -- Exported for testing
    , BuildCache(..)
    ) where

import           Stack.Prelude
import           Crypto.Hash (hashWith, SHA256(..))
import qualified Data.ByteArray as Mem (convert)
import qualified Data.ByteString.Base64.URL as B64URL
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as S8
import           Data.Char (ord)
import qualified Data.Map as M
import qualified Data.Set as Set
import qualified Data.Store as Store
import qualified Data.Text as T
import qualified Data.Yaml as Yaml
import           Foreign.C.Types (CTime)
import           Path
import           Path.IO
import           Stack.Constants
import           Stack.Constants.Config
import           Stack.StoreTH
import           Stack.Types.Build
import           Stack.Types.Compiler
import           Stack.Types.Config
import           Stack.Types.GhcPkgId
import           Stack.Types.NamedComponent
import qualified System.FilePath as FP
import           System.PosixCompat.Files (modificationTime, getFileStatus, setFileTimes)

-- | Directory containing files to mark an executable as installed
exeInstalledDir :: (MonadReader env m, HasEnvConfig env, MonadThrow m)
                => InstallLocation -> m (Path Abs Dir)
exeInstalledDir Snap = (</> relDirInstalledPackages) `liftM` installationRootDeps
exeInstalledDir Local = (</> relDirInstalledPackages) `liftM` installationRootLocal

-- | Get all of the installed executables
getInstalledExes :: (MonadReader env m, HasEnvConfig env, MonadIO m, MonadThrow m)
                 => InstallLocation -> m [PackageIdentifier]
getInstalledExes loc = do
    dir <- exeInstalledDir loc
    (_, files) <- liftIO $ handleIO (const $ return ([], [])) $ listDir dir
    return $
        concat $
        M.elems $
        -- If there are multiple install records (from a stack version
        -- before https://github.com/commercialhaskell/stack/issues/2373
        -- was fixed), then we don't know which is correct - ignore them.
        M.fromListWith (\_ _ -> []) $
        map (\x -> (pkgName x, [x])) $
        mapMaybe (parsePackageIdentifier . toFilePath . filename) files

-- | Mark the given executable as installed
markExeInstalled :: (MonadReader env m, HasEnvConfig env, MonadIO m, MonadThrow m)
                 => InstallLocation -> PackageIdentifier -> m ()
markExeInstalled loc ident = do
    dir <- exeInstalledDir loc
    ensureDir dir
    ident' <- parseRelFile $ packageIdentifierString ident
    let fp = toFilePath $ dir </> ident'
    -- Remove old install records for this package.
    -- TODO: This is a bit in-efficient. Put all this metadata into one file?
    installed <- getInstalledExes loc
    forM_ (filter (\x -> pkgName ident == pkgName x) installed)
          (markExeNotInstalled loc)
    -- TODO consideration for the future: list all of the executables
    -- installed, and invalidate this file in getInstalledExes if they no
    -- longer exist
    liftIO $ B.writeFile fp "Installed"

-- | Mark the given executable as not installed
markExeNotInstalled :: (MonadReader env m, HasEnvConfig env, MonadIO m, MonadThrow m)
                    => InstallLocation -> PackageIdentifier -> m ()
markExeNotInstalled loc ident = do
    dir <- exeInstalledDir loc
    ident' <- parseRelFile $ packageIdentifierString ident
    liftIO $ ignoringAbsence (removeFile $ dir </> ident')

buildCacheFile :: (HasEnvConfig env, MonadReader env m, MonadThrow m)
               => Path Abs Dir
               -> NamedComponent
               -> m (Path Abs File)
buildCacheFile dir component = do
    cachesDir <- buildCachesDir dir
    let nonLibComponent prefix name = prefix <> "-" <> T.unpack name
    cacheFileName <- parseRelFile $ case component of
        CLib -> "lib"
        CInternalLib name -> nonLibComponent "internal-lib" name
        CExe name -> nonLibComponent "exe" name
        CTest name -> nonLibComponent "test" name
        CBench name -> nonLibComponent "bench" name
    return $ cachesDir </> cacheFileName

-- | Try to read the dirtiness cache for the given package directory.
tryGetBuildCache :: HasEnvConfig env
                 => Path Abs Dir
                 -> NamedComponent
                 -> RIO env (Maybe (Map FilePath FileCacheInfo))
tryGetBuildCache dir component = do
  fp <- buildCacheFile dir component
  ensureDir $ parent fp
  either (const Nothing) (Just . buildCacheTimes) <$>
    liftIO (tryAny (Yaml.decodeFileThrow (toFilePath fp)))

-- | Try to read the dirtiness cache for the given package directory.
tryGetConfigCache :: HasEnvConfig env
                  => Path Abs Dir -> RIO env (Maybe ConfigCache)
tryGetConfigCache dir = decodeConfigCache =<< configCacheFile dir

-- | Try to read the mod time of the cabal file from the last build
tryGetCabalMod :: HasEnvConfig env
               => Path Abs Dir -> RIO env (Maybe CTime)
tryGetCabalMod dir = do
  fp <- toFilePath <$> configCabalMod dir
  liftIO $ either (const Nothing) (Just . modificationTime) <$>
      tryIO (getFileStatus fp)

-- | Write the dirtiness cache for this package's files.
writeBuildCache :: HasEnvConfig env
                => Path Abs Dir
                -> NamedComponent
                -> Map FilePath FileCacheInfo -> RIO env ()
writeBuildCache dir component times = do
    fp <- toFilePath <$> buildCacheFile dir component
    liftIO $ Yaml.encodeFile fp BuildCache
        { buildCacheTimes = times
        }

-- | Write the dirtiness cache for this package's configuration.
writeConfigCache :: HasEnvConfig env
                => Path Abs Dir
                -> ConfigCache
                -> RIO env ()
writeConfigCache dir x = do
    fp <- configCacheFile dir
    encodeConfigCache fp x

-- | See 'tryGetCabalMod'
writeCabalMod :: HasEnvConfig env
              => Path Abs Dir
              -> CTime
              -> RIO env ()
writeCabalMod dir x = do
    fp <- toFilePath <$> configCabalMod dir
    writeFileBinary fp "Just used for its modification time"
    liftIO $ setFileTimes fp x x

-- | Delete the caches for the project.
deleteCaches :: (MonadIO m, MonadReader env m, HasEnvConfig env, MonadThrow m)
             => Path Abs Dir -> m ()
deleteCaches dir = do
    {- FIXME confirm that this is acceptable to remove
    bfp <- buildCacheFile dir
    removeFileIfExists bfp
    -}
    cfp <- configCacheFile dir
    liftIO $ ignoringAbsence (removeFile cfp)

flagCacheFile :: (MonadIO m, MonadThrow m, MonadReader env m, HasEnvConfig env)
              => Installed
              -> m (Path Abs File)
flagCacheFile installed = do
    rel <- parseRelFile $
        case installed of
            Library _ gid _ -> ghcPkgIdString gid
            Executable ident -> packageIdentifierString ident
    dir <- flagCacheLocal
    return $ dir </> rel

-- | Loads the flag cache for the given installed extra-deps
tryGetFlagCache :: HasEnvConfig env
                => Installed
                -> RIO env (Maybe ConfigCache)
tryGetFlagCache gid = do
    fp <- flagCacheFile gid
    decodeConfigCache fp

writeFlagCache :: HasEnvConfig env
               => Installed
               -> ConfigCache
               -> RIO env ()
writeFlagCache gid cache = do
    file <- flagCacheFile gid
    ensureDir (parent file)
    encodeConfigCache file cache

successBS, failureBS :: ByteString
successBS = "success"
failureBS = "failure"

-- | Mark a test suite as having succeeded
setTestSuccess :: HasEnvConfig env
               => Path Abs Dir
               -> RIO env ()
setTestSuccess dir = do
    fp <- testSuccessFile dir
    writeFileBinary (toFilePath fp) successBS

-- | Mark a test suite as not having succeeded
unsetTestSuccess :: HasEnvConfig env
                 => Path Abs Dir
                 -> RIO env ()
unsetTestSuccess dir = do
    fp <- testSuccessFile dir
    writeFileBinary (toFilePath fp) failureBS

-- | Check if the test suite already passed
checkTestSuccess :: HasEnvConfig env
                 => Path Abs Dir
                 -> RIO env Bool
checkTestSuccess dir = do
  fp <- testSuccessFile dir
  -- we could ensure the file is the right size first,
  -- but we're not expected an attack from the user's filesystem
  either (const False) (== successBS)
    <$> tryIO (readFileBinary $ toFilePath fp)

--------------------------------------
-- Precompiled Cache
--
-- Idea is simple: cache information about packages built in other snapshots,
-- and then for identical matches (same flags, config options, dependencies)
-- just copy over the executables and reregister the libraries.
--------------------------------------

-- | The file containing information on the given package/configuration
-- combination. The filename contains a hash of the non-directory configure
-- options for quick lookup if there's a match.
--
-- It also returns an action yielding the location of the precompiled
-- path based on the old binary encoding.
--
-- We only pay attention to non-directory options. We don't want to avoid a
-- cache hit just because it was installed in a different directory.
precompiledCacheFile :: HasEnvConfig env
                     => PackageLocationImmutable
                     -> ConfigureOpts
                     -> Set GhcPkgId -- ^ dependencies
                     -> RIO env (Path Abs File)
precompiledCacheFile loc copts installedPackageIDs = do
  ec <- view envConfigL

  compiler <- view actualCompilerVersionL >>= parseRelDir . compilerVersionString
  cabal <- view cabalVersionL >>= parseRelDir . versionString

  -- The goal here is to come up with a string representing the
  -- package location which is unique. Luckily @TreeKey@s are exactly
  -- that!
  treeKey <- getPackageLocationTreeKey loc
  pkg <- parseRelDir $ T.unpack $ utf8BuilderToText $ display treeKey

  platformRelDir <- platformGhcRelDir
  let precompiledDir =
            view stackRootL ec
        </> relDirPrecompiled
        </> platformRelDir
        </> compiler
        </> cabal

  -- In Cabal versions 1.22 and later, the configure options contain the
  -- installed package IDs, which is what we need for a unique hash.
  -- Unfortunately, earlier Cabals don't have the information, so we must
  -- supplement it with the installed package IDs directly.
  -- See issue: https://github.com/commercialhaskell/stack/issues/1103
  let input = (coNoDirs copts, installedPackageIDs)
  hashPath <- parseRelFile $ S8.unpack $ B64URL.encode
            $ Mem.convert $ hashWith SHA256 $ Store.encode input

  let longPath = precompiledDir </> pkg </> hashPath

  -- See #3649 - shorten the paths on windows if MAX_PATH will be
  -- violated. Doing this only when necessary allows use of existing
  -- precompiled packages.
  if pathTooLong (toFilePath longPath) then do
      shortPkg <- shaPath pkg
      shortHash <- shaPath hashPath
      return $ precompiledDir </> shortPkg </> shortHash
  else
      return longPath

-- | Write out information about a newly built package
writePrecompiledCache :: HasEnvConfig env
                      => BaseConfigOpts
                      -> PackageLocationImmutable
                      -> ConfigureOpts
                      -> Set GhcPkgId -- ^ dependencies
                      -> Installed -- ^ library
                      -> [GhcPkgId] -- ^ sublibraries, in the GhcPkgId format
                      -> Set Text -- ^ executables
                      -> RIO env ()
writePrecompiledCache baseConfigOpts loc copts depIDs mghcPkgId sublibs exes = do
  file <- precompiledCacheFile loc copts depIDs
  ensureDir (parent file)
  ec <- view envConfigL
  let stackRootRelative = makeRelative (view stackRootL ec)
  mlibpath <- case mghcPkgId of
    Executable _ -> return Nothing
    Library _ ipid _ -> liftM Just $ pathFromPkgId stackRootRelative ipid
  sublibpaths <- mapM (pathFromPkgId stackRootRelative) sublibs
  exes' <- forM (Set.toList exes) $ \exe -> do
      name <- parseRelFile $ T.unpack exe
      relPath <- stackRootRelative $ bcoSnapInstallRoot baseConfigOpts </> bindirSuffix </> name
      return $ toFilePath relPath
  encodePrecompiledCache file PrecompiledCache
      { pcLibrary = mlibpath
      , pcSubLibs = sublibpaths
      , pcExes = exes'
      }
  where
    pathFromPkgId stackRootRelative ipid = do
      ipid' <- parseRelFile $ ghcPkgIdString ipid ++ ".conf"
      relPath <- stackRootRelative $ bcoSnapDB baseConfigOpts </> ipid'
      return $ toFilePath relPath

-- | Check the cache for a precompiled package matching the given
-- configuration.
readPrecompiledCache :: forall env. HasEnvConfig env
                     => PackageLocationImmutable -- ^ target package
                     -> ConfigureOpts
                     -> Set GhcPkgId -- ^ dependencies
                     -> RIO env (Maybe PrecompiledCache)
readPrecompiledCache loc copts depIDs = do
    file <- precompiledCacheFile loc copts depIDs
    mcache <- decodePrecompiledCache file
    maybe (pure Nothing) (fmap Just . mkAbs) mcache
  where
    -- Since commit ed9ccc08f327bad68dd2d09a1851ce0d055c0422,
    -- pcLibrary paths are stored as relative to the stack
    -- root. Therefore, we need to prepend the stack root when
    -- checking that the file exists. For the older cached paths, the
    -- file will contain an absolute path, which will make `stackRoot
    -- </>` a no-op.
    mkAbs :: PrecompiledCache -> RIO env PrecompiledCache
    mkAbs pc0 = do
      stackRoot <- view stackRootL
      let mkAbs' = (toFilePath stackRoot FP.</>)
      return PrecompiledCache
        { pcLibrary = mkAbs' <$> pcLibrary pc0
        , pcSubLibs = mkAbs' <$> pcSubLibs pc0
        , pcExes = mkAbs' <$> pcExes pc0
        }

-- | Check if a filesystem path is too long.
pathTooLong :: FilePath -> Bool
pathTooLong
  | osIsWindows = \path -> utf16StringLength path >= win32MaxPath
  | otherwise = const False
  where
    win32MaxPath = 260
    -- Calculate the length of a string in 16-bit units
    -- if it were converted to utf-16.
    utf16StringLength :: String -> Integer
    utf16StringLength = sum . map utf16CharLength
      where
        utf16CharLength c | ord c < 0x10000 = 1
                          | otherwise       = 2
