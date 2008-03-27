-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.Install
-- Copyright   :  Isaac Jones 2003-2004
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Explanation: Perform the \"@.\/setup install@\" and \"@.\/setup
-- copy@\" actions.  Move files into place based on the prefix
-- argument.

{- All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.Simple.Install (
	install,
  ) where

import Distribution.PackageDescription (
	PackageDescription(..), BuildInfo(..), Library(..),
	hasLibs, withLib, hasExes, withExe )
import Distribution.Package (Package(..))
import Distribution.Simple.LocalBuildInfo (
        LocalBuildInfo(..), InstallDirs(..), absoluteInstallDirs,
        substPathTemplate)
import Distribution.Simple.BuildPaths (haddockName, haddockPref)
import Distribution.Simple.Utils (createDirectoryIfMissingVerbose,
                                  copyFileVerbose, die, info, notice,
                                  copyDirectoryRecursiveVerbose)
import Distribution.Simple.Compiler
         ( CompilerFlavor(..), compilerFlavor )
import Distribution.Simple.Setup (CopyFlags(..), CopyDest(..), fromFlag)

import qualified Distribution.Simple.GHC  as GHC
import qualified Distribution.Simple.NHC  as NHC
import qualified Distribution.Simple.JHC  as JHC
import qualified Distribution.Simple.Hugs as Hugs

import Control.Monad (when, unless)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath(takeDirectory, (</>), isAbsolute)

import Distribution.Verbosity

-- |Perform the \"@.\/setup install@\" and \"@.\/setup copy@\"
-- actions.  Move files into place based on the prefix argument.  FIX:
-- nhc isn't implemented yet.

install :: PackageDescription -- ^information from the .cabal file
        -> LocalBuildInfo -- ^information from the configure step
        -> CopyFlags -- ^flags sent to copy or install
        -> IO ()
install pkg_descr lbi flags = do
  let verbosity = fromFlag (copyVerbosity flags)
      copydest  = fromFlag (copyDest' flags)
      InstallDirs {
         bindir     = binPref,
         libdir     = libPref,
         dynlibdir  = dynlibPref,
         datadir    = dataPref,
         progdir    = progPref,
         docdir     = docPref,
         htmldir    = htmlPref,
         haddockdir = interfacePref,
         includedir = incPref
      } = absoluteInstallDirs pkg_descr lbi copydest
      
      progPrefixPref = substPathTemplate pkg_descr lbi (progPrefix lbi)
      progSuffixPref = substPathTemplate pkg_descr lbi (progSuffix lbi)
  
  docExists <- doesDirectoryExist $ haddockPref pkg_descr
  info verbosity ("directory " ++ haddockPref pkg_descr ++
                  " does exist: " ++ show docExists)
  flip mapM_ (dataFiles pkg_descr) $ \ file -> do
      let dir = takeDirectory file
      createDirectoryIfMissingVerbose verbosity True (dataPref </> dir)
      copyFileVerbose verbosity file (dataPref </> file)
  when docExists $ do
      createDirectoryIfMissingVerbose verbosity True htmlPref
      copyDirectoryRecursiveVerbose verbosity (haddockPref pkg_descr) htmlPref
      -- setPermissionsRecursive [Read] htmlPref
      -- The haddock interface file actually already got installed
      -- in the recursive copy, but now we install it where we actually
      -- want it to be (normally the same place). We could remove the
      -- copy in htmlPref first.
      createDirectoryIfMissingVerbose verbosity True interfacePref
      copyFileVerbose verbosity
                      (haddockPref pkg_descr </> haddockName pkg_descr)
                      (interfacePref </> haddockName pkg_descr)

  let lfile = licenseFile pkg_descr
  unless (null lfile) $ do
    createDirectoryIfMissingVerbose verbosity True docPref
    copyFileVerbose verbosity lfile (docPref </> lfile)

  let buildPref = buildDir lbi
  when (hasLibs pkg_descr) $
    notice verbosity ("Installing: " ++ libPref)
  when (hasExes pkg_descr) $
    notice verbosity ("Installing: " ++ binPref)

  -- install include files for all compilers - they may be needed to compile
  -- haskell files (using the CPP extension)
  when (hasLibs pkg_descr) $ installIncludeFiles verbosity pkg_descr incPref

  case compilerFlavor (compiler lbi) of
     GHC  -> do withLib pkg_descr () $ \_ ->
                  GHC.installLib verbosity lbi libPref dynlibPref buildPref pkg_descr
                withExe pkg_descr $ \_ ->
		  GHC.installExe verbosity lbi binPref buildPref (progPrefixPref, progSuffixPref) pkg_descr
     JHC  -> do withLib pkg_descr () $ JHC.installLib verbosity libPref buildPref pkg_descr
                withExe pkg_descr $ JHC.installExe verbosity binPref buildPref (progPrefixPref, progSuffixPref) pkg_descr
     Hugs -> do
       let targetProgPref = progdir (absoluteInstallDirs pkg_descr lbi NoCopyDest)
       let scratchPref = scratchDir lbi
       Hugs.install verbosity libPref progPref binPref targetProgPref scratchPref (progPrefixPref, progSuffixPref) pkg_descr
     NHC  -> do withLib pkg_descr () $ NHC.installLib verbosity libPref buildPref (packageId pkg_descr)
                withExe pkg_descr $ NHC.installExe verbosity binPref buildPref (progPrefixPref, progSuffixPref)
     _    -> die ("only installing with GHC, JHC, Hugs or nhc98 is implemented")
  return ()
  -- register step should be performed by caller.

-- | Install the files listed in install-includes
installIncludeFiles :: Verbosity -> PackageDescription -> FilePath -> IO ()
installIncludeFiles verbosity PackageDescription{library=Just l} incdir
 = do
   incs <- mapM (findInc relincdirs) (installIncludes lbi)
   unless (null incs) $ do
     createDirectoryIfMissingVerbose verbosity True incdir
     sequence_ [ copyFileVerbose verbosity path (incdir </> f)
	       | (f,path) <- incs ]
  where
   relincdirs = "." : filter (not.isAbsolute) (includeDirs lbi)
   lbi = libBuildInfo l

   findInc [] f = die ("can't find include file " ++ f)
   findInc (d:ds) f = do
     let path = (d </> f)
     b <- doesFileExist path
     if b then return (f,path) else findInc ds f
installIncludeFiles _ _ _ = die "installIncludeFiles: Can't happen?"
