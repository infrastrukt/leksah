{-# LANGUAGE CPP, ForeignFunctionInterface #-}
{-# OPTIONS_GHC -XScopedTypeVariables #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Package
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
--
-- | The packages methods of ide.
--
---------------------------------------------------------------------------------

module IDE.Package (
    packageConfig
,   packageConfig'
,   buildPackage

,   packageDoc
,   packageClean
,   packageClean'
,   packageCopy
,   packageCopy'
,   packageRun
,   activatePackage
,   deactivatePackage

,   packageInstallDependencies
,   packageRegister
,   packageRegister'
,   packageTest
,   packageTest'
,   packageSdist
,   packageOpenDoc

,   getPackageDescriptionAndPath
,   getEmptyModuleTemplate
,   getModuleTemplate
,   addModuleToPackageDescr
,   delModuleFromPackageDescr

,   backgroundBuildToggled
,   runUnitTestsToggled
,   makeModeToggled

,   debugStart
,   printBindResultFlag
,   breakOnErrorFlag
,   breakOnExceptionFlag

,   printEvldWithShowFlag
,   tryDebug
,   tryDebugQuiet
,   executeDebugCommand

,   choosePackageFile

,   idePackageFromPath

) where

import Graphics.UI.Gtk
import Distribution.Package hiding (depends,packageId)
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse
import Distribution.PackageDescription.Configuration
import Distribution.Verbosity
import System.FilePath
import Control.Concurrent
import System.Directory (setCurrentDirectory, doesFileExist)
import Prelude hiding (catch)
import Data.Maybe (isNothing, isJust, fromJust)
import Control.Exception (SomeException(..), catch)
import Paths_leksah

import IDE.Core.State
import IDE.Utils.GUIUtils
import IDE.Pane.PackageEditor
import IDE.Pane.SourceBuffer
import IDE.Pane.PackageFlags (readFlags)
import Distribution.Text (display)
import IDE.Utils.FileUtils(getConfigFilePathForLoad)
import IDE.LogRef
import MyMissing (replace)
import Distribution.ModuleName (ModuleName(..))
import Data.List (isInfixOf, nub, foldl', delete)
import qualified System.IO.UTF8 as UTF8  (readFile)
import IDE.Utils.Tool (ToolOutput(..), runTool, newGhci, ToolState(..))
import qualified Data.Set as  Set (fromList)
import qualified Data.Map as  Map (empty, fromList)
import System.Exit (ExitCode(..))
import Control.Applicative ((<$>))
import IDE.Utils.Tool (executeGhciCommand, getProcessExitCode, interruptProcessGroupOf)
import qualified Data.Enumerator as E (run_, Iteratee(..), last)
import qualified Data.Enumerator.List as EL (foldM, zip3, zip)
import Data.Enumerator (($$))
import Control.Monad.Trans.Reader (ask)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Class (lift)
import Control.Monad (when, unless, liftM)
#if MIN_VERSION_Cabal(1,10,0)
import Distribution.PackageDescription.PrettyPrintCopied
       (writeGenericPackageDescription)
#endif
import Debug.Trace (trace)

moduleInfo :: (a -> BuildInfo) -> (a -> [ModuleName]) -> a -> [(ModuleName, BuildInfo)]
moduleInfo bi mods a = map (\m -> (m, buildInfo)) $ mods a
    where buildInfo = bi a

#if MIN_VERSION_Cabal(1,8,0)
myLibModules pd = case library pd of
                    Nothing -> []
                    Just l -> moduleInfo libBuildInfo libModules l
myExeModules pd = concatMap (moduleInfo buildInfo exeModules) (executables pd)
#else
myLibModules pd = moduleInfo libModules libBuildInfo pd
myExeModules pd = moduleInfo exeModules buildInfo pd
#endif


packageOpen :: IDEAction
packageOpen = packageOpenThis Nothing

packageOpenThis :: Maybe FilePath -> IDEAction
packageOpenThis mbFilePath = do
    active <- readIDE activePack
    case active of
        Just p -> deactivatePackage
        Nothing -> return ()
    selectActivePackage mbFilePath
    return ()

selectActivePackage :: Maybe FilePath -> IDEM (Maybe IDEPackage)
selectActivePackage mbFilePath' = do
    window     <- getMainWindow
    mbFilePath <- case mbFilePath' of
                    Nothing -> liftIO $ choosePackageFile  window Nothing
                    Just fp -> return (Just fp)
    case mbFilePath of
        Nothing -> return Nothing
        Just filePath -> idePackageFromPath filePath >>= (\ p -> activatePackage p >> return p)

activatePackage :: Maybe IDEPackage -> IDEM ()
activatePackage mbPack@(Just pack) = do
        modifyIDE_ (\ide -> ide{activePack = mbPack})
        liftIO $ setCurrentDirectory (dropFileName (ipdCabalFile pack))
        triggerEventIDE (Sensitivity [(SensitivityProjectActive,True)])
        mbWs <- readIDE workspace
        let wsStr = case mbWs of
                Nothing -> ""
                Just ws -> wsName ws
        let txt = wsStr ++ " > " ++ packageIdentifierToString (ipdPackageId pack)
        triggerEventIDE (StatusbarChanged [CompartmentPackage txt])
        return ()
activatePackage Nothing = return ()

deactivatePackage :: IDEAction
deactivatePackage = do
    oldActivePack <- readIDE activePack
    modifyIDE_ (\ide -> ide{activePack = Nothing})
    when (isJust oldActivePack) $ do
        triggerEventIDE (Sensitivity [(SensitivityProjectActive,False)])
        return ()
    mbWs <- readIDE workspace
    let wsStr = case mbWs of
                    Nothing -> ""
                    Just ws -> wsName ws
    let txt = wsStr ++ ":"
    triggerEventIDE (StatusbarChanged [CompartmentPackage txt])
    return ()

packageConfig :: PackageAction
packageConfig = do
    package <- ask
    lift $ packageConfig' package (\ _ -> return ())

packageConfig'  :: IDEPackage -> (Bool -> IDEAction) -> IDEAction
packageConfig' package continuation = do
    let dir = dropFileName (ipdCabalFile package)
    runExternalTool "Configuring" "cabal" (["configure"]
                                    ++ (ipdConfigFlags package)) (Just dir) $ do
        (mbLastOutput, _) <- EL.zip E.last logOutput
        lift $ do
            mbPack <- idePackageFromPath (ipdCabalFile package)
            case mbPack of
                Just pack -> do
                    changePackage pack
                    triggerEventIDE (WorkspaceChanged False True)
                    continuation (mbLastOutput == Just (ToolExit ExitSuccess))
                    return ()
                Nothing -> do
                    ideMessage Normal "Can't read package file"
                    continuation False
                    return()

runCabalBuild :: Bool -> Bool -> Bool -> IDEPackage -> Bool -> (Bool -> IDEAction) -> IDEAction
runCabalBuild backgroundBuild jumpToWarnings withoutLinking package shallConfigure continuation = do
    prefs <- readIDE prefs
    let dir =  dropFileName (ipdCabalFile package)
    let args = (["build"] ++
                if backgroundBuild && withoutLinking
                    then ["--with-ld=false"]
                    else []
                        ++ ipdBuildFlags package)
    runExternalTool "Building" "cabal" args (Just dir) $ do
        (mbLastOutput, isConfigErr, _) <- EL.zip3 E.last isConfigError $
            logOutputForBuild package backgroundBuild jumpToWarnings
        lift $ do
            errs <- readIDE errorRefs
            if shallConfigure && isConfigErr
                then
                    packageConfig' package (\ b ->
                        when b $ runCabalBuild backgroundBuild jumpToWarnings withoutLinking package False continuation)
                else do
                    continuation (mbLastOutput == Just (ToolExit ExitSuccess))
                    return ()

isConfigError :: Monad m => E.Iteratee ToolOutput m Bool
isConfigError = EL.foldM (\a b -> return $ a || isCErr b) False
    where
    isCErr (ToolError str) = str1 `isInfixOf` str || str2 `isInfixOf` str || str3 `isInfixOf` str
    isCErr _ = False
    str1 = "Run the 'configure' command first"
    str2 = "please re-configure"
    str3 = "cannot satisfy -package-id"

buildPackage :: Bool -> Bool -> Bool -> IDEPackage -> (Bool -> IDEAction) -> IDEAction
buildPackage backgroundBuild jumpToWarnings withoutLinking package continuation = catchIDE (do
    ideR      <- ask
    prefs     <- readIDE prefs
    maybeDebug <- readIDE debugState
    case maybeDebug of
        Nothing -> do
            alreadyRunning <- isRunning
            if alreadyRunning
                then do
                    interruptBuild
                    when (not backgroundBuild) $ liftIO $ do
                        timeoutAddFull (do
                            reflectIDE (do
                                buildPackage backgroundBuild jumpToWarnings withoutLinking
                                                package continuation
                                return False) ideR
                            return False) priorityDefaultIdle 1000
                        return ()
                else runCabalBuild backgroundBuild jumpToWarnings withoutLinking package True continuation
        Just debug@(_, ghci) -> do
            -- TODO check debug package matches active package
            ready <- liftIO $ isEmptyMVar (currentToolCommand ghci)
            when ready $ do
                let dir = dropFileName (ipdCabalFile package)
                when (saveAllBeforeBuild prefs) (do fileSaveAll belongsToWorkspace; return ())
                (`runDebug` debug) . executeDebugCommand ":reload" $ do
                    errs <- logOutputForBuild package backgroundBuild jumpToWarnings
                    when (null errs) $ do
                        cmd <- lift $ readIDE autoCommand
                        liftIO . postGUISync $ reflectIDE cmd ideR
    )
    (\(e :: SomeException) -> sysMessage Normal (show e))

packageDoc :: PackageAction
packageDoc = do
    package <- ask
    lift $ catchIDE (do
        let dir = dropFileName (ipdCabalFile package)
        runExternalTool "Documenting" "cabal" (["haddock"]
                        ++ (ipdHaddockFlags package)) (Just dir) logOutput)
        (\(e :: SomeException) -> putStrLn (show e))

packageClean :: PackageAction
packageClean = do
    package <- ask
    lift $ packageClean' package (\ _ -> return ())

packageClean' :: IDEPackage -> (Bool -> IDEAction) -> IDEAction
packageClean' package continuation = do
    let dir = dropFileName (ipdCabalFile package)
    runExternalTool "Cleaning" "cabal" ["clean"] (Just dir) $ do
        (mbLastOutput, _) <- EL.zip E.last logOutput
        lift $ continuation (mbLastOutput == Just (ToolExit ExitSuccess))

packageCopy :: PackageAction
packageCopy = do
    package <- ask
    lift $ catchIDE (do
        window      <- getMainWindow
        mbDir       <- liftIO $ chooseDir window "Select the target directory" Nothing
        case mbDir of
            Nothing -> return ()
            Just fp -> do
                let dir = dropFileName (ipdCabalFile package)
                runExternalTool "Copying" "cabal" (["copy"]
                           ++ ["--destdir=" ++ fp]) (Just dir) logOutput)
        (\(e :: SomeException) -> putStrLn (show e))

packageInstallDependencies :: PackageAction
packageInstallDependencies = do
    package <- ask
    lift $ catchIDE (do
        let dir = dropFileName (ipdCabalFile package)
        runExternalTool "Installing" "cabal" (["install","--only-dependencies"]
            ++ (ipdConfigFlags package)
            ++ (ipdInstallFlags package)) (Just dir) logOutput)
        (\(e :: SomeException) -> putStrLn (show e))

packageCopy' :: IDEPackage -> (Bool -> IDEAction) -> IDEAction
packageCopy' package continuation = do
    catchIDE (do
        let dir = dropFileName (ipdCabalFile package)
        runExternalTool "Copying" "cabal" (["copy"]
            ++ (ipdInstallFlags package)) (Just dir) $ do
                (mbLastOutput, _) <- EL.zip E.last logOutput
                lift $ continuation (mbLastOutput == Just (ToolExit ExitSuccess)))
        (\(e :: SomeException) -> putStrLn (show e))

packageRun :: PackageAction
packageRun = do
    package <- ask
    lift $ catchIDE (do
        ideR        <- ask
        maybeDebug   <- readIDE debugState
        pd <- liftIO $ readPackageDescription normal (ipdCabalFile package) >>= return . flattenPackageDescription
        case maybeDebug of
            Nothing -> do
                case executables pd of
                    (Executable name _ _):_ -> do
                        let path = "dist/build" </> name </> name
                        let dir = dropFileName (ipdCabalFile package)
                        runExternalTool ("Running " ++ name) path (ipdExeFlags package) (Just dir) logOutput
                    otherwise -> do
                        sysMessage Normal "no executable in selected package"
                        return ()
            Just debug -> do
                -- TODO check debug package matches active package
                case executables pd of
                    (Executable _ mainFilePath _):_ -> do
                        runDebug (do
                            executeDebugCommand (":module *" ++ (map (\c -> if c == '/' then '.' else c) (takeWhile (/= '.') mainFilePath))) logOutput
                            executeDebugCommand (":main " ++ (unwords (ipdExeFlags package))) logOutput) debug
                    otherwise -> do
                        sysMessage Normal "no executable in selected package"
                        return ())
        (\(e :: SomeException) -> putStrLn (show e))

packageRegister :: PackageAction
packageRegister = do
    package <- ask
    lift $ packageRegister' package (\ _ -> return ())

packageRegister' :: IDEPackage -> (Bool -> IDEAction) -> IDEAction
packageRegister' package continuation =
    if ipdHasLibs package
        then catchIDE (do
            let dir = dropFileName (ipdCabalFile package)
            runExternalTool "Registering" "cabal" (["register"]
                ++ (ipdRegisterFlags package)) (Just dir) $ do
                    (mbLastOutput, _) <- EL.zip E.last logOutput
                    lift $ continuation (mbLastOutput == Just (ToolExit ExitSuccess)))
            (\(e :: SomeException) -> putStrLn (show e))
        else continuation True

packageTest :: PackageAction
packageTest = do
    package <- ask
    lift $ packageTest' package (\ _ -> return ())

packageTest' :: IDEPackage -> (Bool -> IDEAction) -> IDEAction
packageTest' package continuation =
    if "--enable-tests" `elem` ipdConfigFlags package
        then catchIDE (do
            let dir = dropFileName (ipdCabalFile package)
            runExternalTool "Testing" "cabal" (["test"]
                ++ (ipdTestFlags package)) (Just dir) $ do
                    (mbLastOutput, _) <- EL.zip E.last logOutput
                    lift $ continuation (mbLastOutput == Just (ToolExit ExitSuccess)))
            (\(e :: SomeException) -> putStrLn (show e))
        else continuation True

packageSdist :: PackageAction
packageSdist = do
    package <- ask
    lift $ catchIDE (do
        let dir = dropFileName (ipdCabalFile package)
        runExternalTool "Source Dist" "cabal" (["sdist"]
                        ++ (ipdSdistFlags package)) (Just dir) logOutput)
        (\(e :: SomeException) -> putStrLn (show e))


packageOpenDoc :: PackageAction
packageOpenDoc = do
    package <- ask
    lift $ catchIDE (do
        prefs   <- readIDE prefs
        let path = dropFileName (ipdCabalFile package)
                        </> "dist/doc/html"
                        </> display (pkgName (ipdPackageId package))
                        </> "index.html"
            dir = dropFileName (ipdCabalFile package)
        runExternalTool "Opening Documentation" (browser prefs) [path] (Just dir) logOutput)
        (\(e :: SomeException) -> putStrLn (show e))

runExternalTool :: String -> FilePath -> [String] -> Maybe FilePath -> E.Iteratee ToolOutput IDEM () -> IDEAction
runExternalTool description executable args mbDir handleOutput = do
    prefs          <- readIDE prefs
    alreadyRunning <- isRunning
    unless alreadyRunning $ do
        when (saveAllBeforeBuild prefs) (do fileSaveAll belongsToWorkspace; return ())
        triggerEventIDE (StatusbarChanged [CompartmentState description, CompartmentBuild True])
        reifyIDE $ \ideR -> forkIO $ do
            (output, pid) <- runTool executable args mbDir
            reflectIDE (modifyIDE_ (\ide -> ide{runningTool = Just pid})) ideR
            E.run_ $ output $$ (reflectIDEI handleOutput ideR)
        return ()


-- ---------------------------------------------------------------------
-- | Handling of Compiler errors
--
isRunning :: IDEM Bool
isRunning = do
    maybeProcess <- readIDE runningTool
    liftIO $ do
        case maybeProcess of
            Just process -> do
                isNothing <$> getProcessExitCode process
            Nothing -> return False

interruptBuild :: IDEAction
interruptBuild = do
    maybeProcess <- readIDE runningTool
    liftIO $ case maybeProcess of
        Just h -> interruptProcessGroupOf h
        _ -> return ()

-- ---------------------------------------------------------------------
-- | * Utility functions/procedures, that have to do with packages
--

getPackageDescriptionAndPath :: IDEM (Maybe (PackageDescription,FilePath))
getPackageDescriptionAndPath = do
    active <- readIDE activePack
    case active of
        Nothing -> do
            ideMessage Normal "No active package"
            return Nothing
        Just p  -> do
            ideR <- ask
            reifyIDE (\ideR -> catch (do
                pd <- readPackageDescription normal (ipdCabalFile p)
                return (Just (flattenPackageDescription pd,ipdCabalFile p)))
                    (\(e :: SomeException) -> do
                        reflectIDE (ideMessage Normal ("Can't load package " ++(show e))) ideR
                        return Nothing))

getEmptyModuleTemplate :: PackageDescription -> String -> IO String
getEmptyModuleTemplate pd modName = getModuleTemplate "module" pd modName "" ""

getModuleTemplate :: String -> PackageDescription -> String -> String -> String -> IO String
getModuleTemplate template pd modName exports body = catch (do
    dataDir  <- getDataDir
    filePath <- getConfigFilePathForLoad (template ++ leksahTemplateFileExtension) Nothing dataDir
    template <- UTF8.readFile filePath
    return (foldl' (\ a (from, to) -> replace from to a) template
        [   ("@License@"      , (show . license) pd)
        ,   ("@Maintainer@"   , maintainer pd)
        ,   ("@Stability@"    , stability pd)
        ,   ("@Portability@"  , "")
        ,   ("@Copyright@"    , copyright pd)
        ,   ("@ModuleName@"   , modName)
        ,   ("@ModuleExports@", exports)
        ,   ("@ModuleBody@"   , body)]))
                    (\ (e :: SomeException) -> sysMessage Normal ("Couldn't read template file: " ++ show e) >> return "")

#if MIN_VERSION_Cabal(1,10,0)
addModuleToPackageDescr :: ModuleName -> Bool -> PackageAction
addModuleToPackageDescr moduleName isExposed = do
    p    <- ask
    lift $ reifyIDE (\ideR -> catch (do
        gpd <- readPackageDescription normal (ipdCabalFile p)
        let npd = if isExposed && isJust (condLibrary gpd)
                then gpd{
                    condLibrary = Just (addModToLib moduleName
                                                (fromJust (condLibrary gpd))),
                    condExecutables = map (addModToBuildInfoExe moduleName)
                                            (condExecutables gpd)}
                else gpd{
                    condLibrary = case condLibrary gpd of
                                    Nothing -> Nothing
                                    Just lib -> Just (addModToBuildInfoLib moduleName
                                                       (fromJust (condLibrary gpd))),
                    condExecutables = map (addModToBuildInfoExe moduleName)
                                                (condExecutables gpd)}
        writeGenericPackageDescription (ipdCabalFile p) npd)
           (\(e :: SomeException) -> do
            reflectIDE (ideMessage Normal ("Can't update package " ++ show e)) ideR
            return ()))

addModToLib :: ModuleName -> CondTree ConfVar [Dependency] Library ->
    CondTree ConfVar [Dependency] Library
addModToLib modName ct@CondNode{condTreeData = lib} =
    ct{condTreeData = lib{exposedModules = modName : exposedModules lib}}

addModToBuildInfoLib :: ModuleName -> CondTree ConfVar [Dependency] Library ->
    CondTree ConfVar [Dependency] Library
addModToBuildInfoLib modName ct@CondNode{condTreeData = lib} =
    ct{condTreeData = lib{libBuildInfo = (libBuildInfo lib){otherModules = modName
        : otherModules (libBuildInfo lib)}}}

addModToBuildInfoExe :: ModuleName -> (String, CondTree ConfVar [Dependency] Executable) ->
    (String, CondTree ConfVar [Dependency] Executable)
addModToBuildInfoExe modName (str,ct@CondNode{condTreeData = exe}) =
    (str, ct{condTreeData = exe{buildInfo = (buildInfo exe){otherModules = modName
        : otherModules (buildInfo exe)}}})

--------------------------------------------------------------------------
delModuleFromPackageDescr :: ModuleName -> PackageAction
delModuleFromPackageDescr moduleName = trace ("addModule " ++ show moduleName) $ do
    p    <- ask
    lift $ reifyIDE (\ideR -> catch (do
        gpd <- readPackageDescription normal (ipdCabalFile p)
        let isExposedAndJust = isExposedModule moduleName (condLibrary gpd)
        let npd = if isExposedAndJust
                then gpd{
                    condLibrary = Just (delModFromLib moduleName
                                                (fromJust (condLibrary gpd))),
                    condExecutables = map (delModFromBuildInfoExe moduleName)
                                            (condExecutables gpd)}
                else gpd{
                    condLibrary = case condLibrary gpd of
                                    Nothing -> Nothing
                                    Just lib -> Just (delModFromBuildInfoLib moduleName
                                                       (fromJust (condLibrary gpd))),
                    condExecutables = map (delModFromBuildInfoExe moduleName)
                                                (condExecutables gpd)}
        writeGenericPackageDescription (ipdCabalFile p) npd)
           (\(e :: SomeException) -> do
            reflectIDE (ideMessage Normal ("Can't update package " ++ show e)) ideR
            return ()))

delModFromLib :: ModuleName -> CondTree ConfVar [Dependency] Library ->
    CondTree ConfVar [Dependency] Library
delModFromLib modName ct@CondNode{condTreeData = lib} =
    ct{condTreeData = lib{exposedModules = delete modName (exposedModules lib)}}

delModFromBuildInfoLib :: ModuleName -> CondTree ConfVar [Dependency] Library ->
    CondTree ConfVar [Dependency] Library
delModFromBuildInfoLib modName ct@CondNode{condTreeData = lib} =
    ct{condTreeData = lib{libBuildInfo = (libBuildInfo lib){otherModules =
        delete modName (otherModules (libBuildInfo lib))}}}

delModFromBuildInfoExe :: ModuleName -> (String, CondTree ConfVar [Dependency] Executable) ->
    (String, CondTree ConfVar [Dependency] Executable)
delModFromBuildInfoExe modName (str,ct@CondNode{condTreeData = exe}) =
    (str, ct{condTreeData = exe{buildInfo = (buildInfo exe){otherModules =
        delete modName (otherModules (buildInfo exe))}}})

isExposedModule :: ModuleName -> Maybe (CondTree ConfVar [Dependency] Library)  -> Bool
isExposedModule mn Nothing                             = False
isExposedModule mn (Just CondNode{condTreeData = lib}) = elem mn (exposedModules lib)

#else
-- Old version to support older Cabal
addModuleToPackageDescr :: ModuleName -> Bool -> PackageAction
addModuleToPackageDescr moduleName isExposed = do
    p    <- ask
    lift $ reifyIDE (\ideR -> catch (do
        gpd <- readPackageDescription normal (ipdCabalFile p)
        if hasConfigs gpd
            then do
                reflectIDE (ideMessage High
                    "Cabal file with configurations can't be automatically updated with the current version of Leksah") ideR
            else
                let pd = flattenPackageDescription gpd
                    npd = if isExposed && isJust (library pd)
                            then pd{library = Just ((fromJust (library pd)){exposedModules =
                                                            moduleName : exposedModules (fromJust $ library pd)})}
                            else let npd1 = case library pd of
                                               Nothing -> pd
                                               Just lib -> pd{library = Just (lib{libBuildInfo =
                                                        addModToBuildInfo (libBuildInfo lib) moduleName})}
                               in npd1{executables = map
                                        (\exe -> exe{buildInfo = addModToBuildInfo (buildInfo exe) moduleName})
                                            (executables npd1)}
                in writePackageDescription (ipdCabalFile p) npd)
                   (\(e :: SomeException) -> do
                    reflectIDE (ideMessage Normal ("Can't upade package " ++ show e)) ideR
                    return ()))
    where
    addModToBuildInfo :: BuildInfo -> ModuleName -> BuildInfo
    addModToBuildInfo bi mn = bi {otherModules = mn : otherModules bi}

-- Old version to support older Cabal
delModuleFromPackageDescr :: ModuleName -> PackageAction
delModuleFromPackageDescr moduleName = do
    p    <- ask
    lift $ reifyIDE (\ideR -> catch (do
        gpd <- readPackageDescription normal (ipdCabalFile p)
        if hasConfigs gpd
            then do
                reflectIDE (ideMessage High
                    "Cabal file with configurations can't be automatically updated with the current version of Leksah") ideR
            else
                let pd = flattenPackageDescription gpd
                    isExposedAndJust = isExposedModule pd moduleName
                    npd = if isExposedAndJust
                            then pd{library = Just ((fromJust (library pd)){exposedModules =
                                                             delete moduleName (exposedModules (fromJust $ library pd))})}
                            else let npd1 = case library pd of
                                               Nothing -> pd
                                               Just lib -> pd{library = Just (lib{libBuildInfo =
                                                        delModFromBuildInfo (libBuildInfo lib) moduleName})}
                               in npd1{executables = map
                                        (\exe -> exe{buildInfo = delModFromBuildInfo (buildInfo exe) moduleName})
                                            (executables npd1)}
                in writePackageDescription (ipdCabalFile p) npd)
                   (\(e :: SomeException) -> do
                    reflectIDE (ideMessage Normal ("Can't update package " ++ show e)) ideR
                    return ()))
    where
    delModFromBuildInfo :: BuildInfo -> ModuleName -> BuildInfo
    delModFromBuildInfo bi mn = bi {otherModules = delete mn (otherModules bi)}

-- Old version to support older Cabal
isExposedModule :: PackageDescription -> ModuleName -> Bool
isExposedModule pd mn = do
    if isJust (library pd)
        then elem mn (exposedModules (fromJust $ library pd))
        else False
#endif

backgroundBuildToggled :: IDEAction
backgroundBuildToggled = do
    toggled <- getBackgroundBuildToggled
    modifyIDE_ (\ide -> ide{prefs = (prefs ide){backgroundBuild= toggled}})

runUnitTestsToggled :: IDEAction
runUnitTestsToggled = do
    toggled <- getRunUnitTests
    modifyIDE_ (\ide -> ide{prefs = (prefs ide){runUnitTests= toggled}})

makeModeToggled :: IDEAction
makeModeToggled = do
    toggled <- getMakeModeToggled
    modifyIDE_ (\ide -> ide{prefs = (prefs ide){makeMode= toggled}})

-- ---------------------------------------------------------------------
-- | * Debug code that needs to use the package
--

interactiveFlag :: String -> Bool -> String
interactiveFlag name f = (if f then "-f" else "-fno-") ++ name

printEvldWithShowFlag :: Bool -> String
printEvldWithShowFlag = interactiveFlag "print-evld-with-show"

breakOnExceptionFlag :: Bool -> String
breakOnExceptionFlag = interactiveFlag "break-on-exception"

breakOnErrorFlag :: Bool -> String
breakOnErrorFlag = interactiveFlag "break-on-error"

printBindResultFlag :: Bool -> String
printBindResultFlag = interactiveFlag "print-bind-result"

interactiveFlags :: Prefs -> [String]
interactiveFlags prefs =
    (printEvldWithShowFlag $ printEvldWithShow prefs)
    : (breakOnExceptionFlag $ breakOnException prefs)
    : (breakOnErrorFlag $ breakOnError prefs)
    : [printBindResultFlag $ printBindResult prefs]

debugStart :: PackageAction
debugStart = do
    package   <- ask
    lift $ catchIDE (do
        ideRef     <- ask
        prefs'     <- readIDE prefs
        maybeDebug <- readIDE debugState
        case maybeDebug of
            Nothing -> do
                ghci <- reifyIDE $ \ideR -> newGhci (ipdBuildFlags package) (interactiveFlags prefs')
                    $ reflectIDEI (logOutputForBuild package True False >> return ()) ideR
                modifyIDE_ (\ide -> ide {debugState = Just (package, ghci)})
                triggerEventIDE (Sensitivity [(SensitivityInterpreting, True)])
                setDebugToggled True
                -- Fork a thread to wait for the output from the process to close
                liftIO $ forkIO $ do
                    readMVar (outputClosed ghci)
                    postGUISync $ reflectIDE (do
                        setDebugToggled False
                        modifyIDE_ (\ide -> ide {debugState = Nothing, autoCommand = return ()})
                        triggerEventIDE (Sensitivity [(SensitivityInterpreting, False)])
                        -- Kick of a build if one is not already due
                        modifiedPacks <- fileCheckAll belongsToPackage
                        let modified = not (null modifiedPacks)
                        prefs <- readIDE prefs
                        when ((not modified) && (backgroundBuild prefs)) $ do
                            -- So although none of the pakages are modified,
                            -- they may have been modified in ghci mode.
                            -- Lets build to make sure the binaries are up to date
                            mbPackage   <- readIDE activePack
                            case mbPackage of
                                Just package -> runCabalBuild True False True package True (\ _ -> return ())
                                Nothing -> return ()) ideRef
                return ()
            _ -> do
                sysMessage Normal "Debugger already running"
                return ())
            (\(e :: SomeException) -> putStrLn (show e))

tryDebug :: DebugAction -> PackageAction
tryDebug f = do
    maybeDebug <- lift $ readIDE debugState
    case maybeDebug of
        Just debug -> do
            -- TODO check debug package matches active package
            lift $ runDebug f debug
        _ -> do
            window <- lift $ getMainWindow
            resp <- liftIO $ do
                md <- messageDialogNew (Just window) [] MessageQuestion ButtonsCancel
                        "GHCi debugger is not running."
                dialogAddButton md "_Start GHCi" (ResponseUser 1)
                dialogSetDefaultResponse md (ResponseUser 1)
                set md [ windowWindowPosition := WinPosCenterOnParent ]
                resp <- dialogRun md
                widgetDestroy md
                return resp
            case resp of
                ResponseUser 1 -> do
                    debugStart
                    maybeDebug <- lift $ readIDE debugState
                    case maybeDebug of
                        Just debug -> lift $ postAsyncIDE $ runDebug f debug
                        _ -> return ()
                _  -> return ()

tryDebugQuiet :: DebugAction -> PackageAction
tryDebugQuiet f = do
    maybeDebug <- lift $ readIDE debugState
    case maybeDebug of
        Just debug -> do
            -- TODO check debug package matches active package
            lift $ runDebug f debug
        _ -> do
            return ()

executeDebugCommand :: String -> (E.Iteratee ToolOutput IDEM ()) -> DebugAction
executeDebugCommand command handler = do
    (_, ghci) <- ask
    lift $ do
        reifyIDE $ \ideR -> do
            liftIO $ postGUIAsync $ reflectIDE (do
                triggerEventIDE (StatusbarChanged [CompartmentState command, CompartmentBuild True])
                return ()) ideR
            executeGhciCommand ghci command $ do
                reflectIDEI handler ideR
                liftIO $ postGUIAsync $ reflectIDE (do
                    triggerEventIDE (StatusbarChanged [CompartmentState "", CompartmentBuild False])
                    return ()) ideR
                return ()

allBuildInfo' :: PackageDescription -> [BuildInfo]
#if MIN_VERSION_Cabal(1,10,0)
allBuildInfo' pkg_descr = [ libBuildInfo lib  | Just lib <- [library pkg_descr] ]
                       ++ [ buildInfo exe     | exe <- executables pkg_descr ]
                       ++ [ testBuildInfo tst | tst <- testSuites pkg_descr ]
#else
allBuildInfo' = allBuildInfo
#endif

idePackageFromPath :: FilePath -> IDEM (Maybe IDEPackage)
idePackageFromPath filePath = do
    mbPackageD <- reifyIDE (\ideR -> catch (do
        pd <- readPackageDescription normal filePath
        return (Just (flattenPackageDescription pd)))
            (\ (e  :: SomeException) -> do
                reflectIDE (ideMessage Normal ("Can't activate package " ++(show e))) ideR
                return Nothing))
    case mbPackageD of
        Nothing       -> return Nothing
        Just packageD -> do
            let modules    = Map.fromList $ myLibModules packageD ++ myExeModules packageD
            let mainFiles  = [ (modulePath exe, buildInfo exe, False) | exe <- executables packageD ]
#if MIN_VERSION_Cabal(1,10,0)
                             ++ [ (f, bi, True) | TestSuite _ (TestSuiteExeV10 _ f) bi _ <- testSuites packageD ]
#endif
            let files      = Set.fromList $ extraSrcFiles packageD
            let srcDirs = case (nub $ concatMap hsSourceDirs (allBuildInfo' packageD)) of
                                [] -> [".","src"]
                                l -> l
#if MIN_VERSION_Cabal(1,10,0)
            let exts       = nub $ concatMap oldExtensions (allBuildInfo' packageD)
            let tests      = [ testName t | t <- testSuites packageD
                                          , buildable (testBuildInfo t) ]
#else
            let exts       = nub $ concatMap extensions (allBuildInfo' packageD)
            let tests      = []
#endif

            let packp      = IDEPackage {
                ipdPackageId = package packageD,
                ipdCabalFile = filePath,
                ipdDepends = buildDepends packageD,
                ipdModules = modules,
                ipdHasLibs = hasLibs packageD,
                ipdTests   = tests,
                ipdMain    = mainFiles,
                ipdExtraSrcs =  files,
                ipdSrcDirs = srcDirs,
                ipdExtensions =  exts,
                ipdConfigFlags = ["--user", "--enable-tests"],
                ipdBuildFlags = [],
                ipdTestFlags = [],
                ipdHaddockFlags = [],
                ipdExeFlags = [],
                ipdInstallFlags = [],
                ipdRegisterFlags = [],
                ipdUnregisterFlags = [],
                ipdSdistFlags = []}
            let pfile      = dropExtension filePath
            pack <- (do
                flagFileExists <- liftIO $ doesFileExist (pfile ++ leksahFlagFileExtension)
                if flagFileExists
                    then liftIO $ readFlags (pfile ++ leksahFlagFileExtension) packp
                    else return packp)
            return (Just pack)

