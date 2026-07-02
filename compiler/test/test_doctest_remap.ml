(** Tests for doctest loc remapping.

    A doctest runs inside a synthetic program built by
    [Test_runner.generate_doctest_program], so any diagnostic the
    compiler emits points at the synthetic source — wrong line numbers,
    wrong snippets relative to the user's real source. These tests
    guard the end-to-end remap that makes errors land on the original
    source's line instead.

    Four invariants:
      1. [extract_doctests_from_doc] preserves per-line origin line
         numbers through its strip/split/filter passes.
      2. [generate_doctest_program] emits a synthetic→original line
         map keyed on the synthetic line number.
      3. Boilerplate lines (imports, func wrapper, [tests:] struct)
         are absent from the map — we intentionally don't claim a
         false mapping for generator-emitted scaffolding.
      4. A real doctest compile error surfaces with loc rewritten to
         the original source file + line.

    Contract: docstrings are passed in with a [~doc_start_line]. That
    is the 1-based line number of the FIRST content line inside the
    docstring (the line immediately after the opening [---]). Every
    origin line number in the returned [dtg_code_origins] is absolute
    to the original file. *)

open Blorp

(* ============================================================================
   Helpers
   ============================================================================ *)

let sample_doc =
  "Doc preamble line one.\n\n\
   doctests:\n\
  \    :: simple case\n\
  \    x: Int = 1\n\
  \    x == 1\n\n\
  \    :: block with blank line\n\n\
  \    y: Int = 2\n\
  \    y == 2\n"

(* ============================================================================
   extract_doctests_from_doc: origin-line preservation
   ============================================================================ *)

let test_extract_single_group_origins () =
  (* sample_doc's "doctests:" line is line 3 of the doc. The code
     lines start at doc-relative line 5 and 6 for the first group.
     If the doc's first content line is at source line 10, then:
       doc line 1 -> source 10  ("Doc preamble line one.")
       doc line 3 -> source 12  ("doctests:")
       doc line 5 -> source 14  ("    x: Int = 1")
       doc line 6 -> source 15  ("    x == 1")
     and the dtg_code lines (after 4-space-indent strip) should be
     ["x: Int = 1"; "x == 1"] with origins [14; 15]. *)
  let groups =
    Test_runner.extract_doctests_from_doc ~doc_start_line:10 "somefn" sample_doc
  in
  match groups with
  | [ first; _ ] ->
      Alcotest.(check string)
        "first group description" "simple case" first.dtg_description;
      let code_lines = String.split_on_char '\n' first.dtg_code in
      Alcotest.(check (list string))
        "first group code" [ "x: Int = 1"; "x == 1" ] code_lines;
      Alcotest.(check (list int))
        "first group origin lines" [ 14; 15 ] first.dtg_code_origins
  | _ -> Alcotest.failf "expected 2 doctest groups, got %d" (List.length groups)

let test_extract_blank_stripping_preserves_origin () =
  (* Second group has a blank line between the delimiter and the first
     code line. The blank-strip step must NOT renumber — the first
     kept line's origin must be the original (blank line skipped),
     NOT collapsed to the delimiter's line. *)
  let groups =
    Test_runner.extract_doctests_from_doc ~doc_start_line:10 "somefn" sample_doc
  in
  match groups with
  | [ _; second ] ->
      let code_lines = String.split_on_char '\n' second.dtg_code in
      Alcotest.(check (list string))
        "second group code" [ "y: Int = 2"; "y == 2" ] code_lines;
      (* doc-relative: :: at line 8, blank at 9, code at 10 and 11.
         Absolute (doc_start_line = 10): [19; 20]. *)
      Alcotest.(check (list int))
        "second group origin lines" [ 19; 20 ] second.dtg_code_origins
  | _ -> Alcotest.failf "expected 2 doctest groups, got %d" (List.length groups)

let test_extract_empty_doctests_section () =
  let groups =
    Test_runner.extract_doctests_from_doc ~doc_start_line:1 "empty"
      "no doctests here"
  in
  Alcotest.(check int) "no groups" 0 (List.length groups)

(* ============================================================================
   generate_doctest_program: line-map construction
   ============================================================================ *)

(* Shared fixture: join lines with newlines for readable source-text
   construction in tests (lines are 1-indexed matching [Ast.loc]). *)
let make_source lines = String.concat "\n" lines

let contains_substring s needle =
  let len_s = String.length s and len_n = String.length needle in
  let rec loop i =
    i + len_n <= len_s && (String.sub s i len_n = needle || loop (i + 1))
  in
  len_n = 0 || loop 0

(* Shared fixture: a minimal func_decl shell for tests that attach a
   docstring and care about the decl_loc.line <-> source layout. *)
let mk_func_decl ~name ~doc ~decl_line : Ast.decl =
  let func : Ast.func_decl =
    {
      func_name = Some name;
      func_type_params = [];
      func_params = [];
      func_return_type = Some (Ast.TyNamed ("Int", []));
      func_body = Ast.FuncNoBody;
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  {
    decl_desc = Ast.DFunc func;
    decl_loc = { Ast.dummy_loc with line = decl_line };
    decl_doc = Some doc;
  }

let mk_import_decl ?alias module_name symbols : Ast.decl =
  let import_symbols =
    Some
      (List.map
         (fun name ->
           { Ast.sym_name = name; sym_alias = None; sym_ctors = Ast.CtorNone })
         symbols)
  in
  {
    decl_desc =
      Ast.DImport
        { import_module = module_name; import_symbols; import_alias = alias };
    decl_loc = Ast.dummy_loc;
    decl_doc = None;
  }

let test_generate_program_line_map_covers_code () =
  (* Full-pipeline test: construct a realistic source_text where the
     opening `---` is on a known line, the decl_loc.line matches what
     the parser would report for the closing `---`, and assert the
     remap table carries the doctest code line back to its original
     file:line. Exercises extract + find_docstring_start + generate
     end-to-end without the prior [override_doc_starts] test hook. *)
  let doc = "Adds one.\n\ndoctests:\n    :: basic\n    1 + 1 == 2\n" in
  (* Layout:
       line 24: ---              (opening)
       line 25: Adds one.        ← doc_start_line
       line 26: (blank)
       line 27: doctests:
       line 28:     :: basic
       line 29:     1 + 1 == 2   ← the code line we care about
       line 30: ---              (closing, == decl_loc.line) *)
  let source_text =
    make_source
      [
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        (* 1-10 *)
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        (* 11-20 *)
        "";
        "";
        "";
        (* 21-23 *)
        "---";
        (* 24 *)
        "Adds one.";
        (* 25 *)
        "";
        (* 26 *)
        "doctests:";
        (* 27 *)
        "    :: basic";
        (* 28 *)
        "    1 + 1 == 2";
        (* 29 *)
        "---";
        (* 30 *)
        "pure func addone(): 1 + 1";
        (* 31 *)
      ]
  in
  let decl = mk_func_decl ~name:"addone" ~doc ~decl_line:30 in
  let source, remap =
    Test_runner.generate_doctest_program_with_map ~source_path:"/tmp/foo.brp"
      ~source_text [ decl ]
  in
  Alcotest.(check bool) "source is non-empty" true (String.length source > 0);
  let syn_lines = String.split_on_char '\n' source in
  let idx =
    List.mapi
      (fun i s -> if String.trim s = "1 + 1 == 2" then Some (i + 1) else None)
      syn_lines
    |> List.find_map Fun.id
  in
  match idx with
  | None -> Alcotest.fail "synthetic source missing the doctest code line"
  | Some syn_line -> (
      match Hashtbl.find_opt remap syn_line with
      | None ->
          Alcotest.failf "remap has no entry for synthetic line %d" syn_line
      | Some entry ->
          Alcotest.(check string)
            "original file" "/tmp/foo.brp" entry.Test_runner.original_file;
          Alcotest.(check int) "original line" 29 entry.original_line)

let test_generate_program_excludes_boilerplate () =
  (* Lines that belong to the generator's own emitted scaffolding —
     imports, func wrappers, the tests: struct — should not appear
     in the remap. Synthetic line 1 is always "import:" (or blank)
     and never a doctest code line. *)
  let doc = "doctests:\n    :: basic\n    1 == 1\n" in
  let source_text =
    make_source
      [
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        "";
        (* 1-10 *)
        "";
        "";
        "";
        "";
        (* 11-14 *)
        "---";
        (* 15 opening *)
        "doctests:";
        (* 16 *)
        "    :: basic";
        (* 17 *)
        "    1 == 1";
        (* 18 *)
        "---";
        (* 19 closing *)
        "pure func f(): 1";
        (* 20 *)
      ]
  in
  let decl = mk_func_decl ~name:"f" ~doc ~decl_line:19 in
  let _, remap =
    Test_runner.generate_doctest_program_with_map ~source_path:"/tmp/x.brp"
      ~source_text [ decl ]
  in
  Alcotest.(check bool)
    "synthetic line 1 is unmapped" true
    (Hashtbl.find_opt remap 1 = None)

let test_generate_program_emits_colon_imports () =
  let doc = "doctests:\n    :: uses import\n    True\n" in
  let source_text =
    make_source
      [
        "---";
        "doctests:";
        "    :: uses import";
        "    True";
        "---";
        "pure func ok(): True";
      ]
  in
  let decl = mk_func_decl ~name:"ok" ~doc ~decl_line:5 in
  let source, _ =
    Test_runner.generate_doctest_program_with_map
      ~source_path:"/tmp/imports.brp" ~source_text
      [
        mk_import_decl "codec" [ "Value"; "get_field" ];
        mk_import_decl ~alias:"H" "heap" [ "Heap" ];
        decl;
      ]
  in
  Alcotest.(check bool)
    "selective import uses colon" true
    (contains_substring source "    codec: Value, get_field");
  Alcotest.(check bool)
    "aliased selective import uses colon" true
    (contains_substring source "    heap as H: Heap");
  Alcotest.(check bool)
    "no brace selective import" false
    (contains_substring source "codec {"
    || contains_substring source "heap as H {")

(* ============================================================================
   find_docstring_start_line: direct unit coverage
   ============================================================================

   Until this suite existed, the function's parser-position assumption
   was only tested transitively through extract/generate. These tests
   pin the actual input-output behavior so future parser/span changes surface
   here instead of as mysterious mis-mapped error locations. *)

let test_find_standard_shape () =
  (* Typical shape: preamble, blank, ---, content, ---, decl.
     decl line = 6 (the closing ---); opening --- on line 3;
     doc first content line = 4. *)
  let src =
    make_source
      [
        "import:";
        (* line 1 *)
        "  list: map";
        (* line 2 *)
        "---";
        (* line 3 — opening *)
        "Doc line one.";
        (* line 4 *)
        "Doc line two.";
        (* line 5 *)
        "---";
        (* line 6 — closing *)
        "pure func f(): 0";
        (* line 7 *)
      ]
  in
  Alcotest.(check (option int))
    "standard shape" (Some 4)
    (Test_runner.find_docstring_start_line src 6)

let test_find_line_1_docstring () =
  (* Edge case: opening [---] on line 1 — no preamble at all. Previously
     [find_docstring_start_line] short-circuited via [decl_line <= 1]
     and returned [None], silently losing remap fidelity for this shape. *)
  let src =
    make_source
      [
        "---";
        (* line 1 — opening *)
        "Doc only.";
        (* line 2 *)
        "---";
        (* line 3 — closing *)
        "func g(): 0";
        (* line 4 *)
      ]
  in
  Alcotest.(check (option int))
    "line-1 docstring" (Some 2)
    (Test_runner.find_docstring_start_line src 3)

let test_find_no_docstring () =
  (* decl_line points at a non-delimiter line (no doc above). Should
     return [None] rather than walking backward indefinitely. *)
  let src =
    make_source
      [
        "import:";
        "  x: y";
        "";
        "pure func h(): 0";
        (* line 4 — no --- block above *)
      ]
  in
  Alcotest.(check (option int))
    "no docstring" None
    (Test_runner.find_docstring_start_line src 4)

let test_find_decl_line_zero () =
  Alcotest.(check (option int))
    "decl_line = 0" None
    (Test_runner.find_docstring_start_line "---\nx\n---\nfunc()" 0)

let test_find_decl_line_out_of_bounds () =
  Alcotest.(check (option int))
    "decl_line past EOF" None
    (Test_runner.find_docstring_start_line "x\ny\n" 99)

(* ============================================================================
   remap_loc: end_line is mapped independently
   ============================================================================ *)

let mk_loc ?(file = "<syn>") ~line ~end_line () : Ast.loc =
  { Ast.line; column = 1; end_line; end_column = 1; loc_file = Some file }

let test_remap_preserves_multiline_span () =
  (* When an error spans multiple synthetic lines and BOTH endpoints
     have origin entries, the remapped loc must carry the mapped
     [line] and the mapped [end_line] independently. Previously
     [remap_loc] collapsed end_line to the start's origin — fine for
     single-line errors (the common case) but silently lost the
     height of multi-line errors. *)
  let table : Test_runner.loc_remap_table = Hashtbl.create 4 in
  Hashtbl.add table 10
    { Test_runner.original_file = "x.brp"; original_line = 100 };
  Hashtbl.add table 12
    { Test_runner.original_file = "x.brp"; original_line = 102 };
  let loc = mk_loc ~line:10 ~end_line:12 () in
  let remapped = Test_runner.remap_loc table loc in
  Alcotest.(check int) "line remapped" 100 remapped.line;
  Alcotest.(check int) "end_line remapped" 102 remapped.end_line;
  Alcotest.(check (option string))
    "file rewritten" (Some "x.brp") remapped.loc_file

let test_remap_end_line_fallback_when_unmapped () =
  (* If only the start line has an entry (end_line falls on a line
     the map doesn't know), end_line falls back to the start's
     mapped line. Losing span height is acceptable; silently
     pointing [end_line] at a synthetic number is not. *)
  let table : Test_runner.loc_remap_table = Hashtbl.create 4 in
  Hashtbl.add table 10
    { Test_runner.original_file = "x.brp"; original_line = 100 };
  let loc = mk_loc ~line:10 ~end_line:11 () in
  let remapped = Test_runner.remap_loc table loc in
  Alcotest.(check int) "line remapped" 100 remapped.line;
  Alcotest.(check int) "end_line fallback" 100 remapped.end_line

let test_remap_loc_unmapped_passes_through () =
  (* A loc whose start line isn't in the table is generator-owned
     scaffolding. Leave it untouched — don't invent a false mapping. *)
  let table : Test_runner.loc_remap_table = Hashtbl.create 4 in
  let loc = mk_loc ~file:"tmp.brp" ~line:7 ~end_line:7 () in
  let remapped = Test_runner.remap_loc table loc in
  Alcotest.(check int) "line unchanged" 7 remapped.line;
  Alcotest.(check int) "end_line unchanged" 7 remapped.end_line;
  Alcotest.(check (option string))
    "file unchanged" (Some "tmp.brp") remapped.loc_file

(* ============================================================================
   Suite
   ============================================================================ *)

let suite =
  [
    ( "extract",
      [
        Alcotest.test_case "single group origins" `Quick
          test_extract_single_group_origins;
        Alcotest.test_case "blank strip preserves" `Quick
          test_extract_blank_stripping_preserves_origin;
        Alcotest.test_case "empty section" `Quick
          test_extract_empty_doctests_section;
      ] );
    ( "generate",
      [
        Alcotest.test_case "line-map covers code" `Quick
          test_generate_program_line_map_covers_code;
        Alcotest.test_case "boilerplate excluded" `Quick
          test_generate_program_excludes_boilerplate;
        Alcotest.test_case "colon imports" `Quick
          test_generate_program_emits_colon_imports;
      ] );
    ( "find_docstring_start",
      [
        Alcotest.test_case "standard shape" `Quick test_find_standard_shape;
        Alcotest.test_case "line-1 docstring" `Quick test_find_line_1_docstring;
        Alcotest.test_case "no docstring" `Quick test_find_no_docstring;
        Alcotest.test_case "decl_line = 0" `Quick test_find_decl_line_zero;
        Alcotest.test_case "decl_line out of bounds" `Quick
          test_find_decl_line_out_of_bounds;
      ] );
    ( "remap_loc",
      [
        Alcotest.test_case "multiline span" `Quick
          test_remap_preserves_multiline_span;
        Alcotest.test_case "end_line fallback" `Quick
          test_remap_end_line_fallback_when_unmapped;
        Alcotest.test_case "unmapped passes through" `Quick
          test_remap_loc_unmapped_passes_through;
      ] );
  ]
