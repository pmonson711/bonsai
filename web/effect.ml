open! Core_kernel
open! Async_kernel
open! Import

module Callback = struct
  type ('request, 'response) t =
    | T :
        { request : 'request
        ; userdata : 'userdata
        ; on_response : 'response -> 'userdata -> Vdom.Event.t
        }
        -> ('request, 'response) t

  let make_with_userdata ~request ~on_response ~userdata =
    T { request; on_response; userdata }
  ;;

  let make ~request ~on_response =
    let on_response x () = on_response x in
    make_with_userdata ~request ~on_response ~userdata:()
  ;;

  let request (T { request; _ }) = request
  let respond_to (T { on_response; userdata; _ }) response = on_response response userdata
end

type 'response t =
  | T :
      { request : 'request
      ; evaluator : ('request, 'response) Callback.t -> Vdom.Event.t
      }
      -> 'response t

let of_sync_fun (type query result) f =
  let module E =
    Vdom.Event.Define (struct
      module Action = struct
        type t = (query, result) Callback.t
      end

      let handle action =
        let result = f (Callback.request action) in
        let evt = Callback.respond_to action result in
        Vdom.Event.Expert.handle_non_dom_event_exn evt
      ;;
    end)
  in
  let evaluator = E.inject in
  stage (fun request -> T { request; evaluator })
;;

module For_testing = struct
  module Svar = struct
    type 'a state =
      | Empty of { handlers : ('a -> unit) Bag.t }
      | Full of 'a

    type 'a t = 'a state ref

    let create () = ref (Empty { handlers = Bag.create () })

    let upon t handler =
      match !t with
      | Empty { handlers } -> ignore (Bag.add handlers handler : _ Bag.Elt.t)
      | Full x -> handler x
    ;;

    let fill_if_empty t x =
      match !t with
      | Full _ -> ()
      | Empty { handlers } ->
        Bag.iter handlers ~f:(fun handler -> handler x);
        t := Full x
    ;;

    let peek t =
      match !t with
      | Empty _ -> None
      | Full x -> Some x
    ;;
  end

  let of_svar_fun (type query result) f =
    let module E =
      Vdom.Event.Define (struct
        module Action = struct
          type t = (query, result) Callback.t
        end

        let handle action =
          Svar.upon
            (f (Callback.request action))
            (fun result ->
               let evt = Callback.respond_to action result in
               Vdom.Event.Expert.handle_non_dom_event_exn evt)
        ;;
      end)
    in
    let evaluator = E.inject in
    stage (fun request -> T { request; evaluator })
  ;;

  module Query_response_tracker = struct
    type ('q, 'r) rpc =
      { query : 'q
      ; response : 'r Svar.t
      }

    type ('q, 'r) t = ('q, 'r) rpc Bag.t

    let create () = Bag.create ()

    let add_query t query =
      let response = Svar.create () in
      ignore (Bag.add t { query; response } : _ Bag.Elt.t);
      response
    ;;

    let queries_pending_response t =
      Bag.to_list t |> List.map ~f:(fun { query; response = _ } -> query)
    ;;

    type 'r maybe_respond =
      | No_response_yet
      | Respond of 'r

    let maybe_respond t ~f =
      Bag.filter_inplace t ~f:(fun { query; response } ->
        match f query with
        | No_response_yet -> true
        | Respond resp ->
          Svar.fill_if_empty response resp;
          false)
    ;;
  end

  let of_query_response_tracker qrt = of_svar_fun (Query_response_tracker.add_query qrt)
end

let return value =
  let f = unstage (of_sync_fun Fn.id) in
  f value
;;

let inject (T { request; evaluator }) ~on_response =
  evaluator (Callback.make ~request ~on_response)
;;

let inject_ignoring_response t = inject t ~on_response:(Fn.const Vdom.Event.Ignore)

let inject_with_userdata (T { request; evaluator }) ~userdata ~on_response =
  evaluator (Callback.make_with_userdata ~request ~userdata ~on_response)
;;

let hoist (T { request; evaluator }) ~f ~inject_handle_second =
  T
    { request
    ; evaluator =
        (fun (Callback.T { request; userdata; on_response }) ->
           let on_response response ud =
             match f response with
             | First response -> on_response response ud
             | Second other -> inject_handle_second other
           in
           evaluator (Callback.make_with_userdata ~request ~userdata ~on_response))
    }
;;

let map (T { request; evaluator }) ~f =
  T
    { request
    ; evaluator =
        (fun (Callback.T { request; userdata; on_response }) ->
           let on_response response ud = on_response (f response) ud in
           evaluator (Callback.make_with_userdata ~request ~userdata ~on_response))
    }
;;

let bind (T { request; evaluator }) ~f =
  T
    { request
    ; evaluator =
        (fun (Callback.T { request; userdata; on_response }) ->
           let on_response response ud =
             let bound : _ t = f response in
             inject bound ~on_response:(fun x -> on_response x ud)
           in
           evaluator (Callback.make_with_userdata ~request ~userdata ~on_response))
    }
;;

include Core_kernel.Monad.Make (struct
    type nonrec 'a t = 'a t

    let return = return
    let map = `Custom map
    let bind = bind
  end)

let handle_error t ~f = hoist t ~f:Result.to_either ~inject_handle_second:f

let of_deferred_fun (type query result) f =
  let module E =
    Vdom.Event.Define (struct
      module Action = struct
        type t = (query, result) Callback.t
      end

      let handle action =
        don't_wait_for
          (let%map.Deferred result = f (Callback.request action) in
           let evt = Callback.respond_to action result in
           Vdom.Event.Expert.handle_non_dom_event_exn evt)
      ;;
    end)
  in
  let evaluator = E.inject in
  stage (fun request -> T { request; evaluator })
;;

let never = T { request = (); evaluator = (fun _ -> Vdom.Event.Ignore) }

let sequence =
  let module E =
    Vdom.Event.Define (struct
      module Action = struct
        type t = (Vdom.Event.t, unit) Callback.t
      end

      let handle action =
        Vdom.Event.Expert.handle_non_dom_event_exn (Callback.request action);
        let evt = Callback.respond_to action () in
        Vdom.Event.Expert.handle_non_dom_event_exn evt
      ;;
    end)
  in
  E.inject
;;

let of_event (request : Vdom.Event.t) =
  let evaluator = sequence in
  T { request; evaluator }
;;
