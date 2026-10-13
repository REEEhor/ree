# The REE programming language

This repo contains (or rather.. will contain :D) a compiler for my own programming language 'REE'.
This project is a semestral work for the project NI-GEN (code generators) at FIT CTU.

---

## Checkpoint 0 (Project githup repo & outline)

REE is planned to be more-or less a simple subset of (Tiny)C with some tweaks to the syntax.

- **Syntax** - the syntax changes with respect to C:
    - Instead of `int x = 42;`, we write `var x: i32 = 42;`.
    - Functions are declared as `val sum = fn(a: i32, b: i32) i32 { return a+b; };`.
    - Structs are declared as `val Person = struct { age: i32; name: []u8; };`
    - Pointer syntax is modified as follows:
        - `int *ptr` -> `var ptr: ^int`
        - `a = *ptr` -> `a = ptr^`
        - `ptr = &a` -> `ptr = ^a`

- **The `->` operator**
    - If I get to it, I plan on implementing the `->` binary operator, which takes in an expression and 'pipes' it into a function as a first argument.
    - This means that `sum((10+20), 30)` is equivalent to `(10+20)->sum(30)`.
    - Another example is `sayHi(person)` being equivalent to `person->sayHi()`.

- **Slices**
    - I am considering to have built-in slices into the language, such as `[]u8` or `[]Person`.
    - The type `[]u8` is basically the same as a `struct {ptr: *u8; len: u64}`, with the postfix operator `[]`.

- **Intermediate representation**
    - The REE compiler uses its own intermediate representation, as I don't want to bloat-up this project with LLVM dependencies :D
    - As of wrinting this, the project has a simple 3 address IR.

- **Target x86**
    - I am targetting x86 64 bits. Mainly to have an excuse to learn assembly at least to some basic level.

### Current state of the project
My compiler is able to compile a `.ree` file into a `.s` file. I am currenlty compiling only simple arithmetic expressions, declaration of variables and printing integers to stdout.
All types are `i32` so far.
See `playground/` or `test/inputs/parser/` for examples.
The project uses Zig 0.16.


