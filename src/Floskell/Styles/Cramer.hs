{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE FlexibleContexts  #-}

-- | Enno Cramer's Style.
module Floskell.Styles.Cramer ( cramer ) where

import           Control.Applicative            ( (<|>) )
import           Control.Monad                  ( forM_, replicateM_, unless
                                                , when )
import           Control.Monad.State.Strict     ( get, gets )

import           Data.Int                       ( Int64 )
import           Data.List                      ( groupBy, intersperse, sortOn )
import           Data.Maybe                     ( catMaybes, isJust, mapMaybe )

import           Floskell.Pretty                hiding ( inter, spaced )
import           Floskell.Types

import           Language.Haskell.Exts          ( prettyPrint )
import           Language.Haskell.Exts.Comments
import           Language.Haskell.Exts.SrcLoc
import           Language.Haskell.Exts.Syntax

-- | Line breaking mode for syntactical constructs.
data LineBreak = Free    -- ^ Break whenever
               | Single  -- ^ Force single line (if possible)
               | Multi   -- ^ Force multiple lines
    deriving (Eq, Enum, Show)

-- | Printer state.
data State =
    State { cramerLineBreak          :: LineBreak     -- ^ Current line breaking mode
          , cramerLangPragmaLength   :: Int    -- ^ Padding length for pragmas
          , cramerModuleImportLength :: Int  -- ^ Padding length for module imports
          , cramerRecordFieldLength  :: Int   -- ^ Padding length for record fields
          }
    deriving (Show)

-- | Syntax shortcut for Extenders.
type Extend f = f NodeInfo -> Printer State ()

-- | Style definition.
cramer :: Style
cramer = Style { styleName = "cramer"
               , styleAuthor = "Enno Cramer"
               , styleDescription = "Enno Cramer's style"
               , styleInitialState = State { cramerLineBreak = Free
                                           , cramerLangPragmaLength = 0
                                           , cramerModuleImportLength = 0
                                           , cramerRecordFieldLength = 0
                                           }
               , styleExtenders = [ Extender extModule
                                  , Extender extModulePragma
                                  , Extender extModuleHead
                                  , Extender extExportSpecList
                                  , Extender extImportDecl
                                  , Extender extDecl
                                  , Extender extDeclHead
                                  , Extender extConDecl
                                  , Extender extFieldDecl
                                  , Extender extDeriving
                                  , Extender extRhs
                                  , Extender extContext
                                  , Extender extType
                                  , Extender extPat
                                  , Extender extExp
                                  , Extender extStmt
                                  , Extender extMatch
                                  , Extender extBinds
                                  , Extender extFieldUpdate
                                  , Extender extInstRule
                                  , Extender extQualConDecl
                                  ]
               , styleDefConfig = defaultConfig { configMaxColumns = 80
                                                , configIndentSpaces = 4
                                                }
               , styleCommentPreprocessor = return
               , styleLinePenalty = linePenalty
               }

--------------------------------------------------------------------------------
-- Helper
-- | Compute line penalty
linePenalty :: Bool -> Int64 -> Printer State Penalty
linePenalty eol col = do
    state <- get
    let maxcol = configMaxColumns (psConfig state)
    return $ linebreakPenalty + overfullPenalty (col - maxcol)
  where
    linebreakPenalty = if eol then 1 else 0
    overfullPenalty n = if n > 0 then 10 + fromIntegral (n `div` 2) else 0

-- | Return an ast node's SrcSpan.
nodeSrcSpan :: Annotated a => a NodeInfo -> SrcSpan
nodeSrcSpan = srcInfoSpan . nodeInfoSpan . ann

-- | Turn a Name into a String
nameStr :: Name a -> String
nameStr (Ident _ s) = s
nameStr (Symbol _ s) = "(" ++ s ++ ")"

-- | Extract the name as a String from a ModuleName
moduleName :: ModuleName a -> String
moduleName (ModuleName _ s) = s

-- | Extract the names of a ModulePragma
pragmaNames :: ModulePragma a -> [String]
pragmaNames (LanguagePragma _ names) = map nameStr names
pragmaNames _ = []

-- | Return whether a data type has only empty constructors.
isEnum :: Decl NodeInfo -> Bool
isEnum (DataDecl _ (DataType _) Nothing (DHead _ _) constructors _) =
    all isSimple constructors
  where
    isSimple (QualConDecl _ Nothing Nothing (ConDecl _ _ [])) = True
    isSimple _ = False
isEnum _ = False

-- | Return whether a data type has only zero or one constructor.
isSingletonType :: Decl NodeInfo -> Bool
isSingletonType (DataDecl _ _ _ _ [] _) = True
isSingletonType (DataDecl _ _ _ _ [ _ ] _) = True
isSingletonType _ = False

-- | If the given String is smaller than the given length, pad on
-- right with spaces until the length matches.
padRight :: Int -> String -> String
padRight l s = take (max l (length s)) (s ++ repeat ' ')

-- | Return comments with matching location.
filterComments :: Annotated a
               => (Maybe ComInfoLocation -> Bool)
               -> a NodeInfo
               -> [ComInfo]
filterComments f = filter (f . comInfoLocation) . nodeInfoComments . ann

-- | Return whether an AST node has matching comments.
hasComments :: Annotated a
            => (Maybe ComInfoLocation -> Bool)
            -> a NodeInfo
            -> Bool
hasComments f = not . null . filterComments f

-- | Copy comments marked After from one AST node to another.
copyComments :: (Annotated ast1, Annotated ast2)
             => ComInfoLocation
             -> ast1 NodeInfo
             -> ast2 NodeInfo
             -> ast2 NodeInfo
copyComments loc from to = amap updateComments to
  where
    updateComments info = info { nodeInfoComments = oldComments ++ newComments
                               }
    oldComments = filterComments (/= Just loc) to
    newComments = filterComments (== Just loc) from

-- | Return the number of line breaks between AST nodes.
lineDelta :: (Annotated ast1, Annotated ast2)
          => ast1 NodeInfo
          -> ast2 NodeInfo
          -> Int
lineDelta prev next = nextLine - prevLine
  where
    prevLine = maximum (prevNodeLine : prevCommentLines)
    nextLine = minimum (nextNodeLine : nextCommentLines)
    prevNodeLine = srcSpanEndLine . nodeSrcSpan $ prev
    nextNodeLine = srcSpanStartLine . nodeSrcSpan $ next
    prevCommentLines = map (srcSpanEndLine . commentSrcSpan) $
        filterComments (== Just After) prev
    nextCommentLines = map (srcSpanStartLine . commentSrcSpan) $
        filterComments (== Just Before) next
    commentSrcSpan = annComment . comInfoComment
    annComment (Comment _ sp _) = sp

-- | Specialized forM_ for Maybe.
maybeM_ :: Maybe a -> (a -> Printer s ()) -> Printer s ()
maybeM_ = forM_

-- | Simplified Floskell.Pretty.inter that does not modify the indent level.
inter :: Printer s () -> [Printer s ()] -> Printer s ()
inter sep = sequence_ . intersperse sep

-- | Simplified Floskell.Pretty.spaced that does not modify the indent level.
spaced :: [Printer s ()] -> Printer s ()
spaced = inter space

-- | Indent one level.
indentFull :: Printer s a -> Printer s a
indentFull = indentedBlock

-- | Indent a half level.
indentHalf :: Printer s a -> Printer s a
indentHalf p = getIndentSpaces >>= flip indented p . (`div` 2)

-- | Set indentation level to current column.
align :: Printer s a -> Printer s a
align p = do
    col <- getNextColumn
    column col p

-- | Update the line breaking mode and restore afterwards.
withLineBreak :: LineBreak -> Printer State a -> Printer State a
withLineBreak lb p = do
    old <- gets (cramerLineBreak . psUserState)
    modifyState $ \s -> s { cramerLineBreak = lb }
    result <- p
    modifyState $ \s -> s { cramerLineBreak = old }
    return result

-- | Relax the line breaking mode and restore afterwards.  In
-- multi-line mode, switch to free line breaking, otherwise keep line
-- breaking mode.
withLineBreakRelaxed :: Printer State a -> Printer State a
withLineBreakRelaxed p = do
    old <- gets (cramerLineBreak . psUserState)
    withLineBreak (if old == Multi then Free else old) p

-- | Use the first printer if it fits on a single line within the
-- column limit, otherwise use the second.
attemptSingleLine :: Printer State a -> Printer State a -> Printer State a
attemptSingleLine single multi = do
    linebreak <- gets (cramerLineBreak . psUserState)
    case linebreak of
        Single -> single
        Multi -> multi
        Free -> withLineBreak Single single `fitsOnOneLineOr` multi

-- | Same as attemptSingleLine, but execute the second printer in Multi
-- mode.  Used in type signatures to force either a single line or
-- have each `->` on a line by itself.
attemptSingleLineType :: Printer State a -> Printer State a -> Printer State a
attemptSingleLineType single multi =
    attemptSingleLine single (withLineBreak Multi multi)

-- | Format a list-like structure on a single line.
listSingleLine :: Pretty a
               => String
               -> String
               -> String
               -> [a NodeInfo]
               -> Printer State ()
listSingleLine open close _ [] = do
    string open
    space
    string close
listSingleLine open close sep xs = do
    string open
    space
    inter (string sep >> space) $ map pretty xs
    space
    string close

-- | Format a list-like structure with each element on a line by
-- itself.
listMultiLine :: Pretty a
              => String
              -> String
              -> String
              -> [a NodeInfo]
              -> Printer State ()
listMultiLine open close _ [] = align $ do
    string open
    newline
    string close
listMultiLine open close sep xs = align $ do
    string open
    space
    inter (newline >> string sep >> space) $ map (cut . pretty) xs
    unless (close == "") $ do
        newline
        string close

-- | Format a list-like structure on a single line, if possible, or
-- each element on a line by itself.
listAttemptSingleLine :: Pretty a
                      => String
                      -> String
                      -> String
                      -> [a NodeInfo]
                      -> Printer State ()
listAttemptSingleLine open close sep xs =
    attemptSingleLine (listSingleLine open close sep xs)
                      (listMultiLine open close sep xs)

-- | Format a list-like structure, automatically breaking lines when
-- the next separator and item do not fit within the column limit.
listAutoWrap :: Pretty a
             => String
             -> String
             -> String
             -> [a NodeInfo]
             -> Printer State ()
listAutoWrap open close sep ps = align $ do
    string open
    unless (null ps) $ do
        space
        pretty $ head ps
        forM_ (tail ps) $
            \p -> maybeNewline $ string sep >> space >> pretty p
        space
    string close
  where
    maybeNewline p = cut $
        (withOutputRestriction NoOverflow p) <|> (newline >> p)

-- | Like `inter newline . map pretty`, but preserve empty lines
-- between elements.
preserveLineSpacing :: Pretty ast => [ast NodeInfo] -> Printer State ()
preserveLineSpacing [] = return ()
preserveLineSpacing asts@(first : rest) = do
    cut $ pretty first
    forM_ (zip asts rest) $
        \(prev, cur) -> do
            replicateM_ (min 2 (max 1 $ lineDelta prev cur)) newline
            cut $ pretty cur

-- | Either simply precede the given printer with a space, or with
-- indent the the printer after a newline, depending on the available
-- space.
spaceOrIndent :: Printer State () -> Printer State ()
spaceOrIndent p = (space >> p) <|> (newline >> indentFull p)

-- | Special casing for `do` blocks and leading comments
inlineExpr :: (Printer State () -> Printer State ())
           -> Exp NodeInfo
           -> Printer State ()
inlineExpr _ expr | not (null (filterComments (== (Just Before)) expr)) = do
                        newline
                        indentFull $ pretty expr
inlineExpr _ expr@Do{} = do
    space
    pretty expr
inlineExpr fmt expr = fmt (pretty expr)

--------------------------------------------------------------------------------
-- Printer for reused syntactical constructs
moduleImports :: [ImportDecl NodeInfo] -> Printer State ()
moduleImports = inter (newline >> newline) .
    map preserveLineSpacing .
        groupBy samePrefix . sortOn (moduleName . importModule)
  where
    samePrefix left right = prefix left == prefix right
    prefix = takeWhile (/= '.') . moduleName . importModule

forallVars :: [TyVarBind NodeInfo] -> Printer State ()
forallVars vars = do
    write "forall "
    spaced $ map pretty vars
    write "."

whereBinds :: Binds NodeInfo -> Printer State ()
whereBinds binds = do
    newline
    indentHalf $ do
        write "where"
        newline
        indentHalf $ pretty binds

rhsExpr :: Exp NodeInfo -> Printer State ()
rhsExpr expr = do
    space
    rhsSeparator
    inlineExpr spaceOrIndent expr

guardedRhsExpr :: GuardedRhs NodeInfo -> Printer State ()
guardedRhsExpr (GuardedRhs _ guards expr) = depend (write "| ") $ do
    inter (write ", ") $ map pretty guards
    rhsExpr expr

tupleExpr :: Pretty ast => Boxed -> [ast NodeInfo] -> Printer State ()
tupleExpr boxed exprs = attemptSingleLine single multi
  where
    single = do
        string open
        inter (write ", ") $ map pretty exprs
        string close
    multi = listMultiLine open close "," exprs
    (open, close) = case boxed of
        Unboxed -> ("(# ", " #)")
        Boxed -> ("(", ")")

listExpr :: Pretty ast => [ast NodeInfo] -> Printer State ()
listExpr [] = write "[]"
listExpr xs = listAttemptSingleLine "[" "]" "," xs

recordExpr :: (Pretty ast, Pretty ast')
           => ast NodeInfo
           -> [ast' NodeInfo]
           -> Printer State ()
recordExpr expr updates = do
    pretty expr
    space
    listAttemptSingleLine "{" "}" "," updates

ifExpr :: (Printer State () -> Printer State ())
       -> Exp NodeInfo
       -> Exp NodeInfo
       -> Exp NodeInfo
       -> Printer State ()
ifExpr indent cond true false = attemptSingleLine single multi
  where
    single = spaced [ if', then', else' ]
    multi = align $ do
        if'
        indent $ do
            newline
            then'
            newline
            else'
    if' = cut $ write "if " >> pretty cond
    then' = cut $ write "then " >> pretty true
    else' = cut $ write "else " >> pretty false

letExpr :: Binds NodeInfo -> Exp NodeInfo -> Printer State ()
letExpr binds expr = align $ do
    depend (write "let ") $ pretty binds
    newline
    write "in"
    inlineExpr (\p -> newline >> indentFull p) expr

infixExpr :: Exp NodeInfo -> Printer State ()
-- No line break before do
infixExpr (InfixApp _ arg1 op arg2@Do{}) =
    spaced [ pretty arg1, pretty op, pretty arg2 ]
-- Try to preserve existing line break before and after infix ops
infixExpr (InfixApp _ arg1 op arg2)
    | deltaBefore /= 0 && deltaAfter /=
          0 = align $ inter newline [ pretty arg1, pretty op, pretty arg2 ]
    | deltaBefore /= 0 || deltaAfter /= 0 = pretty arg1 >>
          preserveLinebreak deltaBefore
                            (pretty op >>
                                 preserveLinebreak deltaAfter (pretty arg2))
    | otherwise = do
          pretty arg1
          space
          pretty op
          spaceOrIndent (pretty arg2)
  where
    preserveLinebreak delta p =
        if delta > 0 then newline >> indentFull p else space >> p
    deltaBefore = lineDelta arg1 op
    deltaAfter = lineDelta op arg2
infixExpr _ = error "not an InfixApp"

applicativeExpr :: Exp NodeInfo
                -> [(QOp NodeInfo, Exp NodeInfo)]
                -> Printer State ()
applicativeExpr ctor args = attemptSingleLine single multi
  where
    single = spaced (pretty ctor : map prettyArg args)
    multi = do
        cut $ pretty ctor
        depend space $ inter newline $ map prettyArg args
    prettyArg (op, arg) = cut $ pretty op >> space >> pretty arg

typeSig :: Type NodeInfo -> Printer State ()
typeSig ty = attemptSingleLineType (write ":: " >> pretty ty)
                                   (align $ write ":: " >> pretty ty)

typeInfixExpr :: Type NodeInfo -> Printer State ()
-- As Floskell does not know about operator precedence, preserve
-- existing line breaks, but do not add new ones.
typeInfixExpr (TyInfix _ arg1 op arg2)
    | deltaBefore /= 0 && deltaAfter /= 0 =
          align $ inter newline [ pretty arg1, prettyInfixOp op, pretty arg2 ]
    | deltaBefore /= 0 || deltaAfter /= 0 = pretty arg1 >>
          preserveLinebreak deltaBefore
                            (prettyInfixOp op >>
                                 preserveLinebreak deltaAfter (pretty arg2))
    | otherwise = spaced [ pretty arg1, prettyInfixOp op, pretty arg2 ]
  where
    preserveLinebreak delta p =
        if delta > 0 then newline >> indentFull p else space >> p
    deltaBefore = lineDelta arg1 op
    deltaAfter = lineDelta op arg2
typeInfixExpr _ = error "not a TyInfix"

--------------------------------------------------------------------------------
-- Extenders
extModule :: Extend Module
extModule (Module _ mhead pragmas imports decls) = do
    modifyState $ \s -> s { cramerLangPragmaLength = pragLen
                          , cramerModuleImportLength = modLen
                          }
    inter (newline >> newline) $
        catMaybes [ unless' (null pragmas) $ preserveLineSpacing pragmas
                  , cut . pretty <$> mhead
                  , unless' (null imports) $ moduleImports imports
                  , unless' (null decls) $ do
                      forM_ (init decls) $
                          \decl -> do
                              cut $ pretty decl
                              newline
                              unless (skipNewline decl) newline
                      cut $ pretty (last decls)
                  ]
  where
    pragLen = maximum $ map length $ concatMap pragmaNames pragmas
    modLen = maximum $ map (length . moduleName . importModule) imports
    unless' cond expr = if not cond then Just expr else Nothing
    skipNewline TypeSig{} = True
    skipNewline DeprPragmaDecl{} = True
    skipNewline WarnPragmaDecl{} = True
    skipNewline AnnPragma{} = True
    skipNewline MinimalPragma{} = True
    skipNewline InlineSig{} = True
    skipNewline InlineConlikeSig{} = True
    skipNewline SpecSig{} = True
    skipNewline SpecInlineSig{} = True
    skipNewline InstSig{} = True
    skipNewline _ = False
extModule other = prettyNoExt other

-- Align closing braces of pragmas
extModulePragma :: Extend ModulePragma
extModulePragma (LanguagePragma _ names) = do
    namelen <- gets (cramerLangPragmaLength . psUserState)
    lined $ map (fmt namelen) names
  where
    fmt len name = do
        write "{-# LANGUAGE "
        string $ padRight len $ nameStr name
        write " #-}"
-- Avoid increasing whitespace after OPTIONS string
extModulePragma (OptionsPragma _ mtool opt) = do
    write "{-# OPTIONS"
    maybeM_ mtool $ \tool -> do
        write "_"
        string $ prettyPrint tool
    space
    string $ trim opt
    write " #-}"
  where
    trim = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')
extModulePragma other = prettyNoExt other

-- Empty or single item export list on one line, otherwise one item
-- per line with parens and comma aligned
extModuleHead :: Extend ModuleHead
extModuleHead (ModuleHead _ name mwarn mexports) = do
    write "module "
    pretty name
    maybeM_ mwarn $ \warn -> space >> pretty warn
    maybeM_ mexports $ \exports -> pretty exports
    write " where"

-- Align export list, one item per line
extExportSpecList :: Extend ExportSpecList
extExportSpecList (ExportSpecList _ exports) = case exports of
    [] -> write " ( )"
    [ e ] | not (hasComments (const True) e) -> write " ( " >> pretty e >> write " )"
    (first : rest) -> do
        newline
        indentFull $ do
            write "( "
            commentCol <- getColumn
            align $ prettyExportSpec "" commentCol first
            forM_ rest $
                \export -> do
                    newline
                    prettyExportSpec ", " commentCol export
            newline
            write ")"
  where
    printCommentsSimple loc ast =
        let rawComments = filterComments (== Just loc) ast
        in do
            preprocessor <- gets psCommentPreprocessor
            comments <- preprocessor $ map comInfoComment rawComments
            forM_ comments $
                printComment (Just $ nodeSrcSpan ast)
    prettyExportSpec prefix col spec = do
        column col $ printCommentsSimple Before spec
        string prefix
        prettyNoExt spec
        printCommentsSimple After spec

-- Align import statements
extImportDecl :: Extend ImportDecl
extImportDecl ImportDecl{..} = do
    if importQualified
        then write "import qualified "
        else write "import           "
    namelen <- gets (cramerModuleImportLength . psUserState)
    if isJust importAs || isJust importSpecs
        then string $ padRight namelen $ moduleName importModule
        else string $ moduleName importModule
    maybeM_ importAs $
        \name -> do
            write " as "
            pretty name
    maybeM_ importSpecs $
        \(ImportSpecList _ importHiding specs) -> do
            space
            when importHiding $ write "hiding "
            listAutoWrap "(" ")" "," $ sortOn prettyPrint specs

extDecl :: Extend Decl
-- No dependent indentation for type decls
extDecl (TypeDecl _ declhead ty) = do
    write "type "
    pretty declhead
    write " = "
    indentFull $ pretty ty
-- Fix whitespace before 'where' in class decl
extDecl (ClassDecl _ mcontext declhead fundeps mdecls) = do
    depend (write "class ") $
        depend (maybeCtx mcontext) $
            depend (pretty declhead) $
                depend (unless (null fundeps) $
                            write " | " >> inter (write ", ")
                                                 (map pretty fundeps)) $
                    when (isJust mdecls) $ write " where"
    maybeM_ mdecls $
        \decls -> do
            newline
            indentFull $ preserveLineSpacing decls
-- Align data constructors
extDecl decl@(DataDecl _ dataOrNew mcontext declHead constructors mderiv) = do
    mapM_ pretty mcontext
    pretty dataOrNew
    space
    pretty declHead
    space
    unless (null constructors) $
        if isEnum decl || isSingletonType decl
        then attemptSingleLine single multi
        else multi
    maybeM_ mderiv $ \deriv -> indentFull $ newline >> pretty deriv
  where
    single = do
        write "= "
        inter (write " | ") $ map pretty constructors
    multi = multi1 <|> multi2
    multi1 = listMultiLine "=" "" "|" constructors
    multi2 = do
        write "="
        newline
        indentFull $ (if isSingletonType decl
                      then mapM_ (cut . pretty) constructors
                      else listMultiLine " " "" "|" constructors)
-- Type signature either on a single line or split at arrows, aligned with '::'
extDecl (TypeSig _ names ty) = do
    inter (write ", ") $ map pretty names
    space
    typeSig ty
-- Preserve empty lines between function matches
extDecl (FunBind _ matches) = preserveLineSpacing matches
-- Half-indent for where clause, half-indent binds
extDecl (PatBind _ pat rhs mbinds) = do
    pretty pat
    cut $ withCaseContext False $ pretty rhs
    maybeM_ mbinds whereBinds
extDecl other = prettyNoExt other

-- Do not modify indent level
extDeclHead :: Extend DeclHead
extDeclHead (DHApp _ dhead var) = do
    pretty dhead
    space
    pretty var
extDeclHead other = prettyNoExt other

extConDecl :: Extend ConDecl
-- No extra space after empty constructor
extConDecl (ConDecl _ name []) = pretty name
extConDecl (ConDecl _ name tys) = attemptSingleLine single multi
  where
    single = spaced $ pretty name : map pretty tys
    multi = depend (pretty name >> space) $ lined $ map pretty tys
-- Align record fields
extConDecl (RecDecl _ name fields) = do
    modifyState $ \s -> s { cramerRecordFieldLength = fieldLen }
    pretty name
    space
    case fields of
        [] -> write "{ }"
        [ _ ] -> listAttemptSingleLine "{" "}" "," fields
        _ -> listMultiLine "{" "}" "," fields
  where
    fieldLen = maximum $ map (length . nameStr) fnames
    fnames = mapMaybe (\(FieldDecl _ ns _) -> case ns of
                           [ n ] -> Just n
                           _ -> Nothing)
                      fields
extConDecl other = prettyNoExt other

extFieldDecl :: Extend FieldDecl
extFieldDecl (FieldDecl _ [ name ] ty) = do
    namelen <- gets (cramerRecordFieldLength . psUserState)
    string $ padRight namelen $ nameStr name
    space
    typeSig ty
extFieldDecl other = prettyNoExt other

-- Derived instances separated by comma and space, no line breaking
extDeriving :: Extend Deriving
extDeriving (Deriving _ instHeads) = do
    write "deriving "
    case instHeads of
        [ x ] -> pretty x
        xs -> parens $ inter (write ", ") $ map pretty xs

extRhs :: Extend Rhs
extRhs (UnGuardedRhs _ expr) = rhsExpr expr
extRhs (GuardedRhss _ [ rhs ]) = space >> guardedRhsExpr rhs
extRhs (GuardedRhss _ rhss) = forM_ rhss $
    \rhs -> do
        newline
        indentFull $ guardedRhsExpr rhs

-- Type constraints on a single line
extContext :: Extend Context
extContext (CxTuple _ ctxs) = parens $ inter (write ", ") $ map pretty ctxs
extContext other = prettyNoExt other

extType :: Extend Type
extType (TyForall _ mforall mcontext ty) = attemptSingleLine single multi
  where
    single = do
        maybeM_ mforall $ \vars -> forallVars vars >> space
        maybeM_ mcontext $ \context -> pretty context >> write " => "
        pretty ty
    multi = do
        maybeM_ mforall $ \vars -> forallVars vars >> newline
        maybeM_ mcontext $
            \context -> pretty context >> newline >> write "=> "
        pretty ty
-- Type signature should line break at each arrow if necessary
extType (TyFun _ from to) =
    attemptSingleLineType (pretty from >> write " -> " >> pretty to)
                          (pretty from >> newline >> write "-> " >> pretty to)
-- Parentheses reset forced line breaking
extType (TyParen _ ty) = withLineBreakRelaxed $ parens $ pretty ty
-- Tuple types on one line, with space after comma
extType (TyTuple _ boxed tys) = withLineBreakRelaxed $ tupleExpr boxed tys
-- Infix application
extType expr@TyInfix{} = typeInfixExpr expr
extType other = prettyNoExt other

extPat :: Extend Pat
-- Infix application with space around operator
extPat (PInfixApp _ arg1 op arg2) = do
    pretty arg1
    space
    prettyInfixOp op
    space
    pretty arg2
-- Tuple patterns on one line, with space after comma
extPat (PTuple _ boxed pats) = tupleExpr boxed pats
-- List patterns on one line, with space after comma
extPat (PList _ pats) = listExpr pats
-- No space after record name in patterns
extPat (PRec _ qname fields) = depend (pretty qname)
                                      (braces (commas (map pretty fields)))
extPat other = prettyNoExt other

extExp :: Extend Exp
-- Function application on a single line or align arguments
extExp expr@(App _ fun arg) = attemptSingleLine single multi
  where
    single = pretty fun >> space >> pretty arg
    multi = pretty fun' >> space >> align (lined $ map pretty $ reverse args')
    (fun', args') = collectArgs expr
    collectArgs :: Exp NodeInfo -> (Exp NodeInfo, [Exp NodeInfo])
    collectArgs app@(App _ g y) = let (f, args) = collectArgs g
                                  in
                                      (f, copyComments After app y : args)
    collectArgs nonApp = (nonApp, [])
-- Infix application on a single line or indented rhs
extExp expr@InfixApp{} =
    if all (isApplicativeOp . fst) opArgs && isFmap (fst $ head opArgs)
    then applicativeExpr firstArg opArgs
    else infixExpr expr
  where
    (firstArg, opArgs) = collectOpExps expr
    collectOpExps :: Exp NodeInfo
                  -> (Exp NodeInfo, [(QOp NodeInfo, Exp NodeInfo)])
    collectOpExps app@(InfixApp _ left op right) =
        let (ctorLeft, argsLeft) = collectOpExps left
            (ctorRight, argsRight) = collectOpExps right
        in
            ( ctorLeft
            , argsLeft ++
                [ (op, copyComments After app ctorRight) ] ++ argsRight
            )
    collectOpExps e = (e, [])
    isApplicativeOp :: QOp NodeInfo -> Bool
    isApplicativeOp (QVarOp _ (UnQual _ (Symbol _ s))) =
        head s == '<' && last s == '>'
    isApplicativeOp _ = False
    isFmap :: QOp NodeInfo -> Bool
    isFmap (QVarOp _ (UnQual _ (Symbol _ "<$>"))) = True
    isFmap _ = False
-- No space after lambda
extExp (Lambda _ pats expr) = do
    write "\\"
    maybeSpace
    spaced $ map pretty pats
    write " ->"
    inlineExpr spaceOrIndent expr
  where
    maybeSpace = case pats of
        PBangPat{} : _ -> space
        PIrrPat{} : _ -> space
        _ -> return ()
-- If-then-else on one line or newline and indent before then and else
extExp (If _ cond true false) = ifExpr id cond true false
-- Newline before in
extExp (Let _ binds expr) = letExpr binds expr
-- Tuples on a single line (no space inside parens but after comma) or
-- one element per line with parens and comma aligned
extExp (Tuple _ boxed exprs) = tupleExpr boxed exprs
-- List on a single line or one item per line with aligned brackets and comma
extExp (List _ exprs) = listExpr exprs
-- Record construction and update on a single line or one line per
-- field with aligned braces and comma
extExp (RecConstr _ qname updates) = recordExpr qname updates
extExp (RecUpdate _ expr updates) = recordExpr expr updates
-- Full indentation for case alts and preserve empty lines between alts
extExp (Case _ expr alts) = do
    write "case "
    cut $ pretty expr
    write " of"
    if null alts
        then write " {}"
        else do
            newline
            withCaseContext True $ indentFull $ preserveLineSpacing alts
-- Line break and indent after do
extExp (Do _ stmts) = do
    write "do"
    newline
    indentFull $ preserveLineSpacing stmts
extExp (ListComp _ e qstmt) =
    brackets (do
                  space
                  pretty e
                  unless (null qstmt)
                         (do
                              newline
                              indented (-1) (write "|")
                              prefixedLined ","
                                            (map (\x -> do
                                                      space
                                                      pretty x
                                                      space)
                                                 qstmt)))
-- Type signatures like toplevel decl
extExp (ExpTypeSig _ expr ty) = do
    pretty expr
    space
    typeSig ty
extExp other = prettyNoExt other

extStmt :: Extend Stmt
extStmt (Qualifier _ (If _ cond true false)) =
    ifExpr indentFull cond true false
extStmt other = prettyNoExt other

extMatch :: Extend Match
-- Indent where same as for top level decl
extMatch (Match _ name pats rhs mbinds) = do
    pretty name
    space
    spaced $ map pretty pats
    cut $ withCaseContext False $ pretty rhs
    maybeM_ mbinds whereBinds
extMatch other = prettyNoExt other

-- Preserve empty lines between bindings
extBinds :: Extend Binds
extBinds (BDecls _ decls) = preserveLineSpacing decls
extBinds other = prettyNoExt other

-- No line break after equal sign
extFieldUpdate :: Extend FieldUpdate
extFieldUpdate (FieldUpdate _ qname expr) = do
    pretty qname
    write " = "
    pretty expr
extFieldUpdate other = prettyNoExt other

extInstRule :: Extend InstRule
extInstRule (IRule _ mvarbinds mctx ihead) = do
    case mvarbinds of
        Nothing -> return ()
        Just xs -> spaced (map pretty xs)
    depend (maybeCtx mctx) (pretty ihead)
extInstRule rule = prettyNoExt rule

extQualConDecl :: Extend QualConDecl
extQualConDecl (QualConDecl _ mforall ctx d) = do
    maybeM_ mforall $ \vars -> forallVars vars >> space
    depend (maybeCtx ctx) (pretty d)