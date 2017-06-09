{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Internal.FileDB where

import           Control.Monad                 (filterM, when)
import           Control.Monad.IO.Class        (MonadIO, liftIO)
import           Data.Aeson                    (FromJSON, ToJSON, fromJSON,
                                                toJSON)
import qualified Data.Aeson                    as A
import qualified Data.ByteString               as BS
import qualified Data.ByteString.Char8         as BS8
import qualified Data.ByteString.Lazy          as BL
import           Data.FileEmbed                (embedDir)
import           Data.List                     (find, nub)
import           Data.Maybe                    (fromMaybe)
import           Data.Monoid                   ((<>))
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as T (decodeUtf8)
import qualified Data.Text.Lazy                as TL
import           Data.Yaml                     ((.:), (.:?), (.=))
import qualified Data.Yaml.Aeson               as Y
import           GHC.Generics
import           Prelude                       hiding (readFile)
import           System.FilePath.Posix         (joinPath, makeRelative,
                                                replaceExtension,
                                                splitDirectories,
                                                splitExtension, splitFileName)
import qualified System.IO.Error               as Error
import           Text.Blaze.Html.Renderer.Text (renderHtml)
import qualified Text.Blaze.Html5              as H
import qualified Text.Mustache                 as M
import qualified Web.Spock                     as Sp
-- nanpage imports
import           Internal.Helpers
import           Internal.HtmlOps              (getFirstImage,
                                                markdownToHtmlString,
                                                removeImages, transformHtml)
import qualified Internal.SpockExt             as Sp

import qualified Debug.Trace                   as Tr (trace, traceShowId)
--tr :: Show a => a -> a
--tr = Tr.traceShowId
tr' :: Show a => String -> a -> a
tr' s a = Tr.trace (s ++ " " ++ show a) a

{------------------------------ FileDB ----------------------------------------}

data FileDB = FileDB {
    pagesDir     :: String,
    templatesDir :: String,
    files        :: [(FilePath, BS.ByteString)],
    mode         :: Mode
}

-- | Mode can be PROD or ADMIN, representing deployment environments.
data Mode = PROD | ADMIN deriving (Read, Show, Eq)

-- | Return a FileDB record with default parameters
defaultFileDB :: FileDB
defaultFileDB = FileDB {
        pagesDir = "pages",
        templatesDir = "templates",
        files = embedAllFiles,
        mode = PROD
    }

-- | Embed all required files. Note that the paths are hardcoded relative paths
-- which has strong implications on project file structure.
embedAllFiles :: [(FilePath, BS.ByteString)]
embedAllFiles = prefixWith "pages" pages
    ++ prefixWith "templates" templates
    ++ static where
    prefixWith' p (p',c) = (joinPath [p,p'], c)
    prefixWith p = map (prefixWith' p)
    pages = $(embedDir "../content/pages")
    templates = $(embedDir "../content/templates")
    static = $(embedDir "../content/static")

-- | Normalize a directory name, i.e. replace double // by / etc.
normalizePath :: FilePath -> FilePath
normalizePath = joinPath . splitDirectories

-- | In files of FileDB find filenames with extension ext under dir
findFiles :: FileDB -> String -> FilePath -> [FilePath]
findFiles db ext dir = filter f ps where
    ps = fst <$> files db
    f p = n dir == n dir' && ext == ext' where
        n = normalizePath
        (dir', file) = splitFileName p
        ext' = (snd.splitExtension) file

-- | In files of FileDB find filenames with extension ext under dir
readFile :: FileDB -> FilePath -> BS.ByteString
readFile db p = case e_c of
    Nothing    -> error (p ++ " could not be found")
    Just (_,c) -> c
    where
        n = normalizePath
        e_c = find (\(p',_)->n p == n p') (files db)

-- | Test whether p1 is subdir of p2. The arguments are arranged such that
-- p1 `isSubDir` p2 tests naturally
isSubDir :: [FilePath] -> [FilePath] -> Bool
isSubDir p1 p2
    | l2 > l1 = False
    | take l2 p1 == p2 = True
    | otherwise = False
    where
        l1 = length p1
        l2 = length p2

-- | In files of FileDB find all the directories underneath the given path.
-- Full paths are returned.
getDirectories :: FileDB -> FilePath -> [FilePath]
getDirectories db = getDirectories' (map fst $ files db)

-- |Helper function that returns the unique elements in a list. Not efficient,
-- but ok for small lists.
unique :: Eq a => [a] -> [a]
unique = reverse . nub . reverse

-- | In list of paths find all the directories underneath the given path
-- (This is a helper function for getDirectories.)
getDirectories' :: [FilePath] -> FilePath -> [FilePath]
getDirectories' ps p' = map joinPath $ filter (`isSubDir` p) dirs where
    dirs = unique $ filter (not.null) $ map (init.splitDirectories) ps
    p = splitDirectories p'


{------------------------------ Template --------------------------------------}

-- | Load, compile and return the template with the given name.
getTemplate :: TemplateName -> FileDB -> M.Template
getTemplate tname db = case e_m of
        Left err -> error "getTemplate: compileMustacheText error"
        Right m  -> m
        where
            pname = M.PName $ T.pack tname
            content' = readFile db $ joinPath [templatesDir db, tname]
            content = TL.fromStrict $ T.decodeUtf8 content'
            e_m = M.compileMustacheText pname content

renderWithTemplate :: [(T.Text, A.Value)] -> TL.Text -> TL.Text
renderWithTemplate pairs t = case e_m of
    Left err -> error "renderWithTemplate: compileMustacheText error"
    Right m  -> M.renderMustache m (A.object pairs)
    where
        pname = M.PName "content"
        e_m = M.compileMustacheText pname t

{-------------------------------- PageConfig ----------------------------------}

data PageConfig = PageConfig {
    _title       :: TL.Text,        -- | Title of the page
    _slug        :: Maybe TL.Text,  -- | Slug of the page. If Nothing it will be deduced from the title
    _keywords    :: Maybe [TL.Text],  -- | Keywords of the page
    _tags        :: Maybe [TL.Text],  -- | Tags of the page
    _categories  :: Maybe [TL.Text],   -- | Categories of the page
    _description :: Maybe TL.Text,     -- | Description of the page
    _author      :: Maybe TL.Text
} deriving Show

instance FromJSON PageConfig where
    parseJSON (A.Object o) = PageConfig
        <$> o .:  "title"
        <*> o .:? "slug"    -- optional
        <*> o .:? "keywords"
        <*> o .:? "tags"
        <*> o .:? "categories"
        <*> o .:? "description"
        <*> o .:? "author"

instance ToJSON PageConfig where
      toJSON (PageConfig t s ks ts cs d a) = A.object
        ["title" .= t, "slug" .= s, "keywords" .= ks, "tags" .= ts,
         "categories" .= cs, "description" .= d, "author" .= a]
      toEncoding (PageConfig t s ks ts cs d a) = A.pairs
        ("title" .= t <> "slug" .= s <> "keywords" .= ks <> "tags" .= ts
         <> "categories" .= cs <> "description" .= d <> "author" .= a)

readPageConfig :: FileDB -> FilePath -> PageConfig
readPageConfig db fname = case Y.decodeEither content of
        Left err -> error err
        Right p  -> p
        where
            content = readFile db fname

keywordsString :: PageConfig -> TL.Text
keywordsString c = case _keywords c of
    Just ks -> TL.intercalate "," ks
    Nothing -> "nanoPage,Website,CMS,Content management system,Haskell"

descriptionString :: PageConfig -> TL.Text
descriptionString c = fromMaybe "This is a nanoPage page" (_description c)

authorString :: PageConfig -> TL.Text
authorString c = fromMaybe "nanoPage" (_author c)


{-------------------------------- Page ----------------------------------------}

data Page = Page {
    config       :: PageConfig,
    mdContent    :: TL.Text,           -- the html'ized content of the md file
    mdPreview    :: TL.Text,           -- the html'ized preview of the md file
    previewImage :: TL.Text,           -- path to the preview image
    template     :: Maybe M.Template   -- parsed content of the template file
}

-- | Parameters passed to partials
type Params = [(T.Text, T.Text)]

-- | Return the title of a page.
title :: Page -> TL.Text
title p = _title (config p)

-- | Return the slug of a page.
slug :: Page -> TL.Text
slug p = case _slug (config p) of
    Just s  -> s
    Nothing -> case makeSlug (title p) of
        Just s' -> s'
        Nothing -> error "Cannot create slug!"

-- | Return the list of keywords of a page.
keywords :: Page -> [TL.Text]
keywords p = fromMaybe [] (_keywords $ config p)

-- | Return the list of tags of a page.
tags :: Page -> [TL.Text]
tags p = fromMaybe [] (_tags $ config p)

-- | Return the list of categories of a page.
categories :: Page -> [TL.Text]
categories p = fromMaybe [] (_categories $ config p)

-- | Return the description of a page.
description :: Page -> TL.Text
description = descriptionString . config

-- | Return the author name of a page.
author :: Page -> TL.Text
author = authorString . config

-- | Returns True when the page is a hidden page (has a slug beginning with '_' or '.')
isHiddenPage :: Page -> Bool
isHiddenPage p = h == '_' || h == '.' where
    h = TL.head $ tr' "slug" $ slug p

-- | Get the page identified by pageDir from FileDB.
getPageNoContent :: FilePath -> FileDB -> Page
getPageNoContent pageDir db = p where
    l = length mdFiles
    mdFiles = findFiles db ".md" pageDir
    cfg = readPageConfig db $ joinPath [pageDir, "config.yaml"]
    p | l == 0 = error $ "No .md files found in " ++ pageDir
      | l > 1  = error $ "There are multiple .md files in " ++ pageDir
      | otherwise = Page { config = cfg, mdContent = "", mdPreview = "", template = Nothing, previewImage = "assets/img/placeholder-320x160.png" }

-- | Return a list of all available pages
getAllPagesNoContent :: FileDB -> [Page]
getAllPagesNoContent db = map (`getPageNoContent` db) ps where
    ps = listPages db

-- | Return a list of all visible pages, i.e. all pages that don't have a leading
-- '.' or '_'
getPagesNoContent :: FileDB -> [Page]
getPagesNoContent db = filter f (getAllPagesNoContent db) where
  isAdmin = mode db == ADMIN
  f p = (h /= '.') && (h /= '_') || isAdmin where
      h = TL.head (slug p)

listPages :: FileDB -> [String]
listPages db = filter (('.'/=).head) dirs where
   dirs = getDirectories db (pagesDir db)

-- | Splits a file content into preview and content. It splits on the first
-- occurence of "---"
splitPagePreviewContent :: BS8.ByteString -> (BS8.ByteString, BS8.ByteString)
splitPagePreviewContent bs = (p, c) where
   brk = "---" :: BS8.ByteString
   (p', c') = BS8.breakSubstring brk bs
   (p,c) | c' == "" = ("", p')
         | otherwise = (p', BS8.drop 3 c')

-- | Create the page identified by @pageDir@ from FileDB @db@.
makePage :: FilePath -> FileDB -> IO Page
makePage pageDir db = do
    -- 0. in ADMIN mode chop the "pages/" in pageDir (TODO: standardize this)
    let relativePageDir | mode db == ADMIN = makeRelative (pagesDir db) pageDir
                        | otherwise        = pageDir
    -- 1. Get a list of mdfiles in pageDirFullPath, raise an error if there is not exactly one
    let mdFiles = Internal.FileDB.findFiles db ".md" pageDir
    when (null mdFiles) (error $ "No .md files found in " ++ pageDir)
    when (length mdFiles > 1)  (error $ "There are multiple .md files in " ++ pageDir)
    let mdFileName = (snd . splitFileName . head) mdFiles
    -- 2. Extract the template filename from the md filename, load the template
    let templateFileName = replaceExtension mdFileName "html"    -- the filename of the page makes the templatename
    let template = getTemplate templateFileName db
    -- 3. read the mdfile, render the markdown to HTML, transform the HTML (fix paths, etc.)
    let mdFileContent = Internal.FileDB.readFile db $ joinPath [pageDir, mdFileName]
    let (mdPreview, mdContent) = splitPagePreviewContent mdFileContent
    let htmlContent' = markdownToHtmlString mdContent
    let htmlPreview' = markdownToHtmlString mdPreview
    htmlContent <- transformHtml relativePageDir htmlContent'
    htmlPreview'' <- transformHtml relativePageDir htmlPreview'
    previewImage <- getFirstImage htmlPreview''
    htmlPreview <- removeImages htmlPreview''
    -- 4. Read the config.yaml file, make the Page with empty content
    let cfg = readPageConfig db $ joinPath [pageDir, "config.yaml"]
    return Page {
        config = cfg,
        template = Just template,
        mdContent = htmlContent,
        mdPreview = htmlPreview,
        previewImage = previewImage
    }

-- | 'Safe' version of makePage that catches IOErrors and returns error messages in an Either.
makePage' :: String -> FileDB -> IO (Either ErrorMessage Page)
makePage' f db = do
  p' <- Error.tryIOError (makePage f db)
  return $ case p' of
      Left err -> Left (Error.ioeGetErrorString err)
      Right p  -> Right p

-- | Return a list of all available pages
makeAllPages :: FileDB -> IO [Page]
makeAllPages db = mapM (`makePage` db) (listPages db)

-- | Return a list of all visible pages, with content. Depending on mode pages with
-- leading '.' or '_' are shown (ADMIN mode) or not (otherwise)
makePages :: FileDB -> IO [Page]
makePages db = filter f <$> makeAllPages db where
   isAdmin = mode db == ADMIN
   f p = (h /= '.') && (h /= '_') || isAdmin where
       h = TL.head (slug p)

-- | Generate a list of routes for all files in FileDB @db@.
getStaticDirRoutes :: FileDB -> IO [Sp.SpockM FileDB () () ()]
getStaticDirRoutes db = return $ map routeFile (files db) where
    routeFile :: (FilePath, BS8.ByteString) -> Sp.SpockM FileDB () () ()
    routeFile (path, content) = do
        liftIO $ putStrLn ("> " ++ path)
        Sp.get (Sp.static path) $ Sp.serveFile (T.pack path) content


{-------------------------------- PageInfo ------------------------------------}

-- | A sanitized, short version of Page that can be returned as a JSON object.
-- PageInfo is used for showing preview cards, for example.
data PageInfo = PageInfo {
   ti :: TL.Text,
   sl :: TL.Text,
   au :: TL.Text,
   pr :: TL.Text,       -- the html'ized preview of the md file
   ts :: [TL.Text],     -- tags
   cs :: [TL.Text],     -- categories
   im :: TL.Text        -- image link
   } deriving (Generic, ToJSON)

-- | Create the sanitized PageInfo form of a Page
mkPageInfo :: Page -> PageInfo
mkPageInfo p = PageInfo (title p) (slug p) (author p) (mdPreview p) (tags p) (categories p) (previewImage p)

-- | Fill the PageInfo's pr field with rendered html by applying the function @f@.
renderPreviewWith :: (H.Html -> PageInfo -> H.Html) -> PageInfo -> PageInfo
renderPreviewWith f p = PageInfo (ti p) (sl p) (au p) preview' (ts p) (cs p) (im p) where
    preview' = renderHtml html'
    html' = f (H.preEscapedText $ TL.toStrict $ pr p) p
