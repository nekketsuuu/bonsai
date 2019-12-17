open! Core_kernel
open! Async_kernel
open! Bonsai_web

module T = struct
  let name = "compose component"

  module Input = struct
    type t = { inject_send_message : string -> Vdom.Event.t } [@@deriving fields]

    let create = Fields.create
  end

  module Model = struct
    type t = { message : string }

    let default = { message = "" }
  end

  module Result = Vdom.Node

  module Action = struct
    type t = Update of string [@@deriving sexp_of]
  end

  let apply_action ~inject:_ ~schedule_event:_ _input _model (Action.Update message) =
    { Model.message }
  ;;

  let compute ~inject input model =
    let on_ret =
      let is_key_ret key =
        String.equal
          "Enter"
          (key##.code
           |> Js_of_ocaml.Js.Optdef.to_option
           |> Option.value_exn
           |> Js_of_ocaml.Js.to_string)
      in
      Vdom.Attr.on_keypress (fun key ->
        if is_key_ret key
        then
          Vdom.Event.Many
            [ Input.inject_send_message input model.Model.message
            ; inject (Action.Update "")
            ]
        else Vdom.Event.Ignore)
    in
    let text_input =
      Vdom_input_widgets.Entry.text
        ~extra_attrs:[ on_ret ]
        ~on_input:(function
          | Some s -> inject (Action.Update s)
          | None -> inject (Action.Update ""))
        ~value:(Some model.Model.message)
        ()
    in
    let submit_button =
      Vdom_input_widgets.Button.simple "send" ~on_click:(fun _ ->
        Input.inject_send_message input model.Model.message)
    in
    Vdom.Node.div [ Vdom.Attr.id "compose" ] [ text_input; submit_button ]
  ;;
end

include T

let component = Bonsai.of_module (module T)
