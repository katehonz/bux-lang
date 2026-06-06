import "../bootstrap/lexer", "../bootstrap/parser", "../bootstrap/ast"

let source = readFile("../src/ast.bux")
let lexRes = tokenize(source, "ast.bux")
let res = parse(lexRes.tokens, "ast.bux")
if res.module != nil:
  echo "Module items: ", res.module.items.len
  for decl in res.module.items:
    if decl.kind == dkStruct:
      echo "Struct: ", decl.declStructName, " fields: ", decl.declStructFields.len
    elif decl.kind == dkModule:
      echo "Inner module: ", decl.declModuleName, " items: ", decl.declModuleItems.len
      for inner in decl.declModuleItems:
        if inner.kind == dkStruct:
          echo "  Struct: ", inner.declStructName, " fields: ", inner.declStructFields.len
