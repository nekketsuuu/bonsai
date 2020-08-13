open! Core_kernel
open! Import

type ('input, 'action, 'model) apply_action =
  inject:('action -> Event.t)
  -> schedule_event:(Event.t -> unit)
  -> 'input
  -> 'model
  -> 'action
  -> 'model

type ('model, 'action, 'result) t =
  | Return : 'result Value.t -> (unit, Nothing.t, 'result) t
  | Leaf :
      { input : 'input Value.t
      ; apply_action : ('input, 'action, 'model) apply_action
      ; compute : inject:('action -> Event.t) -> 'input -> 'model -> 'result
      ; name : string
      }
      -> ('model, 'action, 'result) t
  | Leaf_incr :
      { input : 'input Value.t
      ; apply_action :
          'input Incr.t
          -> 'model Incr.t
          -> inject:('action -> Event.t)
          -> (schedule_event:(Event.t -> unit) -> 'action -> 'model) Incr.t
      ; compute :
          'input Incr.t -> 'model Incr.t -> inject:('action -> Event.t) -> 'result Incr.t
      ; name : string
      }
      -> ('model, 'action, 'result) t
  | Model_cutoff :
      { t : ('m, 'a, 'r) t
      ; model : 'm Meta.Model.t
      }
      -> ('m, 'a, 'r) t
  | Subst :
      { from : ('m1, 'a1, 'r1) t
      ; via : 'r1 Type_equal.Id.t
      ; into : ('m2, 'a2, 'r2) t
      }
      -> ('m1 * 'm2, ('a1, 'a2) Either.t, 'r2) t
  | Assoc :
      { map : ('k, 'v, 'cmp) Map.t Value.t
      ; key_id : 'k Type_equal.Id.t
      ; data_id : 'v Type_equal.Id.t
      ; by : ('model, 'action, 'result) t
      ; model_info : 'model Meta.Model.t
      ; action_info : 'action Meta.Action.t
      ; input_by_k : ('input_by_k, ('k, 'v, 'cmp) Map.t) Type_equal.t
      ; result_by_k : ('result_by_k, ('k, 'result, 'cmp) Map.t) Type_equal.t
      ; model_by_k : ('model_by_k, ('k, 'model, 'cmp) Map.t) Type_equal.t
      }
      -> ('model_by_k, 'k * 'action, 'result_by_k) t
  | Enum :
      { which : 'key Value.t
      ; out_of : ('key, 'a packed, 'cmp) Map.t
      ; sexp_of_key : 'key -> Sexp.t
      ; key_equal : 'key -> 'key -> bool
      ; key_and_cmp : ('key_and_cmp, ('key, 'cmp) Hidden.Multi_model.t) Type_equal.t
      }
      -> ('key_and_cmp, 'key Hidden.Action.t, 'a) t
  (* Lazy wraps the model in an option because otherwise you could make
     infinitely sized models (by eagerly expanding a recursive model) which
     would stack-overflow during eval.  [None] really means "unchanged from the
     default", and is used to halt the the eager expansion. *)
  | Lazy : 'a packed Lazy.t -> (Hidden.Model.t option, unit Hidden.Action.t, 'a) t
  | Wrap :
      { model_id : 'outer_model Type_equal.Id.t
      ; inject_id : ('outer_action -> Event.t) Type_equal.Id.t
      ; inner : ('inner_model, 'inner_action, 'result) t
      ; apply_action : ('result, 'outer_action, 'outer_model) apply_action
      }
      -> ('outer_model * 'inner_model, ('outer_action, 'inner_action) Either.t, 'result) t
  | With_model_resetter :
      { t : ('m, 'a, 'r) t
      ; default_model : 'm
      }
      -> ('m, (unit, 'a) Either.t, 'r * Event.t) t

and 'a packed =
  | T :
      { t : ('model, 'action, 'a) t
      ; action : 'action Meta.Action.t
      ; model : 'model Meta.Model.t
      }
      -> 'a packed
