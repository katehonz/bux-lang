# SimpleDB

File-backed key-value database for Bux.

## Usage

```
simpledb <dbfile> set <key> <value>
simpledb <dbfile> get <key>
simpledb <dbfile> del <key>
simpledb <dbfile> has <key>
simpledb <dbfile> keys
simpledb <dbfile> count
```

## Examples

```sh
$ simpledb data.db set name BuxLang
OK  name = BuxLang

$ simpledb data.db set version 0.1.0
OK  version = 0.1.0

$ simpledb data.db get name
BuxLang

$ simpledb data.db has name
true  name

$ simpledb data.db keys
keys: 2
  name
  version

$ simpledb data.db count
count: 2

$ simpledb data.db del version
DEL version

$ cat data.db
name=BuxLang
```

## Storage

Data is stored as plain text, one `key=value` per line. The file is created automatically on first write.

## Build

```sh
# workaround: disable broken JWT module
mv ../../lib/crypto/jwt.bux ../../lib/crypto/jwt.bux.bak
../../buxc build
mv ../../lib/crypto/jwt.bux.bak ../../lib/crypto/jwt.bux
```

## API

The `Database` struct and its functions are defined in `src/Main.bux` and can be imported into other Bux projects:

```bux
import Simpledb::{Database, DB_New, DB_Load, DB_Save, DB_Get, DB_Set, DB_Del, DB_Has, DB_Count, DB_Keys};
```

| Function | Signature |
|----------|-----------|
| `DB_New` | `(path: String) -> Database` |
| `DB_Load` | `(db: *Database) -> bool` |
| `DB_Save` | `(db: *Database) -> bool` |
| `DB_Get` | `(db: *Database, key: String) -> String` |
| `DB_Set` | `(db: *Database, key: String, value: String)` |
| `DB_Del` | `(db: *Database, key: String) -> bool` |
| `DB_Has` | `(db: *Database, key: String) -> bool` |
| `DB_Count` | `(db: *Database) -> uint` |
| `DB_Keys` | `(db: *Database) -> *String` |
