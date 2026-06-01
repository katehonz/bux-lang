import "../src/lexer", "../src/parser", "../src/ast", "../src/token"
import std/os

let source = readFile("../_selfhost/src/ast.bux")
let lexRes = tokenize(source, "ast.bux")
echo "Tokens: ", lexRes.tokens.len
echo "Errors: ", lexRes.hasErrors
let res = parse(lexRes.tokens, "ast.bux")
if res.module == nil:
  echo "Parse failed, diagnostics: ", res.diagnostics.len
  for d in res.diagnostics:
    echo "  ", d.message
else:
  echo "Parsed OK, items: ", res.module.items.len
  for i, decl in res.module.items:
    echo "Decl ", i, " kind=", decl.kind, " name=", decl.declFuncName
