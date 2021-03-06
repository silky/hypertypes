# AST Terms

Common terms:

* `Apply`: Function application
* `Lam`: Lambdas with named variables
* `Var`: Named variables
* `Let`: Let clauses with generalization
* `TypeSig`: A term with a type signature
* `FuncType`: Type of functions (used as type in `Apply`, `Lam`, `Scope`)
* `Scheme`: A type scheme (a type with "for-alls")
* `NamelessScope`: "Locally-nameless" variable scoping in the spirit of the [`bound`](https://github.com/ekmett/bound/) library
* `Map`: Mapping of keys to sub-expressions, can be used to map record field names to their types.
