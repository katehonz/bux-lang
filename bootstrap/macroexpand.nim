## Declarative macro! expansion (session 59).
## Expands `name!(args)` using `macro! name { ($x:expr) => { … } }` rules.
## Hygiene: substitute clones args at call-site, graft call-site SourceLocation
## onto expanded template nodes (Ast_QuoteCallSite policy from QUALITY_PLAN).

import std/[tables, sequtils, sets, strutils]
import ast, token, source_location

type
  MacroDiagnostic* = object
    loc*: SourceLocation
    message*: string

  MacroExpandResult* = object
    diagnostics*: seq[MacroDiagnostic]

proc emitErr(res: var MacroExpandResult, loc: SourceLocation, msg: string) =
  res.diagnostics.add(MacroDiagnostic(loc: loc, message: msg))

# ---------------------------------------------------------------------------
# Deep clone (bootstrap has no Ast_Clone*)
# ---------------------------------------------------------------------------

proc cloneExpr*(e: Expr): Expr
proc cloneStmt*(s: Stmt): Stmt
proc cloneBlock*(b: Block): Block

proc cloneBlock*(b: Block): Block =
  if b == nil: return nil
  result = Block(loc: b.loc, stmts: @[])
  for s in b.stmts:
    result.stmts.add(cloneStmt(s))

proc clonePattern(p: Pattern): Pattern =
  if p == nil: return nil
  case p.kind
  of pkWildcard:
    result = Pattern(kind: pkWildcard, loc: p.loc)
  of pkLiteral:
    result = Pattern(kind: pkLiteral, loc: p.loc, patLit: p.patLit)
  of pkIdent:
    result = Pattern(kind: pkIdent, loc: p.loc, patIdent: p.patIdent)
  of pkRange:
    result = Pattern(kind: pkRange, loc: p.loc,
      patRangeLo: clonePattern(p.patRangeLo),
      patRangeHi: clonePattern(p.patRangeHi),
      patRangeInclusive: p.patRangeInclusive)
  of pkEnum:
    result = Pattern(kind: pkEnum, loc: p.loc, patEnumPath: p.patEnumPath,
      patEnumArgs: @[], patEnumNamed: @[])
    for a in p.patEnumArgs:
      result.patEnumArgs.add(clonePattern(a))
    for nf in p.patEnumNamed:
      result.patEnumNamed.add((nf.name, clonePattern(nf.pattern)))
  of pkStruct:
    result = Pattern(kind: pkStruct, loc: p.loc, patStructName: p.patStructName,
      patStructFields: @[])
    for f in p.patStructFields:
      result.patStructFields.add((f.name, clonePattern(f.pattern)))
  of pkTuple:
    result = Pattern(kind: pkTuple, loc: p.loc, patTupleElements: @[])
    for el in p.patTupleElements:
      result.patTupleElements.add(clonePattern(el))
  of pkGuarded:
    result = Pattern(kind: pkGuarded, loc: p.loc,
      patGuardedInner: clonePattern(p.patGuardedInner),
      patGuardedExpr: cloneExpr(p.patGuardedExpr))

proc cloneExpr*(e: Expr): Expr =
  if e == nil: return nil
  case e.kind
  of ekLiteral:
    result = Expr(kind: ekLiteral, loc: e.loc, exprLit: e.exprLit)
  of ekIdent:
    result = Expr(kind: ekIdent, loc: e.loc, exprIdent: e.exprIdent)
  of ekSelf:
    result = Expr(kind: ekSelf, loc: e.loc)
  of ekPath:
    result = Expr(kind: ekPath, loc: e.loc, exprPath: e.exprPath)
  of ekSizeOf:
    result = Expr(kind: ekSizeOf, loc: e.loc, exprSizeOfType: e.exprSizeOfType)
  of ekIntrinsic:
    result = Expr(kind: ekIntrinsic, loc: e.loc, exprIntrinsic: e.exprIntrinsic)
  of ekUnary:
    result = Expr(kind: ekUnary, loc: e.loc, exprUnaryOp: e.exprUnaryOp,
      exprUnaryOperand: cloneExpr(e.exprUnaryOperand))
  of ekPostfix:
    result = Expr(kind: ekPostfix, loc: e.loc, exprPostfixOp: e.exprPostfixOp,
      exprPostfixOperand: cloneExpr(e.exprPostfixOperand))
  of ekBinary:
    result = Expr(kind: ekBinary, loc: e.loc, exprBinaryOp: e.exprBinaryOp,
      exprBinaryLeft: cloneExpr(e.exprBinaryLeft),
      exprBinaryRight: cloneExpr(e.exprBinaryRight))
  of ekAssign:
    result = Expr(kind: ekAssign, loc: e.loc, exprAssignOp: e.exprAssignOp,
      exprAssignTarget: cloneExpr(e.exprAssignTarget),
      exprAssignValue: cloneExpr(e.exprAssignValue))
  of ekTernary:
    result = Expr(kind: ekTernary, loc: e.loc,
      exprTernaryCond: cloneExpr(e.exprTernaryCond),
      exprTernaryThen: cloneExpr(e.exprTernaryThen),
      exprTernaryElse: cloneExpr(e.exprTernaryElse))
  of ekRange:
    result = Expr(kind: ekRange, loc: e.loc,
      exprRangeLo: cloneExpr(e.exprRangeLo),
      exprRangeHi: cloneExpr(e.exprRangeHi),
      exprRangeInclusive: e.exprRangeInclusive)
  of ekCall:
    result = Expr(kind: ekCall, loc: e.loc,
      exprCallCallee: cloneExpr(e.exprCallCallee),
      exprCallArgs: @[], exprCallArgNames: e.exprCallArgNames,
      exprCallInferredTypeArgs: e.exprCallInferredTypeArgs)
    for a in e.exprCallArgs:
      result.exprCallArgs.add(cloneExpr(a))
  of ekGenericCall:
    result = Expr(kind: ekGenericCall, loc: e.loc,
      exprGenericCallee: e.exprGenericCallee,
      exprGenericTypeArgs: e.exprGenericTypeArgs)
  of ekIndex:
    result = Expr(kind: ekIndex, loc: e.loc,
      exprIndexObj: cloneExpr(e.exprIndexObj),
      exprIndexIdx: cloneExpr(e.exprIndexIdx),
      exprIndexBoundsCheck: e.exprIndexBoundsCheck)
  of ekField:
    result = Expr(kind: ekField, loc: e.loc,
      exprFieldObj: cloneExpr(e.exprFieldObj),
      exprFieldName: e.exprFieldName)
  of ekStructInit:
    result = Expr(kind: ekStructInit, loc: e.loc,
      exprStructInitName: e.exprStructInitName,
      exprStructInitTypeArgs: e.exprStructInitTypeArgs,
      exprStructInitFields: @[])
    for f in e.exprStructInitFields:
      result.exprStructInitFields.add((f.name, cloneExpr(f.value)))
  of ekSlice:
    result = Expr(kind: ekSlice, loc: e.loc, exprSliceElements: @[])
    for el in e.exprSliceElements:
      result.exprSliceElements.add(cloneExpr(el))
  of ekSpread:
    result = Expr(kind: ekSpread, loc: e.loc,
      exprSpreadOperand: cloneExpr(e.exprSpreadOperand))
  of ekTuple:
    result = Expr(kind: ekTuple, loc: e.loc, exprTupleElements: @[])
    for el in e.exprTupleElements:
      result.exprTupleElements.add(cloneExpr(el))
  of ekCast:
    result = Expr(kind: ekCast, loc: e.loc,
      exprCastOperand: cloneExpr(e.exprCastOperand),
      exprCastType: e.exprCastType)
  of ekIs:
    result = Expr(kind: ekIs, loc: e.loc,
      exprIsOperand: cloneExpr(e.exprIsOperand),
      exprIsType: e.exprIsType)
  of ekTry:
    result = Expr(kind: ekTry, loc: e.loc,
      exprTryOperand: cloneExpr(e.exprTryOperand),
      exprTryType: e.exprTryType)
  of ekUnwrap:
    result = Expr(kind: ekUnwrap, loc: e.loc,
      exprUnwrapOperand: cloneExpr(e.exprUnwrapOperand))
  of ekSpawn:
    result = Expr(kind: ekSpawn, loc: e.loc,
      exprSpawnCallee: cloneExpr(e.exprSpawnCallee),
      exprSpawnArgs: @[], exprSpawnAsync: e.exprSpawnAsync)
    for a in e.exprSpawnArgs:
      result.exprSpawnArgs.add(cloneExpr(a))
  of ekAwait:
    result = Expr(kind: ekAwait, loc: e.loc,
      exprAwaitOperand: cloneExpr(e.exprAwaitOperand))
  of ekBorrow:
    result = Expr(kind: ekBorrow, loc: e.loc,
      exprBorrowOperand: cloneExpr(e.exprBorrowOperand),
      exprBorrowMutable: e.exprBorrowMutable)
  of ekBlock:
    result = Expr(kind: ekBlock, loc: e.loc, exprBlock: cloneBlock(e.exprBlock))
  of ekMatch:
    result = Expr(kind: ekMatch, loc: e.loc,
      exprMatchSubject: cloneExpr(e.exprMatchSubject),
      exprMatchArms: @[])
    for arm in e.exprMatchArms:
      result.exprMatchArms.add(MatchArm(loc: arm.loc,
        pattern: clonePattern(arm.pattern), body: cloneExpr(arm.body)))
  of ekStringInterp:
    result = Expr(kind: ekStringInterp, loc: e.loc,
      exprInterpTexts: e.exprInterpTexts, exprInterpExprs: @[])
    for ie in e.exprInterpExprs:
      result.exprInterpExprs.add(cloneExpr(ie))
  of ekClosure:
    result = Expr(kind: ekClosure, loc: e.loc,
      exprClosureParams: e.exprClosureParams,
      exprClosureBody: cloneBlock(e.exprClosureBody),
      exprClosureReturnType: e.exprClosureReturnType,
      captureCount: 0, captureNames: @[], captureTypeKinds: @[])
  of ekMacroCall:
    result = Expr(kind: ekMacroCall, loc: e.loc,
      exprMacroName: e.exprMacroName, exprMacroArgs: @[],
      exprMacroGroupLens: e.exprMacroGroupLens)
    for a in e.exprMacroArgs:
      result.exprMacroArgs.add(cloneExpr(a))
  of ekMacroStmt:
    result = Expr(kind: ekMacroStmt, loc: e.loc,
      exprMacroStmt: cloneStmt(e.exprMacroStmt))
  of ekMacroPat:
    result = Expr(kind: ekMacroPat, loc: e.loc,
      exprMacroPat: clonePattern(e.exprMacroPat))

proc cloneStmt*(s: Stmt): Stmt =
  if s == nil: return nil
  case s.kind
  of skExpr:
    result = Stmt(kind: skExpr, loc: s.loc, stmtExpr: cloneExpr(s.stmtExpr))
  of skLet:
    result = Stmt(kind: skLet, loc: s.loc, stmtLetMut: s.stmtLetMut,
      stmtLetName: s.stmtLetName, stmtLetPattern: clonePattern(s.stmtLetPattern),
      stmtLetType: s.stmtLetType, stmtLetInit: cloneExpr(s.stmtLetInit))
  of skIf:
    result = Stmt(kind: skIf, loc: s.loc,
      stmtIfCond: cloneExpr(s.stmtIfCond),
      stmtIfThen: cloneBlock(s.stmtIfThen),
      stmtIfElseIfs: @[],
      stmtIfElse: cloneBlock(s.stmtIfElse))
    for ei in s.stmtIfElseIfs:
      result.stmtIfElseIfs.add(ElseIf(loc: ei.loc, cond: cloneExpr(ei.cond),
        blk: cloneBlock(ei.blk)))
  of skWhile:
    result = Stmt(kind: skWhile, loc: s.loc, stmtWhileLabel: s.stmtWhileLabel,
      stmtWhileCond: cloneExpr(s.stmtWhileCond),
      stmtWhileBody: cloneBlock(s.stmtWhileBody))
  of skDoWhile:
    result = Stmt(kind: skDoWhile, loc: s.loc, stmtDoWhileLabel: s.stmtDoWhileLabel,
      stmtDoWhileBody: cloneBlock(s.stmtDoWhileBody),
      stmtDoWhileCond: cloneExpr(s.stmtDoWhileCond))
  of skLoop:
    result = Stmt(kind: skLoop, loc: s.loc, stmtLoopLabel: s.stmtLoopLabel,
      stmtLoopBody: cloneBlock(s.stmtLoopBody))
  of skFor:
    result = Stmt(kind: skFor, loc: s.loc, stmtForLabel: s.stmtForLabel,
      stmtForVar: s.stmtForVar, stmtForIter: cloneExpr(s.stmtForIter),
      stmtForBody: cloneBlock(s.stmtForBody))
  of skMatch:
    result = Stmt(kind: skMatch, loc: s.loc,
      stmtMatchSubject: cloneExpr(s.stmtMatchSubject), stmtMatchArms: @[])
    for arm in s.stmtMatchArms:
      result.stmtMatchArms.add(MatchArm(loc: arm.loc,
        pattern: clonePattern(arm.pattern), body: cloneExpr(arm.body)))
  of skReturn:
    result = Stmt(kind: skReturn, loc: s.loc,
      stmtReturnValue: cloneExpr(s.stmtReturnValue))
  of skBreak:
    result = Stmt(kind: skBreak, loc: s.loc, stmtBreakLabel: s.stmtBreakLabel)
  of skContinue:
    result = Stmt(kind: skContinue, loc: s.loc, stmtContinueLabel: s.stmtContinueLabel)
  of skStaticAssert:
    result = Stmt(kind: skStaticAssert, loc: s.loc,
      stmtStaticAssertCond: cloneExpr(s.stmtStaticAssertCond),
      stmtStaticAssertMsg: cloneExpr(s.stmtStaticAssertMsg))
  of skComptime:
    result = Stmt(kind: skComptime, loc: s.loc,
      stmtComptimeBlock: cloneBlock(s.stmtComptimeBlock))
  of skEmit:
    result = Stmt(kind: skEmit, loc: s.loc, stmtEmitExpr: cloneExpr(s.stmtEmitExpr),
      stmtEmitEvaluated: s.stmtEmitEvaluated)
  of skDefer:
    result = Stmt(kind: skDefer, loc: s.loc, stmtDeferBody: cloneExpr(s.stmtDeferBody))
  of skSwitch:
    result = Stmt(kind: skSwitch, loc: s.loc,
      stmtSwitchExpr: cloneExpr(s.stmtSwitchExpr),
      stmtSwitchCases: @[],
      stmtSwitchDefault: cloneBlock(s.stmtSwitchDefault))
    for c in s.stmtSwitchCases:
      result.stmtSwitchCases.add(SwitchCase(loc: c.loc,
        caseValue: cloneExpr(c.caseValue), caseBody: cloneBlock(c.caseBody)))
  of skDecl:
    # Nested decl — share pointer (macros don't template decls)
    result = Stmt(kind: skDecl, loc: s.loc, stmtDecl: s.stmtDecl)
  of skMacroRep:
    result = Stmt(kind: skMacroRep, loc: s.loc,
      stmtMacroRepBody: cloneBlock(s.stmtMacroRepBody))

# ---------------------------------------------------------------------------
# Call-site graft (overwrite locations)
# ---------------------------------------------------------------------------

proc graftExprLoc(e: Expr, loc: SourceLocation)
proc graftStmtLoc(s: Stmt, loc: SourceLocation)
proc graftBlockLoc(b: Block, loc: SourceLocation)

proc graftExprLoc(e: Expr, loc: SourceLocation) =
  if e == nil: return
  e.loc = loc
  case e.kind
  of ekUnary: graftExprLoc(e.exprUnaryOperand, loc)
  of ekPostfix: graftExprLoc(e.exprPostfixOperand, loc)
  of ekBinary:
    graftExprLoc(e.exprBinaryLeft, loc)
    graftExprLoc(e.exprBinaryRight, loc)
  of ekAssign:
    graftExprLoc(e.exprAssignTarget, loc)
    graftExprLoc(e.exprAssignValue, loc)
  of ekTernary:
    graftExprLoc(e.exprTernaryCond, loc)
    graftExprLoc(e.exprTernaryThen, loc)
    graftExprLoc(e.exprTernaryElse, loc)
  of ekRange:
    graftExprLoc(e.exprRangeLo, loc)
    graftExprLoc(e.exprRangeHi, loc)
  of ekCall:
    graftExprLoc(e.exprCallCallee, loc)
    for a in e.exprCallArgs: graftExprLoc(a, loc)
  of ekIndex:
    graftExprLoc(e.exprIndexObj, loc)
    graftExprLoc(e.exprIndexIdx, loc)
  of ekField: graftExprLoc(e.exprFieldObj, loc)
  of ekStructInit:
    for f in e.exprStructInitFields: graftExprLoc(f.value, loc)
  of ekSlice:
    for el in e.exprSliceElements: graftExprLoc(el, loc)
  of ekSpread: graftExprLoc(e.exprSpreadOperand, loc)
  of ekTuple:
    for el in e.exprTupleElements: graftExprLoc(el, loc)
  of ekCast: graftExprLoc(e.exprCastOperand, loc)
  of ekIs: graftExprLoc(e.exprIsOperand, loc)
  of ekTry: graftExprLoc(e.exprTryOperand, loc)
  of ekUnwrap: graftExprLoc(e.exprUnwrapOperand, loc)
  of ekSpawn:
    graftExprLoc(e.exprSpawnCallee, loc)
    for a in e.exprSpawnArgs: graftExprLoc(a, loc)
  of ekAwait: graftExprLoc(e.exprAwaitOperand, loc)
  of ekBorrow: graftExprLoc(e.exprBorrowOperand, loc)
  of ekBlock: graftBlockLoc(e.exprBlock, loc)
  of ekMatch:
    graftExprLoc(e.exprMatchSubject, loc)
    for arm in e.exprMatchArms: graftExprLoc(arm.body, loc)
  of ekStringInterp:
    for ie in e.exprInterpExprs: graftExprLoc(ie, loc)
  of ekClosure: graftBlockLoc(e.exprClosureBody, loc)
  of ekMacroCall:
    for a in e.exprMacroArgs: graftExprLoc(a, loc)
  of ekMacroStmt:
    graftStmtLoc(e.exprMacroStmt, loc)
  of ekMacroPat:
    discard
  else: discard

proc graftStmtLoc(s: Stmt, loc: SourceLocation) =
  if s == nil: return
  s.loc = loc
  case s.kind
  of skExpr: graftExprLoc(s.stmtExpr, loc)
  of skLet: graftExprLoc(s.stmtLetInit, loc)
  of skIf:
    graftExprLoc(s.stmtIfCond, loc)
    graftBlockLoc(s.stmtIfThen, loc)
    for ei in s.stmtIfElseIfs:
      graftExprLoc(ei.cond, loc)
      graftBlockLoc(ei.blk, loc)
    graftBlockLoc(s.stmtIfElse, loc)
  of skWhile:
    graftExprLoc(s.stmtWhileCond, loc)
    graftBlockLoc(s.stmtWhileBody, loc)
  of skDoWhile:
    graftBlockLoc(s.stmtDoWhileBody, loc)
    graftExprLoc(s.stmtDoWhileCond, loc)
  of skLoop: graftBlockLoc(s.stmtLoopBody, loc)
  of skFor:
    graftExprLoc(s.stmtForIter, loc)
    graftBlockLoc(s.stmtForBody, loc)
  of skMatch:
    graftExprLoc(s.stmtMatchSubject, loc)
    for arm in s.stmtMatchArms: graftExprLoc(arm.body, loc)
  of skReturn: graftExprLoc(s.stmtReturnValue, loc)
  of skStaticAssert:
    graftExprLoc(s.stmtStaticAssertCond, loc)
    graftExprLoc(s.stmtStaticAssertMsg, loc)
  of skComptime: graftBlockLoc(s.stmtComptimeBlock, loc)
  of skEmit: graftExprLoc(s.stmtEmitExpr, loc)
  of skDefer: graftExprLoc(s.stmtDeferBody, loc)
  of skSwitch:
    graftExprLoc(s.stmtSwitchExpr, loc)
    for c in s.stmtSwitchCases:
      graftExprLoc(c.caseValue, loc)
      graftBlockLoc(c.caseBody, loc)
    graftBlockLoc(s.stmtSwitchDefault, loc)
  of skMacroRep:
    graftBlockLoc(s.stmtMacroRepBody, loc)
  else: discard

proc graftBlockLoc(b: Block, loc: SourceLocation) =
  if b == nil: return
  b.loc = loc
  for s in b.stmts:
    graftStmtLoc(s, loc)

# ---------------------------------------------------------------------------
# Substitution of $frags (singles + list bindings for $(…)*)
# ---------------------------------------------------------------------------

type
  MacroEnv = object
    singles: Table[string, Expr]
    lists: Table[string, seq[Expr]]

var macroGensymCounter = 0
# Call-site binders introduced via `var $name` / `for $i` (skip gensym)
var expandUnhygienic: HashSet[string]

proc binderIdentFromFrag(env: MacroEnv, name: string): string =
  ## If `name` is a $frag bound to a bare ident, return that ident (unhygienic binder).
  if name.len == 0 or not env.singles.hasKey(name): return ""
  let e = env.singles[name]
  if e != nil and e.kind == ekIdent and e.exprIdent.len > 0:
    return e.exprIdent
  ""

proc gensymLocals(b: Block, callLoc: SourceLocation): Block
proc renameIdents(e: Expr, map: Table[string, string]): Expr
proc renameIdentsStmt(s: Stmt, map: Table[string, string]): Stmt
proc renameIdentsBlock(b: Block, map: Table[string, string]): Block

proc renameIdents(e: Expr, map: Table[string, string]): Expr =
  if e == nil: return nil
  let c = cloneExpr(e)
  if c.kind == ekIdent and map.hasKey(c.exprIdent):
    c.exprIdent = map[c.exprIdent]
  case c.kind
  of ekUnary: c.exprUnaryOperand = renameIdents(c.exprUnaryOperand, map)
  of ekBinary:
    c.exprBinaryLeft = renameIdents(c.exprBinaryLeft, map)
    c.exprBinaryRight = renameIdents(c.exprBinaryRight, map)
  of ekAssign:
    c.exprAssignTarget = renameIdents(c.exprAssignTarget, map)
    c.exprAssignValue = renameIdents(c.exprAssignValue, map)
  of ekCall:
    c.exprCallCallee = renameIdents(c.exprCallCallee, map)
    var args: seq[Expr] = @[]
    for a in c.exprCallArgs: args.add(renameIdents(a, map))
    c.exprCallArgs = args
  of ekBlock: c.exprBlock = renameIdentsBlock(c.exprBlock, map)
  of ekTernary:
    c.exprTernaryCond = renameIdents(c.exprTernaryCond, map)
    c.exprTernaryThen = renameIdents(c.exprTernaryThen, map)
    c.exprTernaryElse = renameIdents(c.exprTernaryElse, map)
  else: discard
  result = c

proc renameIdentsStmt(s: Stmt, map: Table[string, string]): Stmt =
  if s == nil: return nil
  let c = cloneStmt(s)
  case c.kind
  of skLet:
    if map.hasKey(c.stmtLetName):
      c.stmtLetName = map[c.stmtLetName]
    c.stmtLetInit = renameIdents(c.stmtLetInit, map)
  of skExpr: c.stmtExpr = renameIdents(c.stmtExpr, map)
  of skIf:
    c.stmtIfCond = renameIdents(c.stmtIfCond, map)
    c.stmtIfThen = renameIdentsBlock(c.stmtIfThen, map)
    c.stmtIfElse = renameIdentsBlock(c.stmtIfElse, map)
  of skWhile:
    c.stmtWhileCond = renameIdents(c.stmtWhileCond, map)
    c.stmtWhileBody = renameIdentsBlock(c.stmtWhileBody, map)
  of skFor:
    if map.hasKey(c.stmtForVar):
      c.stmtForVar = map[c.stmtForVar]
    c.stmtForIter = renameIdents(c.stmtForIter, map)
    c.stmtForBody = renameIdentsBlock(c.stmtForBody, map)
  of skReturn: c.stmtReturnValue = renameIdents(c.stmtReturnValue, map)
  of skMacroRep:
    c.stmtMacroRepBody = renameIdentsBlock(c.stmtMacroRepBody, map)
  else: discard
  result = c

proc renameIdentsBlock(b: Block, map: Table[string, string]): Block =
  if b == nil: return nil
  result = Block(loc: b.loc, stmts: @[])
  for s in b.stmts:
    result.stmts.add(renameIdentsStmt(s, map))

proc collectLetNames(blk: Block, map: var Table[string, string])
proc collectLetNamesExpr(e: Expr, map: var Table[string, string])

proc collectLetNamesExpr(e: Expr, map: var Table[string, string]) =
  if e == nil: return
  case e.kind
  of ekBlock:
    collectLetNames(e.exprBlock, map)
  of ekUnary:
    collectLetNamesExpr(e.exprUnaryOperand, map)
  of ekBinary:
    collectLetNamesExpr(e.exprBinaryLeft, map)
    collectLetNamesExpr(e.exprBinaryRight, map)
  of ekCall:
    collectLetNamesExpr(e.exprCallCallee, map)
    for a in e.exprCallArgs: collectLetNamesExpr(a, map)
  of ekAssign:
    collectLetNamesExpr(e.exprAssignTarget, map)
    collectLetNamesExpr(e.exprAssignValue, map)
  else:
    discard

proc collectLetNames(blk: Block, map: var Table[string, string]) =
  if blk == nil: return
  for s in blk.stmts:
    if s == nil: continue
    if s.kind == skLet and s.stmtLetName.len > 0 and not map.hasKey(s.stmtLetName):
      # Unhygienic: call-site binder from `var $name` — keep the name
      if s.stmtLetName notin expandUnhygienic:
        inc macroGensymCounter
        map[s.stmtLetName] = "__m" & $macroGensymCounter & "_" & s.stmtLetName
    if s.kind == skFor and s.stmtForVar.len > 0 and not map.hasKey(s.stmtForVar):
      if s.stmtForVar notin expandUnhygienic:
        inc macroGensymCounter
        map[s.stmtForVar] = "__m" & $macroGensymCounter & "_" & s.stmtForVar
    if s.kind == skLet:
      collectLetNamesExpr(s.stmtLetInit, map)
    if s.kind == skExpr:
      collectLetNamesExpr(s.stmtExpr, map)
    if s.kind == skMacroRep:
      collectLetNames(s.stmtMacroRepBody, map)
    if s.kind == skIf:
      collectLetNames(s.stmtIfThen, map)
      collectLetNames(s.stmtIfElse, map)
    if s.kind == skWhile:
      collectLetNames(s.stmtWhileBody, map)
    if s.kind == skFor:
      collectLetNamesExpr(s.stmtForIter, map)
      collectLetNames(s.stmtForBody, map)

proc gensymLocals(b: Block, callLoc: SourceLocation): Block =
  ## Rename template let/var locals so multiple expansions don't collide in CBE.
  if b == nil: return nil
  var map = initTable[string, string]()
  collectLetNames(b, map)
  if map.len == 0:
    return cloneBlock(b)
  result = renameIdentsBlock(b, map)
  if result != nil:
    result.loc = callLoc

proc substExpr(e: Expr, env: MacroEnv, callLoc: SourceLocation): Expr
proc substStmt(s: Stmt, env: MacroEnv, callLoc: SourceLocation): Stmt
proc substBlock(b: Block, env: MacroEnv, callLoc: SourceLocation): Block
proc substStmtsFlat(stmts: seq[Stmt], env: MacroEnv, callLoc: SourceLocation): seq[Stmt]
proc substPattern(p: Pattern, env: MacroEnv, callLoc: SourceLocation): Pattern

proc substPattern(p: Pattern, env: MacroEnv, callLoc: SourceLocation): Pattern =
  ## Substitute `$p:pat` (pkIdent `$name`) with the bound pattern.
  if p == nil: return nil
  if p.kind == pkIdent and env.singles.hasKey(p.patIdent):
    let bound = env.singles[p.patIdent]
    if bound != nil and bound.kind == ekMacroPat:
      result = clonePattern(bound.exprMacroPat)
      if result != nil: result.loc = callLoc
      return
  case p.kind
  of pkRange:
    result = Pattern(kind: pkRange, loc: callLoc,
      patRangeLo: substPattern(p.patRangeLo, env, callLoc),
      patRangeHi: substPattern(p.patRangeHi, env, callLoc),
      patRangeInclusive: p.patRangeInclusive)
  of pkEnum:
    result = Pattern(kind: pkEnum, loc: callLoc, patEnumPath: p.patEnumPath,
      patEnumArgs: @[], patEnumNamed: @[])
    for a in p.patEnumArgs:
      result.patEnumArgs.add(substPattern(a, env, callLoc))
    for nf in p.patEnumNamed:
      result.patEnumNamed.add((nf.name, substPattern(nf.pattern, env, callLoc)))
  of pkStruct:
    result = Pattern(kind: pkStruct, loc: callLoc, patStructName: p.patStructName,
      patStructFields: @[])
    for f in p.patStructFields:
      result.patStructFields.add((f.name, substPattern(f.pattern, env, callLoc)))
  of pkTuple:
    result = Pattern(kind: pkTuple, loc: callLoc, patTupleElements: @[])
    for el in p.patTupleElements:
      result.patTupleElements.add(substPattern(el, env, callLoc))
  of pkGuarded:
    result = Pattern(kind: pkGuarded, loc: callLoc,
      patGuardedInner: substPattern(p.patGuardedInner, env, callLoc),
      patGuardedExpr: substExpr(p.patGuardedExpr, env, callLoc))
  else:
    result = clonePattern(p)
    if result != nil: result.loc = callLoc

proc substBlock(b: Block, env: MacroEnv, callLoc: SourceLocation): Block =
  if b == nil: return nil
  result = Block(loc: callLoc, stmts: substStmtsFlat(b.stmts, env, callLoc))

proc collectListNames(e: Expr, env: MacroEnv, into: var seq[string]) =
  if e == nil: return
  if e.kind == ekIdent and env.lists.hasKey(e.exprIdent):
    if e.exprIdent notin into:
      into.add(e.exprIdent)
  case e.kind
  of ekUnary: collectListNames(e.exprUnaryOperand, env, into)
  of ekBinary:
    collectListNames(e.exprBinaryLeft, env, into)
    collectListNames(e.exprBinaryRight, env, into)
  of ekCall:
    collectListNames(e.exprCallCallee, env, into)
    for a in e.exprCallArgs: collectListNames(a, env, into)
  of ekAssign:
    collectListNames(e.exprAssignTarget, env, into)
    collectListNames(e.exprAssignValue, env, into)
  of ekBlock:
    if e.exprBlock != nil:
      for st in e.exprBlock.stmts:
        if st == nil: continue
        if st.kind == skExpr: collectListNames(st.stmtExpr, env, into)
        elif st.kind == skLet: collectListNames(st.stmtLetInit, env, into)
  else: discard

proc collectListNamesStmt(st: Stmt, env: MacroEnv, into: var seq[string]) =
  if st == nil: return
  case st.kind
  of skExpr: collectListNames(st.stmtExpr, env, into)
  of skLet: collectListNames(st.stmtLetInit, env, into)
  of skIf: collectListNames(st.stmtIfCond, env, into)
  of skReturn: collectListNames(st.stmtReturnValue, env, into)
  of skMacroRep:
    if st.stmtMacroRepBody != nil:
      for inner in st.stmtMacroRepBody.stmts:
        collectListNamesStmt(inner, env, into)
  else: discard

proc substStmtsFlat(stmts: seq[Stmt], env: MacroEnv, callLoc: SourceLocation): seq[Stmt] =
  ## Flatten skMacroRep into repeated statements (zip lists / once for singles).
  result = @[]
  for s in stmts:
    if s == nil: continue
    if s.kind == skMacroRep:
      var listNames: seq[string] = @[]
      if s.stmtMacroRepBody != nil:
        for st in s.stmtMacroRepBody.stmts:
          collectListNamesStmt(st, env, listNames)
      # Nested same-list: if no list names but singles used, expand once
      if listNames.len == 0:
        let body = substBlock(s.stmtMacroRepBody, env, callLoc)
        if body != nil:
          for st in body.stmts:
            result.add(st)
        continue
      # Zip all referenced lists by index
      var n = 0
      for ln in listNames:
        if env.lists.hasKey(ln):
          n = max(n, env.lists[ln].len)
      if n == 0:
        continue
      for i in 0 ..< n:
        var singles = initTable[string, Expr]()
        for k, v in env.singles.pairs: singles[k] = v
        var lists = initTable[string, seq[Expr]]()
        for k, v in env.lists.pairs:
          if k notin listNames:
            lists[k] = v
        for ln in listNames:
          if env.lists.hasKey(ln) and i < env.lists[ln].len:
            singles[ln] = env.lists[ln][i]
        let subEnv = MacroEnv(singles: singles, lists: lists)
        let body = substBlock(s.stmtMacroRepBody, subEnv, callLoc)
        if body != nil:
          for st in body.stmts:
            result.add(st)
    elif s.kind == skExpr and s.stmtExpr != nil and s.stmtExpr.kind == ekIdent and
         env.singles.hasKey(s.stmtExpr.exprIdent):
      let bound = env.singles[s.stmtExpr.exprIdent]
      if bound != nil and bound.kind == ekMacroStmt:
        # Splice `$s:stmt` as a real statement (not an expression)
        result.add(substStmt(bound.exprMacroStmt, env, callLoc))
      else:
        result.add(substStmt(s, env, callLoc))
    else:
      result.add(substStmt(s, env, callLoc))

proc substStmt(s: Stmt, env: MacroEnv, callLoc: SourceLocation): Stmt =
  if s == nil: return nil
  if s.kind == skMacroRep:
    # Should be flattened by substStmtsFlat; expand empty as no-op expr
    return Stmt(kind: skExpr, loc: callLoc,
      stmtExpr: newLiteralExpr(Token(kind: tkIntLiteral, text: "0", loc: callLoc)))
  let c = cloneStmt(s)
  case c.kind
  of skExpr:
    c.stmtExpr = substExpr(c.stmtExpr, env, callLoc)
  of skLet:
    # Unhygienic binder: `var $name: T = …` with $name:ident → call-site name
    let letBn = binderIdentFromFrag(env, c.stmtLetName)
    if letBn.len > 0:
      c.stmtLetName = letBn
      expandUnhygienic.incl(letBn)
    c.stmtLetInit = substExpr(c.stmtLetInit, env, callLoc)
  of skIf:
    c.stmtIfCond = substExpr(c.stmtIfCond, env, callLoc)
    c.stmtIfThen = substBlock(c.stmtIfThen, env, callLoc)
    var eifs: seq[ElseIf] = @[]
    for ei in c.stmtIfElseIfs:
      eifs.add(ElseIf(loc: callLoc, cond: substExpr(ei.cond, env, callLoc),
        blk: substBlock(ei.blk, env, callLoc)))
    c.stmtIfElseIfs = eifs
    c.stmtIfElse = substBlock(c.stmtIfElse, env, callLoc)
  of skWhile:
    c.stmtWhileCond = substExpr(c.stmtWhileCond, env, callLoc)
    c.stmtWhileBody = substBlock(c.stmtWhileBody, env, callLoc)
  of skDoWhile:
    c.stmtDoWhileBody = substBlock(c.stmtDoWhileBody, env, callLoc)
    c.stmtDoWhileCond = substExpr(c.stmtDoWhileCond, env, callLoc)
  of skLoop:
    c.stmtLoopBody = substBlock(c.stmtLoopBody, env, callLoc)
  of skFor:
    let forBn = binderIdentFromFrag(env, c.stmtForVar)
    if forBn.len > 0:
      c.stmtForVar = forBn
      expandUnhygienic.incl(forBn)
    c.stmtForIter = substExpr(c.stmtForIter, env, callLoc)
    c.stmtForBody = substBlock(c.stmtForBody, env, callLoc)
  of skMatch:
    c.stmtMatchSubject = substExpr(c.stmtMatchSubject, env, callLoc)
    var arms: seq[MatchArm] = @[]
    for arm in c.stmtMatchArms:
      arms.add(MatchArm(loc: callLoc, pattern: substPattern(arm.pattern, env, callLoc),
        body: substExpr(arm.body, env, callLoc)))
    c.stmtMatchArms = arms
  of skReturn:
    c.stmtReturnValue = substExpr(c.stmtReturnValue, env, callLoc)
  of skStaticAssert:
    c.stmtStaticAssertCond = substExpr(c.stmtStaticAssertCond, env, callLoc)
    c.stmtStaticAssertMsg = substExpr(c.stmtStaticAssertMsg, env, callLoc)
  of skComptime:
    c.stmtComptimeBlock = substBlock(c.stmtComptimeBlock, env, callLoc)
  of skEmit:
    c.stmtEmitExpr = substExpr(c.stmtEmitExpr, env, callLoc)
  of skDefer:
    c.stmtDeferBody = substExpr(c.stmtDeferBody, env, callLoc)
  of skSwitch:
    c.stmtSwitchExpr = substExpr(c.stmtSwitchExpr, env, callLoc)
    var cases: seq[SwitchCase] = @[]
    for sc in c.stmtSwitchCases:
      cases.add(SwitchCase(loc: callLoc,
        caseValue: substExpr(sc.caseValue, env, callLoc),
        caseBody: substBlock(sc.caseBody, env, callLoc)))
    c.stmtSwitchCases = cases
    c.stmtSwitchDefault = substBlock(c.stmtSwitchDefault, env, callLoc)
  of skMacroRep:
    discard
  else:
    discard
  c.loc = callLoc
  result = c

proc substExpr(e: Expr, env: MacroEnv, callLoc: SourceLocation): Expr =
  if e == nil: return nil
  # Fragment splice: $x → clone of bound argument (already call-site loc)
  if e.kind == ekIdent and env.singles.hasKey(e.exprIdent):
    result = cloneExpr(env.singles[e.exprIdent])
    graftExprLoc(result, callLoc)
    return
  # Bare use of list frag outside $(…)* → first element if any, else 0
  if e.kind == ekIdent and env.lists.hasKey(e.exprIdent):
    let items = env.lists[e.exprIdent]
    if items.len > 0:
      result = cloneExpr(items[0])
      graftExprLoc(result, callLoc)
      return
    return newLiteralExpr(Token(kind: tkIntLiteral, text: "0", loc: callLoc))
  let c = cloneExpr(e)
  case c.kind
  of ekUnary:
    c.exprUnaryOperand = substExpr(c.exprUnaryOperand, env, callLoc)
  of ekPostfix:
    c.exprPostfixOperand = substExpr(c.exprPostfixOperand, env, callLoc)
  of ekBinary:
    c.exprBinaryLeft = substExpr(c.exprBinaryLeft, env, callLoc)
    c.exprBinaryRight = substExpr(c.exprBinaryRight, env, callLoc)
  of ekAssign:
    c.exprAssignTarget = substExpr(c.exprAssignTarget, env, callLoc)
    c.exprAssignValue = substExpr(c.exprAssignValue, env, callLoc)
  of ekTernary:
    c.exprTernaryCond = substExpr(c.exprTernaryCond, env, callLoc)
    c.exprTernaryThen = substExpr(c.exprTernaryThen, env, callLoc)
    c.exprTernaryElse = substExpr(c.exprTernaryElse, env, callLoc)
  of ekRange:
    c.exprRangeLo = substExpr(c.exprRangeLo, env, callLoc)
    c.exprRangeHi = substExpr(c.exprRangeHi, env, callLoc)
  of ekCall:
    c.exprCallCallee = substExpr(c.exprCallCallee, env, callLoc)
    var args: seq[Expr] = @[]
    for a in c.exprCallArgs:
      args.add(substExpr(a, env, callLoc))
    c.exprCallArgs = args
  of ekIndex:
    c.exprIndexObj = substExpr(c.exprIndexObj, env, callLoc)
    c.exprIndexIdx = substExpr(c.exprIndexIdx, env, callLoc)
  of ekField:
    c.exprFieldObj = substExpr(c.exprFieldObj, env, callLoc)
  of ekStructInit:
    var fields: seq[tuple[name: string, value: Expr]] = @[]
    for f in c.exprStructInitFields:
      fields.add((f.name, substExpr(f.value, env, callLoc)))
    c.exprStructInitFields = fields
  of ekSlice:
    var els: seq[Expr] = @[]
    for el in c.exprSliceElements:
      els.add(substExpr(el, env, callLoc))
    c.exprSliceElements = els
  of ekSpread:
    c.exprSpreadOperand = substExpr(c.exprSpreadOperand, env, callLoc)
  of ekTuple:
    var els: seq[Expr] = @[]
    for el in c.exprTupleElements:
      els.add(substExpr(el, env, callLoc))
    c.exprTupleElements = els
  of ekCast:
    c.exprCastOperand = substExpr(c.exprCastOperand, env, callLoc)
  of ekIs:
    c.exprIsOperand = substExpr(c.exprIsOperand, env, callLoc)
  of ekTry:
    c.exprTryOperand = substExpr(c.exprTryOperand, env, callLoc)
  of ekUnwrap:
    c.exprUnwrapOperand = substExpr(c.exprUnwrapOperand, env, callLoc)
  of ekSpawn:
    c.exprSpawnCallee = substExpr(c.exprSpawnCallee, env, callLoc)
    var args: seq[Expr] = @[]
    for a in c.exprSpawnArgs:
      args.add(substExpr(a, env, callLoc))
    c.exprSpawnArgs = args
  of ekAwait:
    c.exprAwaitOperand = substExpr(c.exprAwaitOperand, env, callLoc)
  of ekBorrow:
    c.exprBorrowOperand = substExpr(c.exprBorrowOperand, env, callLoc)
  of ekBlock:
    c.exprBlock = substBlock(c.exprBlock, env, callLoc)
  of ekMatch:
    c.exprMatchSubject = substExpr(c.exprMatchSubject, env, callLoc)
    var arms: seq[MatchArm] = @[]
    for arm in c.exprMatchArms:
      arms.add(MatchArm(loc: callLoc, pattern: substPattern(arm.pattern, env, callLoc),
        body: substExpr(arm.body, env, callLoc)))
    c.exprMatchArms = arms
  of ekStringInterp:
    var ies: seq[Expr] = @[]
    for ie in c.exprInterpExprs:
      ies.add(substExpr(ie, env, callLoc))
    c.exprInterpExprs = ies
  of ekClosure:
    c.exprClosureBody = substBlock(c.exprClosureBody, env, callLoc)
  of ekMacroCall:
    # Nested macro call — expand outer pass will re-walk; still subst args
    var args: seq[Expr] = @[]
    for a in c.exprMacroArgs:
      args.add(substExpr(a, env, callLoc))
    c.exprMacroArgs = args
  else:
    discard
  c.loc = callLoc
  result = c

# ---------------------------------------------------------------------------
# Expand one call
# ---------------------------------------------------------------------------

# Mutual recursion
proc expandExpr(e: Expr, macros: Table[string, Decl], res: var MacroExpandResult,
                depth: int): Expr
proc expandBlock(b: Block, macros: Table[string, Decl], res: var MacroExpandResult,
                 depth: int): Block
proc expandStmt(s: Stmt, macros: Table[string, Decl], res: var MacroExpandResult,
                depth: int): Stmt
proc expandDecl(d: Decl, macros: Table[string, Decl], res: var MacroExpandResult,
                depth: int)

proc expandOneCall(call: Expr, macros: Table[string, Decl],
                   res: var MacroExpandResult, depth: int): Expr =
  if call == nil or call.kind != ekMacroCall:
    return call
  if depth > 32:
    res.emitErr(call.loc, "macro expansion depth exceeded")
    return newLiteralExpr(Token(kind: tkIntLiteral, text: "0", loc: call.loc))

  let name = call.exprMacroName
  # Built-in quote!(e) — identity with call-site graft (hygiene API demo)
  if name == "quote":
    if call.exprMacroArgs.len != 1:
      res.emitErr(call.loc, "quote! expects exactly 1 argument")
      return newLiteralExpr(Token(kind: tkIntLiteral, text: "0", loc: call.loc))
    result = cloneExpr(call.exprMacroArgs[0])
    # Expand nested macros inside quoted expr first
    result = expandExpr(result, macros, res, depth + 1)
    graftExprLoc(result, call.loc)
    return

  if not macros.hasKey(name):
    res.emitErr(call.loc, "unknown macro '" & name & "'")
    return newLiteralExpr(Token(kind: tkIntLiteral, text: "0", loc: call.loc))

  let mdecl = macros[name]
  let nargs = call.exprMacroArgs.len

  # Expand args first
  var args: seq[Expr] = @[]
  for a in call.exprMacroArgs:
    args.add(expandExpr(a, macros, res, depth + 1))

  # Build arg groups: m!(a,b; c,d) → [[a,b],[c,d]]
  var groups: seq[seq[Expr]] = @[]
  if call.exprMacroGroupLens.len == 0:
    groups.add(args)
  else:
    var off = 0
    for glen in call.exprMacroGroupLens:
      var g: seq[Expr] = @[]
      var j = 0
      while j < glen and off < args.len:
        g.add(args[off])
        inc off
        inc j
      groups.add(g)
    # leftover args append to last group
    while off < args.len:
      if groups.len == 0: groups.add(@[])
      groups[^1].add(args[off])
      inc off

  proc fragNames(f: MacroFragment): seq[string] =
    if f.names.len > 0: return f.names
    if f.name.len > 0: return @[f.name]
    @[]

  proc fragKinds(f: MacroFragment): seq[MacroFragKind] =
    if f.kinds.len > 0: return f.kinds
    @[f.kind]

  proc exprToPattern(arg: Expr): Pattern =
    ## Convert a call-site expression into a pattern for `$p:pat`.
    if arg == nil: return nil
    if arg.kind == ekMacroPat: return clonePattern(arg.exprMacroPat)
    case arg.kind
    of ekIdent:
      if arg.exprIdent == "_":
        return Pattern(kind: pkWildcard, loc: arg.loc)
      return Pattern(kind: pkIdent, loc: arg.loc, patIdent: arg.exprIdent)
    of ekLiteral:
      return Pattern(kind: pkLiteral, loc: arg.loc, patLit: arg.exprLit)
    of ekPath:
      return Pattern(kind: pkEnum, loc: arg.loc, patEnumPath: arg.exprPath,
        patEnumArgs: @[], patEnumNamed: @[])
    of ekCall:
      # Enum::Variant(args) or Variant(args)
      var path: seq[string] = @[]
      if arg.exprCallCallee == nil: return nil
      case arg.exprCallCallee.kind
      of ekIdent: path = @[arg.exprCallCallee.exprIdent]
      of ekPath: path = arg.exprCallCallee.exprPath
      else: return nil
      var pargs: seq[Pattern] = @[]
      for a in arg.exprCallArgs:
        let ap = exprToPattern(a)
        if ap == nil: return nil
        pargs.add(ap)
      return Pattern(kind: pkEnum, loc: arg.loc, patEnumPath: path,
        patEnumArgs: pargs, patEnumNamed: @[])
    of ekTuple:
      var elems: seq[Pattern] = @[]
      for el in arg.exprTupleElements:
        let ep = exprToPattern(el)
        if ep == nil: return nil
        elems.add(ep)
      return Pattern(kind: pkTuple, loc: arg.loc, patTupleElements: elems)
    of ekStructInit:
      var fields: seq[tuple[name: string, pattern: Pattern]] = @[]
      for f in arg.exprStructInitFields:
        let fp = exprToPattern(f.value)
        if fp == nil: return nil
        fields.add((f.name, fp))
      return Pattern(kind: pkStruct, loc: arg.loc,
        patStructName: arg.exprStructInitName, patStructFields: fields)
    of ekRange:
      let lo = exprToPattern(arg.exprRangeLo)
      let hi = exprToPattern(arg.exprRangeHi)
      if lo == nil or hi == nil: return nil
      return Pattern(kind: pkRange, loc: arg.loc, patRangeLo: lo, patRangeHi: hi,
        patRangeInclusive: arg.exprRangeInclusive)
    else:
      return nil

  proc coerceArg(k: MacroFragKind, arg: Expr): Expr =
    ## Normalize arg for storage (pat → ekMacroPat). Returns nil if kind fails.
    if arg == nil: return nil
    case k
    of mfkIdent:
      if arg.kind != ekIdent: return nil
      return arg
    of mfkLiteral:
      if arg.kind != ekLiteral: return nil
      return arg
    of mfkBlock:
      if arg.kind != ekBlock: return nil
      return arg
    of mfkStmt:
      if arg.kind == ekMacroStmt: return arg
      # Expression as expression-statement
      if arg.kind in {ekMacroPat}: return nil
      return Expr(kind: ekMacroStmt, loc: arg.loc,
        exprMacroStmt: Stmt(kind: skExpr, loc: arg.loc, stmtExpr: arg))
    of mfkPat:
      let pat = exprToPattern(arg)
      if pat == nil: return nil
      return Expr(kind: ekMacroPat, loc: arg.loc, exprMacroPat: pat)
    of mfkExpr, mfkTt:
      if arg.kind in {ekMacroStmt, ekMacroPat}: return nil
      return arg

  proc fragMatches(k: MacroFragKind, arg: Expr): bool =
    ## Kind constraint at match time (after arg expand).
    coerceArg(k, arg) != nil

  var matched: MacroRule
  var env: MacroEnv
  var found = false
  for rule in mdecl.declMacroRules:
    var e = MacroEnv(singles: initTable[string, Expr](), lists: initTable[string, seq[Expr]]())
    var failed = false
    let nReps = rule.frags.countIt(it.isRep)
    var gi = 0
    var ai = 0
    let useGroups = nReps > 1 and groups.len > 1
    let flat = args

    for frag in rule.frags:
      if failed: break
      let ns = fragNames(frag)
      let ks = fragKinds(frag)
      if frag.isRep:
        let chunk = max(1, ns.len)
        for n in ns:
          e.lists[n] = @[]
        if ns.len == 0:
          failed = true
          break
        if useGroups:
          if gi >= groups.len:
            continue  # empty rep
          let g = groups[gi]
          inc gi
          if g.len mod chunk != 0:
            failed = true
            break
          var i = 0
          while i < g.len:
            for c in 0 ..< chunk:
              let arg = g[i + c]
              let k = if c < ks.len: ks[c] else: mfkExpr
              let coerced = coerceArg(k, arg)
              if coerced == nil:
                failed = true
                break
              e.lists[ns[c]].add(coerced)
            if failed: break
            i += chunk
        else:
          if (flat.len - ai) mod chunk != 0:
            failed = true
            break
          while ai < flat.len:
            for c in 0 ..< chunk:
              let arg = flat[ai]
              let k = if c < ks.len: ks[c] else: mfkExpr
              let coerced = coerceArg(k, arg)
              if coerced == nil:
                failed = true
                break
              e.lists[ns[c]].add(coerced)
              inc ai
            if failed: break
      else:
        var arg: Expr = nil
        if useGroups:
          if gi >= groups.len or ai >= groups[gi].len:
            failed = true
            break
          arg = groups[gi][ai]
          inc ai
          if ai >= groups[gi].len:
            inc gi
            ai = 0
        else:
          if ai >= flat.len:
            failed = true
            break
          arg = flat[ai]
          inc ai
        let k = if ks.len > 0: ks[0] else: frag.kind
        let coerced = coerceArg(k, arg)
        if coerced == nil:
          failed = true
          break
        let n = if ns.len > 0: ns[0] else: frag.name
        e.singles[n] = coerced

    if not failed:
      if useGroups:
        if gi < groups.len: failed = true
      else:
        if ai != flat.len: failed = true

    if failed: continue
    matched = rule
    env = e
    found = true
    break

  if not found:
    res.emitErr(call.loc, "macro '" & name & "' has no matching rule for " &
      $nargs & " argument(s)")
    return newLiteralExpr(Token(kind: tkIntLiteral, text: "0", loc: call.loc))

  if matched.body == nil:
    res.emitErr(call.loc, "macro '" & name & "' rule has empty body")
    return newLiteralExpr(Token(kind: tkIntLiteral, text: "0", loc: call.loc))

  # Splice $frags / $(…)* , then gensym hygienic locals (skip unhygienic binders)
  expandUnhygienic = initHashSet[string]()
  let body = substBlock(matched.body, env, call.loc)
  let body2 = gensymLocals(body, call.loc)
  result = Expr(kind: ekBlock, loc: call.loc, exprBlock: body2)
  # Expand any macro calls introduced by substitution
  result = expandExpr(result, macros, res, depth + 1)

# ---------------------------------------------------------------------------
# Walk + expand trees
# ---------------------------------------------------------------------------

proc expandExpr(e: Expr, macros: Table[string, Decl], res: var MacroExpandResult,
                depth: int): Expr =
  if e == nil: return nil
  if e.kind == ekMacroCall:
    return expandOneCall(e, macros, res, depth)

  case e.kind
  of ekUnary:
    e.exprUnaryOperand = expandExpr(e.exprUnaryOperand, macros, res, depth)
  of ekPostfix:
    e.exprPostfixOperand = expandExpr(e.exprPostfixOperand, macros, res, depth)
  of ekBinary:
    e.exprBinaryLeft = expandExpr(e.exprBinaryLeft, macros, res, depth)
    e.exprBinaryRight = expandExpr(e.exprBinaryRight, macros, res, depth)
  of ekAssign:
    e.exprAssignTarget = expandExpr(e.exprAssignTarget, macros, res, depth)
    e.exprAssignValue = expandExpr(e.exprAssignValue, macros, res, depth)
  of ekTernary:
    e.exprTernaryCond = expandExpr(e.exprTernaryCond, macros, res, depth)
    e.exprTernaryThen = expandExpr(e.exprTernaryThen, macros, res, depth)
    e.exprTernaryElse = expandExpr(e.exprTernaryElse, macros, res, depth)
  of ekRange:
    e.exprRangeLo = expandExpr(e.exprRangeLo, macros, res, depth)
    e.exprRangeHi = expandExpr(e.exprRangeHi, macros, res, depth)
  of ekCall:
    e.exprCallCallee = expandExpr(e.exprCallCallee, macros, res, depth)
    for i in 0 ..< e.exprCallArgs.len:
      e.exprCallArgs[i] = expandExpr(e.exprCallArgs[i], macros, res, depth)
  of ekIndex:
    e.exprIndexObj = expandExpr(e.exprIndexObj, macros, res, depth)
    e.exprIndexIdx = expandExpr(e.exprIndexIdx, macros, res, depth)
  of ekField:
    e.exprFieldObj = expandExpr(e.exprFieldObj, macros, res, depth)
  of ekStructInit:
    for i in 0 ..< e.exprStructInitFields.len:
      e.exprStructInitFields[i].value =
        expandExpr(e.exprStructInitFields[i].value, macros, res, depth)
  of ekSlice:
    for i in 0 ..< e.exprSliceElements.len:
      e.exprSliceElements[i] = expandExpr(e.exprSliceElements[i], macros, res, depth)
  of ekSpread:
    e.exprSpreadOperand = expandExpr(e.exprSpreadOperand, macros, res, depth)
  of ekTuple:
    for i in 0 ..< e.exprTupleElements.len:
      e.exprTupleElements[i] = expandExpr(e.exprTupleElements[i], macros, res, depth)
  of ekCast:
    e.exprCastOperand = expandExpr(e.exprCastOperand, macros, res, depth)
  of ekIs:
    e.exprIsOperand = expandExpr(e.exprIsOperand, macros, res, depth)
  of ekTry:
    e.exprTryOperand = expandExpr(e.exprTryOperand, macros, res, depth)
  of ekUnwrap:
    e.exprUnwrapOperand = expandExpr(e.exprUnwrapOperand, macros, res, depth)
  of ekSpawn:
    e.exprSpawnCallee = expandExpr(e.exprSpawnCallee, macros, res, depth)
    for i in 0 ..< e.exprSpawnArgs.len:
      e.exprSpawnArgs[i] = expandExpr(e.exprSpawnArgs[i], macros, res, depth)
  of ekAwait:
    e.exprAwaitOperand = expandExpr(e.exprAwaitOperand, macros, res, depth)
  of ekBorrow:
    e.exprBorrowOperand = expandExpr(e.exprBorrowOperand, macros, res, depth)
  of ekBlock:
    e.exprBlock = expandBlock(e.exprBlock, macros, res, depth)
  of ekMatch:
    e.exprMatchSubject = expandExpr(e.exprMatchSubject, macros, res, depth)
    for i in 0 ..< e.exprMatchArms.len:
      e.exprMatchArms[i].body = expandExpr(e.exprMatchArms[i].body, macros, res, depth)
  of ekStringInterp:
    for i in 0 ..< e.exprInterpExprs.len:
      e.exprInterpExprs[i] = expandExpr(e.exprInterpExprs[i], macros, res, depth)
  of ekClosure:
    e.exprClosureBody = expandBlock(e.exprClosureBody, macros, res, depth)
  else:
    discard
  result = e

proc expandBlock(b: Block, macros: Table[string, Decl], res: var MacroExpandResult,
                 depth: int): Block =
  if b == nil: return nil
  for i in 0 ..< b.stmts.len:
    b.stmts[i] = expandStmt(b.stmts[i], macros, res, depth)
  result = b

proc expandStmt(s: Stmt, macros: Table[string, Decl], res: var MacroExpandResult,
                depth: int): Stmt =
  if s == nil: return nil
  case s.kind
  of skExpr:
    s.stmtExpr = expandExpr(s.stmtExpr, macros, res, depth)
  of skLet:
    s.stmtLetInit = expandExpr(s.stmtLetInit, macros, res, depth)
  of skIf:
    s.stmtIfCond = expandExpr(s.stmtIfCond, macros, res, depth)
    s.stmtIfThen = expandBlock(s.stmtIfThen, macros, res, depth)
    for i in 0 ..< s.stmtIfElseIfs.len:
      s.stmtIfElseIfs[i].cond = expandExpr(s.stmtIfElseIfs[i].cond, macros, res, depth)
      s.stmtIfElseIfs[i].blk = expandBlock(s.stmtIfElseIfs[i].blk, macros, res, depth)
    s.stmtIfElse = expandBlock(s.stmtIfElse, macros, res, depth)
  of skWhile:
    s.stmtWhileCond = expandExpr(s.stmtWhileCond, macros, res, depth)
    s.stmtWhileBody = expandBlock(s.stmtWhileBody, macros, res, depth)
  of skDoWhile:
    s.stmtDoWhileBody = expandBlock(s.stmtDoWhileBody, macros, res, depth)
    s.stmtDoWhileCond = expandExpr(s.stmtDoWhileCond, macros, res, depth)
  of skLoop:
    s.stmtLoopBody = expandBlock(s.stmtLoopBody, macros, res, depth)
  of skFor:
    s.stmtForIter = expandExpr(s.stmtForIter, macros, res, depth)
    s.stmtForBody = expandBlock(s.stmtForBody, macros, res, depth)
  of skMatch:
    s.stmtMatchSubject = expandExpr(s.stmtMatchSubject, macros, res, depth)
    for i in 0 ..< s.stmtMatchArms.len:
      s.stmtMatchArms[i].body = expandExpr(s.stmtMatchArms[i].body, macros, res, depth)
  of skReturn:
    s.stmtReturnValue = expandExpr(s.stmtReturnValue, macros, res, depth)
  of skStaticAssert:
    s.stmtStaticAssertCond = expandExpr(s.stmtStaticAssertCond, macros, res, depth)
    s.stmtStaticAssertMsg = expandExpr(s.stmtStaticAssertMsg, macros, res, depth)
  of skComptime:
    s.stmtComptimeBlock = expandBlock(s.stmtComptimeBlock, macros, res, depth)
  of skEmit:
    s.stmtEmitExpr = expandExpr(s.stmtEmitExpr, macros, res, depth)
  of skDefer:
    s.stmtDeferBody = expandExpr(s.stmtDeferBody, macros, res, depth)
  of skSwitch:
    s.stmtSwitchExpr = expandExpr(s.stmtSwitchExpr, macros, res, depth)
    for i in 0 ..< s.stmtSwitchCases.len:
      s.stmtSwitchCases[i].caseValue =
        expandExpr(s.stmtSwitchCases[i].caseValue, macros, res, depth)
      s.stmtSwitchCases[i].caseBody =
        expandBlock(s.stmtSwitchCases[i].caseBody, macros, res, depth)
    s.stmtSwitchDefault = expandBlock(s.stmtSwitchDefault, macros, res, depth)
  of skDecl:
    expandDecl(s.stmtDecl, macros, res, depth)
  else:
    discard
  result = s

proc expandDecl(d: Decl, macros: Table[string, Decl], res: var MacroExpandResult,
                depth: int) =
  if d == nil: return
  case d.kind
  of dkFunc:
    if d.declFuncBody != nil:
      d.declFuncBody = expandBlock(d.declFuncBody, macros, res, depth)
  of dkImpl:
    for m in d.declImplMethods:
      expandDecl(m, macros, res, depth)
  of dkModule:
    for it in d.declModuleItems:
      expandDecl(it, macros, res, depth)
  of dkConst:
    d.declConstValue = expandExpr(d.declConstValue, macros, res, depth)
  of dkInterface:
    for m in d.declInterfaceMethods:
      expandDecl(m, macros, res, depth)
  of dkExternBlock:
    for it in d.declExtBlockItems:
      expandDecl(it, macros, res, depth)
  else:
    discard

proc collectMacroDeclsFrom(d: Decl, tab: var Table[string, Decl]) =
  if d == nil: return
  case d.kind
  of dkMacro:
    if not tab.hasKey(d.declMacroName):
      tab[d.declMacroName] = d
  of dkModule:
    for it in d.declModuleItems:
      collectMacroDeclsFrom(it, tab)
  else:
    discard

proc collectMacroDecls(modu: Module): Table[string, Decl] =
  result = initTable[string, Decl]()
  for it in modu.items:
    collectMacroDeclsFrom(it, result)

proc expandMacros*(modu: Module): MacroExpandResult =
  ## Expand all declarative macro! invocations in the module (in place).
  result = MacroExpandResult(diagnostics: @[])
  let macros = collectMacroDecls(modu)
  for d in modu.items:
    expandDecl(d, macros, result, 0)
