# Blorp Formal Grammar (EBNF)

This is the formal grammar for the blorp programming language in Extended Backus-Naur Form (EBNF).
It is the authoritative specification. The implementation lives in the Blorp
frontend sources under `compiler/blorp/src/stage_02_lex/lexer.brp` and
`compiler/blorp/src/stage_03_parse/language_parser.brp`.

The grammar defines the shape of source text. Name resolution, scoping, UFCS
dispatch, trait coherence, orphan rules, and dimension-variable interpretation
are semantic checks implemented after parsing; they are summarized in the
Language Guide and compiler architecture docs rather than specified by this
grammar.

## Notation

```
=           definition
|           alternation
[ ... ]     optional (0 or 1)
{ ... }     repetition (0 or more)
( ... )     grouping
"..."       terminal string (keyword/operator)
UPPER       terminal token from lexer
lower       non-terminal
```

## Lexical Structure

Blorp uses indentation-sensitive lexing. The lexer emits `INDENT` and `DEDENT` tokens
based on indentation changes. `NEWLINE` tokens separate statements.
Inside balanced delimiters (`()`, `[]`, `{}`), newlines are ignored.
For method chains, a more-indented line that starts with `.identifier`
continues the previous expression instead of starting an indented block.

### Keywords

```
func   pure   var   union   enum   record   struct   void
while  for    in    if      else   and      or       not
break  continue    match   import   as       private   on
debug  resource     implements   trait   Self   type   alias   opaque
builtin    foreign      concurrent    concurrently    detach      where
select     from         after         sealed         into
True   False
```

Declarations are public by default; `private` hides a declaration from
importers. There is no `export` keyword.
`try` remains reserved only so the parser can diagnose removed `try:` blocks;
it is not part of the accepted grammar.

### Operators and Delimiters

```
(  )  [  ]  {  }
:  ,  .  ..  ...  +  -  *  /  _
<  >  %  #  @  ->  <=  >=  ==  !=  =
+=  -=  *=  /=  ?=  =>  |
```

### Literals

```
INT                  = digit { digit }
BIGINT               = digit { digit }              (* integer literal outside Int64 range *)
FLOAT                = digit { digit } "." digit { digit } [ ("e" | "E") ["+" | "-"] digit { digit } ]
STRING               = '"' { string_char } '"'
STRING_INTERP        = '"' { string_char_or_interp } '"'
RAW_STRING           = 'raw"' { any_char_except_quote } '"'
PIPE_STRING          = aligned_pipe_line { newline aligned_pipe_line }
RAW_PIPE_STRING      = "raw" newline aligned_pipe_line { newline aligned_pipe_line }
CHAR                 = "'" unicode_char "'"
IDENT                = (letter | "_") { letter | digit | "_" }
DOCSTRING            = "---" newline { line } "---"
```

`aligned_pipe_line` is indentation followed by `|` and line content. All lines
in the same pipe string must use the same `|` column. Use `||` for a literal
leading pipe in the content.

### Comments

```
comment = "--" { any_char_except_newline }
```

## Grammar

### Program

```ebnf
program = { NEWLINE } decl_list EOF ;

decl_list = { decl { NEWLINE } | import_block { NEWLINE } | foreign_block { NEWLINE } } ;
```

### Declarations

```ebnf
decl = [ docstring ] ( func_decl
                      | type_decl
                      | enum_decl
                      | record_decl
                      | struct_decl
                      | var_decl
                      | trait_decl
                      | impl_decl
                      | type_alias_decl
                      | "private" decl ) ;

docstring = DOCSTRING ;
```

### Function Declaration

```ebnf
func_decl = { annotation } [ "pure" ] "func" name [ type_params ] params [ "->" type_expr ] [ where_clause ] ":" func_body ;

annotation = "@" IDENT [ NEWLINE ]
           | "@" IDENT "(" INT ")" [ NEWLINE ] ;

func_body = expr
          | NEWLINE INDENT stmt_list DEDENT
          | NEWLINE ;                           (* forward declaration *)

where_clause = "where" dim_constraint { "," dim_constraint } ;
dim_constraint = dim_expr "==" dim_expr ;

stmt_list = stmt { NEWLINE stmt } ;
```

Compiler-recognized function annotations include `@tail_recursive` and
`@debug_only`. `@debug_only` is declaration metadata: calls and function
references to that declaration are valid only inside `debug:` blocks, in
`--debug` builds, or when compiled by `blorp test`. Normal builds erase
`debug:` block bodies after Core lowering; `--debug` builds and `blorp test`
retain them.

### Type Parameters

```ebnf
type_params = "[" [ type_param { "," type_param } [ "," ] ] "]" ;

type_param = IDENT                              (* T *)
           | "#" IDENT                          (* #N — dimension param *)
           | "#" "_"                            (* #_ — wildcard dim *)
           | IDENT ":" bounds ;                 (* T: Equatable + Orderable *)

bounds = IDENT { "+" IDENT } ;
```

Type parameter names must start with a capital ASCII letter and contain only
ASCII letters and digits (`T`, `Elem`, `Item2`). Dimension parameters use the
same rule after `#` (`#N`, `#Rows`); `#_` is the wildcard dimension exception.

The `type_params` list is optional. If a capitalized alphanumeric name or a
`#`-prefixed dim (`#N`, `#Ds...`) appears in `params` or `type_expr` without
being declared as a type (record, union, alias) anywhere in the program,
typechecking auto-generalizes it as an implicit type parameter. See the Type
Inference section of GUIDE.md for details.

### Parameters

```ebnf
params = "(" [ param { "," param } [ "," ] ] ")" ;

param = IDENT ":" type_expr                     (* named with type *)
      | IDENT                                   (* named, type inferred *)
      | "_"                                     (* discard *)
      | "_" ":" type_expr                       (* discard with type *)
      | tuple_param [ ":" type_expr ] ;         (* 2-4 element tuple destructure *)

tuple_param = "(" IDENT "," IDENT [ "," IDENT [ "," IDENT ] ] [ "," ] ")" ;
```

### Statements

```ebnf
stmt = var_decl
     | IDENT "=" expr                           (* assignment *)
     | "while" expr ":" NEWLINE INDENT stmt_list DEDENT
     | "for" IDENT "in" expr ":" NEWLINE INDENT stmt_list DEDENT
     | "for" "_" "in" expr ":" NEWLINE INDENT stmt_list DEDENT
     | "for" "(" destruct_ids ")" "in" expr ":" NEWLINE INDENT stmt_list DEDENT
     | IDENT "?=" expr                          (* question-bind *)
     | IDENT ":" type_expr "?=" expr            (* typed question-bind *)
     | [ "pure" ] "func" name [ type_params ] params [ "->" type_expr ] [ where_clause ] ":" func_body
                                                   (* nested function declaration *)
     | "debug" ":" NEWLINE INDENT stmt_list DEDENT
     | expr ;

destruct_ids = destruct_id "," destruct_id [ "," destruct_id [ "," destruct_id ] ] [ "," ] ;
destruct_id  = IDENT | "_" ;
```

### Variable Declaration

```ebnf
var_decl = "var" IDENT [ ":" type_expr ] var_initializer    (* mutable *)
         | IDENT [ ":" type_expr ] var_initializer ;         (* immutable *)

var_initializer = "=" expr
                | "=" NEWLINE INDENT expr DEDENT ;
```

**Semantic constraints:**
- Immutable top-level bindings are constants. Function, method, and closure
  calls in immutable global initializers must be pure and evaluatable by the
  compile-time evaluator. Union constructors are data construction and are
  allowed.
- Mutable top-level `var` initializers cannot call a function, method, or
  closure, because mutable globals are not constants and calls there would
  create hidden startup work.
- Subscript expressions in top-level initializers are accepted only when the
  checker can prove or lower them without unsupported runtime helper work.

### Type Declarations

```ebnf
type_decl = "union" IDENT [ type_params ] ":" NEWLINE INDENT variant_list DEDENT
          | "type" IDENT [ type_params ] "=" "builtin"   (* std-only *)
          | "resource" "type" IDENT [ type_params ] "=" "builtin"
              [ "(" STRING ")" ] ;  (* std-only; optional cleanup builtin *)

enum_decl = "enum" IDENT ":" NEWLINE INDENT variant_list DEDENT ;

variant_list = variant { NEWLINE variant } ;
variant      = variant_name [ "(" type_expr { "," type_expr } [ "," ] ")" ] ;
variant_name = IDENT | "True" | "False" ;

record_decl = "record" IDENT [ type_params ] "{" field_list "}"
            | "record" IDENT [ type_params ] "{" "builtin" "}" ;
struct_decl = "struct" IDENT "{" field_list "}" ;

field_list = [ field_decl { "," field_decl } [ "," ] ] ;
field_decl = identifier ":" type_expr ;

type_alias_decl = "type" "alias" IDENT [ type_params ] "=" type_expr
                | "opaque" "type" IDENT [ type_params ] "=" type_expr ;
```

### Import System

```ebnf
import_block = "import" ":" NEWLINE INDENT { import_item { NEWLINE } } DEDENT ;

(* All forms: bare, qualified, selective, or combined qualified + selective *)
import_item = module_path [ "as" identifier ]
              [ ":" import_syms_inline
              | ":" NEWLINE INDENT import_sym_lines DEDENT ] ;

import_syms_inline = import_sym { "," import_sym } ;

import_sym_line = import_sym { "," import_sym } [ "," ] ;

import_sym_lines = import_sym_line { NEWLINE import_sym_line } [ NEWLINE ] ;

import_sym = name [ "as" IDENT ]
           | name "(" name { "," name } [ "," ] ")" ;

module_path = module_part { "/" module_part }
            | "./" module_part { "/" module_part }
            | { "../" } module_part { "/" module_part } ;

module_part = identifier ;
identifier  = IDENT | "debug" | "with" | "concurrent" | "select" | "after" | "sealed" ;
```

**Semantic constraints:**
- Each module may appear at most once per file. If a module needs both an alias
  and selected symbols, use one combined import item.
- Brace selective imports are not supported; use `module: name1, name2`.
- Wildcard imports are not supported.
- A module alias introduced with `as` must not reuse an already visible declaration name, including a type, constructor, trait, function, or top-level variable.
- A selective import's local name, after any `as` alias, must be unique in the file and must not reuse a module alias or top-level declaration name. Import same-named symbols from different modules by giving each one a distinct alias.

### Foreign Function Interface

```ebnf
foreign_block = "foreign" foreign_dispatch ;

foreign_dispatch = "(" foreign_args ")" ":" NEWLINE INDENT { foreign_item { NEWLINE } } DEDENT
                 | ":" NEWLINE INDENT { foreign_item { NEWLINE } } DEDENT ;

foreign_args = foreign_arg { "," foreign_arg } ;
foreign_arg  = IDENT ":" STRING ;

foreign_item = [ "private" ] { annotation_inline } [ "pure" ] "func" name params "->" type_expr [ "=" STRING ] ;
annotation_inline = "@" IDENT [ "(" INT ")" ] ;
```

**Semantic constraints:**
- `include:` names a C header to emit in generated C. Relative header paths are resolved from the `.brp` file that declares the foreign function.
- `link:`, `link_linux:`, and `link_macos:` carry restricted C compiler/linker flags. Accepted tokens are `-lNAME`, `-LDIR`, `-IDIR`, `-framework NAME`, and `-pthread`. Object/archive filenames and raw linker escapes such as `-Wl,...` are rejected. Link flags are not needed for headers that live next to the declaring `.brp` file.

### Trait System

```ebnf
trait_decl = "trait" IDENT [ type_params ] ":" NEWLINE INDENT trait_methods DEDENT
           | "trait" IDENT ":" supertrait_list NEWLINE
           | "trait" IDENT [ type_params ] ":" supertrait_list ":" NEWLINE INDENT trait_methods DEDENT ;

supertrait_list = IDENT { "+" IDENT } ;

trait_methods = trait_method { NEWLINE trait_method } ;

trait_method = [ "pure" ] "func" name params [ "->" type_expr ]                 (* abstract *)
             | [ "pure" ] "func" name params "->" type_expr ":" trait_body ;    (* default *)

trait_body = expr | NEWLINE INDENT stmt_list DEDENT ;

impl_decl = "implements" IDENT "for" type_expr ":"
            NEWLINE INDENT impl_methods DEDENT ;
(* Bounds on type params use inline syntax: Type[T: Bound] *)

impl_methods = impl_method { NEWLINE impl_method } ;
impl_method  = [ "pure" ] "func" name [ type_params ] params [ "->" type_expr ] [ where_clause ] ":" func_body ;
```

Receiver type parameters introduced by `impl_decl` are in scope throughout
its methods. An `impl_method` may introduce additional type parameters, but it
must not redeclare a receiver type parameter with the same name.

### Type Expressions

```ebnf
type_expr = type_primary { array_suffix } ;

type_primary = IDENT                                        (* simple: Int, String *)
             | IDENT "[" type_args "]"                      (* generic or tensor: List[Int], Int[#3] *)
             | IDENT "." IDENT                              (* qualified: Module.Type *)
             | IDENT "." IDENT "[" type_args "]"            (* qualified generic/tensor *)
             | "#" IDENT                                    (* dim variable: #N *)
             | "#" INT                                      (* dim literal: #32 *)
             | ".." "#" INT                                 (* range type: ..#5 *)
             | ".." "#" IDENT                               (* range type: ..#N *)
             | "Self"                                       (* self type *)
             | "(" ")"                                      (* Void *)
             | "(" ")" "->" type_expr                       (* nullary function *)
             | "pure" "(" [ type_list ] ")" "->" type_expr  (* pure function *)
             | "(" type_list ")" "->" type_expr             (* function type *)
             | "(" type_list ")"                            (* tuple or grouping *) ;

array_suffix = "[" array_dim_arg { "," array_dim_arg } [ "," ] "]" ;

type_args = type_arg { "," type_arg } [ "," ] ;

type_arg = type_expr
         | dim_expr
         | IDENT ":" bounds                                 (* bounded type arg *)
         | "#" "_"                                          (* wildcard dim *)
         | "#" IDENT "..." ;                                (* variadic dim *)

array_dim_arg = dim_expr
              | "#" "_"
              | "#" "_" "..."
              | "#" IDENT "..." ;

type_list = tuple_elem { "," tuple_elem } [ "," ] ;
tuple_elem = type_expr | IDENT ":" bounds ;

dim_expr = dim_mul { ("+" | "-") dim_mul } ;
dim_mul  = dim_atom { ("*" | "/") dim_atom } ;
dim_atom = "#" IDENT | "#" INT | INT | "(" dim_expr ")" ;
```

### Expressions

```ebnf
expr = assign_expr ;

assign_expr = postfix_expr "=" assign_expr              (* assignment / destruct *)
            | IDENT ("+=" | "-=" | "*=" | "/=") assign_expr
            | ascription_expr ;

ascription_expr = or_expr [ "as" type_expr ] ;

or_expr  = or_expr "or" { NEWLINE } and_expr | and_expr ;
and_expr = and_expr "and" { NEWLINE } cmp_expr | cmp_expr ;

cmp_expr = cmp_expr ("==" | "!=" | "<" | ">" | "<=" | ">=") { NEWLINE } range_expr
         | range_expr ;

range_expr = add_expr ".." add_expr | add_expr ;

add_expr = add_expr ("+" | "-") { NEWLINE } mul_expr | mul_expr ;
mul_expr = mul_expr ("*" | "/" | "%") { NEWLINE } unary_expr | unary_expr ;

unary_expr = "-" unary_expr
           | "not" unary_expr
           | postfix_expr ;

postfix_expr = postfix_expr "." identifier                  (* field access *)
             | postfix_expr "(" [ expr_list ] ")"           (* function call *)
             | postfix_expr "[" expr_list "]"               (* subscript *)
             | primary_expr ;

expr_list = expr { "," expr } [ "," ] ;
```

`as` is expression type ascription, not a cast. It binds lower than
`or`, `and`, comparisons, ranges, arithmetic, unary operators, and postfix
calls/field access, but higher than comma and argument separation. Therefore
`1 + 2 as Int32` parses as `(1 + 2) as Int32`; use parentheses for
operand-level ascription such as `(1 as Int32) + (2 as Int32)`.

### Primary Expressions

```ebnf
primary_expr = INT | BIGINT | FLOAT | STRING | RAW_STRING
             | PIPE_STRING | RAW_PIPE_STRING
             | STRING_INTERP
             | CHAR | "True" | "False"
             | "into" opaque_conversion_type "(" expr ")"
             | "from" opaque_conversion_type "(" expr ")"
             | IDENT | "debug"
             | "_" | "void"
             | "break" | "continue"
             | "builtin" [ "(" STRING ")" ]                 (* std function
                                                                bodies use the
                                                                named form *)
             | "(" ")"                                      (* void literal *)
             | "(" expr ")"                                 (* grouping *)
             | "(" expr "," expr_list ")"                   (* tuple *)
             | lambda_expr
             | "[" [ expr_list ] "]"                        (* list literal *)
             | "{" dict_pairs "}"                           (* dict literal *)
             | "{" [ field_inits ] "}"                      (* record literal *)
             | "{" or_expr "|" field_inits "}"              (* record update *)
             | "{" vector_elems "}"                         (* vector literal *)
             | if_expr
             | match_expr
             | select_expr
             | with_expr
             | concurrent_expr
             | detach_expr ;

dict_pairs  = dict_pair { "," dict_pair } [ "," ] ;
dict_pair   = or_expr "=>" expr ;
vector_elems = or_expr { "," or_expr } [ "," ] ;

opaque_conversion_type = IDENT [ "[" type_arg { "," type_arg } [ "," ] "]" ]
                       | IDENT "." IDENT [ "[" type_arg { "," type_arg } [ "," ] "]" ] ;

field_inits = field_init { "," field_init } [ "," ] ;
field_init  = identifier "=" expr ;
```

### Control Flow

```ebnf
if_expr = "if" expr ":" NEWLINE INDENT stmt_list DEDENT [ else_clause ] ;

else_clause = "else" ":" NEWLINE INDENT stmt_list DEDENT
            | "else" "if" expr ":" NEWLINE INDENT stmt_list DEDENT [ else_clause ] ;

(* NOTE: There is no inline if expression. `if cond: expr` on a single line is NOT
   valid syntax. The body must always be on an indented line after the colon.
   Use `match` for concise conditional expressions. *)

match_expr = "match" expr ":" NEWLINE INDENT match_cases DEDENT ;

match_cases = match_case { NEWLINE match_case } ;
match_case  = pattern ":" ( expr | NEWLINE INDENT stmt_list DEDENT ) ;

select_expr = "select" ":" NEWLINE INDENT select_arms DEDENT ;

select_arms = select_arm { NEWLINE select_arm } ;
select_arm  = destruct_id "from" expr ":" NEWLINE INDENT stmt_list DEDENT
            | "sealed" expr ":" NEWLINE INDENT stmt_list DEDENT
            | "_" "after" expr ":" NEWLINE INDENT stmt_list DEDENT ;

with_expr = "with" with_binding ":" NEWLINE INDENT stmt_list DEDENT ;
with_binding = destruct_id [ ":" type_expr ] "=" expr
             | destruct_id [ ":" type_expr ] "?=" expr [ "on" destruct_id "=>" expr ] ;

debug_block = "debug" ":" NEWLINE INDENT stmt_list DEDENT ;

concurrent_expr = "concurrent" [ "(" concurrent_params ")" ] ":" NEWLINE INDENT stmt_list DEDENT
                | "for" IDENT "in" expr "concurrently" "(" concurrently_params ")" ":" NEWLINE INDENT stmt_list DEDENT ;

concurrent_params = concurrent_param [ "," concurrent_param ] ;
concurrent_param  = IDENT ":" expr ;

concurrently_params = concurrently_param { "," concurrently_param } ;
concurrently_param  = "limit" ":" INT
                    | "timeout" ":" expr ;

detach_expr = "detach" unary_expr ;
```

`debug_block` returns `Void`. Normal builds erase the body after Core lowering;
`--debug` builds and `blorp test` retain it.

`select_expr` is statement-only and impure. Receive and sealed arms currently
accept `Channel[T]`; `after` arms accept an integer millisecond timeout or
`Duration`. A receive arm runs only when it receives a value. A sealed arm runs
once the channel is sealed and drained. If several arms are ready, runtime scan
order rotates across `select` calls to avoid permanent starvation.

`with_expr` is active syntax for scoped resources. The acquired value must have
a `resource type`; the `?=` form unwraps an `Option`/`Result` resource carrier
and propagates failure from the enclosing carrier-returning function. Cleanup is
driven by the resource type's compiler-owned cleanup metadata.

### Patterns

```ebnf
pattern = simple_pattern { "|" simple_pattern } ;      (* or-pattern *)

simple_pattern = "_"                                    (* wildcard *)
               | IDENT                                  (* variable or constructor *)
               | INT | BIGINT | "-" INT                 (* integer literal *)
               | FLOAT | "-" FLOAT                      (* float literal *)
               | STRING | RAW_STRING
               | CHAR                                   (* char literal *)
               | "True" | "False"                       (* bool literal *)
               | IDENT "(" [ pattern_list ] ")"         (* constructor *)
               | tuple_pattern
               | IDENT "." IDENT [ "(" [ pattern_list ] ")" ]  (* qualified *)
               | list_pattern ;

pattern_list = pattern { "," pattern } [ "," ] ;
tuple_pattern = "(" pattern "," pattern [ "," pattern [ "," pattern ] ] [ "," ] ")" ;

list_pattern = "[" "]"                                  (* empty list *)
             | "[" "..." spread_target "]"              (* spread only *)
             | "[" pattern { "," pattern } [ "," "..." spread_target ] "]" ;

spread_target = IDENT | "_" ;
```

### Lambda Expressions

```ebnf
lambda_expr = lambda_purity "(" [ lambda_params ] ")" [ "->" type_expr ] ":" lambda_body ;

lambda_purity = "func" | "pure" "func" ;

lambda_params = lambda_param { "," lambda_param } [ "," ] ;
lambda_param  = IDENT [ ":" type_expr ]
              | "_" [ ":" type_expr ] ;

lambda_body = or_expr | NEWLINE INDENT stmt_list DEDENT ;
```

`func` and `pure func` are the lambda spellings used in public examples.

### Names

Certain keywords can be used as identifiers in field/function name position:

```ebnf
name = IDENT | "debug" | "and" | "or" | "not" | "type" | "opaque" | "match" | "if" | "else"
     | "True" | "False" | "in" | "for" | "while" | "with" | "foreign"
     | "resource" | "concurrent" | "on"
     | "select" | "after" | "sealed" ;
```

## Operator Precedence (lowest to highest)

| Precedence | Operators | Associativity |
|---|---|---|
| 1 | `=` `+=` `-=` `*=` | right |
| 2 | `or` | left |
| 3 | `and` | left |
| 4 | `==` `!=` | left |
| 5 | `<` `>` `<=` `>=` | left |
| 6 | `..` | none |
| 7 | `+` `-` | left |
| 8 | `*` `/` `%` | left |
| 9 | `-` (unary) `not` | prefix |
| 10 | `.` `()` `[]` | left (postfix) |

## Indentation Rules

1. After `:` followed by `NEWLINE`, the next line must be indented (produces `INDENT`)
2. When indentation decreases, `DEDENT` tokens are emitted (one per level)
3. Inside balanced delimiters (`()`, `[]`, `{}`), newlines are ignored
4. Tabs count as 4 spaces for indentation
5. `else if` chains must not have blank lines between `if` and `else`
6. Multi-line expressions can break after binary operators (`+`, `-`, `*`, `and`, `or`, etc.)
7. Method chains can continue on more-indented leading-dot lines (`value\n    .map(...)`)
