(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast

module Make (L : Loc_sig.S) (Env_api : Env_api.S with module L = L) = struct
  module L = L
  module Provider_api = Env_api.Provider_api
  module Name_def = Name_def.Make (L)
  open Name_def

  module Tarjan =
    Tarjan.Make
      (struct
        include L

        let to_string l = debug_to_string l
      end)
      (L.LMap)
      (L.LSet)

  module FindDependencies : sig
    val depends : Env_api.env_info -> Name_def.def -> L.t Nel.t L.LMap.t

    val recursively_resolvable : Name_def.def -> bool
  end = struct
    (* This analysis consumes variable defs and returns a map representing the variables that need to be
       resolved before we can resolve this def.

       Consider for example the program

         1: var x = 42;
         2: type T = typeof x;

       And let's specifically look at the def `TypeAlias(type T = typeof x)`, which will be one of the
       defs generated by the analysis in `name_def.ml`. Given this def, the question that this module
       answers is what variable definitions need to be resolved before the `TypeAlias` def itself can be resolved.

       We can see that the type alias depends on reading `x`, so in order to actually resolve the type alias, we
       first need to know the type of `x`. In order to do that, we need to have resolved the writes that (according
       to the name_resolver) reach this reference to `x`. That's what this analysis tells us--it will traverse the
       TypeAlias def, find the read of `x`, and add the writes to `x` that reach that read to the set of defs that need to
       be resolved before the type alias can be resolved. We'll ultimately use this to figure out the correct ordering
       of nodes.

       The actual output of this analysis is a map, whose keys are the locations of variables whose defs need to be resolved
       before this def can be. The values of this map are the locations within the def itself that led us to those variable definitions--
       in this case, the result will be [def of `x`] => [dereference of `x`]. This information is included for good error messages eventually,
       but the more important bit for the correctness of the analysis is the keys of the map--it may be easier to think of the map
       as a set and ignore the values.
    *)

    (* Helper class for the dependency analysis--traverse the AST nodes
       in a def to determine which variables appear *)
    class use_visitor ({ Env_api.env_values; env_entries; _ } as env) init =
      object (this)
        inherit [L.t Nel.t L.LMap.t, L.t] Flow_ast_visitor.visitor ~init

        method add ~why t =
          this#update_acc (fun uses ->
              L.LMap.update
                t
                (function
                  | None -> Some (Nel.one why)
                  | Some locs -> Some (Nel.cons why locs))
                uses
          )

        method find_writes ~for_type loc =
          let write_locs = Env_api.write_locs_of_read_loc env_values loc in
          let writes = Base.List.concat_map ~f:(Env_api.writes_of_write_loc ~for_type) write_locs in
          let refinements =
            Base.List.concat_map ~f:(Env_api.refinements_of_write_loc env) write_locs
          in
          let rec writes_of_refinement refi =
            let open Env_api.Refi in
            match refi with
            | InstanceOfR ((_loc, _) as exp)
            | LatentR { func = (_loc, _) as exp; _ } ->
              ignore (this#expression exp)
            | AndR (l, r)
            | OrR (l, r) ->
              writes_of_refinement l;
              writes_of_refinement r
            | NotR r -> writes_of_refinement r
            | TruthyR _
            | NullR
            | UndefinedR
            | MaybeR
            | IsArrayR
            | BoolR _
            | FunctionR
            | NumberR _
            | ObjectR
            | StringR _
            | SentinelR _
            | SymbolR _
            | SingletonBoolR _
            | SingletonStrR _
            | SingletonNumR _ ->
              ()
          in
          Base.List.iter ~f:writes_of_refinement refinements;
          writes

        (* In order to resolve a def containing a variable read, the writes that the
           Name_resolver determines reach the variable must be resolved *)
        method! identifier ((loc, _) as id) =
          let writes = this#find_writes ~for_type:false loc in
          Base.List.iter ~f:(this#add ~why:loc) writes;
          id

        method! type_identifier_reference ((loc, _) as id) =
          let writes = this#find_writes ~for_type:true loc in
          Base.List.iter ~f:(this#add ~why:loc) writes;
          id

        (* In order to resolve a def containing a variable write, the
           write itself should first be resolved *)
        method! pattern_identifier ?kind:_ ((loc, _) as id) =
          (* Ignore cases that don't have bindings in the environment, like `var x;` *)
          if L.LMap.mem loc env_entries then this#add ~why:loc loc;
          id

        method! binding_type_identifier ((loc, _) as id) =
          (* Unconditional, unlike the above, because all binding type identifiers should
             exist in the environment. *)
          this#add ~why:loc loc;
          id

        method! member_property_identifier (id : (L.t, L.t) Ast.Identifier.t) = id

        method! typeof_member_identifier ident = ident

        method! member_type_identifier (id : (L.t, L.t) Ast.Identifier.t) = id

        method! pattern_object_property_identifier_key ?kind:_ id = id

        method! enum_member_identifier id = id

        method! object_key_identifier (id : (L.t, L.t) Ast.Identifier.t) = id

        (* For classes/functions that are known to be fully annotated, we skip property bodies *)
        method function_def ~fully_annotated (expr : ('loc, 'loc) Ast.Function.t) =
          let open Ast.Function in
          let { params; body; predicate; return; tparams; _ } = expr in
          let open Flow_ast_mapper in
          let _ = this#function_params params in
          let _ =
            if fully_annotated then
              (this#type_annotation_hint return, body)
            else
              (return, this#function_body_any body)
          in
          let _ = map_opt this#predicate predicate in
          let _ = map_opt this#type_params tparams in
          ()

        method class_body_annotated (cls_body : ('loc, 'loc) Ast.Class.Body.t) =
          let open Ast.Class.Body in
          let (_, { body; comments = _ }) = cls_body in
          Base.List.iter ~f:this#class_element_annotated body;
          cls_body

        method class_element_annotated (elem : ('loc, 'loc) Ast.Class.Body.element) =
          let open Ast.Class.Body in
          match elem with
          | Method (_, meth) -> this#class_method_annotated meth
          | Property (_, prop) -> this#class_property_annotated prop
          | PrivateField (_, field) -> this#class_private_field_annotated field

        method class_method_annotated (meth : ('loc, 'loc) Ast.Class.Method.t') =
          let open Ast.Class.Method in
          let { kind = _; key; value = (_, value); static = _; decorators; comments = _ } = meth in
          let _ = Base.List.map ~f:this#class_decorator decorators in
          let _ = this#object_key key in
          let _ = this#function_def ~fully_annotated:true value in
          ()

        method class_property_annotated (prop : ('loc, 'loc) Ast.Class.Property.t') =
          let open Ast.Class.Property in
          let { key; value = _; annot; static = _; variance = _; comments = _ } = prop in
          let _ = this#object_key key in
          let _ = this#type_annotation_hint annot in
          ()

        method class_private_field_annotated (prop : ('loc, 'loc) Ast.Class.PrivateField.t') =
          let open Ast.Class.PrivateField in
          let { key; value = _; annot; static = _; variance = _; comments = _ } = prop in
          let _ = this#private_name key in
          let _ = this#type_annotation_hint annot in
          ()
      end

    (* For all the possible defs, explore the def's structure with the class above
       to find what variables have to be resolved before this def itself can be resolved *)
    let depends ({ Env_api.providers; _ } as env) =
      let visitor = new use_visitor env L.LMap.empty in
      let depends_of_node mk_visit state =
        visitor#set_acc state;
        let node_visit () = mk_visit visitor in
        visitor#eval node_visit ()
      in
      (* depends_of_annotation and of_expression take the `state` parameter from
         `depends_of_node` above as an additional currried parameter. *)
      let depends_of_annotation anno =
        depends_of_node (fun visitor -> ignore @@ visitor#type_annotation anno)
      in
      let depends_of_expression expr =
        depends_of_node (fun visitor -> ignore @@ visitor#expression expr)
      in
      let depends_of_fun fully_annotated function_ =
        depends_of_node
          (fun visitor -> visitor#function_def ~fully_annotated function_)
          L.LMap.empty
      in
      let depends_of_class
          fully_annotated
          { Ast.Class.id = _; body; tparams; extends; implements; class_decorators; comments = _ } =
        depends_of_node
          (fun visitor ->
            let open Flow_ast_mapper in
            let _ =
              if fully_annotated then
                visitor#class_body_annotated body
              else
                visitor#class_body body
            in
            let _ = map_opt (map_loc visitor#class_extends) extends in
            let _ = map_opt visitor#class_implements implements in
            let _ = map_list visitor#class_decorator class_decorators in
            let _ = map_opt visitor#type_params tparams in
            ())
          L.LMap.empty
      in
      let depends_of_declared_class
          {
            Ast.Statement.DeclareClass.id = _;
            tparams;
            body;
            extends;
            mixins;
            implements;
            comments = _;
          } =
        depends_of_node
          (fun visitor ->
            let open Flow_ast_mapper in
            let _ = map_opt visitor#type_params tparams in
            let _ = map_loc visitor#object_type body in
            let _ = map_opt (map_loc visitor#generic_type) extends in
            let _ = map_list (map_loc visitor#generic_type) mixins in
            let _ = map_opt visitor#class_implements implements in
            ())
          L.LMap.empty
      in
      let depends_of_alias { Ast.Statement.TypeAlias.tparams; right; _ } =
        depends_of_node
          (fun visitor ->
            let open Flow_ast_mapper in
            let _ = map_opt visitor#type_params tparams in
            let _ = visitor#type_ right in
            ())
          L.LMap.empty
      in
      let depends_of_opaque { Ast.Statement.OpaqueType.tparams; impltype; supertype; _ } =
        depends_of_node
          (fun visitor ->
            let open Flow_ast_mapper in
            let _ = map_opt visitor#type_params tparams in
            let _ = map_opt visitor#type_ impltype in
            let _ = map_opt visitor#type_ supertype in
            ())
          L.LMap.empty
      in
      let depends_of_tparam (_, { Ast.Type.TypeParam.bound; variance; default; _ }) =
        depends_of_node
          (fun visitor ->
            let open Flow_ast_mapper in
            let _ = visitor#type_annotation_hint bound in
            let _ = visitor#variance_opt variance in
            let _ = map_opt visitor#type_ default in
            ())
          L.LMap.empty
      in
      let depends_of_interface { Ast.Statement.Interface.tparams; extends; body; _ } =
        depends_of_node
          (fun visitor ->
            let open Flow_ast_mapper in
            let _ = map_opt visitor#type_params tparams in
            let _ = map_list (map_loc visitor#generic_type) extends in
            let _ = map_loc visitor#object_type body in
            ())
          L.LMap.empty
      in
      let depends_of_root state = function
        | Annotation anno -> depends_of_annotation anno state
        | Value exp -> depends_of_expression exp state
        | For (_, exp) -> depends_of_expression exp state
        | Contextual _ -> state
        | Catch -> state
      in
      let depends_of_selector state = function
        | Computed exp
        | Default exp ->
          depends_of_expression exp state
        | Elem _
        | Prop _
        | ObjRest _
        | ArrRest _ ->
          state
      in
      let depends_of_lhs id_loc =
        (* When looking at a binding def, like `x = y`, in order to resolve this def we need
             to have resolved the providers for `x`, as well as the type of `y`, in order to check
             the type of `y` against `x`. So in addition to exploring the RHS, we also add the providers
             for `x` to the set of dependencies. *)
        if not @@ Provider_api.is_provider providers id_loc then
          let (_, providers) =
            Base.Option.value_exn (Provider_api.providers_of_def providers id_loc)
          in
          Base.List.fold
            ~init:L.LMap.empty
            ~f:(fun acc r ->
              let key = Reason.poly_loc_of_reason r in
              L.LMap.update
                key
                (function
                  | None -> Some (Nel.one id_loc)
                  | Some locs -> Some (Nel.cons id_loc locs))
                acc)
            providers
        else
          L.LMap.empty
      in
      let depends_of_binding id_loc bind =
        let state = depends_of_lhs id_loc in
        let rec rhs_loop bind state =
          match bind with
          | Root root -> depends_of_root state root
          | Select (selector, binding) ->
            let state = depends_of_selector state selector in
            rhs_loop binding state
        in
        rhs_loop bind state
      in
      let depends_of_update id_loc =
        let state = depends_of_lhs id_loc in
        let visitor = new use_visitor env state in
        let writes = visitor#find_writes ~for_type:false id_loc in
        Base.List.iter ~f:(visitor#add ~why:id_loc) writes;
        visitor#acc
      in
      let depends_of_op_assign id_loc rhs =
        (* reusing depends_of_update, since the LHS of an op-assign is handled identically to an update *)
        let state = depends_of_update id_loc in
        depends_of_expression rhs state
      in
      function
      | Binding (id_loc, binding) -> depends_of_binding id_loc binding
      | Update (id_loc, _) -> depends_of_update id_loc
      | OpAssign (id_loc, _, rhs) -> depends_of_op_assign id_loc rhs
      | Function { fully_annotated; function_ } -> depends_of_fun fully_annotated function_
      | Class { fully_annotated; class_ } -> depends_of_class fully_annotated class_
      | DeclaredClass decl -> depends_of_declared_class decl
      | TypeAlias alias -> depends_of_alias alias
      | OpaqueType alias -> depends_of_opaque alias
      | TypeParam tparam -> depends_of_tparam tparam
      | Interface inter -> depends_of_interface inter
      | Enum _ ->
        (* Enums don't contain any code or type references, they're literal-like *) L.LMap.empty
      | Import _ -> (* same with all imports *) L.LMap.empty

    (* Is the variable defined by this def able to be recursively depended on, e.g. created as a 0->1 tvar before being
       resolved? *)
    let recursively_resolvable =
      let rec bind_loop b =
        match b with
        | Root (Annotation _ | Catch) -> true
        | Root (For _ | Value _ | Contextual _) -> false
        | Select ((Computed _ | Default _), _) -> false
        | Select (_, b) -> bind_loop b
      in
      function
      | Binding (_, bind) -> bind_loop bind
      | TypeAlias _
      | OpaqueType _
      | TypeParam _
      | Function { fully_annotated = true; _ }
      | Interface _
      (* Imports are academic here since they can't be in a cycle anyways, since they depend on nothing *)
      | Import { import_kind = Ast.Statement.ImportDeclaration.(ImportType | ImportTypeof); _ }
      | Import
          {
            import =
              Named { kind = Some Ast.Statement.ImportDeclaration.(ImportType | ImportTypeof); _ };
            _;
          }
      | Class { fully_annotated = true; _ }
      | DeclaredClass _ ->
        true
      | Update _
      | OpAssign _
      | Function { fully_annotated = false; _ }
      | Enum _
      | Import _
      | Class { fully_annotated = false; _ } ->
        false
  end

  type element =
    | Normal of L.t
    | Resolvable of L.t
    | Illegal of L.t

  type result =
    | Singleton of element
    | ResolvableSCC of element Nel.t
    | IllegalSCC of element Nel.t

  let dependencies env loc def acc =
    let depends = FindDependencies.depends env def in
    L.LMap.add loc depends acc

  let build_graph env map = L.LMap.fold (dependencies env) map L.LMap.empty

  let build_ordering env map =
    let graph = build_graph env map in
    let order_graph = L.LMap.map (fun deps -> L.LMap.keys deps |> L.LSet.of_list) graph in
    let roots = L.LMap.keys order_graph |> L.LSet.of_list in
    let sort =
      try Tarjan.topsort ~roots order_graph |> List.rev with
      | Not_found ->
        let all =
          L.LMap.values order_graph
          |> List.map L.LSet.elements
          |> List.flatten
          |> L.LSet.of_list
          |> L.LSet.elements
          |> Base.List.map ~f:(L.debug_to_string ~include_source:false)
          |> String.concat ","
        in
        let roots =
          L.LSet.elements roots
          |> Base.List.map ~f:(L.debug_to_string ~include_source:true)
          |> String.concat ","
        in
        failwith (Printf.sprintf "roots: %s\n\nall: %s" roots all)
    in
    let result_of_scc (fst, rest) =
      let element_of_loc loc =
        if L.LSet.mem loc (L.LMap.find loc order_graph) then
          if FindDependencies.recursively_resolvable (L.LMap.find loc map) then
            Resolvable loc
          else
            Illegal loc
        else
          Normal loc
      in
      match rest with
      | [] -> Singleton (element_of_loc fst)
      | _ ->
        if
          Base.List.for_all
            ~f:(fun m -> FindDependencies.recursively_resolvable (L.LMap.find m map))
            (fst :: rest)
        then
          ResolvableSCC (Nel.map element_of_loc (fst, rest))
        else
          IllegalSCC (Nel.map element_of_loc (fst, rest))
    in
    Base.List.map ~f:result_of_scc sort
end

module With_Loc = Make (Loc_sig.LocS) (Env_api.With_Loc)
module With_ALoc = Make (Loc_sig.ALocS) (Env_api.With_ALoc)
