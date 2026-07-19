# greet

Demo package for the Bux registry (`config/registry.toml`).

```bash
bux add greet
bux install
```

```bux
func Main() -> int {
    PrintLine(Greet_Hello("Bux"));
    return 0;
}
```
