open! Core_kernel
open! Import
open Incr.Let_syntax

(* Share this incremental node *)
let unusable_apply_action : (schedule_event:(Event.t -> unit) -> Nothing.t -> unit) Incr.t
  =
  return (fun ~schedule_event:_ action -> Nothing.unreachable_code action)
;;

let rec eval
  : type model action result.
    environment:Environment.t
    -> path:Path.t
    -> model:model Incr.t
    -> inject:(action -> Event.t)
    -> (model, action, result) Computation.t
    -> (model, action, result) Snapshot.t
  =
  fun ~environment ~path ~model ~inject computation ->
  match computation with
  | Return var ->
    let result = Value.eval environment var in
    Snapshot.create ~result ~apply_action:unusable_apply_action
  | Leaf { input; apply_action; compute; name = _; kind = _ } ->
    let%pattern_bind result, apply_action =
      let%mapn input = Value.eval environment input
      and model = model in
      compute ~inject input model, apply_action ~inject input model
    in
    Snapshot.create ~result ~apply_action
  | Leaf_incr { input; apply_action; compute; name = _ } ->
    let input = Value.eval environment input in
    let result = compute ~inject input model
    and apply_action = apply_action ~inject input model in
    Snapshot.create ~result ~apply_action
  | Model_cutoff { t; model = { Meta.Model.equal; _ } } ->
    let model = Incr.map model ~f:Fn.id in
    Incr.set_cutoff model (Incr.Cutoff.of_equal equal);
    eval ~environment ~path ~model ~inject t
  | Subst { from; via; into } ->
    let from =
      let inject e = inject (First e) in
      let model = Incr.map model ~f:Tuple2.get1 in
      let path = Path.append path Path.Elem.Subst_from in
      eval ~environment ~path ~model ~inject from
    in
    let from_result = Snapshot.result from in
    let environment = Environment.add_exn environment ~key:via ~data:from_result in
    let into =
      let inject e = inject (Second e) in
      let model = Incr.map model ~f:Tuple2.get2 in
      let path = Path.append path Path.Elem.Subst_into in
      eval ~environment ~path ~model ~inject into
    in
    let apply_action =
      let%mapn m1, m2 = model
      and apply_action_from = Snapshot.apply_action from
      and apply_action_into = Snapshot.apply_action into in
      fun ~schedule_event action ->
        match action with
        | First action1 -> apply_action_from action1 ~schedule_event, m2
        | Second action2 -> m1, apply_action_into action2 ~schedule_event
    and result = Snapshot.result into in
    Snapshot.create ~result ~apply_action
  | Assoc
      { map
      ; by
      ; key_compare
      ; key_id
      ; data_id
      ; model_info
      ; action_info
      ; result_by_k = T
      ; input_by_k = T
      ; model_by_k = T
      } ->
    let map_input = Value.eval environment map in
    let input_and_models_map =
      Incr_map.merge map_input model ~f:(fun ~key:_ -> function
        | `Left input -> Some (input, model_info.default)
        | `Right _ -> None
        | `Both input_and_models -> Some input_and_models)
    in
    let create_keyed = unstage (Path.Elem.keyed ~compare:key_compare key_id) in
    let results_map, apply_action_map =
      Incr_map.unzip_mapi' input_and_models_map ~f:(fun ~key ~data:input_and_model ->
        let path = Path.append path Path.Elem.(Assoc (create_keyed key)) in
        let%pattern_bind value, model = input_and_model in
        let environment =
          (* It is safe to reuse the same [key_id] and [data_id] for each pair in the map,
             since they all start with a fresh "copy" of the outer environment. *)
          environment
          |> Environment.add_exn ~key:key_id ~data:(Incr.const key)
          |> Environment.add_exn ~key:data_id ~data:value
        in
        let inject action = inject (key, action) in
        let snapshot = eval ~environment ~path ~inject ~model by in
        Snapshot.result snapshot, Snapshot.apply_action snapshot)
    in
    let apply_action =
      let%mapn apply_action_map = apply_action_map
      and model = model in
      fun ~schedule_event action ->
        let id, action = action in
        match Map.find apply_action_map id with
        | None ->
          let key = Type_equal.Id.to_sexp key_id id in
          let action = Type_equal.Id.to_sexp action_info action in
          eprint_s
            [%message
              "an action inside of Bonsai.assoc as been dropped because the computation \
               is no longer active"
                (key : Sexp.t)
                (action : Sexp.t)];
          model
        (* drop it on the floor *)
        | Some apply_action ->
          let data = apply_action ~schedule_event action in
          if model_info.equal data model_info.default
          then Map.remove model id
          else Map.set model ~key:id ~data
    in
    Snapshot.create ~result:results_map ~apply_action
  | Assoc_simpl
      { map
      ; by
      ; key_id = _
      ; data_id = _
      ; model_info = _
      ; result_by_k = T
      ; input_by_k = T
      ; model_by_k = T
      } ->
    let map_input = Value.eval environment map in
    let result = Incr_map.mapi map_input ~f:(fun ~key ~data -> by key data) in
    Snapshot.create ~result ~apply_action:unusable_apply_action
  | Enum
      { which; out_of; key_equal; key_type_id; key_compare; key_and_cmp = T; sexp_of_key }
    ->
    let key = Value.eval environment which in
    Incremental.set_cutoff key (Incremental.Cutoff.of_equal key_equal);
    let%pattern_bind result, apply_action =
      let create_keyed = unstage (Path.Elem.keyed ~compare:key_compare key_type_id) in
      let%map key = key in
      let path = Path.append path Path.Elem.(Assoc (create_keyed key)) in
      let (T { t; model = model_info; action = action_info }) = Map.find_exn out_of key in
      let chosen_model =
        Incremental.map model ~f:(fun map ->
          let (Hidden.Model.T { model; info; t_of_sexp = _ }) =
            Hidden.Multi_model.find_exn map key
          in
          let equal = Type_equal.Id.same_witness_exn info.type_id model_info.type_id in
          Type_equal.conv equal model)
      in
      let inject action =
        inject (Hidden.Action.T { action; type_id = action_info; key })
      in
      let snapshot = eval ~environment ~model:chosen_model ~path ~inject t in
      let apply_action =
        let%mapn apply_action = Snapshot.apply_action snapshot
        and model = model in
        fun ~schedule_event (Hidden.Action.T { action; type_id; key = key' }) ->
          match key_equal key' key, Type_equal.Id.same_witness type_id action_info with
          | true, Some T ->
            let new_model = apply_action ~schedule_event action in
            let new_model = Hidden.Model.create model_info new_model in
            Hidden.Multi_model.set model ~key ~data:new_model
          | _ ->
            let key = sexp_of_key key in
            let action = Type_equal.Id.to_sexp type_id action in
            eprint_s
              [%message
                "an action inside of Bonsai.enum as been dropped because the computation \
                 is no longer active"
                  (key : Sexp.t)
                  (action : Sexp.t)];
            model
      in
      Snapshot.result snapshot, apply_action
    in
    let apply_action = Incr.join apply_action
    and result = Incr.join result in
    Snapshot.create ~apply_action ~result
  | Lazy lazy_computation ->
    let (T { t; model = model_info; action = action_info }) = force lazy_computation in
    let input_model =
      let%map model = model in
      let (Hidden.Model.T { model; info; _ }) =
        Option.value model ~default:(Hidden.Model.create model_info model_info.default)
      in
      let witness = Type_equal.Id.same_witness_exn info.type_id model_info.type_id in
      Type_equal.conv witness model
    in
    let inject action =
      inject (Hidden.Action.T { action; type_id = action_info; key = () })
    in
    let snapshot = eval ~environment ~path ~model:input_model ~inject t in
    let apply_action =
      let%map apply_action = Snapshot.apply_action snapshot
      and model = model in
      fun ~schedule_event (Hidden.Action.T { action; type_id; key = () }) ->
        match Type_equal.Id.same_witness type_id action_info with
        | Some T ->
          let new_model = apply_action ~schedule_event action in
          Some (Hidden.Model.create model_info new_model)
        | None -> model
    in
    Snapshot.create ~apply_action ~result:(Snapshot.result snapshot)
  | Wrap { model_id; inject_id; inner; apply_action } ->
    let%pattern_bind outer_model, inner_model = model in
    let inject_outer a = inject (Either.First a) in
    let inject_inner a = inject (Either.Second a) in
    let inner_snapshot =
      let environment =
        environment
        |> Environment.add_exn ~key:model_id ~data:outer_model
        |> Environment.add_exn ~key:inject_id ~data:(Incr.return inject_outer)
      in
      eval ~environment ~path ~model:inner_model ~inject:inject_inner inner
    in
    let inner_result = Snapshot.result inner_snapshot in
    let apply_action =
      let%mapn outer_model = outer_model
      and inner_result = inner_result
      and inner_apply_action = Snapshot.apply_action inner_snapshot
      and inner_model = inner_model in
      fun ~schedule_event action ->
        match action with
        | First action1 ->
          let new_outer_model =
            apply_action
              ~inject:inject_outer
              ~schedule_event
              inner_result
              outer_model
              action1
          in
          new_outer_model, inner_model
        | Second action2 ->
          let new_inner_model = inner_apply_action ~schedule_event action2 in
          outer_model, new_inner_model
    in
    Snapshot.create ~result:inner_result ~apply_action
  | With_model_resetter { t; default_model } ->
    let reset_event = inject (First ()) in
    let inject a = inject (Second a) in
    let snapshot = eval ~environment ~path ~model ~inject t in
    let apply_action =
      let%map apply_action = Snapshot.apply_action snapshot in
      fun ~schedule_event action ->
        match action with
        | First () -> default_model
        | Second a -> apply_action ~schedule_event a
    in
    let result =
      let%map result = Snapshot.result snapshot in
      result, reset_event
    in
    Snapshot.create ~result ~apply_action
  | Path ->
    Snapshot.create
      ~result:(Incr.return path)
      ~apply_action:
        (Incr.return (fun ~schedule_event:_ action -> Nothing.unreachable_code action))
;;
