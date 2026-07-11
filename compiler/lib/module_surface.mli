type symbol_kind =
  | Function
  | Variable
  | Type
  | Record
  | TypeAlias
  | Trait
  | TraitMethod
  | ImplMethod

type symbol_source =
  | Decl of int
  | TraitMethod of int * int
  | ImplMethod of int * int
  | PrivateDecl of int
  | PrivateTraitMethod of int * int
  | PrivateImplMethod of int * int

type symbol = {
  name : string;
  kind : symbol_kind;
  source : symbol_source;
}

type import = { module_path : string }

type t = {
  module_name : string;
  imports : import list;
  exports : symbol list;
  private_names : symbol list;
  private_traits : string list;
}

val symbol_kind_of_string : string -> (symbol_kind, string) result
val symbol_kind_name : symbol_kind -> string
val export_names : t -> string list
val private_names : t -> string list
val import_module_names : t -> string list
val validate_against_program : Ast.program -> t -> (unit, string) result
val decl_for_symbol_source : Ast.program -> symbol_source -> Ast.decl option
val impl_method_export_decl :
  Ast.decl -> method_index:int -> Ast.decl option
val exports_as_ast_pairs : Ast.program -> t -> (string * Ast.decl) list
val private_names_as_ast_pairs : Ast.program -> t -> (string * Ast.decl) list
