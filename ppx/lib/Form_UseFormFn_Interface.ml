open Meta
open Ast
open AstHelpers
open Printer
open Ppxlib
open Ast_helper

module Dirty = struct
  type context =
    | FieldsOnly
    | CollectionsOnly of { collections_cond : expression }
    | FieldsAndCollections of { collections_cond : expression }

  let collection_cond ~loc ({ collection; fields } : Scheme.collection) =
    [%expr
      Belt.Array.every
        [%e E.field2 ~in_:("state", "fieldsStatuses") ~loc collection.plural]
        [%e
          Uncurried.fn
            ~loc
            ~arity:1
            [%expr
              fun item ->
                [%e
                  Exp.match_
                    ~attrs:[ warning_4_disable ~loc ]
                    [%expr item]
                    [ Exp.case
                        (Pat.record
                           (fields
                            |> List.rev_map (fun (field : Scheme.field) ->
                              Lident field.name |> lid ~loc, [%pat? Pristine]))
                           Closed)
                        [%expr false]
                    ; Exp.case
                        (Pat.record
                           (fields
                            |> List.rev_map (fun (field : Scheme.field) ->
                              ( Lident field.name |> lid ~loc
                              , match fields, field.validator with
                                | _x :: [], SyncValidator _ -> [%pat? Dirty _]
                                | _x :: [], AsyncValidator _ ->
                                  [%pat? Dirty _ | Validating _]
                                | _, SyncValidator _ -> [%pat? Pristine | Dirty _]
                                | _, AsyncValidator _ ->
                                  [%pat? Pristine | Dirty _ | Validating _] )))
                           Closed)
                        [%expr true]
                    ]]]] [@res.uapp]]
  ;;
end

let ast ~(scheme : Scheme.t) ~(async : bool) ~(metadata : unit option) ~loc =
  let dirty =
    let fields = scheme |> Scheme.fields in
    let collections = scheme |> Scheme.collections in
    let context =
      match fields, collections with
      | _fields :: _, [] -> Dirty.FieldsOnly
      | [], collection :: collections ->
        Dirty.CollectionsOnly
          { collections_cond =
              collections
              |> E.conj
                   ~loc
                   ~exp:(Dirty.collection_cond ~loc collection)
                   ~make:Dirty.collection_cond
          }
      | _fields :: _, collection :: collections ->
        Dirty.FieldsAndCollections
          { collections_cond =
              collections
              |> E.conj
                   ~loc
                   ~exp:(Dirty.collection_cond ~loc collection)
                   ~make:Dirty.collection_cond
          }
      | [], [] ->
        failwith
          "No fields and no collections in the schema. Please, file an issue with your \
           use-case."
    in
    let no_case =
      Exp.case
        (Pat.record
           (scheme
            |> List.rev
            |> List.rev_map (fun (entry : Scheme.entry) ->
              match entry with
              | Field field -> Lident field.name |> lid ~loc, [%pat? Pristine]
              | Collection { collection } ->
                Lident collection.plural |> lid ~loc, [%pat? _]))
           Closed)
        [%expr false]
    in
    let yes_case =
      Exp.case
        (Pat.record
           (scheme
            |> List.rev
            |> List.rev_map (fun (entry : Scheme.entry) ->
              match entry with
              | Field field ->
                ( Lident field.name |> lid ~loc
                , (match
                     ( scheme
                       |> List.filter (fun (entry : Scheme.entry) ->
                         match entry with
                         | Field _ -> true
                         | Collection _ -> false)
                     , field.validator )
                   with
                   | _x :: [], SyncValidator _ -> [%pat? Dirty _]
                   | _x :: [], AsyncValidator _ -> [%pat? Dirty _ | Validating _]
                   | _, SyncValidator _ -> [%pat? Pristine | Dirty _]
                   | _, AsyncValidator _ -> [%pat? Pristine | Dirty _ | Validating _]) )
              | Collection { collection } ->
                Lident collection.plural |> lid ~loc, [%pat? _]))
           Closed)
        [%expr true]
    in
    let match_exp =
      Exp.match_
        ~attrs:[ warning_4_disable ~loc ]
        [%expr state.fieldsStatuses]
        [ no_case; yes_case ]
    in
    Uncurried.fn
      ~loc
      ~arity:1
      [%expr
        fun () ->
          [%e
            match context with
            | FieldsOnly -> match_exp
            | CollectionsOnly { collections_cond } -> collections_cond
            | FieldsAndCollections { collections_cond } ->
              [%expr if [%e collections_cond] then true else [%e match_exp]]]]
  in
  let valid =
    if async
    then
      Uncurried.fn
        ~loc
        ~arity:1
        [%expr
          fun () ->
            match
              [%e
                match metadata with
                | None ->
                  [%expr
                    validateForm
                      state.input
                      ~validators
                      ~fieldsStatuses:state.fieldsStatuses [@res.uapp]]
                | Some () ->
                  [%expr
                    validateForm
                      state.input
                      ~validators
                      ~fieldsStatuses:state.fieldsStatuses
                      ~metadata [@res.uapp]]]
            with
            | Validating _ -> None
            | Valid _ -> Some true
            | Invalid _ -> Some false]
    else
      Uncurried.fn
        ~loc
        ~arity:1
        [%expr
          fun () ->
            match
              [%e
                match metadata with
                | None ->
                  [%expr
                    validateForm
                      state.input
                      ~validators
                      ~fieldsStatuses:state.fieldsStatuses [@res.uapp]]
                | Some () ->
                  [%expr
                    validateForm
                      state.input
                      ~validators
                      ~fieldsStatuses:state.fieldsStatuses
                      ~metadata [@res.uapp]]]
            with
            | Valid _ -> true
            | Invalid _ -> false]
  in
  let base =
    [ "input", [%expr state.input]
    ; "status", [%expr state.formStatus]
    ; "dirty", dirty
    ; "valid", valid
    ; ( "submitting"
      , [%expr
          match state.formStatus with
          | Submitting _ -> true
          | Editing | Submitted | SubmissionFailed _ -> false] )
    ; "submit", Uncurried.fn ~loc ~arity:1 [%expr fun () -> (dispatch Submit [@res.uapp])]
    ; ( "mapSubmissionError"
      , Uncurried.fn
          ~loc
          ~arity:1
          [%expr fun map -> (dispatch (MapSubmissionError map) [@res.uapp])] )
    ; ( "dismissSubmissionError"
      , Uncurried.fn
          ~loc
          ~arity:1
          [%expr fun () -> (dispatch DismissSubmissionError [@res.uapp])] )
    ; ( "dismissSubmissionResult"
      , Uncurried.fn
          ~loc
          ~arity:1
          [%expr fun () -> (dispatch DismissSubmissionResult [@res.uapp])] )
    ; "reset", Uncurried.fn ~loc ~arity:1 [%expr fun () -> (dispatch Reset [@res.uapp])]
    ]
  in
  let update_fns =
    scheme
    |> List.fold_left
         (fun acc (entry : Scheme.entry) ->
           match entry with
           | Field field ->
             ( FieldPrinter.update_fn ~field:field.name
             , Uncurried.fn
                 ~loc
                 ~arity:2
                 [%expr
                   fun nextInputFn nextValue ->
                     (dispatch
                        [%e
                          Exp.construct
                            (Lident (FieldPrinter.update_action ~field:field.name)
                             |> lid ~loc)
                            (Some
                               (Uncurried.fn
                                  ~loc
                                  ~arity:1
                                  [%expr
                                    fun __x -> (nextInputFn __x nextValue [@res.uapp])]))]
                      [@res.uapp])] )
             :: acc
           | Collection { collection; fields } ->
             fields
             |> List.fold_left
                  (fun acc (field : Scheme.field) ->
                    ( FieldOfCollectionPrinter.update_fn ~collection ~field:field.name
                    , Uncurried.fn
                        ~loc
                        ~arity:3
                        [%expr
                          fun ~at:index nextInputFn nextValue ->
                            (dispatch
                               [%e
                                 Exp.construct
                                   (Lident
                                      (FieldOfCollectionPrinter.update_action
                                         ~collection
                                         ~field:field.name)
                                    |> lid ~loc)
                                   (Some
                                      [%expr
                                        [%e
                                          Uncurried.fn
                                            ~loc
                                            ~arity:1
                                            [%expr
                                              fun __x ->
                                                (nextInputFn __x nextValue [@res.uapp])]]
                                        , index])] [@res.uapp])] )
                    :: acc)
                  acc)
         []
  in
  let blur_fns =
    scheme
    |> List.fold_left
         (fun acc (entry : Scheme.entry) ->
           match entry with
           | Field field ->
             ( FieldPrinter.blur_fn ~field:field.name
             , Uncurried.fn
                 ~loc
                 ~arity:1
                 [%expr
                   fun () ->
                     (dispatch
                        [%e
                          Exp.construct
                            (Lident (FieldPrinter.blur_action ~field:field.name)
                             |> lid ~loc)
                            None] [@res.uapp])] )
             :: acc
           | Collection { collection; fields } ->
             fields
             |> List.fold_left
                  (fun acc (field : Scheme.field) ->
                    ( FieldOfCollectionPrinter.blur_fn ~collection ~field:field.name
                    , Uncurried.fn
                        ~loc
                        ~arity:1
                        [%expr
                          fun ~at:index ->
                            (dispatch
                               [%e
                                 Exp.construct
                                   (Lident
                                      (FieldOfCollectionPrinter.blur_action
                                         ~collection
                                         ~field:field.name)
                                    |> lid ~loc)
                                   (Some [%expr index])] [@res.uapp])] )
                    :: acc)
                  acc)
         []
  in
  let result_entries =
    scheme
    |> List.fold_left
         (fun acc (entry : Scheme.entry) ->
           match entry with
           | Field field ->
             ( FieldPrinter.result_value ~field:field.name
             , match field.validator with
               | SyncValidator _ ->
                 [%expr
                   exposeFieldResult
                     [%e field.name |> E.field2 ~in_:("state", "fieldsStatuses") ~loc]
                   [@res.uapp]]
               | AsyncValidator _ ->
                 [%expr
                   Async.exposeFieldResult
                     [%e field.name |> E.field2 ~in_:("state", "fieldsStatuses") ~loc]
                   [@res.uapp]] )
             :: acc
           | Collection { collection; fields } ->
             fields
             |> List.fold_left
                  (fun acc (field : Scheme.field) ->
                    ( FieldOfCollectionPrinter.result_fn ~collection ~field:field.name
                    , match field.validator with
                      | SyncValidator _ ->
                        Uncurried.fn
                          ~loc
                          ~arity:1
                          [%expr
                            fun ~at:index ->
                              (exposeFieldResult
                                 [%e
                                   field.name
                                   |> E.field_of_collection2
                                        ~in_:("state", "fieldsStatuses")
                                        ~collection
                                        ~loc] [@res.uapp])]
                      | AsyncValidator _ ->
                        Uncurried.fn
                          ~loc
                          ~arity:1
                          [%expr
                            fun ~at:index ->
                              (Async.exposeFieldResult
                                 [%e
                                   field.name
                                   |> E.field_of_collection2
                                        ~in_:("state", "fieldsStatuses")
                                        ~collection
                                        ~loc] [@res.uapp])] )
                    :: acc)
                  acc)
         []
  in
  let collection_entries =
    scheme
    |> List.fold_left
         (fun acc (entry : Scheme.entry) ->
           match entry with
           | Field _ -> acc
           | Collection { collection; validator } ->
             let add_fn =
               ( collection |> CollectionPrinter.add_fn
               , Uncurried.fn
                   ~loc
                   ~arity:1
                   [%expr
                     fun entry ->
                       (dispatch
                          [%e
                            Exp.construct
                              (Lident (collection |> CollectionPrinter.add_action)
                               |> lid ~loc)
                              (Some [%expr entry])] [@res.uapp])] )
             in
             let remove_fn =
               ( collection |> CollectionPrinter.remove_fn
               , Uncurried.fn
                   ~loc
                   ~arity:1
                   [%expr
                     fun ~at:index ->
                       (dispatch
                          [%e
                            Exp.construct
                              (Lident (collection |> CollectionPrinter.remove_action)
                               |> lid ~loc)
                              (Some [%expr index])] [@res.uapp])] )
             in
             let result_value =
               match validator with
               | Ok (Some ()) | Error () ->
                 Some
                   ( collection |> CollectionPrinter.result_value
                   , collection.plural
                     |> E.field2 ~in_:("state", "collectionsStatuses") ~loc )
               | Ok None -> None
             in
             (match result_value with
              | Some result_value -> result_value :: remove_fn :: add_fn :: acc
              | None -> remove_fn :: add_fn :: acc))
         []
  in
  E.record
    ~loc
    (base
     |> List.rev_append collection_entries
     |> List.rev_append result_entries
     |> List.rev_append blur_fns
     |> List.rev_append update_fns)
;;
