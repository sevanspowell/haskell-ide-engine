{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes   #-}
module Main where

import           Control.Concurrent.STM.TChan
import           Control.Monad
import           Control.Monad.STM
import           Data.Monoid                           ((<>))
import           Data.Version                          (showVersion)
import qualified GhcMod.Types                          as GM
import           Haskell.Ide.Engine.Dispatcher
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.Options
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.Transport.LspStdio
import           Haskell.Ide.Engine.Transport.JsonStdio
import qualified Language.Haskell.LSP.Core             as Core
import           Options.Applicative.Simple
import qualified Paths_haskell_ide_engine              as Meta
import           System.Directory
import           System.Environment
import qualified System.Log.Logger                     as L
import qualified System.Remote.Monitoring.Wai          as EKG

-- ---------------------------------------------------------------------
-- plugins

import           Haskell.Ide.Engine.Plugin.ApplyRefact
import           Haskell.Ide.Engine.Plugin.Brittany
import           Haskell.Ide.Engine.Plugin.Build
import           Haskell.Ide.Engine.Plugin.Base
import           Haskell.Ide.Engine.Plugin.Example2
import           Haskell.Ide.Engine.Plugin.GhcMod
import           Haskell.Ide.Engine.Plugin.HaRe
import           Haskell.Ide.Engine.Plugin.Hoogle
import           Haskell.Ide.Engine.Plugin.HsImport
import           Haskell.Ide.Engine.Plugin.Liquid
import           Haskell.Ide.Engine.Plugin.Package
import           Haskell.Ide.Engine.Plugin.Haddock
import           Haskell.Ide.Engine.Plugin.HfaAlign


-- ---------------------------------------------------------------------

-- | This will be read from a configuration, eventually
plugins :: Bool -> IdePlugins
plugins includeExamples = pluginDescToIdePlugins allPlugins
  where
    allPlugins = if includeExamples
                   then basePlugins ++ examplePlugins
                   else basePlugins
    basePlugins =
      [applyRefactDescriptor "applyrefact"
      ,baseDescriptor        "base"
      ,brittanyDescriptor    "brittany"
      ,buildPluginDescriptor "build"
      ,ghcmodDescriptor      "ghcmod"
      ,hareDescriptor        "hare"
      ,hoogleDescriptor      "hoogle"
      ,hsimportDescriptor    "hsimport"
      ,liquidDescriptor      "liquid"
      ,packageDescriptor     "package"
      ,haddockDescriptor     "haddock"
      ]
    examplePlugins =
      [example2Descriptor "eg2"
      ,hfaAlignDescriptor "hfaa"
      ]

-- ---------------------------------------------------------------------

main :: IO ()
main = do
    let
        numericVersion :: Parser (a -> a)
        numericVersion =
            infoOption
                (showVersion Meta.version)
                (long "numeric-version" <>
                 help "Show only version number")
        compiler :: Parser (a -> a)
        compiler =
            infoOption
                hieGhcDisplayVersion
                (long "compiler" <>
                 help "Show only compiler and version supported")
    -- Parse the options and run
    (global, ()) <-
        simpleOptions
            version
            "haskell-ide-engine - Provide a common engine to power any Haskell IDE"
            ""
            (numericVersion <*> compiler <*> globalOptsParser)
            empty

    run global

-- ---------------------------------------------------------------------

run :: GlobalOpts -> IO ()
run opts = do
  let mLogFileName = case optLogFile opts of
        Just f  -> Just f
        Nothing -> Nothing

      logLevel = if optDebugOn opts
                   then L.DEBUG
                   else L.INFO

  Core.setupLogger mLogFileName ["hie"] logLevel

  projGhcVersion <- getProjectGhcVersion
  when (projGhcVersion /= hieGhcVersion) $
    warningm $ "Mismatching GHC versions: Project is " ++ projGhcVersion
            ++ ", HIE is " ++ hieGhcVersion

  when (optEkg opts) $ do
    logm $ "Launching EKG server on port " ++ show (optEkgPort opts)
    void $ EKG.forkServer "localhost" (optEkgPort opts)

  origDir <- getCurrentDirectory

  maybe (pure ()) setCurrentDirectory $ projectRoot opts

  progName <- getProgName
  logm $  "Run entered for HIE(" ++ progName ++ ") " ++ version
  d <- getCurrentDirectory
  logm $ "Current directory:" ++ d

  let vomitOptions = GM.defaultOptions { GM.optOutput = oo { GM.ooptLogLevel = GM.GmVomit}}
      oo = GM.optOutput GM.defaultOptions
  let defaultOpts = if optGhcModVomit opts then vomitOptions else GM.defaultOptions
      -- Running HIE on projects with -Werror breaks most of the features since all warnings
      -- will be treated with the same severity of type errors. In order to offer a more useful
      -- experience, we make sure warnings are always reported as warnings by setting -Wwarn
      ghcModOptions = defaultOpts { GM.optGhcUserOptions = ["-Wwarn"] }

  when (optGhcModVomit opts) $
    logm "Enabling --vomit for ghc-mod. Output will be on stderr"

  when (optExamplePlugin opts) $
    logm "Enabling Example2 plugin, will insert constant diagnostics etc."

  let plugins' = plugins (optExamplePlugin opts)

  -- launch the dispatcher.
  if optJson opts then do
    pin <- atomically newTChan
    jsonStdioTransport (dispatcherP pin plugins' ghcModOptions) pin
  else do
    pin <- atomically newTChan
    lspStdioTransport (dispatcherP pin plugins' ghcModOptions) pin origDir plugins' (optCaptureFile opts)
